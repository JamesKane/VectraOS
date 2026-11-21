// SPDX-License-Identifier: BSD-3-Clause

// The framebuffer descriptors against valhall 08's field tables and worked
// examples: the tile-buffer budgeting (8.8.4, 8.8.6), the tagged pointer
// (8.1.3), the parameters block (8.2.1), the render target (8.4), the clear
// packing (8.7.2) and the linear layout (05 section 5.5.4).

import MaliCore
import Testing

// MARK: Tile budgeting (08 section 8.8.4's worked examples, G720)

@Test func theEffectiveTileSizeOfTheFourWorkedExamples() throws {
  let g = TileBuffer.g720
  // 1. One RGBA8, 1 sample: 64 x 64 tile, alloc 16384, field 16.
  let one = try #require(TilePlan.make(g, bytesPerSample: [4], samples: 1))
  #expect(one.tilePixels == 4096 && one.tileLog2 == 12 && one.tileWidth == 64 && one.tileHeight == 64)
  #expect(one.allocationBytes == 16384 && one.allocationField == 16 && one.offsets == [0])
  // 2. One RGBA8, 4 samples: 32 x 32, alloc 16384.
  let four = try #require(TilePlan.make(g, bytesPerSample: [4], samples: 4))
  #expect(four.tilePixels == 1024 && four.tileWidth == 32 && four.allocationBytes == 16384)
  // 3. RGBA8, RGBA8, RGBA16F, R32UI: 20 bytes a pixel, 1024-pixel tile, alloc 20480, offsets 0, 4096, 8192, 16384.
  let mixed = try #require(TilePlan.make(g, bytesPerSample: [4, 4, 8, 4], samples: 1))
  #expect(mixed.tilePixels == 1024 && mixed.allocationBytes == 20480 && mixed.allocationField == 20)
  #expect(mixed.offsets == [0, 4096, 8192, 16384])
  #expect(mixed.offsets.map { $0 >> 4 } == [0, 256, 512, 1024])
  // 4. Eight RGBA32F, 4 samples: 8 x 8 tile, alloc 32768.
  let eight = try #require(TilePlan.make(g, bytesPerSample: [Int](repeating: 16, count: 8), samples: 4))
  #expect(eight.tilePixels == 64 && eight.tileWidth == 8 && eight.tileHeight == 8 && eight.allocationBytes == 32768)
}

@Test func theG310ExampleDoublesATooSmallTile() throws {
  // 8.8.4: colour 16384, depth 8192, max 1024; eight RGBA32F at 8 samples: T0 = 8 doubles to 16, alloc 16384.
  let plan = try #require(TilePlan.make(.g310, bytesPerSample: [Int](repeating: 16, count: 8), samples: 8))
  #expect(plan.tilePixels == 16 && plan.allocationBytes == 16384)
}

@Test func aPassTheTileBufferCannotHoldHasNoPlan() {
  #expect(TilePlan.make(.g310, bytesPerSample: [Int](repeating: 16, count: 8), samples: 16) == nil)
  #expect(TilePlan.make(.g720, bytesPerSample: [4], samples: 3) == nil)
}

// MARK: Layout and clear

@Test func theLinearLayoutAlignsToSixtyFourBytes() {
  // 5.5.4's worked example: R8G8B8A8 100 x 70 is row stride 448 and surface stride 31 360.
  let l = LinearLayout(width: 100, height: 70, bytesPerPixel: 4)
  #expect(l.rowStride == 448 && l.surfaceStride == 31_360)
  let t = LinearLayout(width: 64, height: 64, bytesPerPixel: 4)
  #expect(t.rowStride == 256 && t.surfaceStride == 16384)
}

@Test func theClearWordFollowsSection872() {
  // Worked example 1: RGBA8 clear (0.5, 0.25, 1.0, 0.0): R = round_even(127.5) = 128, G = 64, B = 255, A = 0.
  #expect(ColourFormat.packedClear(red: 0.5, green: 0.25, blue: 1, alpha: 0) == 0x00FF_4080)
  // Opaque black and white, and values out of range clamped.
  #expect(ColourFormat.packedClear(red: 0, green: 0, blue: 0, alpha: 1) == 0xFF00_0000)
  #expect(ColourFormat.packedClear(red: 2, green: -1, blue: 1, alpha: 1) == 0xFFFF_00FF)
}

@Test func theSwizzleIsTheInversePermutationOfTheChannelOrder() {
  // 5.2.4: the identity is 0x688; BGRA swaps R and B (its own inverse).
  #expect(ColourFormat.rgba8.swizzle == 0x688)
  #expect(ColourFormat.bgra8.swizzle == 0x60A)
}

// MARK: Render target

@Test func theRenderTargetPacksTable841() throws {
  let rt = RenderTargetDescriptor(format: .rgba8, internalBufferOffset: 0, address: 0x20_0000, rowStride: 256,
                                  surfaceStride: 16384, clearWord: 0xFF00_0000)
  let w = try rt.words()
  #expect(w.count == 16)
  // Word 0: writeback mode 0, offset 0, internal format R8G8B8A8 (1) at [31:26].
  #expect(w[0] == 1 << 26)
  // Word 1: write enable, writeback format R8G8B8A8 (19) at [7:3], block format Linear (2) at [11:8], single sample,
  // no sRGB, dithering [15], the identity swizzle at [27:16], clean tile write [31].
  #expect(w[1] == 1 | 19 << 3 | 2 << 8 | 1 << 15 | 0x688 << 16 | 1 << 31)
  // Words 8 and 9: the base. Word 10: the row stride. Word 11: the surface stride.
  #expect(w[8] == 0x20_0000 && w[9] == 0 && w[10] == 256 && w[11] == 16384)
  // Words 12 to 15: the clear word four times. Everything else is zero.
  #expect(Array(w[12...15]) == [0xFF00_0000, 0xFF00_0000, 0xFF00_0000, 0xFF00_0000])
  for i in [2, 3, 4, 5, 6, 7] { #expect(w[i] == 0) }
  // A BGRA target differs only in the swizzle.
  var b = rt
  b.format = .bgra8
  #expect(try b.words()[1] == w[1] & ~(0xFFF << 16) | 0x60A << 16)
}

@Test func theSurfaceStrideSplitsAcrossWords10And11() throws {
  var rt = RenderTargetDescriptor(format: .rgba8, address: 0x4000, rowStride: 0x1_0000, surfaceStride: 0x3_0000_0040,
                                  clearWord: 0)
  let w = try rt.words()
  // The 37-bit surface stride: the low 32 bits in word 11, bits 36:32 in word 10 [31:27].
  #expect(w[11] == 0x0000_0040 && w[10] == 0x1_0000 | 3 << 27)
  rt.internalBufferOffset = 17
  #expect(throws: DescriptorError.outOfRange) { try rt.words() }
  rt.internalBufferOffset = 0
  rt.address = 0x4020
  #expect(throws: DescriptorError.misaligned) { try rt.words() }
}

// MARK: Framebuffer parameters

@Test func theFramebufferParametersPackTable821() throws {
  let fb = FramebufferParameters(width: 64, height: 64, sampleLocations: 0x10_0300, effectiveTileLog2: 12,
                                 colourAllocationKiB: 16, tiler: 0x10_0140)
  let w = try fb.words()
  #expect(w.count == 32)
  // Word 0: no frame shaders, layer 0. Word 1 zero. Words 2 and 3: the frame argument, zero.
  #expect(w[0] == 0 && w[1] == 0 && w[2] == 0 && w[3] == 0)
  #expect(w[4] == 0x10_0300 && w[5] == 0 && w[6] == 0 && w[7] == 0)
  // Word 8: size minus one; 9 and 10: the inclusive box, the whole frame.
  #expect(w[8] == 63 | 63 << 16 && w[9] == 0 && w[10] == 63 | 63 << 16)
  // Word 11: sample count 0, pattern 0, tie-break 2 [8:6], tile 12 [12:9], first provoking vertex [14], origin max Y
  // [15], one target, colour allocation 16 [31:24].
  #expect(w[11] == 2 << 6 | 12 << 9 | 1 << 14 | 1 << 15 | 16 << 24)
  // Word 12: Z internal format D24 for a pass with no depth attachment; word 13 the depth clear.
  #expect(w[12] == 1 << 16 && w[13] == 0)
  #expect(w[14] == 0x10_0140 && w[15] == 0)
  for i in 16..<32 { #expect(w[i] == 0) }
  #expect(fb.boundingBoxRegisters.min == 0 && fb.boundingBoxRegisters.max == 63 | 63 << 16)
}

@Test func theTieBreakIsTwoUnlessSixteenSamples() throws {
  var fb = FramebufferParameters(width: 8, height: 8, sampleLocations: 0, effectiveTileLog2: 6, colourAllocationKiB: 1, tiler: 0)
  #expect(fb.tieBreak == 2)
  fb.sampleCountLog2 = 4
  #expect(fb.tieBreak == 3)
  #expect(try fb.words()[11] & 7 == 4)
}

@Test func theFramebufferRefusesABoxOutsideTheFrameAndAMisalignedTiler() {
  var fb = FramebufferParameters(width: 64, height: 64, sampleLocations: 0, effectiveTileLog2: 12, colourAllocationKiB: 16, tiler: 0x1000)
  fb.boundMaxX = 64
  #expect(throws: DescriptorError.outOfRange) { try fb.words() }
  fb.boundMaxX = 63
  fb.tiler = 0x1020
  #expect(throws: DescriptorError.misaligned) { try fb.words() }
}

// MARK: Tagged pointer and group size (8.1)

@Test func theTaggedPointerIsTheWorkedExampleOfSection813() {
  // Group at 0x0000_1000_0000_0000, extension present, 2 targets: tag 1 + 2 + (1 << 2) = 7.
  #expect(FramebufferParameters.taggedPointer(address: 0x0000_1000_0000_0000, extensionPresent: true, renderTargetCount: 2)
    == 0x0000_1000_0000_0007)
  // No extension, one target: the tag is 1.
  #expect(FramebufferParameters.taggedPointer(address: 0x1000, extensionPresent: false, renderTargetCount: 1) == 0x1001)
}

@Test func theGroupSizeIsSection812s() {
  // Two targets, depth/stencil (extension), 4 layers: G = 128 + 64 + 128 = 320.
  #expect(FramebufferParameters.groupBytes(extensionPresent: true, renderTargetCount: 2) == 320)
  #expect(FramebufferParameters.groupBytes(extensionPresent: false, renderTargetCount: 1) == 192)
  #expect(RenderPass.groupBytes == 192)
}
