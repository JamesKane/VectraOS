// SPDX-License-Identifier: BSD-3-Clause

// The tiler's descriptors against valhall 07's field tables and worked examples:
// the context (7.2), the heap descriptor (7.4), the hierarchy mask and its bin
// pointer memory (7.6.2 to 7.6.4) and the sample position table (7.9).

import MaliCore
import Testing

// MARK: Tiler context

@Test func theTilerContextPacksItsWordsAsTable72Has() throws {
  let c = TilerContext(
    hierarchyMask: 0xAC, samplePattern: 2, firstProvokingVertex: true, effectiveTileLog2: 12, width: 64, height: 64,
    heap: 0x10_0200, geometryBuffer: 0x50_0000)
  let w = try c.words()
  #expect(w.count == 32)
  // Word 2: mask [12:0], pattern [15:13], first provoking vertex [18], tile size [23:20].
  #expect(w[2] == 0xAC | 2 << 13 | 1 << 18 | 12 << 20)
  // Word 3: width and height minus one.
  #expect(w[3] == 63 | 63 << 16)
  // Word 4: layer count minus one, offset 0. Word 5 reserved.
  #expect(w[4] == 0 && w[5] == 0)
  // Words 6 and 7: the heap; words 8 and 9: the geometry buffer with its size in 4 KiB units (16 = 64 KiB).
  #expect(w[6] == 0x10_0200 && w[7] == 0)
  #expect(w[8] == 0x50_0010 && w[9] == 0)
  // The polygon list, the completed pointers (words 10 to 13), the reserved words and the private state are zero.
  #expect(w[0] == 0 && w[1] == 0)
  for i in 10..<32 { #expect(w[i] == 0, "word \(i)") }
  // The completed top and bottom are at byte 40 and 48, which 7.10 says FINISH_FRAGMENT loads.
  #expect(TilerContext.completedOffset == 40 && TilerContext.size == 128 && TilerContext.alignment == 64)
}

@Test func theLayerFieldsAreCountMinusOneAndANineBitSignedOffset() throws {
  var c = TilerContext(effectiveTileLog2: 8, width: 100, height: 70, layerCount: 8, layerOffset: -8,
                       heap: 0x1000, geometryBuffer: 0x2000)
  // 7.8: 8 layers is 7; the offset of the second context of a layered pass is -(8 k) as nine bits: -8 is 0x1F8.
  #expect(try c.words()[4] == 7 | 0x1F8 << 8)
  c.layerOffset = 0
  c.layerCount = 1
  #expect(try c.words()[4] == 0)
  c.layerCount = 9
  #expect(throws: DescriptorError.outOfRange) { try c.words() }
}

@Test func theTilerContextRefusesWhatItCannotEncode() {
  let ok = TilerContext(effectiveTileLog2: 12, width: 64, height: 64, heap: 0x1000, geometryBuffer: 0x2000)
  var c = ok
  c.heap = 0x1008
  #expect(throws: DescriptorError.misaligned) { try c.words() }
  c = ok
  c.geometryBuffer = 0x2800
  #expect(throws: DescriptorError.misaligned) { try c.words() }
  c = ok
  c.effectiveTileLog2 = 13
  #expect(throws: DescriptorError.outOfRange) { try c.words() }
  c = ok
  c.geometryUnits = 4096
  #expect(throws: DescriptorError.outOfRange) { try c.words() }
  c = ok
  c.width = 65537
  #expect(throws: DescriptorError.outOfRange) { try c.words() }
}

// MARK: Heap descriptor

@Test func theHeapDescriptorIsABufferDescriptorOfTypeNineAndBufferTypeTwo() throws {
  let h = TilerHeapDescriptor(chunkBytes: 1 << 20, firstChunk: 0x4_0040_0000)
  let w = try h.words()
  // 7.4: type 9, buffer type 2; the size; the base; bottom = base + 64; top = base + size.
  #expect(w == [0x29, 0x10_0000, 0x0040_0000, 0x4, 0x0040_0040, 0x4, 0x0050_0000, 0x4])
  #expect(TilerHeapDescriptor.size == 32 && TilerHeapDescriptor.alignment == 32)
  #expect(throws: DescriptorError.misaligned) { try TilerHeapDescriptor(chunkBytes: 4096, firstChunk: 0x1800).words() }
  #expect(throws: DescriptorError.outOfRange) { try TilerHeapDescriptor(chunkBytes: 5000, firstChunk: 0x1000).words() }
}

@Test func aChunkReferenceCarriesItsSizeInFourKiBUnits() {
  // panthor 08 section 8.3.3's example: a 2 MiB chunk at 0x7F_FE40_0000 is 0x7F_FE40_0200.
  #expect(TilerHeapDescriptor.chunkReference(address: 0x7F_FE40_0000, chunkBytes: 2 << 20) == 0x7F_FE40_0200)
}

// MARK: Hierarchy mask (07 sections 7.6.2 to 7.6.4)

@Test func binsPerLevelAreCeilDivisions() {
  // Example A's table: 1920 x 1080 at levels 1, 3, 5 and 7.
  #expect(HierarchyMask.bins(level: 1, width: 1920, height: 1080) == 60 * 34)
  #expect(HierarchyMask.bins(level: 3, width: 1920, height: 1080) == 15 * 9)
  #expect(HierarchyMask.bins(level: 5, width: 1920, height: 1080) == 4 * 3)
  #expect(HierarchyMask.bins(level: 7, width: 1920, height: 1080) == 1)
}

@Test func exampleAPicksTheAutomaticMask() {
  // 1920 x 1080, T = 1024, a 2 MiB chunk: the automatic 0xAA estimates 2192 * 16 = 35 072 bytes, below 2 097 088.
  #expect(HierarchyMask.estimateMask(0, tilePixels: 1024, arch: 12) == 0xAA)
  #expect(HierarchyMask.estimateBytes(mask: 0, width: 1920, height: 1080, tilePixels: 1024, arch: 12) == 35_072)
  #expect(HierarchyMask.select(width: 1920, height: 1080, tilePixels: 1024, maxLevels: 8, chunkBytes: 2 << 20) == 0)
}

@Test func exampleBDropsTheFinestLevelsDownToMaskOneE0() {
  // 4096 x 4096, T = 1024, the minimum chunk 128 KiB (budget 131 008), M = 8.
  #expect(HierarchyMask.estimateBytes(mask: 0, width: 4096, height: 4096, tilePixels: 1024, arch: 12) == 279_680)
  #expect(HierarchyMask.estimateBytes(mask: 0x1FE, width: 4096, height: 4096, tilePixels: 1024, arch: 12) == 279_680)
  #expect(HierarchyMask.estimateBytes(mask: 0x1E0, width: 4096, height: 4096, tilePixels: 1024, arch: 12) == 1408)
  #expect(HierarchyMask.select(width: 4096, height: 4096, tilePixels: 1024, maxLevels: 8, chunkBytes: 128 << 10) == 0x1E0)
}

@Test func theAutomaticMaskForALargeTileIsTheCoarserOne() {
  // 7.6.1: a tile over 1024 pixels gets 0xAC (levels 2, 3, 5 and 7: 64, 128, 512 and 2048 px).
  #expect(HierarchyMask.estimateMask(0, tilePixels: 4096, arch: 12) == 0xAC)
  // A mask of more than four bits is replaced by it for the estimate; a smaller mask is its own.
  #expect(HierarchyMask.estimateMask(0x1FE, tilePixels: 1024, arch: 12) == 0xAA)
  #expect(HierarchyMask.estimateMask(0x82, tilePixels: 1024, arch: 12) == 0x82)
  // Before arch 12 the mask is its own and the pointer is 8 bytes.
  #expect(HierarchyMask.estimateMask(0, tilePixels: 1024, arch: 11) == 0)
  // The pass the board draws: 64 x 64, T = 4096: 1 + 1 + 1 + 1 bins = 4, rounded to 8, times 16.
  #expect(HierarchyMask.estimateBytes(mask: 0, width: 64, height: 64, tilePixels: 4096, arch: 12) == 128)
  #expect(HierarchyMask.select(width: 64, height: 64, tilePixels: 4096, maxLevels: 4, chunkBytes: 1 << 20) == 0)
}

@Test func theStartMaskTableOfStepThree() {
  // M = 4 for a 4096 x 4096 target with a tiny budget: the start mask is 0xAA, shifted by top - 8 = 1 (top 9),
  // and the finest levels are dropped until it fits. The result keeps only coarse levels or is refused.
  let m = HierarchyMask.select(width: 4096, height: 4096, tilePixels: 1024, maxLevels: 4, chunkBytes: 128 << 10)
  #expect(m != nil)
  if let m {
    #expect(HierarchyMask.estimateBytes(mask: m, width: 4096, height: 4096, tilePixels: 1024, arch: 12) < (128 << 10) - 64)
  }
}

// MARK: Sizing

@Test func theSmallPassHeapIsFarAboveWhatOneTriangleNeeds() {
  // 1 MiB against the 64-byte header and the 128 bytes of bin pointers of a 64 x 64 target.
  #expect(TilerHeapSizing.smallPassChunkBytes == 1 << 20)
  #expect(TilerHeapSizing.binTableBytes(width: 64, height: 64, tilePixels: 4096) == 128 + 64)
  #expect(TilerHeapSizing.binTableBytes(width: 1920, height: 1080, tilePixels: 1024) == 35_072 + 64)
  #expect(TilerHeapSizing.smallPassChunkBytes >= 128 << 10)
}

// MARK: Sample positions (07 section 7.9)

@Test func theSamplePatternsFollowTheSampleCount() {
  #expect(SamplePatterns.pattern(samples: 1) == 0 && SamplePatterns.pattern(samples: 2) == 5)
  #expect(SamplePatterns.pattern(samples: 4) == 2 && SamplePatterns.pattern(samples: 8) == 3)
  #expect(SamplePatterns.pattern(samples: 16) == 4 && SamplePatterns.pattern(samples: 3) == nil)
}

@Test func theSampleTableHasOneBlockPerPatternWithItsOrigin() {
  let t = SamplePatterns.table()
  #expect(t.count == 1536)
  func u16(_ at: Int) -> Int { Int(t[at]) | Int(t[at + 1]) << 8 }
  // Single: sample 0 is the pixel centre, 128/256 on each axis.
  #expect(u16(0) == 128 && u16(2) == 128)
  // Rotated 4x (pattern 2, block at 512): sample 0 is (-2, -6) sixteenths: 128 - 32 and 128 - 96.
  #expect(u16(512) == 96 && u16(514) == 32)
  // Rotated 2x (pattern 5, block at 1280): (4, 4) then (-4, -4).
  #expect(u16(1280) == 192 && u16(1282) == 192 && u16(1284) == 64 && u16(1286) == 64)
  // D3D 16x (pattern 4, block at 1024): sixteen positions; the 16th is (-7, -8): 16 and 0.
  #expect(u16(1024 + 4 * 15) == 16 && u16(1024 + 4 * 15 + 2) == 0)
  // The origin at byte 128 of every block; 132 to 255 zero.
  for p in 0..<6 {
    #expect(u16(256 * p + 128) == 128 && u16(256 * p + 130) == 128)
    for i in 132..<256 { #expect(t[256 * p + i] == 0) }
  }
  // Single has only one position: the second is zero.
  #expect(u16(4) == 0 && u16(6) == 0)
  #expect(SamplePatterns.offsets(pattern: SamplePatterns.d3d8x).count == 8)
}
