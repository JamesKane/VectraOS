// SPDX-License-Identifier: BSD-3-Clause

// What a driver host takes from its device's grants and what it does when its
// supplies end (D170, D173): the info word of each interrupt by its index, a
// host's interrupts asked for by index, and the steps a driver adds to run
// before the host exits.

import DriverHost
import Sys
import Testing

private let modes: [Interrupt.Mode] = [.default, .edgeLow, .edgeHigh, .levelLow, .levelHigh]

@Test func theFirstInterruptKeepsItsInfoWordAndLaterOnesNameTheirIndex() {
  for mode in modes {
    // A host that asks for one interrupt is granted what it always was.
    #expect(DeviceHandle.interrupt(index: 0, mode) == DeviceHandle.interrupt(mode))
  }
  // Index 2 (panthor's GPU line) at level-high is not index 1's, nor index 0's.
  let words = [DeviceHandle.interrupt(index: 0, .levelHigh), DeviceHandle.interrupt(index: 1, .levelHigh),
               DeviceHandle.interrupt(index: 2, .levelHigh)]
  #expect(Set(words).count == 3)
  // Three same-mode lines are told apart, in any mode.
  for mode in modes {
    var seen: Set<UInt32> = []
    for index in 0..<DeviceHandle.interruptLimit { seen.insert(DeviceHandle.interrupt(index: index, mode)) }
    #expect(seen.count == DeviceHandle.interruptLimit)
  }
}

@Test func anInterruptsArgumentParsesBackToItsIndexAndMode() {
  for index in 0..<DeviceHandle.interruptLimit {
    for mode in modes {
      let info = DeviceHandle.interrupt(index: index, mode)
      let argument = info >> 16
      let parsed = DeviceHandle.parseInterrupt(argument: argument)
      #expect(parsed?.index == index)
      #expect(parsed?.mode == mode)
    }
  }
  // Nothing else is an interrupt.
  #expect(DeviceHandle.parseInterrupt(argument: DeviceHandle.dmaBTI) == nil)
  #expect(DeviceHandle.parseInterrupt(argument: DeviceHandle.bar(3) >> 16) == nil)
  #expect(DeviceHandle.parseInterrupt(argument: DeviceHandle.indexedInterruptBase + 0x100) == nil)
  #expect(DeviceHandle.parseInterrupt(argument: DeviceHandle.indexedInterruptBase + 1) == nil)  // mode 1 is none
}

@Test func theStepsRunOnceLastAddedFirst() {
  let ending = HostShutdown()
  final class Log: @unchecked Sendable {
    let lock = Lock()
    var names: [String] = []
  }
  let log = Log()
  ending.add("a") { log.lock.withLock { log.names.append("a") } }
  ending.add("b") { log.lock.withLock { log.names.append("b") } }
  #expect(ending.names == ["b", "a"])
  #expect(ending.run() == ["b", "a"])
  #expect(log.names == ["b", "a"])
  // The end is one end: a second run does nothing.
  #expect(ending.run().isEmpty)
  #expect(log.names == ["b", "a"])
}

@Test func aHostWithNoStepsEndsWithNoneRun() {
  #expect(HostShutdown().run().isEmpty)
}
