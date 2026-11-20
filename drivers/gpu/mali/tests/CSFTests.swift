// SPDX-License-Identifier: BSD-3-Clause

// The CSF interface's layout and protocol (panthor 05 §5.4 to §5.7, 06),
// the host's side run against the model firmware over a byte array.

import Mali
import Testing

final class Bell: CSFDoorbell {
  var rings: [Int] = []
  func ring(_ id: Int) { rings.append(id) }
}

/// A host and a model firmware over one section.
struct Rig {
  let memory: ByteMemory
  var fw: ModelFirmware<ByteMemory>
  let bell = Bell()
  let pagesBase: Int

  init(_ config: ModelConfig = ModelConfig()) {
    let probe = ModelFirmware(memory: ByteMemory(size: 0), config: config)
    pagesBase = (probe.interfaceEnd + 0xFFF) & ~0xFFF
    memory = ByteMemory(size: pagesBase + config.groups * config.streams * 0x2000)
    fw = ModelFirmware(memory: memory, config: config)
    fw.boot()
  }

  func discover() throws(CSFError) -> CSFHost<ByteMemory> {
    CSFHost(memory: memory, layout: try CSFLayout.discover(memory))
  }

  func pages(_ g: Int, _ s: Int) -> RingPages<ByteMemory> {
    let at = pagesBase + (g * fw.config.streams + s) * 0x2000
    return RingPages(memory: memory, input: at, output: at + 0x1000)
  }

  func va(_ offset: Int) -> UInt64 { UInt64(CSF.Section.base) + UInt64(offset) }

  func params(_ g: Int, _ s: Int, doorbell: UInt32 = 1) -> CSParams {
    let p = pages(g, s)
    return CSParams(ringBase: 0x10_0000 + UInt64(s) * 0x1000, ringSize: 0x1000, userInput: va(p.input),
                    userOutput: va(p.output), priority: 3, doorbell: doorbell)
  }

  static let program = CSGProgram(allowCompute: 0xFF, allowFragment: 0xF0, allowOther: 1,
                                  endpoint: EndpointRequest(compute: 8, fragment: 4, tiler: 1, priority: 7),
                                  addressSpace: 2, suspendBuffer: 0x8000_0000, protmSuspendBuffer: 0x8001_0000)

  /// Programs `streams` of group `g` and starts it, and lets the firmware do it.
  mutating func start(_ host: CSFHost<ByteMemory>, _ g: Int, streams: [Int]) throws(CSFError) {
    var mask: UInt32 = 0
    for s in streams {
      try host.csProgram(g, s, params(g, s), pages: pages(g, s))
      mask |= 1 << UInt32(s)
    }
    let w = try host.csgStart(g, Rig.program, streams: mask, resume: false, bell)
    fw.step()
    #expect(host.isDone(w))
  }
}

let versions: [CSFVersion] = [CSFVersion(1, 0, 0), CSFVersion(1, 1, 0), CSFVersion(3, 2, 7), CSFVersion(4, 0, 0),
                              CSFVersion(4, 1, 0)]

// MARK: The words

@Test func aToggleInvertsTheAcknowledgeAndKeepsTheOthers() {
  // 06 §6.3.3: REQ_new = (~ACK & M) | (REQ_old & ~M), so a second toggle before
  // the firmware acts changes nothing and a request is never a plain 1.
  let req: UInt32 = 0b1010_0110, ack: UInt32 = 0b0000_0110
  let once = ReqAck.toggled(req: req, ack: ack, mask: 0b101)
  #expect(once == 0b1010_0011)
  #expect(ReqAck.toggled(req: once, ack: ack, mask: 0b101) == once)
  #expect(ReqAck.pending(req: once, ack: ack, mask: 0b101) == 0b101)
  #expect(ReqAck.set(req: 0xFF00, value: 0x12, mask: 0xFF) == 0xFF12)
  #expect(ReqAck.acknowledged(req: 0, ack: 0b1100, events: 0b0100) == 0b0100)
  #expect(ReqAck.acknowledged(req: 0b1, ack: 0b1100, events: 0b0100) == 0b0101)
}

@Test func aFieldPartlyMatchingIsNotDone() {
  #expect(!ReqAck.complete(ack: 0b010, expected: 0b011, mask: 7))
  #expect(ReqAck.complete(ack: 0b011, expected: 0b011, mask: 7))
  // Bits outside the mask don't count.
  #expect(ReqAck.complete(ack: 0xF3, expected: 0x03, mask: 7))
}

@Test func theVersionGatesAreWhereTheSpecPutsThem() {
  #expect(!CSFVersion(1, 0, 9).hasInstrFeatures && CSFVersion(1, 1, 0).hasInstrFeatures)
  #expect(!CSFVersion(3, 255, 65535).hasEndpointRequest64 && CSFVersion(4, 0, 0).hasEndpointRequest64)
  #expect(!CSFVersion(4, 0, 99).hasGlobalState && CSFVersion(4, 1, 0).hasGlobalState)
  let v = CSFVersion(raw: 0x0402_0007)
  #expect(v.major == 4 && v.minor == 2 && v.patch == 7)
  #expect(CSFVersion(4, 2, 7).raw == 0x0402_0007)
}

@Test func timersEncodeAs1024TickUnits() {
  // 06 §6.4.4's worked example: RK3588's 24 MHz system counter.
  #expect(CSF.timer(microseconds: 10_000, frequency: 24_000_000, source: .timestamp) == 235)
  #expect(CSF.timer(microseconds: 800, frequency: 24_000_000, source: .timestamp) == 19)
  #expect(CSF.timer(microseconds: 800, frequency: 500_000_000, source: .cycles) == 1 << 31 | 391)
  #expect(CSF.timer(microseconds: UInt64.max, frequency: UInt64.max, source: .timestamp) == 0x7FFF_FFFF)
  #expect(CSF.timer(microseconds: 1 << 40, frequency: 1_000_000_000, source: .cycles) == 0xFFFF_FFFF)
  let c = GlobalConfig.boot(shaderPresent: 0x55_0555, timestampFrequency: 24_000_000, coreFrequency: nil)
  #expect(c.pwroffTimer == 235 && c.idleTimer == 19 && c.progressTimer == 2_560_000 && c.allocEn == 0x55_0555)
  #expect(GlobalConfig.boot(shaderPresent: 1, timestampFrequency: nil, coreFrequency: nil).pwroffTimer == 0xFFFF_FFFF)
  #expect(GlobalConfig.boot(shaderPresent: 1, timestampFrequency: nil, coreFrequency: 500_000_000).idleTimer >> 31 == 1)
}

@Test func theEndpointRequestRoundTrips() {
  let ep = EndpointRequest(compute: 8, fragment: 4, tiler: 1, exclusiveFragment: true, priority: 15)
  #expect(ep.raw == 0xF021_0408)
  #expect(EndpointRequest(raw: ep.raw) == ep)
  // A field past its width does not carry into the next.
  #expect(EndpointRequest(compute: 0x1FF, priority: 0x1F).raw == 0xF000_00FF)
}

@Test func theAckMaskIsTheSpecs() {
  #expect(CSF.globalAckIrqMask(CSFVersion(4, 0, 0)) == 0x0400_050E)
  #expect(CSF.globalAckIrqMask(CSFVersion(4, 1, 0)) == 0x0400_750E)
}

@Test func blocksAreAsLargeAsTheSpecSays() {
  #expect(CSF.GlobalInput.minSize == 0x84 && CSF.GlobalOutput.minSize == 0x1C)
  #expect(CSF.GroupInput.minSize == 0x58 && CSF.GroupOutput.minSize == 0x20)
  #expect(CSF.StreamInput.minSize == 0x58 && CSF.StreamOutput.minSize == 0xD8)
  #expect(CSF.GlobalControl.size == 0x20 && CSF.GroupControl.size == 0x1C && CSF.StreamControl.size == 0x0C)
  #expect(CSF.GroupInput.epReq == 0x34 && CSF.GroupInput.epReq64 == 0x38)
}

// MARK: Discovery

@Test(arguments: versions)
func discoveryFindsWhatTheFirmwarePublished(_ version: CSFVersion) throws {
  let rig = Rig(ModelConfig(version: version, groups: 4, streams: 8))
  let layout = try CSFLayout.discover(rig.memory)
  // GLB_INSTR_FEATURES below 1.1.0 holds junk that discovery reads as 0.
  #expect(layout == rig.fw.layout)
  #expect(layout.version == version)
  #expect(layout.groupCount == 4 && layout.streamCount == 8 && layout.workRegisters == 96)
  #expect(layout.instrFeatures == (version.hasInstrFeatures ? 0x5 : 0))
  #expect(rig.memory.load32(CSF.GlobalControl.instrFeatures) == (version.hasInstrFeatures ? 0x5 : 0xDEAD_BEEF))
  #expect(layout.groups[2].streams[3].control == layout.groups[2].control + 0x40 + 3 * 0x20)
  #expect(layout.groups[3].control == 0x1000 + 3 * layout.groupStride)
}

@Test func discoveryHandlesTheLimits() throws {
  let most = Rig(ModelConfig(groups: 31, streams: 32))
  let layout = try CSFLayout.discover(most.memory)
  #expect(layout.groupCount == 31 && layout.streamCount == 32)
  let least = Rig(ModelConfig(groups: 3, streams: 8))
  #expect(try CSFLayout.discover(least.memory).groupCount == 3)
}

@Test func anInterfaceNotBootedIsRefused() {
  let blank = ByteMemory(size: 0x4000)
  #expect(throws: CSFError.notBooted) { try CSFLayout.discover(blank) }
  #expect(throws: CSFError.sectionTooSmall) { try CSFLayout.discover(ByteMemory(size: 0x1C)) }
}

@Test func malformedInterfacesAreRefused() {
  func bad(_ expected: CSFError, _ spoil: (ByteMemory, CSFLayout) -> Void, _ comment: Comment? = nil) {
    let rig = Rig(ModelConfig(groups: 4, streams: 8))
    spoil(rig.memory, rig.fw.layout)
    #expect(throws: expected, comment) { try CSFLayout.discover(rig.memory) }
  }
  let base = CSF.Section.base
  // An address below the section.
  bad(.outsideSection(.globalInput, group: 0, stream: 0), { m, _ in m.store32(CSF.GlobalControl.inputVA, base - 4) })
  bad(.outsideSection(.globalInput, group: 0, stream: 0), { m, _ in m.store32(CSF.GlobalControl.inputVA, 0) })
  // A block that starts inside and ends past it, by one word, and one that starts at the end.
  bad(.outsideSection(.globalOutput, group: 0, stream: 0), { m, _ in
    m.store32(CSF.GlobalControl.outputVA, base + UInt32(m.size - CSF.GlobalOutput.minSize + 4))
  })
  bad(.outsideSection(.globalInput, group: 0, stream: 0), { m, _ in
    m.store32(CSF.GlobalControl.inputVA, base + UInt32(m.size))
  })
  bad(.outsideSection(.globalInput, group: 0, stream: 0), { m, _ in m.store32(CSF.GlobalControl.inputVA, 0xFFFF_FFFC) })
  // Unaligned.
  bad(.outsideSection(.globalInput, group: 0, stream: 0), { m, l in m.store32(CSF.GlobalControl.inputVA, base + UInt32(l.input) + 2) })
  // Too small: a CSG's output with room for 0x1C of its 0x20 bytes.
  bad(.outsideSection(.groupOutput, group: 2, stream: 0), { m, l in
    m.store32(l.groups[2].control + CSF.GroupControl.outputVA, base + UInt32(m.size - 0x1C))
  })
  bad(.outsideSection(.groupInput, group: 1, stream: 0), { m, l in
    m.store32(l.groups[1].control + CSF.GroupControl.inputVA, base + UInt32(m.size - 0x54))
  })
  bad(.outsideSection(.streamInput, group: 3, stream: 5), { m, l in
    m.store32(l.groups[3].streams[5].control + CSF.StreamControl.inputVA, base - 0x100)
  })
  bad(.outsideSection(.streamOutput, group: 0, stream: 7), { m, l in
    m.store32(l.groups[0].streams[7].control + CSF.StreamControl.outputVA, base + UInt32(m.size - 0xD4))
  })
  // The counts.
  bad(.groupCount(2), { m, _ in m.store32(CSF.GlobalControl.groupNum, 2) })
  bad(.groupCount(32), { m, _ in m.store32(CSF.GlobalControl.groupNum, 32) })
  bad(.groupCount(0), { m, _ in m.store32(CSF.GlobalControl.groupNum, 0) })
  bad(.streamCount(group: 0, count: 7), { m, l in m.store32(l.groups[0].control + CSF.GroupControl.streamNum, 7) })
  bad(.streamCount(group: 2, count: 33), { m, l in m.store32(l.groups[2].control + CSF.GroupControl.streamNum, 33) })
  // A control block outside the section.
  bad(.outsideSection(.groupControl, group: 1, stream: 0), { m, _ in m.store32(CSF.GlobalControl.groupStride, 0x1000_0000) })
  bad(.outsideSection(.groupControl, group: 0, stream: 0), { m, _ in m.store32(CSF.GlobalControl.groupStride, 0x1002) })
  bad(.outsideSection(.streamControl, group: 0, stream: 1), { m, l in
    m.store32(l.groups[0].control + CSF.GroupControl.streamStride, 0x1000_0000)
  })
  bad(.outsideSection(.streamControl, group: 1, stream: 0), { m, l in
    m.store32(l.groups[1].control + CSF.GroupControl.streamStride, 0x2)
  })
  // Slots that differ.
  bad(.mismatch(.groupFeatures, group: 2, stream: 0), { m, l in m.store32(l.groups[2].control + CSF.GroupControl.features, 0x7) })
  bad(.mismatch(.suspendSize, group: 1, stream: 0), { m, l in m.store32(l.groups[1].control + CSF.GroupControl.suspendSize, 0x1000) })
  bad(.mismatch(.protmSuspendSize, group: 3, stream: 0), { m, l in
    m.store32(l.groups[3].control + CSF.GroupControl.protmSuspendSize, 0)
  })
  bad(.mismatch(.streamNum, group: 1, stream: 0), { m, l in m.store32(l.groups[1].control + CSF.GroupControl.streamNum, 9) })
  bad(.mismatch(.streamFeatures, group: 2, stream: 4), { m, l in
    m.store32(l.groups[2].streams[4].control + CSF.StreamControl.features, 0x7_0000)
  })
}

// MARK: The global interface

@Test(arguments: versions)
func theGlobalInitializationIsAppliedAndAcknowledged(_ version: CSFVersion) throws {
  var rig = Rig(ModelConfig(version: version))
  let host = try rig.discover()
  let config = GlobalConfig.boot(shaderPresent: 0x55_0555, timestampFrequency: 24_000_000, coreFrequency: nil)
  let wait = host.initGlobal(config, rig.bell)
  #expect(rig.bell.rings == [0])
  #expect(!host.isDone(wait))
  // The level bits are set, the three toggles pending.
  #expect(host.glbReq & CSF.GlobalReq.levels == CSF.GlobalReq.idleEnable | CSF.GlobalReq.counterEnable)
  #expect(ReqAck.pending(req: host.glbReq, ack: host.glbAck, mask: CSF.GlobalReq.toggles)
          == CSF.GlobalReq.cfgAllocEn | CSF.GlobalReq.cfgPwroffTimer | CSF.GlobalReq.cfgProgressTimer)
  #expect(rig.memory.load32(rig.fw.layout.input + CSF.GlobalInput.ackIrqMask) == CSF.globalAckIrqMask(version))
  rig.fw.step()
  #expect(host.isDone(wait))
  #expect(rig.fw.applied.allocEn == 0x55_0555)
  #expect(rig.fw.applied.pwroffTimer == 235 && rig.fw.applied.idleTimer == 19 && rig.fw.applied.progressTimer == 2_560_000)
  let irq = rig.fw.takeInterrupts()
  #expect(irq == 1 << 31)
  // Nothing more to do: a second step changes nothing.
  let more = rig.fw.step()
  #expect(!more)
}

@Test func aPingIsAcknowledgedAndAnotherIsAgain() throws {
  var rig = Rig()
  let host = try rig.discover()
  let first = host.ping(rig.bell)
  #expect(!host.isDone(first))
  rig.fw.step()
  #expect(host.isDone(first))
  let second = host.ping(rig.bell)
  #expect(!host.isDone(second))
  #expect(host.spin(second, spins: 3) == false)
  rig.fw.step()
  #expect(host.isDone(second))
  #expect(rig.bell.rings == [0, 0])
  #expect(rig.fw.performed == 2)
}

@Test func haltBeforeAndFrom41() throws {
  // Before 4.1: the HALT bit, never acknowledged; MCU_STATUS alone says it.
  var old = Rig(ModelConfig(version: CSFVersion(4, 0, 0)))
  let oldHost = try old.discover()
  oldHost.requestHalt(old.bell)
  old.fw.step()
  #expect(old.fw.halted)
  #expect(oldHost.glbAck & CSF.GlobalReq.halt == 0)
  #expect(!oldHost.haltComplete(mcuStatus: 0) && oldHost.haltComplete(mcuStatus: 2))
  oldHost.clearHalt()
  old.fw.step()
  #expect(!old.fw.halted)
  // From 4.1: the state field; done when MCU_STATUS is HALT and the ACK's state is.
  var new = Rig(ModelConfig(version: CSFVersion(4, 1, 0)))
  let newHost = try new.discover()
  newHost.requestHalt(new.bell)
  #expect(!newHost.haltComplete(mcuStatus: 2))
  new.fw.step()
  #expect(new.fw.halted)
  #expect(newHost.glbAck & CSF.GlobalReq.stateMask == 1 << 12)
  #expect(newHost.haltComplete(mcuStatus: 2) && !newHost.haltComplete(mcuStatus: 1))
  newHost.clearHalt()
  new.fw.step()
  #expect(!new.fw.halted && newHost.glbAck & CSF.GlobalReq.stateMask == 0)
}

@Test func theGlobalIdleEventIsAcknowledgedByCopyingItsAck() throws {
  var rig = Rig()
  let host = try rig.discover()
  host.initGlobal(GlobalConfig(allocEn: 1, pwroffTimer: 1, progressTimer: 1, idleTimer: 1), rig.bell)
  rig.fw.step()
  _ = rig.fw.takeInterrupts()
  rig.fw.raiseGlobalEvent(CSF.GlobalReq.idle)
  let irq = rig.fw.takeInterrupts()
  #expect(irq == 1 << 31)
  #expect(host.glbInterrupt() == CSF.GlobalReq.idle)
  #expect(host.glbReq & CSF.GlobalReq.idle == host.glbAck & CSF.GlobalReq.idle)
  #expect(host.glbInterrupt() == 0)
}

// MARK: CSG start, suspend, resume, terminate

@Test(arguments: versions)
func aGroupStartsAndTheEndpointRequestIsInTheVersionsField(_ version: CSFVersion) throws {
  var rig = Rig(ModelConfig(version: version))
  let host = try rig.discover()
  try rig.start(host, 1, streams: [0, 1])
  let gl = rig.fw.layout.groups[1]
  #expect(host.csgAckState(1) == .started && host.csgAckState(1).isRunning)
  #expect(rig.fw.applied.endpoints[1] == Rig.program.endpoint)
  #expect(host.endpoint(1) == Rig.program.endpoint)
  // The other version's field stays 0.
  let wrongOffset = version.hasEndpointRequest64 ? CSF.GroupInput.epReq : CSF.GroupInput.epReq64
  #expect(rig.memory.load32(gl.input + wrongOffset) == 0)
  #expect(rig.memory.load64(gl.input + CSF.GroupInput.allowCompute) == 0xFF)
  #expect(rig.memory.load64(gl.input + CSF.GroupInput.allowFragment) == 0xF0)
  #expect(rig.memory.load32(gl.input + CSF.GroupInput.allowOther) == 1)
  #expect(rig.memory.load32(gl.input + CSF.GroupInput.config) == 2)
  #expect(rig.memory.load64(gl.input + CSF.GroupInput.suspendBuf) == 0x8000_0000)
  #expect(rig.memory.load64(gl.input + CSF.GroupInput.protmSuspendBuf) == 0x8001_0000)
  #expect(rig.fw.running[1 * 8 + 0] && rig.fw.running[1 * 8 + 1] && !rig.fw.running[1 * 8 + 2])
  #expect(!rig.fw.running[0])
  // The CS's own words: base, size, pages, priority and doorbell, the idle policy.
  let cs = gl.streams[1]
  #expect(rig.memory.load64(cs.input + CSF.StreamInput.base) == 0x10_1000)
  #expect(rig.memory.load32(cs.input + CSF.StreamInput.size) == 0x1000)
  #expect(rig.memory.load32(cs.input + CSF.StreamInput.config) == 0x103)
  #expect(rig.memory.load32(cs.input + CSF.StreamInput.req) == 0x501)
  #expect(rig.memory.load64(cs.input + CSF.StreamInput.userInput) == rig.va(rig.pages(1, 1).input))
  // GLB_DB_REQ's bit for slot 1 was toggled and acknowledged, and CSG_DB_REQ's for CS 0 and 1.
  #expect(rig.memory.load32(rig.fw.layout.input + CSF.GlobalInput.dbReq) == 0b10)
  #expect(rig.memory.load32(rig.fw.layout.output + CSF.GlobalOutput.dbAck) == 0b10)
  #expect(rig.memory.load32(gl.input + CSF.GroupInput.dbReq) == 0b11)
  #expect(rig.memory.load32(gl.output + CSF.GroupOutput.dbAck) == 0b11)
  #expect(rig.bell.rings == [0])
}

@Test func suspendResumeAndTerminateAreAcknowledgedByTheirState() throws {
  var rig = Rig()
  let host = try rig.discover()
  try rig.start(host, 0, streams: [2])
  let suspend = host.csgSetState(0, CSF.GroupState.suspend, rig.bell)
  #expect(!host.isDone(suspend))
  #expect(host.csgAckState(0) == .started)
  rig.fw.step()
  #expect(host.isDone(suspend) && host.csgAckState(0) == .suspended && !host.csgAckState(0).isRunning)
  #expect(!rig.fw.running[2])
  // The host sets the CS to STOP, no doorbell, no wait.
  host.csStop(0, 2)
  #expect(rig.memory.load32(rig.fw.layout.groups[0].streams[2].input + CSF.StreamInput.req) & 7 == 0)
  // Resume restores it. (Its CS is programmed again, as a group's streams are.)
  try host.csProgram(0, 2, rig.params(0, 2), pages: rig.pages(0, 2))
  let resume = try host.csgStart(0, Rig.program, streams: 0b100, resume: true, rig.bell)
  rig.fw.step()
  #expect(host.isDone(resume) && host.csgAckState(0) == .resumed && rig.fw.running[2])
  let terminate = host.csgSetState(0, CSF.GroupState.terminate, rig.bell)
  rig.fw.step()
  #expect(host.isDone(terminate) && host.csgAckState(0) == .terminated && !rig.fw.running[2])
}

@Test func aStateTheFirmwareAcknowledgesAsCorruptIsDecoded() {
  #expect(CSGAckState(0) == .terminated && CSGAckState(1) == .started)
  #expect(CSGAckState(2) == .suspended && CSGAckState(3) == .resumed)
  #expect(CSGAckState(5) == .invalid(5) && !CSGAckState(5).isRunning)
  #expect(CSGAckState(0xF1) == .started)
}

@Test func aPriorityChangeIsOnlyCurrentOnceAcknowledged() throws {
  var rig = Rig(ModelConfig(version: CSFVersion(4, 0, 0)))
  let host = try rig.discover()
  try rig.start(host, 0, streams: [0])
  let w = host.csgSetPriority(0, 12, rig.bell)
  #expect(!host.isDone(w))
  #expect(rig.fw.applied.endpoints[0].priority == 7)
  rig.fw.step()
  #expect(host.isDone(w))
  #expect(rig.fw.applied.endpoints[0] == EndpointRequest(compute: 8, fragment: 4, tiler: 1, priority: 12))
}

@Test func twoKicksBeforeTheFirmwareActsAreOne() throws {
  var rig = Rig()
  let host = try rig.discover()
  let dbReq = rig.fw.layout.input + CSF.GlobalInput.dbReq
  let dbAck = rig.fw.layout.output + CSF.GlobalOutput.dbAck
  host.kickGroup(2, rig.bell)
  host.kickGroup(2, rig.bell)
  #expect(rig.memory.load32(dbReq) ^ rig.memory.load32(dbAck) == 0b100)
  rig.fw.step()
  #expect(rig.memory.load32(dbReq) == rig.memory.load32(dbAck))
  host.kickGroup(2, rig.bell)
  #expect(rig.memory.load32(dbReq) ^ rig.memory.load32(dbAck) == 0b100)
  #expect(rig.bell.rings == [0, 0, 0])
}

@Test func theGroupsInputsAreLeftAloneWhileItsStartIsUnacknowledged() throws {
  var rig = Rig()
  let host = try rig.discover()
  try host.csProgram(0, 0, rig.params(0, 0), pages: rig.pages(0, 0))
  let w = try host.csgStart(0, Rig.program, streams: 1, resume: false, rig.bell)
  #expect(host.startPending(0))
  #expect(throws: CSFError.startPending) { try host.csProgram(0, 1, rig.params(0, 1), pages: rig.pages(0, 1)) }
  #expect(throws: CSFError.startPending) { try host.csgStart(0, Rig.program, streams: 1, resume: false, rig.bell) }
  rig.fw.step()
  #expect(host.isDone(w) && !host.startPending(0))
  try host.csProgram(0, 1, rig.params(0, 1), pages: rig.pages(0, 1))
}

@Test func aCSIsProgrammedOnlyWithAGoodRingAndSlot() throws {
  var rig = Rig()
  let host = try rig.discover()
  var p = rig.params(0, 0)
  p.ringSize = 0x1800
  #expect(throws: CSFError.badRingSize) { try host.csProgram(0, 0, p, pages: rig.pages(0, 0)) }
  p.ringSize = 0
  #expect(throws: CSFError.badRingSize) { try host.csProgram(0, 0, p, pages: rig.pages(0, 0)) }
  #expect(throws: CSFError.badSlot) { try host.csProgram(0, 8, rig.params(0, 0), pages: rig.pages(0, 0)) }
  #expect(throws: CSFError.badSlot) { try host.csProgram(4, 0, rig.params(0, 0), pages: rig.pages(0, 0)) }
  // INSERT must not be behind EXTRACT.
  let pages = rig.pages(0, 0)
  rig.memory.store64(pages.output + CSF.RingOutput.extract, 64)
  #expect(throws: CSFError.insertBeforeExtract) { try host.csProgram(0, 0, rig.params(0, 0), pages: pages) }
  rig.memory.store64(pages.input + CSF.RingInput.insert, 64)
  try host.csProgram(0, 0, rig.params(0, 0), pages: pages)
  #expect(rig.memory.load64(pages.input + CSF.RingInput.extract) == 64)
  try rig.start(host, 1, streams: [])
  #expect(throws: CSFError.badSlot) { try host.csgStart(9, Rig.program, streams: 0, resume: false, rig.bell) }
}

// MARK: CS events

@Test func aSubmissionRoundTripsToASyncUpdate() throws {
  var rig = Rig()
  let host = try rig.discover()
  try rig.start(host, 0, streams: [0])
  _ = rig.fw.takeInterrupts()
  let pages = rig.pages(0, 0)
  #expect(pages.isEmpty)
  // 06 §6.7.3: the instructions, a barrier, EXTRACT then INSERT, the CS's doorbell.
  let barriers = rig.memory.barriers
  pages.publish(insert: 128)
  #expect(rig.memory.barriers == barriers + 1)
  host.memory.writeBarrier()
  rig.bell.ring(1)
  #expect(rig.bell.rings.last == 1)
  #expect(pages.insert == 128 && pages.extract == 0 && !pages.isEmpty)
  rig.fw.step()
  #expect(pages.extract == 128 && pages.isEmpty)
  #expect(rig.fw.drains == 1)
  let irq = rig.fw.takeInterrupts()
  #expect(irq == 1)
  var streamsSeen = 0
  let ringsBefore = rig.bell.rings.count
  let result = host.csgInterrupt(0, rig.bell) { _, _ in
    streamsSeen += 1
    return 0
  }
  // The CS whose START was acknowledged is reported too, with no events of its own.
  #expect(result.events == CSF.GroupReq.syncUpdate && result.streams == 1 && streamsSeen == 0)
  // Acknowledged, and the CSG rung (GLB_DB_REQ's bit and doorbell 0).
  #expect(host.csgReq(0) & CSF.GroupReq.syncUpdate == host.csgAck(0) & CSF.GroupReq.syncUpdate)
  #expect(rig.bell.rings.count == ringsBefore + 1 && rig.bell.rings.last == 0)
  rig.fw.step()
  // Nothing more happened: a second interrupt does nothing and rings nothing.
  let again = host.csgInterrupt(0, rig.bell) { _, _ in 0 }
  #expect(again.isEmpty && rig.bell.rings.count == ringsBefore + 1)
  #expect(rig.memory.lockDepth == 0 && rig.memory.lockCalls > 0)
}

@Test func theExtractMovesInStepsAndAGroupNotRunningDoesntMove() throws {
  var rig = Rig(ModelConfig(extractPerStep: 64))
  let host = try rig.discover()
  let pages = rig.pages(2, 3)
  pages.publish(insert: 160)
  rig.fw.step()
  #expect(pages.extract == 0)  // its group isn't running
  try rig.start(host, 2, streams: [3])
  #expect(pages.extract == 64 && rig.fw.drains == 0)
  rig.fw.step()
  rig.fw.step()
  #expect(pages.extract == 160 && rig.fw.drains == 1)
  rig.fw.step()
  #expect(rig.fw.drains == 1)
}

@Test func aFaultIsDecodedAcknowledgedAndRung() throws {
  var rig = Rig()
  let host = try rig.discover()
  try rig.start(host, 0, streams: [0, 5])
  _ = rig.fw.takeInterrupts()
  _ = host.csgInterrupt(0, rig.bell) { _, _ in 0 }  // the start's own acks: no events
  rig.fw.step()
  rig.fw.raiseStreamFault(0, 5, type: 0x55, data: 0x1234, info: 0xABCD_EF01_2345)
  let irq = rig.fw.takeInterrupts()
  #expect(irq == 1)
  #expect(host.csEvents(0, 5) == CSF.StreamReq.fault)
  var got: [(Int, UInt32)] = []
  let ringsBefore = rig.bell.rings.count
  let result = host.csgInterrupt(0, rig.bell) { slot, events in
    got.append((slot, events))
    return events
  }
  #expect(result.streams == 1 << 5 && result.events == 0)
  #expect(got.count == 1 && got[0].0 == 5 && got[0].1 == CSF.StreamReq.fault)
  let fault = host.csFault(0, 5)
  #expect(fault.type == 0x55 && fault.data == 0x1234 && fault.info == 0xABCD_EF01_2345)
  #expect(host.csEvents(0, 5) == 0)
  // CSG_CS_IRQ_ACK caught up before the CS words were read; CS 5's bit toggled in CSG_DB_REQ; rung.
  let gl = rig.fw.layout.groups[0]
  #expect(rig.memory.load32(gl.input + CSF.GroupInput.csIrqAck) == rig.memory.load32(gl.output + CSF.GroupOutput.csIrqReq))
  #expect(rig.memory.load32(gl.input + CSF.GroupInput.dbReq) ^ rig.memory.load32(gl.output + CSF.GroupOutput.dbAck) == 1 << 5)
  #expect(rig.bell.rings.count == ringsBefore + 1)
  rig.fw.step()
  #expect(rig.memory.load32(gl.input + CSF.GroupInput.dbReq) == rig.memory.load32(gl.output + CSF.GroupOutput.dbAck))
}

@Test func aFatalErrorAndAnUnackedTilerOOM() throws {
  var rig = Rig()
  let host = try rig.discover()
  try rig.start(host, 3, streams: [1, 2])
  _ = host.csgInterrupt(3, rig.bell) { _, _ in 0 }
  rig.fw.raiseStreamFatal(3, 1, type: CSException.unrecoverable, data: 9, info: 7)
  rig.fw.raiseTilerOOM(3, 2, heapAddress: 0x4000_0000, vtStart: 5, vtEnd: 3, fragEnd: 2)
  let irq = rig.fw.takeInterrupts()
  #expect(irq & 1 << 3 != 0)
  var seen: [UInt32] = [0, 0, 0]
  let result = host.csgInterrupt(3, rig.bell) { slot, events in
    seen[slot] = events
    // The OOM waits for a chunk.
    return events & ~CSF.StreamReq.tilerOOM
  }
  #expect(result.streams == 0b110)
  #expect(seen[1] == CSF.StreamReq.fatal && seen[2] == CSF.StreamReq.tilerOOM)
  let fatal = host.csFatal(3, 1)
  #expect(fatal.type == CSException.unrecoverable && fatal.data == 9 && fatal.info == 7)
  #expect(host.csEvents(3, 1) == 0 && host.csEvents(3, 2) == CSF.StreamReq.tilerOOM)
  let oom = host.csTilerOOM(3, 2)
  #expect(oom.isConsistent && oom.passesInFlight == 3 && oom.passesWaitingForFragment == 1)
  #expect(oom.heapAddress == 0x4000_0000)
  #expect(!TilerOOMReport(heapAddress: 0, vtStart: 3, vtEnd: 3, fragEnd: 0).isConsistent)
  #expect(!TilerOOMReport(heapAddress: 0, vtStart: 5, vtEnd: 3, fragEnd: 4).isConsistent)
  // The reply: the same chunk in both, the event acknowledged, the stream kicked.
  let chunk = TilerOOMReport.chunk(address: 0x4000_1000, size: 0x20_0000)
  #expect(chunk == 0x4000_1000 | 0x200)
  host.csSetTilerHeap(3, 2, chunk: chunk)
  let input = rig.fw.layout.groups[3].streams[2].input
  #expect(rig.memory.load64(input + CSF.StreamInput.tilerHeapStart) == chunk)
  #expect(rig.memory.load64(input + CSF.StreamInput.tilerHeapEnd) == chunk)
  host.csAcknowledge(3, 2, CSF.StreamReq.tilerOOM)
  host.kickStream(3, 2, rig.bell)
  #expect(host.csEvents(3, 2) == 0)
}

@Test func anEventRaisedWhileOneIsPendingIsNotLostByTheModel() throws {
  // The firmware must not toggle a pending bit again (two toggles cancel):
  // the model refuses, and the host acknowledges once.
  var rig = Rig()
  let host = try rig.discover()
  try rig.start(host, 0, streams: [0])
  rig.fw.raiseGroupEvent(0, CSF.GroupReq.idle)
  rig.fw.raiseGroupEvent(0, CSF.GroupReq.idle)
  let result = host.csgInterrupt(0, rig.bell) { _, _ in 0 }
  #expect(result.events == CSF.GroupReq.idle)
  rig.fw.raiseGroupEvent(0, CSF.GroupReq.idle | CSF.GroupReq.progressTimerEvent)
  #expect(host.csgInterrupt(0, rig.bell) { _, _ in 0 }.events == CSF.GroupReq.idle | CSF.GroupReq.progressTimerEvent)
}

@Test func aHostRequestInFlightIsNotAnEvent() throws {
  var rig = Rig()
  let host = try rig.discover()
  try rig.start(host, 0, streams: [0])
  _ = host.csgInterrupt(0, rig.bell) { _, _ in 0 }
  // CSG_REQ and CSG_ACK differ (a toggle not yet done), but the interrupt has nothing to do.
  let w = host.csgStatusUpdate(0, rig.bell)
  let rings = rig.bell.rings.count
  #expect(host.csgInterrupt(0, rig.bell) { _, _ in 0 }.isEmpty)
  #expect(rig.bell.rings.count == rings)
  #expect(!host.isDone(w))
  rig.fw.step()
  #expect(host.isDone(w))
}

@Test func theStatusIsInterpretedAsTheSpecSays() {
  var s = CSStatus(wait: CSF.Wait.syncWait | CSF.Wait.syncWaitSize64 | CSF.Wait.conditionGT << 24,
                   syncPointer: 0x1000, syncValueLow: 5, syncValueHigh: 1, scoreboards: 0,
                   blockedReason: CSF.BlockedReason.syncObject)
  #expect(s.isSyncWait && s.syncSize64 && s.reference == 1 << 32 | 5)
  #expect(s.isBlockedOnSync)
  #expect(s.isSatisfied(sequence: 1 << 32 | 6) && !s.isSatisfied(sequence: 1 << 32 | 5))
  s.wait = CSF.Wait.syncWait | CSF.Wait.conditionLE << 24
  #expect(s.reference == 5 && s.isSatisfied(sequence: 5) && !s.isSatisfied(sequence: 6))
  s.scoreboards = 1
  #expect(!s.isBlockedOnSync)
  s.blockedReason = 0
  s.scoreboards = 0
  #expect(s.isIdle(insert: 64, extract: 64) && !s.isIdle(insert: 128, extract: 64))
}

@Test func theLockIdsAreDistinctAndEveryRequestIsUnderOne() throws {
  var seen: [Int] = []
  for g in 0..<31 { seen.append(CSF.Lock.group(g)) }
  for g in 0..<31 { for s in 0..<32 { seen.append(CSF.Lock.stream(g, s)) } }
  seen.append(CSF.Lock.global)
  seen.sort()
  for i in 1..<seen.count { #expect(seen[i] != seen[i - 1]) }
  var rig = Rig()
  let host = try rig.discover()
  try rig.start(host, 0, streams: [0])
  #expect(rig.memory.lockDepth == 0 && rig.memory.lockCalls >= 4)
}
