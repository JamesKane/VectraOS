// SPDX-License-Identifier: BSD-3-Clause

// AFBC images (valhall 05 section 5.11, 03 section 3.9.6, 08 sections 8.4.6 and 8.5.1) and the CRC tables of transaction
// elimination (08 section 8.6) against the specs' worked examples.

import MaliCore
import Testing

@Test func anAFBCLevelIsTheSpecsWorkedExample() {
  // 05 section 5.11.6, worked example 1: RGBA8, 16 x 16 sparse superblocks, linear headers, 100 x 70.
  let l = ImageLayout(format: .rgba8, kind: .afbc, width: 100, height: 70)
  let level = l.levels[0]
  #expect(level.rowStride == 112, "the header row stride")
  #expect(level.headerBytes == 560)
  #expect(level.bodyOffset == 640)
  #expect(level.surfaceStride == 36480, "header area through body")
  #expect(l.afbcYTR, "four colour components: the transform")
  #expect(!ImageLayout(format: .depth32f, kind: .afbc, width: 100, height: 70).afbcYTR, "never for depth")
  #expect(ImageLayoutKind.afbc.blockFormat == 12)
}

@Test func anAFBCPlaneIsType6WithTheModeAndTheHeaderArea() throws {
  let l = ImageLayout(format: .rgba8, kind: .afbc, width: 100, height: 70)
  let p = l.planes(base: 0x10_0000)[0]
  let w = try p.words()
  // Type 10, plane type 6, superblock 16 x 16, YTR [16], prefetch [20], mode R8G8B8A8 (10) at [31:26].
  #expect(w[0] == 10 | 6 << 4 | 1 << 16 | 1 << 20 | 10 << 26)
  #expect(w[1] == 36480 && w[2] == 0x10_0000 && w[4] == 112 && w[5] == 560 && w[6] == 0)
  #expect(w[7] == 99 | 69 << 16)
  // 16-bit depth is mode R8G8, no transform.
  let d = try ImageLayout(format: .depth16, kind: .afbc, width: 32, height: 32).planes(base: 0)[0].words()
  #expect(d[0] == 10 | 6 << 4 | 1 << 20 | 3 << 26)
}

@Test func anAFBCRenderTargetNamesItsHeaderRowStrideAndBody() throws {
  var t = RenderTargetDescriptor(format: .rgba8, address: 0x20_0000, rowStride: 112, surfaceStride: 640, clearWord: 0)
  t.blockFormat = 12
  t.afbcMode = 10
  t.afbcYTR = true
  t.reverseIssueOrder = true
  let w = try t.words()
  #expect(w[1] >> 8 & 0xF == 12, "block format AFBC")
  #expect(w[2] == 1 | 1 << 3 | 10 << 10, "YTR, reverse issue order, mode")
  #expect(w[8] == 0x20_0000 && w[10] == 112 && w[11] == 640, "header, header row stride, body offset")
  var z = ZSTarget(depthFormat: .d32f, hasStencil: false)
  z.depthAddress = 0x30_0000
  z.depthRowStride = 112
  z.depthSurfaceStride = 640
  z.depthAFBC = true
  z.reverseIssueOrder = true
  let e = try z.words()
  #expect(e[0] & 0xF == 14 && e[0] >> 4 & 0xF == 12 && e[0] >> 30 & 1 == 1, "D32, block format AFBC, reverse issue order")
  #expect(e[8] == 0x30_0000 && e[10] == 112 && e[11] == 640)
}

@Test func aCRCTableIsTheSpecsWorkedExamples() {
  // 08 section 8.6.1, arch 12 (a prefetch region of 64 pixels).
  #expect(CRCTable.size(width: 1920, height: 1080) == (960, 65280))
  #expect(CRCTable.size(width: 130, height: 70) == (128, 1024))
  let word = CRCTable.emptyWord(clears: [[1, 1, 1, 1]], counter: 7)
  #expect(word & 0xFFFF == 7 && word >> 63 == 0 && word >> 62 & 1 == 1, "the counter, bit 63 clear, the signature's bit 46")
  let t = CRCTable(address: 0x40_0040, rowStride: 128, counter: 7)
  let w = t.words(emptyWord: word)
  #expect(w[0] == 0 && w[1] == 128 && w[4] == 0x40_0040 && UInt64(w[2]) | UInt64(w[3]) << 32 == word)
  var f = FramebufferParameters(width: 64, height: 64, sampleCountLog2: 0, samplePattern: 0, sampleLocations: 0, effectiveTileLog2: 8,
                                colourAllocationKiB: 1, tiler: 0)
  f.crc = true
  let fw = try? f.words()
  #expect(fw.map { $0[12] >> 21 & 1 == 1 && $0[12] >> 28 == 0xE } == true, "the extension, empty tile write, CRC read and write")
}
