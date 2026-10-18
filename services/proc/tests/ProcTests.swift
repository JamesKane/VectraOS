// SPDX-License-Identifier: BSD-3-Clause

// /proc (D79) over a fake kernel: a directory a process, current as it is
// walked and listed; Plan 9's status line; ctl's kill; notes posted to a
// process and to its note group (its job's tree); /proc/trace (D102).

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
  /// /proc/trace's kernel, if it has one.
  var trace: TraceHost?

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
      },
      trace: trace)
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

/// The kernel's trace, faked: what it was asked, and a recording.
final class FakeTrace: @unchecked Sendable {
  let lock = Lock()
  var started: [(hz: UInt64, pages: Int, categories: UInt32)] = []
  var stops = 0
  var refuse: Status?

  func host(_ kernel: FakeKernel) -> TraceHost {
    TraceHost(
      start: { (hz: UInt64, pages: Int, categories: UInt32) throws(Status) in
        try self.lock.withLock { () throws(Status) in
          if let r = self.refuse { throw r }
          self.started.append((hz, pages, categories))
        }
      },
      stop: {
        self.lock.withLock { self.stops += 1 }
        return [1, 2, 3]
      },
      describe: { koid in
        kernel.lock.withLock { kernel.entries.contains { $0.koid == koid } }
          ? TracedProcess(koid: koid, task: UInt32(koid) + 100, name: "p\(koid)", mappings: [
            ProcessMapping(name: "bootfs", base: 0x1000 * koid, size: 0x2000, flags: 4, vmoKoid: 9, vmoOffset: 0x30000)])
          : nil
      })
  }
}

/// /proc/trace: ctl starts the kernel's trace with samples and the
/// categories named, says what it does, and on stop gives the recording
/// and every process seen since the start, those gone by then too.
@Test func procTraceRecordsTheKernelAndTheProcessesItSaw() throws {
  let kernel = FakeKernel()
  let trace = FakeTrace()
  kernel.trace = trace.host(kernel)
  kernel.entries = [ProcEntry(koid: 5, jobs: [1]), ProcEntry(koid: 6, jobs: [1])]
  let service = try ProcService(kernel)
  defer { service.stop() }
  var root = try service.connect()
  #expect(try root.readdir(cursor: 0, max: 64).entries.map { $0.name }.sorted() == ["5", "6", "trace"])
  #expect(try root.readText("trace/ctl") == "idle\n")
  #expect(throws: (any Error).self) { try root.writeText("stop", "trace/ctl") }
  #expect(throws: (any Error).self) { try root.writeText("start hz", "trace/ctl") }
  #expect(throws: (any Error).self) { try root.writeText("start hz 0", "trace/ctl") }
  #expect(throws: (any Error).self) { try root.writeText("start pages 5000", "trace/ctl") }
  #expect(throws: (any Error).self) { try root.writeText("start disk", "trace/ctl") }
  #expect(throws: (any Error).self) { try root.writeText("begin", "trace/ctl") }
  #expect(trace.lock.withLock { trace.started.count } == 0)

  try root.writeText("start hz 4000 sched ipc sched\n", "trace/ctl")
  #expect(trace.lock.withLock { trace.started.map { "\($0.hz) \($0.pages) \($0.categories)" } }
    == ["4000 \(ProcTrace.defaultPages) \((1 << 6) | 1 | (1 << 3))"])
  #expect(try root.readText("trace/ctl") == "recording hz 4000 sched ipc\n")
  #expect(try root.readAll("trace/kernel.trace") == [])

  // 6 ends and 7 starts while it records: both are in procs.
  kernel.lock.withLock { kernel.entries = [ProcEntry(koid: 5, jobs: [1]), ProcEntry(koid: 7, jobs: [1])] }
  try root.writeText("stop", "trace/ctl")
  #expect(try root.readText("trace/ctl") == "stopped hz 4000\n")
  #expect(try root.readAll("trace/kernel.trace") == [1, 2, 3])
  #expect(try root.readText("trace/procs") == """
    sampling 4000
    process 5 105 p5
    map 5 0x5000 0x2000 0x30000 bootfs
    process 6 106 p6
    map 6 0x6000 0x2000 0x30000 bootfs
    process 7 107 p7
    map 7 0x7000 0x2000 0x30000 bootfs

    """)

  // Started again: the last recording goes; a refusal leaves it idle.
  try root.writeText("start", "trace/ctl")
  #expect(trace.lock.withLock { trace.started.last.map { "\($0.hz) \($0.categories)" } } == "1000 64")
  #expect(try root.readAll("trace/kernel.trace") == [])
  trace.lock.withLock { trace.refuse = .noMemory }
  #expect(throws: (any Error).self) { try root.writeText("start pages 4096", "trace/ctl") }
  #expect(trace.lock.withLock { trace.stops } == 2)  // the recording under way, first
  #expect(try root.readText("trace/ctl") == "idle\n")
}

/// Without the tracing resource there is no /proc/trace.
@Test func procWithoutTracingHasNoTrace() throws {
  let kernel = FakeKernel()
  kernel.entries = [ProcEntry(koid: 5, jobs: [1])]
  let service = try ProcService(kernel)
  defer { service.stop() }
  var root = try service.connect()
  #expect(try root.readdir(cursor: 0, max: 64).entries.map { $0.name } == ["5"])
}
