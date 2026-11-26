// SPDX-License-Identifier: BSD-3-Clause

// The fixed-function state of a draw against valhall 06 (6.4 to 6.10), 08 (8.2.1, 8.5) and 09: the depth/stencil descriptor
// with the test on, the depth and stencil target's parameters word and extension, the early and late decision's worked
// examples, the viewport's rectangle, and the primitive modes' numbers.

import MaliCore
import Testing

@Test func theDepthStencilDescriptorWithTheTestOnHasTheSpecsFields() {
  var z = ZSDescriptorState()
  z.depthFunction = 1  // less
  z.depthWrite = true
  // Depth only: word 0 is the type alone, word 4 has cull enable [22], clamp mode 1 [24:23], fixed-function source [26:25],
  // write [27] and the function [31:29].
  #expect(z.words == [7, 0, 0, 0, 1 << 22 | 1 << 23 | 2 << 25 | 1 << 27 | 1 << 29, 0, 0, 0])
  z.stencilTest = true
  z.front.function = 2
  z.front.failOperation = 1
  z.front.depthFailOperation = 2
  z.front.passOperation = 3
  z.back.function = 5
  z.back.failOperation = 4
  z.back.depthFailOperation = 6
  z.back.passOperation = 7
  z.front.writeMask = 0x0F
  z.back.writeMask = 0xF0
  z.front.compareMask = 0x3C
  z.back.compareMask = 0xC3
  z.front.reference = 5
  z.back.reference = 9
  let w = z.words
  #expect(w[0] == 7 | 2 << 4 | 1 << 7 | 2 << 10 | 3 << 13 | 5 << 16 | 4 << 19 | 6 << 22 | 7 << 25 | 1 << 31)
  #expect(w[1] == 0x0F | 0xF0 << 8 | 0x3C << 16 | 0xC3 << 24)
  #expect(w[2] == 5 | 9 << 8)
}

@Test func theBiasClampAndClipOfTheDepthDescriptor() {
  var z = ZSDescriptorState()
  z.depthBias = true
  z.biasConstant = -2
  z.biasSlope = 0.5
  z.biasClamp = 0.25
  z.depthClip = false
  z.clampToViewport = true
  let w = z.words
  #expect(w[4] & 1 << 22 == 0, "clip off")
  #expect(w[4] >> 23 & 3 == 2, "clamp to the viewport's range")
  #expect(w[4] & 1 << 28 != 0)
  #expect(w[5] == Float(-2).bitPattern && w[6] == Float(0.5).bitPattern && w[7] == Float(0.25).bitPattern)
  z.depthBias = false
  #expect(z.words[5] == 0 && z.words[4] & 1 << 28 == 0)
  #expect(z.words[4] >> 25 & 3 == 2, "the depth comes from the fixed function")
  z.depthFromShader = true
  #expect(z.words[4] >> 25 & 3 == 3, "or from the fragment shader (6.8.3)")
}

@Test func aStencilOnlyTargetHasTheStencilRecordAndD24InTheParameters() throws {
  var t = ZSTarget(depthFormat: nil, hasStencil: true)
  t.stencilAddress = 0x1_0000
  t.stencilRowStride = 64
  t.stencilSurfaceStride = 64 * 32
  t.clearStencil = 0x5A
  // Word 12: stencil clear [7:0], stencil write [8], Z internal format D24 (1) [17:16], extension [21].
  #expect(t.word12 == 0x5A | 1 << 8 | 1 << 16 | 1 << 21)
  let w = try t.words()
  #expect(w[0] == 1 << 16 | 2 << 20 | 1 << 31, "S8 write format, linear block format, clean tile write")
  #expect(w[12] == 0x1_0000 && w[13] == 0 && w[14] == 64 && w[15] == 64 * 32)
  #expect(w[8] == 0 && w[10] == 0, "no depth record: no write")
}

@Test func aDepthTargetHasItsWriteFormatInternalFormatAndClear() throws {
  for (format, write, internalFormat) in [(DepthFormat.d16, UInt32(1), UInt32(0)), (.d24, 4, 1), (.d32f, 14, 2)] {
    var t = ZSTarget(depthFormat: format, hasStencil: false)
    t.depthAddress = 0x2_0000
    t.depthRowStride = 128
    t.depthSurfaceStride = 128 * 16
    t.clearDepth = 0.25
    #expect(t.word12 == internalFormat << 16 | 1 << 18 | 1 << 21)
    let w = try t.words()
    #expect(w[0] == write | 2 << 4 | 1 << 31)
    #expect(w[8] == 0x2_0000 && w[10] == 128 && w[11] == 128 * 16)
  }
  // A target the pass doesn't store: the extension has no write.
  var kept = ZSTarget(depthFormat: .d32f, hasStencil: false)
  kept.clearDepth = 1
  #expect(try kept.words() == [UInt32](repeating: 0, count: 16))
  #expect(kept.word12 == 2 << 16 | 1 << 21)
  var bad = kept
  bad.depthAddress = 0x2_0010
  bad.depthRowStride = 64
  #expect(throws: DescriptorError.self) { _ = try bad.words() }
}

@Test func theFramebufferParametersCarryTheDepthTargetsClearsAndTheGroupGrows() throws {
  var fbd = FramebufferParameters(width: 64, height: 64, sampleLocations: 0x1000, effectiveTileLog2: 8, colourAllocationKiB: 16,
                                  tiler: 0x4000)
  #expect(try fbd.words()[12] == 1 << 16, "no depth: D24, no extension")
  var t = ZSTarget(depthFormat: .d32f, hasStencil: true)
  t.depthAddress = 0x2_0000
  t.depthRowStride = 256
  t.depthSurfaceStride = 256 * 64
  t.stencilAddress = 0x3_0000
  t.stencilRowStride = 64
  t.stencilSurfaceStride = 64 * 64
  t.clearDepth = 0.5
  t.clearStencil = 7
  fbd.zs = t
  let w = try fbd.words()
  #expect(w[12] == 7 | 1 << 8 | 2 << 16 | 1 << 18 | 1 << 21)
  #expect(w[13] == Float(0.5).bitPattern)
  #expect(FramebufferParameters.groupBytes(extensionPresent: true, renderTargetCount: 1) == 256)
  #expect(FramebufferParameters.taggedPointer(address: 0x1000, extensionPresent: true, renderTargetCount: 1) == 0x1003)
}

@Test func theEarlyAndLateDecisionMatchesTheWorkedExamples() {
  func ops(sw: Bool, wzo: Bool, ac: Bool = false, lc: Bool, se: Bool, pass: Bool) -> (PixelOperation, PixelOperation) {
    let r = PixelOperations.derive(sw: sw, wzo: wzo, ac: ac, lc: lc, se: se, eft: false, pass: pass)
    return (r.update, r.kill)
  }
  // 6.10.2 (arch 12): an opaque shader, depth write and test: force early both.
  #expect(ops(sw: false, wzo: true, lc: false, se: false, pass: false) == (.forceEarly, .forceEarly))
  // The same shader can discard: late update, early kill.
  #expect(ops(sw: false, wzo: true, lc: true, se: false, pass: false) == (.forceLate, .forceEarly))
  // No depth test and no query, a plain shader: early update, weak early kill.
  #expect(ops(sw: false, wzo: false, lc: false, se: false, pass: true) == (.forceEarly, .weakEarly))
  // A shader that writes depth: late both.
  #expect(ops(sw: true, wzo: true, lc: false, se: false, pass: false) == (.forceLate, .forceLate))
  // A shader that stores to memory with the depth test on: early update, late kill.
  #expect(ops(sw: false, wzo: true, lc: false, se: true, pass: false) == (.forceEarly, .forceLate))
  // Alpha to coverage forces a late update (and `lc`).
  #expect(ops(sw: false, wzo: false, ac: true, lc: true, se: false, pass: true).0 == .forceLate)
  // Declared early tests override the late flags.
  let e = PixelOperations.derive(sw: true, wzo: true, ac: false, lc: true, se: true, eft: true, pass: false)
  #expect(e.update == .forceEarly && e.kill == .forceEarly)
}

@Test func aViewportsRectangleIsTruncatedClampedAndOrdered() {
  let v = DrawViewport(x: 8, y: 4, width: 16, height: 10)
  let b = v.box(width: 32, height: 32)
  #expect(b.minX == 8 && b.minY == 4 && b.maxX == 23 && b.maxY == 13)
  // Past the target: clamped to its last pixel. A negative origin is zero.
  let c = DrawViewport(x: -4, y: 28, width: 100, height: 100).box(width: 32, height: 32)
  #expect(c.minX == 0 && c.minY == 28 && c.maxX == 31 && c.maxY == 31)
  // A negative height swaps the bounds (6.7.2); a zero extent keeps the minimum.
  let d = DrawViewport(x: 0, y: 16, width: 8, height: -8).box(width: 32, height: 32)
  #expect(d.minY == 8 && d.maxY == 15)
  let e = DrawViewport(x: 5, y: 5, width: 0, height: 0).box(width: 32, height: 32)
  #expect(e.minX == 5 && e.maxX == 5 && e.minY == 5 && e.maxY == 5)
}

@Test func theTopologiesHaveTheirModesAndMinimumVertices() {
  var s = DrawPipelineState()
  #expect(s.minimumVertices == 3)
  for (mode, number, minimum) in [(DrawMode.points, 1, 1), (.lines, 2, 2), (.lineStrip, 4, 2), (.triangles, 8, 3), (.triangleStrip, 10, 3),
                                  (.triangleFan, 12, 3)] {
    s.mode = mode
    #expect(mode.rawValue == UInt32(number))
    #expect(s.minimumVertices == minimum)
    #expect(PrimitiveFlags(mode: mode, primitiveRestart: true).word & 0xF == UInt32(number))
  }
}
