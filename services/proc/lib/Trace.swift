// SPDX-License-Identifier: BSD-3-Clause

// /proc/trace (D102), after Plan 9's: the kernel's trace and its samples,
// with what a reader needs to name the samples' addresses.
//   ctl           `start [hz N] [pages N] [CATEGORY ...]`, `stop`; reads
//                 what it is doing
//   kernel.trace  the kernel's recording (docs/trace-format.md), once stopped
//   procs         each process seen while it recorded (there at the start,
//                 started meanwhile, or there at the stop): its pid, its
//                 trace task, its name, and the mappings it may run
// Samples are always on; the categories add the kernel's others. What it
// needs of the kernel is a TraceHost's, so it runs hosted against fakes.

import Node
import Sys

/// A process as /proc/trace's procs gives it.
public struct TracedProcess: Equatable, Sendable {
  public var koid: UInt64
  /// Its threads' trace ids shifted right 12: the kernel's task number.
  public var task: UInt32
  public var name: String
  /// The mappings it may run.
  public var mappings: [ProcessMapping]
  public init(koid: UInt64, task: UInt32, name: String, mappings: [ProcessMapping]) {
    (self.koid, self.task, self.name, self.mappings) = (koid, task, name, mappings)
  }
}

/// What /proc/trace needs of the kernel.
public struct TraceHost: @unchecked Sendable {
  /// Starts the kernel's trace: `categories` (trace.h's bits), samples
  /// `hz` a second, `pages` × 128 records a CPU.
  public var start: (_ hz: UInt64, _ pages: Int, _ categories: UInt32) throws(Status) -> Void
  /// Stops it, and gives the recording as a trace file.
  public var stop: () -> [UInt8]
  /// The process `koid`, if it is still there.
  public var describe: (UInt64) -> TracedProcess?
  /// Calls its argument with each process that starts from now, before
  /// it runs, until the function it gives is called.
  public var watch: (@escaping @Sendable (TracedProcess) -> Void) -> () -> Void

  public init(start: @escaping (UInt64, Int, UInt32) throws(Status) -> Void, stop: @escaping () -> [UInt8],
              describe: @escaping (UInt64) -> TracedProcess?,
              watch: @escaping (@escaping @Sendable (TracedProcess) -> Void) -> () -> Void = { _ in {} }) {
    self.start = start
    self.stop = stop
    self.describe = describe
    self.watch = watch
  }
}

public enum ProcTrace {
  /// The kernel's categories (trace.h's CROI_TRACE_*), by name.
  public static let categories: [(name: StaticString, bit: UInt32)] = [
    ("sched", 1 << 0), ("irq", 1 << 1), ("vm", 1 << 2), ("ipc", 1 << 3), ("futex", 1 << 4), ("syscall", 1 << 5),
  ]
  /// CROI_TRACE_SAMPLE: always on.
  public static let sample: UInt32 = 1 << 6
  public static let defaultHz: UInt64 = 1000
  /// 512 pages: 65,536 records a CPU, some seven seconds of samples at
  /// 1 kHz with full stacks.
  public static let defaultPages = 512
  /// The kernel's limits (trace_configure).
  public static let maxPages = 4096
  public static let maxHz: UInt64 = 100_000

  /// A start command's settings: `start [hz N] [pages N] [CATEGORY ...]`;
  /// nil if it isn't one.
  public static func parse(_ words: [[UInt8]]) -> (hz: UInt64, pages: Int, categories: UInt32, names: [[UInt8]])? {
    guard words.first.map({ same($0, "start") }) == true else { return nil }
    var hz = defaultHz, pages = defaultPages, mask = sample
    var names: [[UInt8]] = []
    var i = 1
    while i < words.count {
      let w = words[i]
      if same(w, "hz") || same(w, "pages") {
        guard i + 1 < words.count, let n = number(words[i + 1]) else { return nil }
        if same(w, "hz") {
          guard n >= 1, n <= maxHz else { return nil }
          hz = n
        } else {
          guard n >= 1, n <= UInt64(maxPages) else { return nil }
          pages = Int(n)
        }
        i += 2
        continue
      }
      guard let c = categories.first(where: { same(w, $0.name) }) else { return nil }
      if mask & c.bit == 0 { names.append(w) }
      mask |= c.bit
      i += 1
    }
    return (hz, pages, mask, names)
  }

  /// procs' text: `sampling HZ`, then for each process `process PID TASK
  /// NAME` and a `map PID BASE SIZE OFFSET NAME` line for each mapping it
  /// may run (hexadecimal; OFFSET is where it starts in its VMO, NAME the
  /// VMO's: `bootfs`, a bootfs file's path, `push:NAME`).
  public static func procs(hz: UInt64, _ processes: [TracedProcess]) -> String {
    var out = "sampling \(hz)\n"
    for p in processes {
      out += "process \(p.koid) \(p.task) \(p.name)\n"
      for m in p.mappings {
        out += "map \(p.koid) \(hex(m.base)) \(hex(m.size)) \(hex(m.vmoOffset)) \(m.name)\n"
      }
    }
    return out
  }

  static func same(_ a: [UInt8], _ b: StaticString) -> Bool {
    unsafe a.elementsEqual(UnsafeBufferPointer(start: b.utf8Start, count: b.utf8CodeUnitCount))
  }

  static func number(_ w: [UInt8]) -> UInt64? {
    guard !w.isEmpty, w.count <= 19 else { return nil }
    var n: UInt64 = 0
    for c in w {
      guard c >= 0x30, c <= 0x39 else { return nil }
      n = n * 10 + UInt64(c - 0x30)
    }
    return n
  }

  static func hex(_ v: UInt64) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    var n = v
    repeat {
      out.append(digits[Int(n & 15)])
      n >>= 4
    } while n != 0
    return "0x" + String(decoding: out.reversed(), as: UTF8.self)
  }
}

/// /proc/trace's files, under `tree`.
final class TraceFiles: @unchecked Sendable {
  enum State {
    case idle
    case recording(hz: UInt64, names: [[UInt8]])
    case stopped(hz: UInt64)
  }

  let tree: NodeTree
  let host: TraceHost
  let processes: () -> [ProcEntry]
  let lock = Lock()
  var state = State.idle
  /// Each process seen since the recording started.
  var seen: [TracedProcess] = []
  /// Ends the watch for processes starting, while it records.
  var unwatch: (() -> Void)?
  var kernelNode: TreeNode
  var procsNode: TreeNode

  init(tree: NodeTree, host: TraceHost, processes: @escaping () -> [ProcEntry]) {
    self.tree = tree
    self.host = host
    self.processes = processes
    tree.directory("trace")
    kernelNode = tree.file("trace/kernel.trace", [])
    procsNode = tree.file("trace/procs", [])
    tree.text("trace/ctl", read: { [self] in status() }, write: { [self] (text: String) throws(NodeError) in
      try command(Array(Proc.note(text).utf8).split(separator: 0x20).map { Array($0) })
    })
  }

  func status() -> String {
    lock.withLock { () -> String in
      switch state {
      case .idle: return "idle\n"
      case .stopped(let hz): return "stopped hz \(hz)\n"
      case .recording(let hz, let names):
        var line = "recording hz \(hz)"
        for n in names { line += " " + String(decoding: n, as: UTF8.self) }
        return line + "\n"
      }
    }
  }

  func command(_ words: [[UInt8]]) throws(NodeError) {
    if words.count == 1, ProcTrace.same(words[0], "stop") {
      try stop()
    } else if let s = ProcTrace.parse(words) {
      try start(s.hz, s.pages, s.categories, s.names)
    } else {
      throw .invalid
    }
  }

  func start(_ hz: UInt64, _ pages: Int, _ categories: UInt32, _ names: [[UInt8]]) throws(NodeError) {
    if case .recording = lock.withLock({ state }) {
      _ = host.stop()
      lock.withLock { unwatch }?()
    }
    tree.setContents(kernelNode, [])
    tree.setContents(procsNode, [])
    let now = describeAll()
    do throws(Status) {
      try host.start(hz, pages, categories)
    } catch {
      lock.withLock { state = .idle }
      throw error == .noMemory ? .io : Proc.nodeError(error)
    }
    lock.withLock {
      seen = now
      state = .recording(hz: hz, names: names)
    }
    let ends = host.watch { [self] p in
      lock.withLock { if !seen.contains(where: { $0.koid == p.koid }) { seen.append(p) } }
    }
    lock.withLock { unwatch = ends }
  }

  func stop() throws(NodeError) {
    guard case .recording(let hz, _) = lock.withLock({ state }) else { throw .invalid }
    let recording = host.stop()
    lock.withLock { () -> (() -> Void)? in
      defer { unwatch = nil }
      return unwatch
    }?()
    let now = describeAll()
    let all = lock.withLock { () -> [TracedProcess] in
      for p in now where !seen.contains(where: { $0.koid == p.koid }) { seen.append(p) }
      state = .stopped(hz: hz)
      return seen
    }
    tree.setContents(kernelNode, recording)
    tree.setContents(procsNode, Array(ProcTrace.procs(hz: hz, all).utf8))
  }

  func describeAll() -> [TracedProcess] { processes().compactMap { host.describe($0.koid) } }
}
