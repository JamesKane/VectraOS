// SPDX-License-Identifier: BSD-3-Clause

// Words made of a definition's fixed bits and random free bits: a word the
// decoder accepts encodes again to itself, and the text it disassembles to
// assembles to the same word.

import Testing

@testable import ValhallISA

struct Random64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var x = state
    x ^= x >> 33
    x = x &* 0xFF51_AFD7_ED55_8CCD
    x ^= x >> 33
    return x
  }
}

@Suite struct FuzzTests {
  let isa = ISATable.shared

  @Test func decodedWordsEncodeToThemselves() {
    var rng = Random64(state: 0x5EED)
    var decoded = 0
    var failures: [String] = []
    let total = 40_000
    for n in 0..<total {
      let d = isa.defs[Int(rng.next() % UInt64(isa.defs.count))]
      let flowAndPage = (rng.next() & 0x7E00_0000_0000_0000)
      let word = (d.base & ~d.freeMask) | (rng.next() & d.freeMask) | flowAndPage
      let arch = archFor(d)
      for aliases in [false, true] {
        guard let inst = try? isa.decode(word, arch: arch, aliases: aliases) else { continue }
        decoded += 1
        do {
          let again = try isa.encode(inst)
          if again != word { failures.append("\(hex16(word)) (\(inst.def.fullName)) encodes as \(hex16(again))") }
        } catch {
          // reserved flow values decode but do not encode
          if inst.flow != .reserved11 && inst.flow != .reserved14 { failures.append("\(hex16(word)): \(error.description)") }
        }
      }
      _ = n
    }
    #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
    #expect(decoded > total / 4, "only \(decoded) words decoded")
  }

  @Test func disassembledTextAssemblesToTheSameWord() {
    var rng = Random64(state: 0xA55E)
    var failures: [String] = []
    var checked = 0
    for _ in 0..<20_000 {
      let d = isa.defs[Int(rng.next() % UInt64(isa.defs.count))]
      var word = (d.base & ~d.freeMask) | (rng.next() & d.freeMask)
      // reserved flow values have no text; keep the page the definition's, a source naming FAU needs its page
      word |= UInt64((rng.next() % 10)) << 59
      guard let inst = try? isa.decode(word, arch: archFor(d), aliases: rng.next() & 1 == 0) else { continue }
      if let b = inst.stagingRead, b.first + b.count > 64 { continue }
      if let b = inst.stagingWrite, b.first + b.count > 64 { continue }
      let text = isa.disassemble(inst)
      if text.contains("r64") { continue }
      // a 64-bit FAU source naming word 1 has no text of its own: it is an invalid encoding
      if isa.effectiveSources(inst).contains(where: { $0.wide && $0.byte & 1 != 0 && ($0.byte >= 0x80 && $0.byte < 0xC0 || $0.byte >= 0xE0) }) { continue }
      checked += 1
      do {
        let back = try isa.assemble(text, arch: archFor(d))
        let e = try isa.encode(back)
        if e != word { failures.append("\(text): \(hex16(word)) assembled to \(hex16(e))") }
      } catch {
        failures.append("\(text) (\(hex16(word))): \(error)")
      }
    }
    #expect(checked > 1000)
    #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
  }
}
