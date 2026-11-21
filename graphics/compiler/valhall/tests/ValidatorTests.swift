// SPDX-License-Identifier: BSD-3-Clause

// The validator's rules (Validator.swift): for each, a shader that breaks it
// and the corrected one.

import Testing

@testable import ValhallISA

let isa = ISATable.shared

/// Assemble a shader.
func shader(_ text: String, arch: Int = 12) -> [Instruction] {
  do {
    return try isa.assemble(program: text, arch: arch)
  } catch {
    Issue.record("does not assemble: \(error.description)\n\(text)")
    return []
  }
}

/// The names of the rules a shader breaks.
func broken(_ text: String, _ options: ValidatorOptions = ValidatorOptions(), edit: (inout [Instruction]) -> Void = { _ in })
  -> [String]
{
  var p = shader(text, arch: options.arch)
  edit(&p)
  var names: [String] = []
  for v in isa.validate(p, options: options) where !names.contains(v.rule) { names.append(v.rule) }
  return names
}

let fragment = ValidatorOptions(stage: .fragment)

@Suite struct ValidatorTests {
  /// valhall 13.7.5: the worked sequence.
  let clean = """
    LOAD.i32.slot0 @r8, [r2:r3], offset:0
    LOAD.i32.slot1.wait0 @r9, [r2:r3], offset:4
    FADD.f32.wait1 r10, r8, r9
    STORE.i32.slot2 @r10, [r4:r5], offset:0
    NOP.end
    """

  @Test func aCorrectShaderPasses() {
    #expect(broken(clean) == [])
    #expect(broken(clean, ValidatorOptions(registerClass: .class32)) == [])
  }

  @Test func everyRuleHasAName() {
    #expect(ValidationRule.all.count == 30)
    var seen: [String] = []
    for r in ValidationRule.all {
      #expect(!seen.contains(r), "\(r) twice")
      seen.append(r)
    }
  }

  @Test func encodable() {
    let bad = broken("FADD.f32 r0, r1, r2\nNOP.end") { $0[0].values[$0[0].def.fieldIndex("dst")] = 70 }
    #expect(bad.contains(ValidationRule.encodable))
    let reserved = broken("NOP.end") { $0[0].flow = .reserved14 }
    #expect(reserved.contains(ValidationRule.encodable))
  }

  @Test func archAvailable() {
    #expect(broken("MMUL.f32 r0, u0, r1, r2\nNOP.end", ValidatorOptions(arch: 11)) == [])
    #expect(broken("NOP.end", ValidatorOptions(arch: 11)) == [])
    var p = shader("LD_CHECKED_IMM.i32.slot0 @r0, [r2:r3], #4, r5\nNOP.end")
    p[0].flow = .none
    let rules = isa.validate(p, options: ValidatorOptions(arch: 11)).map { $0.rule }
    #expect(rules.contains(ValidationRule.archAvailable))
  }

  @Test func registerClass() {
    let text = "MOV.i32 r20, r1\nNOP.end"
    #expect(broken(text, ValidatorOptions(registerClass: .class64)) == [])
    #expect(broken(text, ValidatorOptions(registerClass: .class32)).contains(ValidationRule.registerClass))
    #expect(broken("MOV.i32 r50, r15\nNOP.end", ValidatorOptions(registerClass: .class32)) == [])
  }

  @Test func pairAlignment() {
    let odd = broken("LOAD.i32.slot0 @r0, [r2:r3], offset:0\nNOP.end") { p in
      p[0].setSource(0, .register(3))
    }
    #expect(odd.contains(ValidationRule.pairAlignment))
    let word1 = broken("LOAD.i32.slot0 @r0, u0, offset:0\nNOP.end") { p in p[0].setSource(0, .user(slot: 0, word: 1)) }
    #expect(word1.contains(ValidationRule.pairAlignment))
    let dst = broken("IADD.u64 r2:r3, r4:r5, r6:r7\nNOP.end") { p in p[0].set("dst", 3) }
    #expect(dst.contains(ValidationRule.pairAlignment))
  }

  @Test func stagingBlocks() {
    let odd = broken("LOAD.i64.slot0 @r2:r3, [r4:r5], offset:0\nNOP.end") { p in p[0].set("sr", 3) }
    #expect(odd.contains(ValidationRule.stagingAlignment))
    let past = broken("LOAD.i128.slot0 @r4:r5:r6:r7, [r0:r1], offset:0\nNOP.end") { p in p[0].set("sr", 62) }
    #expect(past.contains(ValidationRule.stagingRange))
    let count = broken("LOAD.i32.slot0 @r4, [r0:r1], offset:0\nNOP.end") { p in p[0].set("sc", 2) }
    #expect(count.contains(ValidationRule.stagingCount))
    #expect(broken("LOAD.i64.slot0 @r2:r3, [r4:r5], offset:0\nNOP.wait0\nNOP.end") == [])
  }

  @Test func specialEntriesAndPages() {
    let undefined = broken("FADD.f32 r0, r1, r2\nNOP.end") { p in
      p[0].setSource(1, .special(entry: 0))
    }
    #expect(undefined.contains(ValidationRule.specialEntry))
    let page = broken("FADD.f32 r0, r1, r2\nNOP.end") { p in p[0].fauPage = 1 }
    #expect(page.contains(ValidationRule.fauPage))
    #expect(broken("FADD.f32 r0, r1, u37.w1\nNOP.end") == [])
    #expect(broken("ADR r2, #0x10\nNOP.end") == [])
    let mmul = broken("MMUL.f32 r0, u0, u1, r2\nNOP.end") { p in p[0].fauPage = 1 }
    #expect(mmul.contains(ValidationRule.mmulPage))
  }

  @Test func fauBudget() {
    // two locations
    #expect(broken("FADD.f32 r0, u0.w0, u1.w0\nNOP.end").contains(ValidationRule.fauBudget))
    // a user word and a special entry: one location too many for an ALU instruction
    #expect(broken("FADD.f32 r0, u0.w0, atest_datum.w0\nNOP.end").contains(ValidationRule.fauBudget))
    // three words
    #expect(broken("FMA.f32 r0, u0.w0, u0.w1, 0x3F800000\nNOP.end").contains(ValidationRule.fauBudget))
    // two words of one slot, or a word and a constant: fine
    #expect(broken("FADD.f32 r0, u0.w0, u0.w1\nNOP.end") == [])
    #expect(broken("FADD.f32 r0, u0.w0, 0x3F800000\nNOP.end") == [])
    // zero is free from arch 12, and counts before
    #expect(broken("FMA.f32 r0, u0.w0, 0x3F800000, 0x0\nNOP.end") == [])
    #expect(broken("FMA.f32 r0, u0.w0, 0x3F800000, 0x0\nNOP.end", ValidatorOptions(arch: 11)).contains(ValidationRule.fauBudget))
    // a message instruction may read a user slot and a special entry together
    #expect(broken("LD_PKA.i32.slot0 @r0, u32.w0, resource_table_pointer.w0\nNOP.end", ValidatorOptions(stage: .vertex)) == [])
  }

  @Test func messagesDoNotReadPageThreeOrWarpID() {
    #expect(broken("LOAD.i32.slot0 @r0, lane_id, offset:0\nNOP.end").contains(ValidationRule.messageSpecial))
    #expect(broken("LOAD.i32.slot0 @r0, warp_id, offset:0\nNOP.end").contains(ValidationRule.messageSpecial))
    #expect(broken("LOAD.i32.slot0 @r0, thread_local_pointer, offset:0\nNOP.end") == [])
    #expect(broken("MOV.i32 r1, lane_id.w0\nNOP.end") == [])
  }

  @Test func slotField() {
    #expect(broken("LOAD.i32.slot7 @r0, [r2:r3], offset:0\nNOP.end").contains(ValidationRule.slotField))
    #expect(broken("BARRIER.slot7.wait\nNOP.end") == [])
  }

  @Test func fixedCoverageRegister() {
    let ok = "ATEST.wait0126 @r60, r60, r1, atest_datum.w0\nNOP.end"
    #expect(broken(ok, fragment) == [])
    let bad = "ATEST.wait0126 @r60, r59, r1, atest_datum.w0\nNOP.end"
    #expect(broken(bad, fragment).contains(ValidationRule.fixedRegister))
    let dest = "ATEST.wait0126 @r58, r60, r1, atest_datum.w0\nNOP.end"
    #expect(broken(dest, fragment).contains(ValidationRule.fixedRegister))
  }

  @Test func waitsBeforeFragmentOutput() {
    #expect(broken("ATEST @r60, r60, r1, atest_datum.w0\nNOP.end", fragment).contains(ValidationRule.waitFragmentOutput))
    #expect(broken("ATEST.wait0126 @r60, r60, r1, atest_datum.w0\nNOP.end", fragment) == [])
    #expect(broken("ATEST.wait @r60, r60, r1, atest_datum.w0\nNOP.end", fragment) == [])
    // the wait may sit on the instruction before when it issues no message
    #expect(broken("NOP.wait0126\nATEST @r60, r60, r1, atest_datum.w0\nNOP.end", fragment) == [])
    // ZS_EMIT after ATEST
    let both = """
      ATEST.wait0126 @r60, r60, r1, atest_datum.w0
      ZS_EMIT.wait0126.z @r60, r1, 0x0, r60
      NOP.end
      """
    #expect(broken(both, fragment) == [])
    #expect(broken("ZS_EMIT.wait0126.z @r60, r1, 0x0, r60\nNOP.end", fragment) == [ValidationRule.atestBeforeZS])
    #expect(broken("ZS_EMIT.z @r60, r1, 0x0, r60\nNOP.end", fragment).contains(ValidationRule.waitFragmentOutput))
  }

  @Test func waitsBeforeTileAccessAndBlend() {
    let blend = "BLEND.f32.slot0 @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:0\nNOP.end"
    #expect(broken(blend, fragment).contains(ValidationRule.waitTile))
    #expect(broken(blend.replacingFirst("BLEND.f32.slot0", "BLEND.f32.slot0.wait"), fragment) == [])
    #expect(broken("ST_TILE.v4.f32.slot0 @r8:r9:r10:r11, r4, r60, r5\nNOP.end", fragment).contains(ValidationRule.waitTile))
    #expect(broken("ST_TILE.v4.f32.slot0.wait @r8:r9:r10:r11, r4, r60, r5\nNOP.end", fragment) == [])
    // a colour LD_TILE needs slot 7, a depth or stencil one slot 6
    #expect(broken("LD_TILE.v4.f32.slot0.wait0126 @r8:r9:r10:r11, r4, r60, r5\nNOP.end", fragment).contains(ValidationRule.waitTile))
    #expect(broken("LD_TILE.f32.slot0.z_stencil.wait0126 @r8, r4, r60, 0x0\nNOP.end", fragment) == [])
    #expect(broken("LD_TILE.f32.slot0.z_stencil @r8, r4, r60, 0x0\nNOP.end", fragment).contains(ValidationRule.waitTile))
    // a blend shader does not repeat the waits
    #expect(broken(blend, ValidatorOptions(stage: .blend)) == [])
  }

  @Test func blendCanEndOnlyWithItsWaitBefore() {
    let blend = "BLEND.f32.slot0.end @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:0"
    #expect(broken(blend, fragment).contains(ValidationRule.waitTile))
    #expect(broken("NOP.wait\n" + blend, fragment) == [])
    // the wait cannot come from a message instruction before it
    let message = "LD_TILE.v4.f32.slot1.wait @r8:r9:r10:r11, r4, r60, r5\n" + blend
    #expect(broken(message, fragment).contains(ValidationRule.waitTile))
  }

  @Test func archDeltas() {
    #expect(broken("MOV.i32 r1, shader_output.w0\nNOP.end", ValidatorOptions(arch: 11)).contains(ValidationRule.specialEntry))
    #expect(broken("MOV.i32 r1, shader_output.w0\nNOP.end", ValidatorOptions(arch: 12)) == [])
    #expect(broken("MOV.i32 r1, prepass_state.w0\nNOP.end", ValidatorOptions(arch: 12)).contains(ValidationRule.specialEntry))
    #expect(broken("MOV.i32 r1, prepass_state.w0\nNOP.end", ValidatorOptions(arch: 13)) == [])
    let tile = broken("LD_TILE.f32.slot0.z_stencil.last_read.wait0126 @r8, r4, r60, 0x0\nNOP.end", ValidatorOptions(arch: 10, stage: .fragment))
    #expect(tile.contains(ValidationRule.formRestriction))
    #expect(broken("IADD.v4u8 r0, r1, r2\nNOP.end", ValidatorOptions(arch: 10)) == [])
    let old = shader("IADD.v4u8 r0, r1, r2\nNOP.end", arch: 10)
    #expect(isa.validate(old, options: ValidatorOptions(arch: 11)).map { $0.rule } == [ValidationRule.archAvailable])
  }

  @Test func barrier() {
    let ok = """
      STORE.i32.slot0 @r0, [r2:r3], offset:0
      NOP.wait0
      BARRIER.slot7.wait
      LOAD.i32.slot1 @r4, [r2:r3], offset:0
      NOP.wait1.end
      """
    #expect(broken(ok) == [])
    // the barrier's own wait does not stand for the earlier one
    let own = "STORE.i32.slot0 @r0, [r2:r3], offset:0\nBARRIER.slot7.wait\nNOP.end"
    #expect(broken(own).contains(ValidationRule.waitBarrier))
    // and it carries wait
    let flow = "NOP\nBARRIER.slot7\nNOP.end"
    #expect(broken(flow).contains(ValidationRule.waitBarrier))
    #expect(broken("BARRIER.slot7.wait\nNOP.end", fragment).contains(ValidationRule.stageInstruction))
  }

  @Test func hazardsOnMessageResults() {
    // read before the slot is waited on, and after
    let raw = "LOAD.i32.slot0 @r8, [r2:r3], offset:0\nFADD.f32 r10, r8, r9\nNOP.end"
    #expect(broken(raw).contains(ValidationRule.waitRAW))
    #expect(broken(raw.replacingFirst("FADD.f32", "FADD.f32.wait0")) == [])
    // overwrite
    let waw = "LOAD.i32.slot0 @r8, [r2:r3], offset:0\nMOV.i32 r8, r9\nNOP.end"
    #expect(broken(waw).contains(ValidationRule.waitWAW))
    #expect(broken(waw.replacingFirst("MOV.i32", "MOV.i32.wait0")) == [])
    // another slot's wait is not this slot's
    let other = "LOAD.i32.slot0 @r8, [r2:r3], offset:0\nFADD.f32.wait1 r10, r8, r9\nNOP.end"
    #expect(broken(other).contains(ValidationRule.waitRAW))
    // a load in one arm, its use after the join
    let join = """
      BRANCH.reconverge r1, offset:1
      LOAD.i32.slot0.reconverge @r8, [r2:r3], offset:0
      FADD.f32 r10, r8, r9
      NOP.end
      """
    #expect(broken(join).contains(ValidationRule.waitRAW))
  }

  @Test func memoryOrder() {
    let storeThenLoad = "STORE.i32.slot0 @r0, [r2:r3], offset:0\nLOAD.i32.slot1 @r4, [r2:r3], offset:0\nNOP.wait01.end"
    #expect(broken(storeThenLoad).contains(ValidationRule.memoryOrder))
    #expect(broken(storeThenLoad.replacingFirst("slot1", "slot1.wait0")) == [])
    #expect(broken(storeThenLoad, ValidatorOptions(orderMemory: false)) == [])
    // load after load needs nothing, a store after a load does
    #expect(broken("LOAD.i32.slot0 @r4, [r2:r3], offset:0\nLOAD.i32.slot1 @r6, [r2:r3], offset:4\nNOP.wait01.end") == [])
    let loadThenStore = "LOAD.i32.slot0 @r4, [r2:r3], offset:0\nSTORE.i32.slot1 @r6, [r2:r3], offset:0\nNOP.wait01.end"
    #expect(broken(loadThenStore).contains(ValidationRule.memoryOrder))
  }

  @Test func varyingHiddenState() {
    let two = """
      LD_VAR_BUF_IMM.f32.slot0.v4.src_f32.center.store @r0:r1:r2:r3, 0x0, offset:0
      LD_VAR_BUF_IMM.f32.slot1.v4.src_f32.center.store @r4:r5:r6:r7, 0x0, offset:16
      NOP.wait01.end
      """
    #expect(broken(two, fragment).contains(ValidationRule.varyingHiddenState))
    #expect(broken(two.replacingFirst("slot1", "slot1.wait0"), fragment) == [])
    // a retrieve may follow a store
    let retrieve = two.replacingFirst("center.store @r4", "center.retrieve @r4")
    #expect(broken(retrieve, fragment) == [])
  }

  @Test func lastUse() {
    // r4 is marked last use and read again
    let live = "FADD.f32 r1, r4^, r5\nFADD.f32 r2, r4, r5\nNOP.end"
    #expect(broken(live).contains(ValidationRule.lastUseLive))
    #expect(broken("FADD.f32 r1, r4^, r5\nFADD.f32 r4, r6, r5\nFADD.f32 r2, r4, r5\nNOP.end") == [])
    // overwritten by the same instruction, and a read on another path
    #expect(broken("FADD.f32 r4, r4^, r5\nFADD.f32 r2, r4, r5\nNOP.end") == [])
    let path = """
      BRANCH.reconverge r1, offset:1
      FADD.f32 r2, r4^, r5
      FADD.f32 r3, r4, r5
      NOP.end
      """
    #expect(broken(path).contains(ValidationRule.lastUseLive))
    // a pair is marked as a whole
    #expect(broken("IADD.u64 r2:r3, r4:r5, r6:r7\nIADD.u32 r8, r4, r4\nNOP.end") == [])
    #expect(broken("IADD.u64 r2:r3, r4^:r5^, r6:r7\nIADD.u32 r8, r5, r5\nNOP.end").contains(ValidationRule.lastUseLive))
    // an in-flight message still reads its staging block
    let staging = "STORE.i32.slot0 @r4, [r2:r3], offset:0\nFADD.f32 r1, r4^, r5\nNOP.wait0.end"
    #expect(broken(staging).contains(ValidationRule.lastUseStaging))
    #expect(broken("STORE.i32.slot0 @r4, [r2:r3], offset:0\nFADD.f32.wait0 r1, r4^, r5\nNOP.end") == [])
  }

  @Test func controlFlow() {
    // a branch past the end, or before the start
    #expect(broken("BRANCH.not 0x0, offset:5\nNOP.end").contains(ValidationRule.branchTarget))
    #expect(broken("BRANCH.not 0x0, offset:-3\nNOP.end").contains(ValidationRule.branchTarget))
    // the offset counts instructions from the next one
    #expect(broken("BRANCH.not 0x0, offset:1\nFADD.f32 r0, r1, r2\nNOP.end") == [])
    #expect(broken("FADD.f32 r0, r1, r2\nBRANCH.not.reconverge 0x0, offset:-2\nNOP.end") == [])
    // a shader must end
    #expect(broken("FADD.f32 r0, r1, r2").contains(ValidationRule.endOfShader))
    #expect(broken("FADD.f32.end r0, r1, r2") == [])
    // a path that falls off the end through a branch
    let falls = "BRANCH.reconverge r1, offset:1\nNOP.end\nFADD.f32 r0, r1, r2"
    #expect(broken(falls).contains(ValidationRule.endOfShader))
    // reconverge on the blocks feeding a join (13.5.2)
    let ifThen = """
      BRANCH.not.reconverge r1, offset:1
      FADD.f32.reconverge r4, r2, r3
      FADD.f32 r5, r4, r2
      NOP.end
      """
    #expect(broken(ifThen) == [])
    #expect(broken(ifThen.replacingFirst("BRANCH.not.reconverge", "BRANCH.not")).contains(ValidationRule.reconverge))
    #expect(broken(ifThen.replacingFirst("FADD.f32.reconverge", "FADD.f32")).contains(ValidationRule.reconverge))
    // the loop of 13.4.4
    let loop = """
      FADD.f32.reconverge r1, r6, r2
      FADD.f32 r3, r3, r2
      FADD.f32 r4, r4, r2
      BRANCH.reconverge r1^, offset:-4
      NOP.end
      """
    #expect(broken(loop) == [])
    // the loop-carried read of r1 makes the mark on the branch wrong
    #expect(broken(loop.replacingFirst("r1, r6, r2", "r1, r1, r2")) == [ValidationRule.lastUseLive])
  }

  @Test func discardIsForFragmentShaders() {
    #expect(broken("NOP.discard\nNOP.end").contains(ValidationRule.discardStage))
    #expect(broken("NOP.discard\nNOP.end", fragment) == [])
    #expect(broken("CLPER.subgroup4.xor r6, r5, r7.b0\nNOP.end", ValidatorOptions(stage: .vertex)).contains(ValidationRule.stageInstruction))
    #expect(broken("CLPER.subgroup4.xor r6, r5, r7.b0\nNOP.end", fragment) == [])
  }

  @Test func formRestrictions() {
    #expect(broken("ICMP.s32.gt.i1 r0, r1, r2\nNOP.end") == [])
    let bad = broken("ICMP.s32.gt.i1 r0, r1, r2\nNOP.end") { p in p[0].set("cmp", named: "total") }
    #expect(bad.contains(ValidationRule.formRestriction))
    #expect(broken("FCMP.f32.total.i1 r0, r1, r2\nNOP.end") == [])
    let lane = broken("LD_PKA.i8.slot0 @r2, u0.w0, u0.w1\nNOP.wait0.end") { p in p[0].set("lane", named: "b1") }
    #expect(lane.contains(ValidationRule.formRestriction))
    let sat = broken("IADD.u64 r2:r3, r4:r5, r6:r7\nNOP.end") { p in p[0].set("saturate", 1) }
    #expect(sat.contains(ValidationRule.formRestriction))
    #expect(broken("TEX_FETCH.tex2d.dst32.rgba.slot0 @r0:r1:r2:r3, @r60:r61, u0\nNOP.wait0.end", fragment) == [])
    let cube = broken("TEX_FETCH.tex2d.dst32.rgba.slot0 @r0:r1:r2:r3, @r60:r61, u0\nNOP.wait0.end", fragment) { p in
      p[0].set("dim", named: "cube")
    }
    #expect(cube.contains(ValidationRule.formRestriction))
  }
}

extension String {
  /// This string with the first occurrence of `old` replaced.
  func replacingFirst(_ old: String, _ new: String) -> String {
    let a = Array(self)
    let o = Array(old)
    var i = 0
    while i + o.count <= a.count {
      if Array(a[i..<(i + o.count)]) == o { return String(a[0..<i]) + new + String(a[(i + o.count)...]) }
      i += 1
    }
    return self
  }
}
