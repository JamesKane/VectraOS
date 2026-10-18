// SPDX-License-Identifier: BSD-3-Clause

// A profile of a node (D102, vx trace profile): the kernel's samples from
// a recording of proc(4)'s /proc/trace, each a thread's PC and return
// addresses, put with the processes its procs file names, so each
// address is a place in an image (the kernel, or what a mapping is of),
// which a symbolizer names. Counted by process, and by function: a
// function's own samples (at the top of the stack) and those it is
// anywhere in (inclusive), and each stack folded to a line, for flame
// graphs.

/// A sample (trace.h's SAMPLE then FRAMES records): the thread sampled,
/// its CPU, and its addresses innermost first, the PC first. A thread in
/// a syscall has its kernel frames, then its user PC and frames.
public struct TraceSample: Equatable, Sendable {
  public static let kernelBit: UInt64 = 1 << 63
  static let sampleKind: UInt16 = 64
  static let framesKind: UInt16 = 65

  public var time: UInt64
  public var tid: UInt32
  public var cpu: UInt16
  public var addresses: [UInt64]

  public init(time: UInt64, tid: UInt32, cpu: UInt16, addresses: [UInt64]) {
    (self.time, self.tid, self.cpu, self.addresses) = (time, tid, cpu, addresses)
  }

  /// A ring's records, in its order, as samples: a SAMPLE's frames are
  /// the FRAMES records after it, two a record.
  static func assemble(_ records: ArraySlice<TraceRecord>) -> [TraceSample] {
    var out: [TraceSample] = []
    var wanted = 0
    for r in records {
      if r.kind == sampleKind {
        out.append(TraceSample(time: r.time, tid: r.tid, cpu: r.cpu, addresses: [r.a]))
        wanted = Int(min(r.b >> 8, 16))
      } else if r.kind == framesKind, wanted > 0, !out.isEmpty {
        for a in [r.a, r.b].prefix(wanted) where a != 0 { out[out.count - 1].addresses.append(a) }
        wanted -= min(2, wanted)
      }
    }
    return out
  }
}

/// A place in an image: `kernel` (an offset from its start), or a
/// mapping's VMO's name and the offset in it.
public struct CodeLocation: Hashable, Sendable {
  public var image: String
  public var offset: UInt64
  public init(image: String, offset: UInt64) { (self.image, self.offset) = (image, offset) }
}

/// proc(4)'s /proc/trace/procs: the sampling rate, and each process seen
/// while it recorded, with the mappings it may run.
public struct ProcessTable: Sendable {
  public struct Mapping: Equatable, Sendable {
    public var base: UInt64
    public var size: UInt64
    public var offset: UInt64
    public var name: String
  }

  public struct Process: Equatable, Sendable {
    public var pid: UInt64
    public var task: UInt32
    public var name: String
    public var mappings: [Mapping] = []
  }

  public var hz: UInt64 = 1000
  public var processes: [Process] = []

  public init(text: String) {
    func number(_ s: Substring) -> UInt64? { s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : UInt64(s) }
    for line in text.split(whereSeparator: \.isNewline) {
      let words = line.split(separator: " ", maxSplits: 5)
      if words.count == 2, words[0] == "sampling", let hz = number(words[1]) { self.hz = hz }
      if words.count >= 3, words[0] == "process", let pid = number(words[1]), let task = number(words[2]) {
        let name = words.count > 3 ? line.split(separator: " ", maxSplits: 3)[3] : ""
        processes.append(Process(pid: pid, task: UInt32(truncatingIfNeeded: task), name: String(name)))
      }
      if words.count >= 5, words[0] == "map", let pid = number(words[1]), let base = number(words[2]),
        let size = number(words[3]), let offset = number(words[4]),
        let i = processes.lastIndex(where: { $0.pid == pid })
      {
        let name = words.count > 5 ? String(words[5]) : ""
        processes[i].mappings.append(Mapping(base: base, size: size, offset: offset, name: name))
      }
    }
  }

  /// The process whose task a trace id names; nil for the kernel's own
  /// threads (task 0) and those it didn't see.
  public func process(tid: UInt32) -> Process? {
    let task = tid >> 12
    return task == 0 ? nil : processes.last { $0.task == task }
  }

  /// Where `address` is: in the kernel, or in what one of `process`'s
  /// mappings is of.
  public static func location(_ address: UInt64, in process: Process?) -> CodeLocation? {
    if address & TraceSample.kernelBit != 0 { return CodeLocation(image: "kernel", offset: address & ~TraceSample.kernelBit) }
    guard let m = process?.mappings.first(where: { address >= $0.base && address - $0.base < $0.size }) else { return nil }
    return CodeLocation(image: m.name, offset: m.offset + (address - m.base))
  }
}

/// The samples, counted.
public struct Profile: Sendable {
  /// A function, as a symbolizer names it, and its image.
  public struct Frame: Hashable, Sendable {
    public var function: String
    public var image: String
    public init(function: String, image: String) { (self.function, self.image) = (function, image) }
  }

  public struct Count: Sendable {
    public var frame: Frame
    /// The process it ran in (`kernel` for the kernel's threads).
    public var process: String
    public var own: Int
    public var inclusive: Int
  }

  public var hz: UInt64
  public var samples: Int
  public var dropped: UInt64
  /// Samples per process, most first.
  public var processes: [(name: String, samples: Int)]
  /// Each function in each process, most own samples first.
  public var functions: [Count]
  /// Each stack, outermost first: process;frame;...;frame, and its count.
  public var folded: [(stack: String, count: Int)]

  /// `symbolize` names a location, and says whether it is a return address
  /// (each but the first); nil leaves it as `image+0xOFFSET`.
  public init(trace: TraceFile, processes table: ProcessTable,
              symbolize: (CodeLocation, Bool) -> Frame?) {
    hz = table.hz
    samples = trace.samples.count
    dropped = trace.dropped
    var byProcess: [String: Int] = [:]
    var counts: [String: Count] = [:]
    var stacks: [String: Int] = [:]
    for s in trace.samples {
      let process = table.process(tid: s.tid)
      let processName = process.map { $0.name.isEmpty ? "pid \($0.pid)" : $0.name }
        ?? (s.tid >> 12 == 0 ? "kernel" : "task \(s.tid >> 12)")
      byProcess[processName, default: 0] += 1
      var frames: [Frame] = []
      for (i, a) in s.addresses.enumerated() {
        guard let at = ProcessTable.location(a, in: process) else {
          frames.append(Frame(function: "0x" + String(a, radix: 16), image: "?"))
          continue
        }
        frames.append(symbolize(at, i > 0)
          ?? Frame(function: "\(at.image)+0x\(String(at.offset, radix: 16))", image: at.image))
      }
      guard let top = frames.first else { continue }
      func key(_ f: Frame) -> String { processName + "\u{0}" + f.image + "\u{0}" + f.function }
      counts[key(top), default: Count(frame: top, process: processName, own: 0, inclusive: 0)].own += 1
      var seen = Set<String>()
      for f in frames where seen.insert(key(f)).inserted {
        counts[key(f), default: Count(frame: f, process: processName, own: 0, inclusive: 0)].inclusive += 1
      }
      stacks[([processName] + frames.reversed().map(\.function)).joined(separator: ";"), default: 0] += 1
    }
    processes = byProcess.map { ($0.key, $0.value) }.sorted { $0.samples != $1.samples ? $0.samples > $1.samples : $0.name < $1.name }
    functions = counts.values.sorted {
      $0.own != $1.own ? $0.own > $1.own
        : $0.inclusive != $1.inclusive ? $0.inclusive > $1.inclusive : $0.frame.function < $1.frame.function
    }
    folded = stacks.map { ($0.key, $0.value) }.sorted { $0.stack < $1.stack }
  }
}
