// SPDX-License-Identifier: BSD-3-Clause

// Streams (D84): a read of a stream with nothing in it waits, the server
// holding the call until the stream is ready; a read mid-batch doesn't
// wait; the stream hears its channels come and go; a reader that closes
// while held leaves nothing behind.

import Glibc
import IPC
import Node
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
