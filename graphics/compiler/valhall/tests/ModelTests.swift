// SPDX-License-Identifier: BSD-3-Clause

// The instruction model, the notation of valhall 10.14 and the errors an
// encoder or an assembler reports.

import Testing

@testable import ValhallISA

@Suite struct ModelTests {
  let isa = ISATable.shared

  @Test func buildsAnInstructionFromTheModel() throws {
    var i = try #require(Instruction("FADD", "f32"))
    i.setSource(0, .register(1))
    i.setSource(1, .user(slot: 5, word: 1))
    i.fauPage = 1
    i.set("dst", 0)
    #expect(try isa.encode(i) == 0x02A4_C000_0000_8B01)
    #expect(isa.disassemble(i) == "FADD.f32 r0, r1, u37.w1")
    #expect(i.mnemonic == "FADD" && i.variant == "f32")
    #expect(i.def.unit == .fma && i.def.cls == .r2)
    #expect(i.sources.count == 2)
  }

  @Test func operandsCarryTheirModifiers() throws {
    let i = try isa.assemble("FMA.f32 r2, r0, 0x44000000.neg.h1, 0x0.neg")
    let b = try #require(i.operand(1))
    #expect(b.source == .constant(29) && b.negate && !b.absolute && b.laneName == "h1")
    let c = try #require(i.operand(2))
    #expect(c.source == .zero && c.negate)
    #expect(i.operand(3) == nil)
    #expect(i.destination == 2 && i.destinationWidth == 3)
  }

  @Test func wideOperandsAndBlocks() throws {
    let i = try isa.assemble("LOAD.i64.slot1 @r2:r3, [r4^:r5^], offset:-16")
    #expect(i.operand(0)?.is64Bit == true)
    #expect(i.source(0) == .register(4, lastUse: true))
    #expect(i.stagingWrite == RegisterBlock(first: 2, count: 2))
    #expect(i.stagingRead == nil)
    #expect(i.slot == 1)
    #expect(i.value("offset") == UInt64(bitPattern: -16))
    let t = try isa.assemble("ATOM_RETURN.i32.aadd.slot0 @r7, @r12, [r48:r49], offset:4")
    #expect(t.stagingWrite == RegisterBlock(first: 7, count: 1))
    #expect(t.stagingRead == RegisterBlock(first: 12, count: 1))
  }

  @Test func theAssemblerReadsEveryFormOfSource() throws {
    #expect(try isa.assemble("IADD.u32 r0, r1, 0x7060504").source(1) == .constant(9))
    #expect(try isa.assemble("MOV.i32 r1, lane_id.w0").source(0) == .special(entry: 1))
    #expect(try isa.assemble("MOV.i32 r1, lane_id.w0").fauPage == 3)
    #expect(try isa.assemble("FADD.f32 r0, r1, u37.w1").fauPage == 1)
    #expect(try isa.assemble("FADD.f32 r0, r1, r2 ; a comment").source(1) == .register(2))
    #expect(try isa.assemble("0x0000_C000_0000_0000").mnemonic == "NOP")
  }

  @Test func theDisassemblerPrefersAnAliasWhenAsked() throws {
    let word: UInt64 = 0x0110_C512_3456_78C0
    #expect(isa.disassemble(try isa.decode(word)) == "IADD_IMM.i32 r5, 0x0, #0x12345678")
    #expect(isa.disassemble(try isa.decode(word, aliases: true)) == "MOV_IMM.i32 r5, #0x12345678")
    #expect(isa.disassemble(try isa.decode(0x0710_C200_0000_10FE, aliases: true)) == "ADR r2, #0x10")
    #expect(isa.disassemble(try isa.decode(0x7800_C000_0000_0000)) == "NOP.end")
    #expect(isa.disassemble(try isa.decode(0x0860_8082_1800_0040)) == "LOAD.i32.slot0.wait0 @r0, [r0^:r1^], offset:0")
  }

  @Test func aProgramAssemblesLineByLine() throws {
    let p = try isa.assemble(program: "; a shader\nNOP\n\nNOP.wait0 ; wait\nNOP.end\n")
    #expect(p.count == 3 && p[1].flow == .wait0 && p[2].flow == .end)
  }

  @Test func theAssemblerRejectsWhatDoesNotEncode() {
    func fails(_ text: String) -> Bool {
      do {
        _ = try isa.assemble(text)
        return false
      } catch {
        return true
      }
    }
    #expect(fails("FROB r0, r1"))
    #expect(fails("FADD.q32 r0, r1, r2"))
    #expect(fails("FADD.f32 r0, r1, 0x12345678"))  // not a small constant
    #expect(fails("FADD.f32 r0, r1, u0.w0, u1.w0"))  // too many operands
    #expect(fails("FADD.f32 r0, r1"))  // too few
    #expect(fails("FADD.f32 r0, u0.w0, u40.w0"))  // two FAU pages
    #expect(fails("IADD.u64 r2:r3, r5:r7, r6:r7"))  // not a pair
    #expect(fails("FADD.f32.nonsense r0, r1, r2"))
    #expect(fails("LOAD.i64.slot0 @r2, [r4:r5], offset:0"))  // one register for two
    #expect(fails("NOP r0"))
    #expect(fails("FADD.f32 r64, r1, r2"))
  }

  @Test func theEncoderRejectsWhatDoesNotFit() throws {
    var i = try #require(Instruction("BRANCH"))
    i.set("offset", UInt64(1 << 26))
    #expect(throws: EncodeError.self) { try isa.encode(i) }
    i.set("offset", UInt64(bitPattern: -(1 << 26)))
    #expect(try isa.decode(try isa.encode(i)).value("offset") == UInt64(bitPattern: -(1 << 26)))
    var f = try #require(Instruction("FADD", "f32"))
    f.set("clamp", 4)
    #expect(throws: EncodeError.self) { try isa.encode(f) }
    f.set("clamp", 0)
    f.fauPage = 4
    #expect(throws: EncodeError.self) { try isa.encode(f) }
  }

  @Test func theSmallConstantTableIsTheSpecs() {
    #expect(SmallConstants.values.count == 32)
    #expect(SmallConstants.index(of: 0x3F80_0000) == 16)
    #expect(SmallConstants.index(of: 0) == 0)
    #expect(SmallConstants.index(of: 0x2724_28E0) == 21)
    #expect(SpecialFAU.name(page: 3, entry: 15) == "pc")
    #expect(SpecialFAU.entry(named: "blend_descriptor_7")?.entry == 15)
  }

  @Test func branchOffsetsCountInstructions() throws {
    // valhall 13.4.4: the loop of three instructions closed by a branch at A+24, offset -4
    let loop = try isa.assemble("BRANCH.not 0x0, offset:-4")
    #expect(try isa.encode(loop) == 0x001F_C017_FFFF_FCC0)
    #expect(try isa.encode(isa.assemble("BRANCH r1, offset:-4")) == 0x001F_C007_FFFF_FC01)
  }
}
