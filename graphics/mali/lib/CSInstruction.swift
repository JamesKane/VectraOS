// SPDX-License-Identifier: BSD-3-Clause

// The command-stream instructions a user driver writes (chinese-wall's
// valhall 01, sections 1.2 to 1.10): one 64-bit word each, the opcode in
// bits [63:56]. Pure functions from fields to words; a stream's shape and
// register use are CSBuilder's. Bits a field table doesn't name are zero.
// Arch 12 (the G720) first: arch 10's SET_SB_ENTRY is here, arch 13's
// register-arithmetic families are not.

/// A branch condition: the 32-bit signed value in the register against zero.
public enum CSCondition: UInt64, Sendable {
  case lessOrEqual = 0
  case greater = 1
  case equal = 2
  case notEqual = 3
  case less = 4
  case greaterOrEqual = 5
  case always = 6
}

/// SYNC_WAIT*'s two usable conditions (01 section 1.7).
public enum CSSyncCondition: UInt64, Sendable {
  /// Unblocks when the memory value is at most the reference.
  case lessOrEqual = 0
  /// Unblocks when the memory value is above the reference.
  case greater = 1
}

/// SYNC_ADD/SET's scope: system (the CPU and devices see it) or the group's.
public enum CSScope: UInt64, Sendable {
  case system = 0
  case group = 2
}

/// STORE_STATE's value (01 section 1.7).
public enum CSStateValue: UInt64, Sendable {
  case timestamp = 0
  case cycleCount = 1
  case disjointCount = 2
  case errorStatus = 3
}

/// SET_STATE's targets (01 section 1.6).
public enum CSStateTarget: UInt64, Sendable {
  case endpointSlot = 0
  case otherSlot = 1
  case deferredSlot = 2
  case streamMask = 8
  case waitMask = 9
}

/// FLUSH_CACHE2's L2 and LSC modes (mode 2 is undefined).
public enum CSFlushMode: UInt64, Sendable {
  case none = 0
  case clean = 1
  case cleanInvalidate = 3
}

/// FLUSH_CACHE2's mode for the caches in front of the texture unit and tile readers.
public enum CSOtherFlush: UInt64, Sendable {
  case none = 0
  case invalidate = 2
}

/// REQ_RESOURCE's bits.
public struct CSResources: Equatable, Sendable {
  public var rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static let compute = CSResources(rawValue: 1)
  public static let fragment = CSResources(rawValue: 2)
  public static let tiler = CSResources(rawValue: 4)
  public static let idvs = CSResources(rawValue: 8)
  public static func | (a: CSResources, b: CSResources) -> CSResources { CSResources(rawValue: a.rawValue | b.rawValue) }
}

/// NEXT_SB_ENTRY's slot type.
public enum CSSlotType: UInt64, Sendable {
  case noChange = 0
  case endpoint = 1
  case other = 2
  case deferred = 3
}

public enum CSInstruction {
  @inline(__always) private static func reg(_ r: Int) -> UInt64 { UInt64(truncatingIfNeeded: r) & 0xFF }
  @inline(__always) private static func mask16(_ m: UInt16) -> UInt64 { UInt64(m) << 16 }

  // MARK: Opcodes (01 section 1.2)
  public static let opNOP: UInt64 = 0
  public static let opMOVE48: UInt64 = 1
  public static let opMOVE32: UInt64 = 2
  public static let opWAIT: UInt64 = 3
  public static let opRUN_COMPUTE: UInt64 = 4
  public static let opADD_IMMEDIATE32: UInt64 = 16
  public static let opADD_IMMEDIATE64: UInt64 = 17
  public static let opCOMPARE_SELECT32: UInt64 = 18
  public static let opLOGIC_OP32: UInt64 = 19
  public static let opLOAD_MULTIPLE: UInt64 = 20
  public static let opSTORE_MULTIPLE: UInt64 = 21
  public static let opBRANCH: UInt64 = 22
  public static let opSET_SB_ENTRY: UInt64 = 23
  public static let opSET_EXCEPTION_HANDLER: UInt64 = 25
  public static let opNEXT_SB_ENTRY: UInt64 = 26
  public static let opSET_STATE: UInt64 = 27
  public static let opSET_STATE_IMM32: UInt64 = 28
  public static let opCALL: UInt64 = 32
  public static let opJUMP: UInt64 = 33
  public static let opREQ_RESOURCE: UInt64 = 34
  public static let opFLUSH_CACHE2: UInt64 = 36
  public static let opSYNC_ADD32: UInt64 = 37
  public static let opSYNC_SET32: UInt64 = 38
  public static let opSYNC_WAIT32: UInt64 = 39
  public static let opSTORE_STATE: UInt64 = 40
  public static let opRUN_COMPUTE_INDIRECT: UInt64 = 44
  public static let opERROR_BARRIER: UInt64 = 47
  public static let opSYNC_ADD64: UInt64 = 51
  public static let opSYNC_SET64: UInt64 = 52
  public static let opSYNC_WAIT64: UInt64 = 53

  // MARK: Registers and constants

  /// NOP: no effect; the hardware ignores the fields, so a driver may leave markers.
  public static func nop(type: UInt8 = 0, payload: UInt64 = 0) -> UInt64 {
    opNOP << 56 | UInt64(type) << 48 | payload & 0xFFFF_FFFF_FFFF
  }
  /// MOVE48: the immediate to the pair `dst`, `dst + 1` (its high 16 bits, zero extended).
  public static func mov48(_ dst: Int, _ immediate: UInt64) -> UInt64 {
    opMOVE48 << 56 | reg(dst) << 48 | immediate & 0xFFFF_FFFF_FFFF
  }
  public static func mov32(_ dst: Int, _ immediate: UInt32) -> UInt64 {
    opMOVE32 << 56 | reg(dst) << 48 | UInt64(immediate)
  }
  /// dst = src + immediate, 32-bit wrap.
  public static func add32(dst: Int, src: Int, immediate: Int32) -> UInt64 {
    opADD_IMMEDIATE32 << 56 | reg(dst) << 48 | reg(src) << 40 | UInt64(UInt32(bitPattern: immediate))
  }
  /// The pair `dst` = the pair `src` + the sign-extended immediate.
  public static func add64(dst: Int, src: Int, immediate: Int32) -> UInt64 {
    opADD_IMMEDIATE64 << 56 | reg(dst) << 48 | reg(src) << 40 | UInt64(UInt32(bitPattern: immediate))
  }
  /// dst = the unsigned minimum of the two sources.
  public static func umin32(dst: Int, _ a: Int, _ b: Int) -> UInt64 {
    opCOMPARE_SELECT32 << 56 | reg(dst) << 48 | reg(a) << 40 | reg(b) << 32
  }
  /// dst = a bitwise function of `a` and `b` (arch 11 and later): bit k of `truthTable` is the
  /// result when (a, b) is (1,1), (1,0), (0,1), (0,0) for k = 0 to 3. With `bitIndex`, the value
  /// of register `b` is a bit number n, and the second operand is the mask with bit n set.
  public static func logic32(dst: Int, _ a: Int, _ b: Int, truthTable: UInt8, bitIndex: Bool = false) -> UInt64 {
    opLOGIC_OP32 << 56 | reg(dst) << 48 | reg(a) << 40 | reg(b) << 32 | (bitIndex ? 1 << 4 : 0)
      | UInt64(truthTable & 0xF)
  }
  public static let logicOR: UInt8 = 7
  public static let logicAND: UInt8 = 1
  public static let logicXOR: UInt8 = 6
  public static let logicMove: UInt8 = 3
  public static let logicAndNot: UInt8 = 2

  // MARK: Memory

  /// For the k-th set bit i of `mask` (k from 0 at the least significant bit), register
  /// `base + i` receives the word at address + offset + 4k: the memory words are packed in
  /// the order of the set bits (01 section 1.4.2). Asynchronous on the other slot.
  public static func loadMultiple(base: Int, address: Int, offset: Int16 = 0, mask: UInt16) -> UInt64 {
    opLOAD_MULTIPLE << 56 | reg(base) << 48 | reg(address) << 40 | mask16(mask) | UInt64(UInt16(bitPattern: offset))
  }
  /// The same packing, from the registers to memory.
  public static func storeMultiple(base: Int, address: Int, offset: Int16 = 0, mask: UInt16) -> UInt64 {
    opSTORE_MULTIPLE << 56 | reg(base) << 48 | reg(address) << 40 | mask16(mask) | UInt64(UInt16(bitPattern: offset))
  }

  // MARK: Control

  /// Continue `offset` instructions from the one after this, if the register's value meets the condition.
  public static func branch(_ condition: CSCondition, register: Int, offset: Int16) -> UInt64 {
    opBRANCH << 56 | reg(register) << 40 | condition.rawValue << 28 | UInt64(UInt16(bitPattern: offset))
  }
  /// Call the stream at the address pair for the byte length in `size`.
  public static func call(address: Int, size: Int) -> UInt64 {
    opCALL << 56 | reg(address) << 40 | reg(size) << 32
  }
  /// As CALL, with no return.
  public static func jump(address: Int, size: Int) -> UInt64 {
    opJUMP << 56 | reg(address) << 40 | reg(size) << 32
  }
  public static func requestResources(_ r: CSResources) -> UInt64 { opREQ_RESOURCE << 56 | r.rawValue }
  public static let errorBarrier: UInt64 = opERROR_BARRIER << 56
  /// Run the stream range (address pair, length register) when exception `type` is raised;
  /// a zero address or length unregisters.
  public static func setExceptionHandler(type: UInt8, address: Int, size: Int) -> UInt64 {
    opSET_EXCEPTION_HANDLER << 56 | reg(address) << 40 | reg(size) << 32 | UInt64(type)
  }

  // MARK: Scoreboards

  /// Stall until the counts of every slot in `mask` are zero.
  public static func wait(mask: UInt16) -> UInt64 { opWAIT << 56 | mask16(mask) }
  /// Stall until the slots in the wait mask (SET_STATE) are zero (arch 11 and later).
  public static let waitIndirect: UInt64 = opWAIT << 56 | 1 << 33
  /// Arch 10: both entries together.
  public static func setScoreboardEntry(endpoint: Int, other: Int) -> UInt64 {
    opSET_SB_ENTRY << 56 | UInt64(other & 0xF) << 4 | UInt64(endpoint & 0xF)
  }
  /// Arch 11 and later: a state value from a register.
  public static func setState(_ target: CSStateTarget, from register: Int) -> UInt64 {
    opSET_STATE << 56 | reg(register) << 40 | target.rawValue << 32
  }
  public static func setState(_ target: CSStateTarget, immediate: UInt32) -> UInt64 {
    opSET_STATE_IMM32 << 56 | target.rawValue << 32 | UInt64(immediate)
  }
  /// Advance the selected slot, returning its index (or, with `mask`, its one-bit mask) in `dst`.
  public static func nextScoreboardEntry(_ type: CSSlotType, mask: Bool = false, dst: Int) -> UInt64 {
    opNEXT_SB_ENTRY << 56 | reg(dst) << 48 | (mask ? 1 << 36 : 0) | type.rawValue << 32
  }

  // MARK: Synchronisation and cache

  /// FLUSH_CACHE2 (always asynchronous): modes in [3:0], [7:4], [11:8]; the flush id's register in
  /// [47:40] (a user driver's register holds zero); the slot to signal in [51:48].
  public static func flushCache2(
    l2: CSFlushMode, lsc: CSFlushMode, other: CSOtherFlush = .none, flushIDRegister: Int, waitMask: UInt16 = 0,
    signalSlot: Int = 0, deferred: Bool = false
  ) -> UInt64 {
    opFLUSH_CACHE2 << 56 | (deferred ? 1 << 52 : 0) | UInt64(signalSlot & 0xF) << 48 | reg(flushIDRegister) << 40
      | mask16(waitMask) | other.rawValue << 8 | lsc.rawValue << 4 | l2.rawValue
  }

  private static func sync(
    _ op: UInt64, address: Int, data: Int, waitMask: UInt16, signalSlot: Int, scope: CSScope, errorPropagate: Bool,
    deferred: Bool
  ) -> UInt64 {
    op << 56 | (deferred ? 1 << 52 : 0) | UInt64(signalSlot & 0xF) << 48 | reg(address) << 40 | reg(data) << 32
      | mask16(waitMask) | scope.rawValue << 1 | (errorPropagate ? 1 : 0)
  }
  /// Atomically add the 64-bit pair `value` to the 64-bit word at the address pair `address`.
  public static func syncAdd64(
    address: Int, value: Int, waitMask: UInt16 = 0, signalSlot: Int = 0, scope: CSScope = .system,
    errorPropagate: Bool = false, deferred: Bool = false
  ) -> UInt64 {
    sync(opSYNC_ADD64, address: address, data: value, waitMask: waitMask, signalSlot: signalSlot, scope: scope,
         errorPropagate: errorPropagate, deferred: deferred)
  }
  public static func syncAdd32(
    address: Int, value: Int, waitMask: UInt16 = 0, signalSlot: Int = 0, scope: CSScope = .system,
    errorPropagate: Bool = false, deferred: Bool = false
  ) -> UInt64 {
    sync(opSYNC_ADD32, address: address, data: value, waitMask: waitMask, signalSlot: signalSlot, scope: scope,
         errorPropagate: errorPropagate, deferred: deferred)
  }
  public static func syncSet64(
    address: Int, value: Int, waitMask: UInt16 = 0, signalSlot: Int = 0, scope: CSScope = .system,
    errorPropagate: Bool = false, deferred: Bool = false
  ) -> UInt64 {
    sync(opSYNC_SET64, address: address, data: value, waitMask: waitMask, signalSlot: signalSlot, scope: scope,
         errorPropagate: errorPropagate, deferred: deferred)
  }
  public static func syncSet32(
    address: Int, value: Int, waitMask: UInt16 = 0, signalSlot: Int = 0, scope: CSScope = .system,
    errorPropagate: Bool = false, deferred: Bool = false
  ) -> UInt64 {
    sync(opSYNC_SET32, address: address, data: value, waitMask: waitMask, signalSlot: signalSlot, scope: scope,
         errorPropagate: errorPropagate, deferred: deferred)
  }
  /// Block until the 64-bit value at the address pair meets `condition` against the pair `reference`.
  public static func syncWait64(
    address: Int, reference: Int, condition: CSSyncCondition, errorReject: Bool = false
  ) -> UInt64 {
    opSYNC_WAIT64 << 56 | reg(address) << 40 | reg(reference) << 32 | condition.rawValue << 28 | (errorReject ? 1 : 0)
  }
  public static func syncWait32(
    address: Int, reference: Int, condition: CSSyncCondition, errorReject: Bool = false
  ) -> UInt64 {
    opSYNC_WAIT32 << 56 | reg(address) << 40 | reg(reference) << 32 | condition.rawValue << 28 | (errorReject ? 1 : 0)
  }
  /// Write a hardware state value (64 bits) at address + offset.
  public static func storeState(
    address: Int, state: CSStateValue, offset: Int16 = 0, waitMask: UInt16 = 0, signalSlot: Int = 0,
    deferred: Bool = false
  ) -> UInt64 {
    opSTORE_STATE << 56 | (deferred ? 1 << 52 : 0) | UInt64(signalSlot & 0xF) << 48 | reg(address) << 40
      | state.rawValue << 32 | mask16(waitMask) | UInt64(UInt16(bitPattern: offset))
  }

  // MARK: Runs

  /// RUN_COMPUTE's operand word (01 section 1.9.2): the register pairs it reads are selected by
  /// `srt`, `spd`, `tsd` and `fau` (0 to 3: the pair at register 0, 16, 24 or 8 plus twice the select).
  /// - Parameters:
  ///   - taskIncrement: workgroups per task along `taskAxis` (14 bits).
  ///   - epLimit: arch 12 and later; 0 for no extra limit.
  public static func runCompute(
    taskIncrement: UInt32, taskAxis: Int, epLimit: UInt8 = 0, srt: Int = 0, spd: Int = 0, tsd: Int = 0, fau: Int = 0,
    stage: UInt8 = 0
  ) -> UInt64 {
    opRUN_COMPUTE << 56 | UInt64(stage & 0xF) << 48 | UInt64(fau & 3) << 46 | UInt64(tsd & 3) << 44
      | UInt64(spd & 3) << 42 | UInt64(srt & 3) << 40 | UInt64(epLimit) << 16 | UInt64(taskAxis & 3) << 14
      | UInt64(taskIncrement & 0x3FFF)
  }
  /// As RUN_COMPUTE, with the workgroups per task in 16 bits. The driver the spec was read from loads
  /// the grid size itself and uses RUN_COMPUTE, since this form has been seen to hang (01 section 1.9.2).
  public static func runComputeIndirect(
    workgroupsPerTask: UInt32, epLimit: UInt8 = 0, srt: Int = 0, spd: Int = 0, tsd: Int = 0, fau: Int = 0,
    stage: UInt8 = 0
  ) -> UInt64 {
    opRUN_COMPUTE_INDIRECT << 56 | UInt64(stage & 0xF) << 48 | UInt64(fau & 3) << 46 | UInt64(tsd & 3) << 44
      | UInt64(spd & 3) << 42 | UInt64(srt & 3) << 40 | UInt64(epLimit) << 16 | UInt64(workgroupsPerTask & 0xFFFF)
  }
}

/// LOAD_MULTIPLE and STORE_MULTIPLE pack their memory words in the order of the set mask bits.
public enum CSPacking {
  /// The index of the memory word register `base + bit` uses: the number of set bits below `bit`;
  /// nil when the bit is clear.
  public static func wordIndex(mask: UInt16, bit: Int) -> Int? {
    guard bit >= 0, bit < 16, mask >> UInt16(bit) & 1 == 1 else { return nil }
    return (mask & ((UInt16(1) << UInt16(bit)) &- 1)).nonzeroBitCount
  }
}
