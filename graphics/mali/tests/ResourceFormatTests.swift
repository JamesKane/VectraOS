// SPDX-License-Identifier: BSD-3-Clause

// The resources' descriptors against valhall 03 and 05: the texel format table (05 section 5.3), compressed and depth planes, the
// layout of volumes and block formats (05 section 5.5), the sampler's compare, anisotropy and bias fields (03 section 3.7).

import MaliCore
import Testing

@Test func theNumericFamiliesGiveTheIndicesOfTheTable() {
  // index = group + 8 * (N - 1) + slot: group UNORM 160, SNORM 96, UINT 128, SINT or F16 192; slot 3 is 8 bits, 4 is 16, 5 is 32, 7 float.
  #expect(TexelFormat.rg8.index == 160 + 8 * 1 + 3)
  #expect(TexelFormat.rgba8snorm.index == 96 + 8 * 3 + 3)
  #expect(TexelFormat.rg16ui.index == 128 + 8 * 1 + 4)
  #expect(TexelFormat.rgba32i.index == 192 + 8 * 3 + 5)
  #expect(TexelFormat.rgba16f.index == 192 + 8 * 3 + 7)
  #expect(TexelFormat.r32f.index == 160 + 7)
  #expect(TexelFormat.rgba32f.index == 160 + 8 * 3 + 7)
  // One and two component formats read (R, 0, 0, 1) and (R, G, 0, 1): order RGB1 (16).
  #expect(TexelFormat.rg8.order == 16 && TexelFormat.r16f.order == 16 && TexelFormat.rgba16f.order == 0)
  #expect(TexelFormat.rgb10a2.index == 67 && TexelFormat.rg11b10f.index == 89 && TexelFormat.rgb9e5.index == 91)
}

@Test func theTexelSizeChoosesTheRawClump() {
  #expect(TexelFormat.rg8.clump == 1 && TexelFormat.rg16f.clump == 2 && TexelFormat.rgba16f.clump == 3 && TexelFormat.rgba32f.clump == 4)
  #expect(TexelFormat.rg32f.clump == 3 && TexelFormat.r32f.clump == 2)
}

@Test func depthAndStencilPlanesAreOneAspectEach() {
  // 05 section 5.3.2: Z16 75, Z32 76, Z24X8 77 in 32 bits; stencil is S8 93 with order GRBA (2) and its own clump format (22).
  #expect(TexelFormat.depth16.index == 75 && TexelFormat.depth16.clump == 1)
  #expect(TexelFormat.depth32f.index == 76 && TexelFormat.depth32f.clump == 2)
  #expect(TexelFormat.depth24.index == 77 && TexelFormat.depth24.clump == 2)
  #expect(TexelFormat.stencil8.index == 93 && TexelFormat.stencil8.order == 2 && TexelFormat.stencil8.clump == 22)
  #expect(TexelFormat.stencil8.word == 93 << 12 | 2)
}

@Test func compressedFormatsAreBlocksOfTheirOwnClumps() {
  // 05 section 5.3.4: ETC2 RGB8 is the decoded RGBA8 (187) in order RGB1 and the ETC2 RGB8 clump (32); 8 bytes of 4 by 4 texels.
  let etc = TexelFormat.etc2rgb8
  #expect(etc.index == 187 && etc.order == 16 && etc.clump == 32 && etc.bytesPerTexel == 8 && etc.blockWidth == 4 && etc.blockHeight == 4)
  #expect(TexelFormat.etc2rgb8srgb.word == TexelFormat.etc2rgb8.word | 1 << 20)
  #expect(TexelFormat.eacR11.index == 164 && TexelFormat.eacR11snorm.index == 100 && TexelFormat.eacRG11.index == 172)
  #expect(TexelFormat.bc1rgba.clump == 48 && TexelFormat.bc7.clump == 57 && TexelFormat.bc6hu.index == 223)
  // ASTC LDR linear decodes to 16-bit floats (223), sRGB to 8 bits (187 with the sRGB bit).
  #expect(TexelFormat.astc(blockWidth: 6, blockHeight: 5, srgb: false).index == 223)
  #expect(TexelFormat.astc(blockWidth: 6, blockHeight: 5, srgb: true).word == 187 << 12 | 1 << 20)
}

@Test func anASTCPlaneIsOfTypeFourWithItsBlockAndDecodeMode() throws {
  let l = ImageLayout(format: .astc(blockWidth: 8, blockHeight: 5, srgb: false), kind: .linear, width: 16, height: 10)
  let words = try l.planes(base: 0x1000)[0].words()
  // type 10 [3:0], plane type 4 [7:4], clump ordering linear 2, decode wide [25], block width 8 is code 4 [28:26], height 5 is code 1 [31:29].
  #expect(words[0] == 10 | 4 << 4 | 2 << 8 | 1 << 25 | 4 << 26 | 1 << 29)
  let s = try ImageLayout(format: .astc(blockWidth: 4, blockHeight: 4, srgb: true), kind: .linear, width: 8, height: 8).planes(base: 0)[0].words()
  #expect(s[0] >> 25 & 1 == 0)
  #expect(ASTCPlaneFields.code(7) == nil && ASTCPlaneFields.code(12) == 7 && ASTCPlaneFields.code(10) == 6)
}

@Test func aBlockFormatsLevelsAreInBlocks() {
  // 100 by 70 texels of ASTC 4x4: 25 by 18 blocks of 16 bytes; rows align to 64: 400 to 448.
  let l = ImageLayout(format: .astc(blockWidth: 4, blockHeight: 4, srgb: false), kind: .linear, width: 100, height: 70, levels: 2)
  #expect(l.levels[0].surfaceStride == 448 * 18)
  #expect(l.levels[0].rowStride == 448)
  // Level 1 is 50 by 35 texels: 13 by 9 blocks: 208 bytes a row, aligned to 256.
  #expect(l.levels[1].rowStride == 256)
  // The block at texel (8, 4) of level 0 is block (2, 1).
  #expect(l.texelOffset(x: 8, y: 4) == 448 + 2 * 16)
  // ETC2 RGB8: 8 by 8 texels are 2 by 2 blocks of 8 bytes.
  let e = ImageLayout(format: .etc2rgb8, kind: .linear, width: 8, height: 8)
  #expect(e.levels[0].rowStride == 64 && e.levels[0].surfaceStride == 128)
}

@Test func aVolumeHasASurfacePerSliceAndHalvesItsDepth() throws {
  let l = ImageLayout(format: .rgba8, kind: .linear, width: 8, height: 8, depth: 4, levels: 3)
  // Level 0: 8x8x4, 256-byte rows of 32 bytes aligned to 64: row 64, surface 64 * 8 = 512, four slices.
  #expect(l.levels[0].rowStride == 64 && l.levels[0].surfaceStride == 512 && l.levels[0].depth == 4 && l.levels[0].levelSize == 2048)
  #expect(l.levels[1].depth == 2 && l.levels[1].offset == 2048)
  #expect(l.levels[2].depth == 1)
  #expect(l.texelOffset(x: 1, y: 2, z: 3) == 3 * 512 + 2 * 64 + 4)
  // A 3D view has one layer of entries, each the level's first slice with the slice stride (03 section 3.9.3).
  let planes = l.planes(base: 0x10000)
  #expect(planes.count == 3)
  #expect(planes[0].sliceStride == 512 && planes[0].size == 2048)
  let words = try planes[0].words()
  #expect(words[6] == 512)
}

@Test func aViewOfLevelsAndLayersHasTheEntriesItCovers() {
  let l = ImageLayout(format: .rgba8, kind: .linear, width: 16, height: 16, levels: 4, layers: 3)
  // Layer slowest, then level: layers 1 and 2, levels 1 to 2 are four entries.
  let planes = l.planes(base: 0, levels: 1..<3, layers: 1..<3)
  #expect(planes.count == 4)
  #expect(planes[0].address == UInt64(l.arrayStride + l.levels[1].offset))
  #expect(planes[1].address == UInt64(l.arrayStride + l.levels[2].offset))
  #expect(planes[2].address == UInt64(2 * l.arrayStride + l.levels[1].offset))
  #expect(planes[0].width == 8 && planes[1].width == 4)
}

@Test func theSamplerCarriesItsCompareAnisotropyAndBias() throws {
  var s = SamplerWords(minFilter: .nearest, magFilter: .linear, mipmap: .trilinear, lodBias: -256)
  s.compare = 4
  s.maxAnisotropy = 8
  let w = try s.words()
  // Word 0: minify nearest [27] set, magnify nearest [28] clear, mipmap mode trilinear [31:30] = 3.
  #expect(w[0] >> 27 & 1 == 1 && w[0] >> 28 & 1 == 0 && w[0] >> 30 == 3)
  // Word 1: compare function [15:13]; word 2: bias [15:0], maximum anisotropy minus one [20:16], the anisotropic algorithm 3 [25:24].
  #expect(w[1] >> 13 & 7 == 4)
  #expect(w[2] & 0xFFFF == 0xFF00 && w[2] >> 16 & 0x1F == 7 && w[2] >> 24 & 3 == 3)
  // Without anisotropy the algorithm is isotropic.
  let plain = try SamplerWords().words()
  #expect(plain[2] >> 24 & 3 == 0 && plain[2] >> 16 & 0x1F == 0)
  var bad = SamplerWords()
  bad.maxAnisotropy = 33
  #expect(throws: DescriptorError.self) { try bad.words() }
}

@Test func theBorderColourIsTheFourWordsGiven() throws {
  let w = try SamplerWords(wrapS: .clampToBorder, wrapT: .clampToBorder, wrapR: .clampToBorder, border: SamplerWords.borderWords(r: 0.25, g: 0.5, b: 0.75, a: 1)).words()
  #expect(w[4] == Float(0.25).bitPattern && w[7] == Float(1).bitPattern)
  #expect(w[0] >> 16 & 15 == 11 && w[0] >> 12 & 15 == 11 && w[0] >> 8 & 15 == 11)
}

@Test func aTexturesMaximumLevelOfDetailIsTheLastLevelUnlessSaid() throws {
  var d = TextureDescriptor(format: .rgba8, width: 4, height: 4, layout: .linear, levels: 3, surfaces: 0x40)
  #expect(try d.words()[3] >> 16 == 2 << 8)
  d.levels = 1
  d.maxLOD = 256
  #expect(try d.words()[3] >> 16 == 256)
}
