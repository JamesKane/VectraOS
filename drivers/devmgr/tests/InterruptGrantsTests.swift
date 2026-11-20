// SPDX-License-Identifier: BSD-3-Clause

// The layout of a device's interrupt grants (Grants.swift): each interrupt
// of its description in its place, the first as a host with one interrupt
// always took it, the rest by index (the Mali's JOB, MMU and GPU lines are
// three of one mode).

import DevMgr
import DriverHost
import Sys
import Testing

@Test func aDeviceWithThreeSameModeInterruptsGetsThreeDistinctGrants() {
  let plan = InterruptGrants.plan([(number: 0x10D, mode: .levelHigh), (number: 0x10E, mode: .levelHigh),
                                   (number: 0x10F, mode: .levelHigh)])
  #expect(plan.map { $0.index } == [0, 1, 2])
  #expect(plan.map { $0.number } == [0x10D, 0x10E, 0x10F])
  #expect(Set(plan.map { $0.info }).count == 3)
  // The first is the info word a one-interrupt driver takes.
  #expect(plan[0].info == DeviceHandle.interrupt(.levelHigh))
  // What the host asks for by index is what devmgr grants.
  for g in plan { #expect(g.info == DeviceHandle.interrupt(index: g.index, g.mode)) }
}

@Test func aDeviceWithOneInterruptIsGrantedItAsBefore() {
  let plan = InterruptGrants.plan([(number: 33, mode: .edgeHigh)])
  #expect(plan.count == 1)
  #expect(plan[0].info == DeviceHandle.interrupt(.edgeHigh))
  #expect(InterruptGrants.plan([]).isEmpty)
}

@Test func theModesOfLaterInterruptsAreKept() {
  let plan = InterruptGrants.plan([(number: 1, mode: .levelHigh), (number: 2, mode: .edgeLow), (number: 3, mode: .levelLow)])
  #expect(plan.map { $0.mode } == [.levelHigh, .edgeLow, .levelLow])
  #expect(DeviceHandle.parseInterrupt(argument: plan[1].info >> 16)?.mode == .edgeLow)
  #expect(DeviceHandle.parseInterrupt(argument: plan[2].info >> 16)?.index == 2)
}

@Test func moreInterruptsThanTheLimitAreLeftOut() {
  var many: [(number: UInt32, mode: Interrupt.Mode)] = []
  for n in 0..<40 { many.append((number: UInt32(n), mode: .levelHigh)) }
  let plan = InterruptGrants.plan(many)
  #expect(plan.count == DeviceHandle.interruptLimit)
  #expect(plan.last?.number == UInt32(DeviceHandle.interruptLimit - 1))
}
