// SPDX-License-Identifier: BSD-3-Clause

// A croi recording read as one timeline (M3f): a call's FLOW records at
// both ends join croi's CHANNEL_WRITE, CHANNEL_READ and DONATE by flow id.

import Testing
import TraceFormat
import TraceReader

@Test func aCallJoinsBothEndsAndTheKernel() {
  let flow: UInt64 = 0xF10, other: UInt64 = 0xF20
  let hz: UInt64 = 1_000_000_000  // a tick a nanosecond
  func user(_ time: UInt64, _ id: UInt64) -> TraceRecord {
    TraceRecord(time: time, kind: TraceKind.flow.rawValue, a: id, b: 0)
  }
  func kernel(_ time: UInt64, _ kind: UInt16, _ id: UInt64) -> TraceRecord {
    TraceRecord(time: time, kind: kind, a: id, b: 0)
  }
  let client = TraceFile(counterHz: hz, records: [user(1000, flow), user(9000, flow), user(20000, other)],
                         names: [0: "Node.read"])
  let server = TraceFile(counterHz: hz, records: [user(3000, flow), user(7000, flow)], names: [0: "Node.read"])
  let croi = TraceFile(counterHz: hz, processID: 0, records: [
    kernel(1500, TraceSet.channelWrite, flow), kernel(2500, TraceSet.channelRead, flow),
    kernel(2600, TraceSet.donate, flow), kernel(7500, TraceSet.channelWrite, flow),
  ], names: [:])
  let set = TraceSet([("kernel", croi), ("n0-exit", client), ("fs", server)])

  let joined = set.joinedFlows()
  #expect(joined[flow]?.name == "Node.read")
  #expect(joined[flow]?.steps.map(\.what) == ["n0-exit", "write", "read", "donate", "fs", "fs", "write", "n0-exit"])
  let b = set.breakdown().first { $0.name == "Node.read" }
  #expect(b?.count == 2)  // the call, and another with one step
  #expect(b?.path.count == 8)
  #expect(b?.gaps.first == 500e-9)
  #expect(b?.total == 8000e-9)
}
