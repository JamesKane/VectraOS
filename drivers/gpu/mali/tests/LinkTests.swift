// SPDX-License-Identifier: BSD-3-Clause

// The scheduler's link over the CSF interface (Link.swift; panthor 07
// section 7.3, 7.4, 7.9 and 7.10, 05 section 5.8) against the model firmware:
// a group bound and started or resumed, its priorities, suspended and
// terminated, the ring's words and INSERT, the sync objects, what a JOB
// interrupt carries, the faults acknowledged, the watchdog, and the halt
// before the power goes.

import Mali
import Testing

/// The world a link runs in: the model firmware over a section, queue memory
/// of byte arrays, a clock whose pauses are the firmware's steps.
final class LinkWorld: LinkMemory, GPUClock {
  typealias Memory = ByteMemory
  let section: ByteMemory
  var fw: ModelFirmware<ByteMemory>
  let bell = Bell()
  let layout: CSFLayout
  let pagesBase: Int
  var time: Int64 = 1_000
  /// A firmware that does nothing when the host waits for it.
  var firmwareRuns = true
  var queues: [Int: LinkQueueMemory<ByteMemory>] = [:]
  var nextPage = 0

  init(_ config: ModelConfig = ModelConfig(version: CSFVersion(3, 13, 0), groups: 4, streams: 8)) {
    let probe = ModelFirmware(memory: ByteMemory(size: 0), config: config)
    pagesBase = (probe.interfaceEnd + 0xFFF) & ~0xFFF
    section = ByteMemory(size: pagesBase + config.groups * config.streams * 0x2000)
    fw = ModelFirmware(memory: section, config: config)
    fw.boot()
    layout = try! CSFLayout.discover(section)
  }

  func now() -> Int64 { time }
  func pause(nanoseconds: Int64) {
    time += nanoseconds
    if firmwareRuns { fw.step() }
  }

  func queue(group: Int, queue: Int) -> LinkQueueMemory<ByteMemory>? {
    let key = group * 64 + queue
    if let q = queues[key] { return q }
    precondition(nextPage < fw.config.groups * fw.config.streams, "the model has pages for so many queues")
    let offset = pagesBase + nextPage * 0x2000
    nextPage += 1
    let q = LinkQueueMemory(ring: ByteMemory(size: 0x1000), ringVA: 0x4000_0000 + UInt64(key) * 0x1000, ringSize: 0x1000,
                            control: section, controlOffset: offset, controlVA: UInt64(CSF.Section.base) + UInt64(offset),
                            sync: ByteMemory(size: 0x40), syncOffset: queue * 16)
    queues[key] = q
    return q
  }

  func suspendBuffers(group: Int) -> (normal: UInt64, protected: UInt64) {
    (0x0500_0000 + UInt64(group) * 0x20000, 0x0500_0000 + UInt64(group) * 0x20000 + 0x10000)
  }

  func link() -> LinkBox {
    LinkBox(CSFLink(host: CSFHost(memory: section, layout: layout), door: bell, memory: self, clock: self,
                    policy: LinkPolicy(shaderPresent: 0x55_0555, tilerPresent: 1)))
  }

  /// Steps the firmware until it has nothing left to do, and the JOB interrupt it raised.
  func settle() -> UInt32 {
    var guardCount = 0
    while fw.step() && guardCount < 100 { guardCount += 1 }
    return fw.takeInterrupts()
  }
}

/// The link as a reference, since `#expect` can't take a call on a mutable value.
final class LinkBox {
  var link: CSFLink<ByteMemory, Bell, LinkWorld, LinkWorld>
  init(_ link: CSFLink<ByteMemory, Bell, LinkWorld, LinkWorld>) { self.link = link }
  var csgSlotCount: Int { link.csgSlotCount }
  var queuesPerGroup: Int { link.queuesPerGroup }
  var log: [String] { link.log }
  var journalLines: [String] { link.journal.lines }
  var nextWatchdog: Int64 { link.nextWatchdog }
  func program(csg: Int, group: LinkGroupProgram) -> Bool { link.program(csg: csg, group: group) }
  func setPriorities(_ u: [LinkPriorityUpdate]) -> Bool { link.setPriorities(u) }
  func suspend(csg: Int) -> Bool { link.suspend(csg: csg) }
  func terminate(csg: Int) -> Bool { link.terminate(csg: csg) }
  func statusUpdate() -> Bool { link.statusUpdate() }
  func events(jobStatus: UInt32) -> [LinkEvent] { link.events(jobStatus: jobStatus) }
  func watchdog() -> LinkEvent? { link.watchdog() }
  func rebooted(host: CSFHost<ByteMemory>) { link.rebooted(host: host) }
  func storeRing(group: Int, queue: Int, byteOffset: Int, word: UInt64) {
    link.storeRing(group: group, queue: queue, byteOffset: byteOffset, word: word)
  }
  func publishInsert(group: Int, queue: Int, insert: UInt64) { link.publishInsert(group: group, queue: queue, insert: insert) }
  func readSync(group: Int, queue: Int) -> SyncRecord { link.readSync(group: group, queue: queue) }
  func writeSync(group: Int, queue: Int, record: SyncRecord) { link.writeSync(group: group, queue: queue, record: record) }
  func ringDoorbell(csg: Int) { link.ringDoorbell(csg: csg) }
  func acknowledgeFault(csg: Int, queue: Int) { link.acknowledgeFault(csg: csg, queue: queue) }
  func tilerOOMReport(csg: Int, queue: Int) -> TilerOOMReport { link.tilerOOMReport(csg: csg, queue: queue) }
  func replyTilerHeap(csg: Int, queue: Int, chunk: UInt64) { link.replyTilerHeap(csg: csg, queue: queue, chunk: chunk) }
  func queueStatus(csg: Int, queue: Int) -> LinkQueueStatus { link.queueStatus(csg: csg, queue: queue) }
}

func program(_ group: Int, queues: Int = 1, priority: Int = 7, resume: Bool = false, asSlot: Int = 1) -> LinkGroupProgram {
  var qs: [LinkQueueProgram] = []
  for i in 0..<queues { qs.append(LinkQueueProgram(ringSize: 0x1000, insert: 0, extract: 0, priority: 3 + i)) }
  return LinkGroupProgram(group: group, addressSpace: asSlot, priority: priority, resume: resume, queues: qs)
}

@Test func aGroupIsBoundWithItsQueuesThenItsSlotAndStarted() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.csgSlotCount == 4)
  #expect(link.queuesPerGroup == 8)
  #expect(link.program(csg: 2, group: program(5, queues: 2, priority: 9, asSlot: 3)))
  let host = CSFHost(memory: w.section, layout: w.layout)
  #expect(host.csgAckState(2) == .started)
  // The queue's slots: the ring, its control pages, its priority and the doorbell CSG slot + 1.
  for i in 0..<2 {
    let q = w.queue(group: 5, queue: i)!
    let cs = w.layout.groups[2].streams[i]
    #expect(w.section.load64(cs.input + CSF.StreamInput.base) == q.ringVA)
    #expect(w.section.load32(cs.input + CSF.StreamInput.size) == 0x1000)
    #expect(w.section.load64(cs.input + CSF.StreamInput.userInput) == q.controlVA)
    #expect(w.section.load64(cs.input + CSF.StreamInput.userOutput) == q.controlVA + 0x1000)
    let config = w.section.load32(cs.input + CSF.StreamInput.config)
    #expect(config & 0xF == UInt32(3 + i))
    #expect(config >> 8 & 0xFF == 3)
    #expect(w.section.load32(cs.input + CSF.StreamInput.req) & CSF.StreamReq.stateMask == CSF.StreamReq.start)
  }
  // The slot: the address space, the suspend buffers, the endpoint's priority and the allowed cores.
  let gl = w.layout.groups[2]
  #expect(w.section.load32(gl.input + CSF.GroupInput.config) == 3)
  #expect(w.section.load64(gl.input + CSF.GroupInput.suspendBuf) == 0x0500_0000 + 5 * 0x20000)
  #expect(w.section.load64(gl.input + CSF.GroupInput.protmSuspendBuf) == 0x0500_0000 + 5 * 0x20000 + 0x10000)
  #expect(w.section.load64(gl.input + CSF.GroupInput.allowCompute) == 0x55_0555)
  #expect(w.section.load32(gl.input + CSF.GroupInput.allowOther) == 1)
  #expect(w.fw.applied.endpoints[2].priority == 9)
  #expect(w.fw.applied.endpoints[2].compute == 10)
  #expect(w.fw.applied.endpoints[2].tiler == 1)
  // The doorbell 0 was rung for the group; the slot is taken until it leaves.
  #expect(w.bell.rings.contains(CSF.Section.globalDoorbell))
  #expect(!link.program(csg: 2, group: program(6)))
}

@Test func aSuspendedGroupIsResumedNotStarted() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1)))
  #expect(link.suspend(csg: 0))
  #expect(w.fw.groupState[0] == CSF.GroupState.suspend)
  #expect(link.program(csg: 1, group: program(1, resume: true)))
  #expect(w.fw.groupState[1] == CSF.GroupState.resume)
}

@Test func suspendingAndTerminatingStopEachStreamAndFreeTheSlot() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 1, group: program(2, queues: 3)))
  #expect(link.suspend(csg: 1))
  for s in 0..<3 {
    let cs = w.layout.groups[1].streams[s]
    #expect(w.section.load32(cs.input + CSF.StreamInput.req) & CSF.StreamReq.stateMask == CSF.StreamReq.stop)
  }
  // A suspended slot isn't suspended again; it takes another group.
  #expect(!link.suspend(csg: 1))
  #expect(link.program(csg: 1, group: program(3)))
  #expect(link.terminate(csg: 1))
  #expect(w.fw.groupState[1] == CSF.GroupState.terminate)
}

@Test func aSlotTheFirmwareNeverAnswersFailsAfter100ms() {
  let w = LinkWorld()
  let link = w.link()
  w.firmwareRuns = false
  let before = w.time
  #expect(!link.program(csg: 0, group: program(1)))
  #expect(w.time - before >= 100_000_000)
  #expect(w.time - before < 110_000_000)
  #expect(link.log.last?.contains("did not acknowledge") == true)
  // Nothing is bound, so nothing is suspended.
  #expect(!link.suspend(csg: 0))
}

@Test func prioritiesAreWrittenForEverySlotThenAcknowledged() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1, priority: 3)))
  #expect(link.program(csg: 1, group: program(2, priority: 4)))
  #expect(link.setPriorities([LinkPriorityUpdate(csg: 0, priority: 12), LinkPriorityUpdate(csg: 1, priority: 11)]))
  #expect(w.fw.applied.endpoints[0].priority == 12)
  #expect(w.fw.applied.endpoints[1].priority == 11)
  // An update for a slot that holds no group is refused.
  #expect(!link.setPriorities([LinkPriorityUpdate(csg: 3, priority: 1)]))
}

@Test func aRingsWordsAndInsertReachTheFirmwareAndItsDrainIsASyncUpdate() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1)))
  _ = w.settle()
  let q = w.queue(group: 1, queue: 0)!
  link.storeRing(group: 1, queue: 0, byteOffset: 0, word: 0xAABB_CCDD_1122_3344)
  link.storeRing(group: 1, queue: 0, byteOffset: 8, word: 0x55)
  // A word at the ring's end wraps to the start.
  link.storeRing(group: 1, queue: 0, byteOffset: 0x1000 + 16, word: 0x66)
  #expect(q.ring.load64(0) == 0xAABB_CCDD_1122_3344)
  #expect(q.ring.load64(8) == 0x55)
  #expect(q.ring.load64(16) == 0x66)
  link.publishInsert(group: 1, queue: 0, insert: 64)
  #expect(q.control.load64(q.controlOffset + CSF.RingInput.insert) == 64)
  link.ringDoorbell(csg: 0)
  #expect(w.bell.rings.last == 1)
  let status = w.settle()
  #expect(status & 1 == 1)
  // The sync object the GPU would have raised.
  link.writeSync(group: 1, queue: 0, record: SyncRecord(sequence: 3, status: 0))
  #expect(link.readSync(group: 1, queue: 0) == SyncRecord(sequence: 3, status: 0))
  link.writeSync(group: 1, queue: 0, record: SyncRecord(sequence: 4, status: SyncRecord.terminatedStatus))
  #expect(link.readSync(group: 1, queue: 0).status == SyncRecord.terminatedStatus)
  let events = link.events(jobStatus: status)
  #expect(events == [.syncUpdate(csg: 0)])
  // The queue's status: the firmware's EXTRACT, not blocked.
  let st = link.queueStatus(csg: 0, queue: 0)
  #expect(st.extract == 64)
  #expect(st.blockedReason == 0)
  // The events were acknowledged: a second look finds none.
  #expect(link.events(jobStatus: 1).isEmpty)
}

@Test func aSyncRecordOfTheSlotsOwnQueueIsReadFromItsOwnObject() {
  let w = LinkWorld()
  let link = w.link()
  link.writeSync(group: 1, queue: 0, record: SyncRecord(sequence: 1))
  link.writeSync(group: 1, queue: 2, record: SyncRecord(sequence: 9))
  #expect(link.readSync(group: 1, queue: 0).sequence == 1)
  #expect(link.readSync(group: 1, queue: 2).sequence == 9)
  // Sync objects are 16 bytes each: the second 8 bytes' padding is zero.
  let q = w.queue(group: 1, queue: 2)!
  #expect(q.sync.load32(q.syncOffset + 12) == 0)
}

@Test func aCSFaultIsReportedWhereTheStreamWasAndAcknowledgedOnRequest() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 1, group: program(7, queues: 2)))
  _ = link.events(jobStatus: w.settle())  // the start's own acknowledgements: no events
  w.fw.raiseStreamFault(1, 1, type: 0x49, data: 0x1234, info: 0xABCD)
  let events = link.events(jobStatus: w.fw.takeInterrupts())
  #expect(events == [.csFault(csg: 1, queue: 1, extract: 0)])
  #expect(link.log.last?.contains("CS_INSTR_INVALID") == true)
  // The fault stays until the scheduler has noted it; then the stream is let go.
  let cs = w.layout.groups[1].streams[1]
  func pending() -> UInt32 {
    ReqAck.pending(req: w.section.load32(cs.input + CSF.StreamInput.req),
                   ack: w.section.load32(cs.output + CSF.StreamOutput.ack), mask: CSF.StreamReq.fault)
  }
  #expect(pending() != 0)
  link.acknowledgeFault(csg: 1, queue: 1)
  #expect(pending() == 0)
  _ = w.settle()
  #expect(link.events(jobStatus: 2).isEmpty)
}

@Test func aFatalErrorIsAcknowledgedAndUnrecoverableOnesAreTold() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1, queues: 2)))
  _ = link.events(jobStatus: w.settle())  // the start's own acknowledgements: no events
  w.fw.raiseStreamFatal(0, 0, type: 0x48, data: 1, info: 2)
  w.fw.raiseStreamFatal(0, 1, type: 0x41)
  let events = link.events(jobStatus: w.fw.takeInterrupts())
  #expect(events == [.csFatal(csg: 0, queue: 0, unrecoverable: false), .csFatal(csg: 0, queue: 1, unrecoverable: true)])
  for s in 0..<2 {
    let cs = w.layout.groups[0].streams[s]
    #expect(ReqAck.pending(req: w.section.load32(cs.input + CSF.StreamInput.req),
                           ack: w.section.load32(cs.output + CSF.StreamOutput.ack), mask: CSF.StreamReq.fatal) == 0)
  }
}

@Test func aTilerOOMIsLeftUnacknowledgedUntilTheReplyAndTheReplyIsBothRegisters() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 2, group: program(4, queues: 2)))
  _ = link.events(jobStatus: w.settle())
  w.fw.raiseTilerOOM(2, 1, heapAddress: 0x7F_0000_0000, vtStart: 15, vtEnd: 12, fragEnd: 10)
  let events = link.events(jobStatus: w.fw.takeInterrupts())
  #expect(events == [.tilerOOM(csg: 2, queue: 1)])
  let host = CSFHost(memory: w.section, layout: w.layout)
  func pending() -> UInt32 { host.csEvents(2, 1) & CSF.StreamReq.tilerOOM }
  // Still pending: the interrupt did not acknowledge it, and a second interrupt of the stream names it again.
  #expect(pending() != 0)
  let report = link.link.tilerOOMReport(csg: 2, queue: 1)
  #expect(report == TilerOOMReport(heapAddress: 0x7F_0000_0000, vtStart: 15, vtEnd: 12, fragEnd: 10))
  #expect(report.passesInFlight == 5 && report.passesWaitingForFragment == 2 && report.isConsistent)
  w.fw.raiseStreamFault(2, 1, type: 0x49)
  #expect(link.events(jobStatus: w.fw.takeInterrupts()) == [.tilerOOM(csg: 2, queue: 1), .csFault(csg: 2, queue: 1, extract: 0)])
  link.acknowledgeFault(csg: 2, queue: 1)
  #expect(pending() != 0)
  // The reply: the chunk in both registers, the event acknowledged, the stream's doorbell toggled, the group kicked.
  w.bell.rings.removeAll()
  let pointer = TilerOOMReport.chunk(address: 0x7F_FE40_0000, size: 2 << 20)
  #expect(pointer == 0x7F_FE40_0200)
  link.link.replyTilerHeap(csg: 2, queue: 1, chunk: pointer)
  #expect(pending() == 0 && w.bell.rings.contains(CSF.Section.globalDoorbell))
  _ = w.settle()
  #expect(w.fw.tilerReplies == [TilerReply(group: 2, stream: 1, start: pointer, end: pointer)])
  // Other streams are untouched, and the next OOM is a new event.
  #expect(link.events(jobStatus: 4).isEmpty)
  w.fw.raiseTilerOOM(2, 1, heapAddress: 0x7F_0000_0000, vtStart: 16, vtEnd: 12, fragEnd: 10)
  #expect(link.events(jobStatus: w.fw.takeInterrupts()) == [.tilerOOM(csg: 2, queue: 1)])
  // A refusal is 0 in both.
  link.link.replyTilerHeap(csg: 2, queue: 1, chunk: 0)
  _ = w.settle()
  #expect(w.fw.tilerReplies.last == TilerReply(group: 2, stream: 1, start: 0, end: 0))
}

@Test func aTilerOOMOfAGroupSuspendedBeforeTheReplyIsRaisedAgainAfterItsResume() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1)))
  _ = link.events(jobStatus: w.settle())
  w.fw.raiseTilerOOM(0, 0, heapAddress: 0x1000, vtStart: 3, vtEnd: 2, fragEnd: 1)
  #expect(link.events(jobStatus: w.fw.takeInterrupts()) == [.tilerOOM(csg: 0, queue: 0)])
  #expect(link.suspend(csg: 0))
  _ = w.settle()
  #expect(w.fw.tilerReplies.isEmpty)
  // Resumed on its slot, the firmware raises the event again; the old one was never acknowledged.
  #expect(link.program(csg: 0, group: program(1, resume: true)))
  var again: [LinkEvent] = []
  for _ in 0..<4 { again += link.events(jobStatus: w.settle()) }
  #expect(again == [.tilerOOM(csg: 0, queue: 0)])
}

@Test func theGroupAndGlobalEventsAreEachReportedOnce() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 3, group: program(1)))
  _ = link.events(jobStatus: w.settle())  // the start's own acknowledgements: no events
  let host = CSFHost(memory: w.section, layout: w.layout)
  host.initGlobal(GlobalConfig.boot(shaderPresent: 1, timestampFrequency: nil, coreFrequency: nil), w.bell)
  _ = link.events(jobStatus: w.settle())
  w.fw.raiseGroupEvent(3, CSF.GroupReq.idle | CSF.GroupReq.progressTimerEvent)
  w.fw.raiseGlobalEvent(CSF.GlobalReq.idle)
  let status = w.fw.takeInterrupts()
  #expect(status == 1 << 3 | 1 << 31)
  let events = link.events(jobStatus: status)
  #expect(events == [.globalIdle, .idle(csg: 3), .progressTimeout(csg: 3)])
  #expect(link.events(jobStatus: status).isEmpty)
}

@Test func aCorruptStateIsAnUnknownState() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1)))
  _ = link.events(jobStatus: w.settle())  // the start's own acknowledgements: no events
  let ack = w.layout.groups[0].output + CSF.GroupOutput.ack
  w.section.store32(ack, w.section.load32(ack) & ~7 | 5)
  #expect(link.events(jobStatus: 1) == [.unknownState(csg: 0)])
}

@Test func theWatchdogPingsEveryPeriodAndNamesAnUnansweredOne() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.watchdog() == nil)
  // Not due yet: no ping.
  let req = w.layout.input + CSF.GlobalInput.req
  let before = w.section.load32(req) & CSF.GlobalReq.ping
  w.time += 11_000_000_000
  #expect(link.watchdog() == nil)
  #expect(w.section.load32(req) & CSF.GlobalReq.ping == before)
  // Due: the ping is requested; the firmware answers; the next one is a period on.
  w.time += 2_000_000_000
  #expect(link.watchdog() == nil)
  #expect(w.section.load32(req) & CSF.GlobalReq.ping != before)
  _ = w.settle()
  #expect(link.watchdog() == nil)
  #expect(link.nextWatchdog > w.time)
  // The next ping is never answered.
  w.time = link.nextWatchdog + 1
  #expect(link.watchdog() == nil)
  w.firmwareRuns = false
  w.time += 250_000_000
  #expect(link.watchdog() == .pingTimeout)
  #expect(link.log.last?.contains("did not answer a ping") == true)
}

@Test func theFirmwaresLinesCarryTheirTimesInOrder() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1, queues: 2)))
  _ = link.events(jobStatus: w.settle())
  // A fatal error at 5 ms and an unanswered ping a good while later, 12 345 ms.
  w.time = 5_001_000
  w.fw.raiseStreamFatal(0, 0, type: 0x48, data: 1, info: 2)
  _ = link.events(jobStatus: w.fw.takeInterrupts())
  w.time = 12_100_000_000
  #expect(link.watchdog() == nil)
  w.firmwareRuns = false
  w.time = 12_345_001_000
  #expect(link.watchdog() == .pingTimeout)
  let lines = link.journalLines
  #expect(lines.count == 2)
  #expect(lines[0].hasPrefix("[5 ms] CSG 0 CS 0 FATAL CS_BUS_FAULT"))
  #expect(lines[1].hasPrefix("[12345 ms] the firmware did not answer a ping"))
}

@Test func theFirmwareComingBackLeavesNoSlotBound() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.program(csg: 0, group: program(1)))
  link.rebooted(host: CSFHost(memory: w.section, layout: w.layout))
  #expect(!link.suspend(csg: 0))
  #expect(link.statusUpdate())
}

@Test func theStatusUpdateOfBoundSlotsIsWaitedForTogether() {
  let w = LinkWorld()
  let link = w.link()
  #expect(link.statusUpdate())  // nothing bound: nothing to wait for
  #expect(link.program(csg: 0, group: program(1)))
  #expect(link.program(csg: 2, group: program(2)))
  #expect(link.statusUpdate())
  w.firmwareRuns = false
  #expect(!link.statusUpdate())
}

// MARK: Halting the MCU before its power goes

/// The registers a halt reads: MCU_STATUS reads HALT once the firmware has seen the request.
final class HaltRegs: GPURegisterFile {
  let world: LinkWorld
  var halts = true
  init(_ world: LinkWorld) { self.world = world }
  func barrier() {}
  func load32(_ o: Int) -> UInt32 {
    if o == GPUControlRegister.mcuStatus { return world.fw.halted && halts ? CSF.mcuStatusHalt : 1 }
    return 0
  }
  func store32(_ o: Int, _ v: UInt32) {}
}

@Test(arguments: [CSFVersion(3, 13, 0), CSFVersion(4, 0, 0), CSFVersion(4, 1, 0)])
func theMCUIsHaltedTheWayItsInterfaceVersionSays(_ version: CSFVersion) {
  let w = LinkWorld(ModelConfig(version: version, groups: 4, streams: 8))
  let regs = HaltRegs(w)
  let control = GPUControl(regs: regs, clock: w)
  let host = CSFHost(memory: w.section, layout: w.layout)
  #expect(host.haltMCU(control, door: w.bell, timeout: 500_000_000))
  if version.hasGlobalState {
    #expect(w.section.load32(w.layout.input + CSF.GlobalInput.req) & CSF.GlobalReq.stateMask
      == CSF.GlobalState.halt << CSF.GlobalReq.stateShift)
  } else {
    #expect(w.section.load32(w.layout.input + CSF.GlobalInput.req) & CSF.GlobalReq.halt != 0)
  }
  #expect(w.bell.rings.last == CSF.Section.globalDoorbell)
}

@Test func aMCUThatDoesNotHaltIsGivenUpOnAfterTheTimeout() {
  let w = LinkWorld()
  let regs = HaltRegs(w)
  regs.halts = false
  let control = GPUControl(regs: regs, clock: w)
  let host = CSFHost(memory: w.section, layout: w.layout)
  let before = w.time
  #expect(!host.haltMCU(control, door: w.bell, timeout: 300_000_000))
  #expect(w.time - before >= 300_000_000)
  #expect(w.time - before < 310_000_000)
}
