// SPDX-License-Identifier: BSD-3-Clause

// The encoder and decoder (valhall 10.3, 10.13.1). To encode, take the
// definition's base word with its free fields cleared, then OR in each
// field's value at its bit position, the flow field and the FAU page. To
// decode, find the definition whose fixed bits the word carries (the
// decode procedure of 10.3.1: the class, then the opcode fields, which are
// part of the fixed bits) and read the free fields.

/// Why an instruction could not be encoded.
public enum EncodeError: Error, Equatable {
  /// The value of field `name` does not fit its bits.
  case fieldOverflow(String)
  /// An enumeration field holds a value the family does not name.
  case unknownValue(String)
  /// The flow field is a reserved value.
  case reservedFlow
  /// The FAU page is not 0 to 3.
  case badPage
  /// A count outside what the field stores.
  case badCount(String)
  /// A distance that is not a whole number of 8-byte instructions.
  case misaligned(String)
  /// The definition is not valid on the arch.
  case wrongArch
}

/// Why a word could not be decoded.
public enum DecodeError: Error, Equatable {
  /// Bit 63 is set.
  case reservedBit
  /// The class is not defined, or no definition of the class has these fixed bits.
  case noInstruction
  /// A definition matches, but not on this arch.
  case wrongArch
}

extension ISATable {
  // MARK: field access

  /// The raw bits of a field in a word, concatenating its ranges.
  static func extract(_ f: FieldDef, from word: UInt64) -> UInt64 {
    var v: UInt64 = 0
    var shift: UInt64 = 0
    for r in f.ranges {
      let part = (word >> UInt64(r.lo)) & ((r.width == 64) ? ~0 : ((1 << UInt64(r.width)) - 1))
      v |= part << shift
      shift += UInt64(r.width)
    }
    return v
  }

  static func insert(_ f: FieldDef, _ raw: UInt64, into word: inout UInt64) {
    var v = raw
    for r in f.ranges {
      word |= (v << UInt64(r.lo)) & r.mask
      v >>= UInt64(r.width)
    }
  }

  /// The logical value of a field from its raw bits.
  static func logical(_ f: FieldDef, raw: UInt64) -> UInt64 {
    switch f.kind {
    case .count8: return raw == 0 ? 8 : raw
    case .countMinusOne: return raw + 1
    case .distance8: return raw * 8
    case .signedImmediate, .namedSigned:
      let w = UInt64(f.width)
      if w < 64 && raw & (1 << (w - 1)) != 0 { return raw | (~0 << w) }
      return raw
    default: return raw
    }
  }

  // MARK: derived fields

  /// The value a derived field takes, from the other fields. Nil if the rule
  /// needs a field the definition lacks (the field is then left as given).
  func derive(_ rule: DerivedRule, _ d: InstructionDef, _ v: [UInt64], _ index: Int) -> UInt64? {
    func field(_ name: String) -> UInt64? {
      let i = d.fieldIndex(name)
      return i < 0 ? nil : v[i]
    }
    func isName(_ fieldName: String, _ valueName: String) -> Bool {
      let i = d.fieldIndex(fieldName)
      if i < 0 || d.fields[i].family < 0 { return false }
      return families[d.fields[i].family].name(of: v[i]) == valueName
    }
    func popcount4(_ x: UInt64) -> UInt64 { UInt64((x & 15).nonzeroBitCount) }
    switch rule {
    case .none: return nil
    case .constant: return d.fields[index].defaultValue
    case .fmulNeg2, .f2hNeg1:
      guard let r = field("round") else { return nil }
      return r == 2 ? 0 : 1
    case .loadCount: return isName("lane", "d0") ? 2 : 1
    case .formatCount:
      guard let vs = field("vsz"), let fmt = field("fmt") else { return nil }
      return (vs >> (fmt & 1)) + 1
    case .varBuf32Count, .specialCount:
      guard let vs = field("vsz") else { return nil }
      return vs + 1
    case .varBuf16Count:
      guard let vs = field("vsz") else { return nil }
      return (vs >> 1) + 1
    case .atomCount:
      let op = field("op") ?? ((d.base >> 22) & 15)
      return op <= 1 ? 1 : 2
    case .blendCount:
      guard let fmt = field("fmt") else { return nil }
      return fmt & 1 != 0 ? 2 : 4
    case .texSingleRead:
      guard let dim = field("dim"), let proj = field("project"), let arr = field("array"), let off = field("texel_offset"),
        let cmp = field("compare"), let lod = field("lod")
      else { return nil }
      var n: UInt64 = 1
      if dim != 0 { n += 1 }
      if dim == 2 || (dim == 3 && proj != 0) { n += 1 }
      if proj != 0 && dim != 3 { n += 1 }
      n += arr + cmp + off
      if lod == 4 || lod == 5 || lod == 7 { n += 1 }
      if lod == 6 { n += 2 }
      return n
    case .texFetchRead:
      guard let dim = field("dim"), let arr = field("array"), let off = field("texel_offset") else { return nil }
      var n: UInt64 = 1
      if dim == 1 || dim == 2 { n += 1 }
      if dim == 2 { n += 1 }
      return n + arr + off
    case .texGatherRead:
      guard let proj = field("project"), let arr = field("array"), let off = field("texel_offset"), let cmp = field("compare")
      else { return nil }
      return 2 + proj + arr + cmp + off
    case .texGradientRead:
      guard let dim = field("dim"), let proj = field("project"), let deriv = field("derivative") else { return nil }
      // (c << derivative) + projection (12b.5.6), c the coordinate words of the dimensionality: 1, 2, 3
      // for 1D, 2D, 3D and 2 for a cube (its face-packed S and T). 5 and 7 come out for derivative with
      // projection on 2D, 3D and cube; they are not encodable (`encode` refuses them).
      let c: UInt64 = dim == 0 ? 1 : (dim == 2 ? 3 : 2)
      return (c << deriv) + proj
    case .texDualWrite, .varTexDualWrite:
      // Rp + Rs registers (the stored value is one less): Rp from the primary mask and width (a fixed
      // 2 or 4 for the fused form), Rs from 1 to 4 for a dst32 secondary and 1 or 2 for dst16.
      guard let width = field("width"), let swidth = field("swidth") else { return nil }
      let rp: UInt64
      if rule == .texDualWrite {
        guard let mask = field("mask") else { return nil }
        let n = popcount4(mask)
        rp = width != 0 ? n : (n + 1) / 2
      } else {
        rp = width != 0 ? 4 : 2
      }
      let most = rp + (swidth != 0 ? 4 : 2)
      return min(max(v[index], rp + 1), most)
    case .texWrite:
      guard let mask = field("mask"), let width = field("width") else { return nil }
      let n = popcount4(mask)
      return width != 0 ? n : (n + 1) / 2
    }
  }

  /// Fill every derived field of `inst` from the others, in definition order.
  public func normalize(_ inst: inout Instruction) {
    let d = defs[inst.op]
    var i = 0
    while i < d.fields.count {
      if d.fields[i].rule != .none, let x = derive(d.fields[i].rule, d, inst.values, i) {
        inst.values[i] = x
      }
      i += 1
    }
  }

  // MARK: encode

  /// The 64-bit word of an instruction. Derived fields are computed.
  public func encode(_ inst: Instruction) throws(EncodeError) -> UInt64 {
    let d = defs[inst.op]
    if inst.flow == .reserved11 || inst.flow == .reserved14 { throw .reservedFlow }
    if inst.fauPage < 0 || inst.fauPage > 3 { throw .badPage }
    var word = d.base & ~d.freeMask
    word |= UInt64(inst.flow.rawValue) << 59
    word |= UInt64(inst.fauPage) << 57
    var i = 0
    while i < d.fields.count {
      let f = d.fields[i]
      var v = inst.values[i]
      if f.rule != .none, let x = derive(f.rule, d, inst.values, i) { v = x }
      if f.rule == .texGradientRead && (v == 5 || v == 7) { throw .badCount(f.name) }
      var raw = v
      let w = UInt64(f.width)
      switch f.kind {
      case .count:
        if v > 7 { throw .badCount(f.name) }
      case .count8:
        if v < 1 || v > 8 { throw .badCount(f.name) }
        raw = v == 8 ? 0 : v
      case .countMinusOne:
        if v < 1 || v > 8 { throw .badCount(f.name) }
        raw = v - 1
      case .distance8:
        if v & 7 != 0 { throw .misaligned(f.name) }
        raw = v >> 3
      case .signedImmediate, .namedSigned:
        let s = Int64(bitPattern: v)
        let lim = Int64(1) << (Int64(w) - 1)
        if s < -lim || s >= lim { throw .fieldOverflow(f.name) }
        raw = v & ((1 << w) - 1)
      default: break
      }
      if w < 64 && raw >> w != 0 { throw .fieldOverflow(f.name) }
      if f.kind == .enumeration, f.family >= 0, families[f.family].name(of: v) == nil { throw .unknownValue(f.name) }
      ISATable.insert(f, raw, into: &word)
      i += 1
    }
    return word
  }

  // MARK: decode

  /// Read the free fields of `word` as definition `op`. Nil when the fixed
  /// bits differ, or a derived field disagrees with its rule.
  func read(_ word: UInt64, as op: Int) -> Instruction? {
    let d = defs[op]
    if word & d.fixedMask != d.base & d.fixedMask { return nil }
    var values: [UInt64] = []
    for f in d.fields {
      let v = ISATable.logical(f, raw: ISATable.extract(f, from: word))
      if f.kind == .enumeration, f.family >= 0, families[f.family].name(of: v) == nil { return nil }
      values.append(v)
    }
    let flow = Flow(rawValue: UInt8((word >> 59) & 15)) ?? .none
    var inst = Instruction(op: op, flow: flow, fauPage: Int((word >> 57) & 3), values: values)
    var i = 0
    while i < d.fields.count {
      if d.fields[i].rule != .none, let x = derive(d.fields[i].rule, d, values, i), x != values[i] { return nil }
      if d.fields[i].rule == .texGradientRead && (values[i] == 5 || values[i] == 7) { return nil }
      i += 1
    }
    inst.values = values
    return inst
  }

  /// Decode a word (valhall 10.3.1). With `aliases`, an assembler alias
  /// whose fixed fields the word carries is returned in place of the
  /// instruction it is built on; otherwise the underlying instruction.
  public func decode(_ word: UInt64, arch: Int = 12, aliases: Bool = false) throws(DecodeError) -> Instruction {
    if word >> 63 != 0 { throw .reservedBit }
    let candidates = byClass[Int((word >> 52) & 31)]
    var best: Instruction?
    var bestBits = -1
    var sawOtherArch = false
    for op in candidates {
      let d = defs[op]
      if d.isAlias && !aliases { continue }
      let bits = d.fixedMask.nonzeroBitCount
      if bits <= bestBits { continue }
      guard let inst = read(word, as: op) else { continue }
      if !d.available(on: arch) {
        sawOtherArch = true
        continue
      }
      best = inst
      bestBits = bits
    }
    if let best { return best }
    throw sawOtherArch ? .wrongArch : .noInstruction
  }
}
