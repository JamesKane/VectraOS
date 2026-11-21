// SPDX-License-Identifier: BSD-3-Clause

// Fields the spec pins down in its clarified text: the shift lane of the
// 32- and 64-bit families (11b.5.1, 11b.5.2), LD_VAR_SPECIAL's suffixes
// (10.14 rule 2, 12c.5.4), BLEND's skip (12c.6.3), the texture register type
// (12b.4), TEX_GRADIENT's read count (12b.5.6) and the dual forms' write
// count (12b.8.3, 12b.9.3).

import Testing

@testable import ValhallISA

private func laneField(_ word: UInt64) -> UInt64 { (word >> 26) & 15 }

@Suite struct ClarifiedFieldTests {
  let isa = ISATable.shared

  // MARK: spec examples that break a rule of their own section

  @Test func discrepantExamplesAreOnlyTheOnesListed() {
    #expect(discrepantExamples.count == 1)
    for e in discrepantExamples {
      // The spec's word does not decode (type 0); the corrected word is the example.
      let spec = allSpecWords.first { $0.asm == e.asm }
      #expect(spec != nil)
      if let spec { #expect((try? isa.decode(spec.word, arch: spec.arch)) == nil) }
      #expect(throws: Never.self) { _ = try isa.decode(e.corrected, arch: 12) }
      let assembled = try? isa.assemble(e.asm, arch: 12)
      #expect(assembled.flatMap { try? isa.encode($0) } == e.corrected)
    }
  }

  @Test func theFADDExamplesOfSection13Verify() throws {
    let a = try isa.assemble("FADD.f32.wait0126 r3, r3^, r9.h1")
    #expect(try isa.encode(a) == 0x40A4_C300_0800_0943)
    let b = try isa.assemble("FADD.f32.wait r2, r2^, r9^.h0")
    #expect(try isa.encode(b) == 0x48A4_C200_0400_4942)
    #expect(isa.disassemble(try isa.decode(0x40A4_C300_0800_0943)) == "FADD.f32.wait0126 r3, r3^, r9.h1")
  }

  // MARK: shift lanes

  @Test func shiftLaneDefaultsAndValues() throws {
    for m in ["LSHIFT", "RSHIFT", "ARSHIFT", "LROT", "RROT"] {
      for v in ["i32", "i64"] {
        let wide = v == "i64"
        let text = wide ? "\(m).\(v) r0:r1, r2:r3, r4:r5" : "\(m).\(v) r0, r1, r2"
        #expect(laneField(try isa.encode(try isa.assemble(text))) == 4, "\(m).\(v)")
        for (lane, code) in [("b0", 4), ("b1", 5), ("b2", 6), ("b3", 7)] {
          let src1 = wide ? "r4:r5.\(lane)" : "r2.\(lane)"
          let t = wide ? "\(m).\(v) r0:r1, r2:r3, \(src1)" : "\(m).\(v) r0, r1, \(src1)"
          #expect(laneField(try isa.encode(try isa.assemble(t))) == UInt64(code), "\(t)")
        }
      }
      #expect(laneField(try isa.encode(try isa.assemble("\(m).v2i16 r0, r1, r2"))) == 0)
      #expect(laneField(try isa.encode(try isa.assemble("\(m).v4i8 r0, r1, r2"))) == 0)
    }
    // the family itself, and its aliases' base words
    #expect(laneField(try isa.encode(try isa.assemble("RSHIFT_OR.i32 r0, r1, r2, r3"))) == 4)
    #expect(laneField(try isa.encode(try isa.assemble("LSHIFT_AND.i64 r0:r1, r2:r3, r4:r5, r6:r7"))) == 4)
    #expect(laneField(try isa.encode(try isa.assemble("LSHIFT_AND.v2i16 r0, r1, r2, r3"))) == 0)
    #expect(try isa.encode(try isa.assemble("LROT.i32 r0, r1, r2")) == 0x00B4_C003_11C0_0201)
    #expect(try isa.encode(try isa.assemble("RSHIFT_OR.i32.not_result r0, r1^, r2^.b0, 0x0")) == 0x00B4_C000_51C0_4241)
  }

  @Test func shiftLaneOutsideFourToSevenDoesNotEncode() throws {
    for v in ["i32", "i64"] {
      let wide = v == "i64"
      let text = wide ? "RSHIFT_OR.i64 r0:r1, r2:r3, r4:r5, r6:r7" : "RSHIFT_OR.i32 r0, r1, r2, r3"
      let base = try isa.assemble(text)
      let at = base.def.fieldIndex(role: .lane(1))
      #expect(at >= 0)
      for lane in [0, 1, 2, 3, 8, 9, 15] as [UInt64] {
        var i = base
        i.values[at] = lane
        #expect(throws: EncodeError.unknownValue(base.def.fields[at].name)) { _ = try isa.encode(i) }
        let rules = isa.validate([i, Instruction("NOP")!.with(flow: .end)], options: ValidatorOptions(stage: .compute)).map { $0.rule }
        #expect(rules.contains(ValidationRule.encodable), "\(v) lane \(lane)")
      }
      // and a word that carries one is no instruction
      let w = try isa.encode(base) & ~(UInt64(15) << 26)
      #expect(throws: DecodeError.noInstruction) { _ = try isa.decode(w) }
    }
    // the 16-bit and byte families keep 0
    let v2 = try isa.assemble("RSHIFT_OR.v2i16 r0, r1, r2, r3")
    #expect(isa.validate([v2, Instruction("NOP")!.with(flow: .end)]).isEmpty)
  }

  // MARK: LD_VAR_SPECIAL

  @Test func ldVarSpecialSuffixes() throws {
    let canon = "LD_VAR_SPECIAL.v2.f32.point.slot0.sample.clobber.wait0 @r2:r3, r61"
    let word: UInt64 = 0x0856_82B4_1200_003D
    #expect(try isa.encode(try isa.assemble(canon)) == word)
    // `.clobber` is the same as leaving the update mode out; the suffixes go in any order
    let spellings = [
      "LD_VAR_SPECIAL.v2.f32.point.slot0.sample.wait0 @r2:r3, r61",
      "LD_VAR_SPECIAL.v2.f32.point.slot0.clobber.sample.wait0 @r2:r3, r61",
      "LD_VAR_SPECIAL.sample.point.v2.slot0.f32.wait0 @r2:r3, r61",
      "LD_VAR_SPECIAL.wait0.v2.f32.point.slot0.sample @r2:r3, r61",
    ]
    for s in spellings { #expect(try isa.encode(try isa.assemble(s, arch: 10)) == word, "\(s)") }
    // output is canonical: v2, f32, name, slot, sample, flow, with no update on arch 10 to 13
    #expect(isa.disassemble(try isa.decode(word)) == "LD_VAR_SPECIAL.v2.f32.point.slot0.sample.wait0 @r2:r3, r61")
    #expect(
      isa.disassemble(try isa.assemble("LD_VAR_SPECIAL.frag_z.f32.center.slot0 @r2, 0x0"))
        == "LD_VAR_SPECIAL.f32.frag_z.slot0.center @r2, 0x0")
    #expect(
      isa.disassemble(try isa.assemble("LD_VAR_SPECIAL.f32.frag_w.slot1.centroid.clobber @r2, 0x0"))
        == "LD_VAR_SPECIAL.f32.frag_w.slot1.centroid @r2, 0x0")
  }

  @Test func ldVarSpecialHasNoOperandsForItsNames() {
    // the name is a suffix, never an operand; the hardware fixes the update mode on arch 10 to 13
    #expect(throws: AssembleError.self) { _ = try isa.assemble("LD_VAR_SPECIAL.v2.f32.slot0.sample.clobber.wait0 @r2:r3, r61, point") }
    #expect(throws: AssembleError.self) { _ = try isa.assemble("LD_VAR_SPECIAL.f32.point.slot0.center.store @r2, 0x0") }
    #expect(throws: AssembleError.self) { _ = try isa.assemble("LD_VAR_SPECIAL.f32.point.slot0.center.retrieve @r2, 0x0") }
  }

  // MARK: BLEND skip

  @Test func blendSkipIsBytesInEightByteUnits() throws {
    let i = try isa.assemble("BLEND.f32.slot0 @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:16")
    #expect((try isa.encode(i) >> 8) & 0xFF == 2)
    #expect(i.value("skip") == 16)
    #expect(isa.disassemble(i) == "BLEND.f32.slot0 @r0:r1:r2:r3, blend_descriptor_0, r60, skip:16")
    #expect(try isa.encode(try isa.assemble("BLEND.f32.slot0 @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:2040")) >> 8 & 0xFF == 255)
    let back = try isa.decode(try isa.encode(i))
    #expect(back.value("skip") == 16)
    #expect(throws: EncodeError.misaligned("skip")) {
      _ = try isa.encode(try isa.assemble("BLEND.f32.slot0 @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:12"))
    }
    #expect(throws: EncodeError.fieldOverflow("skip")) {
      _ = try isa.encode(try isa.assemble("BLEND.f32.slot0 @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:2048"))
    }
    #expect(throws: AssembleError.self) {
      _ = try isa.assemble("BLEND.f32.slot0 @r0:r1:r2:r3, blend_descriptor_0.w0, r60, target:0")
    }
    var bad = i
    bad.set("skip", 12)
    #expect(isa.validate([bad]).map { $0.rule }.contains(ValidationRule.encodable))
  }

  // MARK: texture register type

  @Test func textureRegisterType() throws {
    let text = "TEX_FETCH.tex2d.dst32.rgba.slot0 @r0:r1:r2:r3, @r60:r61, u0"
    let f = try isa.assemble(text)
    #expect(try isa.encode(f) == 0x0125_7C34_17C0_0080)
    #expect(f.valueName("rtype") == "f")
    for (name, code) in [("f", 1), ("u", 2), ("s", 3)] as [(String, UInt64)] {
      let t = text.replacingFirst("TEX_FETCH.", "TEX_FETCH.\(name).")
      let w = try isa.encode(try isa.assemble(t))
      #expect((w >> 26) & 3 == code, "\(t)")
      let shown = isa.disassemble(try isa.decode(w))
      #expect(shown == (name == "f" ? "TEX_FETCH.tex2d.dst32.slot0 @r0:r1:r2:r3, @r60:r61, u0" : "TEX_FETCH.\(name).tex2d.dst32.slot0 @r0:r1:r2:r3, @r60:r61, u0"), "\(shown)")
    }
    // every texture family has it, and 0 is invalid
    for m in ["TEX_SINGLE", "TEX_FETCH", "TEX_GATHER", "TEX_GRADIENT", "TEX_DUAL", "VAR_TEX_SINGLE", "VAR_TEX_GATHER",
      "VAR_TEX_GRADIENT", "VAR_TEX_DUAL", "VAR_TEX_BUF_SINGLE"]
    {
      var i = try #require(Instruction(m))
      #expect(i.valueName("rtype") == "f", "\(m)")
      i.set("rtype", 0)
      #expect(throws: EncodeError.unknownValue("rtype")) { _ = try isa.encode(i) }
      #expect(isa.validate([i]).map { $0.rule }.contains(ValidationRule.encodable), "\(m)")
    }
    #expect(throws: DecodeError.noInstruction) { _ = try isa.decode(0x0125_7C34_13C0_0080) }
  }

  // MARK: TEX_GRADIENT read count

  @Test func gradientReadCount() throws {
    // (c << derivative) + projection, c = 1, 2, 3 and 2 for a cube; 5 and 7 are not encodable
    let dims: [(String, UInt64)] = [("tex1d", 1), ("tex2d", 2), ("tex3d", 3), ("cube", 2)]
    for (dim, c) in dims {
      for derivative in [false, true] {
        for projection in [false, true] {
          var i = try #require(Instruction("TEX_GRADIENT"))
          i.set("dim", named: dim)
          i.set("derivative", derivative ? 1 : 0)
          i.set("project", projection ? 1 : 0)
          isa.normalize(&i)
          let expected = (c << (derivative ? 1 : 0)) + (projection ? 1 : 0)
          #expect(i.stagingRead?.count == Int(expected), "\(dim) derivative \(derivative) projection \(projection)")
          if expected == 5 || expected == 7 {
            #expect(throws: EncodeError.badCount("sc")) { _ = try isa.encode(i) }
          } else {
            let w = try isa.encode(i)
            #expect(try isa.decode(w).stagingRead?.count == Int(expected))
          }
        }
      }
    }
    // only tex1d takes derivative with projection
    var ok = 0
    for (dim, _) in dims {
      var i = try #require(Instruction("TEX_GRADIENT"))
      i.set("dim", named: dim)
      i.set("derivative", 1)
      i.set("project", 1)
      isa.normalize(&i)
      if (try? isa.encode(i)) != nil { ok += 1 }
    }
    #expect(ok == 1)
  }

  // MARK: dual write counts

  @Test func texDualWriteCount() throws {
    // total = Rp + Rs registers, stored one less (1 to 7); Rs is 1 to 4 (dst32) or 1 or 2 (dst16)
    for (mask, rpWidth, rp) in [("rgba", "dst32", 4), ("r", "dst32", 1), ("rg", "dst16", 1), ("rgba", "dst16", 2)]
      as [(String, String, Int)]
    {
      for (sw, most) in [("dst32", 4), ("dst16", 2)] {
        var i = try #require(Instruction("TEX_DUAL"))
        i.set("mask", named: mask)
        i.set("width", named: rpWidth)
        i.set("swidth", named: sw)
        for total in 1...8 {
          i.set("swc", UInt64(total))
          let lo = rp + 1
          let hi = rp + most
          var n = i
          isa.normalize(&n)
          let want = min(max(total, lo), hi)
          #expect(n.stagingWrite?.count == want, "\(mask) \(rpWidth) \(sw) total \(total)")
          let rules = isa.validate([i, Instruction("NOP")!.with(flow: .end)]).map { $0.rule }
          #expect(rules.contains(ValidationRule.stagingCount) == (total != want), "\(mask) \(rpWidth) \(sw) total \(total)")
          if total == want {
            let w = try isa.encode(i)
            #expect((w >> 36) & 7 == UInt64(total - 1))
            #expect(try isa.decode(w).stagingWrite?.count == total)
          }
        }
      }
    }
    // the largest: rgba dst32 + dst32 with 4 channels is 8 registers, stored 7
    var big = try #require(Instruction("TEX_DUAL"))
    big.set("mask", named: "rgba")
    big.set("width", named: "dst32")
    big.set("swidth", named: "dst32")
    big.set("swc", 8)
    #expect((try isa.encode(big) >> 36) & 7 == 7)
  }

  @Test func varTexDualWriteCount() throws {
    // Rp is 2 for a dst16 primary and 4 for dst32, the stored count 2 to 7
    for (width, rp) in [("dst16", 2), ("dst32", 4)] as [(String, Int)] {
      for (sw, most) in [("dst32", 4), ("dst16", 2)] {
        var i = try #require(Instruction("VAR_TEX_DUAL"))
        i.set("width", named: width)
        i.set("swidth", named: sw)
        for total in 1...8 {
          i.set("sc", UInt64(total))
          let want = min(max(total, rp + 1), rp + most)
          var n = i
          isa.normalize(&n)
          #expect(n.stagingWrite?.count == want, "\(width) \(sw) total \(total)")
          let rules = isa.validate([i, Instruction("NOP")!.with(flow: .end)]).map { $0.rule }
          #expect(rules.contains(ValidationRule.stagingCount) == (total != want), "\(width) \(sw) total \(total)")
          if total == want {
            let stored = (try isa.encode(i) >> 36) & 7
            #expect(stored == UInt64(total - 1) && stored >= 2)
          }
        }
      }
    }
    // the assembler reports a block of the wrong size
    #expect(throws: AssembleError.self) {
      _ = try isa.assemble("VAR_TEX_DUAL.skip.sample_store.tex2d.dst32.none.slot0 @r0:r1, u1, u0.w0")
    }
  }
}

extension Instruction {
  fileprivate func with(flow: Flow) -> Instruction {
    var i = self
    i.flow = flow
    return i
  }
}
