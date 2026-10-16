// SPDX-License-Identifier: BSD-3-Clause

// Bulk reads and writes on an SQ/CQ ring pair (D67): far past a batch's
// 32 KiB, many entries in flight, the end of a file, errors in their
// completions, one pair a channel, and the pair gone with its channel.

import Glibc
import IPC
import Node
import Testing

/// `count` bytes of a pattern that differs from offset to offset.
func pattern(_ count: Int, seed: UInt8 = 0) -> [UInt8] {
  (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) &+ seed }
}

@Test func bulkMovesMegabytesThroughTheRings() throws {
  let s = try standard()
  defer { s.end() }
  var root = try s.connect()
  var bulk = try NodeBulkChannel(try root.open("data/scratch"), slots: 8, dataSize: 64 * 1024)
  let bytes = pattern(3 * 1024 * 1024 + 123)
  #expect(try bulk.write(at: 0, bytes) == bytes.count)
  #expect(try bulk.read(at: 0, count: bytes.count) == bytes)
  // A batch sees what the rings wrote, and the rings what a batch wrote.
  #expect(try root.read("data/scratch", offset: 1_000_000, max: 64) == Array(bytes[1_000_000..<1_000_064]))
  try root.write("data/scratch", offset: 10, [1, 2, 3])
  #expect(try bulk.read(at: 8, count: 6) == [bytes[8], bytes[9], 1, 2, 3, bytes[13]])
}

@Test func bulkReadsStopAtTheEnd() throws {
  let s = try standard()
  defer { s.end() }
  var root = try s.connect()
  var bulk = try NodeBulkChannel(try root.open("data/hello"), slots: 4, dataSize: 16)
  #expect(try bulk.read(at: 0, count: 1000) == Array("hello, world".utf8))
  #expect(try bulk.read(at: 7, count: 3) == Array("wor".utf8))
  #expect(try bulk.read(at: 100, count: 10) == [])
  // Text leaves read too, rendered for each read.
  var status = try NodeBulkChannel(try root.open("status"), slots: 2, dataSize: 4096)
  #expect(try status.read(at: 0, count: 100) == Array("count 0\n".utf8))
}

@Test func bulkErrorsComeBackInTheirCompletions() throws {
  let s = try standard()
  defer { s.end() }
  var root = try s.connect()
  var hello = try NodeBulkChannel(try root.open("data/hello"), slots: 2, dataSize: 4096)
  var failed: NodeError?
  do throws(NodeBulkChannel.Failure) { try hello.write(at: 0, [1]) } catch {
    if case .remote(let e) = error { failed = e }
  }
  #expect(failed == .unsupported)  // read only
  #expect(try hello.read(at: 0, count: 5) == Array("hello".utf8))  // the pair goes on
  var dir: NodeError?
  let data = try root.open("data")
  do throws(NodeBulkChannel.Failure) {
    var d = try NodeBulkChannel(data)
    _ = try d.read(at: 0, count: 1)
  } catch {
    if case .remote(let e) = error { dir = e }
  }
  #expect(dir == .isDirectory)
}

@Test func attachChecksWhatItIsGiven() throws {
  let s = try standard()
  defer { s.end() }
  var root = try s.connect()
  // One pair a channel.
  var file = try root.open("data/scratch")
  let again = try file.open("")
  var bulk = try NodeBulkChannel(again, slots: 2, dataSize: 4096)
  _ = try bulk.read(at: 0, count: 1)
  func attachError(_ make: () throws -> NodeIPC.Bulk) throws -> NodeError? {
    var target = try root.open("data/scratch")
    let bulk = try make()
    do throws(Client.Failure) { try target.attach(bulk) } catch {
      if case .remote(let e) = error { return e }
    }
    return nil
  }
  // Rings that aren't there, and offsets outside the VMO.
  #expect(try attachError {
    NodeIPC.Bulk(memory: try VMO.create(size: 4096), serverBell: try Counter.create(), clientBell: try Counter.create(),
                 sqSlots: 4, cqSlots: 4, cqOffset: 2048, dataOffset: 3072, dataSize: 1024)
  } == .invalid)
  #expect(try attachError {
    NodeIPC.Bulk(memory: try VMO.create(size: 4096), serverBell: try Counter.create(), clientBell: try Counter.create(),
                 sqSlots: 3, cqSlots: 4, cqOffset: 4096, dataOffset: 8192, dataSize: 1 << 40)
  } == .invalid)
  _ = consume file
}

@Test func aPairGoesWithItsChannel() throws {
  let s = try standard()
  var root = try s.connect()
  var bulk: NodeBulkChannel? = try NodeBulkChannel(try root.open("data/scratch"), slots: 4, dataSize: 4096)
  try bulk!.write(at: 0, pattern(10_000))
  bulk = nil
  _ = consume root
  // Its channel's server and the watch of its doorbell both go.
  let deadline = Clock.monotonic() + 5_000_000_000
  while s.dispatcher.count > 0 && Clock.monotonic() < deadline { usleep(1000) }
  s.stop()
  #expect(s.dispatcher.count == 0)
}
