// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import Glibc
import Trace
import TraceReader
import Testing

let work = TraceName("work")
let outer = TraceName("outer")
let depth = TraceName("depth")

/// Runs `body` on a new thread, which has no ring yet, and waits for it.
func onNewThread(_ body: @escaping @Sendable () -> Void) {
  final class Box: @unchecked Sendable { let body: @Sendable () -> Void; init(_ b: @escaping @Sendable () -> Void) { body = b } }
  var thread = pthread_t()
  let box = Unmanaged.passRetained(Box(body)).toOpaque()
  pthread_create(&thread, nil, { arg in
    let b = Unmanaged<Box>.fromOpaque(arg!).takeRetainedValue()
    b.body()
    return nil
  }, box)
  pthread_join(thread, nil)
}

func scratch(_ name: String) -> String { "/tmp/todhchai-trace-test-\(getpid())-\(name).trace" }

func read(_ path: String) throws -> TraceFile {
  let fd = open(path, O_RDONLY)
  defer { close(fd) }
  var st = stat()
  fstat(fd, &st)
  var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
  var got = 0
  while got < bytes.count {
    let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, $0.count - got) }
    guard n > 0 else { break }
    got += n
  }
  return try TraceFile(bytes: bytes)
}

@Suite(.serialized) struct Recording {
  @Test func zonesMarksAndCountersRoundTrip() throws {
    let path = scratch("roundtrip")
    defer { unlink(path) }
    #expect(Trace.start(path: path, categories: [.app, .mark]))
    for _ in 0..<3 {
      onNewThread {
        Trace.mark("begin")
        for i in 0..<10 {
          Trace.zone(outer) {
            Trace.zone(work) { _ = (0..<1000).reduce(0, &+) }
          }
          Trace.counter(depth, Int64(i))
        }
        Trace.mark("end")
      }
    }
    Trace.stop()
    let t = try read(path)
    let zones = t.zones()
    #expect(zones["work"]?.count == 30 && zones["outer"]?.count == 30)
    #expect(t.records.filter { $0.kind == TraceKind.counter.rawValue }.count == 30)
    #expect(Set(t.records.map(\.tid)).count == 3)
    #expect(t.intervals(from: "begin", to: "end").count == 3)
    #expect(t.counterHz > 1_000_000 && t.dropped == 0)
    // Each outer zone contains the work zone that ended inside it.
    let outerTotal = zones["outer"]!.reduce(0, +), workTotal = zones["work"]!.reduce(0, +)
    #expect(outerTotal >= workTotal)
  }

  // (todhchai's test of a call's flow across both ends comes back with
  // IPC, V2's item 4.)

  @Test func oneshotRingsDropWhatDoesntFit() throws {
    let path = scratch("oneshot")
    defer { unlink(path) }
    #expect(Trace.start(path: path, categories: .app, recordsPerRing: 16))
    onNewThread { for _ in 0..<40 { Trace.zone(work) {} } }
    Trace.stop()
    let t = try read(path)
    #expect(t.records.count == 16 && t.dropped == 24)
  }

  @Test func circularRingsKeepTheNewest() throws {
    let path = scratch("circular")
    defer { unlink(path) }
    #expect(Trace.start(path: path, categories: .app, circular: true, recordsPerRing: 16))
    onNewThread { for i in 0..<40 { Trace.counter(depth, Int64(i)) } }
    Trace.stop()
    let t = try read(path)
    // The newest 16, values 24 to 39: a reader skips only a slot being
    // overwritten, by its sequence (D50).
    #expect(t.records.map { Int64(bitPattern: $0.b) } == Array(24...39))
  }

  @Test func disabledCategoriesRecordNothing() throws {
    let path = scratch("disabled")
    defer { unlink(path) }
    #expect(Trace.start(path: path, categories: [.audio]))
    onNewThread {
      Trace.zone(work, .app) {}
      Trace.mark("ignored")
      Trace.zone(work, .audio) {}
    }
    Trace.stop()
    let t = try read(path)
    #expect(t.records.count == 1)
  }
}

@Test func distributionsArePercentiles() {
  let d = Distribution((1...100).map(Double.init))
  #expect(d.count == 100 && d.p50 == 50 && d.p99 == 99 && d.max == 100 && d.total == 5050)
}

@Test func garbageIsNotATrace() {
  #expect(throws: TraceReadError.notATrace) { try TraceFile(bytes: [UInt8](repeating: 7, count: 8192)) }
}

extension Recording {
  /// The session's export (td-trace lines: base64 pieces, zero runs, an
  /// end) reassembles to the file; a dropped piece is damage. (In the
  /// recording suite: Trace.start is the process's.)
  @Test func anExportReassembles() throws {
    let path = scratch("export")
    defer { unlink(path) }
    #expect(Trace.start(path: path, categories: .app, recordsPerRing: 64))
    onNewThread { for i in 0..<20 { Trace.counter(depth, Int64(i)) } }
    Trace.stop()
    let fd = open(path, O_RDONLY)
    var st = stat()
    fstat(fd, &st)
    var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
    _ = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
    close(fd)
    // As TraceSession.emit writes them, after the debuglog's prefix.
    var lines: [String] = []
    var at = 0
    while at < bytes.count {
      var zeros = 0
      while at + zeros < bytes.count && bytes[at + zeros] == 0 { zeros += 1 }
      if zeros >= 120 {
        lines.append("[00001.000] 01:02> td-trace 1-test \(at) zero \(zeros)\r")
        at += zeros
      } else {
        let n = min(120, bytes.count - at)
        lines.append("[00001.000] 01:02> td-trace 1-test \(at) \(Data(bytes[at..<(at + n)]).base64EncodedString())\r")
        at += n
      }
    }
    lines.append("td-trace 1-test end \(bytes.count)")
    guard case .success(let files) = TraceExport.reassemble(lines) else { Issue.record("damaged"); return }
    #expect(files.count == 1 && files[0].name == "1-test" && files[0].bytes == bytes)
    #expect(try TraceFile(bytes: files[0].bytes).records.count == 20)
    var dropped = lines
    dropped.remove(at: 1)
    guard case .failure = TraceExport.reassemble(dropped) else { Issue.record("a dropped piece wasn't seen"); return }
  }
}

/// A profile: samples put together from SAMPLE and FRAMES records, each
/// address placed in the kernel or in what its process's mapping is of,
/// and counted by process, by function (own and inclusive) and by stack.
@Test func profileCountsSamplesByProcessAndFunction() {
  let k = TraceSample.kernelBit
  func sample(_ tid: UInt32, _ pc: UInt64, _ frames: [UInt64]) -> [TraceRecord] {
    var out = [TraceRecord(time: 1, kind: 64, tid: tid, a: pc, b: UInt64(frames.count) << 8)]
    var i = 0
    while i < frames.count {
      out.append(TraceRecord(time: 1, kind: 65, tid: tid, a: frames[i], b: i + 1 < frames.count ? frames[i + 1] : 0))
      i += 2
    }
    return out
  }
  // net (task 3): twice in its loop under main, once in a syscall from it;
  // the kernel's own thread (task 0) once.
  let records = sample(3 << 12 | 1, 0x1_0010, [0x1_0105])
    + sample(3 << 12 | 2, 0x1_0020, [0x1_0105])
    + sample(3 << 12 | 1, k | 0x40, [0x1_0030, 0x1_0105])
    + sample(5, k | 0x80, [])
    + sample(9 << 12, 0x7777, [])
  let trace = TraceFile(counterHz: 1_000_000, records: records, names: [:])
  #expect(trace.samples.map(\.addresses.count) == [2, 2, 3, 1, 1])
  let table = ProcessTable(text: """
    sampling 2000
    process 40 3 net
    map 40 0x10000 0x1000 0x5000 bootfs
    process 41 4 idle one
    """)
  #expect(table.hz == 2000 && table.processes.map(\.name) == ["net", "idle one"])
  #expect(ProcessTable.location(0x1_0010, in: table.processes[0]) == CodeLocation(image: "bootfs", offset: 0x5010))
  #expect(ProcessTable.location(k | 0x40, in: nil) == CodeLocation(image: "kernel", offset: 0x40))
  #expect(ProcessTable.location(0x2_0000, in: table.processes[0]) == nil)

  var returns: [Bool] = []
  let profile = Profile(trace: trace, processes: table) { at, isReturn in
    if at.image == "bootfs" { returns.append(isReturn) }
    let names: [UInt64: String] = [0x5010: "loop", 0x5020: "loop", 0x5030: "loop", 0x5105: "main"]
    if at.image == "kernel" { return Profile.Frame(function: at.offset == 0x40 ? "syscall" : "timer", image: "kernel") }
    return names[at.offset].map { Profile.Frame(function: $0, image: "bin/net") }
  }
  #expect(returns == [false, true, false, true, true, true])
  #expect(profile.samples == 5 && profile.hz == 2000)
  #expect(profile.processes.map { "\($0.name) \($0.samples)" } == ["net 3", "kernel 1", "task 9 1"])
  let net = profile.functions.filter { $0.process == "net" }.map { "\($0.frame.function) \($0.own) \($0.inclusive)" }
  #expect(net == ["loop 2 3", "syscall 1 1", "main 0 3"])
  #expect(profile.functions.contains { $0.frame.function == "0x7777" && $0.frame.image == "?" })
  #expect(profile.folded.map { "\($0.stack) \($0.count)" }
    == ["kernel;timer 1", "net;main;loop 2", "net;main;loop;syscall 1", "task 9;0x7777 1"])
}
