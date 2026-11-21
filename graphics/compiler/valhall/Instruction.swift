// SPDX-License-Identifier: BSD-3-Clause

// An instruction value (valhall 10.2): a definition, the flow field, the FAU
// page and one value for each of the definition's free fields.

/// An 8-bit source operand (valhall 10.5.1).
public struct Source: Equatable, Sendable {
  public var byte: UInt8
  public init(byte: UInt8) { self.byte = byte }

  public enum Kind: Equatable, Sendable {
    case register, userFAU, constant, special
  }

  /// `r0` to `r63`, optionally marked last use.
  public static func register(_ r: Int, lastUse: Bool = false) -> Source {
    Source(byte: UInt8(r & 63) | (lastUse ? 0x40 : 0))
  }
  /// A user FAU word: `slot` 0 to 31 within the page, `word` 0 or 1. For a
  /// 64-bit source, `word` is 0.
  public static func user(slot: Int, word: Int = 0) -> Source {
    Source(byte: 0x80 | UInt8((slot & 31) << 1) | UInt8(word & 1))
  }
  /// A small constant, table index 0 to 31 (valhall 10.5.2).
  public static func constant(_ index: Int) -> Source { Source(byte: 0xC0 | UInt8(index & 31)) }
  /// A special FAU entry 0 to 15 of the instruction's page, word 0 or 1.
  public static func special(entry: Int, word: Int = 0) -> Source {
    Source(byte: 0xE0 | UInt8((entry & 15) << 1) | UInt8(word & 1))
  }
  /// The zero constant.
  public static let zero = Source.constant(0)

  public var kind: Kind {
    if byte < 0x80 { return .register }
    if byte < 0xC0 { return .userFAU }
    if byte < 0xE0 { return .constant }
    return .special
  }
  /// The register number, when this is a register.
  public var register: Int { Int(byte & 63) }
  public var lastUse: Bool { byte < 0x80 && byte & 0x40 != 0 }
  /// The slot within the FAU page (user words), 0 to 31.
  public var fauSlot: Int { Int((byte >> 1) & 31) }
  /// The word within a slot, 0 or 1.
  public var word: Int { Int(byte & 1) }
  /// The small-constant table index.
  public var constantIndex: Int { Int(byte & 31) }
  /// The special entry, 0 to 15.
  public var specialEntry: Int { Int((byte >> 1) & 15) }
}

/// The small-constant table of valhall 10.5.2 (index 21 is the arch 11 and
/// later value; software treats it as unavailable).
public enum SmallConstants {
  public static let values: [UInt32] = [
    0x0000_0000, 0xFFFF_FFFF, 0x7FFF_FFFF, 0xFAFC_FDFE, 0x0100_0000, 0x8000_2000, 0x7060_5030, 0xC0B0_A090,
    0x0302_0100, 0x0706_0504, 0x0B0A_0908, 0x0F0E_0D0C, 0x1312_1110, 0x1716_1514, 0x1B1A_1918, 0x1F1E_1D1C,
    0x3F80_0000, 0x3DCC_CCCD, 0x3EA2_F983, 0x3F31_7218, 0x4049_0FDB, 0x2724_28E0, 0x477F_FF00, 0x5C00_5BF8,
    0x2E66_0000, 0x3400_0000, 0x3800_0000, 0x3C00_0000, 0x4000_0000, 0x4400_0000, 0x4800_0000, 0x4248_0000,
  ]

  /// The table index of a 32-bit value, or nil. Index 21 is the arch 11 value, which software treats as unavailable
  /// (valhall 10.5.2); it is named so that the word still assembles.
  public static func index(of value: UInt32) -> Int? {
    var i = 0
    while i < values.count {
      if values[i] == value { return i }
      i += 1
    }
    return nil
  }
}

/// The special FAU entries (valhall 10.5.3).
public enum SpecialFAU {
  /// The name of entry `entry` of `page`, or nil when none is defined.
  public static func name(page: Int, entry: Int) -> String? {
    switch (page, entry) {
    case (0, 2): return "warp_id"
    case (0, 4): return "framebuffer_size"
    case (0, 5): return "atest_datum"
    case (0, 6): return "sample"
    case (0, 8...15): return "blend_descriptor_" + String(entry - 8)
    case (1, 1): return "thread_local_pointer"
    case (1, 3): return "workgroup_local_pointer"
    case (1, 7): return "resource_table_pointer"
    case (3, 1): return "lane_id"
    case (3, 3): return "core_id"
    case (3, 4): return "shader_output"
    case (3, 5): return "prepass_state"
    case (3, 15): return "pc"
    default: return nil
    }
  }

  /// The page and entry of a name.
  public static func entry(named s: String) -> (page: Int, entry: Int)? {
    var page = 0
    while page < 4 {
      var e = 0
      while e < 16 {
        if let n = name(page: page, entry: e), n.sameBytes(s) { return (page, e) }
        e += 1
      }
      page += 1
    }
    return nil
  }
}

/// A source operand with its modifiers (valhall 10.5, 10.6).
public struct SourceOperand: Equatable, Sendable {
  public var source: Source
  /// The operand is a register pair, a FAU slot or a zero-extended constant.
  public var is64Bit: Bool
  /// The instruction's FAU page, which `source` names a word of when it is a FAU word.
  public var fauPage: Int
  public var negate = false
  public var absolute = false
  public var complement = false
  /// The widen, lane or swizzle value (the family of the instruction's field) and its name.
  public var lane: UInt64 = 0
  public var laneName = ""

  public init(source: Source, is64Bit: Bool, fauPage: Int) {
    self.source = source
    self.is64Bit = is64Bit
    self.fauPage = fauPage
  }
}

/// A block of consecutive staging registers.
public struct RegisterBlock: Equatable, Sendable {
  public var first: Int
  public var count: Int
  public init(first: Int, count: Int) {
    self.first = first
    self.count = count
  }
}

/// One instruction: a definition plus its field values.
public struct Instruction: Equatable, Sendable {
  /// Index into `ISATable.shared.defs`.
  public var op: Int
  public var flow: Flow
  /// The FAU page, `[58:57]`.
  public var fauPage: Int
  /// One value per free field of the definition, in definition order. A
  /// signed field holds its two's complement in 64 bits; a count its number
  /// of registers; derived fields hold the derived value after `normalize`.
  public var values: [UInt64]

  public init(op: Int, flow: Flow = .none, fauPage: Int = 0, values: [UInt64]) {
    self.op = op
    self.flow = flow
    self.fauPage = fauPage
    self.values = values
  }

  /// An instruction of definition `op` with every field at its default.
  public init(op: Int) {
    let d = ISATable.shared.defs[op]
    var v: [UInt64] = []
    for f in d.fields { v.append(f.defaultValue) }
    self.init(op: op, fauPage: Int((d.base >> 57) & 3), values: v)
  }

  /// An instruction by mnemonic and variant, with every field at its default.
  public init?(_ mnemonic: String, _ variant: String = "", arch: Int = 12) {
    guard let op = ISATable.shared.lookup(mnemonic: mnemonic, variant: variant, arch: arch) else { return nil }
    self.init(op: op)
  }

  public var def: InstructionDef { ISATable.shared.defs[op] }
  public var mnemonic: String { def.mnemonic }
  public var variant: String { def.variant }

  // MARK: fields by name

  /// The value of a field, or nil if the definition has none by that name.
  public func value(_ name: String) -> UInt64? {
    let i = def.fieldIndex(name)
    return i < 0 ? nil : values[i]
  }

  /// Set a field by name. Returns false when the definition has no such field.
  @discardableResult
  public mutating func set(_ name: String, _ value: UInt64) -> Bool {
    let i = def.fieldIndex(name)
    if i < 0 { return false }
    values[i] = value
    return true
  }

  /// Set an enumeration field by one of its value names.
  @discardableResult
  public mutating func set(_ name: String, named valueName: String) -> Bool {
    let d = def
    let i = d.fieldIndex(name)
    if i < 0 || d.fields[i].family < 0 { return false }
    guard let v = ISATable.shared.families[d.fields[i].family].value(named: valueName) else { return false }
    values[i] = v
    return true
  }

  /// The name of an enumeration field's current value.
  public func valueName(_ name: String) -> String? {
    let d = def
    let i = d.fieldIndex(name)
    if i < 0 || d.fields[i].family < 0 { return nil }
    return ISATable.shared.families[d.fields[i].family].name(of: values[i])
  }

  // MARK: operands

  /// Source `n` (`src0` to `src3`), or nil when the instruction has none.
  public func source(_ n: Int) -> Source? {
    let i = def.fieldIndex(role: .source(n))
    return i < 0 ? nil : Source(byte: UInt8(truncatingIfNeeded: values[i]))
  }

  /// Set source `n`. Returns false when the instruction has none.
  @discardableResult
  public mutating func setSource(_ n: Int, _ s: Source) -> Bool {
    let i = def.fieldIndex(role: .source(n))
    if i < 0 { return false }
    values[i] = UInt64(s.byte)
    return true
  }

  /// Whether source `n` is a 64-bit operand (a register pair or a FAU slot).
  public func sourceIs64Bit(_ n: Int) -> Bool {
    let i = def.fieldIndex(role: .source(n))
    return i >= 0 && def.fields[i].kind != .src32
  }

  /// The sources, in order, as `(index, source)` pairs.
  public var sources: [Source] {
    var out: [Source] = []
    var n = 0
    while n < 4 {
      if let s = source(n) { out.append(s) }
      n += 1
    }
    return out
  }

  /// The destination register of an ALU instruction (the even register for
  /// a pair), or nil.
  public var destination: Int? {
    let i = def.fieldIndex(role: .destination)
    return i < 0 ? nil : Int(values[i])
  }

  /// Whether the destination is a 64-bit pair.
  public var destinationIs64Bit: Bool {
    let i = def.fieldIndex(role: .destination)
    return i >= 0 && def.fields[i].kind == .registerPair
  }

  /// The destination width field (`h0` 1, `h1` 2, `none` 3; narrow forms
  /// also `h01` 0), or 3 where the instruction has none.
  public var destinationWidth: Int {
    let i = def.fieldIndex(role: .destinationWidth)
    return i < 0 ? 3 : Int(values[i])
  }

  /// The block the instruction reads (or the only block it moves), when it
  /// moves any.
  public var stagingRead: RegisterBlock? { block(read: true) }
  /// The block the instruction writes, when it writes one.
  public var stagingWrite: RegisterBlock? { block(read: false) }

  private func block(read: Bool) -> RegisterBlock? {
    let d = def
    switch d.staging {
    case .none: return nil
    case .read: if !read { return nil }
    case .write: if read { return nil }
    case .readWrite: break
    }
    let regRole: FieldRole
    let countRole: FieldRole
    if d.staging == .readWrite && !read {
      regRole = .stagingWriteRegister
      countRole = .stagingWriteCount
    } else {
      regRole = .stagingRegister
      countRole = .stagingCount
    }
    let r = d.fieldIndex(role: regRole)
    let c = d.fieldIndex(role: countRole)
    if r < 0 || c < 0 { return nil }
    return RegisterBlock(first: Int(values[r]), count: Int(values[c]))
  }

  /// Source `n` with everything that applies to it: the source byte, whether
  /// it is a 64-bit operand, its `neg`, `abs` and `not`, and its widen,
  /// lane or swizzle. Nil when the instruction has no such source. A source
  /// an alias fixes in its base word is returned too, as the alias's
  /// underlying instruction reads it.
  public func operand(_ n: Int) -> SourceOperand? {
    let d = def
    let isa = ISATable.shared
    let si = d.fieldIndex(role: .source(n))
    var byte: UInt8
    var wide: Bool
    if si >= 0 {
      byte = UInt8(truncatingIfNeeded: values[si])
      wide = d.fields[si].kind != .src32
    } else if d.isAlias {
      let u = isa.defs[d.aliasOf]
      let ui = u.fieldIndex(role: .source(n))
      if ui < 0 { return nil }
      byte = UInt8(truncatingIfNeeded: d.base >> UInt64(8 * n))
      wide = u.fields[ui].kind != .src32
    } else {
      return nil
    }
    var op = SourceOperand(source: Source(byte: byte), is64Bit: wide, fauPage: fauPage)
    let nu = d.fieldIndex(role: .negate(n))
    let ab = d.fieldIndex(role: .absolute(n))
    let nt = d.fieldIndex(role: .complement(n))
    if nu >= 0 { op.negate = values[nu] != 0 }
    if ab >= 0 { op.absolute = values[ab] != 0 }
    if nt >= 0 { op.complement = values[nt] != 0 }
    let li = d.fieldIndex(role: .lane(n))
    if li >= 0 {
      op.lane = values[li]
      if d.fields[li].family >= 0 { op.laneName = isa.families[d.fields[li].family].name(of: values[li]) ?? "" }
    }
    return op
  }

  /// The slot field (0 to 2, or 7 for `BARRIER`), or nil.
  public var slot: Int? {
    let i = def.fieldIndex(role: .slot)
    return i < 0 ? nil : Int(values[i])
  }

  /// A fixed slot the definition's base word carries (`ATEST`, `ZS_EMIT`,
  /// `BARRIER`): bits `[32:30]` when the definition has no slot field.
  public var effectiveSlot: Int? {
    if let s = slot { return s }
    let d = def
    return d.cls.isMessage && d.cls.code != 18 ? Int((d.base >> 30) & 7) : nil
  }
}
