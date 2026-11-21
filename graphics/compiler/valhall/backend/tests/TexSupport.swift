// SPDX-License-Identifier: BSD-3-Clause

// What the texture, derivative and built-in tests share: GLSL shaders compiled to committed SPIR-V (tests/shaders, made by
// `vx shaders`), compiled by the backend (which runs the ISA validator over what it makes), run over one warp of the
// interpreter with a texture model, and the CPU reference that is the model itself, called by the test on the inputs the
// shader should have used.

import Foundation
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA
import ValhallInterp

let texHandle0 = DescriptorHeap.handle(index: 16)
let smpHandle0 = DescriptorHeap.handle(index: 40)

func shaderWords(_ name: String) throws -> [UInt32] {
  guard let w = treeWords("graphics/compiler/valhall/backend/tests/shaders/\(name).frag.spv") else {
    throw CompileError("shader \(name) not found")
  }
  return w
}

func compileShader(_ name: String, options: BackendOptions = BackendOptions()) throws -> CompiledGraphicsShader {
  try ValhallBackend.compileGraphics(spirv: try shaderWords(name), options: options)
}

/// A float texel from a hash of its place, so that every texel differs and neighbours are not related.
func hashFloat(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Float {
  var h = UInt32(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791 ^ d &* 2_654_435_761)
  h ^= h >> 15
  h = h &* 0x2C1B_3C6D
  h ^= h >> 12
  return Float(h & 0xFFFF) / 65535
}

func floatTexture(
  _ dim: TexDim, _ w: Int, _ h: Int = 1, depth: Int = 1, layers: Int = 1, arrayed: Bool = false, levels: Int = 1, samples: Int = 1
) -> TextureModel {
  TextureModel(
    dim: dim, width: w, height: h, depth: depth, layers: layers, arrayed: arrayed, levels: levels, samples: samples
  ) { l, layer, s, x, y, z in
    (0..<4).map { hashFloat(l * 1000 + layer, s * 100 + x, y * 50 + z, $0).bitPattern }
  }
}

func intTexture(_ w: Int, _ h: Int, levels: Int = 1) -> TextureModel {
  TextureModel(dim: .d2, width: w, height: h, levels: levels, integer: true) { l, _, _, x, y, _ in
    [UInt32(l * 1000 + y * 16 + x), UInt32(x), UInt32(y), 7]
  }
}

func f(_ w: UInt32) -> Float { Float(bitPattern: w) }

/// One run of a fragment shader over a warp: the result and the compiled shader.
struct FragRun {
  var shader: CompiledGraphicsShader
  var result: FragmentResult
  var input: FragmentInput
}

func runFragment(
  _ name: String, _ input: FragmentInput, textures: [UInt32: TextureModel] = [:], samplers: [UInt32: SamplerModel] = [:],
  bindings: [(set: Int, binding: Int, handle: UInt32)]? = nil, options: BackendOptions = BackendOptions()
) throws -> FragRun {
  let c = try compileShader(name, options: options)
  if let p = getenv("VX_PRINT"), String(cString: p) == name { print(name + "\n" + c.listing) }
  let b = bindings ?? [(set: 0, binding: 0, handle: texHandle0), (set: 0, binding: 1, handle: smpHandle0)]
  let r = try HostRun.fragment(c, input: input, bindings: b, dummySampler: smpHandle0, textures: textures, samplers: samplers)
  return FragRun(shader: c, result: r, input: input)
}

/// The base level of detail of `lane`'s quad from the coordinates `coords` gives each lane (the model's own difference).
func quadLod(_ tex: TextureModel, _ lane: Int, _ coords: (Int) -> [Float]) -> Float {
  let q = lane & ~3
  let o = coords(q)
  let a = coords(q + 1), b = coords(q + 2)
  let dx = (0..<o.count).map { a[$0] - o[$0] }
  let dy = (0..<o.count).map { b[$0] - o[$0] }
  return tex.dim == .cube ? tex.cubeBaseLod(o, dx: dx, dy: dy) : tex.baseLod(dx: dx, dy: dy)
}

func clampLod(_ lod: Float, _ s: SamplerModel) -> Float { min(max(lod + s.bias, s.minLod), s.maxLod) }

/// The s8.8 word a shader's explicit level or bias goes through (12b.5.5): clamped to +-16, times 256, truncated.
func levelQuantized(_ x: Float) -> Float { Float(Int32(min(max(x, -16), 16) * 256)) / 256 }

func expectTexel(_ got: [UInt32]?, _ want: [UInt32], _ what: String, tolerance: Float = 0) {
  guard let got else {
    Issue.record("\(what): the lane wrote nothing")
    return
  }
  for c in 0..<min(got.count, want.count) {
    let a = f(got[c]), b = f(want[c])
    let ok = tolerance == 0 ? got[c] == want[c] : abs(a - b) <= tolerance + tolerance * abs(b)
    if !ok { Issue.record("\(what): channel \(c) is \(a) (\(String(got[c], radix: 16))), expected \(b) (\(String(want[c], radix: 16)))") }
  }
}

/// A default input: the quads at pixels (8, 8) and on, every lane covered, a varying at location 0 of `scale` per pixel.
func linearInput(scale: (Float, Float), origin: Float = 0.05) -> FragmentInput {
  var inp = FragmentInput()
  inp.origin = (8, 8)
  inp.varying = { loc, x, y in
    loc == 0 ? [origin + x * scale.0, origin + y * scale.1, 0, 1] : [0, 0, 0, 0]
  }
  return inp
}
