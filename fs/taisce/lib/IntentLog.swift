// SPDX-License-Identifier: BSD-3-Clause

/// One operation since the last commit, as the intent log keeps it (S1e):
/// the batch the engine applied, and the file blocks the file system
/// allocated for it and freed after it. Replaying operations in order on
/// the committed state rebuilds what was applied; B+tree nodes rebuild
/// themselves, so only file blocks need recording.
public struct IntentOp: Equatable, Sendable {
  public var messages: [Message]
  public var allocated: [Extent]
  public var freed: [Extent]
}

/// The intent log (filesystem.md §2, S1): fsync's fast path. Records go to
/// the intent region from its start, each a header block and its payload:
///
///     header   magic "TInt" u32, payload blocks u32, the committed txg the
///              record builds on u64, seq u64 (from 0), the next inode u64,
///              payload bytes u64, BLAKE3-128 (of the header with these 16
///              bytes zero, then the payload)
///     payload  the operations, encoded
///
/// Mount replays the records whose txg is the superblock's, in seq order,
/// stopping at the first that doesn't check out; then it commits, and the
/// new txg leaves them all behind.
enum IntentLog {
  static let magic: UInt32 = 0x746E_4954  // "TInt"
  static let checksumOffset = 48

  struct Record {
    var txg: UInt64
    var seq: UInt64
    var nextInode: UInt64
    var ops: [IntentOp]
  }

  // MARK: Encoding

  static func encode(_ r: Record) -> [UInt8] {
    var payload: [UInt8] = []
    func u8(_ v: UInt8) { payload.append(v) }
    func u32(_ v: UInt32) { for i in 0..<4 { payload.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    func u64(_ v: UInt64) { for i in 0..<8 { payload.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    func bytes(_ b: [UInt8]) {
      u32(UInt32(b.count))
      payload += b
    }
    u32(UInt32(r.ops.count))
    for op in r.ops {
      u32(UInt32(op.messages.count))
      for m in op.messages {
        switch m {
        case .insert(let tree, let key, let value):
          u8(1); u64(tree); bytes(key); bytes(value)
        case .delete(let tree, let key):
          u8(2); u64(tree); bytes(key)
        case .delta(let tree, let key, .put(let offset, let b)):
          u8(3); u64(tree); bytes(key); u32(UInt32(offset)); bytes(b)
        case .delta(let tree, let key, .add(let offset, let v)):
          u8(4); u64(tree); bytes(key); u32(UInt32(offset)); u64(v)
        }
      }
      for list in [op.allocated, op.freed] {
        u32(UInt32(list.count))
        for e in list {
          u64(e.start)
          u64(e.count)
        }
      }
    }
    let blocks = (payload.count + Layout.blockSize - 1) / Layout.blockSize
    var header = [UInt8](repeating: 0, count: Layout.blockSize)
    header.put(magic, at: 0)
    header.put(UInt32(blocks), at: 4)
    header.put(r.txg, at: 8)
    header.put(r.seq, at: 16)
    header.put(r.nextInode, at: 24)
    header.put(UInt64(payload.count), at: 32)
    payload += [UInt8](repeating: 0, count: blocks * Layout.blockSize - payload.count)
    let c = Checksum(of: header + payload)
    header.put(c.a, at: checksumOffset)
    header.put(c.b, at: checksumOffset + 8)
    return header + payload
  }

  /// The record at `block` if it's a valid one for `txg` and `seq`, and how
  /// many blocks it takes.
  static func read<D: BlockDevice>(_ device: inout D, at block: UInt64, end: UInt64, txg: UInt64, seq: UInt64)
    throws(TaisceError) -> (Record, UInt64)?
  {
    guard block < end else { return nil }
    var header = try device.read(block, count: 1)
    guard header.get(UInt32.self, at: 0) == magic, header.get(UInt64.self, at: 8) == txg,
      header.get(UInt64.self, at: 16) == seq
    else { return nil }
    let blocks = UInt64(header.get(UInt32.self, at: 4))
    let stated = header.get(UInt64.self, at: 32)  // unchecked yet: compared before it's an Int
    guard block + 1 + blocks <= end, stated <= blocks * UInt64(Layout.blockSize) else { return nil }
    let length = Int(stated)
    let payload = try device.read(block + 1, count: Int(blocks))
    let stored = Checksum(a: header.get(UInt64.self, at: checksumOffset), b: header.get(UInt64.self, at: checksumOffset + 8))
    header.put(UInt64(0), at: checksumOffset)
    header.put(UInt64(0), at: checksumOffset + 8)
    guard Checksum(of: header + payload) == stored, let ops = decode(Array(payload[..<length])) else { return nil }
    return (Record(txg: txg, seq: seq, nextInode: header.get(UInt64.self, at: 24), ops: ops), 1 + blocks)
  }

  static func decode(_ p: [UInt8]) -> [IntentOp]? {
    var at = 0
    func u8() -> UInt8? {
      guard at < p.count else { return nil }
      defer { at += 1 }
      return p[at]
    }
    func u32() -> UInt32? {
      guard at + 4 <= p.count else { return nil }
      defer { at += 4 }
      return p.get(UInt32.self, at: at)
    }
    func u64() -> UInt64? {
      guard at + 8 <= p.count else { return nil }
      defer { at += 8 }
      return p.get(UInt64.self, at: at)
    }
    func bytes() -> [UInt8]? {
      guard let n = u32().map(Int.init), at + n <= p.count else { return nil }
      defer { at += n }
      return Array(p[at..<(at + n)])
    }
    guard let opCount = u32() else { return nil }
    var ops: [IntentOp] = []
    for _ in 0..<opCount {
      guard let messageCount = u32() else { return nil }
      var messages: [Message] = []
      for _ in 0..<messageCount {
        guard let kind = u8(), let tree = u64(), let key = bytes() else { return nil }
        switch kind {
        case 1:
          guard let value = bytes() else { return nil }
          messages.append(.insert(tree: tree, key: key, value: value))
        case 2: messages.append(.delete(tree: tree, key: key))
        case 3:
          guard let offset = u32(), let b = bytes() else { return nil }
          messages.append(.delta(tree: tree, key: key, .put(offset: Int(offset), bytes: b)))
        case 4:
          guard let offset = u32(), let v = u64() else { return nil }
          messages.append(.delta(tree: tree, key: key, .add(offset: Int(offset), value: v)))
        default: return nil
        }
      }
      var lists: [[Extent]] = []
      for _ in 0..<2 {
        guard let n = u32() else { return nil }
        var list: [Extent] = []
        for _ in 0..<n {
          guard let start = u64(), let count = u64() else { return nil }
          list.append(Extent(start: start, count: count))
        }
        lists.append(list)
      }
      ops.append(IntentOp(messages: messages, allocated: lists[0], freed: lists[1]))
    }
    return ops
  }
}
