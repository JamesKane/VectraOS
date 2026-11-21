// SPDX-License-Identifier: BSD-3-Clause

// Images against valhall 05's worked examples (the linear and u-interleaved address arithmetic, the u-curve), 03's
// texture, plane and sampler tables, 12b's handle forms, and 09's blend examples and decision procedure.

import MaliCore
import Testing

// MARK: layouts (05 sections 5.5.4 and 5.6.3)

@Test func theLinearExampleOfSection554() {
  let l = ImageLayout(format: .rgba8, kind: .linear, width: 100, height: 70, levels: 3, layers: 2)
  #expect(l.levels[0].rowStride == 448 && l.levels[0].surfaceStride == 31360 && l.levels[0].offset == 0)
  #expect(l.levels[1].rowStride == 256 && l.levels[1].surfaceStride == 8960 && l.levels[1].offset == 31360)
  #expect(l.levels[2].rowStride == 128 && l.levels[2].surfaceStride == 2176 && l.levels[2].offset == 40320)
  #expect(l.levels[2].width == 25 && l.levels[2].height == 17)
  #expect(l.arrayStride == 42496)
  #expect(l.size == 86016)
  // Texel (10, 5) of level 0 of layer 1.
  #expect(l.texelOffset(x: 10, y: 5, level: 0, layer: 1) == 44776)
}

@Test func theUInterleavedExampleOfSection563() {
  let l = ImageLayout(format: .rgba8, kind: .uInterleaved, width: 100, height: 70, levels: 2)
  #expect(l.levels[0].rowStride == 7168 && l.levels[0].surfaceStride == 35840)
  #expect(l.levels[1].rowStride == 4096 && l.levels[1].surfaceStride == 12288 && l.levels[1].offset == 35840)
  // Texel (37, 21): tile column 2, tile row 1, in-tile (5, 5), u-curve index 0x22 = 34.
  #expect(ImageLayout.uCurve(x: 5, y: 5) == 34)
  #expect(l.texelOffset(x: 37, y: 21) == 9352)
}

@Test func theUCurveIsAPermutationOfTheTile() {
  var seen = [Bool](repeating: false, count: 256)
  for y in 0..<16 {
    for x in 0..<16 { seen[ImageLayout.uCurve(x: x, y: y)] = true }
  }
  #expect(!seen.contains(false))
  // The most significant bit is y3 and the next x3 xor y3 (05 section 5.6.2).
  #expect(ImageLayout.uCurve(x: 0, y: 8) == 0b1100_0000)
  #expect(ImageLayout.uCurve(x: 8, y: 0) == 0b0100_0000)
  #expect(ImageLayout.uCurve(x: 8, y: 8) == 0b1000_0000)
  #expect(ImageLayout.uCurve(x: 1, y: 0) == 1 && ImageLayout.uCurve(x: 0, y: 1) == 3)
}

@Test func uploadAndDownloadRoundTripInBothLayouts() {
  for kind in [ImageLayoutKind.linear, ImageLayoutKind.uInterleaved] {
    for (w, h) in [(16, 16), (37, 21), (1, 1), (100, 3)] {
      let l = ImageLayout(format: .rgba8, kind: kind, width: w, height: h, levels: 1, layers: 2)
      var texels = [UInt8](repeating: 0, count: w * h * 4)
      for i in 0..<texels.count { texels[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
      var memory = [UInt8](repeating: 0xEE, count: l.size)
      l.upload(texels, layer: 1, into: &memory)
      #expect(l.download(layer: 1, from: memory) == texels)
      // Layer 0 untouched.
      #expect(l.download(layer: 0, from: memory) == [UInt8](repeating: 0xEE, count: w * h * 4))
    }
  }
  // One-byte texels.
  let r = ImageLayout(format: .r8, kind: .uInterleaved, width: 20, height: 18)
  var t = [UInt8](repeating: 0, count: 20 * 18)
  for i in 0..<t.count { t[i] = UInt8(i & 255) }
  var m = [UInt8](repeating: 0, count: r.size)
  r.upload(t, into: &m)
  #expect(r.download(from: m) == t)
}

// MARK: formats (05 section 5.2)

@Test func theFormatWords() {
  // RGBA8 UNORM: index 187 at [19:12], order RGBA; sRGB bit 20; BGRA order 4; R8 index 163 with order RGB1 (16).
  #expect(TexelFormat.rgba8.word == 187 << 12)
  #expect(TexelFormat.rgba8srgb.word == 187 << 12 | 1 << 20)
  #expect(TexelFormat.bgra8.word == 187 << 12 | 4)
  #expect(TexelFormat.bgra8srgb.word == 187 << 12 | 4 | 1 << 20)
  #expect(TexelFormat.r8.word == 163 << 12 | 16)
  // The raw clump format follows the texel's size.
  #expect(TexelFormat.rgba8.clump == 2 && TexelFormat.r8.clump == 0)
  // The family arithmetic of 05 section 5.2.2: group 160 (UNORM), N = 4, slot 3 is RGBA8 UNORM 187.
  #expect(160 + 8 * 3 + 3 == 187)
  #expect(TextureSwizzle.identity == 0x688)
}

// MARK: descriptors (03 sections 3.7 to 3.9)

@Test func aTextureDescriptorIsThe38Layout() throws {
  let image = ImageLayout(format: .rgba8, kind: .uInterleaved, width: 16, height: 16)
  let t = TextureDescriptor(image: image, surfaces: 0x0000_0001_0000_1000)
  let w = try t.words()
  #expect(w[0] == 2 | 2 << 4 | (187 << 12) << 10)
  #expect(w[1] == 15 | 15 << 16)
  #expect(w[2] == 0x688 | 1 << 12)
  #expect(w[3] == 0)
  #expect(w[4] == 0x1000 && w[5] == 1 && w[6] == 0 && w[7] == 0)
  // A linear layout does not set texel interleave; levels, layers and the maximum LOD follow the view.
  let lin = ImageLayout(format: .bgra8srgb, kind: .linear, width: 64, height: 32, levels: 3, layers: 4)
  let v = try TextureDescriptor(image: lin, surfaces: 0x2000).words()
  #expect(v[2] == 0x688 | 2 << 16)
  #expect(v[3] == UInt32(2 << 8) << 16)
  #expect(v[6] == 3)
  #expect(v[0] >> 10 == 187 << 12 | 4 | 1 << 20)
  #expect(throws: DescriptorError.misaligned) { try TextureDescriptor(image: lin, surfaces: 0x2010).words() }
  #expect(throws: DescriptorError.outOfRange) {
    try TextureDescriptor(format: .rgba8, width: 0, height: 1, layout: .linear, surfaces: 0).words()
  }
}

@Test func aPlaneDescriptorIsThe392Layout() throws {
  let image = ImageLayout(format: .rgba8, kind: .uInterleaved, width: 100, height: 70, levels: 2, layers: 2)
  let planes = image.planes(base: 0x0000_0002_0000_0000)
  // Layer slowest, then level (03 section 3.8.3).
  #expect(planes.count == 4)
  #expect(planes[1].address == 0x2_0000_0000 + 35840)
  #expect(planes[2].address == 0x2_0000_0000 + UInt64(image.arrayStride))
  let w = try planes[0].words()
  #expect(w[0] == 10 | 1 << 4 | 1 << 8 | 2 << 24)
  #expect(w[1] == 35840 && w[2] == 0 && w[3] == 2)
  #expect(w[4] == 7168 && w[5] == 0 && w[6] == 0)
  #expect(w[7] == 99 | 69 << 16)
  // A linear plane's clump ordering is 2.
  let lin = try ImageLayout(format: .r8, kind: .linear, width: 8, height: 8).planes(base: 0x1000)[0].words()
  #expect(lin[0] == 10 | 1 << 4 | 2 << 8 | 0 << 24)
  #expect(PlaneDescriptor.null.count == 8 && PlaneDescriptor.null[0] == 10)
}

@Test func aSamplerDescriptorIsThe37Layout() throws {
  let w = try SamplerWords.nearest.words()
  // Type 1; wrap clamp to edge (9) in R, T and S; seamless cube, normalised coordinates, clamp array indices;
  // both filters nearest, so no round to nearest even; mipmap mode None (1).
  #expect(w[0] == 1 | 9 << 8 | 9 << 12 | 9 << 16 | 1 << 23 | 1 << 25 | 1 << 26 | 1 << 27 | 1 << 28 | 1 << 30)
  #expect(w[1] == 0x1FFF << 16 && w[2] == 0 && w[3] == 0)
  let linear = try SamplerWords(wrapS: .repeat, wrapT: .mirroredRepeat, magFilter: .linear).words()
  #expect(linear[0] & (1 << 21) != 0, "round to nearest even unless both filters are nearest")
  #expect(linear[0] >> 16 & 15 == 8 && linear[0] >> 12 & 15 == 12)
  let b = try SamplerWords(wrapS: .clampToBorder, border: SamplerWords.borderWords(r: 1, g: 0.5, b: 0, a: 1)).words()
  #expect(b[4] == 0x3F80_0000 && b[5] == 0x3F00_0000 && b[6] == 0 && b[7] == 0x3F80_0000)
  #expect(throws: DescriptorError.outOfRange) { try SamplerWords(border: [0, 0]).words() }
}

@Test func theHeapIsATableOf32ByteDescriptors() throws {
  var heap = DescriptorHeap()
  let image = ImageLayout(format: .rgba8, kind: .uInterleaved, width: 16, height: 16)
  let t = heap.add(try TextureDescriptor(image: image, surfaces: 0x1000).words())
  let s = heap.add(try SamplerWords.nearest.words())
  #expect(t == 0 && s == 1 && heap.count == 2 && heap.byteSize == 64 && heap.bytes.count == 64)
  #expect(DescriptorHeap.handle(index: 5) == 0x0100_0005)
  let table = try DescriptorHeap.resourceTable(heapAddress: 0x4000, heapBytes: heap.byteSize)
  #expect(table.count == 64)
  var m = MemoryImage(size: 64)
  m.store(bytes: table, at: 0)
  // Entry 0 unused; entry 1 the heap with descriptors, 64 bytes.
  #expect(m.load64(at: 0) == 0 && m.load64(at: 8) == 0)
  #expect(m.load32(at: 16) == 0x4000 && m.load32(at: 20) == 1 << 24 && m.load32(at: 24) == 64)
}

@Test func theHandleFormsOf12b() {
  // Wide: word 0 the sampler's handle, word 1 the texture's.
  #expect(TextureHandle.wide(sampler: 0x0100_0003, texture: 0x0100_0007) == 0x0100_0007_0100_0003)
  // Packed: texture table [31:27], index [26:16], sampler table [15:11], index [10:0].
  #expect(TextureHandle.packed(textureTable: 1, textureIndex: 5, samplerTable: 1, samplerIndex: 2) == 1 << 27 | 5 << 16 | 1 << 11 | 2)
  #expect(TextureHandle.packed(textureTable: 12, textureIndex: 0, samplerTable: 0, samplerIndex: 0) == nil)
  #expect(TextureHandle.packed(textureTable: 1, textureIndex: 1024, samplerTable: 0, samplerIndex: 0) == nil)
}

// MARK: blend (09)

@Test func theStandardAlphaBlendIsExample2() throws {
  let d = try BlendDescriptor(state: BlendState(enabled: true, equation: .alpha), renderTarget: 0, isSRGB: true)
  #expect(d.mode == .fixedFunction)
  #expect(d.words == [0x0000_0E01, 0xF0D3_2503, 0x0000_001A, 0x001E_D000])
  // Without sRGB the words lose bits 10 and 20.
  let n = try BlendDescriptor(state: BlendState(enabled: true, equation: .alpha))
  #expect(n.words == [0x0000_0A01, 0xF0D3_2503, 0x0000_001A, 0x000E_D000])
}

@Test func theOpaqueDescriptorIsExample1() throws {
  #expect(BlendDescriptor(renderTarget: 0).words == [0x0000_0A00, 0xF012_2122, 0x0000_0019, 0x000E_D000])
  let d = try BlendDescriptor(state: .disabled)
  #expect(d.mode == .opaque && d.words == BlendDescriptor(renderTarget: 0).words)
  // ADD with ONE and ZERO and a full mask is opaque too (9.4.4).
  let s = try BlendDescriptor(state: BlendState(enabled: true, equation: .replace))
  #expect(s.mode == .opaque)
}

@Test func aPartialMaskReadsTheDestination() throws {
  let d = try BlendDescriptor(state: BlendState(enabled: false, writeMask: 0b0111))
  #expect(d.mode == .fixedFunction)
  #expect(d.words[0] & 1 == 1)
  #expect(d.words[1] == 0x7000_0000 | 0x122 << 12 | 0x122)
  #expect(d.words[2] & 3 == 2)
}

@Test func anEmptyMaskIsOff() throws {
  let d = try BlendDescriptor(state: BlendState(enabled: true, writeMask: 0))
  #expect(d.mode == .off)
  #expect(d.words == [0, 0, 3, 0])
}

@Test func premultipliedAlphaIsSourcePlusDestinationTimesOneMinusAlpha() throws {
  // Both functions: fs = ONE (row 2): A Src, B Dest, C Src alpha inverted = 0xD32.
  let d = try BlendDescriptor(state: BlendState(enabled: true, equation: .premultiplied))
  #expect(d.words[1] == 0xF000_0000 | 0xD32 << 12 | 0xD32)
  #expect(d.words[0] & 1 == 1, "the destination is read")
}

@Test func theSevenRearrangementsOfSection942() {
  func E(_ v: UInt32) -> UInt32? { v }
  func f(_ op: BlendOperation, _ s: BlendFactor, _ d: BlendFactor, alpha: Bool = false) -> UInt32? {
    BlendEquationEncoder.encode(operation: op, source: s, destination: d, alpha: alpha)
  }
  // Row 3 and example 3: ADD with CONSTANT_COLOR and ZERO: A Zero, B Src, C Constant = 0x721.
  #expect(f(.add, .constantColour, .zero) == E(0x721))
  // Row 1: ZERO + DST: A Zero, B Dest, C of fd; subtract negates B.
  #expect(f(.add, .zero, .srcColour) == E(1 | 3 << 4 | 2 << 8))
  #expect(f(.subtract, .zero, .srcColour) == E(1 | 3 << 4 | 1 << 7 | 2 << 8))
  // Row 2: fs ONE; reverse subtract negates A.
  #expect(f(.reverseSubtract, .one, .srcAlpha) == E(2 | 1 << 3 | 3 << 4 | 5 << 8))
  // Row 4: fd ONE, A Dest; subtract negates A, reverse subtract negates B.
  #expect(f(.add, .srcAlpha, .one) == E(3 | 2 << 4 | 5 << 8))
  #expect(f(.subtract, .srcAlpha, .one) == E(3 | 1 << 3 | 2 << 4 | 5 << 8))
  #expect(f(.reverseSubtract, .srcAlpha, .one) == E(3 | 2 << 4 | 1 << 7 | 5 << 8))
  // Row 5: the same factor and inversion: add Src plus Dest.
  #expect(f(.add, .srcColour, .srcColour) == E(1 | 1 << 4 | 2 << 8))
  #expect(f(.subtract, .srcColour, .srcColour) == E(1 | 0 << 4 | 2 << 8))
  #expect(f(.reverseSubtract, .srcColour, .srcColour) == E(1 | 0 << 4 | 1 << 7 | 2 << 8))
  // Row 6: twice source times destination.
  #expect(f(.add, .dstColour, .srcColour) == E(1 | 3 << 4 | 4 << 8))
  #expect(f(.add, .dstAlpha, .srcAlpha, alpha: true) == E(1 | 3 << 4 | 4 << 8))
  // Row 7: the same base factor, one inverted.
  #expect(f(.add, .srcAlpha, .oneMinusSrcAlpha) == E(0x503))
  #expect(f(.reverseSubtract, .srcAlpha, .oneMinusSrcAlpha) == E(3 | 1 << 4 | 1 << 7 | 5 << 8))
  #expect(f(.subtract, .srcAlpha, .oneMinusSrcAlpha) == E(3 | 1 << 3 | 1 << 4 | 5 << 8))
  // The alpha function takes a colour factor as its alpha variant.
  #expect(f(.add, .one, .oneMinusSrcColour, alpha: true) == E(0xD32))
  // Not expressible: minimum, maximum, the saturated source alpha, two different factors.
  #expect(f(.min, .one, .one) == nil && f(.max, .one, .one) == nil)
  #expect(f(.add, .srcAlphaSaturate, .one) == nil)
  #expect(f(.add, .srcColour, .dstColour) == nil)
}

@Test func theConstantIsOneScalarScaledTo8Bits() throws {
  // Example 3: constant 0.5 is trunc(0.5 * 65280) = 0x7F80 in word 0 [31:16].
  let e = BlendEquation(colourSource: .constantColour, colourDestination: .zero, alphaSource: .one, alphaDestination: .zero)
  let d = try BlendDescriptor(state: BlendState(enabled: true, equation: e, constant: [0.5, 0.5, 0.5, 0]))
  #expect(d.words[0] >> 16 == 0x7F80)
  #expect(d.words[1] & 0xFFF == 0x721)
  #expect(BlendEquationEncoder.constantWord(1) == 65280 && BlendEquationEncoder.constantWord(0) == 0)
  // Channels that differ need a blend shader.
  #expect(throws: BlendRefusal.self) {
    try BlendDescriptor(state: BlendState(enabled: true, equation: e, constant: [0.25, 0.5, 0.5, 0]))
  }
  // A second target's constant must equal the first's.
  #expect(throws: BlendRefusal.self) {
    try BlendDescriptor(state: BlendState(enabled: true, equation: e, constant: [1, 1, 1, 1]), firstConstant: 0x7F80)
  }
}

@Test func whatNeedsABlendShaderIsRefusedWithAReason() {
  func refusal(_ s: BlendState) -> String? {
    do throws(BlendRefusal) {
      _ = try BlendEquationEncoder.plan(s)
      return nil
    } catch {
      if case .needsBlendShader(let why) = error { return why }
      return nil
    }
  }
  #expect(refusal(BlendState(enabled: true, logicOperation: true))?.contains("logic") == true)
  #expect(refusal(BlendState(enabled: true, alphaToOne: true))?.contains("alpha to one") == true)
  let max = BlendEquation(
    colourOperation: .max, colourSource: .one, colourDestination: .one, alphaOperation: .max, alphaSource: .one, alphaDestination: .one)
  #expect(refusal(BlendState(enabled: true, equation: max))?.contains("colour equation") == true)
  let sat = BlendEquation(colourSource: .srcAlphaSaturate, colourDestination: .one, alphaSource: .one, alphaDestination: .one)
  #expect(refusal(BlendState(enabled: true, equation: sat)) != nil)
  #expect(refusal(.disabled) == nil)
  #expect(refusal(BlendState(enabled: true, equation: .alpha)) == nil)
}
