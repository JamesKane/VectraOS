// SPDX-License-Identifier: BSD-3-Clause

// The other texture forms (valhall 12b): depth compare, gather, fetch (also multisampled), the queries, arrays, 3D and cube
// images, and a sampled-image array indexed non-uniformly. Each shader is GLSL (tests/shaders), run on one warp of the
// interpreter, the lanes' results checked against the texture model called on the inputs the shader should have used.

import Foundation
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA
import ValhallInterp

/// The hardware's gather order permuted into the API's (x0,y1), (x1,y1), (x1,y0), (x0,y0) (12b.5.7).
private func apiOrder(_ hw: [UInt32]) -> [UInt32] { [hw[2], hw[3], hw[1], hw[0]] }

private func uv(_ inp: FragmentInput, _ lane: Int, _ loc: Int = 0) -> [Float] {
  let p = inp.pixel(lane)
  return inp.varying(loc, Float(p.x) + 0.5, Float(p.y) + 0.5)
}

@Suite struct GatherAndCompareTests {
  let tex = floatTexture(.d2, 8, 8, levels: 3)

  @Test func aGatherReturnsTheFootprintInTheAPIsOrder() throws {
    let inp = linearInput(scale: (0.06, 0.05))
    let r = try runFragment("gather", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    #expect(r.shader.instructions.filter { $0.mnemonic == "TEX_GATHER" }.count == 3)
    for lane in 0..<16 {
      let c = uv(inp, lane)
      expectTexel(r.result.colours[lane][0], apiOrder(tex.gather(linearSampler, c, layer: 0, component: 1)), "component 1, lane \(lane)")
      expectTexel(
        r.result.colours[lane][1], apiOrder(tex.gather(linearSampler, c, layer: 0, component: 2, offset: (1, 0, 0))), "offset, lane \(lane)")
      expectTexel(r.result.colours[lane][2], apiOrder(tex.gather(linearSampler, c, layer: 0, component: 0)), "component 0, lane \(lane)")
    }
  }

  @Test func fourOffsetsAreFourGathers() throws {
    let inp = linearInput(scale: (0.06, 0.05))
    let r = try runFragment("gatheroffsets", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    #expect(r.shader.instructions.filter { $0.mnemonic == "TEX_GATHER" }.count == 4)
    let offsets = [(0, 0), (2, 0), (0, 3), (-1, -1)]
    for lane in 0..<16 {
      let c = uv(inp, lane)
      var want: [UInt32] = []
      for (j, o) in offsets.enumerated() {
        want.append(apiOrder(tex.gather(linearSampler, c, layer: 0, component: 0, offset: (o.0, o.1, 0)))[j])
      }
      expectTexel(r.result.colours[lane][0], want, "lane \(lane)")
    }
  }

  @Test func aDepthCompareFiltersTheResults() throws {
    let s = SamplerModel(mipmap: SamplerModel.mipTrilinear, compareOp: 3)
    var inp = linearInput(scale: (0.07, 0.06))
    inp.varying = { loc, x, y in
      loc == 0 ? [0.05 + x * 0.07, 0.05 + y * 0.06, 0, 1] : [0.2 + (x * 0.13 + y * 0.37).truncatingRemainder(dividingBy: 1) * 0.6, 0, 0, 0]
    }
    let r = try runFragment("shadow", inp, textures: [texHandle0: tex], samplers: [smpHandle0: s])
    #expect(r.shader.instructions.contains { $0.mnemonic == "TEX_SINGLE" && $0.value("compare") == 1 })
    #expect(r.shader.instructions.contains { $0.mnemonic == "TEX_GATHER" && $0.value("compare") == 1 })
    for lane in 0..<16 {
      let c = uv(inp, lane)
      let ref = uv(inp, lane, 1)[0]
      let lod = clampLod(quadLod(tex, lane) { Array(uv(inp, $0).prefix(2)) }, s)
      let a = tex.sample(s, [c[0], c[1]], layer: 0, lod: lod, compare: ref)[0]
      expectTexel(r.result.colours[lane][0], [a, a, a, a], "implicit, lane \(lane)")
      let b = tex.sample(s, [c[0], c[1]], layer: 0, lod: clampLod(1, s), compare: ref)[0]
      expectTexel(r.result.colours[lane][1], [b, b, b, b], "explicit, lane \(lane)")
      expectTexel(r.result.colours[lane][2], apiOrder(tex.gather(s, [c[0], c[1]], layer: 0, component: 0, compare: ref)), "gather, lane \(lane)")
    }
  }
}

@Suite struct FetchTests {
  @Test func aFetchTakesTheLevelAndOffsetFromItsOffsetWord() throws {
    let tex = floatTexture(.d2, 32, 32, levels: 4)
    var inp = FragmentInput()
    inp.origin = (8, 8)
    inp.flat = { _, lane in [UInt32(lane % 3), 0, 0, 0] }
    let r = try runFragment("fetch", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    #expect(r.shader.instructions.allSatisfy { $0.mnemonic != "TEX_SINGLE" })
    for lane in 0..<16 {
      let p = inp.pixel(lane)
      expectTexel(r.result.colours[lane][0], tex.fetch(x: p.x, y: p.y, z: 0, layer: 0, level: lane % 3, sample: 0) ?? [0, 0, 0, 0], "level, lane \(lane)")
      expectTexel(r.result.colours[lane][1], tex.fetch(x: p.x + 2, y: p.y + 1, z: 0, layer: 0, level: 1, sample: 0) ?? [0, 0, 0, 0], "offset, lane \(lane)")
    }
  }

  @Test func aFetchOutsideTheLevelReadsZeros() throws {
    // Level 3 of a 32-wide image is 4 texels wide: the pixels at 8 and more are outside (the model's choice, 12b.7 is open).
    let tex = floatTexture(.d2, 32, 32, levels: 4)
    var inp = FragmentInput()
    inp.origin = (8, 8)
    inp.flat = { _, _ in [3, 0, 0, 0] }
    let r = try runFragment("fetch", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    for lane in 0..<16 { expectTexel(r.result.colours[lane][0], [0, 0, 0, 0], "lane \(lane)") }
  }

  @Test func aMultisampledFetchNamesTheSample() throws {
    let tex = floatTexture(.d2, 16, 16, samples: 4)
    var inp = FragmentInput()
    inp.origin = (4, 4)
    inp.flat = { _, lane in [UInt32(lane % 4), 0, 0, 0] }
    let r = try runFragment("fetchms", inp, textures: [texHandle0: tex], bindings: [(set: 0, binding: 0, handle: texHandle0)])
    for lane in 0..<16 {
      let p = inp.pixel(lane)
      expectTexel(r.result.colours[lane][0], tex.fetch(x: p.x, y: p.y, z: 0, layer: 0, level: 0, sample: lane % 4)!, "lane \(lane)")
    }
  }
}

@Suite struct QueryTests {
  @Test func sizeLevelsAndTheLevelOfDetail() throws {
    let tex = floatTexture(.d2, 16, 8, levels: 4)
    for s in [
      SamplerModel(mipmap: SamplerModel.mipTrilinear, lodBias: 0.25, minLod: 0.5, maxLod: 3),
      SamplerModel(mipmap: SamplerModel.mipNearest, minLod: 0, maxLod: 2),
      SamplerModel(mipmap: SamplerModel.mipNone),
    ] {
      var inp = linearInput(scale: (0.1, 0.13))
      inp.flat = { _, lane in [UInt32(lane % 4), 0, 0, 0] }
      let r = try runFragment("query", inp, textures: [texHandle0: tex], samplers: [smpHandle0: s])
      #expect(r.shader.instructions.contains { $0.mnemonic == "TEX_GRADIENT" })
      for lane in 0..<16 {
        let l = lane % 4
        let size = tex.levelSize(l)
        #expect(r.result.colours[lane][1] == [UInt32(size.0), UInt32(size.1), 4, 7], "sizes, lane \(lane): \(String(describing: r.result.colours[lane][1]))")
        // The unclamped level goes through s8.8; the software clamps it (12b.13.4).
        let base = quadLod(tex, lane) { Array(uv(inp, $0).prefix(2)) } + s.bias
        let word = Float(Int16(min(max((base * 256).rounded(), -32768), 32767))) / 256
        var clamped = min(min(max(word, s.minLod), s.maxLod), Float(tex.levels - 1))
        let mode = Int(s.words[0] >> 30)
        if mode == 1 { clamped = 0 } else if mode == 0 { clamped = (clamped + 0.5).rounded(.up) - 1 }
        expectTexel(r.result.colours[lane][0], [clamped.bitPattern, word.bitPattern, 0, Float(1).bitPattern], "lod, lane \(lane) mode \(mode)")
      }
    }
  }

  @Test func theSamplesOfAMultisampledImage() throws {
    let tex = floatTexture(.d2, 16, 16, samples: 4)
    let r = try runFragment("querysamples", FragmentInput(), textures: [texHandle0: tex], bindings: [(set: 0, binding: 0, handle: texHandle0)])
    for lane in 0..<16 { expectTexel(r.result.colours[lane][0], [Float(4).bitPattern, Float(16).bitPattern, Float(16).bitPattern, Float(1).bitPattern], "lane \(lane)") }
  }
}

@Suite struct ImageKindTests {
  @Test func anArrayLayerIsRoundedAndClamped() throws {
    let tex = floatTexture(.d2, 8, 8, layers: 4, arrayed: true, levels: 3)
    var inp = FragmentInput()
    inp.origin = (8, 8)
    inp.varying = { _, x, y in [0.05 + x * 0.07, 0.05 + y * 0.05, (x * 0.31 + y * 0.77).truncatingRemainder(dividingBy: 5) - 0.4, 0] }
    let r = try runFragment("array", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    for lane in 0..<16 {
      let c = uv(inp, lane)
      let layer = Int((c[2] + 0.5).rounded(.down))
      let lod = clampLod(quadLod(tex, lane) { Array(uv(inp, $0).prefix(2)) }, linearSampler)
      expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [c[0], c[1]], layer: layer, lod: lod), "lane \(lane) layer \(c[2])")
      expectTexel(r.result.colours[lane][1], [Float(4).bitPattern, Float(4).bitPattern, Float(4).bitPattern, Float(1).bitPattern], "size, lane \(lane)")
    }
  }

  @Test func aThreeDimensionalImageFiltersInThreeAxes() throws {
    let tex = floatTexture(.d3, 8, 8, depth: 8, levels: 3)
    var inp = FragmentInput()
    inp.origin = (8, 8)
    inp.varying = { _, x, y in [0.05 + x * 0.04, 0.05 + y * 0.03, 0.1 + (x * 0.02 + y * 0.01), 0] }
    let r = try runFragment("tex3d", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    for lane in 0..<16 {
      let c = uv(inp, lane)
      let lod = clampLod(quadLod(tex, lane) { Array(uv(inp, $0).prefix(3)) }, linearSampler)
      expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [c[0], c[1], c[2]], layer: 0, lod: lod), "lane \(lane)")
      expectTexel(r.result.colours[lane][1], [Float(4).bitPattern, Float(4).bitPattern, Float(4).bitPattern, Float(1).bitPattern], "size, lane \(lane)")
    }
  }

  @Test func aCubeIsReadInTheDirectionForm() throws {
    let tex = floatTexture(.cube, 8, 8, layers: 1, levels: 3)
    var inp = FragmentInput()
    inp.origin = (8, 8)
    // Directions that land on several faces across the warp, smooth inside a quad.
    inp.varying = { _, x, y in
      let a = x - 9.5, b = y - 9.5
      return [a * 0.6, b * 0.5 + 0.1, 1.2 - abs(a) * 0.3, 0]
    }
    let r = try runFragment("cube", inp, textures: [texHandle0: tex], samplers: [smpHandle0: linearSampler])
    #expect(r.shader.instructions.contains { $0.mnemonic == "TEX_SINGLE" && $0.valueName("dim") == "cube" && $0.value("project") == 1 })
    var faces = Set<Int>()
    for lane in 0..<16 {
      let c = uv(inp, lane)
      faces.insert(TextureModel.cubeFace(c[0], c[1], c[2]).face)
      let lod = clampLod(quadLod(tex, lane) { Array(uv(inp, $0).prefix(3)) }, linearSampler)
      expectTexel(r.result.colours[lane][0], tex.sample(linearSampler, [c[0], c[1], c[2]], layer: 0, lod: lod), "lane \(lane)")
      expectTexel(r.result.colours[lane][1], [Float(8).bitPattern, Float(8).bitPattern, 0, Float(1).bitPattern], "size, lane \(lane)")
    }
    #expect(faces.count >= 2)
  }

  @Test func anArrayOfImagesIndexedByAFlatVaryingTakesTheHandleLoop() throws {
    let a = floatTexture(.d2, 8, 8, levels: 2)
    let b = floatTexture(.d2, 8, 8, levels: 2)
    let c = floatTexture(.d2, 8, 8, levels: 2)
    var inp = linearInput(scale: (0.05, 0.04))
    inp.flat = { _, lane in [UInt32(lane % 3), 0, 0, 0] }
    let models = [a, b, c]
    let r = try runFragment(
      "nonuniform", inp, textures: [texHandle0: a, texHandle0 + 1: b, texHandle0 + 2: c], samplers: [smpHandle0: linearSampler])
    #expect(r.shader.instructions.contains { $0.mnemonic == "WMASK" })
    for lane in 0..<16 {
      let t = models[lane % 3]
      let co = uv(inp, lane)
      // The handle loop serves the lanes of one texture together, so a quad's level is from the neighbours that are in
      // the lane's round; a neighbour that is not gives no difference, and a missing first lane no level (the model's
      // choice for a quad that has diverged, 12b.6).
      let q = lane & ~3
      func same(_ l: Int) -> Bool { l % 3 == lane % 3 }
      var lod: Float = -Float.infinity
      if same(q) {
        let o = uv(inp, q)
        let dx = same(q + 1) ? [uv(inp, q + 1)[0] - o[0], uv(inp, q + 1)[1] - o[1]] : [0, 0]
        let dy = same(q + 2) ? [uv(inp, q + 2)[0] - o[0], uv(inp, q + 2)[1] - o[1]] : [0, 0]
        lod = t.baseLod(dx: dx, dy: dy)
      }
      expectTexel(r.result.colours[lane][0], t.sample(linearSampler, [co[0], co[1]], layer: 0, lod: clampLod(lod, linearSampler)), "lane \(lane)")
    }
  }
}
