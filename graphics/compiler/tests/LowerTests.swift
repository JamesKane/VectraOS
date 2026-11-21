// SPDX-License-Identifier: BSD-3-Clause

// The SPIR-V lowering and the verifier: golden text, memory layouts, control
// flow annotations, refusals, and the verifier's refusals.

import ShaderCompiler
import ShaderTestKit
import Testing

@Suite struct LowerTests {
  @Test func aBufferWriteLowersToAddressArithmetic() throws {
    let ir = try lowered(Corpus.fill)
    #expect(
      ir.text == """
        module entry=main local_size=64,1,1
        fn main() -> void {
        bb0:
          %0 = builtin global_invocation_id.x : i32
          %1 = imul %0, i32 3 : i32
          %2 = iadd %1, i32 1 : i32
          %3 = imul %0, i32 4 : i32
          %4 = ptradd @res(0,0):ptr<storage>, %3 : ptr<storage>
          store %4, %2 align 4
          ret
        }

        """)
  }

  @Test func theLoopAfterThePassesIsPhisAndMergeBlocks() throws {
    var ir = try lowered(Corpus.loopsum)
    try ir.optimize()
    #expect(
      ir.text == """
        module entry=main local_size=64,1,1
        fn main() -> void {
        bb0:
          %0 = builtin global_invocation_id.x : i32
          br bb1
        bb1:  ; loop merge=bb8 continue=bb7
          %1 = phi [i32 0, bb0], [%9, bb7] : i32
          %2 = phi [i32 0, bb0], [%10, bb7] : i32
          br bb2
        bb2:
          %3 = icmp ult %2, %0 : i1
          condbr %3, bb3, bb8
        bb3:  ; selection merge=bb6
          %4 = and %2, i32 1 : i32
          %5 = icmp eq %4, i32 0 : i1
          condbr %5, bb4, bb5
        bb4:
          %6 = iadd %1, %2 : i32
          br bb6
        bb5:
          %7 = imul %2, i32 3 : i32
          %8 = xor %1, %7 : i32
          br bb6
        bb6:
          %9 = phi [%8, bb5], [%6, bb4] : i32
          br bb7
        bb7:
          %10 = iadd %2, i32 1 : i32
          br bb1
        bb8:
          %11 = imul %0, i32 4 : i32
          %12 = ptradd @res(0,0):ptr<storage>, %11 : ptr<storage>
          store %12, %1 align 4
          ret
        }

        """)
  }

  @Test func theSwitchKeepsItsCasesAndItsPhi() throws {
    let ir = try lowered(Corpus.atomics)
    let t = ir.text
    #expect(t.contains("switch %"), "\(t)")
    #expect(t.contains(", default bb"), "\(t)")
    #expect(t.contains(", 0: bb") && t.contains(", 1: bb"), "\(t)")
    #expect(t.contains("phi [i32 10, bb"), "\(t)")
    #expect(t.contains("atomic add"), "\(t)")
    #expect(ir.functions[0].blocks.filter { $0.kind == .selection }.count == 1)
  }

  @Test func theBarrierAndTheSharedMemoryAreKept() throws {
    let ir = try lowered(Corpus.reduce)
    #expect(ir.globals.count == 1)
    #expect(ir.globals[0].space == .workgroup && ir.globals[0].size == 256 && ir.globals[0].align == 4)
    #expect(opCount(ir.functions[0], .barrier) == 2)
    #expect(ir.text.contains("barrier exec 2 mem 2 sem 264"), "\(ir.text)")
  }

  @Test func explicitLayoutsGiveTheByteOffsets() throws {
    let text = """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main"
      OpExecutionMode %main LocalSize 1 1 1
      OpDecorate %arr2 ArrayStride 16
      OpMemberDecorate %S 0 Offset 0
      OpMemberDecorate %S 1 Offset 8
      OpMemberDecorate %S 2 Offset 16
      OpDecorate %S Block
      OpDecorate %uarr ArrayStride 4
      OpMemberDecorate %O 0 Offset 0
      OpDecorate %O Block
      OpDecorate %ov DescriptorSet 0
      OpDecorate %ov Binding 0
      \(Corpus.prelude)
      %v2float = OpTypeVector %float 2
      %arr2 = OpTypeArray %float %u2
      %S = OpTypeStruct %uint %v2float %arr2
      %ptr_pc_S = OpTypePointer PushConstant %S
      %ptr_pc_v2 = OpTypePointer PushConstant %v2float
      %pc = OpVariable %ptr_pc_S PushConstant
      %uarr = OpTypeRuntimeArray %float
      %O = OpTypeStruct %uarr
      %ptr_sb_O = OpTypePointer StorageBuffer %O
      %ov = OpVariable %ptr_sb_O StorageBuffer
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %pa = OpAccessChain %ptr_pc_uint %pc %u0
      %a = OpLoad %uint %pa
      %pby = OpAccessChain %ptr_pc_float %pc %u1 %u1
      %by = OpLoad %float %pby
      %pa1 = OpAccessChain %ptr_pc_float %pc %u2 %u1
      %arr1 = OpLoad %float %pa1
      %pad = OpAccessChain %ptr_pc_float %pc %u2 %a
      %ad = OpLoad %float %pad
      %pb = OpAccessChain %ptr_pc_v2 %pc %u1
      %b = OpLoad %v2float %pb
      %b0 = OpCompositeExtract %float %b 0
      %o0 = OpAccessChain %ptr_sb_float %ov %u0 %u0
      OpStore %o0 %by
      %o1 = OpAccessChain %ptr_sb_float %ov %u0 %u1
      OpStore %o1 %arr1
      %o2 = OpAccessChain %ptr_sb_float %ov %u0 %u2
      OpStore %o2 %ad
      %o3 = OpAccessChain %ptr_sb_float %ov %u0 %u3
      OpStore %o3 %b0
      OpReturn
      OpFunctionEnd
      """
    let ir = try lowered(text)
    // The constant paths are constant offsets from the push constants.
    #expect(ir.text.contains("ptradd @push, i32 12"), "\(ir.text)")
    #expect(ir.text.contains("ptradd @push, i32 32"), "\(ir.text)")
    // The dynamic one scales by the array's stride.
    #expect(ir.text.contains("imul %"), "\(ir.text)")
    for (name, m) in try variants(text) {
      let mc = Machine(m)
      mc.push = bytes([1, 0, Float(1.5).bitPattern, Float(2.5).bitPattern, Float(10).bitPattern, 0, 0, 0, Float(20).bitPattern])
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 16))
      try mc.dispatch(groups: (1, 1, 1))
      #expect(floats(mc.storage[0]!) == [2.5, 20, 20, 1.5], "\(name)")
    }
  }

  @Test func naturalLayoutsPackScalarsAndAlignVectors() throws {
    // A Private struct { uint a; vec3 b; uint c; } is 48 bytes: b at 16, c at 28.
    let text = """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main"
      OpExecutionMode %main LocalSize 1 1 1
      \(Corpus.prelude)
      %v3float = OpTypeVector %float 3
      %S = OpTypeStruct %uint %v3float %uint
      %ptr_pr_S = OpTypePointer Private %S
      %ptr_pr_uint = OpTypePointer Private %uint
      OpName %pv "pv"
      %pv = OpVariable %ptr_pr_S Private
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %pc = OpAccessChain %ptr_pr_uint %pv %u2
      OpStore %pc %u1
      OpReturn
      OpFunctionEnd
      """
    let ir = try lowered(text)
    #expect(ir.globals.count == 1 && ir.globals[0].space == .private_)
    #expect(ir.globals[0].size == 32 && ir.globals[0].align == 16, "\(ir.globals)")
    #expect(ir.text.contains("ptradd @pv, i32 28"), "\(ir.text)")
  }

  @Test func aSpecializationOverrideChangesTheConstants() throws {
    let a = try lowered(Corpus.spec64)
    let b = try lowered(Corpus.spec64, spec: [(id: 0, bits: 9)])
    #expect(a.specializations.contains(Specialization(id: 0, type: .i32, bits: 5)))
    #expect(b.specializations.contains(Specialization(id: 0, type: .i32, bits: 9)))
    #expect(a.text.contains("i32 6") && b.text.contains("i32 10"), "\(a.text)\n\(b.text)")
  }

  @Test func privateVariablesGetTheirInitializers() throws {
    let text = """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main"
      OpExecutionMode %main LocalSize 1 1 1
      \(Corpus.prelude)
      %ptr_pr_uint = OpTypePointer Private %uint
      %u9 = OpConstant %uint 9
      OpName %pv "pv"
      %pv = OpVariable %ptr_pr_uint Private %u9
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %v = OpLoad %uint %pv
      %w = OpIAdd %uint %v %u1
      OpStore %pv %w
      OpReturn
      OpFunctionEnd
      """
    let ir = try lowered(text)
    #expect(ir.text.contains("store @pv, i32 9 align 4"), "\(ir.text)")
  }
}

@Suite struct RefusalTests {
  func compute(replacing a: String, with b: String, in text: String = Corpus.saxpy) -> String {
    text.replacingOccurrences(of: a, with: b)
  }

  @Test func aVertexShaderNeedsAPosition() {
    let m = refusal(
      """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      OpEntryPoint Vertex %main "main"
      \(Corpus.prelude)
      %main = OpFunction %void None %fn
      %l = OpLabel
      OpReturn
      OpFunctionEnd
      """, lower: true)
    #expect(m.contains("declares no Position output"), "\(m)")
  }

  @Test func aFragmentShaderNeedsItsOrigin() {
    let m = refusal(
      """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      OpEntryPoint Fragment %main "main"
      \(Corpus.prelude)
      %main = OpFunction %void None %fn
      %l = OpLabel
      OpReturn
      OpFunctionEnd
      """, lower: true)
    #expect(m.contains("no OriginUpperLeft"), "\(m)")
  }

  @Test func instructionsAreNamedWithTheReason() {
    let tan = refusal(compute(replacing: "%s = OpExtInst %float %glsl 31 %d", with: "%s = OpExtInst %float %glsl 15 %d", in: Corpus.vec), lower: true)
    #expect(tan.contains("OpExtInst") && tan.contains("GLSL.std.450 Tan is not supported yet"), "\(tan)")
    let rem = refusal(compute(replacing: "OpFAdd", with: "OpFRem"), lower: true)
    #expect(rem.contains("OpFRem") && rem.contains("not supported yet"), "\(rem)")
    let mismatch = refusal(compute(replacing: "%m = OpIMul %uint %i %u3", with: "%m = OpIMul %uint %i %f1", in: Corpus.fill), lower: true)
    #expect(mismatch.contains("OpIMul") && mismatch.contains("has type f32, expected i32"), "\(mismatch)")
    let unbound = refusal(compute(replacing: "OpDecorate %buf Binding 0", with: "", in: Corpus.fill), lower: true)
    #expect(unbound.contains("no DescriptorSet and Binding"), "\(unbound)")
    let nosize = refusal(compute(replacing: "OpExecutionMode %main LocalSize 64 1 1", with: "", in: Corpus.fill), lower: true)
    #expect(nosize.contains("no LocalSize"), "\(nosize)")
    let early = refusal(compute(replacing: "%p = OpAccessChain %ptr_sb_uint %buf %u0 %i", with: "%p = OpAccessChain %ptr_sb_uint %buf %u0 %later", in: Corpus.fill), lower: true)
    #expect(early.contains("%") && early.contains("before it is defined") || early.contains("not a"), "\(early)")
  }

  @Test func aStoreToABuiltinIsRefused() {
    let m = refusal(
      compute(replacing: "OpStore %p %v", with: "OpStore %px %v", in: Corpus.fill),
      lower: true)
    #expect(!m.isEmpty, "\(m)")
  }

  @Test func unreadableThingsAreRefusedNotGuessed() {
    // A matrix type.
    let mat = refusal(
      """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      %f = OpTypeFloat 32
      %v = OpTypeVector %f 4
      %m = OpTypeMatrix %v 4
      """, lower: true)
    #expect(mat.contains("OpTypeMatrix") && mat.contains("not supported"), "\(mat)")
  }
}

@Suite struct VerifierTests {
  func message(_ f: Function, scalar: Bool = false) -> String {
    do {
      try moduleOf(f).verify(scalar: scalar)
    } catch {
      return error.message
    }
    return ""
  }

  @Test func aValueUsedBeforeItsDefinition() {
    var f = Function(name: "t", params: [.i32], returns: .void)
    let b = f.addBlock()
    let a = f.makeInst(Inst(.iadd, .i32, [f.param(0), f.param(0)]))
    let c = f.makeInst(Inst(.iadd, .i32, [f.insts[a].result, f.param(0)]))
    f.blocks[b].insts = [c, a]  // the use first
    f.append(Inst(.ret, .void, []), to: b)
    #expect(message(f).contains("does not dominate its use"), "\(message(f))")
  }

  @Test func aValueFromOneArmUsedAfterTheJoin() {
    var f = Function(name: "t", params: [.bool, .i32], returns: .void)
    let b0 = f.addBlock()
    let b1 = f.addBlock()
    let b2 = f.addBlock()
    f.append(Inst(.condbr, .void, [f.param(0)], blocks: [b1, b2]), to: b0)
    let x = f.append(Inst(.iadd, .i32, [f.param(1), f.param(1)]), to: b1)
    f.append(Inst(.br, .void, [], blocks: [b2]), to: b1)
    let y = f.append(Inst(.iadd, .i32, [x, x]), to: b2)
    _ = y
    f.append(Inst(.ret, .void, []), to: b2)
    #expect(message(f).contains("does not dominate its use"), "\(message(f))")
  }

  @Test func typesAreChecked() {
    var f = Function(name: "t", params: [.i32, .i64], returns: .void)
    let b = f.addBlock()
    _ = f.append(Inst(.iadd, .i32, [f.param(0), f.param(1)]), to: b)
    f.append(Inst(.ret, .void, []), to: b)
    #expect(message(f).contains("operand 1 has type i64, result i32"), "\(message(f))")

    var g = Function(name: "t", params: [.i32], returns: .void)
    let gb = g.addBlock()
    _ = g.append(Inst(.fadd, .i32, [g.param(0), g.param(0)]), to: gb)
    g.append(Inst(.ret, .void, []), to: gb)
    #expect(message(g).contains("needs float operands"), "\(message(g))")

    var h = Function(name: "t", params: [.i32], returns: .i32)
    let hb = h.addBlock()
    h.append(Inst(.ret, .void, []), to: hb)
    #expect(message(h).contains("returned value has the wrong type"), "\(message(h))")
  }

  @Test func phisNeedAnEntryForEveryPredecessor() {
    var f = Function(name: "t", params: [.bool, .i32], returns: .void)
    let b0 = f.addBlock()
    let b1 = f.addBlock()
    let b2 = f.addBlock()
    f.append(Inst(.condbr, .void, [f.param(0)], blocks: [b1, b2]), to: b0)
    f.append(Inst(.br, .void, [], blocks: [b2]), to: b1)
    _ = f.append(Inst(.phi, .i32, [f.param(1)], blocks: [b0]), to: b2)
    f.append(Inst(.ret, .void, []), to: b2)
    #expect(message(f).contains("predecessor bb1 has no incoming value"), "\(message(f))")
  }

  @Test func memoryRules() {
    var f = Function(name: "t", params: [.i32], returns: .void)
    let b = f.addBlock()
    let u = f.resource(set: 0, binding: 0, space: .uniform)
    f.append(Inst(.store, .void, [u, f.param(0)], imm: 4), to: b)
    f.append(Inst(.ret, .void, []), to: b)
    #expect(message(f).contains("store to read-only memory"), "\(message(f))")

    var g = Function(name: "t", params: [.i32], returns: .void)
    let gb = g.addBlock()
    let w = g.resource(set: 0, binding: 0, space: .storage)
    _ = g.append(Inst(.ptradd, .ptr(.storage), [w, g.constant(.i64, 4)]), to: gb)
    g.append(Inst(.ret, .void, []), to: gb)
    #expect(message(g).contains("byte offset of its space's offset type"), "\(message(g))")
  }

  @Test func structuredControlFlow() {
    // A selection header must end in a conditional.
    var f = Function(name: "t", params: [.bool], returns: .void)
    let b0 = f.addBlock()
    let b1 = f.addBlock()
    f.append(Inst(.br, .void, [], blocks: [b1]), to: b0)
    f.blocks[b0].kind = .selection
    f.blocks[b0].merge = b1
    f.append(Inst(.ret, .void, []), to: b1)
    #expect(message(f).contains("selection header must end in a conditional"), "\(message(f))")

    // A loop whose continue block never branches back.
    var g = Function(name: "t", params: [.bool], returns: .void)
    let g0 = g.addBlock()
    let g1 = g.addBlock()
    let g2 = g.addBlock()
    let g3 = g.addBlock()
    g.append(Inst(.br, .void, [], blocks: [g1]), to: g0)
    g.append(Inst(.condbr, .void, [g.param(0)], blocks: [g2, g3]), to: g1)
    g.blocks[g1].kind = .loop
    g.blocks[g1].merge = g3
    g.blocks[g1].continueTarget = g2
    g.append(Inst(.ret, .void, []), to: g2)
    g.append(Inst(.ret, .void, []), to: g3)
    #expect(message(g).contains("no back edge"), "\(message(g))")

    // Two headers with one merge block.
    var h = Function(name: "t", params: [.bool], returns: .void)
    let h0 = h.addBlock()
    let h1 = h.addBlock()
    let h2 = h.addBlock()
    let h3 = h.addBlock()
    h.append(Inst(.condbr, .void, [h.param(0)], blocks: [h1, h2]), to: h0)
    h.append(Inst(.condbr, .void, [h.param(0)], blocks: [h3, h3]), to: h1)
    h.append(Inst(.condbr, .void, [h.param(0)], blocks: [h3, h3]), to: h2)
    h.append(Inst(.ret, .void, []), to: h3)
    h.blocks[h0].kind = .selection
    h.blocks[h0].merge = h3
    h.blocks[h1].kind = .selection
    h.blocks[h1].merge = h3
    #expect(message(h).contains("merge block of two headers"), "\(message(h))")
  }

  @Test func scalarModeRefusesVectors() throws {
    let ir = try lowered(Corpus.vec)
    do {
      try ir.verify(scalar: true)
      Issue.record("accepted vectors")
    } catch {
      #expect(error.message.contains("vector"))
    }
  }

  @Test func theBlockEndsInATerminator() {
    var f = Function(name: "t", params: [.i32], returns: .void)
    let b = f.addBlock()
    _ = f.append(Inst(.iadd, .i32, [f.param(0), f.param(0)]), to: b)
    #expect(message(f).contains("does not end in a terminator"), "\(message(f))")
  }
}
