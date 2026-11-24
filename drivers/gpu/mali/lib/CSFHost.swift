// SPDX-License-Identifier: BSD-3-Clause

// The host's side of the CSF interface (panthor 06 §6.3 to §6.7, 05 §5.6,
// §5.7): the request/acknowledge protocol over a discovered layout. Every
// request is a read-modify-write of one request word under that word's
// lock, followed, where the firmware must look, by the doorbell steps of
// §6.3.6 in their order: the input first, then the request word, then the
// CS or CSG doorbell bit, then doorbell 0. Interrupt handling follows
// §6.3.7. Nothing here reads a register: a doorbell is a `CSFDoorbell`, and
// the interrupt's status register, its clearing and the MCU's status are
// the driver's.
//
// The spec leaves some points open; each is resolved to the safe reading
// where the code takes it, with a comment:
//  - an interrupt "has nothing to do" when no event bit differs and no CS
//    has an event, not when REQ == ACK (a host request in flight also makes
//    them differ);
//  - the CSG doorbell is rung at the end of every interrupt that did
//    something (the spec says Linux does, and that it is safe);
//  - a CSG's inputs are not touched while its START or RESUME is
//    unacknowledged.

/// A doorbell (06 §6.3.5): a write of 1 to its register. Ringing is a
/// device-ordered write: every store to the shared section before it is
/// visible to the MCU first.
public protocol CSFDoorbell {
  func ring(_ id: Int)
}

/// A request in flight: the ACK word and what it must read as. Complete
/// when ACK matches over the whole mask (06 §6.3.4); a field matching in
/// part is not done. The expected value is the REQ the host wrote (the
/// snapshot), so a later request of the same word doesn't move it.
public struct AckWait: Equatable, Sendable {
  public let ack: Int
  public let mask: UInt32
  public let expected: UInt32
  public init(ack: Int, mask: UInt32, expected: UInt32) {
    self.ack = ack
    self.mask = mask
    self.expected = expected
  }
}

/// What a CSG's interrupt found (06 §6.3.7): the event bits it acknowledged
/// and the CS slots whose CS_IRQ_REQ had changed.
public struct CSGInterrupt: Equatable, Sendable {
  public var events: UInt32
  public var streams: UInt32
  public init(events: UInt32 = 0, streams: UInt32 = 0) {
    self.events = events
    self.streams = streams
  }
  public var isEmpty: Bool { events == 0 && streams == 0 }
}

/// The global interface's boot-time settings (05 §5.6.3, 06 §6.4.6).
public struct GlobalConfig: Equatable, Sendable {
  public var allocEn: UInt64
  public var pwroffTimer: UInt32
  public var progressTimer: UInt32
  public var idleTimer: UInt32

  public init(allocEn: UInt64, pwroffTimer: UInt32, progressTimer: UInt32, idleTimer: UInt32) {
    self.allocEn = allocEn
    self.pwroffTimer = pwroffTimer
    self.progressTimer = progressTimer
    self.idleTimer = idleTimer
  }

  /// The policy's values (05 §5.6.3): every shader core, power-off after
  /// 10 ms and idle after 800 us of the system timestamp when its frequency
  /// is known, else of the GPU cycle counter at the core clock, else the
  /// maximum value.
  public static func boot(shaderPresent: UInt64, timestampFrequency: UInt64?, coreFrequency: UInt64?)
    -> GlobalConfig {
    var pwroff = CSF.timerUnknown
    var idle = CSF.timerUnknown
    if let f = timestampFrequency, f != 0 {
      pwroff = CSF.timer(microseconds: CSF.powerOffMicroseconds, frequency: f, source: .timestamp)
      idle = CSF.timer(microseconds: CSF.idleMicroseconds, frequency: f, source: .timestamp)
    } else if let f = coreFrequency, f != 0 {
      pwroff = CSF.timer(microseconds: CSF.powerOffMicroseconds, frequency: f, source: .cycles)
      idle = CSF.timer(microseconds: CSF.idleMicroseconds, frequency: f, source: .cycles)
    }
    return GlobalConfig(allocEn: shaderPresent, pwroffTimer: pwroff, progressTimer: CSF.progressTimerDefault,
                        idleTimer: idle)
  }
}

/// A CSG's inputs written before START or RESUME (06 §6.5.6 step 2).
public struct CSGProgram: Equatable, Sendable {
  public var allowCompute: UInt64
  public var allowFragment: UInt64
  public var allowOther: UInt32
  public var endpoint: EndpointRequest
  /// The MMU address space the group's streams use.
  public var addressSpace: UInt32
  /// MCU addresses of the suspend buffers; 0 is none.
  public var suspendBuffer: UInt64
  public var protmSuspendBuffer: UInt64
  public var ackIrqMask: UInt32

  public init(allowCompute: UInt64, allowFragment: UInt64, allowOther: UInt32, endpoint: EndpointRequest,
              addressSpace: UInt32, suspendBuffer: UInt64 = 0, protmSuspendBuffer: UInt64 = 0,
              ackIrqMask: UInt32 = 0xFFFF_FFFF) {
    self.allowCompute = allowCompute
    self.allowFragment = allowFragment
    self.allowOther = allowOther
    self.endpoint = endpoint
    self.addressSpace = addressSpace
    self.suspendBuffer = suspendBuffer
    self.protmSuspendBuffer = protmSuspendBuffer
    self.ackIrqMask = ackIrqMask
  }
}

/// A CS slot's inputs written before its CSG starts (06 §6.6.6).
public struct CSParams: Equatable, Sendable {
  /// The ring buffer's GPU address in the group's address space, and its
  /// size in bytes (a power of two).
  public var ringBase: UInt64
  public var ringSize: UInt32
  /// The ring's input and output pages, as MCU addresses.
  public var userInput: UInt64
  public var userOutput: UInt64
  /// 0 to 15.
  public var priority: UInt32
  public var doorbell: UInt32
  public var ackIrqMask: UInt32

  public init(ringBase: UInt64, ringSize: UInt32, userInput: UInt64, userOutput: UInt64, priority: UInt32 = 0,
              doorbell: UInt32, ackIrqMask: UInt32 = 0xFFFF_FFFF) {
    self.ringBase = ringBase
    self.ringSize = ringSize
    self.userInput = userInput
    self.userOutput = userOutput
    self.priority = priority
    self.doorbell = doorbell
    self.ackIrqMask = ackIrqMask
  }
}

/// CSG_ACK.STATE (06 §6.5.2).
public enum CSGAckState: Equatable, Sendable {
  case terminated, started, suspended, resumed
  /// 4 to 7: firmware corruption (policy: the group is unusable and the GPU
  /// resets).
  case invalid(UInt32)

  public init(_ field: UInt32) {
    switch field & 7 {
    case 0: self = .terminated
    case 1: self = .started
    case 2: self = .suspended
    case 3: self = .resumed
    default: self = .invalid(field & 7)
    }
  }
  /// The group is running (started or resumed).
  public var isRunning: Bool { self == .started || self == .resumed }
}

/// A CS_FAULT or CS_FATAL word and its info (06 §6.6.5).
public struct CSException: Equatable, Sendable {
  /// The exception type, [7:0].
  public var type: UInt32
  /// The exception data, [31:8].
  public var data: UInt32
  public var info: UInt64
  public init(word: UInt32, info: UInt64) {
    type = word & 0xFF
    data = word >> 8
    self.info = info
  }
  /// CS_UNRECOVERABLE: the policy resets the GPU (06 §6.6.5).
  public static let unrecoverable: UInt32 = 0x41
}

/// What a TILER_OOM carries (06 §6.6.5).
public struct TilerOOMReport: Equatable, Sendable {
  public var heapAddress: UInt64
  public var vtStart: UInt32
  public var vtEnd: UInt32
  public var fragEnd: UInt32
  /// FRAG_END <= VT_END < VT_START; anything else is a fatal stream error
  /// (policy).
  public var isConsistent: Bool { fragEnd <= vtEnd && vtEnd < vtStart }
  public var passesInFlight: UInt32 { vtStart &- fragEnd }
  public var passesWaitingForFragment: UInt32 { vtEnd &- fragEnd }

  public init(heapAddress: UInt64, vtStart: UInt32, vtEnd: UInt32, fragEnd: UInt32) {
    self.heapAddress = heapAddress
    self.vtStart = vtStart
    self.vtEnd = vtEnd
    self.fragEnd = fragEnd
  }

  /// A chunk's pointer for CS_TILER_HEAP_START and _END: bits [63:12] the
  /// 4 KiB-aligned address, [11:0] the size in 4 KiB units.
  public static func chunk(address: UInt64, size: Int) -> UInt64 {
    (address & ~0xFFF) | UInt64(size >> 12) & 0xFFF
  }
}

/// A CS slot's status after a SUSPEND or a STATUS_UPDATE (06 §6.6.4).
public struct CSStatus: Equatable, Sendable {
  public var wait: UInt32
  public var syncPointer: UInt64
  public var syncValueLow: UInt32
  public var syncValueHigh: UInt32
  public var scoreboards: UInt32
  public var blockedReason: UInt32

  public init(wait: UInt32, syncPointer: UInt64, syncValueLow: UInt32, syncValueHigh: UInt32, scoreboards: UInt32,
              blockedReason: UInt32) {
    self.wait = wait
    self.syncPointer = syncPointer
    self.syncValueLow = syncValueLow
    self.syncValueHigh = syncValueHigh
    self.scoreboards = scoreboards
    self.blockedReason = blockedReason
  }

  public var isSyncWait: Bool { wait & CSF.Wait.syncWait != 0 }
  public var syncSize64: Bool { wait & CSF.Wait.syncWaitSize64 != 0 }
  /// 0 is LE, 1 is GT.
  public var condition: UInt32 { wait >> CSF.Wait.conditionShift & 0xF }
  /// The reference value: the high word counts only for a 64-bit wait.
  public var reference: UInt64 { UInt64(syncValueLow) | (syncSize64 ? UInt64(syncValueHigh) << 32 : 0) }
  /// Blocked on a sync object with nothing deferred (06 §6.6.4); with
  /// deferred work it may still progress and counts as runnable.
  public var isBlockedOnSync: Bool { blockedReason == CSF.BlockedReason.syncObject && scoreboards == 0 }
  /// Whether the wait holds for the sync object's sequence number: GT when
  /// it is above the reference, LE when at or below it.
  public func isSatisfied(sequence: UInt64) -> Bool {
    condition == CSF.Wait.conditionGT ? sequence > reference : sequence <= reference
  }
  /// Idle: unblocked, ring empty, no scoreboard work.
  public func isIdle(insert: UInt64, extract: UInt64) -> Bool {
    blockedReason == CSF.BlockedReason.unblocked && insert == extract && scoreboards == 0
  }
}

/// A CS's ring pages (06 §6.7): the host's input page and the firmware's
/// output page, in their own memory (a buffer the MCU maps), with the
/// submission sequence of §6.7.3.
public struct RingPages<P: SharedMemory> {
  public let memory: P
  public let input: Int
  public let output: Int
  public init(memory: P, input: Int, output: Int) {
    self.memory = memory
    self.input = input
    self.output = output
  }

  /// The firmware's EXTRACT.
  public var extract: UInt64 { memory.load64(output + CSF.RingOutput.extract) }
  /// The host's INSERT.
  public var insert: UInt64 { memory.load64(input + CSF.RingInput.insert) }
  /// INSERT == EXTRACT: nothing for the firmware to do.
  public var isEmpty: Bool { insert == extract }

  /// Copies the output page's EXTRACT into the input page's, and checks
  /// INSERT is not behind it (06 §6.6.6 step 1).
  public func syncExtract() throws(CSFError) {
    let e = extract
    memory.store64(input + CSF.RingInput.extract, e)
    guard insert >= e else { throw .insertBeforeExtract }
  }

  /// The new INSERT (06 §6.7.3 step 3), after the ring's instructions are
  /// written: a write barrier, EXTRACT, then INSERT. The caller then rings
  /// the stream's doorbell if the group is resident.
  public func publish(insert newInsert: UInt64) {
    memory.writeBarrier()
    memory.store64(input + CSF.RingInput.extract, extract)
    memory.store64(input + CSF.RingInput.insert, newInsert)
  }
}

/// The host's operations on a discovered interface.
public struct CSFHost<M: SharedMemory> {
  public let memory: M
  public let layout: CSFLayout

  public init(memory: M, layout: CSFLayout) {
    self.memory = memory
    self.layout = layout
  }

  public var version: CSFVersion { layout.version }

  /// A request word before and after a read-modify-write, and the ACK read
  /// with it.
  struct Words {
    var oldReq: UInt32
    var newReq: UInt32
    var ack: UInt32
  }

  /// The one way a request word is written: under its lock, read both
  /// words, store the new REQ (06 §6.3.3).
  @discardableResult
  func update(_ lock: Int, req: Int, ack: Int, _ change: (_ req: UInt32, _ ack: UInt32) -> UInt32) -> Words {
    memory.lock(lock)
    let r = memory.load32(req)
    let a = memory.load32(ack)
    let n = change(r, a)
    memory.store32(req, n)
    memory.unlock(lock)
    return Words(oldReq: r, newReq: n, ack: a)
  }

  func group(_ g: Int) -> CSGLayout {
    precondition(g >= 0 && g < layout.groups.count, "CSG slot out of range")
    return layout.groups[g]
  }

  func stream(_ g: Int, _ s: Int) -> CSLayout {
    let gl = group(g)
    precondition(s >= 0 && s < gl.streams.count, "CS slot out of range")
    return gl.streams[s]
  }

  // MARK: Waiting

  /// Whether `wait` has completed.
  public func isDone(_ wait: AckWait) -> Bool {
    ReqAck.complete(ack: memory.load32(wait.ack), expected: wait.expected, mask: wait.mask)
  }

  /// Polls `spins` times, then once more.
  public func spin(_ wait: AckWait, spins: Int) -> Bool {
    var n = 0
    while n < spins {
      if isDone(wait) { return true }
      n += 1
    }
    return isDone(wait)
  }

  // MARK: Doorbells (06 §6.3.5, §6.3.6)

  /// Makes the firmware look at CSG slot `g`: toggle its bit in GLB_DB_REQ,
  /// then ring doorbell 0. The caller has written the input and the
  /// request word first.
  public func kickGroup<D: CSFDoorbell>(_ g: Int, _ door: D) {
    update(CSF.Lock.global, req: layout.input + CSF.GlobalInput.dbReq, ack: layout.output + CSF.GlobalOutput.dbAck) {
      r, a in ReqAck.toggled(req: r, ack: a, mask: 1 << UInt32(g))
    }
    door.ring(CSF.Section.globalDoorbell)
  }

  /// Whether the firmware has taken the last doorbell of CSG slot `g`:
  /// its GLB_DB_ACK bit equals GLB_DB_REQ's. Only then is another toggle a
  /// new edge (panthor 06 section 6.3.8); it does not say the request in the
  /// slot was read.
  public func doorbellSeen(_ g: Int) -> Bool {
    ReqAck.complete(ack: memory.load32(layout.output + CSF.GlobalOutput.dbAck),
                    expected: memory.load32(layout.input + CSF.GlobalInput.dbReq), mask: 1 << UInt32(g))
  }

  /// Makes it look at CS slot `s` of CSG slot `g`: its bit in CSG_DB_REQ,
  /// then the CSG's (kickGroup).
  public func kickStream<D: CSFDoorbell>(_ g: Int, _ s: Int, _ door: D) {
    toggleStreamDoorbells(g, 1 << UInt32(s))
    kickGroup(g, door)
  }

  /// Toggles the CS bits `mask` in CSG_DB_REQ; the group's own kick follows.
  public func toggleStreamDoorbells(_ g: Int, _ mask: UInt32) {
    let gl = group(g)
    update(CSF.Lock.group(g), req: gl.input + CSF.GroupInput.dbReq, ack: gl.output + CSF.GroupOutput.dbAck) {
      r, a in ReqAck.toggled(req: r, ack: a, mask: mask)
    }
  }

  // MARK: Global interface (06 §6.4)

  /// Writes GLB_REQ: level or field bits to `value` under `setMask`, then
  /// the `toggle` bits inverted from their ACK. The wait is on the toggles
  /// and on `fields` (a state field).
  @discardableResult
  public func glbRequest(set value: UInt32 = 0, mask setMask: UInt32 = 0, toggle: UInt32 = 0,
                         fields: UInt32 = 0) -> AckWait {
    let ack = layout.output + CSF.GlobalOutput.ack
    let w = update(CSF.Lock.global, req: layout.input + CSF.GlobalInput.req, ack: ack) { r, a in
      ReqAck.toggled(req: ReqAck.set(req: r, value: value, mask: setMask), ack: a, mask: toggle)
    }
    return AckWait(ack: ack, mask: toggle | fields, expected: w.newReq)
  }

  /// GLB_REQ and GLB_ACK, and the events the firmware has raised.
  public var glbReq: UInt32 { memory.load32(layout.input + CSF.GlobalInput.req) }
  public var glbAck: UInt32 { memory.load32(layout.output + CSF.GlobalOutput.ack) }

  /// The global interrupt's work (06 §6.4.8): the events pending
  /// (IDLE, ...), each acknowledged by copying its ACK bit into REQ.
  public func glbInterrupt() -> UInt32 {
    let w = update(CSF.Lock.global, req: layout.input + CSF.GlobalInput.req,
                   ack: layout.output + CSF.GlobalOutput.ack) { r, a in
      ReqAck.acknowledged(req: r, ack: a, events: CSF.GlobalReq.events)
    }
    return ReqAck.pending(req: w.oldReq, ack: w.ack, mask: CSF.GlobalReq.events)
  }

  /// The global initialisation after every MCU start, a fast reset too
  /// (06 §6.4.6): the settings, the acknowledge mask, the level bits and
  /// the three configuration toggles, doorbell 0. The caller doesn't wait
  /// for the acks (policy); the wait returned is for those who do.
  @discardableResult
  public func initGlobal<D: CSFDoorbell>(_ config: GlobalConfig, _ door: D) -> AckWait {
    let input = layout.input
    memory.store64(input + CSF.GlobalInput.allocEn, config.allocEn)
    memory.store32(input + CSF.GlobalInput.pwroffTimer, config.pwroffTimer)
    memory.store32(input + CSF.GlobalInput.progressTimer, config.progressTimer)
    memory.store32(input + CSF.GlobalInput.idleTimer, config.idleTimer)
    memory.store32(input + CSF.GlobalInput.ackIrqMask, CSF.globalAckIrqMask(version))
    let levels = CSF.GlobalReq.idleEnable | CSF.GlobalReq.counterEnable
    let w = glbRequest(set: levels, mask: levels,
                       toggle: CSF.GlobalReq.cfgAllocEn | CSF.GlobalReq.cfgPwroffTimer | CSF.GlobalReq.cfgProgressTimer)
    door.ring(CSF.Section.globalDoorbell)
    return w
  }

  /// A watchdog ping (06 §6.4.7): toggle PING, ring doorbell 0.
  public func ping<D: CSFDoorbell>(_ door: D) -> AckWait {
    let w = glbRequest(toggle: CSF.GlobalReq.ping)
    door.ring(CSF.Section.globalDoorbell)
    return w
  }

  /// Asks the MCU to halt (06 §6.4.5): the HALT bit before 4.1, the HALT
  /// state from it.
  public func requestHalt<D: CSFDoorbell>(_ door: D) {
    if version.hasGlobalState {
      glbRequest(set: CSF.GlobalState.halt << CSF.GlobalReq.stateShift, mask: CSF.GlobalReq.stateMask,
                 fields: CSF.GlobalReq.stateMask)
    } else {
      glbRequest(set: CSF.GlobalReq.halt, mask: CSF.GlobalReq.halt)
    }
    door.ring(CSF.Section.globalDoorbell)
  }

  /// The halt is complete: MCU_STATUS reads HALT and, from 4.1, the ACK's
  /// state is HALT too. Before 4.1 nothing is acknowledged.
  public func haltComplete(mcuStatus: UInt32) -> Bool {
    guard mcuStatus == CSF.mcuStatusHalt else { return false }
    guard version.hasGlobalState else { return true }
    return glbAck & CSF.GlobalReq.stateMask == CSF.GlobalState.halt << CSF.GlobalReq.stateShift
  }

  /// Back to active before the MCU is restarted (06 §6.4.5), or the firmware
  /// halts again at once. No doorbell: the MCU isn't running.
  public func clearHalt() {
    if version.hasGlobalState {
      glbRequest(set: CSF.GlobalState.active, mask: CSF.GlobalReq.stateMask)
    } else {
      glbRequest(set: 0, mask: CSF.GlobalReq.halt)
    }
  }

  /// GLB_HALT_STATUS: why the MCU halted.
  public var haltStatus: UInt32 { memory.load32(layout.output + CSF.GlobalOutput.haltStatus) }

  // MARK: CSG interface (06 §6.5)

  /// Writes CSG_REQ, as glbRequest does GLB_REQ.
  @discardableResult
  public func csgRequest(_ g: Int, set value: UInt32 = 0, mask setMask: UInt32 = 0, toggle: UInt32 = 0,
                         fields: UInt32 = 0) -> AckWait {
    let gl = group(g)
    let ack = gl.output + CSF.GroupOutput.ack
    let w = update(CSF.Lock.group(g), req: gl.input + CSF.GroupInput.req, ack: ack) { r, a in
      ReqAck.toggled(req: ReqAck.set(req: r, value: value, mask: setMask), ack: a, mask: toggle)
    }
    return AckWait(ack: ack, mask: toggle | fields, expected: w.newReq)
  }

  public func csgReq(_ g: Int) -> UInt32 { memory.load32(group(g).input + CSF.GroupInput.req) }
  public func csgAck(_ g: Int) -> UInt32 { memory.load32(group(g).output + CSF.GroupOutput.ack) }

  /// CSG_ACK.STATE.
  public func csgAckState(_ g: Int) -> CSGAckState { CSGAckState(csgAck(g)) }

  /// The endpoint request as the interface holds it, from the field the
  /// version names (06 §6.5.4).
  public func endpoint(_ g: Int) -> EndpointRequest {
    let gl = group(g)
    if version.hasEndpointRequest64 {
      return EndpointRequest(raw: UInt32(truncatingIfNeeded: memory.load64(gl.input + CSF.GroupInput.epReq64)))
    }
    return EndpointRequest(raw: memory.load32(gl.input + CSF.GroupInput.epReq))
  }

  /// Writes the endpoint request without asking for it to be applied: it
  /// takes effect on START or RESUME, or at ENDPOINT_CONFIG.
  public func writeEndpoint(_ g: Int, _ ep: EndpointRequest) {
    let gl = group(g)
    if version.hasEndpointRequest64 {
      memory.store64(gl.input + CSF.GroupInput.epReq64, UInt64(ep.raw))
    } else {
      memory.store32(gl.input + CSF.GroupInput.epReq, ep.raw)
    }
  }

  /// Applies a new endpoint request, a priority change of a running group
  /// too (06 §6.5.6): the old priority stays current until the wait is done.
  public func csgEndpointConfig<D: CSFDoorbell>(_ g: Int, _ ep: EndpointRequest, _ door: D) -> AckWait {
    writeEndpoint(g, ep)
    let w = csgRequest(g, toggle: CSF.GroupReq.endpointConfig)
    kickGroup(g, door)
    return w
  }

  /// Changes the priority alone, keeping the other fields.
  public func csgSetPriority<D: CSFDoorbell>(_ g: Int, _ priority: UInt32, _ door: D) -> AckWait {
    var ep = endpoint(g)
    ep.priority = priority
    return csgEndpointConfig(g, ep, door)
  }

  /// Asks the firmware to refresh every CS_STATUS_* output of the group.
  public func csgStatusUpdate<D: CSFDoorbell>(_ g: Int, _ door: D) -> AckWait {
    let w = csgRequest(g, toggle: CSF.GroupReq.statusUpdate)
    kickGroup(g, door)
    return w
  }

  /// Suspend or terminate (06 §6.5.6): the state, the kick, the wait on the
  /// state field.
  public func csgSetState<D: CSFDoorbell>(_ g: Int, _ state: UInt32, _ door: D) -> AckWait {
    let w = csgRequest(g, set: state, mask: CSF.GroupReq.stateMask, fields: CSF.GroupReq.stateMask)
    kickGroup(g, door)
    return w
  }

  /// Starts or resumes a group (06 §6.5.6): its inputs, the CS bits
  /// `streams` (the streams already programmed, csProgram) toggled in
  /// CSG_DB_REQ, the state and ENDPOINT_CONFIG in one write of CSG_REQ, the
  /// kick. The wait is on the state field and ENDPOINT_CONFIG.
  public func csgStart<D: CSFDoorbell>(_ g: Int, _ program: CSGProgram, streams: UInt32, resume: Bool, _ door: D)
    throws(CSFError) -> AckWait {
    guard g >= 0 && g < layout.groups.count else { throw .badSlot }
    let gl = layout.groups[g]
    guard !startPending(g) else { throw .startPending }
    let input = gl.input
    memory.store64(input + CSF.GroupInput.allowCompute, program.allowCompute)
    memory.store64(input + CSF.GroupInput.allowFragment, program.allowFragment)
    memory.store32(input + CSF.GroupInput.allowOther, program.allowOther)
    writeEndpoint(g, program.endpoint)
    memory.store32(input + CSF.GroupInput.config, program.addressSpace)
    memory.store64(input + CSF.GroupInput.suspendBuf, program.suspendBuffer)
    memory.store64(input + CSF.GroupInput.protmSuspendBuf, program.protmSuspendBuffer)
    memory.store32(input + CSF.GroupInput.ackIrqMask, program.ackIrqMask)
    if streams != 0 { toggleStreamDoorbells(g, streams) }
    let state = resume ? CSF.GroupState.resume : CSF.GroupState.start
    let w = csgRequest(g, set: state, mask: CSF.GroupReq.stateMask, toggle: CSF.GroupReq.endpointConfig,
                       fields: CSF.GroupReq.stateMask)
    kickGroup(g, door)
    return w
  }

  /// A START or RESUME of the group is not yet acknowledged: its CSG and CS
  /// inputs are left alone (policy; it isn't documented when the firmware
  /// samples them).
  public func startPending(_ g: Int) -> Bool {
    let req = csgReq(g)
    let state = req & CSF.GroupReq.stateMask
    guard state == CSF.GroupState.start || state == CSF.GroupState.resume else { return false }
    return ReqAck.pending(req: req, ack: csgAck(g), mask: CSF.GroupReq.stateMask) != 0
  }

  /// The interrupt of CSG slot `g` (06 §6.3.7). The caller has cleared the
  /// JOB interrupt's bit first. In order:
  ///  1. read CSG_REQ and ACK and CSG_CS_IRQ_REQ and ACK; nothing to do
  ///     when no event bit differs and no CS has an event;
  ///  2. CSG_CS_IRQ_ACK := the CS_IRQ_REQ just read, before any CS word;
  ///  3. acknowledge the CSG events (SYNC_UPDATE, IDLE, PROGRESS_TIMER);
  ///  4. for each CS whose bit differed, `onStream(slot, events)` gets the
  ///     CS_REQ xor CS_ACK of FATAL, FAULT, TILER_OOM and PROTM_PENDING
  ///     (when any) and returns those to acknowledge now (a TILER_OOM is
  ///     left until a chunk is ready); they are acknowledged and the CS's
  ///     bit toggled in CSG_DB_REQ;
  ///  5. the CSG kick, even when only events were acknowledged.
  public func csgInterrupt<D: CSFDoorbell>(_ g: Int, _ door: D, onStream: (_ slot: Int, _ events: UInt32) -> UInt32)
    -> CSGInterrupt {
    let gl = group(g)
    // 1
    let req = memory.load32(gl.input + CSF.GroupInput.req)
    let ack = memory.load32(gl.output + CSF.GroupOutput.ack)
    let irqReq = memory.load32(gl.output + CSF.GroupOutput.csIrqReq)
    let irqAck = memory.load32(gl.input + CSF.GroupInput.csIrqAck)
    let pendingEvents = ReqAck.pending(req: req, ack: ack, mask: CSF.GroupReq.events)
    let streams = ReqAck.pending(req: irqReq, ack: irqAck, mask: streamMask(gl))
    if pendingEvents == 0 && streams == 0 { return CSGInterrupt() }
    // 2: an event raised after this toggles CS_IRQ_REQ again and isn't missed.
    memory.store32(gl.input + CSF.GroupInput.csIrqAck, irqReq)
    // 3
    let events = pendingEvents != 0 ? csgAcknowledge(g) : 0
    // 4
    var doorbells: UInt32 = 0
    for s in 0..<gl.streams.count where streams & 1 << UInt32(s) != 0 {
      let cs = csEvents(g, s)
      guard cs != 0 else { continue }
      let acknowledge = onStream(s, cs) & cs
      if acknowledge != 0 {
        csAcknowledge(g, s, acknowledge)
        doorbells |= 1 << UInt32(s)
      }
    }
    if doorbells != 0 { toggleStreamDoorbells(g, doorbells) }
    // 5
    kickGroup(g, door)
    return CSGInterrupt(events: events, streams: streams)
  }

  /// Acknowledges the CSG events `events` by copying their ACK bits into
  /// CSG_REQ, and returns those that were pending.
  @discardableResult
  public func csgAcknowledge(_ g: Int, _ events: UInt32 = CSF.GroupReq.events) -> UInt32 {
    let gl = group(g)
    let w = update(CSF.Lock.group(g), req: gl.input + CSF.GroupInput.req, ack: gl.output + CSF.GroupOutput.ack) {
      r, a in ReqAck.acknowledged(req: r, ack: a, events: events)
    }
    return ReqAck.pending(req: w.oldReq, ack: w.ack, mask: events)
  }

  func streamMask(_ gl: CSGLayout) -> UInt32 {
    gl.streams.count >= 32 ? UInt32.max : (1 << UInt32(gl.streams.count)) - 1
  }

  // MARK: CS interface (06 §6.6)

  /// Writes CS_REQ for slot (`g`, `s`).
  @discardableResult
  public func csRequest(_ g: Int, _ s: Int, set value: UInt32 = 0, mask setMask: UInt32 = 0,
                        toggle: UInt32 = 0) -> AckWait {
    let cs = stream(g, s)
    let ack = cs.output + CSF.StreamOutput.ack
    let w = update(CSF.Lock.stream(g, s), req: cs.input + CSF.StreamInput.req, ack: ack) { r, a in
      ReqAck.toggled(req: ReqAck.set(req: r, value: value, mask: setMask), ack: a, mask: toggle)
    }
    return AckWait(ack: ack, mask: toggle, expected: w.newReq)
  }

  /// Programs a CS slot before its CSG starts or resumes (06 §6.6.6): the
  /// input page's EXTRACT from the output page's, the ring, the pages, the
  /// priority and doorbell, the acknowledge mask, and CS_REQ's STATE =
  /// START with IDLE_SYNC_WAIT and IDLE_EMPTY (0x501 under 0x507). The
  /// caller collects the CS bit for csgStart. Refused while the CSG's START
  /// or RESUME is unacknowledged.
  public func csProgram<P: SharedMemory>(_ g: Int, _ s: Int, _ p: CSParams, pages: RingPages<P>) throws(CSFError) {
    guard g >= 0, g < layout.groups.count, s >= 0, s < layout.groups[g].streams.count else { throw .badSlot }
    guard p.ringSize != 0, p.ringSize & (p.ringSize - 1) == 0 else { throw .badRingSize }
    guard !startPending(g) else { throw .startPending }
    try pages.syncExtract()
    let cs = layout.groups[g].streams[s]
    let input = cs.input
    memory.store64(input + CSF.StreamInput.base, p.ringBase)
    memory.store32(input + CSF.StreamInput.size, p.ringSize)
    memory.store64(input + CSF.StreamInput.userInput, p.userInput)
    memory.store64(input + CSF.StreamInput.userOutput, p.userOutput)
    memory.store32(input + CSF.StreamInput.config, p.priority & 0xF | (p.doorbell & 0xFF) << 8)
    memory.store32(input + CSF.StreamInput.ackIrqMask, p.ackIrqMask)
    csRequest(g, s, set: CSF.StreamReq.start | CSF.StreamReq.idleSyncWait | CSF.StreamReq.idleEmpty,
              mask: CSF.StreamReq.stateMask | CSF.StreamReq.idleSyncWait | CSF.StreamReq.idleEmpty)
  }

  /// Sets a CS's state back to STOP after its group left the running state
  /// (06 §6.5.6). No doorbell, no wait.
  public func csStop(_ g: Int, _ s: Int) {
    csRequest(g, s, set: CSF.StreamReq.stop, mask: CSF.StreamReq.stateMask)
  }

  /// The firmware's events on a CS not yet handled: CS_REQ xor CS_ACK of
  /// FATAL, FAULT, TILER_OOM and PROTM_PENDING.
  public func csEvents(_ g: Int, _ s: Int) -> UInt32 {
    let cs = stream(g, s)
    return ReqAck.pending(req: memory.load32(cs.input + CSF.StreamInput.req),
                          ack: memory.load32(cs.output + CSF.StreamOutput.ack), mask: CSF.StreamReq.events)
  }

  /// Acknowledges events by copying their ACK bits into CS_REQ. The firmware
  /// acts on it at the next kick (toggle the CS's CSG_DB_REQ bit and kick
  /// the group; csgInterrupt does).
  public func csAcknowledge(_ g: Int, _ s: Int, _ events: UInt32) {
    let cs = stream(g, s)
    update(CSF.Lock.stream(g, s), req: cs.input + CSF.StreamInput.req, ack: cs.output + CSF.StreamOutput.ack) {
      r, a in ReqAck.acknowledged(req: r, ack: a, events: events)
    }
  }

  /// CS_FAULT and its info.
  public func csFault(_ g: Int, _ s: Int) -> CSException {
    let cs = stream(g, s)
    return CSException(word: memory.load32(cs.output + CSF.StreamOutput.fault),
                       info: memory.load64(cs.output + CSF.StreamOutput.faultInfo))
  }

  /// CS_STATUS_CMD_PTR (panthor 06 section 6.6.4): the VA of the instruction the stream is at, read with a fault to place its info word.
  public func csCommandPointer(_ g: Int, _ s: Int) -> UInt64 { memory.load64(stream(g, s).output + CSF.StreamOutput.statusCmdPtr) }

  /// CS_FATAL and its info.
  public func csFatal(_ g: Int, _ s: Int) -> CSException {
    let cs = stream(g, s)
    return CSException(word: memory.load32(cs.output + CSF.StreamOutput.fatal),
                       info: memory.load64(cs.output + CSF.StreamOutput.fatalInfo))
  }

  /// What a TILER_OOM reports.
  public func csTilerOOM(_ g: Int, _ s: Int) -> TilerOOMReport {
    let out = stream(g, s).output
    return TilerOOMReport(heapAddress: memory.load64(out + CSF.StreamOutput.heapAddress),
                          vtStart: memory.load32(out + CSF.StreamOutput.heapVTStart),
                          vtEnd: memory.load32(out + CSF.StreamOutput.heapVTEnd),
                          fragEnd: memory.load32(out + CSF.StreamOutput.heapFragEnd))
  }

  /// The reply to a TILER_OOM: the same chunk pointer in both (0 for none
  /// now); the caller then acknowledges and kicks the stream.
  public func csSetTilerHeap(_ g: Int, _ s: Int, chunk: UInt64) {
    let input = stream(g, s).input
    memory.store64(input + CSF.StreamInput.tilerHeapStart, chunk)
    memory.store64(input + CSF.StreamInput.tilerHeapEnd, chunk)
  }

  /// A CS's status outputs (valid after a SUSPEND or a STATUS_UPDATE).
  public func csStatus(_ g: Int, _ s: Int) -> CSStatus {
    let out = stream(g, s).output
    return CSStatus(wait: memory.load32(out + CSF.StreamOutput.statusWait),
                    syncPointer: memory.load64(out + CSF.StreamOutput.statusWaitSyncPointer),
                    syncValueLow: memory.load32(out + CSF.StreamOutput.statusWaitSyncValue),
                    syncValueHigh: memory.load32(out + CSF.StreamOutput.statusWaitSyncValueHi),
                    scoreboards: memory.load32(out + CSF.StreamOutput.statusScoreboards),
                    blockedReason: memory.load32(out + CSF.StreamOutput.statusBlockedReason) & 0xF)
  }
}
