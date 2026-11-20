// SPDX-License-Identifier: BSD-3-Clause

// The assembler notation of valhall 10.14 (disassembler and assembler):
//
//   MNEMONIC[.variant][.modifier]...[.slotN][.flow] operand, operand, ...
//
// The destination comes first, then staging blocks (`@r4:r5`, the written
// block first), then sources and immediates in the order of the
// definition's fields, then named operands (`offset:20`). A source is a
// register (`r4`, `r4^` for last use, `r4:r5` for a pair, `[r4:r5]` for an
// address), a user FAU word (`u37.w1`, or `u37` for a pair), a small
// constant as hex (`0x3F800000`) or a special entry by name (`lane_id.w0`),
// followed by `.neg`, `.abs`, `.not` and a widen or lane name. The assembler
// accepts the modifiers in any order and the disassembler writes the order
// of the definition's field list.

/// Why a line could not be assembled.
public enum AssembleError: Error, Equatable {
  case syntax(String)
}

extension String {
  fileprivate func trimmed() -> String {
    var s = self[...]
    while let f = s.first, f == " " || f == "\t" || f == "\r" { s = s.dropFirst() }
    while let l = s.last, l == " " || l == "\t" || l == "\r" { s = s.dropLast() }
    return String(s)
  }
}

func hexString(_ v: UInt64) -> String { "0x" + String(v, radix: 16, uppercase: true) }

func parseNumber(_ s: String) -> Int64? {
  var t = s
  var negative = false
  if t.hasPrefix("-") {
    negative = true
    t = String(t.dropFirst())
  }
  var v: UInt64?
  if t.hasPrefix("0x") || t.hasPrefix("0X") {
    v = UInt64(String(t.dropFirst(2).filter { $0 != "_" }), radix: 16)
  } else {
    v = UInt64(t)
  }
  guard let v else { return nil }
  return negative ? -Int64(bitPattern: v) : Int64(bitPattern: v)
}

// MARK: disassembler

extension ISATable {
  private func registerText(_ n: Int, last: Bool = false) -> String { "r" + String(n) + (last ? "^" : "") }

  private func blockText(_ b: RegisterBlock) -> String {
    var s = "@"
    var i = 0
    while i < b.count {
      if i > 0 { s += ":" }
      s += registerText(b.first + i)
      i += 1
    }
    return s
  }

  private func familyName(_ f: FieldDef, _ v: UInt64) -> String {
    if f.family >= 0, let n = families[f.family].name(of: v) { return n }
    return String(v)
  }

  /// The text of a source operand with its modifiers.
  func sourceText(_ inst: Instruction, _ index: Int) -> String {
    let d = defs[inst.op]
    let fi = d.fieldIndex(role: .source(index))
    let f = d.fields[fi]
    let src = Source(byte: UInt8(truncatingIfNeeded: inst.values[fi]))
    let wide = f.kind != .src32
    var s: String
    switch src.kind {
    case .register:
      if wide {
        s = registerText(src.register, last: src.lastUse) + ":" + registerText(src.register + 1, last: src.lastUse)
        if f.kind == .addr64 { s = "[" + s + "]" }
      } else {
        s = registerText(src.register, last: src.lastUse)
      }
    case .userFAU:
      s = "u" + String(inst.fauPage * 32 + src.fauSlot)
      if !wide || src.word != 0 { s += ".w" + String(src.word) }
    case .constant:
      s = hexString(UInt64(SmallConstants.values[src.constantIndex]))
    case .special:
      s = SpecialFAU.name(page: inst.fauPage, entry: src.specialEntry)
        ?? "special" + String(inst.fauPage) + "_" + String(src.specialEntry)
      if !wide || src.word != 0 { s += ".w" + String(src.word) }
    }
    var i = 0
    while i < d.fields.count {
      let m = d.fields[i]
      switch m.role {
      case .negate(index): if inst.values[i] != 0 { s += ".neg" }
      default: break
      }
      i += 1
    }
    i = 0
    while i < d.fields.count {
      if d.fields[i].role == .absolute(index) && inst.values[i] != 0 { s += ".abs" }
      i += 1
    }
    i = 0
    while i < d.fields.count {
      if d.fields[i].role == .complement(index) && inst.values[i] != 0 { s += ".not" }
      i += 1
    }
    i = d.fieldIndex(role: .lane(index))
    if i >= 0 {
      let m = d.fields[i]
      if m.required || inst.values[i] != m.defaultValue { s += "." + familyName(m, inst.values[i]) }
    }
    return s
  }

  /// The assembler text of an instruction (valhall 10.14).
  public func disassemble(_ inst: Instruction) -> String {
    let d = defs[inst.op]
    var head = d.mnemonic
    if !d.variant.isEmpty { head += "." + d.variant }
    var operands: [String] = []
    // modifiers, in field order
    var i = 0
    while i < d.fields.count {
      let f = d.fields[i]
      let v = inst.values[i]
      if f.role == .other {
        if f.kind == .enumeration, f.required || v != f.defaultValue { head += "." + familyName(f, v) }
        if f.kind == .flag, v != 0 { head += "." + f.name }
      }
      i += 1
    }
    if let si = Optional(d.fieldIndex(role: .slot)), si >= 0 {
      head += "." + familyName(d.fields[si], inst.values[si])
    } else if d.mnemonic == "BARRIER" {
      head += ".slot7"
    }
    if inst.flow != .none { head += "." + inst.flow.name }
    // operands
    let di = d.fieldIndex(role: .destination)
    if di >= 0 {
      let r = Int(inst.values[di])
      var s = registerText(r)
      if d.fields[di].kind == .registerPair { s += ":" + registerText(r + 1) }
      let wi = d.fieldIndex(role: .destinationWidth)
      if wi >= 0 {
        let wv = inst.values[wi]
        let name = familyName(d.fields[wi], wv)
        if name != "none" || d.fields[wi].required { s += "." + name }
      }
      operands.append(s)
    }
    if let w = inst.stagingWrite, w.count > 0 { operands.append(blockText(w)) }
    if let r = inst.stagingRead, r.count > 0 { operands.append(blockText(r)) }
    i = 0
    while i < d.fields.count {
      let f = d.fields[i]
      switch f.kind {
      case .src32, .src64, .addr64:
        if case .source(let n) = f.role { operands.append(sourceText(inst, n)) }
      case .immediate:
        operands.append("#" + hexString(inst.values[i]))
      case .signedImmediate:
        let s = Int64(bitPattern: inst.values[i])
        operands.append(s < 0 ? "#" + String(s) : "#" + hexString(UInt64(s)))
      default: break
      }
      i += 1
    }
    i = 0
    while i < d.fields.count {
      let f = d.fields[i]
      switch f.kind {
      case .named: operands.append(f.name + ":" + String(inst.values[i]))
      case .namedSigned: operands.append(f.name + ":" + String(Int64(bitPattern: inst.values[i])))
      case .optional: if inst.values[i] != 0 { operands.append(f.name + ":" + String(inst.values[i])) }
      default: break
      }
      i += 1
    }
    if operands.isEmpty { return head }
    var out = head + " "
    var k = 0
    while k < operands.count {
      if k > 0 { out += ", " }
      out += operands[k]
      k += 1
    }
    return out
  }
}

// MARK: assembler

extension ISATable {
  private struct SourceOperand {
    var byte: UInt8
    var page: Int?
  }

  private func parseRegister(_ s: String) -> (Int, Bool)? {
    var t = s
    var last = false
    if t.hasSuffix("^") {
      last = true
      t = String(t.dropLast())
    }
    guard t.hasPrefix("r"), let n = Int(t.dropFirst()), n >= 0, n < 64 else { return nil }
    return (n, last)
  }

  /// Parse the base of a source operand (no suffixes). Returns the byte and
  /// the FAU page it needs, if any.
  private func parseSourceBase(_ base: String, wide: Bool) throws(AssembleError) -> SourceOperand {
    if base.hasPrefix("0x") || base.hasPrefix("0X") {
      guard let v = parseNumber(base), v >= 0, v <= 0xFFFF_FFFF, let idx = SmallConstants.index(of: UInt32(v)) else {
        throw .syntax("not a small constant: " + base)
      }
      return SourceOperand(byte: UInt8(0xC0 + idx), page: nil)
    }
    if base.hasPrefix("u"), let n = Int(base.dropFirst()), n >= 0, n < 128 {
      return SourceOperand(byte: 0x80 | UInt8((n & 31) << 1), page: n / 32)
    }
    if base.hasPrefix("r") {
      let parts = base.split(separator: ":").map { String($0) }
      if parts.count == 1, let (n, last) = parseRegister(parts[0]) {
        return SourceOperand(byte: UInt8(n) | (last ? 0x40 : 0), page: nil)
      }
      if parts.count == 2, let (a, l1) = parseRegister(parts[0]), let (b, l2) = parseRegister(parts[1]) {
        if !wide { throw .syntax("a single register is needed: " + base) }
        if b != a + 1 { throw .syntax("not a pair: " + base) }
        return SourceOperand(byte: UInt8(a) | ((l1 && l2) ? 0x40 : 0), page: nil)
      }
    }
    if let (page, entry) = SpecialFAU.entry(named: base) {
      return SourceOperand(byte: 0xE0 | UInt8(entry << 1), page: page)
    }
    // an entry the hardware does not define, as the disassembler writes it
    if base.hasPrefix("special") {
      let parts = base.dropFirst(7).split(separator: "_")
      if parts.count == 2, let p = Int(parts[0]), let e = Int(parts[1]), p >= 0, p < 4, e >= 0, e < 16 {
        return SourceOperand(byte: 0xE0 | UInt8(e << 1), page: p)
      }
    }
    throw .syntax("unknown operand " + base)
  }

  /// Set an instruction's FAU page from a source, checking for a clash.
  private func usePage(_ inst: inout Instruction, _ page: Int?, _ pageSet: inout Bool) throws(AssembleError) {
    guard let page else { return }
    if pageSet && inst.fauPage != page { throw .syntax("sources in different FAU pages") }
    inst.fauPage = page
    pageSet = true
  }

  /// Assemble one instruction (valhall 10.14).
  public func assemble(_ line: String, arch: Int = 12) throws(AssembleError) -> Instruction {
    var text = line
    if let semi = text.firstIndex(of: ";") { text = String(text[text.startIndex..<semi]) }
    text = text.trimmed()
    if text.isEmpty { throw .syntax("empty line") }
    if text.hasPrefix("0x"), text.count >= 16, let w = parseNumber(text), text.firstIndex(of: " ") == nil {
      do {
        return try decode(UInt64(bitPattern: w), arch: arch, aliases: false)
      } catch {
        throw .syntax("not an instruction: " + text)
      }
    }
    var headText = text
    var operandText = ""
    if let sp = text.firstIndex(of: " ") {
      headText = String(text[text.startIndex..<sp])
      operandText = String(text[text.index(after: sp)...]).trimmed()
    }
    let headParts = headText.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }
    let mnemonic = headParts[0]
    var suffixes = Array(headParts.dropFirst())
    // the definition: mnemonic and variant
    var chosen = -1
    var i = 0
    var known = false
    while i < defs.count {
      let d = defs[i]
      if d.mnemonic == mnemonic {
        known = true
        if d.available(on: arch) {
          if let s = suffixes.first, d.variant == s {
            chosen = i
            suffixes.removeFirst()
            break
          }
        }
      }
      i += 1
    }
    if chosen < 0 {
      if let c = lookup(mnemonic: mnemonic, variant: "", arch: arch) {
        chosen = c
      } else {
        throw .syntax(known ? "no such variant of " + mnemonic : "unknown mnemonic " + mnemonic)
      }
    }
    var inst = Instruction(op: chosen)
    let d = defs[chosen]
    // suffixes: flow, slot, modifiers (a name two fields share goes to the first not yet set, in order)
    var assigned = [Bool](repeating: false, count: d.fields.count)
    for s in suffixes {
      if let f = Flow.named(s) {
        inst.flow = f
        continue
      }
      if s == "none" { continue }
      if d.mnemonic == "BARRIER" && s == "slot7" { continue }
      var done = false
      var k = 0
      while k < d.fields.count && !done {
        let f = d.fields[k]
        if (f.role == .other || f.role == .slot) && !assigned[k] {
          if f.kind == .enumeration, f.family >= 0, let v = families[f.family].value(named: s) {
            inst.values[k] = v
            assigned[k] = true
            done = true
          } else if f.kind == .flag && f.name == s {
            inst.values[k] = 1
            assigned[k] = true
            done = true
          }
        }
        k += 1
      }
      if !done { throw .syntax("unknown modifier ." + s + " on " + d.fullName) }
    }
    // operands
    var operands: [String] = []
    if !operandText.isEmpty {
      var depth = 0
      var cur = ""
      for c in operandText {
        if c == "[" { depth += 1 }
        if c == "]" { depth -= 1 }
        if c == "," && depth == 0 {
          operands.append(cur.trimmed())
          cur = ""
        } else {
          cur.append(c)
        }
      }
      operands.append(cur.trimmed())
    }
    var pageSet = false
    var sourceFields: [Int] = []
    var immFields: [Int] = []
    k_loop: for k in 0..<d.fields.count {
      switch d.fields[k].kind {
      case .src32, .src64, .addr64: sourceFields.append(k)
      case .immediate, .signedImmediate: immFields.append(k)
      default: continue k_loop
      }
    }
    var nextSource = 0
    var nextImm = 0
    var destDone = d.fieldIndex(role: .destination) < 0
    var blocks: [RegisterBlock] = []
    for op in operands {
      if op.isEmpty { throw .syntax("empty operand") }
      if op.hasPrefix("@") {
        let regs = op.dropFirst().split(separator: ":").map { String($0) }
        guard let first = parseRegister(regs[0]) else { throw .syntax("bad block " + op) }
        var n = 1
        while n < regs.count {
          guard let r = parseRegister(regs[n]), r.0 == first.0 + n else { throw .syntax("bad block " + op) }
          n += 1
        }
        blocks.append(RegisterBlock(first: first.0, count: regs.count))
        continue
      }
      if op.hasPrefix("#") {
        guard nextImm < immFields.count, let v = parseNumber(String(op.dropFirst())) else {
          throw .syntax("unexpected immediate " + op)
        }
        inst.values[immFields[nextImm]] = UInt64(bitPattern: v)
        nextImm += 1
        continue
      }
      if !destDone {
        destDone = true
        let di = d.fieldIndex(role: .destination)
        let plain = String(op.filter { $0 != "[" && $0 != "]" })
        var parts = plain.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }
        let regPart = parts.removeFirst()
        let regs = regPart.split(separator: ":").map { String($0) }
        guard let r = parseRegister(regs[0]) else { throw .syntax("bad destination " + op) }
        if d.fields[di].kind == .registerPair {
          guard regs.count == 2, let r2 = parseRegister(regs[1]), r2.0 == r.0 + 1 else {
            throw .syntax("a destination pair is needed: " + op)
          }
        } else if regs.count != 1 {
          throw .syntax("a destination register is needed: " + op)
        }
        inst.values[di] = UInt64(r.0)
        for p in parts {
          let wi = d.fieldIndex(role: .destinationWidth)
          guard wi >= 0, d.fields[wi].family >= 0, let v = families[d.fields[wi].family].value(named: p) else {
            throw .syntax("bad destination width ." + p)
          }
          inst.values[wi] = v
        }
        continue
      }
      // a named operand
      if let colon = op.firstIndex(of: ":"), !op.hasPrefix("[") {
        let name = String(op[op.startIndex..<colon])
        let fi = d.fieldIndex(name)
        if fi >= 0, let v = parseNumber(String(op[op.index(after: colon)...])) {
          inst.values[fi] = UInt64(bitPattern: v)
          continue
        }
      }
      // a source
      if nextSource < sourceFields.count {
        let fi = sourceFields[nextSource]
        let f = d.fields[fi]
        guard case .source(let n) = f.role else { throw .syntax("source field without a position") }
        let body = String(op.filter { $0 != "[" && $0 != "]" })
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }
        let wide = f.kind != .src32
        var so = try parseSourceBase(parts[0], wide: wide)
        var word = 0
        var m = 1
        var sawWord = false
        while m < parts.count {
          let p = parts[m]
          m += 1
          // `.w0` and `.w1` after a FAU word select the word, unless the source is 64-bit and has such a widen
          let li0 = d.fieldIndex(role: .lane(n))
          let isWidenName = wide && li0 >= 0 && d.fields[li0].family >= 0 && families[d.fields[li0].family].value(named: p) != nil
          if !sawWord && !isWidenName && (p == "w0" || p == "w1") && (so.byte >= 0x80 && so.byte < 0xC0 || so.byte >= 0xE0) {
            word = p == "w1" ? 1 : 0
            sawWord = true
            continue
          }
          if p == "neg" || p == "abs" || p == "not" {
            let role: FieldRole = p == "neg" ? .negate(n) : (p == "abs" ? .absolute(n) : .complement(n))
            let mi = d.fieldIndex(role: role)
            if mi < 0 { throw .syntax("no ." + p + " on source " + String(n) + " of " + d.fullName) }
            inst.values[mi] = 1
            continue
          }
          let li = d.fieldIndex(role: .lane(n))
          guard li >= 0, d.fields[li].family >= 0, let v = families[d.fields[li].family].value(named: p) else {
            throw .syntax("unknown source modifier ." + p + " on " + op)
          }
          inst.values[li] = v
        }
        if so.byte >= 0x80 && so.byte < 0xC0 || so.byte >= 0xE0 { so.byte |= UInt8(word) }
        try usePage(&inst, so.page, &pageSet)
        inst.values[fi] = UInt64(so.byte)
        nextSource += 1
        continue
      }
      // a bare name of an enumeration value
      var done = false
      var k = 0
      while k < d.fields.count && !done {
        let f = d.fields[k]
        if f.kind == .enumeration, f.role == .other, f.family >= 0, let v = families[f.family].value(named: op) {
          inst.values[k] = v
          done = true
        }
        k += 1
      }
      if !done { throw .syntax("unexpected operand " + op) }
    }
    if !destDone { throw .syntax("the destination is missing") }
    // staging blocks
    let listed: [RegisterBlock] = blocks
    if d.staging == .readWrite {
      guard listed.count == 2 else { throw .syntax(d.fullName + " names a written and a read block") }
      let w = listed[0]
      let r = listed[1]
      setBlock(&inst, d, .stagingWriteRegister, .stagingWriteCount, w)
      setBlock(&inst, d, .stagingRegister, .stagingCount, r)
    } else if d.staging != .none {
      if listed.count == 1 {
        setBlock(&inst, d, .stagingRegister, .stagingCount, listed[0])
      } else if !listed.isEmpty {
        throw .syntax(d.fullName + " names one staging block")
      }
    } else if !listed.isEmpty {
      throw .syntax(d.fullName + " has no staging block")
    }
    if nextSource != sourceFields.count { throw .syntax("missing sources for " + d.fullName) }
    if nextImm != immFields.count { throw .syntax("missing immediate for " + d.fullName) }
    // derived fields must agree with what was written
    let before = inst
    normalize(&inst)
    var f = 0
    while f < d.fields.count {
      let role = d.fields[f].role
      if d.fields[f].rule != .none && (role == .stagingCount || role == .stagingWriteCount) && before.values[f] != inst.values[f]
        && !blocks.isEmpty
      {
        throw .syntax("the staging block of " + d.fullName + " should have " + String(inst.values[f]) + " registers")
      }
      f += 1
    }
    return inst
  }

  private func setBlock(_ inst: inout Instruction, _ d: InstructionDef, _ regRole: FieldRole, _ cntRole: FieldRole, _ b: RegisterBlock) {
    let r = d.fieldIndex(role: regRole)
    let c = d.fieldIndex(role: cntRole)
    if r >= 0 { inst.values[r] = UInt64(b.first) }
    if c >= 0 { inst.values[c] = UInt64(b.count) }
  }

  /// Assemble a program: one instruction per line, blank lines and `;`
  /// comments skipped, a line of 16 hex digits taken as an encoded word.
  public func assemble(program: String, arch: Int = 12) throws(AssembleError) -> [Instruction] {
    var out: [Instruction] = []
    for rawLine in program.split(separator: "\n", omittingEmptySubsequences: true) {
      var l = String(rawLine)
      if let semi = l.firstIndex(of: ";") { l = String(l[l.startIndex..<semi]) }
      l = l.trimmed()
      if l.isEmpty { continue }
      try out.append(assemble(l, arch: arch))
    }
    return out
  }
}
