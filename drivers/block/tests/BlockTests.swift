// SPDX-License-Identifier: BSD-3-Clause

// The block class (D106) over a disk in memory that records its requests
// and, when asked, answers them later and newest first: ctl's lines, a
// GPT's partitions as files and their bounds, reads at any offset and
// writes only of whole sectors, ring entries answered out of order, a
// flush that starts only once the writes before it are done, and Taisce's
// writes and barriers reaching the disk as its crash harness models them.

import Foundation
import FsServer
import IPC
import Node
import Sd
import Sys
import Taisce
import Testing

/// A disk in memory of 512-byte sectors that logs each write as it ends
/// (`write SECTOR COUNT`) and each flush as it starts. `later`: requests
/// are answered on a thread of its own, newest first.
final class RecordedDisk: Disk, @unchecked Sendable {
  let name = "test0"
  let sectors: UInt64
  let sectorSize = 512
  let readOnly = false
  let storage: Locked<[UInt8]>
  let log = Locked<[String]>([])
  let held = Locked<[() -> Void]>([])
  let inFlight = Locked(0)
  let flushedEarly = Locked(false)
  let stopped = Locked(false)
  let later: Bool

  init(sectors: UInt64, later: Bool = false) {
    self.sectors = sectors
    self.later = later
    storage = Locked([UInt8](repeating: 0, count: Int(sectors) * 512))
    if later {
      let held = self.held, stopped = self.stopped
      Thread.detachNewThread {
        while !stopped.withLock({ $0 }) {
          if let next = held.withLock({ $0.popLast() }) { next() } else { usleep(100) }
        }
      }
    }
  }

  deinit { stopped.withLock { $0 = true } }

  func start(_ op: SdOp, sector: UInt64, _ data: SectorBuffer, done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    let count = data.count / sectorSize
    guard data.count % sectorSize == 0, sector + UInt64(count) <= sectors else { return done(.invalid) }
    inFlight.withLock { $0 += 1 }
    let work = { [self] in
      let at = Int(sector) * sectorSize
      storage.withLock { s in
        s.withUnsafeMutableBytes { b in
          if op == .read {
            data.bytes.baseAddress!.copyMemory(from: b.baseAddress! + at, byteCount: data.count)
          } else {
            (b.baseAddress! + at).copyMemory(from: data.bytes.baseAddress!, byteCount: data.count)
          }
        }
      }
      if op == .write { log.withLock { $0.append("write \(sector) \(count)") } }
      inFlight.withLock { $0 -= 1 }
      done(nil)
    }
    if stopped.withLock({ $0 }) || !later { work() } else { held.withLock { $0.append(work) } }
  }

  func flush(done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    if inFlight.withLock({ $0 }) != 0 { flushedEarly.withLock { $0 = true } }
    log.withLock { $0.append("flush") }
    done(nil)
  }

  func bytes(_ sector: UInt64, _ count: Int) -> [UInt8] {
    storage.withLock { Array($0[(Int(sector) * 512)..<(Int(sector) * 512 + count)]) }
  }
}

/// A unit over `disk`, on a dispatcher of its own.
final class Served: @unchecked Sendable {
  let unit: SdUnit
  let dispatcher: IPCDispatcher

  init(_ disk: Disk) throws {
    dispatcher = try IPCDispatcher()
    unit = SdUnit(disk, dispatcher: dispatcher)
    let d = dispatcher
    _ = try Sys.Thread.spawn { try? d.run() }.release()
  }

  func open(_ name: String) throws -> NodeIPC.NodeClient {
    var dir = NodeIPC.NodeClient(channel: try unit.channel())
    return try dir.open(name)
  }

  func names() throws -> [String] {
    let ns = Namespace()
    try ns.mount(try unit.channel(), at: "/sd")
    return try ns.list("/sd").map(\.name)
  }

  deinit { dispatcher.stop() }
}

/// A GPT on `disk`'s storage: a header at sector 1 and 128 entries from
/// sector 2, each (name, first, last).
func writeGPT(_ disk: RecordedDisk, _ parts: [(String, UInt64, UInt64)]) {
  var header = [UInt8](repeating: 0, count: 512)
  header.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
  func put(_ b: inout [UInt8], _ at: Int, _ v: UInt64, _ width: Int) {
    for i in 0..<width { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
  }
  put(&header, 8, 0x0001_0000, 4)
  put(&header, 12, 92, 4)
  put(&header, 72, 2, 8)
  put(&header, 80, 128, 4)
  put(&header, 84, 128, 4)
  var table = [UInt8](repeating: 0, count: 128 * 128)
  for (i, p) in parts.enumerated() {
    let e = i * 128
    table[e] = 0xAF  // a type: anything not zero
    put(&table, e + 32, p.1, 8)
    put(&table, e + 40, p.2, 8)
    for (j, u) in p.0.utf16.enumerated() { put(&table, e + 56 + 2 * j, UInt64(u), 2) }
  }
  disk.storage.withLock { s in
    s.replaceSubrange(512..<1024, with: header)
    s.replaceSubrange(1024..<(1024 + table.count), with: table)
  }
}

@Test func aBlankDiskIsItsCtlAndData() throws {
  let s = try Served(RecordedDisk(sectors: 2048))
  #expect(try s.names() == ["ctl", "data"])
  var ctl = try s.open("ctl")
  #expect(try ctl.readText() == "inquiry test0\ngeometry 2048 512\nalignment 512 0\npart data 0 2048\n")
  var data = try s.open("data")
  #expect(try data.stat(fields: NodeIPC.Fields.size).size == 2048 * 512)
}

@Test func aGPTsPartitionsAreFilesWithinTheirBounds() throws {
  let disk = RecordedDisk(sectors: 4096)
  writeGPT(disk, [("esp", 34, 99), ("taisce", 100, 1099), ("data", 1100, 1199), ("", 1200, 1299)])
  let s = try Served(disk)
  #expect(try s.names() == ["ctl", "data", "esp", "taisce", "data3", "part4"])
  var ctl = try s.open("ctl")
  #expect(try ctl.readText() == """
    inquiry test0
    geometry 4096 512
    alignment 512 0
    part data 0 4096
    part esp 34 100
    part taisce 100 1100
    part data3 1100 1200
    part part4 1200 1300

    """)
  var taisce = try s.open("taisce")
  #expect(try taisce.stat(fields: NodeIPC.Fields.size).size == 1000 * 512)
  let block = [UInt8](repeating: 7, count: 1024)
  #expect(try taisce.write(offset: 0, block) == 1024)
  #expect(disk.bytes(100, 1024) == block)
  // A write that runs past the partition's end is cut short there.
  #expect(try taisce.write(offset: 999 * 512, block) == 512)
  #expect(disk.bytes(1100, 512) == [UInt8](repeating: 0, count: 512))
  #expect(try taisce.write(offset: 1000 * 512, block) == 0)
}

@Test func readsMayBeAtAnyOffsetAndWritesAreWholeSectors() throws {
  let disk = RecordedDisk(sectors: 64)
  disk.storage.withLock { s in for i in s.indices { s[i] = UInt8(truncatingIfNeeded: i &* 7) } }
  let s = try Served(disk)
  var data = try s.open("data")
  #expect(try data.read(offset: 700, max: 1000) == disk.bytes(0, 1700).suffix(1000).map { $0 })
  #expect(try data.read(offset: 64 * 512 - 10, max: 100).count == 10)
  #expect(throws: (any Error).self) { try data.write(offset: 3, [UInt8](repeating: 1, count: 512)) }
  #expect(throws: (any Error).self) { try data.write(offset: 512, [UInt8](repeating: 1, count: 100)) }
  // ctl takes `flush`, and nothing else.
  var ctl = try s.open("ctl")
  #expect(try ctl.write(offset: 0, Array("flush".utf8)) == 5)
  #expect(throws: (any Error).self) { try ctl.write(offset: 0, Array("part x 1 2".utf8)) }
}

@Test func ringEntriesAreAnsweredInAnyOrder() throws {
  let disk = RecordedDisk(sectors: 16384, later: true)
  writeGPT(disk, [("taisce", 4096, 12287)])
  let s = try Served(disk)
  let bytes = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 >> 9) }
  var out = NodeFile(try s.open("taisce"))
  var at = 0
  while at < bytes.count {
    let n = Swift.min(NodeFile.preferredIO, bytes.count - at)
    try out.write(offset: UInt64(at), Array(bytes[at..<at + n]))
    at += n
  }
  try out.finish()
  let onRing = out.onRing
  #expect(onRing)
  #expect(disk.bytes(4096, bytes.count) == bytes)
  // Some writes ended before ones started ahead of them.
  let sectors = disk.log.withLock { $0 }.compactMap { line -> UInt64? in
    let w = line.split(separator: " ")
    return w.first == "write" ? UInt64(w[1]) : nil
  }
  #expect(sectors != sectors.sorted())
  var back = NodeFile(try s.open("taisce"))
  var read: [UInt8] = []
  while read.count < bytes.count {
    let b = try back.read(offset: UInt64(read.count), max: NodeFile.preferredIO)
    if b.isEmpty { break }
    read += b
  }
  #expect(Array(read.prefix(bytes.count)) == bytes)  // the partition goes on past them
}

@Test func aFlushStartsOnlyOnceTheWritesBeforeItAreDone() throws {
  let disk = RecordedDisk(sectors: 8192, later: true)
  let s = try Served(disk)
  var device = try NodeDevice(try s.open("data").takeChannel(), ctl: try s.open("ctl").takeChannel())
  for i in 0..<20 { try device.write(UInt64(i * 16), [UInt8](repeating: UInt8(i), count: 16 * 4096)) }
  try device.flush()
  let early = disk.flushedEarly.withLock { $0 }
  #expect(!early)
  let log = disk.log.withLock { $0 }
  #expect(log.last == "flush")
  #expect(log.filter { $0.hasPrefix("write") }.count >= 20)
}

/// Taisce's writes and barriers, from a workload of groups and an fsync,
/// in the order the crash harness records them (RecordingDevice), block
/// by block: what the harness proves is what the disk is given.
@Test func taisceReachesTheDiskAsItsCrashHarnessModels() throws {
  func workload<D: BlockDevice>(_ fs: inout FileSystem<D>) throws {
    let dir = try fs.create(FileSystem<D>.root, Array("d".utf8), .directory, mode: 0o755, now: 2)
    for i in 0..<6 {
      let f = try fs.create(dir, Array("f\(i)".utf8), .file, mode: 0o644, now: 3)
      try fs.write(f, offset: 0, [UInt8](repeating: UInt8(i), count: 40_000 + i * 9000), now: 4)
      if i % 2 == 1 { try fs.sync() }
      if i == 4 { try fs.fsync() }
    }
    try fs.sync()
  }
  // Straight onto a recording device.
  var direct = try FileSystem.format(RecordingDevice(MemoryDevice(blocks: 1024)), label: Array("t".utf8),
                                     uuid: Array(1...16), now: 1)
  try workload(&direct)
  var expected: [String] = []
  for op in direct.engine.store.volume.device.log {
    switch op {
    case .write(let block, let bytes): for b in 0..<UInt64(bytes.count / 4096) { expected.append("\(block + b)") }
    case .flush: expected.append("flush")
    }
  }
  // Through fs(4)'s device and the block class, onto a disk of 512-byte
  // sectors.
  let disk = RecordedDisk(sectors: 1024 * 8)
  let s = try Served(disk)
  let device = try NodeDevice(try s.open("data").takeChannel(), ctl: try s.open("ctl").takeChannel())
  var through = try FileSystem.format(device, label: Array("t".utf8), uuid: Array(1...16), now: 1)
  try workload(&through)
  var seen: [String] = []
  for line in disk.log.withLock({ $0 }) {
    let w = line.split(separator: " ")
    if w.first == "flush" { seen.append("flush"); continue }
    let sector = UInt64(w[1])!, count = UInt64(w[2])!
    for b in 0..<(count / 8) { seen.append("\(sector / 8 + b)") }
  }
  #expect(seen == expected)
  #expect(disk.bytes(0, 1024 * 4096) == direct.engine.store.volume.device.base.storage)
}

/// A unit mounted in a service's tree, as ramdisk(4) serves it, opens and
/// walks through the tree: the launcher mounts `ramdisk/sdZ0`.
@Test func aUnitMountedInATreeOpensThroughIt() throws {
  // The unit on a dispatcher of its own: the tree waits on its own
  // thread for the mounted channel's answers.
  let s = try Served(RecordedDisk(sectors: 64))
  let dispatcher = try IPCDispatcher()
  let tree = NodeTree(dispatcher: dispatcher)
  _ = tree.mount("sdZ0", try s.unit.channel())
  let d = dispatcher
  _ = try Sys.Thread.spawn { try? d.run() }.release()
  defer { dispatcher.stop() }
  let ends = try Channel.create()
  try tree.serve(ends.b)
  var root = NodeIPC.NodeClient(channel: ends.a)
  var sd = try root.open("sdZ0")
  #expect(try sd.stat(fields: 0).qid.kind == .directory)
  var ctl = try root.open("sdZ0/ctl")
  #expect(try ctl.readText().hasPrefix("inquiry test0\n"))
  var data = try sd.open("data")
  #expect(try data.read(offset: 0, max: 16) == [UInt8](repeating: 0, count: 16))
}
