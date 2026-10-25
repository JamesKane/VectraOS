// SPDX-License-Identifier: BSD-3-Clause

// bin/trace-test: a recording on croi (V2, D50). The program is its own
// traced process: it starts a TraceSession with the root resource and the
// kernel's IPC category, records into the region the session made (zones,
// a counter, marks, and FLOW steps of a channel message), stops, and
// checks both recordings: its region's records, each a one ring read back
// compacted, and the kernel's CHANNEL_WRITE and CHANNEL_READ joined to its
// FLOW by croi's flow id. Then it exports both over the console (td-trace
// lines), which `vx trace collect` reassembles. userboot starts it
// (userboot.next=bin/trace-test, the boot-trace test); it exits 0 if every
// check passed.

import Ring
import Sys
import Trace
import TraceSession

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("trace-test: FAILED: \(name)")
  }
}

let work = TraceName("work")
let depth = TraceName("depth")
let message = TraceName("message")

/// A compacted trace file's records (the session's export): every ring's,
/// read through a one ring reader. Kinds and first arguments only.
func records(_ file: [UInt8]) -> [(kind: UInt16, a: UInt64)] {
  func u32(_ at: Int) -> UInt32 { file.withUnsafeBytes { unsafe $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
  func u64(_ at: Int) -> UInt64 { file.withUnsafeBytes { unsafe $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) } }
  guard file.count >= TraceFormat.headerSize, u32(0) == TraceFormat.regionMagic, u32(4) == TraceFormat.version
  else { return [] }
  let ringsAt = Int(u64(TraceFormat.ringsOffset)), ringSize = Int(u64(TraceFormat.ringSize))
  let bytes = ringSize - TraceFormat.ringHeaderSize
  var out: [(kind: UInt16, a: UInt64)] = []
  let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128)
  defer { unsafe memory.deallocate() }
  for i in 0..<Int(u32(TraceFormat.ringsClaimed)) {
    let at = ringsAt + i * ringSize + TraceFormat.ringHeaderSize
    unsafe file.withUnsafeBytes { unsafe memory.copyMemory(from: $0.baseAddress! + at, byteCount: bytes) }
    guard var reader = unsafe NativeRing(attaching: memory, size: bytes, producer: false,
                                         slotSize: TraceFormat.slotSize, format: TraceFormat.ringFormat,
                                         flags: RingLayout.overwrite) else { continue }
    var slot = InlineArray<5, UInt64>(repeating: 0)
    var dropped: UInt64 = 0
    while unsafe withUnsafeMutableBytes(of: &slot, { unsafe reader.read(to: $0.baseAddress!, dropped: &dropped) }) {
      out.append((UInt16(truncatingIfNeeded: slot[2]), slot[3]))
    }
  }
  return out
}

@main
struct TraceTest {
  static func main() {
    guard let resource = Startup.current.take(ProcessArgs.info(ProcessArgs.resource))?.release() else {
      print("trace-test: no root resource")
      Process.exit(code: 1)
    }
    let session: TraceSession
    do throws(Status) {
      session = try TraceSession(resource: resource, categories: [.app, .mark, .ipc],
                                 kernel: TraceSession.Kernel.ipc, pagesPerCPU: 16)
    } catch {
      print("trace-test: no session: \(error.rawValue)")
      Process.exit(code: 1)
    }
    guard let region = session.region(for: "trace-test") else {
      print("trace-test: no region")
      Process.exit(code: 1)
    }
    check(Trace.start(region: Handle(raw: region.handle)), "recording into the session's region")

    // A message's two steps, as an IPC library would write them: FLOW
    // records with croi's flow id, which the kernel's join.
    var flow: UInt64 = 0
    do throws(Status) {
      let ends = try Channel.create()
      let info = try ends.a.info()
      let txid: UInt32 = 0x1234_5678
      flow = flowID(channel: min(info.koid, info.relatedKoid), txid: txid)
      Trace.flow(flow, message, .ipc)
      try Channel.write(ends.a, bytes: [0x78, 0x56, 0x34, 0x12, 1, 2, 3, 4])
      _ = try Channel.read(ends.b)
      Trace.flow(flow, message, .ipc)
    } catch {
      check(false, "a channel message")
    }
    Trace.mark("begin")
    for i in 0..<10 {
      Trace.zone(work) { _ = (0..<100).reduce(0, &+) }
      Trace.counter(depth, Int64(i))
    }
    Trace.mark("end")
    session.stop()

    let mine = records(session.file(of: "trace-test") ?? [])
    func count(_ kind: TraceKind) -> Int { mine.filter { $0.kind == kind.rawValue }.count }
    check(count(.zone) == 10 && count(.counter) == 10 && count(.mark) == 2, "the region's zones, counters and marks")
    check(mine.filter { $0.kind == TraceKind.flow.rawValue && $0.a == flow }.count == 2, "the message's two steps")
    let kernel = records(session.kernelTrace())
    check(kernel.contains { $0.kind == UInt16(CROI_TK_CHANNEL_WRITE) && $0.a == flow }
            && kernel.contains { $0.kind == UInt16(CROI_TK_CHANNEL_READ) && $0.a == flow },
          "the kernel's write and read, on the same flow")

    session.export { print($0) }
    print("trace-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
