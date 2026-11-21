// SPDX-License-Identifier: BSD-3-Clause

// Texture instructions (valhall 12b) compiled from GLSL and run on the interpreter's texture model, each against the model
// called by the test on the inputs the shader should have used. A sample is exact (the same arithmetic on both sides);
// the level words (12b.5.5) go through s8.8 on both.

import Foundation
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA
import ValhallInterp

let linearSampler = SamplerModel(mipmap: SamplerModel.mipTrilinear, wrap: [9, 9, 9], maxLod: 15)

@Suite struct SampleTests {
  let tex = floatTexture(.d2, 8, 8, levels: 4)

  /// The lanes with their own coordinates, the quad's levels from them.
  func uvOf(_ inp: FragmentInput, _ lane: Int) -> [Float] {
    let p = inp.pixel(lane)
    return inp.varying(0, Float(p.x) + 0.5, Float(p.y) + 0.5)
  }

  @Test func anImplicitSampleUsesTheQuadsLevel() throws {
    for scale in [(Float(0.0125), Float(0.0125)), (0.3, 0.2), (0.11, 0.5), (0.02, 0.09)] {
      let inp = linearInput(scale: scale)
      let r = try runFragment("sample2d", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
      var levels = Set<Int>()
      for lane in 0..<16 {
        let uv = uvOf(inp, lane)
        let lod = clampLod(quadLod(tex, lane) { uvOf(inp, $0).prefix(2).map { $0 } }, linearSampler)
        levels.insert(Int(max(lod, 0)))
        expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [uv[0], uv[1]], layer: 0, lod: lod), "lane \(lane) scale \(scale)")
      }
      if scale.0 == 0.3 { #expect(levels.count > 1 || levels.first! >= 1) }
    }
  }

  @Test func theSamplersBiasAndLimitsApplyToAComputedLevel() throws {
    let s = SamplerModel(mipmap: SamplerModel.mipTrilinear, lodBias: 0.75, minLod: 0.5, maxLod: 2.25)
    let inp = linearInput(scale: (0.04, 0.03))
    let r = try runFragment("sample2d", inp, textures: [texHandle0: tex], samplers: [smpHandle0: s])
    for lane in 0..<16 {
      let uv = uvOf(inp, lane)
      let lod = clampLod(quadLod(tex, lane) { uvOf(inp, $0).prefix(2).map { $0 } }, s)
      expectTexel(r.result.colours[lane][0], tex.sample(s, [uv[0], uv[1]], layer: 0, lod: lod), "lane \(lane)")
    }
  }

  @Test func theEveryFilterAndAddressMode() throws {
    let modes: [(String, SamplerModel)] = [
      ("nearest", SamplerModel(magNearest: true, minNearest: true, mipmap: SamplerModel.mipNearest)),
      ("repeat", SamplerModel(mipmap: SamplerModel.mipNone, wrap: [8, 8, 8])),
      ("mirror", SamplerModel(mipmap: SamplerModel.mipTrilinear, wrap: [12, 12, 12])),
      ("border", SamplerModel(mipmap: SamplerModel.mipNone, wrap: [11, 11, 11], border: [f32(0.25), f32(0.5), f32(0.75), f32(1)])),
      ("mirrorclamp", SamplerModel(mipmap: SamplerModel.mipNone, wrap: [13, 13, 13])),
    ]
    for (name, s) in modes {
      // Coordinates past the edges, so the address mode shows.
      let inp = linearInput(scale: (0.09, -0.06), origin: -0.4)
      let r = try runFragment("sample2d", inp, textures: [texHandle0: tex], samplers: [smpHandle0: s])
      for lane in 0..<16 {
        let uv = uvOf(inp, lane)
        let lod = clampLod(quadLod(tex, lane) { uvOf(inp, $0).prefix(2).map { $0 } }, s)
        expectTexel(r.result.colours[lane][0], tex.sample(s, [uv[0], uv[1]], layer: 0, lod: lod), "\(name) lane \(lane)")
      }
    }
  }

  private func f32(_ x: Float) -> UInt32 { x.bitPattern }

  @Test func aBiasedSampleAddsTheBias() throws {
    var inp = linearInput(scale: (0.07, 0.05))
    inp.varying = { loc, x, y in loc == 0 ? [0.05 + x * 0.07, 0.05 + y * 0.05, 0, 1] : [(x * 0.37).truncatingRemainder(dividingBy: 2) - 0.7, 0, 0, 0] }
    let r = try runFragment("bias", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    for lane in 0..<16 {
      let uv = uvOf(inp, lane)
      let p = inp.pixel(lane)
      let bias = levelQuantized(inp.varying(1, Float(p.x) + 0.5, Float(p.y) + 0.5)[0])
      let lod = clampLod(quadLod(tex, lane) { uvOf(inp, $0).prefix(2).map { $0 } } + bias, linearSampler)
      expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [uv[0], uv[1]], layer: 0, lod: lod), "lane \(lane)")
    }
  }

  @Test func anExplicitLevelIsTheLevelWord() throws {
    var inp = linearInput(scale: (0.07, 0.05))
    inp.varying = { loc, x, y in loc == 0 ? [0.05 + x * 0.07, 0.05 + y * 0.05, 0, 1] : [(x * 0.53).truncatingRemainder(dividingBy: 3.4), 0, 0, 0] }
    let r = try runFragment("lod", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    for lane in 0..<16 {
      let uv = uvOf(inp, lane)
      let p = inp.pixel(lane)
      let l = levelQuantized(inp.varying(1, Float(p.x) + 0.5, Float(p.y) + 0.5)[0])
      expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [uv[0], uv[1]], layer: 0, lod: clampLod(l, linearSampler)), "lane \(lane)")
    }
  }

  @Test func explicitGradientsMakeADescriptor() throws {
    var inp = linearInput(scale: (0.07, 0.05))
    inp.varying = { loc, x, y in
      loc == 0 ? [0.05 + x * 0.07, 0.05 + y * 0.05, 0, 1] : [0.01 + (x * 0.013).truncatingRemainder(dividingBy: 0.2), 0.02, -0.03, 0.05 + (y * 0.021).truncatingRemainder(dividingBy: 0.3)]
    }
    let r = try runFragment("grad", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    let ops = r.shader.instructions.map { $0.mnemonic }
    #expect(ops.contains("TEX_GRADIENT") && ops.contains("TEX_SINGLE"))
    for lane in 0..<16 {
      let uv = uvOf(inp, lane)
      let p = inp.pixel(lane)
      let g = inp.varying(1, Float(p.x) + 0.5, Float(p.y) + 0.5)
      // The descriptor: the level from the derivatives, in s8.8 (rounded), then the sampler's bias and limits.
      let base = tex.baseLod(dx: [g[0], g[1]], dy: [g[2], g[3]])
      let word = Float(Int16(min(max((base * 256).rounded(), -32768), 32767))) / 256
      expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [uv[0], uv[1]], layer: 0, lod: clampLod(word, linearSampler)), "lane \(lane)")
    }
  }

  @Test func aConstantOffsetMovesTheLookupByTexels() throws {
    let inp = linearInput(scale: (0.09, 0.06))
    let r = try runFragment("offset", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    #expect(r.shader.instructions.contains { $0.mnemonic == "TEX_SINGLE" && $0.value("texel_offset") == 1 })
    for lane in 0..<16 {
      let uv = uvOf(inp, lane)
      let lod = clampLod(quadLod(tex, lane) { uvOf(inp, $0).prefix(2).map { $0 } }, linearSampler)
      expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [uv[0], uv[1]], layer: 0, lod: lod, offset: (1, -2, 0)), "lane \(lane)")
    }
  }

  @Test func aProjectiveSampleDividesTheCoordinates() throws {
    var inp = linearInput(scale: (0.04, 0.03))
    inp.varying = { loc, x, y in loc == 0 ? [0.05 + x * 0.04, 0.05 + y * 0.03, 0, 1] : [1.5 + x * 0.01, 0, 0, 0] }
    let r = try runFragment("proj", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    for lane in 0..<16 {
      let p = inp.pixel(lane)
      func coords(_ l: Int) -> [Float] {
        let q = inp.pixel(l)
        let uv = uvOf(inp, l)
        let w = inp.varying(1, Float(q.x) + 0.5, Float(q.y) + 0.5)[0]
        let s = uv[0] * w, t = uv[1] * w
        return [s / w, t / w]
      }
      _ = p
      let c = coords(lane)
      let lod = clampLod(quadLod(tex, lane, coords), linearSampler)
      // The product and quotient are in floats on both sides, so they agree to the last bit or two.
      let want = tex.sample(linearSampler, c, layer: 0, lod: lod)
      expectTexel(r.result.colours[lane][0], want, "lane \(lane)", tolerance: 0.002)
    }
  }
}
