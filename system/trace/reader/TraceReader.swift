// SPDX-License-Identifier: BSD-3-Clause

// Reads trace regions (docs/trace-format.md): every ring's records, merged
// by time, with names resolved; summaries per name; mark pairs for budgets.

import TraceFormat

/// One record, read back.
public struct TraceRecord: Equatable, Sendable {
  public var time: UInt64
  public var kind: UInt16
  public var cpu: UInt16
  public var tid: UInt32
  public var a: UInt64
  public var b: UInt64
  public init(time: UInt64, kind: UInt16, cpu: UInt16 = 0, tid: UInt32 = 1, a: UInt64, b: UInt64) {
    (self.time, self.kind, self.cpu, self.tid, self.a, self.b) = (time, kind, cpu, tid, a, b)
  }
}

public enum TraceReadError: Error, Equatable {
  case notATrace
  case unsupportedVersion(UInt32)
  case malformed(String)
}

/// A trace region, read.
public struct TraceFile: Sendable {
  public var counterHz: UInt64
  public var start: UInt64
  public var processID: UInt32
  public var circular: Bool
  public var records: [TraceRecord]  // every ring's, merged by time
  public var dropped: UInt64
  var strings: [UInt64: String]

  public init(bytes: [UInt8]) throws(TraceReadError) {
    func u32(_ o: Int) -> UInt32 { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    func u64(_ o: Int) -> UInt64 { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
    guard bytes.count >= TraceFormat.headerSize, u32(0) == TraceFormat.regionMagic else { throw .notATrace }
    guard u32(4) == TraceFormat.version else { throw .unsupportedVersion(u32(4)) }
    counterHz = u64(TraceFormat.counterHz)
    start = u64(TraceFormat.start)
    processID = u32(TraceFormat.processID)
    circular = u32(TraceFormat.flags) & TraceFormat.flagCircular != 0
    guard counterHz > 0 else { throw .malformed("no counter frequency") }

    // Strings.
    let stringsAt = Int(u64(TraceFormat.stringsOffset))
    let stringsSize = Int(u64(TraceFormat.stringsSize))
    let used = min(Int(u64(TraceFormat.stringsUsed)), stringsSize)
    guard stringsAt + stringsSize <= bytes.count else { throw .malformed("string table past the end") }
    strings = [:]
    var at = 0
    while at + 4 <= used {
      let length = Int(u32(stringsAt + at))
      guard at + 4 + length <= used else { break }
      strings[UInt64(at)] = String(decoding: bytes[(stringsAt + at + 4)..<(stringsAt + at + 4 + length)], as: UTF8.self)
      at += 4 + (length + 3) & ~3
    }

    // Rings.
    let ringsAt = Int(u64(TraceFormat.ringsOffset))
    let ringSize = Int(u64(TraceFormat.ringSize))
    let claimed = min(Int(u32(TraceFormat.ringsClaimed)), Int(u32(TraceFormat.ringCount)))
    guard ringSize > TraceFormat.ringHeaderSize, ringsAt + claimed * ringSize <= bytes.count else {
      throw .malformed("rings past the end")
    }
    var records: [TraceRecord] = []
    var dropped: UInt64 = 0
    for i in 0..<claimed {
      let ring = ringsAt + i * ringSize
      guard u32(ring + TraceFormat.ringMagicOffset) == TraceFormat.ringMagic else { continue }
      let capacity = u64(ring + TraceFormat.ringCapacity)
      guard capacity > 0, capacity & (capacity - 1) == 0,
        TraceFormat.ringHeaderSize + Int(capacity) * TraceFormat.recordSize <= ringSize
      else { throw .malformed("ring \(i)'s capacity") }
      let head = u64(ring + TraceFormat.ringHead)
      dropped += u64(ring + TraceFormat.ringDropped)
      // Oneshot rings stop at capacity. A wrapped circular ring holds the
      // newest `capacity`, of which the oldest sixteenth may be mid-overwrite.
      let first = head > capacity ? head - capacity + capacity / 16 : 0
      for n in first..<head {
        let r = ring + TraceFormat.ringHeaderSize + Int(n & (capacity - 1)) * TraceFormat.recordSize
        records.append(TraceRecord(
          time: u64(r), kind: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: r + 8, as: UInt16.self) },
          cpu: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: r + 10, as: UInt16.self) },
          tid: u32(r + 12), a: u64(r + 16), b: u64(r + 24)))
      }
    }
    records.sort { $0.time < $1.time }
    self.records = records
    self.dropped = dropped
  }

  /// A name id's text.
  /// A trace from its parts, for tests of what reads traces.
  public init(counterHz: UInt64, start: UInt64 = 0, processID: UInt32 = 1, records: [TraceRecord],
              names: [UInt64: String]) {
    self.counterHz = counterHz
    self.start = start
    self.processID = processID
    circular = false
    self.records = records
    dropped = 0
    strings = names
  }

  public func name(_ id: UInt64) -> String { strings[id] ?? "#\(id)" }

  /// Ticks to seconds.
  public func seconds(_ ticks: UInt64) -> Double { Double(ticks) / Double(counterHz) }

  /// A MARK record's label.
  public static func label(_ r: TraceRecord) -> String {
    var bytes: [UInt8] = []
    for word in [r.a, r.b] { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: word >> (8 * i))) } }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }

  /// Zones, by name: each zone's duration in seconds.
  public func zones() -> [String: [Double]] {
    var out: [String: [Double]] = [:]
    for r in records where r.kind == TraceKind.zone.rawValue && r.a >= r.time {
      out[name(r.b), default: []].append(seconds(r.a - r.time))
    }
    return out
  }

  /// Flows, by name: each flow's span from its first step to its last, in
  /// seconds, and how many steps it had (an IPC call: its write, the
  /// server's read, the reply's write and the caller's read).
  public func flows() -> [String: [(seconds: Double, steps: Int)]] {
    var spans: [UInt64: [UInt64: (first: UInt64, last: UInt64, steps: Int)]] = [:]
    for r in records where r.kind == TraceKind.flow.rawValue {
      let s = spans[r.b, default: [:]][r.a]
      spans[r.b, default: [:]][r.a] = (Swift.min(s?.first ?? r.time, r.time), Swift.max(s?.last ?? r.time, r.time),
                                       (s?.steps ?? 0) + 1)
    }
    var out: [String: [(seconds: Double, steps: Int)]] = [:]
    for (nameID, byFlow) in spans {
      out[name(nameID)] = byFlow.values.map { (seconds($0.last - $0.first), $0.steps) }
    }
    return out
  }

  /// The time between each mark labeled `begin` and the next labeled `end`,
  /// on the same thread, in seconds.
  public func intervals(from begin: String, to end: String) -> [Double] {
    var open: [UInt32: UInt64] = [:]
    var out: [Double] = []
    for r in records where r.kind == TraceKind.mark.rawValue {
      let label = Self.label(r)
      if label == begin {
        open[r.tid] = r.time
      } else if label == end, let t = open.removeValue(forKey: r.tid) {
        out.append(seconds(r.time - t))
      }
    }
    return out
  }
}

/// Count, total and percentiles of a set of durations.
public struct Distribution: Equatable, Sendable {
  public var count: Int
  public var total: Double
  public var p50: Double
  public var p99: Double
  public var max: Double

  public init(_ values: [Double]) {
    let s = values.sorted()
    count = s.count
    total = s.reduce(0, +)
    func at(_ q: Double) -> Double { s.isEmpty ? 0 : s[Swift.min(s.count - 1, Int((Double(s.count) * q).rounded(.up)) - 1)] }
    p50 = at(0.50)
    p99 = at(0.99)
    max = s.last ?? 0
  }
}

/// Several traces of one recording read as one timeline (M3f): the kernel's
/// (`kernel.trace`, from croi's rings) and each process's. They share the
/// cycle counter, so records compare by time; a call's records join by
/// flow id, the user FLOW records each end writes and croi's CHANNEL_WRITE,
/// CHANNEL_READ and DONATE (docs/trace-format.md, "IPC flow ids").
public struct TraceSet: Sendable {
  /// croi's IPC record kinds.
  public static let channelWrite: UInt16 = 80
  public static let channelRead: UInt16 = 81
  public static let donate: UInt16 = 82

  /// One step of a flow: when, and what (a process's name, or croi's
  /// `write`, `read` or `donate`).
  public struct Step: Equatable, Sendable {
    public var time: UInt64
    public var what: String
  }

  /// Each file, by the name of the process that wrote it ("kernel" for
  /// croi's).
  public var files: [(name: String, trace: TraceFile)]

  public init(_ files: [(name: String, trace: TraceFile)]) { self.files = files }

  public var counterHz: UInt64 { files.first?.trace.counterHz ?? 1 }

  /// Each flow's steps across every file, by time, and its name (the first
  /// user step's).
  public func joinedFlows() -> [UInt64: (name: String, steps: [Step])] {
    var flows: [UInt64: (name: String, steps: [Step])] = [:]
    for (process, t) in files {
      for r in t.records {
        let what: String
        switch r.kind {
        case TraceKind.flow.rawValue: what = process
        case Self.channelWrite: what = "write"
        case Self.channelRead: what = "read"
        case Self.donate: what = "donate"
        default: continue
        }
        var f = flows[r.a] ?? (name: "", steps: [])
        if r.kind == TraceKind.flow.rawValue && f.name.isEmpty { f.name = t.name(r.b) }
        f.steps.append(Step(time: r.time, what: what))
        flows[r.a] = f
      }
    }
    for (id, f) in flows { flows[id]!.steps = f.steps.sorted { $0.time < $1.time } }
    return flows
  }

  /// Per flow name: how many, the commonest path through the steps, and
  /// the median time between each step and the next on that path (seconds).
  public func breakdown() -> [(name: String, count: Int, path: [String], gaps: [Double], total: Double)] {
    var byName: [String: [[Step]]] = [:]
    for (_, f) in joinedFlows() where !f.name.isEmpty { byName[f.name, default: []].append(f.steps) }
    var out: [(name: String, count: Int, path: [String], gaps: [Double], total: Double)] = []
    for (name, flows) in byName {
      var paths: [[String]: [[Step]]] = [:]
      for steps in flows { paths[steps.map(\.what), default: []].append(steps) }
      // The commonest; of those as common, the longest (the most complete).
      guard let (path, common) = paths.max(by: { ($0.value.count, $0.key.count) < ($1.value.count, $1.key.count) })
      else { continue }
      func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
      let hz = Double(counterHz)
      let gaps = (1..<max(path.count, 1)).map { i in median(common.map { Double($0[i].time - $0[i - 1].time) / hz }) }
      let total = median(common.map { Double($0.last!.time - $0.first!.time) / hz })
      out.append((name, flows.count, path, gaps, total))
    }
    return out.sorted { $0.name < $1.name }
  }
}
