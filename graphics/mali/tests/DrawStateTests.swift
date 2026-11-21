// SPDX-License-Identifier: BSD-3-Clause

// The draw state against valhall 06's and 09's tables and worked examples: the
// primitive flags (6.2), the three draw flag words (6.9), scissor and viewport
// (6.7), the depth/stencil descriptor with the test off (6.8), the opaque blend
// descriptor (9.5 example 1) and the RUN_IDVS2 staging registers (01 1.9.3).

import MaliCore
import Testing

@Test func thePrimitiveFlagsOfATriangleDraw() {
  let f = PrimitiveFlags()
  // Draw mode Triangles (8), no index, both depth-cull bits [17:16] set (the default), position FIFO basic (1) at
  // [23:22], view mask 0: bits not listed ([7:4], [9]) are zero.
  #expect(f.word == 8 | 1 << 16 | 1 << 17 | 1 << 22)
  #expect(f.word == 0x0043_0008)
  // An indexed strip with restart and a view mask for layer 0.
  let g = PrimitiveFlags(mode: .triangleStrip, indexType: 2, primitiveRestart: true, positionFIFOFormat: 2, viewMask: 1)
  #expect(g.word == 10 | 2 << 8 | 1 << 16 | 1 << 17 | 1 << 19 | 2 << 22 | 1 << 24)
}

@Test func drawFlags0OfAColourOnlyOpaqueDraw() {
  let w = DrawFlags0.colourOnly.word
  // 6.10.2's third worked example: force-early update (0), weak-early kill (2). Allow forward pixel to kill and be
  // killed (6.10.3), scissor to bounding box [23] and cull zero area [26] (6.9.1: always set); nothing culled.
  #expect(w == 1 | 1 << 1 | 2 << 2 | 0 << 4 | 1 << 23 | 1 << 26)
  #expect(w == 0x0480_000B)
  #expect(w >> 17 & 3 == 0, "no face is culled")
  #expect(w >> 10 & 1 == 0, "no primitive barrier")
}

@Test func drawFlags1And2NameRenderTargetZero() {
  #expect(DrawFlags1.word(renderTargetMask: 1) == 0x0001_FFFF)
  // Write mask [23:12] has target 0; neither the depth nor the stencil plane is read by the shader.
  #expect(DrawFlags2.word(writeMask: 1) == 1 << 12 | 1 << 24 | 1 << 25)
  #expect(DrawFlags2.word(readMask: 1, writeMask: 3, noShaderStencilRead: false, noShaderDepthRead: false) == 1 | 3 << 12)
}

@Test func theScissorMaximumIsInclusiveAndTheViewportAddsADepthRange() {
  let s = ScissorBox(width: 64, height: 48)
  #expect(s.words == [0, 63 | 47 << 16])
  let v = Viewport(rectangle: s, minDepth: 0, maxDepth: 1)
  #expect(v.words == [0, 63 | 47 << 16, 0, 0x3F80_0000])
  #expect(ScissorBox(minX: 4, minY: 8, maxX: 9, maxY: 12).words == [4 | 8 << 16, 9 | 12 << 16])
}

@Test func theDepthStencilDescriptorWithTheTestOff() {
  let w = DepthStencilDescriptor.disabled
  #expect(w.count == 8 && w[0] == 7)
  // 6.8: word 4 has depth cull enable [22], clamp mode 1 [24:23], depth source fixed function 2 [26:25], depth
  // function Always 7 [31:29]; no depth write [27], no bias [28]. The stencil test [31] of word 0 is off.
  #expect(w[4] == 1 << 22 | 1 << 23 | 2 << 25 | 7 << 29)
  #expect(w[4] >> 27 & 3 == 0 && w[0] >> 31 == 0)
  for i in [1, 2, 3, 5, 6, 7] { #expect(w[i] == 0) }
}

@Test func theOpaqueBlendDescriptorIsSection95sFirstExample() {
  // Example 1: replace, full mask, RGBA8 unorm, opaque: 0x00000A00, 0xF0122122, 0x00000019, 0x000ED000.
  #expect(BlendDescriptor().words == [0x0000_0A00, 0xF012_2122, 0x0000_0019, 0x000E_D000])
  // sRGB adds the descriptor's bit 10 and the format's bit 20.
  #expect(BlendDescriptor(isSRGB: true).words == [0x0000_0E00, 0xF012_2122, 0x0000_0019, 0x001E_D000])
  // The array position equals the RT field (9.2.3).
  #expect(BlendDescriptor(renderTarget: 1).words[2] == 0x0001_0019)
}

@Test func theBlendRegisterIsTheAddressWithTheCount() throws {
  #expect(try BlendDescriptor.register(address: 0x10_0100, count: 1) == 0x10_0101)
  #expect(throws: DescriptorError.misaligned) { try BlendDescriptor.register(address: 0x10_0108, count: 1) }
  #expect(throws: DescriptorError.outOfRange) { try BlendDescriptor.register(address: 0x10_0100, count: 9) }
}

@Test func theShaderProgramDescriptorCarriesTheCoverageBitmaskTypeOnlyForAFragmentShader() {
  let f = ShaderProgramDescriptor(stage: .fragment, registerClass: .r64, preloadMask: 0x1000, binary: 0x1_0000_0100,
                                  coverageBitmaskType: 1)
  // Type 8, stage 2 at [7:4], the coverage bitmask type [8], class 64 (0).
  #expect(f.words == [8 | 2 << 4 | 1 << 8, 0x1000, 0x0000_0100, 1, 0, 0, 0, 0])
  let v = ShaderProgramDescriptor(stage: .vertex, registerClass: .r64, preloadMask: 0x1800, binary: 0x2000,
                                  coverageBitmaskType: 1)
  #expect(v.words[0] == 8 | 3 << 4, "a vertex descriptor's bit 8 is not the coverage type")
}

// MARK: The instructions of a render pass

@Test func theRenderInstructionsArePlacedByTheirTables() {
  // RUN_IDVS2: opcode 12, malloc [33], early shading, no draw id.
  #expect(CSInstruction.runIDVS2() == 12 << 56 | 1 << 33)
  #expect(CSInstruction.runIDVS2(flagsOverride: 0x300, deferredShading: true, drawIDRegister: 7, stage: 2)
    == 12 << 56 | 2 << 48 | 7 << 40 | 1 << 35 | 1 << 34 | 1 << 33 | 0x300)
  // RUN_FRAGMENT: opcode 7, tile order [7:4].
  #expect(CSInstruction.runFragment() == 7 << 56)
  #expect(CSInstruction.runFragment(tileOrder: .reverseVertical, enableTileEnableMap: true) == 7 << 56 | 6 << 4 | 1)
  #expect(CSInstruction.finishTiling == 9 << 56)
  // FINISH_FRAGMENT: opcode 11, increment [0], wait mask [31:16], last pair [39:32], first pair [47:40], slot [51:48].
  #expect(CSInstruction.finishFragment(firstChunkPair: 74, lastChunkPair: 76, incrementFragmentCompleted: true,
                                       waitMask: 0x0010, signalSlot: 5)
    == 11 << 56 | 5 << 48 | 74 << 40 | 76 << 32 | 0x10 << 16 | 1)
  // HEAP_SET: opcode 48, the pair [47:40]. HEAP_OPERATION: opcode 49, wait mask [31:16], operation [34:32], slot [51:48].
  #expect(CSInstruction.heapSet(addressPair: 66) == 48 << 56 | 66 << 40)
  #expect(CSInstruction.heapOperation(.vertexTilerStarted) == 49 << 56)
  #expect(CSInstruction.heapOperation(.vertexTilerCompleted, waitMask: 0x0008, signalSlot: 1)
    == 49 << 56 | 1 << 48 | 1 << 32 | 8 << 16)
  #expect(CSInstruction.heapOperation(.fragmentCompleted) == 49 << 56 | 3 << 32)
}
