// SPDX-License-Identifier: BSD-3-Clause

// The interpreter's instruction representation.
//
// An `Instr` is one Valhall instruction by the spec's own fields (valhall
// 10 to 13), not by its bits: an opcode, a data type, up to four source
// bytes in the encoding of 10 §10.5.1, a destination and its width,
// per-source widen or swizzle values (the raw field values of 10 §10.6.2
// and 11b §11b.1), negate and absolute-value bits, rounding, clamp,
// comparison and the other modifier fields, a memory width and access, a
// dependency slot, and the flow field (10 §10.9.2). Every modifier is the
// field's value as the spec tabulates it, so a decoded instruction maps
// field for field.
//
// THE ADAPTER POINT. The encoder and decoder (target ValhallISA) produce
// their own decoded type. To run decoded shaders, that type conforms to
// `InstrConvertible` (in a small target that depends on both, or in
// ValhallISA once it may depend on this one) and `Shader(decoded:)` takes
// it from there. The conversion is mechanical: the mapping from bit ranges
// to `Instr` fields is in `Adapter.swift`.

/// The flow field, 10 §10.9.2 (`[62:59]`).
public enum Flow: UInt8, Sendable {
  case none = 0, wait0, wait1, wait01, wait2, wait02, wait12, wait012
  case wait0126 = 8, wait = 9, reconverge = 10, waitResource = 12, discard = 13, end = 15

  /// The dependency slots a wait value waits on (bit n is slot n).
  public var waitSlots: UInt8 {
    switch self {
    case .wait0, .wait1, .wait01, .wait2, .wait02, .wait12, .wait012: rawValue
    case .wait0126: 0b0100_0111
    case .wait: 0b1100_0111
    default: 0
    }
  }
}

/// Data type of the classes that carry one, 10 §10.10.1.
public enum DataType: UInt8, Sendable {
  case u32 = 0, v2u16, v4u8, u64, f32, v2f16, f16, f64, s32, v2s16, v4s8, s64
  public var isSigned: Bool { rawValue >= 8 }
}

public enum Opcode: UInt8, Sendable {
  // Control flow and waiting (13).
  case nop, branch, jump, discard, barrier
  // Float (11a).
  case fadd, faddImm, faddLscale, fma, fmaRscale, fmin, fmax, fcmp, csel, flush, fround, ldexp
  // Integer, bitwise, shifts (11b). `shift` is the whole shift-and-logic family (§11b.5).
  case iadd, isub, imul, iaddImm, andImm, orImm, xorImm, idpadd, iabs, icmp, icmpMulti, mux
  case shift, mov, mkvecV2i16, mkvecV2i8, clz, popcount, bitrev, shadd, segAdd
  // Conversion (11c).
  case s8ToS32, u8ToU32, s16ToS32, u16ToU32, v2s8ToV2s16, v2u8ToV2u16
  case s32ToF32, u32ToF32, f32ToS32, f32ToU32, f16ToF32
  // Special functions (11c).
  case frcp, frsq, flogd, flog, fexp, fpow, frexpm, frexpe, fsinTable, fcosTable, fexpTable
  // Subgroup (13).
  case clper, wmask
  // Memory (12a).
  case load, store, atom, atom1, atom1Return, atomReturn, acmpxchg
  // The hardware vertex-output buffer's address (12a.5.2, 12c.4.1): a test model, see `DispatchConfig.hardwareBuffers`.
  case leaBufImm
  // A texel fetch over the test model `DispatchConfig.textureFetch` (12b): the handle is one value for the warp.
  case texFetch
  // Storage images over the test model `DispatchConfig.storageImage` (12b.10): LD_TEX, LEA_TEX and ST_CVT.
  case ldTex, leaTex, stCvt
  // A word of a descriptor in the resource table through a pseudo-table handle (12a.5, 12b.13.5), over `DispatchConfig.descriptorWord`.
  case ldPka
}

/// A source operand in the encoding of 10 §10.5.1, with the FAU page it needs.
public struct Operand: Sendable, Equatable {
  public var byte: UInt8
  /// The FAU page a user or special source needs (`nil` for registers and constants).
  public var page: UInt8?

  public init(byte: UInt8, page: UInt8? = nil) {
    self.byte = byte
    self.page = page
  }

  public static func r(_ n: Int) -> Operand { Operand(byte: UInt8(n)) }
  /// A register marked last use (`r5^`).
  public static func last(_ n: Int) -> Operand { Operand(byte: 0x40 | UInt8(n)) }
  /// Word `word` of user FAU slot `slot` counting from the start of the array (`u37.w1`).
  public static func u(_ slot: Int, _ word: Int = 0) -> Operand {
    Operand(byte: 0x80 | UInt8((slot % 32) << 1) | UInt8(word), page: UInt8(slot / 32))
  }
  /// Small constant `index` of the table of 10 §10.5.2.
  public static func k(_ index: Int) -> Operand { Operand(byte: 0xC0 | UInt8(index)) }
  /// Special FAU word (10 §10.5.3).
  public static func special(page: Int, entry: Int, word: Int = 0) -> Operand {
    Operand(byte: 0xE0 | UInt8(entry << 1) | UInt8(word), page: UInt8(page))
  }

  public static let zero = k(0)
  public static let ones = k(1)
  public static let oneF = k(16)
  public static let laneId = special(page: 3, entry: 1)
  public static let warpId = special(page: 0, entry: 2)
  public static let threadLocalPointer = special(page: 1, entry: 1)
  public static let workgroupLocalPointer = special(page: 1, entry: 3)
  public static let resourceTablePointer = special(page: 1, entry: 7)
  public static let pc = special(page: 3, entry: 15)
}

/// Small constants, 10 §10.5.2 (index 21 is "unavailable": the spec leaves its purpose open).
let smallConstants: [UInt32] = [
  0x0000_0000, 0xFFFF_FFFF, 0x7FFF_FFFF, 0xFAFC_FDFE, 0x0100_0000, 0x8000_2000, 0x7060_5030, 0xC0B0_A090,
  0x0302_0100, 0x0706_0504, 0x0B0A_0908, 0x0F0E_0D0C, 0x1312_1110, 0x1716_1514, 0x1B1A_1918, 0x1F1E_1D1C,
  0x3F80_0000, 0x3DCC_CCCD, 0x3EA2_F983, 0x3F31_7218, 0x4049_0FDB, 0x2724_28E0, 0x477F_FF00, 0x5C00_5BF8,
  0x2E66_0000, 0x3400_0000, 0x3800_0000, 0x3C00_0000, 0x4000_0000, 0x4400_0000, 0x4800_0000, 0x4248_0000,
]

public struct Instr: Sendable {
  public var op: Opcode
  public var dataType: DataType
  public var flow: Flow = .none
  /// The FAU page (`[58:57]`) the user and special sources address.
  public var fauPage: UInt8 = 0
  public var s0: UInt8 = 0xC0
  public var s1: UInt8 = 0xC0
  public var s2: UInt8 = 0xC0
  public var s3: UInt8 = 0xC0
  /// Destination register, or the first staging register of a message (`[45:40]`).
  public var dst: UInt8 = 0
  /// Destination width (`[47:46]`): 1 `h0`, 2 `h1`, 3 `none` (all 32 bits); 0 is `h01` where a form has it.
  public var dstWidth: UInt8 = 3
  /// The second staging register of the `S2RW` message forms (`[21:16]`).
  public var writeReg: UInt8 = 0
  /// Per-source widen or swizzle: the raw field value of the instruction's family (the identity is
  /// the family's, which `init` sets).
  public var widen0: UInt8 = 0
  public var widen1: UInt8 = 0
  public var widen2: UInt8 = 0
  /// Bit n is the negate (`neg`) or absolute-value (`abs`) modifier of source n (10 §10.6.3).
  public var neg: UInt8 = 0
  public var abs: UInt8 = 0
  /// Complement of source 2 (shift family) and of the result.
  public var notSrc2 = false
  public var notResult = false
  public var round: UInt8 = 0
  public var clamp: UInt8 = 0
  public var saturate = false
  /// `FMIN`/`FMAX` NaN handling (`sem`): 0 suppress, 1 propagate.
  public var sem: UInt8 = 0
  public var cmp: UInt8 = 0
  /// Combine of the compare family (0 or, 1 and, 2 multi) and the branch combine test (0 none, 1 h0,
  /// 2 h1, 3 and, 4 lowbits): the op decides.
  public var combine: UInt8 = 0
  public var resultType: UInt8 = 0
  /// `BRANCH`/`JUMP`: invert the condition after the combine.
  public var not = false
  /// `FMA_RSCALE` special (0 none, 1 n, 2 left, 3 n_add); `FREXP*` mode (0 none, 1 sqrt, 2 log);
  /// `MUX` condition (0 neg, 1 int_zero, 2 fp_zero, 3 bit).
  public var special: UInt8 = 0
  /// `FLUSH`: NaN mode (0 none, 1 flush_nan, 2 quiet_nan), subnormal and infinity flush.
  public var nanMode: UInt8 = 0
  public var ftz = false
  public var flushInf = false
  /// `CLZ`: an all-zero lane gives all ones.
  public var mask = false
  /// `FREXPE`: negate the result.
  public var negResult = false
  /// `R1I` immediate; `BRANCH` offset in 8-byte instructions (`offset`); memory byte offset (`offset`).
  public var imm: UInt32 = 0
  public var offset: Int32 = 0
  /// `SHADD` shift amount.
  public var shiftAmount: UInt8 = 0
  /// Shift family operation: 0 rshift, 1 lshift, 2 rrot, 3 lrot, 4 arshift.
  public var shiftOp: UInt8 = 0
  /// Memory width (10 §10.10.4): 0 i8, 1 i16, 2 i24, 3 i32, 4 i48, 5 i64, 6 i96, 7 i128.
  public var memWidth: UInt8 = 3
  /// Load result lane or store source lane (12a §12a.1.3; `[38:36]`).
  public var lane: UInt8 = 0
  /// Loads: zero-extend (`[39]` set) rather than sign-extend.
  public var zeroExtend = true
  /// Access hint: 0 none, 1 istream, 2 estream, 3 force.
  public var access: UInt8 = 0
  /// The dependency slot a message signals.
  public var slot: UInt8 = 0
  /// Atomic operation code (12a §12a.8.1).
  public var atomOp: UInt8 = 0
  /// `CLPER`/`WMASK`: subgroup (0..3 for 2, 4, 8, 16 lanes), lane operation, inactive-result code.
  public var subgroup: UInt8 = 3
  public var laneOp: UInt8 = 0
  public var inactive: UInt8 = 0

  public init(_ op: Opcode, _ type: DataType? = nil) {
    let type = type ?? Instr.defaultType(op)
    self.op = op
    self.dataType = type
    let id = Instr.identityWiden(op, type)
    widen0 = id.0
    widen1 = id.1
    widen2 = id.2
    if op == .mux { special = 1 }
  }

  /// The data type of the float instructions that have f32 and v2f16 forms, when none is given.
  static func defaultType(_ op: Opcode) -> DataType {
    switch op {
    case .fadd, .faddImm, .faddLscale, .fma, .fmaRscale, .fmin, .fmax, .fcmp, .flush, .fround, .ldexp, .frcp, .frsq, .flogd, .fexp:
      .f32
    default: .u32
    }
  }

  /// The family's identity widen or swizzle value (10 §10.6.2): 2 for the two-lane swizzles, 4 for the
  /// shift-amount lane `b0` of the 32 and 64-bit shifts, 0 elsewhere.
  static func identityWiden(_ op: Opcode, _ t: DataType) -> (UInt8, UInt8, UInt8) {
    switch t {
    case .v2f16, .v2u16, .v2s16:
      if op == .shift { return (2, 0, 0) }
      if op == .mkvecV2i16 { return (0, 0, 0) }
      return (2, 2, 2)
    case .u32, .u64, .s32, .s64:
      if op == .shift { return (0, 4, 0) }
      return (0, 0, 0)
    default: return (0, 0, 0)
    }
  }

  // MARK: Fluent modifiers (tests and the adapter use whichever reads better).

  public func with<T>(_ key: WritableKeyPath<Instr, T>, _ value: T) -> Instr {
    var i = self
    i[keyPath: key] = value
    return i
  }

  /// Sets the sources (and the FAU page their kinds need).
  public func sources(_ a: Operand? = nil, _ b: Operand? = nil, _ c: Operand? = nil, _ d: Operand? = nil) -> Instr {
    var i = self
    for (n, o) in [a, b, c, d].enumerated() {
      guard let o else { continue }
      switch n {
      case 0: i.s0 = o.byte
      case 1: i.s1 = o.byte
      case 2: i.s2 = o.byte
      default: i.s3 = o.byte
      }
      if let p = o.page { i.fauPage = p }
    }
    return i
  }
}
