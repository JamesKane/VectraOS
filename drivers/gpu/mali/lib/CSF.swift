// SPDX-License-Identifier: BSD-3-Clause

// The CSF firmware's host interface, as a layout and a protocol over memory
// (chinese-wall's panthor 05 §5.4 to §5.6 and 06): the shared section's
// control, input and output blocks of the global interface, of each command
// stream group (CSG) slot and of each command stream (CS) slot, with every
// field's offset; discovery of the slots, bounds-checked against the
// section; the interface version's gates; the request/acknowledge words'
// arithmetic; and the timers' and the endpoint request's encodings.
//
// Pure logic: it reads and writes the section through `SharedMemory`, so
// host tests use a byte array and the driver its mapping. Nothing here
// touches a register; a doorbell is `CSFDoorbell` (CSFHost.swift).

/// The shared section, as the host sees it: single 32-bit loads and stores
/// (the mapping is uncached, so never an atomic, 06 §6.3.3), and the locks
/// that serialise writers of one request word.
public protocol SharedMemory {
  /// The bytes of the section the host has mapped.
  var size: Int { get }
  func load32(_ offset: Int) -> UInt32
  func store32(_ offset: Int, _ value: UInt32)
  /// A 64-bit field. Defaults to two 32-bit accesses, low word first;
  /// a mapping that can do one 64-bit access overrides them.
  func load64(_ offset: Int) -> UInt64
  func store64(_ offset: Int, _ value: UInt64)
  /// One lock per interface instance (06 §6.3.3): `CSF.Lock`'s ids. The
  /// host calls them around every read-modify-write of a request word.
  /// Defaults to nothing, for a caller that serialises itself.
  func lock(_ id: Int)
  func unlock(_ id: Int)
  /// Makes every earlier store visible to the MCU before a later one: before
  /// a ring's INSERT (06 §6.3.6). Defaults to nothing.
  func writeBarrier()
}

extension SharedMemory {
  public func load64(_ offset: Int) -> UInt64 {
    UInt64(load32(offset)) | UInt64(load32(offset + 4)) << 32
  }
  public func store64(_ offset: Int, _ value: UInt64) {
    store32(offset, UInt32(truncatingIfNeeded: value))
    store32(offset + 4, UInt32(truncatingIfNeeded: value >> 32))
  }
  public func lock(_ id: Int) {}
  public func unlock(_ id: Int) {}
  public func writeBarrier() {}
}

/// The interface version, GLB_VERSION's value (06 §6.2.3).
public struct CSFVersion: Equatable, Comparable, Sendable {
  public let raw: UInt32
  public init(raw: UInt32) { self.raw = raw }
  public init(_ major: UInt32, _ minor: UInt32, _ patch: UInt32) {
    raw = major << 24 | (minor & 0xFF) << 16 | patch & 0xFFFF
  }
  public var major: UInt32 { raw >> 24 }
  public var minor: UInt32 { raw >> 16 & 0xFF }
  public var patch: UInt32 { raw & 0xFFFF }

  public static func < (a: CSFVersion, b: CSFVersion) -> Bool { a.raw < b.raw }

  /// 1.1.0: GLB_INSTR_FEATURES is valid (below it, it reads as 0).
  public var hasInstrFeatures: Bool { self >= CSFVersion(1, 1, 0) }
  /// 4.0.0: the endpoint request is the 64-bit field at CSG input +0x38.
  public var hasEndpointRequest64: Bool { self >= CSFVersion(4, 0, 0) }
  /// 4.1.0: GLB_REQ and GLB_ACK carry the 3-bit STATE field, and halting is
  /// a state, not the HALT bit.
  public var hasGlobalState: Bool { self >= CSFVersion(4, 1, 0) }
}

/// The interface's constants. Every offset is a byte offset from the start
/// of the block its enum names (06 §6.4 to §6.7); a block's `size` or
/// `minSize` is what the host relies on (05 §5.4.6).
public enum CSF {
  public enum Section {
    /// The MCU address of the shared section's first byte.
    public static let base: UInt32 = 0x0400_0000
    /// The MCU's shared region: no object lies past it.
    public static let regionSize = 0x0400_0000
    /// The first CSG control block, and a CS control block's place in one.
    public static let firstGroup = 0x1000
    public static let firstStream = 0x40
    public static let globalDoorbell = 0
    /// The JOB interrupt's bit for the global interface.
    public static let globalInterruptBit = 31
    public static let maxGroups = 31
    public static let maxStreams = 32
    /// What the host refuses below (policy: 05 §5.4.5).
    public static let minGroups = 3
    public static let minStreams = 8
    public static let maxPriority: UInt32 = 15
  }

  public enum GlobalControl {
    public static let version = 0x00
    public static let features = 0x04
    public static let inputVA = 0x08
    public static let outputVA = 0x0C
    public static let groupNum = 0x10
    public static let groupStride = 0x14
    public static let prfcntSize = 0x18
    public static let instrFeatures = 0x1C
    public static let size = 0x20
  }

  public enum GlobalInput {
    public static let req = 0x00
    public static let ackIrqMask = 0x04
    public static let dbReq = 0x08
    public static let progressTimer = 0x10
    public static let pwroffTimer = 0x14
    /// 64 bits.
    public static let allocEn = 0x18
    public static let prfcntAS = 0x24
    /// 64 bits.
    public static let prfcntBase = 0x28
    public static let prfcntExtract = 0x30
    public static let prfcntConfig = 0x40
    public static let prfcntCSGSelect = 0x44
    public static let prfcntFWEn = 0x48
    public static let prfcntCSGEn = 0x4C
    public static let prfcntCSFEn = 0x50
    public static let prfcntShaderEn = 0x54
    public static let prfcntTilerEn = 0x58
    public static let prfcntMMUL2En = 0x5C
    public static let idleTimer = 0x80
    public static let minSize = 0x84
  }

  public enum GlobalOutput {
    public static let ack = 0x00
    public static let dbAck = 0x08
    public static let haltStatus = 0x10
    public static let prfcntStatus = 0x14
    public static let prfcntInsert = 0x18
    public static let minSize = 0x1C
  }

  /// GLB_REQ's and GLB_ACK's bits (06 §6.4.2).
  public enum GlobalReq {
    /// Before 4.1: 1 asks the MCU to halt; never acknowledged.
    public static let halt: UInt32 = 1 << 0
    public static let cfgProgressTimer: UInt32 = 1 << 1
    public static let cfgAllocEn: UInt32 = 1 << 2
    public static let cfgPwroffTimer: UInt32 = 1 << 3
    public static let protmEnter: UInt32 = 1 << 4
    public static let prfcntEnable: UInt32 = 1 << 5
    public static let prfcntSample: UInt32 = 1 << 6
    public static let counterEnable: UInt32 = 1 << 7
    public static let ping: UInt32 = 1 << 8
    public static let firmwareConfigUpdate: UInt32 = 1 << 9
    public static let idleEnable: UInt32 = 1 << 10
    /// From 4.1: the 3-bit state field (GlobalState).
    public static let stateShift: UInt32 = 12
    public static let stateMask: UInt32 = 7 << 12
    public static let inactiveCompute: UInt32 = 1 << 20
    public static let inactiveFragment: UInt32 = 1 << 21
    public static let inactiveTiler: UInt32 = 1 << 22
    public static let protmExit: UInt32 = 1 << 23
    public static let prfcntThreshold: UInt32 = 1 << 24
    public static let prfcntOverflow: UInt32 = 1 << 25
    public static let idle: UInt32 = 1 << 26
    public static let debugCSF: UInt32 = 1 << 30
    public static let debugHost: UInt32 = 1 << 31
    /// The bits the host raises by toggling (06 §6.3.2, kind 1).
    public static let toggles: UInt32 =
      cfgProgressTimer | cfgAllocEn | cfgPwroffTimer | protmEnter | prfcntSample | ping | firmwareConfigUpdate
    /// The level bits (kind 3).
    public static let levels: UInt32 = prfcntEnable | counterEnable | idleEnable
    /// The firmware's events, [26:20].
    public static let events: UInt32 =
      inactiveCompute | inactiveFragment | inactiveTiler | protmExit | prfcntThreshold | prfcntOverflow | idle
  }

  public enum GlobalState {
    public static let active: UInt32 = 0
    public static let halt: UInt32 = 1
    public static let sleep: UInt32 = 2
    public static let suspend: UInt32 = 3
  }

  /// GLB_HALT_STATUS's values (06 §6.4.5).
  public enum HaltStatus {
    public static let normal: UInt32 = 0x00
    public static let panic: UInt32 = 0x4E
    public static let watchdog: UInt32 = 0x4F
  }

  /// MCU_STATUS's value when halted (panthor 02), read by the driver.
  public static let mcuStatusHalt: UInt32 = 2

  public enum GroupControl {
    public static let features = 0x00
    public static let inputVA = 0x04
    public static let outputVA = 0x08
    public static let suspendSize = 0x0C
    public static let protmSuspendSize = 0x10
    public static let streamNum = 0x14
    public static let streamStride = 0x18
    public static let size = 0x1C
  }

  public enum GroupInput {
    public static let req = 0x00
    public static let ackIrqMask = 0x04
    public static let dbReq = 0x08
    public static let csIrqAck = 0x0C
    /// 64 bits.
    public static let allowCompute = 0x20
    /// 64 bits.
    public static let allowFragment = 0x28
    public static let allowOther = 0x30
    /// Before 4.0: the 32-bit endpoint request.
    public static let epReq = 0x34
    /// From 4.0: the 64-bit endpoint request.
    public static let epReq64 = 0x38
    /// 64 bits.
    public static let suspendBuf = 0x40
    /// 64 bits.
    public static let protmSuspendBuf = 0x48
    public static let config = 0x50
    public static let iterTraceConfig = 0x54
    public static let minSize = 0x58
  }

  public enum GroupOutput {
    public static let ack = 0x00
    public static let dbAck = 0x08
    public static let csIrqReq = 0x0C
    public static let statusEpCurrent = 0x10
    public static let statusEpReq = 0x14
    public static let statusState = 0x18
    public static let resourceDep = 0x1C
    public static let minSize = 0x20
  }

  /// CSG_REQ's and CSG_ACK's bits (06 §6.5.2).
  public enum GroupReq {
    public static let stateMask: UInt32 = 7
    public static let endpointConfig: UInt32 = 1 << 4
    public static let statusUpdate: UInt32 = 1 << 5
    public static let syncUpdate: UInt32 = 1 << 28
    public static let idle: UInt32 = 1 << 29
    public static let doorbell: UInt32 = 1 << 30
    public static let progressTimerEvent: UInt32 = 1 << 31
    /// What the host requests: [5:0].
    public static let hostBits: UInt32 = 0x3F
    /// The firmware's events the host acknowledges.
    public static let events: UInt32 = syncUpdate | idle | progressTimerEvent
  }

  /// The CSG state codes (06 §6.5.2). CSG_ACK.STATE 4 to 7 is corruption.
  public enum GroupState {
    public static let terminate: UInt32 = 0
    public static let start: UInt32 = 1
    public static let suspend: UInt32 = 2
    public static let resume: UInt32 = 3
  }

  public enum StreamControl {
    public static let features = 0x00
    public static let inputVA = 0x04
    public static let outputVA = 0x08
    public static let size = 0x0C
  }

  public enum StreamInput {
    public static let req = 0x00
    /// [3:0] priority, [15:8] doorbell.
    public static let config = 0x04
    public static let ackIrqMask = 0x0C
    /// 64 bits.
    public static let base = 0x10
    public static let size = 0x18
    /// 64 bits.
    public static let tilerHeapStart = 0x20
    /// 64 bits.
    public static let tilerHeapEnd = 0x28
    /// 64 bits.
    public static let userInput = 0x30
    /// 64 bits.
    public static let userOutput = 0x38
    public static let instrConfig = 0x40
    public static let instrBufferSize = 0x44
    public static let instrBufferBase = 0x48
    public static let instrBufferOffsetPointer = 0x50
    public static let minSize = 0x58
  }

  public enum StreamOutput {
    public static let ack = 0x00
    /// 64 bits.
    public static let statusCmdPtr = 0x40
    public static let statusWait = 0x48
    public static let statusReqResource = 0x4C
    /// 64 bits.
    public static let statusWaitSyncPointer = 0x50
    public static let statusWaitSyncValue = 0x58
    public static let statusScoreboards = 0x5C
    public static let statusBlockedReason = 0x60
    public static let statusWaitSyncValueHi = 0x64
    public static let fault = 0x80
    public static let fatal = 0x84
    /// 64 bits.
    public static let faultInfo = 0x88
    /// 64 bits.
    public static let fatalInfo = 0x90
    public static let heapVTStart = 0xC0
    public static let heapVTEnd = 0xC4
    public static let heapFragEnd = 0xCC
    /// 64 bits.
    public static let heapAddress = 0xD0
    public static let minSize = 0xD8
  }

  /// CS_REQ's and CS_ACK's bits (06 §6.6.2).
  public enum StreamReq {
    public static let stateMask: UInt32 = 7
    public static let extractEvent: UInt32 = 1 << 4
    public static let idleSyncWait: UInt32 = 1 << 8
    public static let idleProtmPending: UInt32 = 1 << 9
    public static let idleEmpty: UInt32 = 1 << 10
    public static let idleResourceReq: UInt32 = 1 << 11
    public static let tilerOOM: UInt32 = 1 << 26
    public static let protmPending: UInt32 = 1 << 27
    public static let fatal: UInt32 = 1 << 30
    public static let fault: UInt32 = 1 << 31
    /// The firmware's events (the host reads them through CSG_CS_IRQ).
    public static let events: UInt32 = tilerOOM | protmPending | fatal | fault
    public static let stop: UInt32 = 0
    public static let start: UInt32 = 1
  }

  /// The ring buffer's pages (06 §6.7.1): the input page the host writes, the
  /// output page the firmware writes.
  public enum RingInput {
    public static let insert = 0x00
    public static let extract = 0x08
  }
  public enum RingOutput {
    public static let extract = 0x00
    public static let active = 0x08
  }

  /// CS_STATUS_WAIT's fields and CS_STATUS_BLOCKED_REASON's values (06 §6.6.4).
  public enum Wait {
    public static let syncWait: UInt32 = 1 << 31
    public static let syncWaitSize64: UInt32 = 1 << 30
    public static let conditionShift: UInt32 = 24
    /// Condition 0 is LE, 1 is GT.
    public static let conditionLE: UInt32 = 0
    public static let conditionGT: UInt32 = 1
  }
  public enum BlockedReason {
    public static let unblocked: UInt32 = 0
    public static let scoreboard: UInt32 = 1
    public static let progress: UInt32 = 2
    public static let syncObject: UInt32 = 3
    public static let deferred: UInt32 = 4
    public static let resource: UInt32 = 5
    public static let flush: UInt32 = 6
  }

  /// The ids `SharedMemory.lock` takes: one per request word's instance
  /// (06 §6.3.3): the global interface, each CSG slot, each CS slot.
  public enum Lock {
    public static let global = 0
    public static func group(_ g: Int) -> Int { 1 + g }
    public static func stream(_ g: Int, _ s: Int) -> Int { 64 + g * 32 + s }
  }

  /// Which object a bounds check failed on.
  public enum Block: Equatable, Sendable {
    case globalControl, globalInput, globalOutput
    case groupControl, groupInput, groupOutput
    case streamControl, streamInput, streamOutput
  }

  /// What differs between slots that the host requires identical (policy).
  public enum Mismatch: Equatable, Sendable {
    case groupFeatures, suspendSize, protmSuspendSize, streamNum, streamFeatures
  }

  // MARK: Encodings

  /// A GLB_PWROFF_TIMER or GLB_IDLE_TIMER value (06 §6.4.4): a timeout in
  /// units of 1024 ticks, and the source in bit 31.
  public enum TimerSource: Sendable { case timestamp, cycles }

  /// The value for `microseconds` at `frequency` Hz of `source`:
  /// ceil(t * f / (10^6 * 1024)), clamped to 0x7FFFFFFF.
  public static func timer(microseconds: UInt64, frequency: UInt64, source: TimerSource) -> UInt32 {
    let sourceBit: UInt32 = source == .cycles ? 1 << 31 : 0
    let (product, overflow) = microseconds.multipliedReportingOverflow(by: frequency)
    let unit: UInt64 = 1_000_000 * 1024
    var ticks = overflow ? UInt64(0x7FFF_FFFF) : product / unit + (product % unit != 0 ? 1 : 0)
    if ticks > 0x7FFF_FFFF { ticks = 0x7FFF_FFFF }
    return sourceBit | UInt32(ticks)
  }

  /// With no frequency known at all: the maximum value, the cycle counter
  /// (policy, so that firmware still manages core power).
  public static let timerUnknown: UInt32 = 0xFFFF_FFFF

  /// The boot-time values (05 §5.6.3, policy).
  public static let powerOffMicroseconds: UInt64 = 10_000
  public static let idleMicroseconds: UInt64 = 800
  public static let progressTimerDefault: UInt32 = 2_560_000

  /// GLB_ACK_IRQ_MASK: bits 1, 2, 3, 8, 10 and 26, and the state field from 4.1.
  public static func globalAckIrqMask(_ version: CSFVersion) -> UInt32 {
    let base = GlobalReq.cfgProgressTimer | GlobalReq.cfgAllocEn | GlobalReq.cfgPwroffTimer | GlobalReq.ping
      | GlobalReq.idleEnable | GlobalReq.idle
    return version.hasGlobalState ? base | GlobalReq.stateMask : base
  }
}

/// A request or acknowledge word's arithmetic (06 §6.3.2, §6.3.3, §6.3.4):
/// what each side writes, as pure functions of the two words.
public enum ReqAck {
  /// REQ after the host toggles `mask`: each bit the inverse of its ACK.
  public static func toggled(req: UInt32, ack: UInt32, mask: UInt32) -> UInt32 {
    (~ack & mask) | (req & ~mask)
  }
  /// REQ after the host sets a field or level bits to `value` under `mask`.
  public static func set(req: UInt32, value: UInt32, mask: UInt32) -> UInt32 {
    (value & mask) | (req & ~mask)
  }
  /// REQ after the host acknowledges the firmware's `events`: each bit the
  /// ACK's current value.
  public static func acknowledged(req: UInt32, ack: UInt32, events: UInt32) -> UInt32 {
    (ack & events) | (req & ~events)
  }
  /// The bits of `mask` where the words differ: a host request the firmware
  /// has not done, or an event the host has not handled. For a field, any
  /// difference is the whole field pending.
  public static func pending(req: UInt32, ack: UInt32, mask: UInt32) -> UInt32 {
    (req ^ ack) & mask
  }
  /// A request is complete when ACK matches the REQ the host snapshot, over
  /// the whole mask. A field matching in some bits only is not complete.
  public static func complete(ack: UInt32, expected: UInt32, mask: UInt32) -> Bool {
    ack & mask == expected & mask
  }
}

/// The endpoint request (06 §6.5.4): the same bits in the 32-bit and the
/// 64-bit form (the high half is 0).
public struct EndpointRequest: Equatable, Sendable {
  public var compute: UInt32
  public var fragment: UInt32
  public var tiler: UInt32
  public var exclusiveCompute: Bool
  public var exclusiveFragment: Bool
  /// 0 to 15; a higher value is a higher priority.
  public var priority: UInt32

  public init(compute: UInt32 = 0, fragment: UInt32 = 0, tiler: UInt32 = 0, exclusiveCompute: Bool = false,
              exclusiveFragment: Bool = false, priority: UInt32 = 0) {
    self.compute = compute
    self.fragment = fragment
    self.tiler = tiler
    self.exclusiveCompute = exclusiveCompute
    self.exclusiveFragment = exclusiveFragment
    self.priority = priority
  }

  public init(raw: UInt32) {
    compute = raw & 0xFF
    fragment = raw >> 8 & 0xFF
    tiler = raw >> 16 & 0xF
    exclusiveCompute = raw & 1 << 20 != 0
    exclusiveFragment = raw & 1 << 21 != 0
    priority = raw >> 28
  }

  /// Fields past their width are masked, not carried into the next.
  public var raw: UInt32 {
    var v = compute & 0xFF | (fragment & 0xFF) << 8 | (tiler & 0xF) << 16 | (priority & 0xF) << 28
    if exclusiveCompute { v |= 1 << 20 }
    if exclusiveFragment { v |= 1 << 21 }
    return v
  }
}

/// CS_FEATURES (06 §6.6.1).
public struct CSFeatures: Equatable, Sendable {
  public let raw: UInt32
  public init(_ raw: UInt32) { self.raw = raw }
  /// The field holds the count minus one.
  public var workRegisters: Int { Int(raw & 0xFF) + 1 }
  public var scoreboards: Int { Int(raw >> 8 & 0xFF) }
  public var compute: Bool { raw & 1 << 16 != 0 }
  public var fragment: Bool { raw & 1 << 17 != 0 }
  public var tiler: Bool { raw & 1 << 18 != 0 }
}

/// Why the interface was refused, or a request could not be made.
public enum CSFError: Error, Equatable, Sendable {
  /// The mapped section is smaller than the global control block.
  case sectionTooSmall
  /// GLB_VERSION is 0: the firmware did not come up.
  case notBooted
  /// An object, or a control block, is not wholly inside the section, or is
  /// not 4-byte aligned.
  case outsideSection(CSF.Block, group: Int, stream: Int)
  case groupCount(Int)
  case streamCount(group: Int, count: Int)
  case mismatch(CSF.Mismatch, group: Int, stream: Int)
  /// A slot the interface does not have.
  case badSlot
  /// A ring buffer's size is not a power of two (06 §6.6.3).
  case badRingSize
  /// A CSG's START or RESUME is unacknowledged, so its inputs are left alone.
  case startPending
  /// A ring's INSERT is behind its EXTRACT (06 §6.6.6).
  case insertBeforeExtract
}

/// One CS slot's place in the section.
public struct CSLayout: Equatable, Sendable {
  public var control: Int
  public var input: Int
  public var output: Int
  public var features: CSFeatures

  public init(control: Int, input: Int, output: Int, features: CSFeatures) {
    self.control = control
    self.input = input
    self.output = output
    self.features = features
  }
}

/// One CSG slot's place in the section, and its CS slots.
public struct CSGLayout: Equatable, Sendable {
  public var control: Int
  public var input: Int
  public var output: Int
  public var features: UInt32
  public var suspendSize: Int
  public var protmSuspendSize: Int
  public var streamStride: Int
  public var streams: [CSLayout]

  public init(control: Int, input: Int, output: Int, features: UInt32 = 0, suspendSize: Int = 0,
              protmSuspendSize: Int = 0, streamStride: Int, streams: [CSLayout]) {
    self.control = control
    self.input = input
    self.output = output
    self.features = features
    self.suspendSize = suspendSize
    self.protmSuspendSize = protmSuspendSize
    self.streamStride = streamStride
    self.streams = streams
  }
}

/// The interface as discovered (05 §5.4.5): where every block is, bounds-
/// checked against the section.
public struct CSFLayout: Equatable, Sendable {
  public var version: CSFVersion
  public var features: UInt32
  /// 0 below 1.1.0, whatever the field holds.
  public var instrFeatures: UInt32
  public var prfcntSize: UInt32
  public var input: Int
  public var output: Int
  public var groupStride: Int
  public var groups: [CSGLayout]

  public var groupCount: Int { groups.count }
  /// CS slots in each CSG slot (every slot reports the same number).
  public var streamCount: Int { groups.first?.streams.count ?? 0 }
  /// CS work registers, from CS 0 of CSG 0 (reported to users with the
  /// fixed 4 the kernel keeps).
  public var workRegisters: Int { groups.first?.streams.first?.features.workRegisters ?? 0 }

  public init(version: CSFVersion, features: UInt32 = 0, instrFeatures: UInt32 = 0, prfcntSize: UInt32 = 0,
              input: Int, output: Int, groupStride: Int, groups: [CSGLayout]) {
    self.version = version
    self.features = features
    self.instrFeatures = instrFeatures
    self.prfcntSize = prfcntSize
    self.input = input
    self.output = output
    self.groupStride = groupStride
    self.groups = groups
  }

  /// The MCU address `va` as an offset in the section, if the object of
  /// `size` bytes there is wholly inside it and 4-byte aligned (05 §5.4.1).
  public static func resolve(_ va: UInt32, size: Int, limit: Int) -> Int? {
    guard va >= CSF.Section.base else { return nil }
    let offset = Int(va - CSF.Section.base)
    guard offset & 3 == 0, offset <= limit, size <= limit - offset else { return nil }
    return offset
  }

  static func resolve(_ va: UInt32, size: Int, limit: Int, _ block: CSF.Block, _ g: Int, _ s: Int)
    throws(CSFError) -> Int {
    guard let offset = resolve(va, size: size, limit: limit) else {
      throw .outsideSection(block, group: g, stream: s)
    }
    return offset
  }

  /// Reads the interface once the MCU has signalled its boot (05 §5.4.5).
  /// Rejects it whole on the first violation.
  public static func discover<M: SharedMemory>(_ m: M) throws(CSFError) -> CSFLayout {
    let limit = min(m.size, CSF.Section.regionSize)
    guard limit >= CSF.GlobalControl.size else { throw .sectionTooSmall }
    let rawVersion = m.load32(CSF.GlobalControl.version)
    guard rawVersion != 0 else { throw .notBooted }
    let version = CSFVersion(raw: rawVersion)
    let input = try resolve(m.load32(CSF.GlobalControl.inputVA), size: CSF.GlobalInput.minSize, limit: limit,
                            .globalInput, 0, 0)
    let output = try resolve(m.load32(CSF.GlobalControl.outputVA), size: CSF.GlobalOutput.minSize, limit: limit,
                             .globalOutput, 0, 0)
    let groupNum = Int(m.load32(CSF.GlobalControl.groupNum))
    guard groupNum >= CSF.Section.minGroups, groupNum <= CSF.Section.maxGroups else { throw .groupCount(groupNum) }
    let stride = Int(m.load32(CSF.GlobalControl.groupStride))
    var groups: [CSGLayout] = []
    groups.reserveCapacity(groupNum)
    for g in 0..<groupNum {
      let control = CSF.Section.firstGroup + g * stride
      guard stride & 3 == 0, control + CSF.GroupControl.size <= limit else {
        throw .outsideSection(.groupControl, group: g, stream: 0)
      }
      let gInput = try resolve(m.load32(control + CSF.GroupControl.inputVA), size: CSF.GroupInput.minSize,
                               limit: limit, .groupInput, g, 0)
      let gOutput = try resolve(m.load32(control + CSF.GroupControl.outputVA), size: CSF.GroupOutput.minSize,
                                limit: limit, .groupOutput, g, 0)
      let streamNum = Int(m.load32(control + CSF.GroupControl.streamNum))
      guard streamNum >= CSF.Section.minStreams, streamNum <= CSF.Section.maxStreams else {
        throw .streamCount(group: g, count: streamNum)
      }
      var group = CSGLayout(
        control: control, input: gInput, output: gOutput,
        features: m.load32(control + CSF.GroupControl.features),
        suspendSize: Int(m.load32(control + CSF.GroupControl.suspendSize)),
        protmSuspendSize: Int(m.load32(control + CSF.GroupControl.protmSuspendSize)),
        streamStride: Int(m.load32(control + CSF.GroupControl.streamStride)), streams: [])
      if let first = groups.first {
        if group.features != first.features { throw .mismatch(.groupFeatures, group: g, stream: 0) }
        if group.suspendSize != first.suspendSize { throw .mismatch(.suspendSize, group: g, stream: 0) }
        if group.protmSuspendSize != first.protmSuspendSize {
          throw .mismatch(.protmSuspendSize, group: g, stream: 0)
        }
        if streamNum != first.streams.count { throw .mismatch(.streamNum, group: g, stream: 0) }
      }
      group.streams.reserveCapacity(streamNum)
      for s in 0..<streamNum {
        let sControl = control + CSF.Section.firstStream + s * group.streamStride
        guard group.streamStride & 3 == 0, sControl + CSF.StreamControl.size <= limit else {
          throw .outsideSection(.streamControl, group: g, stream: s)
        }
        let sInput = try resolve(m.load32(sControl + CSF.StreamControl.inputVA), size: CSF.StreamInput.minSize,
                                 limit: limit, .streamInput, g, s)
        let sOutput = try resolve(m.load32(sControl + CSF.StreamControl.outputVA), size: CSF.StreamOutput.minSize,
                                  limit: limit, .streamOutput, g, s)
        let features = CSFeatures(m.load32(sControl + CSF.StreamControl.features))
        if let reference = groups.first?.streams.first ?? group.streams.first, features != reference.features {
          throw .mismatch(.streamFeatures, group: g, stream: s)
        }
        group.streams.append(CSLayout(control: sControl, input: sInput, output: sOutput, features: features))
      }
      groups.append(group)
    }
    return CSFLayout(
      version: version, features: m.load32(CSF.GlobalControl.features),
      instrFeatures: version.hasInstrFeatures ? m.load32(CSF.GlobalControl.instrFeatures) : 0,
      prfcntSize: m.load32(CSF.GlobalControl.prfcntSize), input: input, output: output, groupStride: stride,
      groups: groups)
  }
}
