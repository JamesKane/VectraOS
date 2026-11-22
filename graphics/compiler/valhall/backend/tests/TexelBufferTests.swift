// SPDX-License-Identifier: BSD-3-Clause

// Texel buffers (valhall 03 3.4.1, 3.5, 12a.5.2, 12a.7, 12b.14): a compute shader fetches from uniform texel buffers (an array of
// two, an r32f and an rgba8 unorm one), reads and writes storage texel buffers (r32ui, with an atomic add, and rgba8), and asks the
// size of each, compiled for Valhall and run on the interpreter over its Buffer descriptor model (valhall/interp/lib/TexelBufferOps.swift).
// The expected values are computed here from the formats' definitions, apart from the interpreter's conversion.

import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallInterp

private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) } }
private func get32(_ b: [UInt8], _ at: Int) -> UInt32 {
  (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[at + $1]) << UInt32(8 * $1) }
}

/// The conversion words of 12b.12: the 22-bit pixel formats of 05 5.3.1 (index and order) of the three formats.
private let r32f = PixelWord.make(index: 167, order: 16)
private let rgba8 = PixelWord.make(index: 187, order: 0)
private let bgra8 = PixelWord.make(index: 187, order: 4)
private let r32ui = PixelWord.make(index: 133, order: 16)

private let invocations = 16

/// Each of the 16 invocations i: fetches element i of sources[0] (r32f) and of sources[1] (rgba8), as four floats each, into the
/// output; reads element i of the r32ui storage buffer, writes three times it plus i back and adds one atomically; writes an
/// rgba8 texel to the second storage buffer; and writes the three sizes. The output's layout: 4 words an invocation for each fetch
/// (0 to 63, 64 to 127), then the sizes (128 to 130).
private func shaderText(extra: String = "") -> String {
  """
  OpCapability Shader
  OpCapability SampledBuffer
  OpCapability ImageBuffer
  OpCapability ImageQuery
  OpCapability ShaderNonUniform
  OpCapability StorageImageExtendedFormats
  OpMemoryModel Logical GLSL450
  OpEntryPoint GLCompute %main "main" %gid
  OpExecutionMode %main LocalSize 16 1 1
  OpDecorate %gid BuiltIn GlobalInvocationId
  OpDecorate %arr ArrayStride 4
  OpMemberDecorate %O 0 Offset 0
  OpDecorate %O Block
  OpDecorate %ov DescriptorSet 0
  OpDecorate %ov Binding 1
  OpDecorate %sources DescriptorSet 0
  OpDecorate %sources Binding 3
  OpDecorate %targets DescriptorSet 0
  OpDecorate %targets Binding 4
  OpDecorate %colours DescriptorSet 0
  OpDecorate %colours Binding 5
  \(Corpus.prelude)
  %gid = OpVariable %ptr_in_v3uint Input
  %int0 = OpConstant %int 0
  %u5 = OpConstant %uint 5
  %u6 = OpConstant %uint 6
  %u7 = OpConstant %uint 7
  %u128 = OpConstant %uint 128
  %sixteenth = OpConstant %float 0.0625f
  %quarter = OpConstant %float 0.25f
  %u64c = OpConstant %uint 64
  %v4uint = OpTypeVector %uint 4
  %sampledBuf = OpTypeImage %float 5 0 0 0 1 0
  %storageBuf = OpTypeImage %uint 5 0 0 0 2 33
  %colourBuf = OpTypeImage %float 5 0 0 0 2 4
  %sourcesT = OpTypeArray %sampledBuf %u2
  %targetsT = OpTypeArray %storageBuf %u1
  %coloursT = OpTypeArray %colourBuf %u1
  %ptr_sources = OpTypePointer UniformConstant %sourcesT
  %ptr_targets = OpTypePointer UniformConstant %targetsT
  %ptr_colours = OpTypePointer UniformConstant %coloursT
  %ptr_sampled = OpTypePointer UniformConstant %sampledBuf
  %ptr_storage = OpTypePointer UniformConstant %storageBuf
  %ptr_colour = OpTypePointer UniformConstant %colourBuf
  %ptr_texel = OpTypePointer Image %uint
  %sources = OpVariable %ptr_sources UniformConstant
  %targets = OpVariable %ptr_targets UniformConstant
  %colours = OpVariable %ptr_colours UniformConstant
  %arr = OpTypeRuntimeArray %uint
  %O = OpTypeStruct %arr
  %ptr_O = OpTypePointer StorageBuffer %O
  %ov = OpVariable %ptr_O StorageBuffer
  %main = OpFunction %void None %fn
  %entry = OpLabel
  %g = OpLoad %v3uint %gid
  %i = OpCompositeExtract %uint %g 0
  %ii = OpBitcast %int %i
  %four_i = OpIMul %uint %i %u4
  %s0p = OpAccessChain %ptr_sampled %sources %u0
  %s1p = OpAccessChain %ptr_sampled %sources %u1
  %s0 = OpLoad %sampledBuf %s0p
  %s1 = OpLoad %sampledBuf %s1p
  %f = OpImageFetch %v4float %s0 %ii
  %c = OpImageFetch %v4float %s1 %ii
  %f0v = OpCompositeExtract %float %f 0
  %f1v = OpCompositeExtract %float %f 1
  %f2v = OpCompositeExtract %float %f 2
  %f3v = OpCompositeExtract %float %f 3
  %c0v = OpCompositeExtract %float %c 0
  %c1v = OpCompositeExtract %float %c 1
  %c2v = OpCompositeExtract %float %c 2
  %c3v = OpCompositeExtract %float %c 3
  %f0b = OpBitcast %uint %f0v
  %f1b = OpBitcast %uint %f1v
  %f2b = OpBitcast %uint %f2v
  %f3b = OpBitcast %uint %f3v
  %c0b = OpBitcast %uint %c0v
  %c1b = OpBitcast %uint %c1v
  %c2b = OpBitcast %uint %c2v
  %c3b = OpBitcast %uint %c3v
  %o0 = OpIAdd %uint %four_i %u0
  %o1 = OpIAdd %uint %four_i %u1
  %o2 = OpIAdd %uint %four_i %u2
  %o3 = OpIAdd %uint %four_i %u3
  %p0 = OpAccessChain %ptr_sb_uint %ov %u0 %o0
  %p1 = OpAccessChain %ptr_sb_uint %ov %u0 %o1
  %p2 = OpAccessChain %ptr_sb_uint %ov %u0 %o2
  %p3 = OpAccessChain %ptr_sb_uint %ov %u0 %o3
  OpStore %p0 %f0b
  OpStore %p1 %f1b
  OpStore %p2 %f2b
  OpStore %p3 %f3b
  %q0i = OpIAdd %uint %o0 %u64c
  %q1i = OpIAdd %uint %o1 %u64c
  %q2i = OpIAdd %uint %o2 %u64c
  %q3i = OpIAdd %uint %o3 %u64c
  %q0 = OpAccessChain %ptr_sb_uint %ov %u0 %q0i
  %q1 = OpAccessChain %ptr_sb_uint %ov %u0 %q1i
  %q2 = OpAccessChain %ptr_sb_uint %ov %u0 %q2i
  %q3 = OpAccessChain %ptr_sb_uint %ov %u0 %q3i
  OpStore %q0 %c0b
  OpStore %q1 %c1b
  OpStore %q2 %c2b
  OpStore %q3 %c3b
  %tp = OpAccessChain %ptr_storage %targets %u0
  %t = OpLoad %storageBuf %tp
  %old = OpImageRead %v4uint %t %ii
  %oldx = OpCompositeExtract %uint %old 0
  %triple = OpIMul %uint %oldx %u3
  %nw = OpIAdd %uint %triple %i
  %nv = OpCompositeConstruct %v4uint %nw %nw %nw %nw
  OpImageWrite %t %ii %nv
  %tex = OpImageTexelPointer %ptr_texel %tp %ii %u0
  %was = OpAtomicIAdd %uint %tex %u1 %u0 %u1
  %cp = OpAccessChain %ptr_colour %colours %u0
  %cim = OpLoad %colourBuf %cp
  %fi = OpConvertUToF %float %i
  %fr = OpFMul %float %fi %sixteenth
  %green = OpFAdd %float %fr %quarter
  %rgba = OpCompositeConstruct %v4float %f0 %green %f1 %f1
  OpImageWrite %cim %ii %rgba
  %sizeF = OpImageQuerySize %int %s0
  %sizeC = OpImageQuerySize %int %s1
  %sizeT = OpImageQuerySize %int %t
  %sizeFu = OpBitcast %uint %sizeF
  %sizeCu = OpBitcast %uint %sizeC
  %sizeTu = OpBitcast %uint %sizeT
  %z0 = OpIAdd %uint %u128 %u0
  %z1 = OpIAdd %uint %u128 %u1
  %z2 = OpIAdd %uint %u128 %u2
  %r0 = OpAccessChain %ptr_sb_uint %ov %u0 %z0
  %r1 = OpAccessChain %ptr_sb_uint %ov %u0 %z1
  %r2 = OpAccessChain %ptr_sb_uint %ov %u0 %z2
  OpStore %r0 %sizeFu
  OpStore %r1 %sizeCu
  OpStore %r2 %sizeTu
  \(extra)
  OpReturn
  OpFunctionEnd
  """
}

private struct Texels {
  var floats: [Float]
  var colours: [UInt8]
  var counters: [UInt32]
  var fBytes: [UInt8] { floats.flatMap { le32($0.bitPattern) } }
  var cBytes: [UInt8] { colours }
  var uBytes: [UInt8] { counters.flatMap { le32($0) } }
}

private func texels(count: Int) -> Texels {
  Texels(
    floats: (0..<count).map { Float($0) * 0.5 + 0.25 },
    colours: (0..<count * 4).map { UInt8(truncatingIfNeeded: ($0 / 4) * 16 + ($0 % 4) * 40 + 3) },
    counters: (0..<count).map { UInt32($0 * 11 + 2) })
}

private struct Result {
  var out: [UInt32]
  var targets: [UInt8]
  var colours: [UInt8]
  var sources: [[UInt8]]
}

private func run(
  _ text: String, _ t: Texels, fConversion: UInt32 = r32f, cConversion: UInt32 = rgba8, extraBytes: Int = 0
) throws -> Result {
  let cs = try ValhallBackend.compile(try lowered(text))
  #expect(violations(cs) == [], "\(cs.listing)")
  let count = t.floats.count
  let sources = HostTexelBuffer(
    binding: 3,
    elements: [
      .init(bytes: t.fBytes, stride: 4, conversion: fConversion),
      .init(bytes: t.cBytes, stride: 4, conversion: cConversion),
    ])
  let targets = HostTexelBuffer(binding: 4, .init(bytes: t.uBytes, stride: 4, conversion: r32ui))
  let colours = HostTexelBuffer(
    binding: 5, .init(bytes: [UInt8](repeating: 0xAB, count: 4 * count + extraBytes), stride: 4, conversion: rgba8))
  let out = try HostRun.dispatch(
    cs, buffers: [Buffer(binding: 1, bytes: [UInt8](repeating: 0xFF, count: 4 * 192))], images: [], grid: (1, 1, 1),
    texelBuffers: [sources, targets, colours])
  let words = (0..<192).map { get32(out.buffers[0].bytes, 4 * $0) }
  return Result(
    out: words, targets: out.texelBuffers[1].elements[0].bytes, colours: out.texelBuffers[2].elements[0].bytes,
    sources: out.texelBuffers[0].elements.map { $0.bytes })
}

@Suite struct TexelBufferTests {
  /// The fetches, stores, atomics and sizes of one shader, exact.
  @Test func fetchesStoresAtomicsAndSizes() throws {
    let t = texels(count: invocations)
    let r = try run(shaderText(), t)
    for i in 0..<invocations {
      // An r32f texel fetched as four channels reads (R, 0, 0, 1) (12b.14.1: LD_CVT fills the channels from the order).
      let f = [t.floats[i].bitPattern, 0, 0, Float(1).bitPattern]
      #expect(Array(r.out[(4 * i)..<(4 * i + 4)]) == f, "r32f \(i)")
      // An rgba8 texel: each byte over 255.
      let c = (0..<4).map { (Float(t.colours[4 * i + $0]) / 255).bitPattern }
      #expect(Array(r.out[(64 + 4 * i)..<(64 + 4 * i + 4)]) == c, "rgba8 \(i)")
      // The r32ui buffer: three times the old texel plus the index, plus one.
      #expect(get32(r.targets, 4 * i) == t.counters[i] &* 3 &+ UInt32(i) &+ 1, "r32ui \(i)")
      // The rgba8 store: (0, i / 16 + 1 / 4, 1, 1) as unorm bytes (the green past 1 clamps to 255).
      let green = UInt8(min(255, (Float(i) * 0.0625 + 0.25) * 255).rounded(.toNearestOrEven))
      #expect(Array(r.colours[(4 * i)..<(4 * i + 4)]) == [0, green, 255, 255], "rgba8 store \(i)")
    }
    // The sizes: the elements of each buffer.
    #expect(Array(r.out[128..<131]) == [UInt32(invocations), UInt32(invocations), UInt32(invocations)])
    // The sources are unwritten.
    #expect(r.sources[0] == t.fBytes && r.sources[1] == t.cBytes)
  }

  /// The listing is the sequences of 12b.14.1: LEA_BUF, the conversion word through LD_PKA, LD_CVT or ST_CVT, and an atomic on
  /// the LEA_BUF address.
  @Test func theSequencesAreThoseOfThe12b141() throws {
    let cs = try ValhallBackend.compile(try lowered(shaderText()))
    let lines = cs.listing.split(whereSeparator: { $0.isNewline }).map(String.init)
    func count(_ prefix: String) -> Int { lines.filter { $0.hasPrefix(prefix) }.count }
    #expect(count("LEA_BUF") >= 5, "\(cs.listing)")
    #expect(count("LD_CVT") >= 2 && count("ST_CVT") >= 2, "\(cs.listing)")
    #expect(count("LD_PKA") >= 5, "\(cs.listing)")
    #expect(lines.contains { $0.hasPrefix("ATOM") }, "\(cs.listing)")
    // The fetch asks for all four channels in the shader's register format; the store is auto32.
    #expect(lines.contains { $0.hasPrefix("LD_CVT") && $0.contains(".v4") && $0.contains(".f32") }, "\(cs.listing)")
    #expect(violations(cs) == [])
  }

  /// A view never written has the conversion word zero: the substitute format reads zeros, alpha included (12b.12).
  @Test func anUnwrittenViewReadsZeros() throws {
    let t = texels(count: invocations)
    let r = try run(shaderText(), t, fConversion: 0, cConversion: 0)
    for i in 0..<invocations {
      #expect(Array(r.out[(4 * i)..<(4 * i + 4)]) == [0, 0, 0, 0], "r32f \(i)")
      #expect(Array(r.out[(64 + 4 * i)..<(64 + 4 * i + 4)]) == [0, 0, 0, 0], "rgba8 \(i)")
    }
  }

  /// The component order is the descriptor's: bgra8 bytes (B, G, R, A) read as (R, G, B, A).
  @Test func theComponentOrderIsTheDescriptors() throws {
    let t = texels(count: invocations)
    let r = try run(shaderText(), t, cConversion: bgra8)
    for i in 0..<invocations {
      let b = (0..<4).map { t.colours[4 * i + $0] }
      let c = [b[2], b[1], b[0], b[3]].map { (Float($0) / 255).bitPattern }
      #expect(Array(r.out[(64 + 4 * i)..<(64 + 4 * i + 4)]) == c, "bgra8 \(i)")
    }
  }

  /// The size is the descriptor's size over its stride: a view of fewer bytes than its memory has fewer elements.
  @Test func theSizeIsTheViewsElements() throws {
    let cs = try ValhallBackend.compile(try lowered(shaderText()))
    let t = texels(count: invocations)
    let sources = HostTexelBuffer(
      binding: 3,
      elements: [
        .init(bytes: t.fBytes, stride: 4, conversion: r32f, size: 44),
        .init(bytes: t.cBytes, stride: 4, conversion: rgba8, size: 12),
      ])
    let targets = HostTexelBuffer(binding: 4, .init(bytes: t.uBytes, stride: 4, conversion: r32ui, size: 24))
    let colours = HostTexelBuffer(
      binding: 5, .init(bytes: [UInt8](repeating: 0xAB, count: 4 * invocations), stride: 4, conversion: rgba8))
    let out = try HostRun.dispatch(
      cs, buffers: [Buffer(binding: 1, bytes: [UInt8](repeating: 0xFF, count: 4 * 192))], images: [], grid: (1, 1, 1),
      texelBuffers: [sources, targets, colours])
    #expect((0..<3).map { get32(out.buffers[0].bytes, 4 * (128 + $0)) } == [11, 3, 6])
  }

  /// A fetch repeated after a store or an atomic to the same texel reads again.
  @Test func aFetchAfterAStoreReadsAgain() throws {
    let text = """
      OpCapability Shader
      OpCapability ImageBuffer
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 16 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %arr ArrayStride 4
      OpMemberDecorate %O 0 Offset 0
      OpDecorate %O Block
      OpDecorate %ov DescriptorSet 0
      OpDecorate %ov Binding 1
      OpDecorate %target DescriptorSet 0
      OpDecorate %target Binding 4
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %v4uint = OpTypeVector %uint 4
      %storageBuf = OpTypeImage %uint 5 0 0 0 2 33
      %ptr_storage = OpTypePointer UniformConstant %storageBuf
      %ptr_texel = OpTypePointer Image %uint
      %target = OpVariable %ptr_storage UniformConstant
      %arr = OpTypeRuntimeArray %uint
      %O = OpTypeStruct %arr
      %ptr_O = OpTypePointer StorageBuffer %O
      %ov = OpVariable %ptr_O StorageBuffer
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %g = OpLoad %v3uint %gid
      %i = OpCompositeExtract %uint %g 0
      %ii = OpBitcast %int %i
      %t = OpLoad %storageBuf %target
      %a = OpImageRead %v4uint %t %ii
      %ax = OpCompositeExtract %uint %a 0
      %seven = OpCompositeConstruct %v4uint %u1 %u1 %u1 %u1
      OpImageWrite %t %ii %seven
      %b = OpImageRead %v4uint %t %ii
      %bx = OpCompositeExtract %uint %b 0
      %tex = OpImageTexelPointer %ptr_texel %target %ii %u0
      %was = OpAtomicIAdd %uint %tex %u1 %u0 %u2
      %c = OpImageRead %v4uint %t %ii
      %cx = OpCompositeExtract %uint %c 0
      %o = OpIMul %uint %i %u3
      %o1 = OpIAdd %uint %o %u1
      %o2 = OpIAdd %uint %o %u2
      %p0 = OpAccessChain %ptr_sb_uint %ov %u0 %o
      %p1 = OpAccessChain %ptr_sb_uint %ov %u0 %o1
      %p2 = OpAccessChain %ptr_sb_uint %ov %u0 %o2
      OpStore %p0 %ax
      OpStore %p1 %bx
      OpStore %p2 %cx
      OpReturn
      OpFunctionEnd
      """
    let cs = try ValhallBackend.compile(try lowered(text))
    #expect(violations(cs) == [])
    let t = texels(count: invocations)
    let out = try HostRun.dispatch(
      cs, buffers: [Buffer(binding: 1, bytes: [UInt8](repeating: 0xFF, count: 4 * 64))], images: [], grid: (1, 1, 1),
      texelBuffers: [HostTexelBuffer(binding: 4, .init(bytes: t.uBytes, stride: 4, conversion: r32ui))])
    for i in 0..<invocations {
      let got = (0..<3).map { get32(out.buffers[0].bytes, 4 * (3 * i + $0)) }
      #expect(got == [t.counters[i], 1, 3], "texel \(i)")
    }
  }

  /// A store and an atomic past the buffer's end (12 elements of 16 invocations) do nothing, and the atomic gives 0 (12b.10.5): the bytes
  /// after the end, which the model has, are unchanged.
  @Test func aStoreAndAnAtomicPastTheEndDoNothing() throws {
    let text = """
      OpCapability Shader
      OpCapability ImageBuffer
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 16 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %arr ArrayStride 4
      OpMemberDecorate %O 0 Offset 0
      OpDecorate %O Block
      OpDecorate %ov DescriptorSet 0
      OpDecorate %ov Binding 1
      OpDecorate %target DescriptorSet 0
      OpDecorate %target Binding 4
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %v4uint = OpTypeVector %uint 4
      %storageBuf = OpTypeImage %uint 5 0 0 0 2 33
      %ptr_storage = OpTypePointer UniformConstant %storageBuf
      %ptr_texel = OpTypePointer Image %uint
      %target = OpVariable %ptr_storage UniformConstant
      %arr = OpTypeRuntimeArray %uint
      %O = OpTypeStruct %arr
      %ptr_O = OpTypePointer StorageBuffer %O
      %ov = OpVariable %ptr_O StorageBuffer
      %c500 = OpConstant %uint 500
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %g = OpLoad %v3uint %gid
      %i = OpCompositeExtract %uint %g 0
      %ii = OpBitcast %int %i
      %t = OpLoad %storageBuf %target
      %v = OpIAdd %uint %i %c500
      %vv = OpCompositeConstruct %v4uint %v %v %v %v
      OpImageWrite %t %ii %vv
      %tex = OpImageTexelPointer %ptr_texel %target %ii %u0
      %was = OpAtomicIAdd %uint %tex %u1 %u0 %u1
      %p = OpAccessChain %ptr_sb_uint %ov %u0 %i
      OpStore %p %was
      OpReturn
      OpFunctionEnd
      """
    let cs = try ValhallBackend.compile(try lowered(text))
    #expect(violations(cs) == [], "\(cs.listing)")
    let initial = [UInt8](repeating: 0xEE, count: 64)
    let result = try HostRun.dispatch(
      cs, buffers: [Buffer(binding: 1, bytes: [UInt8](repeating: 0xFF, count: 64))], images: [], grid: (1, 1, 1),
      texelBuffers: [HostTexelBuffer(binding: 4, .init(bytes: initial, stride: 4, conversion: r32ui, size: 48))])
    let bytes = result.texelBuffers[0].elements[0].bytes
    for i in 0..<16 {
      let texel = get32(bytes, 4 * i)
      let was = get32(result.buffers[0].bytes, 4 * i)
      if i < 12 {
        #expect(texel == UInt32(501 + i) && was == UInt32(500 + i), "texel \(i)")
      } else {
        #expect(texel == 0xEEEE_EEEE && was == 0, "texel \(i) is past the end")
      }
    }
  }
}
