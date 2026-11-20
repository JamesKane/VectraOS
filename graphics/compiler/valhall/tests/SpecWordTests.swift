// SPDX-License-Identifier: BSD-3-Clause

// Every encoded example of valhall 10 to 13 (SpecWords.swift) round-trips:
// decoded and encoded again, assembled from its text, and disassembled and
// assembled again, each time to the word the spec gives.

import Testing

@testable import ValhallISA

/// Bits a spec word sets that its own assembler text does not name: the
/// ignored field `[27:26]` of the texture forms (the spec says the
/// reference assembler writes it), which the assembler leaves zero.
func ignoredBits(_ asm: String) -> UInt64 {
  if asm.hasPrefix("TEX_") || asm.hasPrefix("VAR_TEX_") { return 0x0000_0000_0C00_0000 }
  return 0
}

/// Spec examples whose assembler text and word disagree with the spec's own field tables (OPEN QUESTIONs, listed
/// in the report). They are skipped by the text checks, and the words still decode where a definition matches.
let discrepantExamples: [(asm: String, why: String)] = [
  (
    "FADD.f32.wait0126 r3, r3^, r9.h1",
    "valhall 13.3.3: the widen of src1 is at [19:18] in the word; 10.13.2 and 11a put it at [27:26]; the word is FEXP.f32"
  ),
  (
    "FADD.f32.wait r2, r2^, r9^.h0",
    "valhall 13.3.3: the widen of src1 is at [19:18] in the word (opcode 2 = 4, no such instruction)"
  ),
  (
    "RSHIFT_OR.i32.not_result r0, r1^, r2^.b0, 0x0",
    "valhall 11b.5.5: the word holds lane 0 in [29:26] where the text says b0 (4); 11b.5.1 reserves 0"
  ),
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
        let inst = try isa.assemble(w.asm, arch: w.arch)
        let e = try isa.encode(inst)
        let mask = ~ignoredBits(w.asm)
        if e & mask != w.word & mask {
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
