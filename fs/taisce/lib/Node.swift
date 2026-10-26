// SPDX-License-Identifier: BSD-3-Clause

/// A B+tree node: its page, 16 KiB, the same bytes in memory as on disk,
/// read and changed in place (as LMDB's, SQLite's and btrfs's pages are),
/// never decoded into arrays: a node an array of arrays cost a reference
/// count for each key and value it handed out (D127). Leaves hold keys
/// and values; an internal node holds `count + 1` children, where every
/// key in child `i + 1` is at least key `i` and every key in child `i` is
/// below it.
///
/// The page: a 48-byte header (magic u32, level u16, count u16, the cell
/// area's start u16, its dead bytes u16, 4 zero, then an internal node's
/// first child pointer), then the slots, one u16 offset a cell in key
/// order, then free space, then the cells, packed down from the end. A
/// leaf cell is key length (u16), value length (u16), key, value; an
/// internal cell is key length, key, and the pointer to the child on its
/// right (32 bytes: block, BLAKE3-128, birth txg). Inserting or removing
/// moves slots, not cells; a removed cell's bytes are dead until a cell
/// doesn't fit the free space and the cells are packed again (SQLite's
/// way). A page read from the device is checked whole before use (btrfs
/// learned to with its tree checker), so lookups trust its offsets.
public struct Node: Equatable, Sendable {
  /// The node as stored. Its count is the node's capacity: `bytes`, but
  /// twice that while an insert that overfills it is split.
  public private(set) var page: [UInt8]

  public static let bytes = Layout.blockSize * Layout.nodeBlocks
  static let magic: UInt32 = 0x646F_4E54  // "TNod"
  static let headerSize = 48
  static let firstChildAt = 16
  static let maxLevel: UInt16 = 32

  /// An empty node of `level`.
  public init(level: UInt16, capacity: Int = Node.bytes) {
    page = [UInt8](repeating: 0, count: capacity)
    page.put(Self.magic, at: 0)
    page.put(level, at: 4)
    cellStart = capacity
  }

  /// The node a page read from the device holds, checked: every offset
  /// and length inside the page, and its cells and dead bytes filling
  /// the cell area exactly.
  public init(page: [UInt8]) throws(TaisceError) {
    self.page = page
    guard page.count == Self.bytes, page.get(UInt32.self, at: 0) == Self.magic, level <= Self.maxLevel,
      Self.headerSize + 2 * count <= cellStart, cellStart <= page.count, garbage <= page.count - cellStart
    else { throw .corrupt(.node) }
    var live = 0
    for i in 0..<count {
      let o = slot(i)
      guard o >= cellStart, o + 4 <= page.count else { throw .corrupt(.node) }
      let k = Int(page.get(UInt16.self, at: o))
      guard k <= BTree.maxKey else { throw .corrupt(.node) }
      if isLeaf {
        let v = Int(page.get(UInt16.self, at: o + 2))
        guard v <= BTree.maxValue, o + 4 + k + v <= page.count else { throw .corrupt(.node) }
      } else {
        guard o + 2 + k + NodePointer.size <= page.count else { throw .corrupt(.node) }
      }
      live += cellSize(i)
    }
    guard live + garbage == page.count - cellStart else { throw .corrupt(.node) }
  }

  @inline(__always)
  public var level: UInt16 { page.get(UInt16.self, at: 4) }
  @inline(__always)
  public var isLeaf: Bool { level == 0 }
  /// Keys: a leaf's entries, an internal node's children less one.
  @inline(__always)
  public var count: Int {
    get { Int(page.get(UInt16.self, at: 6)) }
    set { page.put(UInt16(newValue), at: 6) }
  }
  var cellStart: Int {
    get { Int(page.get(UInt16.self, at: 8)) }
    set { page.put(UInt16(newValue), at: 8) }
  }
  /// Bytes of removed cells, below `cellStart`'s end and not yet reused.
  var garbage: Int {
    get { Int(page.get(UInt16.self, at: 10)) }
    set { page.put(UInt16(newValue), at: 10) }
  }

  /// Bytes in use: the header, the slots and the live cells.
  public var used: Int { Self.headerSize + 2 * count + (page.count - cellStart - garbage) }

  @inline(__always)
  func slot(_ i: Int) -> Int { Int(page.get(UInt16.self, at: Self.headerSize + 2 * i)) }

  /// Bytes of a leaf cell, or an internal one, and their slot.
  static func leafCell(_ key: Int, _ value: Int) -> Int { 4 + key + value }
  static func internalCell(_ key: Int) -> Int { 2 + key + NodePointer.size }

  @inline(__always)
  func cellSize(_ i: Int) -> Int {
    let o = slot(i)
    let k = Int(page.get(UInt16.self, at: o))
    return isLeaf ? Self.leafCell(k, Int(page.get(UInt16.self, at: o + 2))) : Self.internalCell(k)
  }

  // MARK: Reading

  @inline(__always)
  public func keyRange(_ i: Int) -> Range<Int> {
    let o = slot(i), at = o + (isLeaf ? 4 : 2)
    return at..<(at + Int(page.get(UInt16.self, at: o)))
  }

  /// A leaf's value `i`.
  @inline(__always)
  public func valueRange(_ i: Int) -> Range<Int> {
    let o = slot(i), at = o + 4 + Int(page.get(UInt16.self, at: o))
    return at..<(at + Int(page.get(UInt16.self, at: o + 2)))
  }

  public func key(_ i: Int) -> [UInt8] { Array(page[keyRange(i)]) }
  public func value(_ i: Int) -> [UInt8] { Array(page[valueRange(i)]) }

  /// Key `i` and (a leaf's) value `i` as spans of the page.
  func withEntry<R, E: Error>(_ i: Int, _ body: (Span<UInt8>, Span<UInt8>) throws(E) -> R) throws(E) -> R {
    let s = page.span
    return try body(s.extracting(keyRange(i)), s.extracting(valueRange(i)))
  }

  /// An internal node's child `i`.
  public func child(_ i: Int) -> NodePointer {
    NodePointer.get(page, at: i == 0 ? Self.firstChildAt : keyRange(i - 1).upperBound)
  }

  public var children: [NodePointer] { isLeaf ? [] : (0...count).map { child($0) } }

  /// Key `i` against `key`: below zero if it sorts first, zero if equal,
  /// a prefix first. Read straight from the page, which `init(page:)`
  /// checked, 8 bytes at a time while they last (FSKey's keys share
  /// their node's 8 bytes and more).
  func compare(_ i: Int, _ key: [UInt8]) -> Int {
    precondition(i < count)
    return unsafe page.withUnsafeBytes { p in
      unsafe key.withUnsafeBytes { b in
        let o = Int(UInt16(littleEndian: unsafe p.loadUnaligned(fromByteOffset: Self.headerSize + 2 * i, as: UInt16.self)))
        let length = Int(UInt16(littleEndian: unsafe p.loadUnaligned(fromByteOffset: o, as: UInt16.self)))
        let at = o + (unsafe p[4] | p[5] == 0 ? 4 : 2)  // a leaf's cell has the value's length too
        let n = Swift.min(length, b.count)
        var j = 0
        while j + 8 <= n {
          let x = UInt64(bigEndian: unsafe p.loadUnaligned(fromByteOffset: at + j, as: UInt64.self))
          let y = UInt64(bigEndian: unsafe b.loadUnaligned(fromByteOffset: j, as: UInt64.self))
          if x != y { return x < y ? -1 : 1 }
          j += 8
        }
        while j < n {
          let x = unsafe p[at + j], y = unsafe b[j]
          if x != y { return x < y ? -1 : 1 }
          j += 1
        }
        return length - b.count
      }
    }
  }

  /// The first index whose key is at least `key` (binary search).
  func lowerBound(_ key: [UInt8]) -> Int {
    var lo = 0, hi = count
    while lo < hi {
      let mid = (lo + hi) / 2
      if compare(mid, key) < 0 { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  /// The number of keys at most `key`: in an internal node, the child
  /// that covers it.
  func childIndex(_ key: [UInt8]) -> Int {
    var lo = 0, hi = count
    while lo < hi {
      let mid = (lo + hi) / 2
      if compare(mid, key) > 0 { hi = mid } else { lo = mid + 1 }
    }
    return lo
  }

  // MARK: Changing

  /// Room for a cell of `size` and its slot at `i`, packing the cells
  /// first if the free space is in pieces: the cell's offset, or nil if
  /// the node hasn't the room.
  mutating func makeRoom(_ size: Int, at i: Int) -> Int? {
    let gap = cellStart - Self.headerSize - 2 * count
    guard size + 2 <= gap + garbage else { return nil }
    if size + 2 > gap { pack() }
    let o = cellStart - size
    cellStart = o
    let s = Self.headerSize + 2 * i, end = Self.headerSize + 2 * count
    if s < end { moveBytes(from: s, to: s + 2, count: end - s) }
    page.put(UInt16(o), at: s)
    count += 1
    return o
  }

  /// Inserts a leaf entry at `i`; false if it doesn't fit.
  mutating func insert(at i: Int, _ key: [UInt8], _ value: [UInt8]) -> Bool {
    guard let o = makeRoom(Self.leafCell(key.count, value.count), at: i) else { return false }
    page.put(UInt16(key.count), at: o)
    page.put(UInt16(value.count), at: o + 2)
    putBytes(key, at: o + 4)
    putBytes(value, at: o + 4 + key.count)
    return true
  }

  /// Inserts key `i` of an internal node, `right` the child after it;
  /// false if it doesn't fit.
  mutating func insert(at i: Int, _ key: [UInt8], right: NodePointer) -> Bool {
    guard let o = makeRoom(Self.internalCell(key.count), at: i) else { return false }
    page.put(UInt16(key.count), at: o)
    putBytes(key, at: o + 2)
    right.put(into: &page, at: o + 2 + key.count)
    return true
  }

  /// Removes entry `i` (an internal node's key `i` and child `i + 1`).
  mutating func remove(_ i: Int) {
    garbage += cellSize(i)
    if slot(i) == cellStart {  // the lowest cell: its bytes are free at once
      garbage -= cellSize(i)
      cellStart += cellSize(i)
    }
    let s = Self.headerSize + 2 * i, end = Self.headerSize + 2 * count
    moveBytes(from: s + 2, to: s, count: end - s - 2)
    count -= 1
  }

  /// Replaces a leaf's value `i`; false if it doesn't fit.
  mutating func replaceValue(_ i: Int, _ value: [UInt8]) -> Bool {
    let r = valueRange(i)
    if r.count == value.count {
      putBytes(value, at: r.lowerBound)
      return true
    }
    let key = self.key(i)
    guard used - cellSize(i) + Self.leafCell(key.count, value.count) <= page.count else { return false }
    remove(i)
    return insert(at: i, key, value)
  }

  /// Replaces an internal node's key `i`, keeping the child after it;
  /// false if it doesn't fit.
  mutating func replaceKey(_ i: Int, _ key: [UInt8]) -> Bool {
    let right = child(i + 1)
    guard used - cellSize(i) + Self.internalCell(key.count) <= page.count else { return false }
    remove(i)
    return insert(at: i, key, right: right)
  }

  /// Sets an internal node's child `i`, in place.
  mutating func setChild(_ i: Int, _ p: NodePointer) {
    p.put(into: &page, at: i == 0 ? Self.firstChildAt : keyRange(i - 1).upperBound)
  }

  /// Appends `from`'s cell `i` as is: a node built in key order.
  mutating func append(_ from: Node, _ i: Int) {
    let size = from.cellSize(i), o = from.slot(i)
    let at = makeRoom(size, at: count)!
    unsafe page.withUnsafeMutableBytes { to in
      unsafe from.page.withUnsafeBytes { f in
        unsafe to.baseAddress!.advanced(by: at).copyMemory(from: f.baseAddress!.advanced(by: o), byteCount: size)
      }
    }
  }

  /// This node in a page of `capacity`, its cells packed.
  func copy(capacity: Int) -> Node {
    var n = Node(level: level, capacity: capacity)
    if !isLeaf { n.setChild(0, child(0)) }
    for i in 0..<count { n.append(self, i) }
    return n
  }

  /// Packs the cells against the page's end, in slot order.
  mutating func pack() {
    let old = page
    var at = page.count
    for i in 0..<count {
      let o = old.get(UInt16.self, at: Self.headerSize + 2 * i)
      let k = Int(old.get(UInt16.self, at: Int(o)))
      let size = isLeaf ? Self.leafCell(k, Int(old.get(UInt16.self, at: Int(o) + 2))) : Self.internalCell(k)
      at -= size
      unsafe page.withUnsafeMutableBytes { to in
        unsafe old.withUnsafeBytes { f in
          unsafe to.baseAddress!.advanced(by: at).copyMemory(from: f.baseAddress!.advanced(by: Int(o)), byteCount: size)
        }
      }
      page.put(UInt16(at), at: Self.headerSize + 2 * i)
    }
    cellStart = at
    garbage = 0
  }

  private mutating func putBytes(_ bytes: [UInt8], at offset: Int) {
    guard !bytes.isEmpty else { return }
    unsafe page.withUnsafeMutableBytes { to in
      unsafe bytes.withUnsafeBytes { f in unsafe to.baseAddress!.advanced(by: offset).copyMemory(from: f.baseAddress!, byteCount: f.count) }
    }
  }

  private mutating func moveBytes(from: Int, to: Int, count: Int) {
    guard count > 0 else { return }
    unsafe page.withUnsafeMutableBytes { p in
      unsafe p.baseAddress!.advanced(by: to).copyMemory(from: UnsafeRawPointer(p.baseAddress!.advanced(by: from)), byteCount: count)
    }
  }
}
