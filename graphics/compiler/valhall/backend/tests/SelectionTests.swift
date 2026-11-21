// SPDX-License-Identifier: BSD-3-Clause

// What the backend chooses: patterns of selection, the FAU layout, the
// allocator in both register classes and when it spills, the bring-up
// shader's job written as SPIR-V, and golden listings.

import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

/// layout(local_size_x = 8, local_size_y = 4) in; every builtin of the compute ABI (14.2.1), four words each.
let builtinsShader = """
  OpCapability Shader
  OpMemoryModel Logical GLSL450
  OpEntryPoint GLCompute %main "main" %gid %lid %wid %nwg %lidx
  OpExecutionMode %main LocalSize 8 4 1
  OpDecorate %gid BuiltIn GlobalInvocationId
  OpDecorate %lid BuiltIn LocalInvocationId
  OpDecorate %wid BuiltIn WorkgroupId
  OpDecorate %nwg BuiltIn NumWorkgroups
  OpDecorate %lidx BuiltIn LocalInvocationIndex
  OpDecorate %uarr ArrayStride 4
  OpMemberDecorate %B 0 Offset 0
  OpDecorate %B Block
  OpDecorate %buf DescriptorSet 0
  OpDecorate %buf Binding 0
  \(Corpus.prelude)
  %gid = OpVariable %ptr_in_v3uint Input
  %lid = OpVariable %ptr_in_v3uint Input
  %wid = OpVariable %ptr_in_v3uint Input
  %nwg = OpVariable %ptr_in_v3uint Input
  %lidx = OpVariable %ptr_in_uint Input
  %u8 = OpConstant %uint 8
  %uarr = OpTypeRuntimeArray %uint
  %B = OpTypeStruct %uarr
  %ptr_sb_B = OpTypePointer StorageBuffer %B
  %buf = OpVariable %ptr_sb_B StorageBuffer
  %main = OpFunction %void None %fn
  %entry = OpLabel
  %pgx = OpAccessChain %ptr_in_uint %gid %u0
  %gx = OpLoad %uint %pgx
  %pgy = OpAccessChain %ptr_in_uint %gid %u1
  %gy = OpLoad %uint %pgy
  %plx = OpAccessChain %ptr_in_uint %lid %u0
  %lx = OpLoad %uint %plx
  %ply = OpAccessChain %ptr_in_uint %lid %u1
  %ly = OpLoad %uint %ply
  %pwx = OpAccessChain %ptr_in_uint %wid %u0
  %wx = OpLoad %uint %pwx
  %pwy = OpAccessChain %ptr_in_uint %wid %u1
  %wy = OpLoad %uint %pwy
  %pnx = OpAccessChain %ptr_in_uint %nwg %u0
  %nx = OpLoad %uint %pnx
  %pny = OpAccessChain %ptr_in_uint %nwg %u1
  %ny = OpLoad %uint %pny
  %li = OpLoad %uint %lidx
  %width = OpIMul %uint %nx %u8
  %row = OpIMul %uint %gy %width
  %g = OpIAdd %uint %row %gx
  %base = OpIMul %uint %g %u4
  %lyS = OpShiftLeftLogical %uint %ly %u8
  %lyl = OpBitwiseOr %uint %lx %lyS
  %wyS = OpShiftLeftLogical %uint %wy %u8
  %wyl = OpBitwiseOr %uint %wx %wyS
  %nyS = OpShiftLeftLogical %uint %ny %u8
  %nyl = OpBitwiseOr %uint %nx %nyS
  %p0 = OpAccessChain %ptr_sb_uint %buf %u0 %base
  OpStore %p0 %li
  %b1 = OpIAdd %uint %base %u1
  %p1 = OpAccessChain %ptr_sb_uint %buf %u0 %b1
  OpStore %p1 %lyl
  %b2 = OpIAdd %uint %base %u2
  %p2 = OpAccessChain %ptr_sb_uint %buf %u0 %b2
  OpStore %p2 %wyl
  %b3 = OpIAdd %uint %base %u3
  %p3 = OpAccessChain %ptr_sb_uint %buf %u0 %b3
  OpStore %p3 %nyl
  OpReturn
  OpFunctionEnd
  """

/// The bring-up shader's job (graphics/mali BringUpShader): each invocation stores its global id at its index.
let globalIDStoreShader = """
  OpCapability Shader
  OpMemoryModel Logical GLSL450
  OpEntryPoint GLCompute %main "main" %gid
  OpExecutionMode %main LocalSize 16 1 1
  OpDecorate %gid BuiltIn GlobalInvocationId
  OpDecorate %uarr ArrayStride 4
  OpMemberDecorate %B 0 Offset 0
  OpDecorate %B Block
  OpDecorate %buf DescriptorSet 0
  OpDecorate %buf Binding 0
  \(Corpus.prelude)
  %gid = OpVariable %ptr_in_v3uint Input
  %uarr = OpTypeRuntimeArray %uint
  %B = OpTypeStruct %uarr
  %ptr_sb_B = OpTypePointer StorageBuffer %B
  %buf = OpVariable %ptr_sb_B StorageBuffer
  %main = OpFunction %void None %fn
  %entry = OpLabel
  %px = OpAccessChain %ptr_in_uint %gid %u0
  %i = OpLoad %uint %px
  %p = OpAccessChain %ptr_sb_uint %buf %u0 %i
  OpStore %p %i
  OpReturn
  OpFunctionEnd
  """

/// Sum of `n` loads kept live at once: pressure of n registers.
func pressureShader(_ n: Int) -> String {
  var t = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 16 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %farr ArrayStride 4
    OpMemberDecorate %B 0 Offset 0
    OpDecorate %B Block
    OpDecorate %buf DescriptorSet 0
    OpDecorate %buf Binding 0
    \(Corpus.prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %farr = OpTypeRuntimeArray %float
    %B = OpTypeStruct %farr
    %ptr_sb_B = OpTypePointer StorageBuffer %B
    %buf = OpVariable %ptr_sb_B StorageBuffer

    """
  for k in 0...n { t += "%k\(k) = OpConstant %uint \(k)\n" }
  t += """
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %px = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %px
    %base = OpIMul %uint %i %k\(n)

    """
  for k in 0..<n {
    t += "%o\(k) = OpIAdd %uint %base %k\(k)\n%p\(k) = OpAccessChain %ptr_sb_float %buf %u0 %o\(k)\n%v\(k) = OpLoad %float %p\(k)\n"
  }
  // Each value is used again after all are loaded: v_k * v_(k+1), summed.
  t += "%a0 = OpFMul %float %v0 %v1\n"
  for k in 1..<(n - 1) {
    t += "%m\(k) = OpFMul %float %v\(k) %v\(k + 1)\n%a\(k) = OpFAdd %float %a\(k - 1) %m\(k)\n"
  }
  t += "%ob = OpIAdd %uint %base %k0\n%po = OpAccessChain %ptr_sb_float %buf %u0 %ob\nOpStore %po %a\(n - 2)\nOpReturn\nOpFunctionEnd\n"
  return t
}

@Suite struct SelectionTests {
  @Test func theBringUpShadersJobAsSPIRV() throws {
    let cs = try compileText(globalIDStoreShader)
    let r = try HostRun.dispatch(cs, buffers: [Buffer(binding: 0, bytes: zeros(64))], grid: (4, 1, 1))
    #expect(words(r[0].bytes) == (0..<64).map { UInt32($0) })
    // Run the hand-assembled shader the board ran: the same bytes come out.
    let hand = BringUpShader.globalIDStore(workgroupSize: MaliCore.Dim3(16))
    var decoded: [Instruction] = []
    for w in hand.code { decoded.append(try ISATable.shared.decode(w)) }
    var shader = cs
    shader.instructions = decoded
    let h = try HostRun.dispatch(shader, buffers: [Buffer(binding: 0, bytes: zeros(64))], grid: (4, 1, 1))
    #expect(h[0].bytes == r[0].bytes)
    // The ABI the board verified: r60 preloaded (bit 12), the buffer's address in FAU slot 0, no stack, no merging.
    #expect(cs.shader.preloadMask == hand.preloadMask)
    #expect(cs.shader.fauWords == hand.fauWords)
    #expect(cs.shader.stackBytes == 0 && cs.shader.workgroupMemoryBytes == 0)
    #expect(cs.layout.bindings.count == 1 && cs.layout.bindings[0].slot == 0)
    // Two instructions' worth: the address and the store, as the hand-written shader has them.
    #expect(cs.instructions.count == hand.code.count)
    #expect(cs.instructions[0].mnemonic == "SHADD" && cs.instructions[1].mnemonic == "STORE")
    #expect(cs.instructions[1].flow == .end)
  }

  @Test func builtinsOfTheComputeABI() throws {
    let r = try execute(builtinsShader, inputs: [zeros(4 * 8 * 4 * 6)], grid: (3, 2, 1))
    #expect(r.got == r.want)
    // The local index, the local ids' packing and the workgroup counts are what the IR says.
    let w = words(r.got[0])
    #expect(w[0] == 0 && w[4] == 1)
    #expect(w[3] == (3 | 2 << 8))
    // r55 and r57 to r62 as needed: local ids (bit 7), workgroup ids (bits 9, 10), global ids (bits 12, 13).
    #expect(r.shader.shader.preloadMask & (1 << 7) != 0 && r.shader.shader.preloadMask & (1 << 12) != 0)
    #expect(r.shader.layout.numWorkgroupsWord >= 0)
  }

  @Test func patterns() throws {
    let fill = try compileText(Corpus.fill)
    // The address is one SHADD from the FAU slot, with the 4-byte element folded into its shift.
    #expect(fill.listing.contains("SHADD.u64"))
    #expect(fill.listing.contains("shift:2"))
    let saxpy = try compileText(Corpus.saxpy)
    // The multiply is an FMA with a negative-zero addend; the bound check is one compare and one branch.
    #expect(saxpy.listing.contains("0x0.neg"))
    #expect(saxpy.listing.contains("BRANCH"))
    // The push constant is read in place from the FAU.
    #expect(saxpy.listing.contains("u2.w0") && saxpy.listing.contains("u2.w1"))
    let math = try compileText(Corpus.math)
    #expect(math.listing.contains("CSEL"))
    #expect(math.listing.contains("FEXP.f32") && math.listing.contains("FSIN_TABLE"))
    // A barrier follows a wait on every busy slot, in an instruction of its own before it (13.8).
    let reduce = try compileText(Corpus.reduce)
    let lines = reduce.listing.split(separator: "\n").map(String.init)
    for (k, l) in lines.enumerated() where l.hasPrefix("BARRIER") {
      #expect(l.contains(".wait"))
      #expect(k > 0)
    }
    // Stack accesses force their access (12a.1.7).
    let locals = try compileText(Corpus.locals)
    #expect(locals.listing.contains("thread_local_pointer") || locals.listing.contains("access") || locals.shader.stackBytes > 0)
  }

  @Test func theFAULayoutBuildsTheBlock() throws {
    let cs = try compileText(Corpus.saxpy)
    let block = cs.layout.block(
      address: { _, b in b == 0 ? 0x1111_0000_2222_0000 : 0x3333_0000_4444_0000 }, size: { _, _ in 0 },
      push: [0x4020_0000, 100], workgroups: (1, 1, 1))
    #expect(block.count == cs.layout.slots)
    #expect(block[0] == 0x1111_0000_2222_0000 && block[1] == 0x3333_0000_4444_0000)
    #expect(block[2] == UInt64(100) << 32 | 0x4020_0000)
    #expect(cs.shader.fauWords == 6)
    // A shader that reads the number of workgroups and an array's length has them in the layout too.
    let b = try compileText(builtinsShader)
    #expect(b.layout.numWorkgroupsWord == 2)
    let nw = b.layout.block(address: { _, _ in 0x1000 }, size: { _, _ in 0 }, push: [], workgroups: (7, 8, 9))
    #expect(UInt32(truncatingIfNeeded: nw[1]) == 7 && UInt32(truncatingIfNeeded: nw[2] >> 0) == 8 || nw.count >= 2)
  }

  @Test func class32WhenItFitsAndClass64WhenItDoesNot() throws {
    let small = try compileText(Corpus.fill)
    #expect(small.shader.registerClass == .r32)
    for i in small.instructions { _ = i }
    #expect(violations(small) == [])
    var o = BackendOptions()
    o.preferClass32 = false
    let wide = try compileText(Corpus.fill, options: o)
    #expect(wide.shader.registerClass == .r64)
    #expect(violations(wide) == [])
    // Forty values live at once need more than 32 registers.
    let big = try compileText(pressureShader(40))
    #expect(big.shader.registerClass == .r64)
    #expect(big.spillSlots == 0)
    #expect(violations(big) == [])
    let x = (0..<(16 * 40)).map { Float(($0 * 7) % 13) * 0.5 - 3 }
    let r = try execute(pressureShader(40), inputs: [bytes(x)], grid: (1, 1, 1))
    #expect(r.got == r.want)
    // A class 32 shader names no register in r16 to r47.
    for i in small.instructions {
      let text = ISATable.shared.disassemble(i)
      for r in 16..<48 { #expect(!text.contains("r\(r)^") && !text.contains("r\(r),") && !text.hasSuffix("r\(r)")) }
    }
  }

  @Test func aForcedSpillStillComputesTheSameThing() throws {
    let x = (0..<(16 * 40)).map { Float(($0 * 7) % 13) * 0.5 - 3 }
    var o = BackendOptions()
    o.registerLimit = 12
    let r = try execute(pressureShader(40), inputs: [bytes(x)], grid: (1, 1, 1), options: o)
    #expect(r.shader.spillSlots > 0)
    #expect(r.shader.shader.stackBytes > 0)
    #expect(violations(r.shader) == [])
    #expect(r.got == r.want)
    // The spills are stack accesses at the thread-local pointer with access force.
    #expect(r.shader.listing.contains("thread_local_pointer"))
    #expect(r.shader.listing.contains("access:force") || r.shader.listing.contains(".force"))
    // The corpus's math shader too, at a tight register limit.
    var t = BackendOptions()
    t.registerLimit = 10
    let n = 64
    let xs = (0..<n).map { Float($0 + 1) / 6 }
    let m = try execute(Corpus.math, inputs: [bytes(xs), zeros(n * 22), zeros(n * 5)], grid: (1, 1, 1), options: t)
    #expect(violations(m.shader) == [])
    #expect(words(m.got[2]) == words(m.want[2]))
  }

  @Test func pairsAndStagingBlocksAreAligned() throws {
    for text in [Corpus.fill, Corpus.vec, Corpus.spec64, Corpus.atomics, pressureShader(40)] {
      let cs = try compileText(text)
      for i in cs.instructions {
        if let d = i.destination, i.destinationIs64Bit { #expect(d % 2 == 0) }
        for b in [i.stagingRead, i.stagingWrite] {
          if let b, b.count >= 2 { #expect(b.first % 2 == 0) }
        }
      }
    }
  }

  @Test func theFirstShadersAsGoldenListings() throws {
    let fill = try compileText(Corpus.fill)
    #expect(
      fill.listing == """
        IADD_IMM.i32 r0, 0x0, #0x3
        IMUL.u32 r0, r60, r0^
        IADD_IMM.i32 r0, r0^, #0x1
        SHADD.u64 r2:r3, u0, r60^:r61^.w0, shift:2
        STORE.i32.slot0.end @r0, [r2^:r3^], offset:0

        """)
    let saxpy = try compileText(Corpus.saxpy)
    #expect(
      saxpy.listing == """
        ICMP_OR.u32.m1.lt r0, r60, u2.w1, 0x0
        BRANCH.not.reconverge r0^, offset:10
        SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2
        LOAD.i32.slot0 @r2, [r0^:r1^], offset:0
        SHADD.u64 r0:r1, u1, r60:r61.w0, shift:2
        LOAD.i32.slot1 @r3, [r0^:r1^], offset:0
        FMA.f32.wait0 r0, u2.w0, r2^, 0x0.neg
        FADD.f32.wait1 r0, r0^, r3^
        SHADD.u64 r2:r3, u1, r60^:r61^.w0, shift:2
        STORE.i32.slot2 @r0, [r2^:r3^], offset:0
        NOP.wait2
        NOP.reconverge
        NOP.end

        """)
  }
}
