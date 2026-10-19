// SPDX-License-Identifier: BSD-3-Clause

// A file's data through NodeFile (D103): messages first, the ring once a
// second full read or write shows bulk, reads ahead and in any order,
// writes behind with their failures said late, and messages for good when
// the server won't attach.

import IPC
import Node
import Sys
import Testing

/// A tree with a memory file of `bytes` (read only), a growable one of
/// up to `capacity`, and a fixed one of `fixed` bytes.
func memoryTree(_ bytes: [UInt8], capacity: Int = 8 << 20, fixed: Int = 100_000) throws -> Service {
  let s = try Service()
  let image = try VMO.create(size: Swift.max(bytes.count, 1))
  let m = try VMO.map(image, length: (Swift.max(bytes.count, 1) + 4095) & ~4095)
  m.write(bytes, at: 0)
  s.tree.memory("image", image, size: UInt64(bytes.count), executable: false)
  try s.tree.memory("out", growable: try VMO.create(size: capacity), capacity: UInt64(capacity))
  try s.tree.memory("disk", writable: try VMO.create(size: fixed), size: UInt64(fixed))
  s.tree.file("small", Array("small".utf8))
  s.start()
  return s
}

/// Everything `file` reads from 0, `size` bytes a read.
func readAll(_ file: inout NodeFile, size: Int) throws(NodeFile.Failure) -> [UInt8] {
  var out: [UInt8] = []
  while true {
    let b = try file.read(offset: UInt64(out.count), max: size)
    if b.isEmpty { return out }
    out += b
  }
}

@Test func aNodeFileGoesOnTheRingOnceItReadsBulk() throws {
  let bytes = pattern(3 << 20 | 4321)
  let s = try memoryTree(bytes)
  defer { s.end() }
  var root = try s.connect()
  var small = NodeFile(try root.open("small"))
  #expect(try small.read(offset: 0, max: NodeFile.preferredIO) == Array("small".utf8))
  let ring1 = small.onRing
  #expect(!ring1)  // a little, once: messages
  var file = NodeFile(try root.open("image"))
  #expect(try file.read(offset: 0, max: NodeFile.preferredIO).count == NodeIPC.maxIO)
  let ring2 = file.onRing
  #expect(!ring2)
  #expect(try file.read(offset: UInt64(NodeIPC.maxIO), max: NodeFile.preferredIO).count == NodeIPC.maxIO)
  let ring3 = file.onRing
  #expect(ring3)  // the second full one
  // Read ahead from there to the end, in reads of an odd size; then the
  // whole of it again, and from elsewhere.
  var rest: [UInt8] = []
  var at = 2 * NodeIPC.maxIO
  while true {
    let b = try file.read(offset: UInt64(at), max: 50_000)
    if b.isEmpty { break }
    rest += b
    at += b.count
  }
  #expect(rest == Array(bytes[(2 * NodeIPC.maxIO)...]))
  #expect(try readAll(&file, size: NodeFile.preferredIO) == bytes)
  #expect(try file.read(offset: 1_000_001, max: 10) == Array(bytes[1_000_001..<1_000_011]))
  #expect(try file.read(offset: UInt64(bytes.count), max: 10) == [])
  // Reads ahead done and not taken: finish doesn't wait for more (it did,
  // until the ring's timeout, and failed).
  _ = try file.read(offset: 0, max: 10)
  let start = Clock.monotonic()
  try file.finish()
  #expect(Clock.monotonic() - start < 1_000_000_000)
}

@Test func aNodeFileWritesBehindAndReadsWhatItWrote() throws {
  let s = try memoryTree([])
  defer { s.end() }
  var root = try s.connect()
  var out = NodeFile(try root.open("out"))
  let bytes = pattern(2 << 20 | 77, seed: 3)
  var at = 0
  while at < bytes.count {
    let n = Swift.min(NodeFile.preferredIO, bytes.count - at)
    try out.write(offset: UInt64(at), Array(bytes[at..<at + n]))
    at += n
  }
  let ring4 = out.onRing
  #expect(ring4)
  try out.finish()
  #expect(try root.stat("out", fields: NodeIPC.Fields.size).size == UInt64(bytes.count))
  // Reads on the same file see its writes, those behind first.
  try out.write(offset: 10, [9, 9, 9])
  #expect(try out.read(offset: 8, max: 6) == [bytes[8], bytes[9], 9, 9, 9, bytes[13]])
  var check = NodeFile(try root.open("out"))
  var expected = bytes
  expected.replaceSubrange(10..<13, with: [9, 9, 9])
  #expect(try readAll(&check, size: NodeFile.preferredIO) == expected)
}

@Test func aWriteBehindThatFailsIsSaidLater() throws {
  let s = try memoryTree([], fixed: 300_000)
  defer { s.end() }
  var root = try s.connect()
  var disk = NodeFile(try root.open("disk"))
  // Past its end: the writes behind go short, which the next call or
  // finish says.
  var failed: NodeError?
  do throws(NodeFile.Failure) {
    for i in 0..<8 { try disk.write(offset: UInt64(i * NodeFile.preferredIO), pattern(NodeFile.preferredIO)) }
    try disk.finish()
  } catch {
    if case .remote(let e) = error { failed = e }
  }
  let ring5 = disk.onRing
  #expect(ring5)
  #expect(failed == .io)
  // And then it goes on.
  try disk.write(offset: 0, [1, 2, 3])
  try disk.finish()
  #expect(try disk.read(offset: 0, max: 3) == [1, 2, 3])
}

@Test func aNodeFileStaysOnMessagesWhereTheServerWontAttach() throws {
  let bytes = pattern(300_000)
  let s = try memoryTree(bytes)
  defer { s.end() }
  var root = try s.connect()
  var opened = try root.open("image")
  // A ring already there: a second attach is refused.
  let other = try NodeBulkChannel(attachingTo: &opened, slots: 2, dataSize: 8192)
  var file = NodeFile(opened)
  #expect(try readAll(&file, size: NodeFile.preferredIO) == bytes)
  let ring6 = file.onRing
  #expect(!ring6)
  _ = consume other
}

/// A stream that gives a whole message's worth each read never earns a
/// ring: it has no length.
@Test func aStreamStaysOnMessages() throws {
  let s = try Service()
  s.tree.stream("feed", NodeStream(take: { max in [UInt8](repeating: 7, count: max) }))
  s.start()
  defer { s.end() }
  var root = try s.connect()
  var feed = NodeFile(try root.open("feed"))
  for _ in 0..<4 { #expect(try feed.read(offset: 0, max: NodeFile.preferredIO).count == NodeIPC.maxIO) }
  let ring = feed.onRing
  #expect(!ring)
}

/// readAll of a file of many messages: two batches, then the rest on a
/// ring of its own; of a small one, one batch.
@Test func readAllReadsBulkThroughTheRing() throws {
  let bytes = pattern(1 << 20 | 555)
  let s = try memoryTree(bytes)
  defer { s.end() }
  var root = try s.connect()
  #expect(try root.readAll("image") == bytes)
  #expect(try root.readAll("small") == Array("small".utf8))
}

@Test func aMemoryFilesVMOIsReplacedInPlace() throws {
  let s = try Service()
  defer { s.end() }
  func vmo(_ text: String) throws -> Handle {
    let v = try VMO.create(size: text.utf8.count)
    let m = try VMO.map(v, length: 4096)
    m.write(Array(text.utf8), at: 0)
    return v
  }
  let node = s.tree.memory("resolved", try vmo("first"), size: 5, executable: false)
  s.start()
  var root = try s.connect()
  var file = try root.open("resolved")
  let before = try file.memory(executable: false)
  s.tree.setMemory(node, try vmo("second"), size: 6)
  #expect(try root.readAll("resolved") == Array("second".utf8))
  // The old one, mapped, is as it was.
  let m = try VMO.map(before.vmo, length: 4096, writable: false)
  #expect((0..<5).map { m.load(UInt8.self, at: $0) } == Array("first".utf8))
}
