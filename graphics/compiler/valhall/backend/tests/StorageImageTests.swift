// SPDX-License-Identifier: BSD-3-Clause

// Storage images (valhall 12b.10, 12b.11): compute shaders that read one storage image and write another, atomics on
// an image's texels, and an array of images chosen per lane, compiled for Valhall and run on the interpreter over its
// image model (valhall/interp/lib/ImageOps.swift). The expected texels are computed here from the format's definition,
// in Swift, apart from the interpreter's conversion.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallInterp

/// A storage image format: its SPIR-V number, the sampled type its shader uses, the interpreter's model of it, and how a
/// texel's bytes and its channels' 32-bit register values convert, written apart from the interpreter.
private struct Fmt: Sendable {
  var name: String
  var spirv: Int
  var type: String
  var model: StorageFormat
  var channels: Int
  var bytes: Int
  var decode: @Sendable ([UInt8]) -> [UInt32]
  var encode: @Sendable ([UInt32]) -> [UInt8]
}

private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) } }
private func get32(_ b: [UInt8], _ at: Int) -> UInt32 {
  (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[at + $1]) << UInt32(8 * $1) }
}
private func unormByte(_ v: UInt32) -> UInt8 {
  let x = Float(bitPattern: v) * 255
  return UInt8(max(0, min(255, x.rounded(.toNearestOrEven))))
}
private func half(_ h: UInt16) -> Float { Float(Float16(bitPattern: h)) }

private let formats: [String: Fmt] = [
  "rgba8": Fmt(
    name: "rgba8", spirv: 4, type: "float", model: .rgba8Unorm, channels: 4, bytes: 4,
    decode: { b in b.map { (Float($0) / 255).bitPattern } }, encode: { v in v.prefix(4).map { unormByte($0) } }),
  "bgra8": Fmt(
    name: "bgra8", spirv: 4, type: "float", model: .bgra8Unorm, channels: 4, bytes: 4,
    decode: { b in [b[2], b[1], b[0], b[3]].map { (Float($0) / 255).bitPattern } },
    encode: { v in [unormByte(v[2]), unormByte(v[1]), unormByte(v[0]), unormByte(v[3])] }),
  "r8": Fmt(
    name: "r8", spirv: 15, type: "float", model: .r8Unorm, channels: 1, bytes: 1,
    decode: { b in [(Float(b[0]) / 255).bitPattern] }, encode: { v in [unormByte(v[0])] }),
  "rgba8ui": Fmt(
    name: "rgba8ui", spirv: 32, type: "uint", model: .rgba8Uint, channels: 4, bytes: 4,
    decode: { b in b.map { UInt32($0) } }, encode: { v in v.prefix(4).map { UInt8(min($0, 255)) } }),
  "r32ui": Fmt(
    name: "r32ui", spirv: 33, type: "uint", model: .r32Uint, channels: 1, bytes: 4,
    decode: { b in [get32(b, 0)] }, encode: { v in le32(v[0]) }),
  "r32i": Fmt(
    name: "r32i", spirv: 24, type: "int", model: .r32Sint, channels: 1, bytes: 4,
    decode: { b in [get32(b, 0)] }, encode: { v in le32(v[0]) }),
  "r32f": Fmt(
    name: "r32f", spirv: 3, type: "float", model: .r32Float, channels: 1, bytes: 4,
    decode: { b in [get32(b, 0)] }, encode: { v in le32(v[0]) }),
  "rgba16f": Fmt(
    name: "rgba16f", spirv: 2, type: "float", model: .rgba16Float, channels: 4, bytes: 8,
    decode: { b in (0..<4).map { half(UInt16(b[2 * $0]) | UInt16(b[2 * $0 + 1]) << 8).bitPattern } },
    encode: { v in
      (0..<4).flatMap { k -> [UInt8] in
        let h = Float16(Float(bitPattern: v[k])).bitPattern
        return [UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8)]
      }
    }),
  "rgba32f": Fmt(
    name: "rgba32f", spirv: 1, type: "float", model: .rgba32Float, channels: 4, bytes: 16,
    decode: { b in (0..<4).map { get32(b, 4 * $0) } }, encode: { v in v.prefix(4).flatMap { le32($0) } }),
  "rgba32ui": Fmt(
    name: "rgba32ui", spirv: 30, type: "uint", model: .rgba32Uint, channels: 4, bytes: 16,
    decode: { b in (0..<4).map { get32(b, 4 * $0) } }, encode: { v in v.prefix(4).flatMap { le32($0) } }),
]

/// The texel pattern of an image: bytes that decode to exact, distinct values in every format.
private func pattern(_ f: Fmt, width: Int, height: Int, layers: Int = 1) -> [UInt8] {
  var out: [UInt8] = []
  for l in 0..<layers {
    for y in 0..<height {
      for x in 0..<width {
        let k = UInt32(1 + x * 3 + y * 17 + l * 101)
        var regs: [UInt32] = []
        for c in 0..<f.channels {
          let n = k &+ UInt32(c) &* 5
          switch f.type {
          case "float": regs.append((Float(n % 60) * 0.5 + 0.25).bitPattern)
          case "uint": regs.append(f.name == "rgba8ui" ? n % 100 : n &* 1000)
          default: regs.append(UInt32(bitPattern: Int32(n) &* -77))
          }
        }
        if f.name == "rgba8" || f.name == "bgra8" || f.name == "r8" {
          regs = (0..<f.channels).map { (Float((Int(k) * 7 + $0 * 40) % 256) / 255).bitPattern }
        }
        out += f.encode(regs)
      }
    }
  }
  return out
}

/// The shader: for each invocation of a grid of 8 x 8 workgroups (layers on z), read the source image's texel at
/// (x + dx, y), transform it and write the destination image's texel there. The destination may be an array of two
/// images chosen by the invocation's x.
private func copyShader(
  src: Fmt, dst: Fmt, arrayed: Bool = false, dx: Int = 0, destinationArray: Bool = false, atomics: Bool = false
) -> String {
  let st = src.type, dt = dst.type
  func transform(_ t: String, _ v: String, _ out: String) -> String {
    switch t {
    case "float": return "\(out) = OpVectorTimesScalar %v4float \(v) %half\n"
    default: return "\(out) = OpIAdd %v4\(t) \(v) %seven4_\(t)\n"
    }
  }
  let coordType = arrayed ? "%v3int" : "%v2int"
  let coordMake = arrayed ? "OpCompositeConstruct %v3int %xs %ys %zs" : "OpCompositeConstruct %v2int %xs %ys"
  let texelPtr = destinationArray ? "%dstptr" : "%dst"
  return """
    OpCapability Shader
    OpCapability StorageImageExtendedFormats
    OpCapability StorageImageArrayDynamicIndexing
    OpCapability ShaderNonUniform
    OpCapability StorageImageArrayNonUniformIndexing
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 8 8 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %src DescriptorSet 0
    OpDecorate %src Binding 0
    OpDecorate %dst DescriptorSet 0
    OpDecorate %dst Binding 1
    \(Corpus.prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %v2int = OpTypeVector %int 2
    %v3int = OpTypeVector %int 3
    %v4uint = OpTypeVector %uint 4
    %v4int = OpTypeVector %int 4
    %half = OpConstant %float 0.5f
    %seven_uint = OpConstant %uint 7
    %seven_int = OpConstant %int 7
    %seven4_uint = OpConstantComposite %v4uint %seven_uint %seven_uint %seven_uint %seven_uint
    %seven4_int = OpConstantComposite %v4int %seven_int %seven_int %seven_int %seven_int
    %dxc = OpConstant %int \(dx)
    %i0 = OpConstant %int 0
    %srcImg = OpTypeImage %\(st) 1 0 \(arrayed ? 1 : 0) 0 2 \(src.spirv)
    %dstImg = OpTypeImage %\(dt) 1 0 \(arrayed ? 1 : 0) 0 2 \(dst.spirv)
    %ptr_src = OpTypePointer UniformConstant %srcImg
    %ptr_dst = OpTypePointer UniformConstant %dstImg
    \(destinationArray ? "%dstArr = OpTypeArray %dstImg %u2\n%ptr_dstArr = OpTypePointer UniformConstant %dstArr" : "")
    %src = OpVariable %ptr_src UniformConstant
    %dst = OpVariable \(destinationArray ? "%ptr_dstArr" : "%ptr_dst") UniformConstant
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %g = OpLoad %v3uint %gid
    %gx = OpCompositeExtract %uint %g 0
    %gy = OpCompositeExtract %uint %g 1
    %gz = OpCompositeExtract %uint %g 2
    %xi = OpBitcast %int %gx
    %ys = OpBitcast %int %gy
    %zs = OpBitcast %int %gz
    %xs = OpIAdd %int %xi %dxc
    %coord = \(coordMake)
    %sim = OpLoad %srcImg %src
    %t = OpImageRead %v4\(st) %sim %coord
    \(transform(st == dt ? st : dt, "%t", "%t2"))
    \(destinationArray ? "%pick = OpBitwiseAnd %uint %gx %u1\n%dstptr = OpAccessChain %ptr_dst %dst %pick" : "")
    %dim = OpLoad %dstImg \(texelPtr)
    OpImageWrite %dim %coord %t2
    OpReturn
    OpFunctionEnd
    """
}

private struct Outcome {
  var got: [UInt8]
  var want: [UInt8]
  var shader: CompiledShader
}

/// Run `text` over a source image of the pattern and a destination of sentinel bytes; the expected destination from the
/// formats, over the grid of `gx` x `gy` x `layers` invocations with the texel at (x + dx, y, layer) of a `w` x `h` image.
private func runCopy(
  _ text: String, src: Fmt, dst: Fmt, w: Int, h: Int, layers: Int = 1, dx: Int = 0, groups: (Int, Int, Int) = (2, 1, 1)
) throws -> Outcome {
  let cs = try ValhallBackend.compile(try lowered(text))
  #expect(violations(cs) == [], "\(text)")
  let sourceBytes = pattern(src, width: w, height: h, layers: layers)
  let sentinel = [UInt8](repeating: 0xAB, count: dst.bytes * w * h * layers)
  let images = [
    HostImage(binding: 0, .init(bytes: sourceBytes, width: w, height: h, layers: layers, format: src.model)),
    HostImage(binding: 1, .init(bytes: sentinel, width: w, height: h, layers: layers, format: dst.model)),
  ]
  let out = try HostRun.dispatch(cs, buffers: [], images: images, grid: (UInt32(groups.0), UInt32(groups.1), UInt32(groups.2)))
  // The expected image: every invocation in bounds writes the transformed texel.
  var want = sentinel
  for l in 0..<layers {
    for y in 0..<h {
      for x in 0..<w {
        // The invocation of this texel is at x - dx, which the grid must hold.
        let gx = x - dx
        guard gx >= 0, gx < 8 * groups.0, y < 8 * groups.1, l < groups.2 else { continue }
        let at = (l * h + y) * w + x
        let texel = src.decode(Array(sourceBytes[(at * src.bytes)..<((at + 1) * src.bytes)]))
        var regs = texel
        while regs.count < 4 { regs.append(regs.count == 3 ? (src.type == "float" ? Float(1).bitPattern : 1) : 0) }
        let moved: [UInt32] = regs.map { r in
          dst.type == "float" ? (Float(bitPattern: r) * 0.5).bitPattern : r &+ 7
        }
        let to = (l * h + y) * w + x
        let bytes = dst.encode(moved)
        for k in 0..<dst.bytes { want[to * dst.bytes + k] = bytes[k] }
      }
    }
  }
  #expect(out.images[0].elements[0].bytes == sourceBytes, "the source image is not written")
  return Outcome(got: out.images[1].elements[0].bytes, want: want, shader: cs)
}

@Suite struct StorageImageTests {
  /// Each invocation reads and writes the texel at (x + dx, y, layer); the invocations past the image's edge read zeros
  /// and write nothing.
  @Test func eachFormatReadsAndWritesExactly() throws {
    for name in ["r32ui", "r32i", "r32f", "rgba8", "r8", "rgba8ui", "rgba16f", "rgba32f", "rgba32ui"] {
      let f = try #require(formats[name])
      let r = try runCopy(copyShader(src: f, dst: f), src: f, dst: f, w: 11, h: 5)
      #expect(r.got == r.want, "\(name)")
    }
  }

  @Test func theChannelsAreTheFormatsAndTheRestReadZeroZeroOne() throws {
    // r8 into rgba8: (r, 0, 0, 1) times a half, converted to bytes.
    let a = try #require(formats["r8"]), b = try #require(formats["rgba8"])
    let r = try runCopy(copyShader(src: a, dst: b), src: a, dst: b, w: 9, h: 3)
    #expect(r.got == r.want)
    // rgba8 into r8: the first channel only.
    let r2 = try runCopy(copyShader(src: b, dst: a), src: b, dst: a, w: 9, h: 3)
    #expect(r2.got == r2.want)
    // rgba32ui into r32ui.
    let c = try #require(formats["rgba32ui"]), d = try #require(formats["r32ui"])
    let r3 = try runCopy(copyShader(src: c, dst: d), src: c, dst: d, w: 6, h: 6)
    #expect(r3.got == r3.want)
  }

  @Test func bgraAndRgbaAreTheDescriptorsToSettle() throws {
    // The shader says Rgba8 for both: what differs is the descriptor's format, and the bytes in memory follow it.
    let a = try #require(formats["rgba8"]), b = try #require(formats["bgra8"])
    let r = try runCopy(copyShader(src: a, dst: b), src: a, dst: b, w: 7, h: 4)
    #expect(r.got == r.want)
    let r2 = try runCopy(copyShader(src: b, dst: b), src: b, dst: b, w: 7, h: 4)
    #expect(r2.got == r2.want)
  }

  @Test func aCoordinateOutsideTheImageReadsAndWritesNothing() throws {
    let f = try #require(formats["r32ui"])
    // An offset of 3: the first three columns have no invocation, so they keep their sentinel.
    let r = try runCopy(copyShader(src: f, dst: f, dx: 3), src: f, dst: f, w: 12, h: 4, dx: 3)
    #expect(r.got == r.want)
    // 65536 added: a coordinate whose low 16 bits are in the image but not the coordinate. Nothing is written.
    let far = try runCopy(copyShader(src: f, dst: f, dx: 65536), src: f, dst: f, w: 12, h: 4, dx: 65536)
    #expect(far.got == far.want)
    #expect(far.got.allSatisfy { $0 == 0xAB })
    // Negative: 16 bits all ones, past the width.
    let neg = try runCopy(copyShader(src: f, dst: f, dx: -1), src: f, dst: f, w: 12, h: 4, dx: -1)
    #expect(neg.got == neg.want)
  }

  @Test func anArrayedImageTakesTheLayerOnZ() throws {
    let f = try #require(formats["rgba8ui"])
    let r = try runCopy(copyShader(src: f, dst: f, arrayed: true), src: f, dst: f, w: 10, h: 4, layers: 3, groups: (2, 1, 3))
    #expect(r.got == r.want)
    #expect(r.got.contains { $0 != 0xAB }, "something was written")
  }

  /// The destination is an array of two images chosen by the invocation's x: the handle differs between the lanes of a
  /// warp, so the backend loops over the distinct handles.
  @Test func anImageChosenPerLaneGetsTheHandleLoop() throws {
    let f = try #require(formats["r32ui"])
    let text = copyShader(src: f, dst: f, destinationArray: true)
    let cs = try ValhallBackend.compile(try lowered(text))
    #expect(violations(cs) == [])
    #expect(cs.listing.contains("WMASK") && cs.listing.contains("CLPER"), "\(cs.listing)")
    let w = 12, h = 4
    let source = pattern(f, width: w, height: h)
    let sentinel = [UInt8](repeating: 0xAB, count: 4 * w * h)
    let images = [
      HostImage(binding: 0, .init(bytes: source, width: w, height: h, format: .r32Uint)),
      HostImage(
        binding: 1,
        elements: [
          .init(bytes: sentinel, width: w, height: h, format: .r32Uint),
          .init(bytes: sentinel, width: w, height: h, format: .r32Uint),
        ]),
    ]
    let out = try HostRun.dispatch(cs, buffers: [], images: images, grid: (2, 1, 1))
    for element in 0..<2 {
      var want = sentinel
      for y in 0..<h {
        for x in 0..<w where x & 1 == element {
          let v = get32(source, 4 * (y * w + x)) &+ 7
          for k in 0..<4 { want[4 * (y * w + x) + k] = le32(v)[k] }
        }
      }
      #expect(out.images[1].elements[element].bytes == want, "element \(element)")
    }
  }

  /// OpImageTexelPointer and atomics: each invocation adds 1 to one of four texels (12b.11), and the first row adds 100 to
  /// each.
  @Test func atomicsOnTheTexelsOfAnR32uiImage() throws {
    let text = """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 8 8 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %img DescriptorSet 0
      OpDecorate %img Binding 0
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %v2int = OpTypeVector %int 2
      %i0 = OpConstant %int 0
      %imgT = OpTypeImage %uint 1 0 0 0 2 33
      %ptr_img = OpTypePointer UniformConstant %imgT
      %img = OpVariable %ptr_img UniformConstant
      %c100 = OpConstant %uint 100
      %ptr_texel = OpTypePointer Image %uint
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %g = OpLoad %v3uint %gid
      %gx = OpCompositeExtract %uint %g 0
      %gy = OpCompositeExtract %uint %g 1
      %k = OpBitwiseAnd %uint %gx %u3
      %xi = OpBitcast %int %k
      %coord = OpCompositeConstruct %v2int %xi %i0
      %p = OpImageTexelPointer %ptr_texel %img %coord %u0
      %old = OpAtomicIAdd %uint %p %u1 %u0 %u1
      %first = OpIEqual %bool %gy %u0
      OpSelectionMerge %end None
      OpBranchConditional %first %low %end
      %low = OpLabel
      %q = OpImageTexelPointer %ptr_texel %img %coord %u0
      %oldmax = OpAtomicIAdd %uint %q %u1 %u0 %c100
      OpBranch %end
      %end = OpLabel
      OpReturn
      OpFunctionEnd
      """
    let cs = try ValhallBackend.compile(try lowered(text))
    #expect(violations(cs) == [])
    let images = [HostImage(binding: 0, .init(bytes: [UInt8](repeating: 0, count: 16), width: 4, format: .r32Uint))]
    let out = try HostRun.dispatch(cs, buffers: [], images: images, grid: (1, 1, 1))
    // 64 invocations (gx and gy in 0...7): texel gx & 3 gets 16 adds of 1, and the two of the first row add 100 each.
    #expect(words(out.images[0].elements[0].bytes) == [UInt32](repeating: 216, count: 4))
  }
}
