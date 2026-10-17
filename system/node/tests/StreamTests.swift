// SPDX-License-Identifier: BSD-3-Clause

// Streams (D84): a read of a stream with nothing in it waits, the server
// holding the call until the stream is ready; a read mid-batch doesn't
// wait; the stream hears its channels come and go; a reader that closes
// while held leaves nothing behind. Through the ring (D93), a read waits
// too, a write behind it is answered first, and a channel's own stream
// reads its own bytes.

import Glibc
import IPC
@testable import Node
import Synchronization
import Sys
import Testing

/// Bytes a test puts in, a stream takes out.
final class Queue: @unchecked Sendable {
  let lock = Lock()
  var bytes: [UInt8] = []
  var ended = false
  let opens = Atomic<Int>(0)
  let closes = Atomic<Int>(0)
  var written: [UInt8] = []

  func take(_ max: Int) -> [UInt8]? {
    lock.withLock {
      if bytes.isEmpty { return ended ? [] : nil }
      let n = min(max, bytes.count)
      defer { bytes.removeFirst(n) }
      return Array(bytes[..<n])
    }
  }

  var stream: NodeStream {
    NodeStream(take: { self.take($0) },
               write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
                 self.lock.withLock { self.written += data }
                 return UInt32(data.count)
               },
               opened: { self.opens.add(1, ordering: .relaxed) }, closed: { self.closes.add(1, ordering: .relaxed) })
  }
}

/// Waits until `done`, or two seconds; whether it was done.
func soon(_ done: () -> Bool) -> Bool {
  let deadline = Clock.monotonic() + 2_000_000_000
  while !done() {
    if Clock.monotonic() > deadline { return false }
    Sys.sleep(until: Clock.monotonic() + 1_000_000)
  }
  return true
}

@Test func aReadOfAnEmptyStreamWaitsUntilItIsReady() throws {
  let service = try Service()
  let q = Queue()
  let node = service.tree.stream("kbd", q.stream)
  service.start()
  defer { service.stop() }
  var root = try service.connect()
  var file = try root.open("kbd")
  #expect(soon { q.opens.load(ordering: .relaxed) == 1 })

  // Something there: the read takes it at once.
  q.lock.withLock { q.bytes = Array("ab".utf8) }
  #expect(try file.read(offset: 0, max: 64) == Array("ab".utf8))

  // Nothing: the read waits, on another thread, until the stream is ready.
  let got = Locked<[UInt8]?>(nil)
  let fileRaw = file.takeChannel().release()
  let reader = try Thread.spawn {
    var f = NodeIPC.NodeClient(channel: Handle(raw: fileRaw))
    let bytes = try? f.read(offset: 0, max: 64)
    got.withLock { $0 = bytes }
  }
  Sys.sleep(until: Clock.monotonic() + 50_000_000)
  #expect(got.withLock { $0 } == nil)  // still waiting
  q.lock.withLock { q.bytes = Array("c".utf8) }
  service.tree.ready(node)
  #expect(soon { got.withLock { $0 } == Array("c".utf8) })
  _ = try reader.wait(for: Signals.terminated, deadline: Clock.monotonic() + 2_000_000_000)

  // A read after a walk doesn't wait: what's there, maybe nothing.
  #expect(try root.read("kbd", offset: 0, max: 64) == [])
  // Writes go to the stream.
  #expect(try root.write("kbd", offset: 0, Array("xy".utf8)) == 2)
  #expect(q.lock.withLock { q.written } == Array("xy".utf8))
  // Its end reads as nothing.
  q.lock.withLock { q.ended = true }
  var again = try root.open("kbd")
  #expect(try again.read(offset: 0, max: 64) == [])
}

@Test func aHeldReaderThatClosesLeavesNothingBehind() throws {
  let service = try Service()
  let q = Queue()
  let node = service.tree.stream("cons", q.stream)
  service.start()
  defer { service.stop() }
  var root = try service.connect()
  let file = try root.open("cons")
  let raw = file.takeChannel().release()
  // Held, then the client's end closes under it.
  let reader = try Thread.spawn {
    var f = NodeIPC.NodeClient(channel: Handle(raw: raw))
    f.connection.timeout = 100_000_000
    _ = try? f.read(offset: 0, max: 8)
  }
  _ = try reader.wait(for: Signals.terminated, deadline: Clock.monotonic() + 2_000_000_000)
  #expect(soon { q.closes.load(ordering: .relaxed) == 1 })
  // The stream, ready, finds no waiter; the next reader gets the bytes.
  q.lock.withLock { q.bytes = [7] }
  service.tree.ready(node)
  var next = try root.open("cons")
  #expect(try next.read(offset: 0, max: 8) == [7])
}

/// Each channel's own queue: what a plumber's port gives each reader.
final class Fanout: @unchecked Sendable {
  let lock = Lock()
  var queues: [Locked<[UInt8]>] = []
  let closes = Atomic<Int>(0)

  var stream: NodeStream {
    NodeStream(perChannel: {
      let q = Locked<[UInt8]>([])
      self.lock.withLock { self.queues.append(q) }
      return NodeStreamChannel(take: { max in
        q.withLock { bytes -> [UInt8]? in
          if bytes.isEmpty { return nil }
          defer { bytes.removeFirst(min(max, bytes.count)) }
          return Array(bytes.prefix(max))
        }
      }, closed: { self.closes.add(1, ordering: .relaxed) })
    })
  }

  func post(_ b: [UInt8]) { lock.withLock { for q in queues { q.withLock { $0 += b } } } }
}

@Test func aPerChannelStreamGivesEachReaderItsOwnCopy() throws {
  let service = try Service()
  let fan = Fanout()
  let node = service.tree.stream("port", fan.stream)
  service.start()
  defer { service.stop() }
  var root = try service.connect()
  var a = try root.open("port")
  var b = try root.open("port")
  #expect(soon { fan.lock.withLock { fan.queues.count } == 2 })
  fan.post(Array("msg".utf8))
  service.tree.ready(node)
  #expect(try a.read(offset: 0, max: 64) == Array("msg".utf8))
  #expect(try b.read(offset: 0, max: 64) == Array("msg".utf8))
  _ = consume a
  #expect(soon { fan.closes.load(ordering: .relaxed) == 1 })
}

/// A directory whose entries come and go (/proc's): its refresh runs
/// before a walk passes through it, and before a listing of it, so both
/// see what is there now; a refresh under it runs too.
@Test func aRefreshingDirectoryIsCurrentForWalksAndListings() throws {
  let service = try Service()
  let tree = service.tree
  let live = Locked<[String]>(["1"])
  tree.refresh("") {
    let want = live.withLock { $0 }
    for name in want where tree.node(name) == nil {
      tree.directory(name)
      tree.text(name + "/status", read: { name + "\n" })
    }
    for child in ["1", "2", "3"] where !want.contains(child) {
      if let n = tree.node(child) { tree.remove(n) }
    }
  }
  service.start()
  defer { service.stop() }
  var root = try service.connect()
  #expect(try root.readText("1/status") == "1\n")
  live.withLock { $0 = ["2", "3"] }
  #expect(try root.readText("2/status") == "2\n")  // made by the walk
  #expect(throws: (any Error).self) { _ = try root.readText("1/status") }  // gone
  live.withLock { $0 = ["3"] }
  let names = try root.readdir(cursor: 0, max: 64).entries.map { $0.name }
  #expect(names == ["3"])
}

/// Runs `body` on a thread of its own after `delay` nanoseconds.
func later(_ delay: Int64, _ body: @escaping @Sendable () -> Void) throws -> Handle {
  try Thread.spawn {
    Sys.sleep(until: Clock.monotonic() + delay)
    body()
  }
}

@Test func aRingReadOfAnEmptyStreamWaitsUntilItIsReady() throws {
  let service = try Service()
  let q = Queue()
  let node = service.tree.stream("feed", q.stream)
  service.start()
  defer { service.stop() }
  var root = try service.connect()
  var ring = try NodeBulkChannel(try root.open("feed"), slots: 4, dataSize: 16 * 1024)
  ring.timeout = Int64.max

  // Something there: the read takes it at once.
  q.lock.withLock { q.bytes = Array("ab".utf8) }
  #expect(try ring.take(max: 64) == Array("ab".utf8))

  // Nothing: the read waits until the stream is ready, a frame's worth
  // each.
  let feeder = try later(50_000_000) {
    q.lock.withLock { q.bytes = Array("frame".utf8) }
    service.tree.ready(node)
  }
  let start = Clock.monotonic()
  #expect(try ring.take(max: 64) == Array("frame".utf8))
  #expect(Clock.monotonic() - start >= 40_000_000)
  _ = try feeder.wait(for: Signals.terminated, deadline: Clock.monotonic() + 2_000_000_000)

  // A write goes on while a read is held, and an ended stream reads empty.
  let ender = try later(50_000_000) {
    q.lock.withLock { q.ended = true }
    service.tree.ready(node)
  }
  #expect(try ring.write(at: 0, Array("out".utf8)) == 3)
  #expect(q.lock.withLock { q.written } == Array("out".utf8))
  #expect(try ring.take(max: 64) == [])
  _ = try ender.wait(for: Signals.terminated, deadline: Clock.monotonic() + 2_000_000_000)
}

@Test func aHeldRingReadDoesntHoldUpAWriteBehindIt() throws {
  let service = try Service()
  let q = Queue()
  let node = service.tree.stream("feed", q.stream)
  service.start()
  defer { service.stop() }
  var root = try service.connect()
  var ring = try NodeBulkChannel(try root.open("feed"), slots: 4, dataSize: 16 * 1024)
  ring.timeout = 2_000_000_000
  // A read and a write in one wave: the write's completion comes first,
  // the read's once the stream is ready.
  let read = ring.submitWave(NodeBulk.read, at: 0, remaining: 64)
  let feeder = try later(50_000_000) {
    #expect(soon { q.lock.withLock { q.written } == Array("w".utf8) })
    q.lock.withLock { q.bytes = Array("r".utf8) }
    service.tree.ready(node)
  }
  #expect(try ring.write(at: 0, Array("w".utf8)) == 1)
  let done = try ring.complete(read)
  #expect(done.count == 1 && done[0].1 == 1)
  _ = try feeder.wait(for: Signals.terminated, deadline: Clock.monotonic() + 2_000_000_000)
}

@Test func aPerChannelStreamReadsItsOwnThroughTheRing() throws {
  let service = try Service()
  let fan = Fanout()
  let node = service.tree.stream("port", fan.stream)
  service.start()
  defer { service.stop() }
  var root = try service.connect()
  var a = try NodeBulkChannel(try root.open("port"), slots: 2, dataSize: 8192)
  var b = try root.open("port")
  #expect(soon { fan.lock.withLock { fan.queues.count } == 2 })
  let poster = try later(50_000_000) {
    fan.post(Array("msg".utf8))
    service.tree.ready(node)
  }
  #expect(try a.take(max: 64) == Array("msg".utf8))
  #expect(try b.read(offset: 0, max: 64) == Array("msg".utf8))
  _ = try poster.wait(for: Signals.terminated, deadline: Clock.monotonic() + 2_000_000_000)
}
