// SPDX-License-Identifier: BSD-3-Clause

// A stand-in for the CSF firmware, for the host tests (CSF.swift and
// CSFHost.swift's checks, drivers/gpu/mali/tests and .../check): it owns the
// same shared section, publishes the control blocks at boot for a version
// and slot counts it is told, and acknowledges what the host asks for as
// the real firmware does by panthor 06: it copies a toggle's REQ into ACK,
// a state field's value, answers a doorbell only for the bits toggled in
// GLB_DB_REQ and CSG_DB_REQ, moves each running stream's EXTRACT toward its
// INSERT, and raises events (a sync update when a ring drains, idle, faults)
// when told to. Where the spec is silent it does the simplest thing; those
// are comments. The driver does not use it.

/// A section of bytes: the model's memory in a host test. A class, as a
/// mapping is: the host and the model firmware hold the same one. Counts its
/// locks, so a test can see they are balanced.
public final class ByteMemory: SharedMemory {
  public var bytes: [UInt8]
  public private(set) var lockDepth = 0
  public private(set) var lockCalls = 0
  public private(set) var barriers = 0

  public init(size: Int) { bytes = [UInt8](repeating: 0, count: size) }

  public var size: Int { bytes.count }

  public func load32(_ offset: Int) -> UInt32 {
    precondition(offset >= 0 && offset + 4 <= bytes.count, "load outside the section")
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(bytes[offset + i]) << UInt32(8 * i) }
    return v
  }

  public func store32(_ offset: Int, _ value: UInt32) {
    precondition(offset >= 0 && offset + 4 <= bytes.count, "store outside the section")
    for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt32(8 * i)) }
  }

  public func lock(_ id: Int) {
    lockDepth += 1
    lockCalls += 1
  }
  public func unlock(_ id: Int) { lockDepth -= 1 }
  public func writeBarrier() { barriers += 1 }
}

/// What the model firmware is told at boot.
/// A host's answer to a TILER_OOM, as the model firmware saw it.
public struct TilerReply: Equatable, Sendable {
  public var group: Int
  public var stream: Int
  public var start: UInt64
  public var end: UInt64

  public init(group: Int, stream: Int, start: UInt64, end: UInt64) {
    self.group = group
    self.stream = stream
    self.start = start
    self.end = end
  }
}

public struct ModelConfig: Equatable, Sendable {
  public var version: CSFVersion
  public var groups: Int
  public var streams: Int
  /// The byte stride of CS control blocks (at least 0x0C, a multiple of 4).
  public var streamStride: Int
  public var workRegisters: Int
  public var scoreboards: Int
  public var suspendSize: Int
  public var protmSuspendSize: Int
  /// A stream whose ring drains raises its CSG's SYNC_UPDATE.
  public var syncUpdateOnDrain: Bool
  /// How far a step moves a stream's EXTRACT toward INSERT.
  public var extractPerStep: UInt64

  public init(version: CSFVersion = CSFVersion(4, 1, 0), groups: Int = 4, streams: Int = 8, streamStride: Int = 0x20,
              workRegisters: Int = 96, scoreboards: Int = 8, suspendSize: Int = 0x10000,
              protmSuspendSize: Int = 0x4000, syncUpdateOnDrain: Bool = true, extractPerStep: UInt64 = .max) {
    self.version = version
    self.groups = groups
    self.streams = streams
    self.streamStride = streamStride
    self.workRegisters = workRegisters
    self.scoreboards = scoreboards
    self.suspendSize = suspendSize
    self.protmSuspendSize = protmSuspendSize
    self.syncUpdateOnDrain = syncUpdateOnDrain
    self.extractPerStep = extractPerStep
  }
}

/// What the model firmware has applied from the host's requests.
public struct ModelApplied: Equatable, Sendable {
  public var allocEn: UInt64 = 0
  public var pwroffTimer: UInt32 = 0
  public var progressTimer: UInt32 = 0
  public var idleTimer: UInt32 = 0
  /// The endpoint request each CSG slot last applied.
  public var endpoints: [EndpointRequest] = []
  public init() {}
}

public struct ModelFirmware<M: SharedMemory> {
  public let memory: M
  public let config: ModelConfig
  /// Where the model puts the blocks: what discovery must find.
  public let layout: CSFLayout
  /// The section's size the layout needs; the rings' pages come after it.
  public let interfaceEnd: Int

  public private(set) var applied = ModelApplied()
  /// Host toggle requests and state changes the model has carried out: one
  /// per toggle bit it copied to ACK, one per state it changed.
  public private(set) var performed = 0
  /// Rings drained to INSERT.
  public private(set) var drains = 0
  public private(set) var halted = false
  /// The state each CSG slot last acknowledged.
  public private(set) var groupState: [UInt32]
  /// Running streams, `group * streams + stream`.
  public private(set) var running: [Bool]
  /// Streams with a TILER_OOM raised and not yet answered (the reply is taken when the host acknowledges it).
  public private(set) var oomWaiting: [Bool]
  /// What the host answered each TILER_OOM with: CS_TILER_HEAP_START and _END when it acknowledged.
  public private(set) var tilerReplies: [TilerReply] = []
  /// JOB interrupt bits raised since `takeInterrupts()`: bit i for CSG slot
  /// i, bit 31 for the global interface.
  var interrupts: UInt32 = 0

  public init(memory: M, config: ModelConfig = ModelConfig()) {
    self.memory = memory
    self.config = config
    precondition(config.groups >= 1 && config.groups <= CSF.Section.maxGroups, "groups")
    precondition(config.streams >= 1 && config.streams <= CSF.Section.maxStreams, "streams")
    precondition(config.streamStride >= CSF.StreamControl.size && config.streamStride & 3 == 0, "stride")
    let groupStride = (CSF.Section.firstStream + config.streams * config.streamStride + 0x3F) & ~0x3F
    // Blocks packed after the control blocks, each 8-aligned.
    var at = (CSF.Section.firstGroup + config.groups * groupStride + 0xFF) & ~0xFF
    func take(_ size: Int) -> Int {
      let offset = at
      at += (size + 7) & ~7
      return offset
    }
    let glbIn = take(CSF.GlobalInput.minSize)
    let glbOut = take(CSF.GlobalOutput.minSize)
    var groups: [CSGLayout] = []
    let features = CSFeatures(UInt32(config.workRegisters - 1) | UInt32(config.scoreboards) << 8 | 7 << 16)
    for g in 0..<config.groups {
      let control = CSF.Section.firstGroup + g * groupStride
      let gIn = take(CSF.GroupInput.minSize)
      let gOut = take(CSF.GroupOutput.minSize)
      var streams: [CSLayout] = []
      for s in 0..<config.streams {
        let sControl = control + CSF.Section.firstStream + s * config.streamStride
        let sIn = take(CSF.StreamInput.minSize)
        let sOut = take(CSF.StreamOutput.minSize)
        streams.append(CSLayout(control: sControl, input: sIn, output: sOut, features: features))
      }
      groups.append(CSGLayout(control: control, input: gIn, output: gOut, features: 0x3, suspendSize: config.suspendSize,
                              protmSuspendSize: config.protmSuspendSize, streamStride: config.streamStride,
                              streams: streams))
    }
    layout = CSFLayout(version: config.version, features: 0x1, instrFeatures: config.version.hasInstrFeatures ? 0x5 : 0,
                       prfcntSize: 0x1000, input: glbIn, output: glbOut, groupStride: groupStride, groups: groups)
    interfaceEnd = at
    groupState = [UInt32](repeating: 0, count: config.groups)
    running = [Bool](repeating: false, count: config.groups * config.streams)
    oomWaiting = [Bool](repeating: false, count: config.groups * config.streams)
    applied.endpoints = [EndpointRequest](repeating: EndpointRequest(), count: config.groups)
  }

  static func va(_ offset: Int) -> UInt32 { CSF.Section.base + UInt32(offset) }

  /// Zeroes the section and publishes the control blocks; GLB_VERSION last,
  /// as the firmware's "the interface is up". Below 1.1.0 it leaves junk in
  /// GLB_INSTR_FEATURES, which the host must treat as 0.
  public func boot() {
    var i = 0
    while i + 4 <= memory.size {
      memory.store32(i, 0)
      i += 4
    }
    memory.store32(CSF.GlobalControl.features, layout.features)
    memory.store32(CSF.GlobalControl.inputVA, Self.va(layout.input))
    memory.store32(CSF.GlobalControl.outputVA, Self.va(layout.output))
    memory.store32(CSF.GlobalControl.groupNum, UInt32(layout.groups.count))
    memory.store32(CSF.GlobalControl.groupStride, UInt32(layout.groupStride))
    memory.store32(CSF.GlobalControl.prfcntSize, layout.prfcntSize)
    memory.store32(CSF.GlobalControl.instrFeatures, config.version.hasInstrFeatures ? layout.instrFeatures : 0xDEAD_BEEF)
    for gl in layout.groups {
      memory.store32(gl.control + CSF.GroupControl.features, gl.features)
      memory.store32(gl.control + CSF.GroupControl.inputVA, Self.va(gl.input))
      memory.store32(gl.control + CSF.GroupControl.outputVA, Self.va(gl.output))
      memory.store32(gl.control + CSF.GroupControl.suspendSize, UInt32(gl.suspendSize))
      memory.store32(gl.control + CSF.GroupControl.protmSuspendSize, UInt32(gl.protmSuspendSize))
      memory.store32(gl.control + CSF.GroupControl.streamNum, UInt32(gl.streams.count))
      memory.store32(gl.control + CSF.GroupControl.streamStride, UInt32(gl.streamStride))
      for cs in gl.streams {
        memory.store32(cs.control + CSF.StreamControl.features, cs.features.raw)
        memory.store32(cs.control + CSF.StreamControl.inputVA, Self.va(cs.input))
        memory.store32(cs.control + CSF.StreamControl.outputVA, Self.va(cs.output))
      }
    }
    memory.store32(CSF.GlobalControl.version, config.version.raw)
  }

  // MARK: Interrupts

  /// The JOB interrupt bits raised since the last call, which clears them.
  public mutating func takeInterrupts() -> UInt32 {
    let v = interrupts
    interrupts = 0
    return v
  }

  /// Raises the interrupt for `bit` if any of `changed` is enabled in the
  /// mask word at `maskOffset` (06 §6.3.4).
  mutating func signal(_ changed: UInt32, mask maskOffset: Int, bit: Int) {
    if changed & memory.load32(maskOffset) != 0 { interrupts |= 1 << UInt32(bit) }
  }

  // MARK: Serving the host

  /// Does everything the host's inputs now ask for: the global requests,
  /// every CSG slot whose GLB_DB_REQ bit is toggled, every CS slot whose
  /// CSG_DB_REQ bit is, and the running rings. Returns whether anything
  /// changed. A doorbell is not modelled: it is enough that the host rang
  /// one after it wrote. `scanGlobal: false` leaves GLB_REQ
  /// alone, for a check whose host makes no global request.
  @discardableResult
  public mutating func step(scanGlobal: Bool = true) -> Bool {
    var did = scanGlobal ? serveGlobal() : false
    let input = layout.input
    let output = layout.output
    let dbReq = memory.load32(input + CSF.GlobalInput.dbReq)
    let dbAck = memory.load32(output + CSF.GlobalOutput.dbAck)
    let toggled = ReqAck.pending(req: dbReq, ack: dbAck, mask: groupMask)
    if toggled != 0 {
      // The ack first: a request written after this is seen by the next
      // doorbell, and one written before is read below.
      memory.store32(output + CSF.GlobalOutput.dbAck, dbAck ^ toggled)
      for g in 0..<layout.groups.count where toggled & 1 << UInt32(g) != 0 { serveGroup(g) }
      did = true
    }
    if advanceRings() { did = true }
    return did
  }

  var groupMask: UInt32 { (1 << UInt32(layout.groups.count)) - 1 }

  mutating func serveGlobal() -> Bool {
    let input = layout.input
    let output = layout.output
    let req = memory.load32(input + CSF.GlobalInput.req)
    let ack = memory.load32(output + CSF.GlobalOutput.ack)
    var newAck = ack
    let toggles = ReqAck.pending(req: req, ack: ack, mask: CSF.GlobalReq.toggles)
    if toggles != 0 {
      if toggles & CSF.GlobalReq.cfgAllocEn != 0 { applied.allocEn = memory.load64(input + CSF.GlobalInput.allocEn) }
      if toggles & CSF.GlobalReq.cfgPwroffTimer != 0 {
        applied.pwroffTimer = memory.load32(input + CSF.GlobalInput.pwroffTimer)
      }
      if toggles & CSF.GlobalReq.cfgProgressTimer != 0 {
        applied.progressTimer = memory.load32(input + CSF.GlobalInput.progressTimer)
      }
      applied.idleTimer = memory.load32(input + CSF.GlobalInput.idleTimer)
      newAck ^= toggles
      performed += toggles.nonzeroBitCount
    }
    // The level bits are mirrored into ACK (the spec leaves open whether the
    // real firmware does; the host must not depend on either).
    newAck = (newAck & ~CSF.GlobalReq.levels) | (req & CSF.GlobalReq.levels)
    if config.version.hasGlobalState {
      let state = req & CSF.GlobalReq.stateMask
      if state != ack & CSF.GlobalReq.stateMask {
        newAck = (newAck & ~CSF.GlobalReq.stateMask) | state
        performed += 1
      }
      halted = state >> CSF.GlobalReq.stateShift == CSF.GlobalState.halt
    } else {
      // Before 4.1 the HALT bit is a level, never acknowledged.
      halted = req & CSF.GlobalReq.halt != 0
    }
    guard newAck != ack else { return toggles != 0 }
    memory.store32(output + CSF.GlobalOutput.ack, newAck)
    signal(newAck ^ ack, mask: input + CSF.GlobalInput.ackIrqMask, bit: CSF.Section.globalInterruptBit)
    return true
  }

  mutating func serveGroup(_ g: Int) {
    let gl = layout.groups[g]
    let req = memory.load32(gl.input + CSF.GroupInput.req)
    let ack = memory.load32(gl.output + CSF.GroupOutput.ack)
    var newAck = ack
    let want = req & CSF.GroupReq.stateMask
    if want != ack & CSF.GroupReq.stateMask {
      switch want {
      case CSF.GroupState.start, CSF.GroupState.resume:
        groupState[g] = want
        startStreams(g)
      case CSF.GroupState.suspend, CSF.GroupState.terminate:
        groupState[g] = want
        for s in 0..<gl.streams.count { running[g * config.streams + s] = false }
        if want == CSF.GroupState.terminate {
          for s in 0..<gl.streams.count { oomWaiting[g * config.streams + s] = false }
        }
      default:
        // Not a state: acknowledged as written, so the host sees the 4 to 7
        // it must treat as corruption.
        break
      }
      newAck = (newAck & ~CSF.GroupReq.stateMask) | want
      performed += 1
    }
    let toggles = ReqAck.pending(req: req, ack: newAck, mask: CSF.GroupReq.endpointConfig | CSF.GroupReq.statusUpdate)
    if toggles != 0 {
      if toggles & CSF.GroupReq.endpointConfig != 0 { applied.endpoints[g] = endpointRead(g) }
      newAck ^= toggles
      performed += toggles.nonzeroBitCount
    }
    if newAck != ack {
      memory.store32(gl.output + CSF.GroupOutput.ack, newAck)
      signal(newAck ^ ack, mask: gl.input + CSF.GroupInput.ackIrqMask, bit: g)
    }
    let dbReq = memory.load32(gl.input + CSF.GroupInput.dbReq)
    let dbAck = memory.load32(gl.output + CSF.GroupOutput.dbAck)
    let streams = ReqAck.pending(req: dbReq, ack: dbAck, mask: streamMask)
    if streams != 0 {
      memory.store32(gl.output + CSF.GroupOutput.dbAck, dbAck ^ streams)
      for s in 0..<gl.streams.count where streams & 1 << UInt32(s) != 0 { serveStream(g, s) }
    }
  }

  var streamMask: UInt32 { config.streams >= 32 ? UInt32.max : (1 << UInt32(config.streams)) - 1 }

  func endpointRead(_ g: Int) -> EndpointRequest {
    let input = layout.groups[g].input
    if config.version.hasEndpointRequest64 {
      return EndpointRequest(raw: UInt32(truncatingIfNeeded: memory.load64(input + CSF.GroupInput.epReq64)))
    }
    return EndpointRequest(raw: memory.load32(input + CSF.GroupInput.epReq))
  }

  /// START or RESUME: every stream the host programmed (CS_REQ.STATE =
  /// START) runs, and its CS_ACK.STATE says so.
  mutating func startStreams(_ g: Int) {
    for s in 0..<config.streams {
      let cs = layout.groups[g].streams[s]
      let req = memory.load32(cs.input + CSF.StreamInput.req)
      guard req & CSF.StreamReq.stateMask == CSF.StreamReq.start else { continue }
      running[g * config.streams + s] = true
      let ack = memory.load32(cs.output + CSF.StreamOutput.ack)
      memory.store32(cs.output + CSF.StreamOutput.ack, (ack & ~CSF.StreamReq.stateMask) | CSF.StreamReq.start)
      // An OOM the group was suspended with is raised again after its resume (08 section 8.4.2 step 3).
      if oomWaiting[g * config.streams + s] { signalStream(g, s, CSF.StreamReq.tilerOOM) }
    }
  }

  mutating func serveStream(_ g: Int, _ s: Int) {
    let cs = layout.groups[g].streams[s]
    let req = memory.load32(cs.input + CSF.StreamInput.req)
    let ack = memory.load32(cs.output + CSF.StreamOutput.ack)
    if oomWaiting[g * config.streams + s], req & CSF.StreamReq.tilerOOM == ack & CSF.StreamReq.tilerOOM {
      oomWaiting[g * config.streams + s] = false
      tilerReplies.append(TilerReply(group: g, stream: s, start: memory.load64(cs.input + CSF.StreamInput.tilerHeapStart),
                                     end: memory.load64(cs.input + CSF.StreamInput.tilerHeapEnd)))
    }
    var newAck = (ack & ~CSF.StreamReq.stateMask) | (req & CSF.StreamReq.stateMask)
    let idleBits = CSF.StreamReq.idleSyncWait | CSF.StreamReq.idleProtmPending | CSF.StreamReq.idleEmpty
      | CSF.StreamReq.idleResourceReq
    newAck = (newAck & ~idleBits) | (req & idleBits)
    let toggles = ReqAck.pending(req: req, ack: newAck, mask: CSF.StreamReq.extractEvent)
    if toggles != 0 {
      newAck ^= toggles
      performed += 1
    }
    let started = groupState[g] == CSF.GroupState.start || groupState[g] == CSF.GroupState.resume
    running[g * config.streams + s] = started && req & CSF.StreamReq.stateMask == CSF.StreamReq.start
    if newAck != ack {
      memory.store32(cs.output + CSF.StreamOutput.ack, newAck)
      signalStream(g, s, newAck ^ ack)
    }
  }

  /// A CS_ACK bit changed: reported through CSG_CS_IRQ_REQ if the CS's mask
  /// enables it, and the CSG's interrupt.
  mutating func signalStream(_ g: Int, _ s: Int, _ changed: UInt32) {
    let gl = layout.groups[g]
    guard changed & memory.load32(gl.streams[s].input + CSF.StreamInput.ackIrqMask) != 0 else { return }
    let irq = memory.load32(gl.output + CSF.GroupOutput.csIrqReq)
    memory.store32(gl.output + CSF.GroupOutput.csIrqReq, irq ^ 1 << UInt32(s))
    interrupts |= 1 << UInt32(g)
  }

  /// Each running stream: EXTRACT moves toward INSERT, and a drained ring
  /// raises SYNC_UPDATE if the model is told to.
  mutating func advanceRings() -> Bool {
    var did = false
    for g in 0..<layout.groups.count {
      for s in 0..<config.streams where running[g * config.streams + s] {
        let cs = layout.groups[g].streams[s]
        let limit = memory.size
        guard let inOffset = CSFLayout.resolve(UInt32(truncatingIfNeeded: memory.load64(cs.input + CSF.StreamInput.userInput)),
                                               size: 16, limit: limit),
              let outOffset = CSFLayout.resolve(UInt32(truncatingIfNeeded: memory.load64(cs.input + CSF.StreamInput.userOutput)),
                                                size: 16, limit: limit)
        else { continue }
        let insert = memory.load64(inOffset + CSF.RingInput.insert)
        let extract = memory.load64(outOffset + CSF.RingOutput.extract)
        guard insert > extract else { continue }
        let next = extract + min(insert - extract, config.extractPerStep)
        memory.store64(outOffset + CSF.RingOutput.extract, next)
        did = true
        if next == insert {
          drains += 1
          if config.syncUpdateOnDrain { raiseGroupEvent(g, CSF.GroupReq.syncUpdate) }
        }
      }
    }
    return did
  }

  // MARK: Raising events

  /// Toggles global event bits in GLB_ACK (IDLE, ...).
  public mutating func raiseGlobalEvent(_ bits: UInt32) {
    let ack = memory.load32(layout.output + CSF.GlobalOutput.ack)
    memory.store32(layout.output + CSF.GlobalOutput.ack, ack ^ bits)
    signal(bits, mask: layout.input + CSF.GlobalInput.ackIrqMask, bit: CSF.Section.globalInterruptBit)
  }

  /// Toggles CSG event bits in CSG_ACK (SYNC_UPDATE, IDLE, PROGRESS_TIMER).
  /// An event still unacknowledged is not raised again: two toggles would
  /// cancel, which the real firmware must avoid as well.
  public mutating func raiseGroupEvent(_ g: Int, _ bits: UInt32) {
    let gl = layout.groups[g]
    let ack = memory.load32(gl.output + CSF.GroupOutput.ack)
    let req = memory.load32(gl.input + CSF.GroupInput.req)
    let fresh = bits & ~ReqAck.pending(req: req, ack: ack, mask: bits)
    guard fresh != 0 else { return }
    memory.store32(gl.output + CSF.GroupOutput.ack, ack ^ fresh)
    signal(fresh, mask: gl.input + CSF.GroupInput.ackIrqMask, bit: g)
  }

  /// A recoverable fault on a stream: CS_FAULT and its info, FAULT toggled
  /// in CS_ACK, the stream's bit toggled in CSG_CS_IRQ_REQ.
  public mutating func raiseStreamFault(_ g: Int, _ s: Int, type: UInt32, data: UInt32 = 0, info: UInt64 = 0) {
    let out = layout.groups[g].streams[s].output
    memory.store32(out + CSF.StreamOutput.fault, type & 0xFF | data << 8)
    memory.store64(out + CSF.StreamOutput.faultInfo, info)
    raiseStreamEvent(g, s, CSF.StreamReq.fault)
  }

  /// An unrecoverable error on a stream.
  public mutating func raiseStreamFatal(_ g: Int, _ s: Int, type: UInt32, data: UInt32 = 0, info: UInt64 = 0) {
    let out = layout.groups[g].streams[s].output
    memory.store32(out + CSF.StreamOutput.fatal, type & 0xFF | data << 8)
    memory.store64(out + CSF.StreamOutput.fatalInfo, info)
    raiseStreamEvent(g, s, CSF.StreamReq.fatal)
  }

  /// A tiler heap out of memory.
  public mutating func raiseTilerOOM(_ g: Int, _ s: Int, heapAddress: UInt64, vtStart: UInt32, vtEnd: UInt32,
                                     fragEnd: UInt32) {
    let out = layout.groups[g].streams[s].output
    memory.store64(out + CSF.StreamOutput.heapAddress, heapAddress)
    memory.store32(out + CSF.StreamOutput.heapVTStart, vtStart)
    memory.store32(out + CSF.StreamOutput.heapVTEnd, vtEnd)
    memory.store32(out + CSF.StreamOutput.heapFragEnd, fragEnd)
    oomWaiting[g * config.streams + s] = true
    raiseStreamEvent(g, s, CSF.StreamReq.tilerOOM)
  }

  /// Toggles `bits` of CS_ACK (an event not yet acknowledged is left), then
  /// the CS's bit of CSG_CS_IRQ_REQ: the order the host's interrupt relies on.
  public mutating func raiseStreamEvent(_ g: Int, _ s: Int, _ bits: UInt32) {
    let cs = layout.groups[g].streams[s]
    let req = memory.load32(cs.input + CSF.StreamInput.req)
    let ack = memory.load32(cs.output + CSF.StreamOutput.ack)
    let fresh = bits & ~ReqAck.pending(req: req, ack: ack, mask: bits)
    guard fresh != 0 else { return }
    memory.store32(cs.output + CSF.StreamOutput.ack, ack ^ fresh)
    signalStream(g, s, fresh)
  }
}
