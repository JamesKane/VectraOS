// SPDX-License-Identifier: BSD-3-Clause

// The Valhall shader instruction model (D174): what an instruction is, as
// data. Written from chinese-wall's specs/valhall 10 to 13 only; the tables
// that fill these types are transcribed from those sections (Tables*.swift).
//
// An instruction is one 64-bit word. The word's layout is a *definition*
// (`InstructionDef`: a base word with its exact bits set, and the list of its
// free fields); an `Instruction` is a definition plus a value for each free
// field and the flow field. Encoding, decoding, the assembler notation of
// valhall 10.14 and the validator all run over those definitions.

/// The execution unit of an instruction at arch 11 and later (valhall 10.11).
public enum Unit: UInt8, Sendable {
  case fma, cvt, sfu, msg

  public var name: String {
    switch self {
    case .fma: "fma"
    case .cvt: "cvt"
    case .sfu: "sfu"
    case .msg: "msg"
    }
  }
}

/// The instruction class, `[56:52]` (valhall 10.2.2).
public struct ISAClass: Equatable, Sendable {
  public var code: UInt8
  public init(code: UInt8) { self.code = code }

  public static let n0 = ISAClass(code: 0)
  public static let n1 = ISAClass(code: 1)
  public static let n2 = ISAClass(code: 2)
  public static let n3 = ISAClass(code: 3)
  public static let s0 = ISAClass(code: 4)
  public static let s1 = ISAClass(code: 5)
  public static let s2 = ISAClass(code: 6)
  public static let s3 = ISAClass(code: 7)
  public static let r1 = ISAClass(code: 9)
  public static let r2 = ISAClass(code: 10)
  public static let r3 = ISAClass(code: 11)
  public static let r3a = ISAClass(code: 12)
  public static let r3cmp = ISAClass(code: 15)
  public static let m3 = ISAClass(code: 16)
  public static let r1i = ISAClass(code: 17)
  public static let s2rw = ISAClass(code: 18)
  public static let s3a = ISAClass(code: 19)
  public static let r4csel = ISAClass(code: 21)
  public static let r4fmar = ISAClass(code: 22)
  public static let s4 = ISAClass(code: 23)
  public static let d1 = ISAClass(code: 25)
  public static let d2 = ISAClass(code: 26)
  public static let d3 = ISAClass(code: 27)

  static let names: [String] = [
    "N0", "N1", "N2", "N3", "S0", "S1", "S2", "S3", "R0", "R1", "R2", "R3", "R3A", "R2A", "S2X", "R3_CMP",
    "M3", "R1I", "S2RW", "S3A", "?20", "R4_CSEL", "R4_FMAR", "S4", "?24", "D1", "D2", "D3", "?28", "?29", "?30",
    "D3_CMP",
  ]
  /// The hardware's name for the class (`R3_CMP`, `S2RW`).
  public var name: String { Int(code) < ISAClass.names.count ? ISAClass.names[Int(code)] : "?" }

  /// The class of a message instruction: it has staging registers and a slot.
  public var isMessage: Bool {
    switch code {
    case 4, 5, 6, 7, 18, 19, 23: true
    default: false
    }
  }
}

/// The flow field, `[62:59]` (valhall 10.9.2): one wait, or one control.
public enum Flow: UInt8, Sendable {
  case none = 0, wait0, wait1, wait01, wait2, wait02, wait12, wait012, wait0126, wait
  case reconverge, reserved11, waitResource, discard, reserved14, end

  public var name: String {
    switch self {
    case .none: "none"
    case .wait0: "wait0"
    case .wait1: "wait1"
    case .wait01: "wait01"
    case .wait2: "wait2"
    case .wait02: "wait02"
    case .wait12: "wait12"
    case .wait012: "wait012"
    case .wait0126: "wait0126"
    case .wait: "wait"
    case .reconverge: "reconverge"
    case .reserved11: "reserved11"
    case .waitResource: "wait_resource"
    case .discard: "discard"
    case .reserved14: "reserved14"
    case .end: "end"
    }
  }

  /// A flow value by its assembler name.
  public static func named(_ s: String) -> Flow? {
    var v: UInt8 = 0
    while v < 16 {
      if let f = Flow(rawValue: v), f.name.sameBytes(s), f != .reserved11, f != .reserved14, f != .none { return f }
      v += 1
    }
    return nil
  }

  /// A wait on general slots, as a bit set (bit 0 = slot 0). `wait0126` and
  /// `wait` cover all three; control values cover none.
  public var generalSlots: UInt8 {
    switch rawValue {
    case 1...7: rawValue
    case 8, 9: 7
    default: 0
    }
  }
  /// Waits on slot 6 (`wait0126`, `wait`).
  public var waitsSlot6: Bool { self == .wait0126 || self == .wait }
  /// Waits on slot 7 (`wait`).
  public var waitsSlot7: Bool { self == .wait }
  /// Waits on outstanding resource reads (`wait_resource`, `wait`).
  public var waitsResource: Bool { self == .waitResource || self == .wait }
  /// Any wait value.
  public var isWait: Bool { (rawValue >= 1 && rawValue <= 9) || rawValue == 12 }
}

/// A run of bits of the word. A field may be made of two (an offset split
/// into its low byte and a high nibble); the first range holds the low bits.
public struct BitRange: Equatable, Sendable {
  public var hi: UInt8
  public var lo: UInt8
  public var width: Int { Int(hi) - Int(lo) + 1 }
  public var mask: UInt64 { (width == 64 ? ~0 : ((1 << UInt64(width)) - 1)) << UInt64(lo) }
}

/// How a field's value is read and written.
public enum FieldKind: UInt8, Sendable {
  /// An 8-bit source operand (valhall 10.5.1), 32 bits wide.
  case src32
  /// A source naming an even register pair or a whole FAU slot.
  case src64
  /// A 64-bit source used as a memory address (printed `[r0:r1]`).
  case addr64
  /// A register, 6 bits.
  case register
  /// A register that names an even pair (a 64-bit destination).
  case registerPair
  /// A named value from a `Family`.
  case enumeration
  /// One bit, printed as its name when set.
  case flag
  /// An unsigned immediate, printed `#0x..`.
  case immediate
  /// A signed immediate, printed `#-12`.
  case signedImmediate
  /// An unsigned operand printed `name:value`.
  case named
  /// A signed operand printed `name:value`.
  case namedSigned
  /// A distance in bytes, stored as a count of 8-byte instructions (`BLEND`'s
  /// `skip:N`); written and printed in bytes, which must be a multiple of 8.
  case distance8
  /// An unsigned operand printed `name:value` only when it is not zero
  /// (reserved or ignored bits that a word may still carry).
  case optional
  /// A register count: the field holds the count.
  case count
  /// A register count where 0 means 8 (the texture read count).
  case count8
  /// A register count stored minus one (the write counts).
  case countMinusOne
}

/// A value that the hardware computes from other fields (valhall 10.13.1:
/// "derived"). The encoder sets such a field; it is not a free choice.
public enum DerivedRule: UInt8, Sendable {
  case none
  /// The field is fixed by the variant: it always holds its default.
  case constant
  /// `FMUL`: neg of src2 is 0 if round is `round_down`, else 1.
  case fmulNeg2
  /// `F32_TO_F16`: neg of src1 is 0 if round is `round_down`, else 1.
  case f2hNeg1
  /// Loads: 2 registers if the lane is `d0`, 1 otherwise (`i8`, `i16`, `i32`).
  case loadCount
  /// Conversions and typed loads: `(vector size >> h) + 1`, h = 1 for 16-bit formats.
  case formatCount
  /// `LD_VAR_BUF*` f32 variant: vector size + 1.
  case varBuf32Count
  /// `LD_VAR_BUF*` f16 variant: `(vector size >> 1) + 1`.
  case varBuf16Count
  /// 64-bit atomics: 1 for `aaddu`/`aadds`, else 2.
  case atomCount
  /// `LD_VAR_SPECIAL`: vector size + 1.
  case specialCount
  /// `BLEND`: 2 for a 16-bit register format, else 4.
  case blendCount
  /// Texture read counts, by instruction (valhall 12b.5). The gradient's is
  /// (c << derivative) + projection; 5 and 7 are not encodable.
  case texSingleRead, texFetchRead, texGatherRead, texGradientRead
  /// The write count of `TEX_DUAL` and `VAR_TEX_DUAL` (12b.8.3, 12b.9.3): the
  /// primary block's registers plus the secondary's; a value outside what
  /// the two widths allow is brought into range.
  case texDualWrite, varTexDualWrite
  /// Texture write count: registers of the write mask at the register width.
  case texWrite
}

/// A set of named values for an enumeration field.
public struct Family: Sendable {
  public var names: [String]
  public var values: [UInt64]

  public func name(of value: UInt64) -> String? {
    var i = 0
    while i < values.count {
      if values[i] == value { return names[i] }
      i += 1
    }
    return nil
  }
  public func value(named s: String) -> UInt64? {
    var i = 0
    while i < names.count {
      if names[i].sameBytes(s) { return values[i] }
      i += 1
    }
    return nil
  }
}

/// What a field means to the assembler and the model.
public enum FieldRole: Equatable, Sendable {
  case source(Int)
  case negate(Int)
  case absolute(Int)
  case complement(Int)
  /// Widen, lane or swizzle of source `n`.
  case lane(Int)
  case destination
  case destinationWidth
  /// First register of the block the instruction reads (or only writes).
  case stagingRegister
  /// First register of the second block, written (S2RW).
  case stagingWriteRegister
  case stagingCount
  case stagingWriteCount
  case slot
  /// Anything else: a modifier, an immediate, a named operand.
  case other
}

/// One free field of an instruction definition.
public struct FieldDef: Sendable {
  public var name: String
  public var ranges: [BitRange]
  public var kind: FieldKind
  /// Index into `ISATable.families`, or -1.
  public var family: Int
  public var defaultValue: UInt64
  /// An enumeration without a default (valhall: "required"): always printed.
  public var required: Bool
  public var rule: DerivedRule
  public var role: FieldRole

  /// The bits this field occupies.
  public var mask: UInt64 {
    var m: UInt64 = 0
    for r in ranges { m |= r.mask }
    return m
  }
  /// Total width in bits.
  public var width: Int {
    var w = 0
    for r in ranges { w += r.width }
    return w
  }
  public var isSigned: Bool { kind == .signedImmediate || kind == .namedSigned }
  public var isSource: Bool { kind == .src32 || kind == .src64 || kind == .addr64 }
}

/// Which way an instruction moves its staging registers (valhall 10.7).
public enum StagingDirection: UInt8, Sendable {
  case none, read, write, readWrite
}

/// One instruction variant: a mnemonic, its variant suffix, and the word
/// layout. This is one row of the tables of valhall 11 to 13 (10.13).
public struct InstructionDef: Sendable {
  public var id: Int
  public var mnemonic: String
  /// The variant suffix (`f32`, `i32`, `u64`), or empty.
  public var variant: String
  public var cls: ISAClass
  public var unit: Unit
  public var archLo: Int
  public var archHi: Int
  /// The base word: every fixed field set, every free field zero (10.13.1).
  public var base: UInt64
  public var fields: [FieldDef]
  public var staging: StagingDirection
  /// The definition this is an assembler alias of, or -1.
  public var aliasOf: Int
  /// The bits some field may change: the union of the free fields.
  public var freeMask: UInt64
  /// The bits that decide whether a word is this instruction: `[56:0]`
  /// outside the free fields, and the reserved bit 63.
  public var fixedMask: UInt64 { ~freeMask & ~InstructionDef.flowAndPageMask | (1 << 63) & ~freeMask }

  /// `[62:57]`: the flow field and the FAU page.
  public static let flowAndPageMask: UInt64 = 0x7E00_0000_0000_0000

  public var fullName: String { variant.isEmpty ? mnemonic : mnemonic + "." + variant }
  public var isAlias: Bool { aliasOf >= 0 }
  public func available(on arch: Int) -> Bool { arch >= archLo && arch <= archHi }
  public var isMessage: Bool { cls.isMessage || unit == .msg }

  /// The index of a field by name, or -1.
  public func fieldIndex(_ name: String) -> Int {
    var i = 0
    while i < fields.count {
      if fields[i].name.sameBytes(name) { return i }
      i += 1
    }
    return -1
  }
  /// The index of the field with a role, or -1.
  public func fieldIndex(role: FieldRole) -> Int {
    var i = 0
    while i < fields.count {
      if fields[i].role == role { return i }
      i += 1
    }
    return -1
  }
}
