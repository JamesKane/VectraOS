// SPDX-License-Identifier: BSD-3-Clause

// The instruction table, row by row: every definition with its default
// fields, every enumeration value, every flag and the ends of every number
// round-trips through the encoder, the decoder, the disassembler and the
// assembler. No two definitions may be decodable from one word.

import Testing

@testable import ValhallISA

/// The arch to try a definition on: 12 when it is there, else its first.
func archFor(_ d: InstructionDef) -> Int { d.available(on: 12) ? 12 : d.archLo }

/// A definition's instructions with one field varied over the values worth trying.
func variations(of op: Int, _ isa: ISATable) -> [Instruction] {
  let d = isa.defs[op]
  var out: [Instruction] = [Instruction(op: op)]
  for (i, f) in d.fields.enumerated() {
    var values: [UInt64] = []
    switch f.kind {
    case .enumeration: values = isa.families[f.family].values
    case .flag: values = [0, 1]
    case .register, .registerPair, .src32, .src64, .addr64:
      let hi: UInt64 = f.kind == .src32 || f.kind == .src64 || f.kind == .addr64 ? 0xFE : 62
      values = [0, 2, hi]
    case .named, .optional, .immediate:
      let w = f.width
      values = [0, 1, w >= 64 ? ~0 : (1 << UInt64(w)) - 1]
    case .namedSigned, .signedImmediate:
      let w = UInt64(f.width)
      values = [0, 1, UInt64(bitPattern: -1), (1 << (w - 1)) - 1, UInt64(bitPattern: -Int64(1 << (w - 1)))]
    case .count: values = [1, 2, 4]
    case .count8: values = [1, 2, 8]
    case .countMinusOne: values = [1, 2, 8]
    }
    for v in values {
      var inst = Instruction(op: op)
      inst.values[i] = v
      out.append(inst)
    }
  }
  return out
}

@Suite struct TableTests {
  let isa = ISATable.shared

  @Test func theTableIsComplete() {
    var mnemonics: [String] = []
    for d in isa.defs where !mnemonics.contains(d.mnemonic) { mnemonics.append(d.mnemonic) }
    // valhall 10.15 lists 176 mnemonics at arch 12 (aliases included), 181 with the arch 10 only ones;
    // the table has the ones of 11 to 13 and the arch 10 only forms of 11a to 11c.
    #expect(mnemonics.count >= 176, "\(mnemonics.count) mnemonics")
    for name in ["FADD", "FMA", "IADD", "LOAD", "STORE", "TEX_SINGLE", "BLEND", "BRANCH", "NOP", "BARRIER", "CLPER"] {
      #expect(mnemonics.contains(name), "\(name)")
    }
  }

  /// valhall 10.11 and 10.16.1: the variants and mnemonics each arch has, and the units at arch 12.
  @Test func countsMatchTheInstructionIndex() {
    func count(_ arch: Int) -> (variants: Int, mnemonics: Int) {
      var names: [String] = []
      var n = 0
      for d in isa.defs where d.available(on: arch) {
        n += 1
        if !names.contains(d.mnemonic) { names.append(d.mnemonic) }
      }
      return (n, names.count)
    }
    #expect(count(10) == (365, 181))
    #expect(count(11) == (333, 170))
    #expect(count(12) == (368, 176))
    #expect(count(13) == (368, 176))
    var units = [Int](repeating: 0, count: 4)
    for d in isa.defs where d.available(on: 12) { units[Int(d.unit.rawValue)] += 1 }
    #expect(units == [28, 102, 125, 113], "fma, cvt, sfu, msg: \(units)")
  }

  @Test func everyDefaultInstructionRoundTrips() {
    var failures: [String] = []
    for d in isa.defs {
      let arch = archFor(d)
      var inst = Instruction(op: d.id)
      isa.normalize(&inst)
      do {
        let w = try isa.encode(inst)
        let back = try isa.decode(w, arch: arch, aliases: d.isAlias)
        if back.op != d.id, !(d.isAlias && back.def.isAlias) { failures.append("\(d.fullName): decodes as \(back.def.fullName) (\(hex16(w)))") }
        let again = try isa.encode(back)
        if again != w { failures.append("\(d.fullName): \(hex16(w)) re-encodes as \(hex16(again))") }
      } catch {
        failures.append("\(d.fullName): \(error)")
      }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }

  @Test func everyFieldValueRoundTrips() {
    var failures: [String] = []
    for d in isa.defs {
      let arch = archFor(d)
      for var inst in variations(of: d.id, isa) {
        isa.normalize(&inst)
        do {
          let w = try isa.encode(inst)
          let back = try isa.decode(w, arch: arch, aliases: d.isAlias)
          let sameAlias = d.isAlias && back.def.isAlias && (try? isa.encode(back)) == w
          if (back.op != d.id && !sameAlias) || (back.op == d.id && back.values != inst.values) || back.flow != inst.flow {
            failures.append("\(d.fullName) \(hex16(w)): \(inst.values) -> \(back.def.fullName) \(back.values)")
          }
        } catch {
          failures.append("\(d.fullName): \(inst.values): \(error)")
        }
      }
    }
    #expect(failures.isEmpty, "\(failures.prefix(40).joined(separator: "\n"))")
  }

  @Test func everyFlowRoundTrips() {
    var failures: [String] = []
    for raw in 0..<16 {
      guard let flow = Flow(rawValue: UInt8(raw)) else { continue }
      var inst = Instruction("NOP")!
      inst.flow = flow
      do {
        let w = try isa.encode(inst)
        let back = try isa.decode(w)
        if back.flow != flow { failures.append("\(flow.name)") }
      } catch {
        if flow != .reserved11 && flow != .reserved14 { failures.append("\(flow.name): \(error)") }
      }
    }
    #expect(failures.isEmpty, "\(failures)")
  }

  @Test func everyDefinitionDisassemblesAndAssemblesAgain() {
    var failures: [String] = []
    for d in isa.defs {
      let arch = archFor(d)
      for var inst in variations(of: d.id, isa) {
        isa.normalize(&inst)
        // source bytes that name a pair must be even, and a FAU page may not clash with the instruction's
        for (i, f) in d.fields.enumerated() where f.kind == .src64 || f.kind == .addr64 {
          if inst.values[i] < 0x40 || (inst.values[i] >= 0x40 && inst.values[i] < 0x80) { inst.values[i] &= ~1 }
          if inst.values[i] >= 0x80 { inst.values[i] &= ~1 }
        }
        guard let w = try? isa.encode(inst) else { continue }
        if let b = inst.stagingRead, b.first + b.count > 64 { continue }
        if let b = inst.stagingWrite, b.first + b.count > 64 { continue }
        guard let decoded = try? isa.decode(w, arch: arch, aliases: d.isAlias) else { continue }
        let text = isa.disassemble(decoded)
        do {
          let back = try isa.assemble(text, arch: arch)
          let e = try isa.encode(back)
          if e != w { failures.append("\(text): \(hex16(w)) assembled to \(hex16(e))") }
        } catch {
          failures.append("\(text): \(error)")
        }
      }
    }
    #expect(failures.isEmpty, "\(failures.prefix(40).joined(separator: "\n"))")
  }

  @Test func noWordDecodesAsTwoDefinitions() {
    var ambiguous: [String] = []
    for a in isa.defs where !a.isAlias {
      for b in isa.defs where !b.isAlias && b.id > a.id && b.cls == a.cls {
        if max(a.archLo, b.archLo) > min(a.archHi, b.archHi) { continue }
        // the fixed bits both definitions look at must differ somewhere
        let both = a.fixedMask & b.fixedMask
        if (a.base ^ b.base) & both == 0 { ambiguous.append("\(a.fullName) and \(b.fullName)") }
      }
    }
    #expect(ambiguous.isEmpty, "\(ambiguous.joined(separator: "\n"))")
  }

  @Test func zeroWordIsNotAnInstruction() {
    #expect(throws: DecodeError.self) { try isa.decode(0) }
    #expect((try? isa.decode(0x0000_C000_0000_0000))?.mnemonic == "NOP")
    #expect(throws: DecodeError.self) { try isa.decode(0x8000_C000_0000_0000) }
  }
}
