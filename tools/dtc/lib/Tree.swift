// SPDX-License-Identifier: BSD-3-Clause

import Fdt

/// A devicetree as `vx dtc` builds it from source (D154): nodes with
/// labels, properties whose values may still hold references, resolved
/// and written as a flattened tree by `flatten`.
public final class DtNode {
  public var name: String
  var labels: [String] = []
  var properties: [DtProperty] = []
  public var children: [DtNode] = []
  /// `/omit-if-no-ref/`: dropped unless something refers to it.
  var omitIfNoRef = false
  weak var parent: DtNode?

  init(name: String, parent: DtNode?) {
    self.name = name
    self.parent = parent
  }

  public var path: String {
    guard let parent else { return "/" }
    let above = parent.path
    return (above == "/" ? "" : above) + "/" + name
  }

  func child(named name: String) -> DtNode? { children.first { $0.name == name } }

  /// The child `name`, made if there is none.
  func child(making name: String) -> DtNode {
    if let existing = child(named: name) { return existing }
    let node = DtNode(name: name, parent: self)
    children.append(node)
    return node
  }

  /// Sets property `name`, in its old place if it had one.
  func set(_ property: DtProperty) {
    if let i = properties.firstIndex(where: { $0.name == property.name }) {
      properties[i] = property
    } else {
      properties.append(property)
    }
  }

  public func property(_ name: String) -> [UInt8]? {
    guard let p = properties.first(where: { $0.name == name }) else { return nil }
    return p.chunks.reduce(into: []) { bytes, chunk in
      if case .bytes(let b) = chunk { bytes += b }
    }
  }
}

/// A property's value, in order: bytes, and references resolved late.
struct DtProperty {
  var name: String
  var chunks: [Chunk] = []

  enum Chunk {
    case bytes([UInt8])
    /// A cell: the phandle of the node a label or path names.
    case phandle(Reference)
    /// The full path, NUL-terminated, of the node a label or path names.
    case path(Reference)
  }
}

/// `&label` or `&{/path}`, where it was written.
struct Reference {
  var target: String
  var isPath: Bool
  var at: SourceLocation
}

public struct SourceLocation: CustomStringConvertible, Sendable {
  public var file: String
  public var line: Int
  public var description: String { "\(file):\(line)" }
}

public struct DtcError: Error, CustomStringConvertible {
  public var at: SourceLocation?
  public var message: String
  public var description: String { at.map { "\($0): \(message)" } ?? message }
}

public final class DtTree {
  public let root = DtNode(name: "", parent: nil)

  public init() {}

  /// Every node, the root first, parents before children.
  func walk(_ body: (DtNode) throws -> Void) rethrows {
    var stack = [root]
    while let node = stack.popLast() {
      try body(node)
      stack.append(contentsOf: node.children.reversed())
    }
  }

  func node(labelled label: String) -> DtNode? {
    var found: DtNode?
    walk { if found == nil, $0.labels.contains(label) { found = $0 } }
    return found
  }

  func node(atPath path: String) -> DtNode? {
    var node = root
    for component in path.split(separator: "/") {
      let name = String(component)
      let match = node.children.first { $0.name == name }
        ?? (name.contains("@") ? nil : node.children.first { $0.name.split(separator: "@").first.map(String.init) == name })
      guard let match else { return nil }
      node = match
    }
    return node
  }

  func resolve(_ reference: Reference) throws(DtcError) -> DtNode {
    let node = reference.isPath ? node(atPath: reference.target) : node(labelled: reference.target)
    guard let node else {
      throw DtcError(at: reference.at, message: "no node \(reference.isPath ? "at" : "labelled") '\(reference.target)'")
    }
    return node
  }

  // MARK: Flattening

  /// Drops the `/omit-if-no-ref/` nodes nothing refers to, gives every
  /// node a reference names by phandle a `phandle` property (kept if the
  /// source gave one), and writes the flattened tree.
  public func flatten(bootCpu: UInt32 = 0) throws(DtcError) -> [UInt8] {
    try omitUnreferenced()
    try assignPhandles()
    var size = 4096
    while true {
      var buffer = [UInt8](repeating: 0, count: size)
      let written = try write(into: &buffer)
      if let written { return Array(buffer[0..<written]) }
      size *= 2
    }
  }

  /// Every reference, in document order, and whether it is a cell (one
  /// written as a path needs no phandle).
  private func references() -> [(reference: Reference, isCell: Bool)] {
    var all: [(Reference, Bool)] = []
    walk { node in
      for p in node.properties {
        for chunk in p.chunks {
          switch chunk {
          case .phandle(let r): all.append((r, true))
          case .path(let r): all.append((r, false))
          case .bytes: break
          }
        }
      }
    }
    return all
  }

  private func omitUnreferenced() throws(DtcError) {
    var referenced: [ObjectIdentifier] = []
    for (r, _) in references() { referenced.append(ObjectIdentifier(try resolve(r))) }
    func prune(_ node: DtNode) {
      node.children.removeAll { $0.omitIfNoRef && !referenced.contains(ObjectIdentifier($0)) }
      node.children.forEach(prune)
    }
    prune(root)
  }

  /// dtc's order: each phandle reference, in document order, numbers its
  /// target if it has none yet, from 1, past any the source fixed.
  private func assignPhandles() throws(DtcError) {
    var used: [UInt32] = []
    walk { node in
      if let value = node.property("phandle"), value.count == 4 { used.append(Self.be32(value)) }
    }
    var next: UInt32 = 1
    for (r, isCell) in references() where isCell {
      let target = try resolve(r)
      guard target.property("phandle") == nil else { continue }
      while used.contains(next) { next += 1 }
      target.properties.append(DtProperty(name: "phandle", chunks: [.bytes(Self.cell(next))]))
      used.append(next)
    }
  }

  /// One step of writing the tree: open a node, a property, close it.
  private enum Step {
    case begin([UInt8])
    case property([UInt8], [UInt8])
    case end
  }

  /// The tree as writer steps, references resolved, in document order.
  private func steps() throws(DtcError) -> [Step] {
    var steps: [Step] = []
    var failure: DtcError?
    func visit(_ node: DtNode) {
      steps.append(.begin(Array(node.name.utf8)))
      for p in node.properties {
        var bytes: [UInt8] = []
        for chunk in p.chunks {
          do throws(DtcError) {
            switch chunk {
            case .bytes(let b): bytes += b
            case .phandle(let r):
              let target = try resolve(r)
              guard let value = target.property("phandle") else {
                throw DtcError(at: r.at, message: "'\(r.target)' has no phandle")
              }
              bytes += value
            case .path(let r): bytes += Array(try resolve(r).path.utf8) + [0]
            }
          } catch {
            failure = failure ?? error
          }
        }
        steps.append(.property(Array(p.name.utf8), bytes))
      }
      node.children.forEach(visit)
      steps.append(.end)
    }
    visit(root)
    if let failure { throw failure }
    return steps
  }

  private func write(into buffer: inout [UInt8]) throws(DtcError) -> Int? {
    let steps = try steps()
    let capacity = buffer.count
    return buffer.withUnsafeMutableBytes { raw -> Int? in
      var out = MutableRawSpan(_unsafeBytes: raw)
      var writer = FdtWriter(capacity: capacity)
      for step in steps {
        switch step {
        case .begin(let name): writer.beginNode(name.span.bytes, into: &out)
        case .property(let name, let value): writer.property(name.span.bytes, value.span.bytes, into: &out)
        case .end: writer.endNode(into: &out)
        }
      }
      return writer.finish(into: &out)
    }
  }

  static func cell(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
  }

  static func be32(_ bytes: [UInt8]) -> UInt32 {
    bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
  }
}
