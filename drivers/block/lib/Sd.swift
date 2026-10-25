// SPDX-License-Identifier: BSD-3-Clause

// The block class (D82, D106): a disk as Plan 9's sd(3) directory for one
// unit, which a block driver (or ramdisk(4)) serves from a Disk, its
// requests:
//
//     ctl      inquiry, geometry, alignment, a `part NAME START END` line
//              for each partition (data first); takes `flush`
//     data     the whole disk
//     NAME     each GPT partition, by its name
//
// Reads may be at any offset (the sectors around them read and cut);
// writes are whole sectors, cut short at the partition's end. Each file
// serves Node's attach (NodeRing): a ring entry is a disk request, started
// on the dispatcher's thread and answered when the disk says, in any
// order. A message's read or write waits on the dispatcher's thread. A
// flush makes durable what was written and answered before it.

import IPC
import Node
import Sys
import Synchronization

public enum SdOp: Sendable { case read, write }

/// A request's bytes: a part of a ring's data area or of a buffer, valid
/// until the request's `done`, and the disk's alone until then.
@safe public struct SectorBuffer: @unchecked Sendable {
  public let bytes: UnsafeMutableRawBufferPointer
  @unsafe public init(_ bytes: UnsafeMutableRawBufferPointer) { unsafe self.bytes = bytes }
  public var count: Int { unsafe bytes.count }
}

/// A disk, as a driver gives it: its sectors, and requests that end when
/// `done` is called, from any thread.
public protocol Disk: AnyObject, Sendable {
  /// What ctl's `inquiry` says.
  var name: String { get }
  var sectors: UInt64 { get }
  var sectorSize: Int { get }
  var readOnly: Bool { get }
  /// Reads or writes `data.count / sectorSize` sectors from `sector`.
  func start(_ op: SdOp, sector: UInt64, _ data: SectorBuffer, done: @escaping @Sendable (NodeIPC.NodeError?) -> Void)
  /// Calls `done` once everything written and answered before it is
  /// durable (at once, with no cache to flush).
  func flush(done: @escaping @Sendable (NodeIPC.NodeError?) -> Void)
}

/// A partition: its name and sectors, `end` excluded.
public struct SdPartition: Equatable, Sendable {
  public var name: String
  public var start: UInt64
  public var end: UInt64
  public init(name: String, start: UInt64, end: UInt64) {
    self.name = name
    self.start = start
    self.end = end
  }
}

/// A disk in memory, a VMO mapped: each request done on the spot, with
/// nothing to flush. ramdisk(4)'s, and tests'.
public final class MemoryDisk: Disk, @unchecked Sendable {
  public let name: String
  public let sectors: UInt64
  public let sectorSize: Int
  public let readOnly = false
  let mapping: Mapping

  public init(name: String, _ vmo: consuming Handle, sectors: UInt64, sectorSize: Int) throws(Status) {
    self.name = name
    self.sectors = sectors
    self.sectorSize = sectorSize
    mapping = try VMO.map(vmo, length: Int(sectors) * sectorSize)
  }

  public func start(_ op: SdOp, sector: UInt64, _ data: SectorBuffer,
                    done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    let count = UInt64(data.count / sectorSize)
    guard data.count % sectorSize == 0, sector <= sectors, count <= sectors - sector else { return done(.invalid) }
    let at = unsafe mapping.address + Int(sector) * sectorSize
    if op == .read {
      unsafe data.bytes.baseAddress!.copyMemory(from: at, byteCount: data.count)
    } else {
      unsafe at.copyMemory(from: data.bytes.baseAddress!, byteCount: data.count)
    }
    done(nil)
  }

  public func flush(done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) { done(nil) }
}

/// Waits for one request: the dispatcher's way to do a message's read,
/// write or flush.
final class Waiter: @unchecked Sendable {
  let word = Atomic<UInt32>(0)
  var failure: NodeIPC.NodeError?

  func finish(_ e: NodeIPC.NodeError?) {
    failure = e
    word.store(1, ordering: .releasing)
    unsafe Futex.wake(address, count: 1)
  }

  func wait() -> NodeIPC.NodeError? {
    while word.load(ordering: .acquiring) == 0 { try? unsafe Futex.wait(address, current: 0) }
    return failure
  }

  var address: UnsafeMutablePointer<UInt32> {
    unsafe withUnsafePointer(to: word) { unsafe UnsafeMutablePointer(mutating: UnsafeRawPointer($0).assumingMemoryBound(to: UInt32.self)) }
  }
}

public final class SdUnit: @unchecked Sendable {
  public let disk: Disk
  public let partitions: [SdPartition]
  let dispatcher: IPCDispatcher

  /// The unit over `disk`, its partitions read from its GPT, served on
  /// `dispatcher`: one of its own, if a NodeTree mounts it, since a tree
  /// waits on its dispatcher's thread for a mount's answers.
  public init(_ disk: Disk, dispatcher: IPCDispatcher) {
    self.disk = disk
    self.dispatcher = dispatcher
    partitions = [SdPartition(name: "data", start: 0, end: disk.sectors)] + GPT.partitions(disk)
  }

  /// A channel to the unit's directory, to mount.
  public func channel() throws(Status) -> Handle { try channel(at: 0) }

  func channel(at node: Int) throws(Status) -> Handle {
    let ends = try Channel.create()
    try dispatcher.add(NodeIPC.NodeServer(channel: ends.b, impl: SdSession(unit: self, node: node, end: SdEnd())))
    return ends.a
  }

  /// ctl's text.
  public var control: String {
    var text = "inquiry \(disk.name)\ngeometry \(disk.sectors) \(disk.sectorSize)\nalignment \(disk.sectorSize) 0\n"
    for p in partitions { text += "part \(p.name) \(p.start) \(p.end)\n" }
    return text
  }

  /// Runs one request and waits for it.
  func wait(_ body: (@escaping @Sendable (NodeIPC.NodeError?) -> Void) -> Void) -> NodeIPC.NodeError? {
    let w = Waiter()
    body { w.finish($0) }
    return w.wait()
  }

  /// Reads up to `max` bytes of partition `p` from `offset`.
  func read(_ p: SdPartition, offset: UInt64, max: Int) throws(NodeIPC.NodeError) -> [UInt8] {
    let size = UInt64(disk.sectorSize)
    let length = (p.end - p.start) * size
    guard offset < length, max > 0 else { return [] }
    let n = Int(Swift.min(UInt64(max), length - offset))
    let first = offset / size, last = (offset + UInt64(n) + size - 1) / size
    var sectors = [UInt8](repeating: 0, count: Int(last - first) * disk.sectorSize)
    let failure = unsafe sectors.withUnsafeMutableBytes { b in
      unsafe wait { done in disk.start(.read, sector: p.start + first, unsafe SectorBuffer(b), done: done) }
    }
    if let failure { throw failure }
    let skip = Int(offset - first * size)
    return Array(sectors[skip..<skip + n])
  }

  /// Writes whole sectors of partition `p` from `offset`, cut short at
  /// its end: the bytes written.
  func write(_ p: SdPartition, offset: UInt64, _ data: [UInt8]) throws(NodeIPC.NodeError) -> UInt32 {
    let size = UInt64(disk.sectorSize)
    guard !disk.readOnly else { throw .denied }
    guard offset % size == 0, UInt64(data.count) % size == 0 else { throw .invalid }
    let length = (p.end - p.start) * size
    guard offset < length, !data.isEmpty else { return 0 }
    var bytes = Array(data.prefix(Int(Swift.min(UInt64(data.count), length - offset))))
    let failure = unsafe bytes.withUnsafeMutableBytes { b in
      unsafe wait { done in disk.start(.write, sector: p.start + offset / size, unsafe SectorBuffer(b), done: done) }
    }
    if let failure { throw failure }
    return UInt32(bytes.count)
  }

  /// A ring entry on partition `p`: whole sectors straight to and from
  /// the ring's data area; a read that isn't, through sectors of its own.
  func start(_ p: SdPartition, _ op: UInt32, _ offset: UInt64, _ data: UnsafeMutableRawBufferPointer,
             _ done: @escaping @Sendable (Result<UInt32, NodeIPC.NodeError>) -> Void) {
    let size = UInt64(disk.sectorSize)
    let length = (p.end - p.start) * size
    guard offset < length, unsafe data.count > 0 else { return done(.success(0)) }
    let n = Int(Swift.min(UInt64(unsafe data.count), length - offset))
    let whole = offset % size == 0 && UInt64(n) % size == 0
    if op == NodeBulk.write {
      guard !disk.readOnly else { return done(.failure(.denied)) }
      guard whole else { return done(.failure(.invalid)) }
      let part = unsafe UnsafeMutableRawBufferPointer(rebasing: data[0..<n])
      disk.start(.write, sector: p.start + offset / size, unsafe SectorBuffer(part)) { e in
        done(e.map { .failure($0) } ?? .success(UInt32(n)))
      }
    } else if whole {
      let part = unsafe UnsafeMutableRawBufferPointer(rebasing: data[0..<n])
      disk.start(.read, sector: p.start + offset / size, unsafe SectorBuffer(part)) { e in
        done(e.map { .failure($0) } ?? .success(UInt32(n)))
      }
    } else {
      // Not on sectors: the dispatcher's thread reads them and cuts.
      do throws(NodeIPC.NodeError) {
        let bytes = try read(p, offset: offset, max: n)
        unsafe bytes.withUnsafeBytes { b in unsafe data.baseAddress!.copyMemory(from: b.baseAddress!, byteCount: b.count) }
        done(.success(UInt32(bytes.count)))
      } catch {
        done(.failure(error))
      }
    }
  }

  /// ctl's lines: `flush`.
  func command(_ text: String) throws(NodeIPC.NodeError) {
    let words = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 })
    guard words.count == 1, NodeIPC.same(String(decoding: words[0], as: UTF8.self), "flush") else { throw .invalid }
    if let failure = wait({ done in disk.flush(done: done) }) { throw failure }
  }

  /// A node's name and kind: 0 the directory, 1 ctl, then the partitions.
  func name(_ node: Int) -> String { node == 0 ? "" : node == 1 ? "ctl" : partitions[node - 2].name }

  func stat(_ node: Int) -> NodeIPC.Stat {
    let size: UInt64 = node < 2 ? 0 : (partitions[node - 2].end - partitions[node - 2].start) * UInt64(disk.sectorSize)
    return NodeIPC.Stat(qid: NodeIPC.Qid(path: UInt64(node) + 1, version: 0, kind: node == 0 ? .directory : .file),
                        name: name(node), size: size, modified: 0, attributes: [])
  }

  func child(_ name: String) -> Int? {
    if NodeIPC.same(name, "ctl") { return 1 }
    for (i, p) in partitions.enumerated() where NodeIPC.same(p.name, name) { return i + 2 }
    return nil
  }
}

/// Held only by a session's server: the ring goes with the channel.
final class SdEnd: @unchecked Sendable {
  var ring: NodeRing?
  deinit { ring?.close() }
}

struct SdSession: NodeIPC.NodeHandler {
  let unit: SdUnit
  let node: Int
  let end: SdEnd

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply {
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return failed(results, 0, .tooManyOps) }
    var at = node
    for i in ops.indices {
      do throws(NodeIPC.NodeError) {
        switch ops[i] {
        case .walk(let names):
          var qids: [NodeIPC.Qid] = []
          for name in names {
            if NodeIPC.same(name, "..") {
              at = 0
            } else {
              guard at == 0, let c = unit.child(name) else { throw .notFound }
              at = c
            }
            qids.append(unit.stat(at).qid)
          }
          results.append(.walked(qids))
        case .stat:
          results.append(.stat(unit.stat(at)))
        case .readdir(let cursor, _, _):
          guard at == 0 else { throw .notDirectory }
          let all = 1 + unit.partitions.count
          let from = Int(Swift.min(cursor, UInt64(all)))
          let entries = (from..<all).map { unit.stat($0 + 1) }
          results.append(.dir(NodeIPC.DirBatch(entries: entries, next: UInt64(all), done: true)))
        case .read(let offset, let max):
          switch at {
          case 0: throw .isDirectory
          case 1:
            let text = Array(unit.control.utf8)
            let from = Int(Swift.min(offset, UInt64(text.count)))
            results.append(.data(Array(text[from..<Swift.min(text.count, from + Int(max))])))
          default:
            results.append(.data(try unit.read(unit.partitions[at - 2], offset: offset,
                                               max: Swift.min(Int(max), NodeIPC.maxIO))))
          }
        case .write(let offset, let data):
          switch at {
          case 0: throw .isDirectory
          case 1:
            try unit.command(String(decoding: data, as: UTF8.self))
            results.append(.wrote(UInt32(data.count)))
          default:
            guard data.count <= NodeIPC.maxIO else { throw .invalid }
            results.append(.wrote(try unit.write(unit.partitions[at - 2], offset: offset, data)))
          }
        case .watch:
          throw .unsupported
        case .create, .remove:
          throw .denied
        }
      } catch {
        return failed(results, i, error)
      }
    }
    guard open else { return NodeIPC.Reply(results: results, failure: nil, node: nil) }
    do throws(Status) {
      return NodeIPC.Reply(results: results, failure: nil, node: try unit.channel(at: at))
    } catch {
      return failed(results, ops.count, .io)
    }
  }

  func failed(_ results: [NodeIPC.Outcome], _ index: Int, _ error: NodeIPC.NodeError) -> NodeIPC.Reply {
    NodeIPC.Reply(results: results, failure: NodeIPC.Failure(index: UInt32(index), code: error.rawValue), node: nil)
  }

  mutating func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeIPC.NodeError) {
    guard node >= 2 else { throw .unsupported }
    guard end.ring == nil else { throw .exists }
    let unit = self.unit, partition = unit.partitions[node - 2]
    end.ring = unsafe try NodeRing(bulk, dispatcher: unit.dispatcher) { op, offset, data, done in
      unsafe unit.start(partition, op, offset, data, done)
    }
  }

  func memory(executable: Bool) throws(NodeIPC.NodeError) -> NodeIPC.Memory { throw .unsupported }

  func wstat(_ change: NodeIPC.Wstat) throws(NodeIPC.NodeError) { throw .denied }
}

// MARK: GPT

/// A disk's GUID partition table (UEFI 2.10 §5.3): the header at sector 1
/// and its entries, each named by its UTF-16 name. A name sd can't hold,
/// or none, is `partN` (its entry's number); a second of one name, and
/// `data` and `ctl`, get the entry's number after them. A header or table
/// whose CRC is wrong is no table.
public enum GPT {
  public static func partitions(_ disk: Disk) -> [SdPartition] {
    let size = disk.sectorSize
    guard disk.sectors > 2, var header = read(disk, sector: 1, count: 1),
      header.count >= 92, Array(header[0..<8]) == Array("EFI PART".utf8)
    else { return [] }
    let headerSize = Int(le(header, 12, 4)), headerCRC = UInt32(le(header, 16, 4))
    guard headerSize >= 92, headerSize <= header.count else { return [] }
    header.replaceSubrange(16..<20, with: [0, 0, 0, 0])
    guard crc32(header[0..<headerSize]) == headerCRC else { return [] }
    let entriesAt = le(header, 72, 8), count = Int(le(header, 80, 4)), entrySize = Int(le(header, 84, 4))
    guard entrySize >= 128, count > 0, count <= 1024, entriesAt > 1, entriesAt < disk.sectors else { return [] }
    let sectors = (count * entrySize + size - 1) / size
    guard let table = read(disk, sector: entriesAt, count: sectors),
      crc32(table[0..<(count * entrySize)]) == UInt32(le(header, 88, 4))
    else { return [] }
    var out: [SdPartition] = []
    for i in 0..<count {
      let e = Array(table[(i * entrySize)..<(i * entrySize + 128)])
      guard e[0..<16].contains(where: { $0 != 0 }) else { continue }  // unused
      let first = le(e, 32, 8), last = le(e, 40, 8)
      guard first <= last, last < disk.sectors else { continue }
      var units: [UInt16] = []
      for j in 0..<36 {
        let u = UInt16(e[56 + 2 * j]) | UInt16(e[57 + 2 * j]) << 8
        if u == 0 { break }
        units.append(u)
      }
      var name = String(decoding: units, as: UTF16.self)
      let taken = NodeIPC.same(name, "data") || NodeIPC.same(name, "ctl")
        || out.contains { NodeIPC.same($0.name, name) }
      if !NodeIPC.isValidName(name) || NodeIPC.same(name, "..") { name = "part\(i + 1)" }
      else if taken { name += "\(i + 1)" }
      out.append(SdPartition(name: name, start: first, end: last + 1))
    }
    return out
  }

  static func read(_ disk: Disk, sector: UInt64, count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count * disk.sectorSize)
    let w = Waiter()
    unsafe bytes.withUnsafeMutableBytes { b in
      disk.start(.read, sector: sector, unsafe SectorBuffer(b)) { w.finish($0) }
      _ = w.wait()
    }
    return w.failure == nil ? bytes : nil
  }

  /// A little-endian number of `width` bytes at `at`.
  static func le(_ b: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in (0..<width).reversed() { v = v << 8 | UInt64(b[at + i]) }
    return v
  }

  /// CRC-32 (IEEE 802.3, reflected), as GPT's checksums are.
  static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes {
      crc ^= UInt32(b)
      for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
  }
}
