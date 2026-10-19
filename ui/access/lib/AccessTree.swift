// SPDX-License-Identifier: BSD-3-Clause

// The accessibility tree (M6i part 4, sdk.md §10, desktop.md §1's
// `a11y`): what a window says of itself to an assistive client, the UI
// Kit's per-frame side output. Nodes are in flat order, a parent before
// its children, each with its role, label, value, states, rectangle and
// the declared action it performs (by index into the tree's actions).
//
// On the way to Radharc and from it to readers a tree is packed, whole,
// into bytes (a VMO's: a tree can outgrow a message), in the order a
// reader walks it, little-endian, never a memory layout:
//
//   header (16): "TDAX", version u16 (1), 0 u16, node count u32, action
//                count u32
//   node   (56): key u64, parent i32 (-1: the root), action i32 (-1:
//                none), states u32, role u8, 0 u8 x3, x f32, y f32, width
//                f32, height f32, label (offset u32, length u32), value
//                (offset u32, length u32)
//   action  (8): name (offset u32, length u32)
//   strings    : UTF-8, offsets from the start of this area
//
// A reader checks everything: the magic, sizes, a parent before its
// child, roles it knows, actions in range, strings inside the area.

public enum Role: UInt8, Sendable {
  case none, window, group, label, heading, button, toggle, textField, list, columnHeader, row, cell, menu,
       menuItem, scrollArea, image
}

public struct AccessStates: OptionSet, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let focused = AccessStates(rawValue: 1)
  public static let focusable = AccessStates(rawValue: 2)
  public static let selected = AccessStates(rawValue: 4)
  public static let checked = AccessStates(rawValue: 8)
  public static let editable = AccessStates(rawValue: 16)
}

public struct AccessNode: Equatable, Sendable {
  /// The same node frame after frame (the kit's box key).
  public var key: UInt64
  /// Its parent's index (-1: the root).
  public var parent: Int32
  public var role: Role
  public var label: String
  /// What it holds: a text field's text.
  public var value: String
  /// Its rectangle: the window's logical pixels from the kit, the
  /// window's pixels to Radharc, the screen's from Radharc.
  public var x: Float, y: Float, width: Float, height: Float
  public var states: AccessStates
  /// The declared action it performs (an index into the tree's actions;
  /// -1: none, though a button without one can still be pressed).
  public var action: Int32

  public init(key: UInt64, parent: Int32, role: Role, label: String, value: String, x: Float, y: Float,
              width: Float, height: Float, states: AccessStates, action: Int32)
  {
    self.key = key
    self.parent = parent
    self.role = role
    self.label = label
    self.value = value
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.states = states
    self.action = action
  }
}

public enum AccessTreeError: Error, Equatable, Sendable {
  case malformed
}

public struct AccessTree: Equatable, Sendable {
  public var nodes: [AccessNode]
  /// The declared actions' names.
  public var actions: [String]

  public init(nodes: [AccessNode] = [], actions: [String] = []) {
    self.nodes = nodes
    self.actions = actions
  }

  static let magic: [UInt8] = [0x54, 0x44, 0x41, 0x58]  // "TDAX"
  static let header = 16, nodeSize = 56, actionSize = 8

  /// Scaled by `scale`, then moved by (dx, dy): from logical pixels to a
  /// window's, from a window's to the screen's.
  public mutating func transform(scale: Float = 1, dx: Float, dy: Float) {
    for i in nodes.indices {
      nodes[i].x = nodes[i].x * scale + dx
      nodes[i].y = nodes[i].y * scale + dy
      nodes[i].width *= scale
      nodes[i].height *= scale
    }
  }

  /// The index of the focused node, if any.
  public var focused: Int? { nodes.firstIndex { $0.states.contains(.focused) } }

  // MARK: Packing

  /// The tree packed.
  public func encoded() -> [UInt8] {
    var strings: [UInt8] = []
    func string(_ s: String) -> (UInt32, UInt32) {
      let at = UInt32(strings.count)
      strings.append(contentsOf: s.utf8)
      return (at, UInt32(strings.count) - at)
    }
    var out: [UInt8] = []
    out.reserveCapacity(AccessTree.header + nodes.count * AccessTree.nodeSize + actions.count * AccessTree.actionSize)
    func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
    func u32(_ v: UInt32) { for k in 0..<4 { out.append(UInt8(v >> (8 * UInt32(k)) & 0xFF)) } }
    func u64(_ v: UInt64) { for k in 0..<8 { out.append(UInt8(v >> (8 * UInt64(k)) & 0xFF)) } }
    out.append(contentsOf: AccessTree.magic)
    u16(1)
    u16(0)
    u32(UInt32(nodes.count))
    u32(UInt32(actions.count))
    for n in nodes {
      u64(n.key)
      u32(UInt32(bitPattern: n.parent))
      u32(UInt32(bitPattern: n.action))
      u32(n.states.rawValue)
      out.append(n.role.rawValue)
      out.append(contentsOf: [0, 0, 0])
      for f in [n.x, n.y, n.width, n.height] { u32(f.bitPattern) }
      let l = string(n.label), v = string(n.value)
      u32(l.0)
      u32(l.1)
      u32(v.0)
      u32(v.1)
    }
    for a in actions {
      let s = string(a)
      u32(s.0)
      u32(s.1)
    }
    out.append(contentsOf: strings)
    return out
  }

  /// A packed tree, checked.
  public init(decoding bytes: [UInt8]) throws(AccessTreeError) {
    func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 {
      UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
    guard bytes.count >= AccessTree.header, Array(bytes[0..<4]) == AccessTree.magic, u16(4) == 1, u16(6) == 0
    else { throw .malformed }
    let count = Int(u32(8)), actionCount = Int(u32(12))
    guard count <= bytes.count / AccessTree.nodeSize, actionCount <= bytes.count / AccessTree.actionSize else {
      throw .malformed
    }
    let stringsAt = AccessTree.header + count * AccessTree.nodeSize + actionCount * AccessTree.actionSize
    guard stringsAt <= bytes.count else { throw .malformed }
    let area = bytes.count - stringsAt
    func string(_ at: Int) throws(AccessTreeError) -> String {
      let offset = Int(u32(at)), length = Int(u32(at + 4))
      guard offset <= area, length <= area - offset else { throw .malformed }
      let start = stringsAt + offset
      return String(decoding: bytes[start..<start + length], as: UTF8.self)
    }
    var nodes: [AccessNode] = []
    nodes.reserveCapacity(count)
    for i in 0..<count {
      let at = AccessTree.header + i * AccessTree.nodeSize
      let parent = Int32(bitPattern: u32(at + 8)), action = Int32(bitPattern: u32(at + 12))
      guard let role = Role(rawValue: bytes[at + 20]), bytes[at + 21] == 0, bytes[at + 22] == 0, bytes[at + 23] == 0,
        parent >= -1, Int(parent) < i, (i == 0) == (parent == -1), action >= -1, Int(action) < actionCount
      else { throw .malformed }
      nodes.append(AccessNode(key: u64(at), parent: parent, role: role, label: try string(at + 40),
                              value: try string(at + 48), x: Float(bitPattern: u32(at + 24)),
                              y: Float(bitPattern: u32(at + 28)), width: Float(bitPattern: u32(at + 32)),
                              height: Float(bitPattern: u32(at + 36)), states: AccessStates(rawValue: u32(at + 16)),
                              action: action))
    }
    var actions: [String] = []
    for i in 0..<actionCount {
      actions.append(try string(AccessTree.header + count * AccessTree.nodeSize + i * AccessTree.actionSize))
    }
    self.nodes = nodes
    self.actions = actions
  }
}
