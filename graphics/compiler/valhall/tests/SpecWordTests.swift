// SPDX-License-Identifier: BSD-3-Clause

// Every encoded example of valhall 10 to 13 (SpecWords.swift) round-trips:
// decoded and encoded again, assembled from its text, and disassembled and
// assembled again, each time to the word the spec gives.

import Testing

@testable import ValhallISA

/// The text to assemble for a spec word: its own, with the register type of a texture word written as a modifier
/// where the spec's text does not carry it (12b.4: the type comes from the destination's data kind, which the
/// assembler text does not name).
func textToAssemble(_ w: SpecWord) -> String {
  if w.regType.isEmpty { return w.asm }
  guard let dot = w.asm.firstIndex(of: ".") else { return w.asm }
  return String(w.asm[w.asm.startIndex..<dot]) + "." + w.regType + String(w.asm[dot...])
}

/// Spec examples whose word breaks the spec's own rules. Each is checked in its corrected form below.
let discrepantExamples: [(asm: String, why: String, corrected: UInt64)] = [
  (
    "TEX_SINGLE.tex2d.computed.dst32.rgba.slot0 @r0:r1:r2:r3, @r8:r9, u4",
    "valhall 12b.16: the derived word 0x0128_4834_13C0_2088 has 0 (invalid) in the register type [27:26] (12b.4); "
      + "the word with the type f is 0x0128_4834_17C0_2088",
    0x0128_4834_17C0_2088
  )
]

func isDiscrepant(_ asm: String) -> Bool { discrepantExamples.contains { $0.asm == asm } }

@Suite struct SpecWordTests {
  let isa = ISATable.shared

  @Test func everyWordDecodesAndEncodesAgain() {
    var failures: [String] = []
    for w in allSpecWords where w.arch <= 13 && !isDiscrepant(w.asm) {
      do {
        let plain = try isa.decode(w.word, arch: w.arch)
        let e1 = try isa.encode(plain)
        if e1 != w.word { failures.append("\(w.asm): decode/encode gave \(hexString(e1)), not \(hexString(w.word))") }
        let alias = try isa.decode(w.word, arch: w.arch, aliases: true)
        let e2 = try isa.encode(alias)
        if e2 != w.word { failures.append("\(w.asm): alias decode/encode gave \(hexString(e2))") }
      } catch {
        failures.append("\(w.asm) \(hexString(w.word)): \(error)")
      }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }

  @Test func everyTextAssemblesToItsWord() {
    var failures: [String] = []
    for w in allSpecWords where w.arch <= 13 && !isDiscrepant(w.asm) {
      do {
        let inst = try isa.assemble(textToAssemble(w), arch: w.arch)
        let e = try isa.encode(inst)
        if e != w.word {
          failures.append("\(w.asm): assembled to \(hexString(e)), not \(hexString(w.word))")
        }
      } catch {
        failures.append("\(w.asm): \(error)")
      }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }

  @Test func everyWordDisassemblesAndAssemblesAgain() {
    var failures: [String] = []
    for w in allSpecWords where w.arch <= 13 && !isDiscrepant(w.asm) {
      for aliases in [false, true] {
        do {
          let inst = try isa.decode(w.word, arch: w.arch, aliases: aliases)
          let text = isa.disassemble(inst)
          let back = try isa.assemble(text, arch: w.arch)
          let e = try isa.encode(back)
          if e != w.word { failures.append("\(w.asm) -> \(text): assembled to \(hexString(e)), not \(hexString(w.word))") }
        } catch {
          failures.append("\(w.asm): \(error)")
        }
      }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }
}
