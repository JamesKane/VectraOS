// SPDX-License-Identifier: BSD-3-Clause

/// A name segment (ACPI 6.5 §20.2.2): four characters, kept as AML stores
/// them, little-endian in a UInt32.
public struct NameSeg: Equatable, Sendable {
  public var raw: UInt32

  public init(raw: UInt32) { self.raw = raw }
  public init(_ b: [UInt8], at: Int = 0) { raw = b.le32(at) }

  public var bytes: [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt32($0))) } }

  /// Whether `b` can start a name segment: "A"-"Z" or "_".
  static func isLead(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || b == 0x5F }
  /// Whether `b` can follow: those, or "0"-"9".
  static func isName(_ b: UInt8) -> Bool { isLead(b) || (b >= 0x30 && b <= 0x39) }

  static func make(_ s: StaticString) -> NameSeg {
    var b = unsafe s.withUTF8Buffer { unsafe Array($0) }
    while b.count < 4 { b.append(0x5F) }
    return NameSeg(b)
  }
}

/// A NameString as written (§20.2.2): from the root or not, how many
/// parents up, then segments. A lone segment with neither prefix is
/// looked up through the enclosing scopes (§5.3).
public struct NamePath: Equatable, Sendable {
  public var fromRoot = false
  public var parents = 0
  public var segments: [NameSeg] = []

  public init() {}

  /// Whether lookups search upward (§5.3): one segment, no prefix.
  public var searches: Bool { !fromRoot && parents == 0 && segments.count == 1 }
  public var isNull: Bool { !fromRoot && parents == 0 && segments.isEmpty }
}

/// A span of AML in a loaded table: a method body, or code run at load.
public struct Code: Equatable, Sendable {
  public var table: Int
  public var start: Int
  public var end: Int
}

/// A value an object holds (A0b: what Name and packages hold at load).
public indirect enum Value: Equatable, Sendable {
  case integer(UInt64)
  case string([UInt8])
  case buffer([UInt8])
  case package([Value])
  /// A name in a package, resolved when it's used (§19.6.102).
  case name(NamePath, scope: Int)
  /// Not a constant: evaluated when first needed (A0c).
  case deferred(Code, scope: Int)
}

/// What a namespace node is (§5.3, §19.6).
public enum Object: Equatable, Sendable {
  /// A scope with nothing in it of its own: the predefined roots, and a
  /// name a Scope or a path made before its definition.
  case scope
  case value(Value)
  case method(args: Int, serialized: Bool, syncLevel: Int, body: Code)
  /// One the OS provides (`_OSI`).
  case builtinMethod(args: Int)
  case device
  case processor(id: UInt8, blockAddress: UInt32, blockLength: UInt8)
  case powerResource(systemLevel: UInt8, resourceOrder: UInt16)
  case thermalZone
  case mutex(syncLevel: UInt8)
  case event
  /// An operation region: its space; offset and length are evaluated when
  /// first needed (A0d).
  case region(space: UInt8, offset: Value, length: Value)
  case dataRegion(signature: Value, oemID: Value, oemTableID: Value)
  case field(Field)
  case alias(NamePath, scope: Int)
  /// A buffer field (CreateField and its kin): its buffer and bits are
  /// in the node's run-time data.
  case bufferField
  /// Declared here, defined elsewhere (another table): its object type
  /// and, for a method, its argument count.
  case external(type: UInt8, args: Int)
}

/// A field unit (§19.6.48, .65, .7): bits of a region, of a data field
/// selected through an index field, or of a region selected by a bank.
public struct Field: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    case region(NamePath)
    case index(index: NamePath, data: NamePath)
    case bank(region: NamePath, bank: NamePath, value: Value)
  }
  public var source: Source
  /// Where the field list was: names resolve from here.
  public var scope: Int
  /// AccessType (bits 0-3), LockRule (4), UpdateRule (5-6).
  public var flags: UInt8
  public var bitOffset: UInt32
  public var bitLength: UInt32
  /// The access attribute in force (AccessField, ExtendedAccessField).
  public var accessAttrib: UInt8
  public var accessLength: UInt8
}

/// A namespace node.
public struct Node: Sendable {
  public var name: NameSeg
  public var parent: Int
  public var object: Object
  /// The table that defined it; -1 for the predefined ones.
  public var table: Int
  var firstChild = -1
  var lastChild = -1
  var next = -1
}

/// Something wrong in a table that loading went past (ACPICA does the
/// same): the table loads, without that definition.
public struct LoadProblem: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// A second definition of a name: the first stays.
    case alreadyDefined
    /// A Scope or a path through a name that isn't there.
    case notFound
    /// Load-time code that failed: the table loads without what it did.
    case codeFailed(ACPIError)
  }
  public var kind: Kind
  public var table: Int
  public var offset: Int
}

/// The ACPI namespace (§5.3): every table's objects in one tree, and
/// their run-time values.
public struct Namespace {
  public private(set) var nodes: [Node] = []
  /// Each node's run-time object: a Name's value once first used and as
  /// stores change it, a buffer field's bits, a mutex's or event's count.
  var data: [Datum?] = []
  /// Iterations one While may take before it's abandoned.
  public var loopLimit = 1 << 20
  /// How long one While may run, in the Timer's 100 ns units: 30 s, as
  /// other interpreters allow.
  public var loopTimeout: UInt64 = 300_000_000
  /// Statements and expressions one evaluation may run.
  public var stepLimit = 1 << 26
  /// Call frames so far: a reference to a local names its frame by this,
  /// so one that outlives its call is caught, not misread.
  var frameSerial = 0
  /// The most nodes the namespace holds; definitions past it fail.
  public static let maximumNodes = 1 << 20
  /// Mutexes held, innermost last, for sync-level order (§19.6.87).
  var heldMutexes: [(node: Int, syncLevel: Int, count: Int)] = []
  /// Each loaded table's bytes, which Code spans point into.
  public private(set) var tables: [[UInt8]] = []
  /// Code outside any method, in load order, with its scope: run at load
  /// (A0c), as the tables require.
  public private(set) var loadCode: [(code: Code, scope: Int)] = []
  public private(set) var problems: [LoadProblem] = []
  /// 64, or 32 if the DSDT's revision is below 2.
  public let integerBits: Int

  public static let root = 0

  public init(integerBits: Int = 64) {
    self.integerBits = integerBits
    nodes.append(Node(name: NameSeg.make("\\___"), parent: -1, object: .scope, table: -1))
    data.append(nil)
    // The predefined names (§5.3.1, §5.7).
    for s: StaticString in ["_GPE", "_PR", "_SB", "_SI", "_TZ"] {
      _ = add(NameSeg.make(s), under: Self.root, .scope, table: -1)
    }
    _ = add(NameSeg.make("_OSI"), under: Self.root, .builtinMethod(args: 1), table: -1)
    _ = add(NameSeg.make("_OS"), under: Self.root, .value(.string(Array("Microsoft Windows NT".utf8))), table: -1)
    _ = add(NameSeg.make("_REV"), under: Self.root, .value(.integer(2)), table: -1)
    _ = add(NameSeg.make("_GL"), under: Self.root, .mutex(syncLevel: 0), table: -1)
  }

  // MARK: The tree

  public func children(_ node: Int) -> [Int] {
    var out: [Int] = []
    var c = nodes[node].firstChild
    while c >= 0 {
      out.append(c)
      c = nodes[c].next
    }
    return out
  }

  public func child(_ node: Int, _ name: NameSeg) -> Int? {
    var c = nodes[node].firstChild
    while c >= 0 {
      if nodes[c].name == name { return c }
      c = nodes[c].next
    }
    return nil
  }

  mutating func add(_ name: NameSeg, under parent: Int, _ object: Object, table: Int) -> Int {
    let n = nodes.count
    nodes.append(Node(name: name, parent: parent, object: object, table: table))
    data.append(nil)
    if nodes[parent].lastChild >= 0 { nodes[nodes[parent].lastChild].next = n } else { nodes[parent].firstChild = n }
    nodes[parent].lastChild = n
    return n
  }

  mutating func setObject(_ node: Int, _ object: Object, table: Int) {
    nodes[node].object = object
    nodes[node].table = table
    data[node] = nil
  }

  /// Takes a node (and what's under it) out of the tree: a method's
  /// temporary objects go when it returns (§19.6.85).
  mutating func unlink(_ node: Int) {
    let parent = nodes[node].parent
    guard parent >= 0 else { return }
    var prev = -1
    var c = nodes[parent].firstChild
    while c >= 0 && c != node {
      prev = c
      c = nodes[c].next
    }
    guard c == node else { return }
    if prev >= 0 { nodes[prev].next = nodes[node].next } else { nodes[parent].firstChild = nodes[node].next }
    if nodes[parent].lastChild == node { nodes[parent].lastChild = prev }
    nodes[node].next = -1
    nodes[node].parent = -2  // gone
    data[node] = nil
  }

  /// Whether the node is still in the tree.
  public func isLive(_ node: Int) -> Bool {
    var n = node
    while n != Self.root {
      let p = nodes[n].parent
      if p < 0 { return false }
      n = p
    }
    return true
  }

  mutating func note(_ kind: LoadProblem.Kind, table: Int, offset: Int) {
    guard problems.count < 1000 else { return }  // enough to diagnose; no more memory
    problems.append(LoadProblem(kind: kind, table: table, offset: offset))
  }

  mutating func addLoadCode(_ code: Code, scope: Int) { loadCode.append((code, scope)) }

  mutating func addTable(_ bytes: [UInt8]) -> Int {
    tables.append(bytes)
    return tables.count - 1
  }

  /// A node's absolute path: "\" and its segments joined by "." (as Linux
  /// writes them in sysfs, four characters each).
  public func path(_ node: Int) -> [UInt8] {
    if node == Self.root { return [0x5C] }
    var segs: [[UInt8]] = []
    var n = node
    while n != Self.root {
      segs.append(nodes[n].name.bytes)
      n = nodes[n].parent
    }
    var out: [UInt8] = [0x5C]
    for (i, s) in segs.reversed().enumerated() {
      if i > 0 { out.append(0x2E) }
      out += s
    }
    return out
  }

  // MARK: Names

  /// The scope a path's prefixes and all but its last segment lead to,
  /// from `scope`; nil if a name on the way isn't there.
  func parentScope(_ path: NamePath, from scope: Int) -> Int? {
    var at = path.fromRoot ? Self.root : scope
    for _ in 0..<path.parents {
      guard at != Self.root else { return nil }
      at = nodes[at].parent
    }
    for seg in path.segments.dropLast() {
      guard let c = child(at, seg) else { return nil }
      at = c
    }
    return at
  }

  /// The node `path` names from `scope` (§5.3): a lone segment is
  /// searched for in each enclosing scope up to the root; any other path
  /// is followed exactly. Aliases are followed.
  public func resolve(_ path: NamePath, from scope: Int) -> Int? {
    guard let found = find(path, from: scope) else { return nil }
    return follow(found)
  }

  func find(_ path: NamePath, from scope: Int) -> Int? {
    if path.isNull { return nil }
    if path.fromRoot && path.segments.isEmpty { return Self.root }
    if path.searches {
      var at = scope
      while true {
        if let c = child(at, path.segments[0]) { return c }
        if at == Self.root { return nil }
        at = nodes[at].parent
      }
    }
    guard let parent = parentScope(path, from: scope), let last = path.segments.last else {
      return path.segments.isEmpty ? parentScope(path, from: scope) : nil
    }
    return child(parent, last)
  }

  /// Through aliases to what they name (a few levels at most).
  func follow(_ node: Int) -> Int? {
    var n = node
    for _ in 0..<8 {
      guard case .alias(let target, let scope) = nodes[n].object else { return n }
      guard let t = find(target, from: scope) else { return nil }
      n = t
    }
    return nil
  }

  /// A node by its text path, "\_SB.PCI0" (for tests and tools).
  public func lookup(_ text: StaticString) -> Int? {
    let bytes = unsafe text.withUTF8Buffer { unsafe Array($0) }
    return lookup(bytes)
  }

  public func lookup(_ text: [UInt8]) -> Int? { lookupRelative(text, from: Self.root) }

  /// How many arguments a call to the node takes, if it's a method (or
  /// declared as one by External).
  func methodArgs(_ node: Int) -> Int? {
    switch nodes[node].object {
    case .method(let args, _, _, _): args
    case .builtinMethod(let args): args
    case .external(let type, let args) where type == 8: args  // 8: MethodObj
    default: nil
    }
  }
}
