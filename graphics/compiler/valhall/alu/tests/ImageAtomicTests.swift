// SPDX-License-Identifier: BSD-3-Clause

// Atomics on storage images chosen by a per-lane index (valhall 12b.2.1, 12b.11): the address and the atomics on it are done in the
// loop over the distinct handles, so a warp whose lanes name different images of an array works.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

@Suite struct ImageAtomicTests {
  @Test func anAtomicOnAnImageChosenPerLane() throws {
    let text = """
      OpCapability Shader
      OpCapability StorageImageArrayDynamicIndexing
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 32 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %img DescriptorSet 0
      OpDecorate %img Binding 0
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %v2int = OpTypeVector %int 2
      %i0 = OpConstant %int 0
      %imgT = OpTypeImage %uint 1 0 0 0 2 33
      %imgArr = OpTypeArray %imgT %u2
      %ptr_img = OpTypePointer UniformConstant %imgT
      %ptr_arr = OpTypePointer UniformConstant %imgArr
      %img = OpVariable %ptr_arr UniformConstant
      %ptr_texel = OpTypePointer Image %uint
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %g = OpLoad %v3uint %gid
      %gx = OpCompositeExtract %uint %g 0
      %which = OpBitwiseAnd %uint %gx %u1
      %k = OpBitwiseAnd %uint %gx %u3
      %xi = OpBitcast %int %k
      %coord = OpCompositeConstruct %v2int %xi %i0
      %ip = OpAccessChain %ptr_img %img %which
      %p = OpImageTexelPointer %ptr_texel %ip %coord %u0
      %old = OpAtomicIAdd %uint %p %u1 %u0 %gx
      %back = OpBitwiseOr %uint %old %u0
      OpReturn
      OpFunctionEnd
      """
    let cs = try compileText(text)
    #expect(violations(cs) == [])
    #expect(cs.instructions.contains { $0.mnemonic == "WMASK" || $0.mnemonic == "CLPER" }, "the handle loop")
    let zeros = [UInt8](repeating: 0, count: 16)
    let images = [
      HostImage(
        binding: 0,
        elements: [
          .init(bytes: zeros, width: 4, format: .r32Uint),
          .init(bytes: zeros, width: 4, format: .r32Uint),
        ])
    ]
    let out = try HostRun.dispatch(cs, buffers: [], images: images, grid: (1, 1, 1))
    // Invocation x adds x to texel x & 3 of image x & 1.
    var want = [[UInt32]](repeating: [0, 0, 0, 0], count: 2)
    for x in 0..<32 { want[x & 1][x & 3] &+= UInt32(x) }
    for e in 0..<2 { #expect(unpack(out.images[0].elements[e].bytes) == want[e], "image \(e)") }
  }
}
