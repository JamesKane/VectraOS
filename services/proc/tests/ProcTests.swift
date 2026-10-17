// SPDX-License-Identifier: BSD-3-Clause

// /proc (D79) over a fake kernel: a directory a process, current as it is
// walked and listed; Plan 9's status line; ctl's kill; notes posted to a
// process and to its note group (its job's tree).

import Glibc
import IPC
import Node
import Proc
import Sys
import Testing

/// Processes that come and go, and what was done to them.
final class FakeKernel: @unchecked Sendable {
  let lock = Lock()
  var entries: [ProcEntry] = []
  var killed: [UInt64] = []
  var posted: [(UInt64, String)] = []

  var host: ProcHost {
    ProcHost(
      processes: { self.lock.withLock { self.entries } },
      status: { koid in
        self.lock.withLock { self.entries.contains { $0.koid == koid } }
          ? ProcStatus(name: "p\(koid)", state: "Running", userMilliseconds: 12, realMilliseconds: 3400, memoryKiB: 96)
          : nil
      },
      kill: { koid in
        self.lock.withLock {
          guard self.entries.contains(where: { $0.koid == koid }) else { return false }
          self.killed.append(koid)
          return true
        }
      },
      post: { (koid: UInt64, text: String) throws(Status) in
        try self.lock.withLock { () throws(Status) in
          guard self.entries.contains(where: { $0.koid == koid }) else { throw .badState }
          self.posted.append((koid, text))
        }
      })
  }
}

/// /proc served on a thread of its own.
final class ProcService: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  let files: ProcFiles
  var thread = pthread_t()

  init(_ kernel: FakeKernel) throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    files = ProcFiles(tree: tree, host: kernel.host)
    pthread_create(&thread, nil, { arg in
      let s = Unmanaged<ProcService>.fromOpaque(arg!).takeUnretainedValue()
      try? s.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  func connect() throws -> NodeIPC.NodeClient {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return NodeIPC.NodeClient(channel: ends.a)
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
  }
}

@Test func statusIsPlan9sLine() {
  let line = Proc.statusLine(ProcStatus(name: "rc", state: "Running", userMilliseconds: 12, realMilliseconds: 3400,
                                        memoryKiB: 96))
  let expected = "rc" + String(repeating: " ", count: 25) + " none" + String(repeating: " ", count: 23) + " Running    "
    + "          12           0        3400           0           0           0          96           0           0\n"
  #expect(line == expected)
  // Plan 9's ps reads it by fields: name, user, state, then nine numbers.
  #expect(line.split(separator: " ").count == 12)
}

@Test func aNoteGroupIsAJobAndTheJobsUnderIt() {
  let all = [ProcEntry(koid: 1, jobs: [10]), ProcEntry(koid: 2, jobs: [10, 20]), ProcEntry(koid: 3, jobs: [10, 20, 30]),
             ProcEntry(koid: 4, jobs: [10, 21])]
  #expect(Proc.noteGroup(of: 2, in: all) == [2, 3])
  #expect(Proc.noteGroup(of: 1, in: all) == [1, 2, 3, 4])
  #expect(Proc.noteGroup(of: 9, in: all) == [])
}

@Test func procFollowsProcessesAndPostsTheirNotes() throws {
  let kernel = FakeKernel()
  kernel.entries = [ProcEntry(koid: 5, jobs: [1]), ProcEntry(koid: 6, jobs: [1, 2]), ProcEntry(koid: 7, jobs: [1, 3])]
  let service = try ProcService(kernel)
  defer { service.stop() }
  var root = try service.connect()
  #expect(try root.readdir(cursor: 0, max: 64).entries.map { $0.name } == ["5", "6", "7"])
  #expect(try root.readText("6/args") == "p6")
  #expect(try root.readText("6/status").hasPrefix("p6 "))

  // A note, its newline dropped; then the note group of 5: all three.
  try root.writeText("interrupt\n", "6/note")
  #expect(kernel.lock.withLock { kernel.posted.map { "\($0.0) \($0.1)" } } == ["6 interrupt"])
  try root.writeText("hangup", "5/notepg")
  #expect(kernel.lock.withLock { kernel.posted.count } == 4)
  try root.writeText("kill\n", "7/ctl")
  #expect(kernel.lock.withLock { kernel.killed } == [7])
  #expect(throws: (any Error).self) { try root.writeText("stop", "7/ctl") }

  // One goes, one comes: the walk and the listing both see it.
  kernel.lock.withLock { kernel.entries = [ProcEntry(koid: 5, jobs: [1]), ProcEntry(koid: 8, jobs: [1])] }
  #expect(try root.readText("8/args") == "p8")
  #expect(throws: (any Error).self) { _ = try root.readText("6/status") }
  #expect(try root.readdir(cursor: 0, max: 64).entries.map { $0.name } == ["5", "8"])
}
