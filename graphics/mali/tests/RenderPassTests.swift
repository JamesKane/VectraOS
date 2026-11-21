// SPDX-License-Identifier: BSD-3-Clause

// The render pass recipe's streams decoded back and checked against valhall 01
// (the run instructions and their staging registers, 1.9.3 to 1.10) and 02 (the
// queue's initial state 2.2.3, the render-pass flow 2.6, the stream tail 2.9.1);
// the records it lays out read back from its memory image.

import MaliCore
import Testing

private struct Machine {
  var r = [UInt32](repeating: 0, count: 256)
  /// The words that are not register moves, in order, and the registers as each run issued.
  var others: [UInt64] = []
  var idvsRegisters: [UInt32]?
  var fragmentRegisters: [UInt32]?

  func pair(_ n: Int) -> UInt64 { UInt64(r[n]) | UInt64(r[n + 1]) << 32 }

  mutating func step(_ w: UInt64) {
    switch w >> 56 {
    case 1:
      let d = Int(w >> 48 & 0xFF)
      r[d] = UInt32(truncatingIfNeeded: w)
      r[d + 1] = UInt32(w >> 32 & 0xFFFF)
    case 2: r[Int(w >> 48 & 0xFF)] = UInt32(truncatingIfNeeded: w)
    case 12:
      idvsRegisters = r
      others.append(w)
    case 7:
      fragmentRegisters = r
      others.append(w)
    default: others.append(w)
    }
  }
  var opcodes: [UInt64] { others.map { $0 >> 56 } }
}

private let regs = CSRegisterMap(workRegisters: 128, unpreserved: 4)
private let sbs = CSScoreboards(count: 16)
private let base: UInt64 = 0x10_0000
private let colourAddress: UInt64 = 0x20_0000
private let heapContext: UInt64 = 0x30_0000
private let chunk: UInt64 = 0x40_0000
private let geometry: UInt64 = 0x50_0000

private func request(
  _ layout: RenderQueueLayout, initialise: Bool = true, format: ColourFormat = .rgba8, vertices: Int = 3
) -> RenderPassRequest {
  var v: [WindowVertex] = [WindowVertex(x: 8, y: 6), WindowVertex(x: 58, y: 20), WindowVertex(x: 20, y: 56)]
  while v.count < vertices { v.append(WindowVertex(x: 0, y: 0)) }
  return RenderPassRequest(
    width: 64, height: 64, format: format, colourAddress: colourAddress, vertices: v, colour: [1, 0.5, 0, 1],
    heapContext: heapContext, heapChunk: chunk, heapChunkBytes: 1 << 20, geometryBuffer: geometry, layout: layout,
    initialiseQueues: initialise)
}

private func pass(_ r: RenderPassRequest, capacity: Int = 16384) throws -> RenderPassImage {
  try RenderPass.build(at: base, capacity: capacity, request: r, registers: regs, scoreboards: sbs)
}

private func run(_ stream: CSStream) -> Machine {
  var m = Machine()
  for w in stream.words { m.step(w) }
  return m
}

// MARK: The single stream

@Test func theSingleStreamIsTheRenderPassFlowOfSection26() throws {
  let img = try pass(request(.singleQueue))
  #expect(img.streams.count == 1)
  let words = img.streams[0].words
  #expect(img.streams[0].address & 63 == 0 && img.streams[0].size == words.count * 8)
  // 2.2.3 step 2: the slot state, then 2.9.3: the resources the stream uses, once: fragment, tiler, IDVS.
  #expect(Array(words[0..<5]) == [
    CSInstruction.setState(.endpointSlot, immediate: 3), CSInstruction.setState(.waitMask, immediate: 0x0008),
    CSInstruction.setState(.otherSlot, immediate: 0), CSInstruction.setState(.deferredSlot, immediate: 1),
    CSInstruction.setState(.streamMask, immediate: 0xFFF0),
  ])
  #expect(words[5] == CSInstruction.requestResources(.fragment | .tiler | .idvs))
  let m = run(img.streams[0])
  // The instructions that are not register moves, in order (01 1.9 to 1.10 and 02 2.6.1):
  #expect(m.others.dropFirst(6).map { $0 } == [
    CSInstruction.heapSet(addressPair: 66),  // 2.2.3 step 3
    CSInstruction.setState(.endpointSlot, immediate: 3),
    CSInstruction.heapOperation(.vertexTilerStarted),  // 2.6.2: after the context is in memory
    CSInstruction.runIDVS2(),
    CSInstruction.finishTiling,
    CSInstruction.heapOperation(.vertexTilerCompleted, waitMask: 0x0008, signalSlot: 1),  // 2.6.3
    CSInstruction.wait(mask: 0x000A),  // the tiling's slot and the heap operation's
    CSInstruction.setState(.endpointSlot, immediate: 4),  // the fragment pass counts on the next rotating slot
    CSInstruction.runFragment(),
    CSInstruction.loadMultiple(base: 74, address: 72, mask: 0xF),  // 2.6.4 step 6: completed top and bottom
    CSInstruction.wait(mask: 0x0001),
    CSInstruction.finishFragment(firstChunkPair: 74, lastChunkPair: 76, incrementFragmentCompleted: true, waitMask: 0x0010,
                                 signalSlot: 5),
    // 2.9.1: every slot, the flush id's zero, FLUSH_CACHE2 clean on slot 0, wait for it.
    CSInstruction.wait(mask: 0xFFFF),
    CSInstruction.flushCache2(l2: .clean, lsc: .clean, other: .none, flushIDRegister: 66, signalSlot: 0),
    CSInstruction.wait(mask: 0x0001),
  ])
  // No register the kernel clobbers (124 to 127) is named by a move.
  for w in words where w >> 56 == 1 || w >> 56 == 2 { #expect(Int(w >> 48 & 0xFF) < 124) }
}

@Test func theDrawSetsEveryStagingRegisterOfSection193() throws {
  let img = try pass(request(.singleQueue))
  let m = run(img.streams[0])
  let r = try #require(m.idvsRegisters)
  func pair(_ n: Int) -> UInt64 { UInt64(r[n]) | UInt64(r[n + 1]) << 32 }
  #expect(pair(0) == 0 && pair(2) == 0)  // no resource tables
  #expect(pair(8) == img.draw.vertexFAU && img.draw.vertexFAU >> 56 == 1)  // one FAU word: the table's address
  #expect(pair(10) == 0)
  #expect(pair(16) == img.vertexSPD && pair(18) == img.fragmentSPD)
  #expect(pair(24) == img.localStorage && pair(26) == img.localStorage)
  #expect(r[32] == 0 && r[33] == 3 && r[34] == 1 && r[35] == 0 && r[36] == 0 && r[37] == 0)
  #expect(pair(40) == img.tilerContext)
  // The scissor and the viewport: the whole 64 x 64, the maximum inclusive; depth 0 to 1.
  #expect(r[42] == 0 && r[43] == 63 | 63 << 16 && r[44] == 0 && r[45] == 63 | 63 << 16)
  #expect(r[46] == 0 && r[47] == 0x3F80_0000)
  #expect(pair(48) == 0 && r[50] == 0 && r[51] == 0)  // no index buffer, no varyings
  #expect(pair(52) == img.depthStencil)
  #expect(pair(54) == img.blend | 1)
  #expect(r[56] == PrimitiveFlags().word && r[57] == DrawFlags0.colourOnly.word)
  #expect(r[58] == 0x0001_FFFF && r[59] == 1 << 12 | 1 << 24 | 1 << 25)
  #expect(r[60] == 0 && r[61] == 0 && pair(64) == 0)
}

@Test func theFragmentRunReadsTheTaggedPointerAndTheInclusiveBox() throws {
  let img = try pass(request(.singleQueue))
  let r = try #require(run(img.streams[0]).fragmentRegisters)
  // 8.1.3: the group's address with the tag 1 (no extension, one target); 8.11: (0, 0) to (63, 63), x low, y high.
  #expect(UInt64(r[40]) | UInt64(r[41]) << 32 == img.framebuffer | 1 && img.fragmentPointer == img.framebuffer | 1)
  #expect(r[42] == 0 && r[43] == 63 | 63 << 16)
}

@Test func theCompletedWordsAreLoadedFromByteFortyOfTheTilerContext() throws {
  let img = try pass(request(.singleQueue))
  var m = Machine()
  for w in img.streams[0].words {
    m.step(w)
    if w >> 56 == 20 { break }  // LOAD_MULTIPLE
  }
  #expect(m.pair(72) == img.tilerContext + 40)
  #expect(m.pair(66) == heapContext)
}

@Test func laterPassesLeaveOutTheQueueSetup() throws {
  let img = try pass(request(.singleQueue, initialise: false))
  let m = run(img.streams[0])
  #expect(!m.opcodes.contains(0x22) && m.opcodes.first == 48)
  #expect(m.others.first == CSInstruction.heapSet(addressPair: 66))
  // The endpoint slot is still set by the stream itself, so a state left by another job doesn't matter.
  #expect(m.others.filter { $0 == CSInstruction.setState(.endpointSlot, immediate: 3) }.count == 1)
}

// MARK: The two queues

@Test func theSplitLayoutIsTheVertexTilerQueueAndTheFragmentQueue() throws {
  let img = try pass(request(.splitQueues))
  #expect(img.streams.count == 2 && img.syncObject != 0 && img.syncObject & 63 == 0)
  #expect(img.streams[0].address & 63 == 0 && img.streams[1].address & 63 == 0)
  #expect(img.streams[1].address >= img.streams[0].address + UInt64(img.streams[0].size))
  // Queue 0: the tiling, then the sync signal on the tiling's slot (02 2.6.3: SYNC_ADD64 of 1, CSG scope).
  let q0 = run(img.streams[0])
  #expect(q0.others.dropFirst(6).map { $0 } == [
    CSInstruction.heapSet(addressPair: 66),
    CSInstruction.setState(.endpointSlot, immediate: 3),
    CSInstruction.heapOperation(.vertexTilerStarted),
    CSInstruction.runIDVS2(),
    CSInstruction.finishTiling,
    CSInstruction.heapOperation(.vertexTilerCompleted, waitMask: 0x0008, signalSlot: 1),
    CSInstruction.syncAdd64(address: 68, value: 70, waitMask: 0x0008, signalSlot: 1, scope: .group),
    CSInstruction.wait(mask: 0xFFFF),
    CSInstruction.flushCache2(l2: .clean, lsc: .clean, other: .none, flushIDRegister: 66, signalSlot: 0),
    CSInstruction.wait(mask: 0x0001),
  ])
  // The sync instruction's registers hold the object's address and the value 1.
  #expect(q0.pair(68) == img.syncObject && q0.pair(70) == 1)
  // Queue 0 asks for the tiler and IDVS, queue 1 for the fragment resource only (2.9.3).
  #expect(img.streams[0].words[5] == CSInstruction.requestResources(.tiler | .idvs))
  #expect(img.streams[1].words[5] == CSInstruction.requestResources(.fragment))
  // Queue 1: heap set, the wait for the signal (SYNC_WAIT64, Greater than 1), the fragment pass on the first slot.
  let q1 = run(img.streams[1])
  #expect(q1.others.dropFirst(6).map { $0 } == [
    CSInstruction.heapSet(addressPair: 66),
    CSInstruction.syncWait64(address: 68, reference: 70, condition: .greater),
    CSInstruction.setState(.endpointSlot, immediate: 3),
    CSInstruction.runFragment(),
    CSInstruction.loadMultiple(base: 74, address: 72, mask: 0xF),
    CSInstruction.wait(mask: 0x0001),
    CSInstruction.finishFragment(firstChunkPair: 74, lastChunkPair: 76, incrementFragmentCompleted: true, waitMask: 0x0008,
                                 signalSlot: 5),
    CSInstruction.wait(mask: 0xFFFF),
    CSInstruction.flushCache2(l2: .clean, lsc: .clean, other: .none, flushIDRegister: 66, signalSlot: 0),
    CSInstruction.wait(mask: 0x0001),
  ])
  // The sync object starts at sequence 1, status 0: one signal is a target of 1 (02 2.4.2).
  #expect(img.memory.load64(at: Int(img.syncObject - base)) == 1 && img.memory.load64(at: Int(img.syncObject - base) + 8) == 0)
}

@Test func bothStreamsUseOnlyRegistersTheKernelLeavesAlone() throws {
  let img = try pass(request(.splitQueues))
  for s in img.streams {
    for w in s.words where w >> 56 == 1 || w >> 56 == 2 { #expect(Int(w >> 48 & 0xFF) < 124) }
  }
}

// MARK: The records in the image

@Test func theRenderRecordsAreInTheImageWhereTheRegistersPoint() throws {
  let img = try pass(request(.singleQueue))
  func off(_ a: UInt64) -> Int { Int(a - base) }
  func words(_ a: UInt64, _ n: Int) -> [UInt32] { (0..<n).map { img.memory.load32(at: off(a) + 4 * $0) } }
  #expect(img.vertexSPD & 31 == 0 && img.fragmentSPD & 31 == 0 && img.localStorage & 63 == 0)
  #expect(img.tilerContext & 63 == 0 && img.heapDescriptor & 31 == 0 && img.framebuffer & 63 == 0)
  #expect(img.blend & 15 == 0 && img.depthStencil & 31 == 0 && img.vertexShader & 127 == 0 && img.fragmentShader & 127 == 0)
  // Vertex SPD: stage vertex (3), class 64, r59 and r60 preloaded, the position shader's address.
  #expect(words(img.vertexSPD, 4) == [8 | 3 << 4, 0x1800, UInt32(truncatingIfNeeded: img.vertexShader), UInt32(img.vertexShader >> 32)])
  // Fragment SPD: stage fragment (2), the coverage bitmask type 1 (Vulkan), r60 preloaded.
  #expect(words(img.fragmentSPD, 2) == [8 | 2 << 4 | 1 << 8, 0x1000])
  #expect(img.memory.load64(at: off(img.fragmentSPD) + 8) == img.fragmentShader)
  // No thread storage and no workgroup memory.
  #expect(words(img.localStorage, 8) == [0, 31, 0, 0, 0, 0, 0, 0])
  // The shaders.
  for (i, w) in TriangleShaders.positionWords.enumerated() { #expect(img.memory.load64(at: off(img.vertexShader) + 8 * i) == w) }
  let fw = TriangleShaders.fragmentWords(colour: [0x3F80_0000, 0x3F00_0000, 0, 0x3F80_0000])
  for (i, w) in fw.enumerated() { #expect(img.memory.load64(at: off(img.fragmentShader) + 8 * i) == w) }
  // The FAU word holds the position table's address; the table holds the three vertices, then zeros.
  let fauAddress = img.draw.vertexFAU & 0x00FF_FFFF_FFFF_FFFF
  #expect(img.memory.load64(at: off(fauAddress)) == img.vertexTable)
  #expect(img.memory.load32(at: off(img.vertexTable)) == Float(8).bitPattern)
  #expect(img.memory.load32(at: off(img.vertexTable) + 20) == Float(20).bitPattern)  // vertex 1 y
  #expect(img.memory.load32(at: off(img.vertexTable) + 12) == Float(1).bitPattern)  // 1/w
  #expect(img.memory.load64(at: off(img.vertexTable) + 48) == 0)
  // Tiler context, heap descriptor, the group and its render target are TilerDescriptors' and FramebufferDescriptors'.
  let tiler = TilerContext(hierarchyMask: img.hierarchyMask, effectiveTileLog2: 12, width: 64, height: 64,
                           heap: img.heapDescriptor, geometryBuffer: geometry)
  #expect(words(img.tilerContext, 32) == (try tiler.words()))
  #expect(words(img.heapDescriptor, 8) == (try TilerHeapDescriptor(chunkBytes: 1 << 20, firstChunk: chunk).words()))
  #expect(img.plan.tileLog2 == 12 && img.plan.allocationField == 16 && img.hierarchyMask == 0)
  #expect(img.renderTarget == img.framebuffer + 128)
  let rt = RenderTargetDescriptor(format: .rgba8, address: colourAddress, rowStride: 256, surfaceStride: 16384,
                                  clearWord: 0xFF00_0000)
  #expect(words(img.renderTarget, 16) == (try rt.words()))
  let fb = FramebufferParameters(width: 64, height: 64, sampleLocations: img.sampleTable, effectiveTileLog2: 12,
                                 colourAllocationKiB: 16, tiler: img.tilerContext)
  #expect(words(img.framebuffer, 32) == (try fb.words()))
  #expect(words(img.blend, 4) == BlendDescriptor().words)
  #expect(words(img.depthStencil, 8) == DepthStencilDescriptor.disabled)
  // The sample table is the one of 7.9.
  #expect(img.memory.load32(at: off(img.sampleTable)) == 128 | 128 << 16)
  // Every record of the group is inside the image and the streams are the last things in it.
  #expect(img.memory.count >= off(img.streams[0].address) + img.streams[0].size)
  for (i, w) in img.streams[0].words.enumerated() { #expect(img.memory.load64(at: off(img.streams[0].address) + 8 * i) == w) }
}

@Test func aBgraTargetDiffersOnlyInTheSwizzle() throws {
  let a = try pass(request(.singleQueue, format: .rgba8))
  let b = try pass(request(.singleQueue, format: .bgra8))
  let off = Int(a.renderTarget - base)
  #expect(a.renderTarget == b.renderTarget)
  for i in 0..<16 {
    let x = a.memory.load32(at: off + 4 * i)
    let y = b.memory.load32(at: off + 4 * i)
    if i == 1 { #expect(x & ~(0xFFF << 16) == y & ~(0xFFF << 16) && x >> 16 & 0xFFF == 0x688 && y >> 16 & 0xFFF == 0x60A) } else { #expect(x == y) }
  }
}

@Test func theSixteenVertexTableIsTheMostThePositionShaderReads() throws {
  _ = try pass(request(.singleQueue, vertices: 16))
  #expect(throws: RenderError.badRequest) { try pass(request(.singleQueue, vertices: 17)) }
  var two = request(.singleQueue)
  two.vertices.removeLast()
  #expect(throws: RenderError.badRequest) { try pass(two) }
  var colour = request(.singleQueue)
  colour.colour = [1, 0, 0]
  #expect(throws: RenderError.badRequest) { try pass(colour) }
}

@Test func theBuilderRefusesAnArchWithoutRunIDVS2AndAMisalignedOrCrampedBlock() throws {
  #expect(throws: RenderError.arch(11)) {
    try RenderPass.build(at: base, capacity: 16384, request: request(.singleQueue), registers: regs, scoreboards: sbs, arch: 11)
  }
  #expect(throws: RenderError.descriptor(.misaligned)) {
    try RenderPass.build(at: base + 8, capacity: 16384, request: request(.singleQueue), registers: regs, scoreboards: sbs)
  }
  #expect(throws: RenderError.self) { try pass(request(.singleQueue), capacity: 512) }
  // The smallest chunk (one page) still holds a 64 x 64 target's 128 bytes of bin pointers: the automatic mask.
  var small = request(.singleQueue)
  small.heapChunkBytes = 4096
  #expect(try pass(small).hierarchyMask == 0)
}

// MARK: Compiled shaders

private func withShaders(_ varying: UInt32 = 0, fragmentPush: Int = 0) -> RenderPassRequest {
  var layout = GraphicsFauLayout()
  layout.viewportWord = 0
  layout.pushWord = 6
  layout.pushWords = 2
  layout.words = 8
  var flayout = GraphicsFauLayout()
  flayout.pushWord = 0
  flayout.pushWords = fragmentPush
  flayout.words = (fragmentPush + 1) / 2 * 2
  var r = request(.singleQueue)
  r.vertexShader = VertexShader(
    code: [1, 2, 3], registerClass: .r64, preloadMask: 0x3800, layout: layout, varyingBytes: varying, outputLocations: [],
    attributeLocations: [], storesPointSize: false)
  r.fragmentShader = FragmentShader(
    code: [4, 5], registerClass: .r64, preloadMask: 0x1000, layout: flayout, colourTargets: [0], inputLocations: [],
    nonPerspectiveMask: 0, discards: false, earlyFragmentTests: false)
  return r
}

@Test func compiledShadersReplaceTheHandAssembledOnes() throws {
  let img = try pass(withShaders(32, fragmentPush: 2))
  // The code is theirs, at the addresses the SPDs name.
  let vcode = Int(img.vertexShader - base)
  let fcode = Int(img.fragmentShader - base)
  #expect(img.memory.load64(at: vcode) == 1 && img.memory.load64(at: vcode + 16) == 3)
  #expect(img.memory.load64(at: fcode) == 4 && img.memory.load64(at: fcode + 8) == 5)
  let vspd = Int(img.vertexSPD - base)
  #expect(img.memory.load32(at: vspd + 4) & 0xFFFF == 0x3800)
  let fspd = Int(img.fragmentSPD - base)
  #expect(img.memory.load32(at: fspd + 4) & 0xFFFF == 0x1000)
  // The vertex FAU: four slots, the viewport of a 64 x 64 target and the root pointer to the table of clip positions.
  #expect(img.draw.vertexFAU >> 56 == 4)
  let fau = Int(img.draw.vertexFAU & ((1 << 56) - 1) - base)
  let scale: Float = 32
  #expect(img.memory.load32(at: fau) == scale.bitPattern && img.memory.load32(at: fau + 4) == scale.bitPattern)
  #expect(img.memory.load32(at: fau + 8) == scale.bitPattern && img.memory.load32(at: fau + 12) == scale.bitPattern)
  #expect(img.memory.load32(at: fau + 16) == Float(1).bitPattern && img.memory.load32(at: fau + 20) == 0)
  #expect(img.memory.load64(at: fau + 24) == img.vertexTable)
  // The table holds the corners as clip positions: x = (8 - 32) / 32, w = 1.
  let t = Int(img.vertexTable - base)
  #expect(img.memory.load32(at: t) == Float(-0.75).bitPattern && img.memory.load32(at: t + 12) == Float(1).bitPattern)
  // The fragment shader has a FAU block of its own (one slot of push constants), and the draw has the varying size.
  #expect(img.draw.fragmentFAU >> 56 == 1)
  #expect(img.draw.varySize == 32)
}

@Test func aFragmentShaderWithNoPushConstantsHasNoFAU() throws {
  let img = try pass(withShaders())
  #expect(img.draw.fragmentFAU == 0 && img.draw.varySize == 0)
}

// MARK: Draws with textures and blend

private func texturedDraws(second: BlendState = BlendState(enabled: true, equation: .alpha), stack: UInt32 = 0, storage: UInt64 = 0)
  throws -> DrawPassRequest
{
  var vlayout = GraphicsFauLayout()
  vlayout.viewportWord = 0
  vlayout.pushWord = 6
  vlayout.pushWords = 2
  vlayout.words = 8
  var flayout = GraphicsFauLayout()
  flayout.imageBindings = [ImageBinding(set: 0, binding: 0, word: 0), ImageBinding(set: 0, binding: 1, word: 1)]
  flayout.pushWord = 2
  flayout.pushWords = 2
  flayout.words = 4
  let vs = VertexShader(
    code: [1, 2, 3], registerClass: .r64, preloadMask: 0x3800, layout: vlayout, varyingBytes: 32, outputLocations: [0, 1],
    attributeLocations: [], storesPointSize: false, stackBytes: stack)
  let fs = FragmentShader(
    code: [4, 5], registerClass: .r64, preloadMask: 0x1000, layout: flayout, colourTargets: [0], inputLocations: [0, 1],
    nonPerspectiveMask: 0, discards: false, earlyFragmentTests: false)
  let images = [BindingHandle(set: 0, binding: 0, handle: DescriptorHeap.handle(index: 0)),
                BindingHandle(set: 0, binding: 1, handle: DescriptorHeap.handle(index: 8))]
  let one = PassDraw(vertexShader: vs, fragmentShader: fs, vertexCount: 6, push: [0xAAAA_0000, 0xBBBB], blend: BlendDescriptor(renderTarget: 0), images: images)
  let two = PassDraw(
    vertexShader: vs, fragmentShader: fs, vertexCount: 6, push: [0xCCCC_0000, 0xDDDD],
    blend: try BlendDescriptor(state: second), images: images)
  return DrawPassRequest(
    width: 64, height: 64, format: .rgba8, colourAddress: colourAddress, draws: [one, two], heapAddress: 0x60_0000,
    heapBytes: 1024, heapContext: heapContext, heapChunk: chunk, heapChunkBytes: 1 << 20, geometryBuffer: geometry,
    layout: .singleQueue, threadStorage: storage,
    limits: ComputeLimits(maxThreadsPerCore: 2048, maxThreadsPerWorkgroup: 1024, registersPerCore: 65536, tasksPerCore: 8, shaderPresent: 0xFF))
}

@Test func twoDrawsAreTwoRunsInOneTilerPass() throws {
  let (img, records, table) = try RenderPass.build(
    at: base, capacity: 16384, request: texturedDraws(), registers: regs, scoreboards: sbs)
  #expect(records.count == 2)
  var runs = 0
  var tilingEnds = 0
  for w in img.streams[0].words {
    if w >> 56 == 12 { runs += 1 }
    if w == CSInstruction.finishTiling { tilingEnds += 1 }
  }
  #expect(runs == 2 && tilingEnds == 1)
  // Each run sees its own registers: the blend array, the FAU blocks, six vertices, the resource table.
  var m = Machine()
  var seen: [[UInt32]] = []
  for w in img.streams[0].words {
    m.step(w)
    if w >> 56 == 12, let r = m.idvsRegisters { seen.append(r) }
  }
  #expect(seen.count == 2)
  for (n, r) in seen.enumerated() {
    func pair(_ i: Int) -> UInt64 { UInt64(r[i]) | UInt64(r[i + 1]) << 32 }
    #expect(pair(2) == table && table & 63 == 4, "the fragment SRT is the table with four entries")
    #expect(pair(0) == 0, "the vertex stage has no resources")
    #expect(r[33] == 6 && r[34] == 1)
    #expect(pair(54) == records[n].blend | 1)
    #expect(pair(8) == records[n].state.vertexFAU && pair(10) == records[n].state.fragmentFAU)
    #expect(r[51] == 32)
  }
  #expect(records[0].blend != records[1].blend)
}

@Test func theResourceTableNamesTheHeapAsTableOne() throws {
  let (img, _, table) = try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(), registers: regs, scoreboards: sbs)
  let at = Int(table & ~63 - base)
  // Entry 0 unused; entry 1: the heap's address, the descriptors flag, its size.
  #expect(img.memory.load64(at: at) == 0 && img.memory.load64(at: at + 8) == 0)
  #expect(img.memory.load32(at: at + 16) == 0x60_0000 && img.memory.load32(at: at + 20) == 1 << 24)
  #expect(img.memory.load32(at: at + 24) == 1024)
}

@Test func eachDrawHasItsOwnPushConstantsAndImageHandles() throws {
  let (img, records, _) = try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(), registers: regs, scoreboards: sbs)
  for (n, r) in records.enumerated() {
    // The vertex stage's push constants follow the viewport; the fragment stage's follow the two handle words.
    let v = Int(r.vertexFAU & ((1 << 56) - 1) - base)
    let f = Int(r.fragmentFAU & ((1 << 56) - 1) - base)
    let word: UInt32 = n == 0 ? 0xAAAA_0000 : 0xCCCC_0000
    #expect(img.memory.load32(at: v + 24) == word)
    #expect(img.memory.load32(at: f) == 0x0100_0000, "the textures' element 0 is heap index 0")
    #expect(img.memory.load32(at: f + 4) == 0x0100_0008, "the sampler is heap index 8")
    #expect(img.memory.load32(at: f + 8) == word)
  }
}

@Test func theBlendDescriptorsAreLaidOutOneToADraw() throws {
  let (img, records, _) = try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(), registers: regs, scoreboards: sbs)
  let a = Int(records[0].blend - base)
  let b = Int(records[1].blend - base)
  #expect(img.memory.load32(at: a + 8) & 3 == 1, "the first draw is opaque")
  #expect(img.memory.load32(at: b + 8) & 3 == 2, "the second is fixed-function")
  #expect(img.memory.load32(at: b + 4) == 0xF0D3_2503)
  #expect(img.memory.load32(at: b) & 1 == 1, "and reads the destination")
}

@Test func aDrawThatReadsTheDestinationMayNotKillEarlierFragments() throws {
  let (_, records, _) = try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(), registers: regs, scoreboards: sbs)
  // 6.10.3: allow-to-kill is clear for the blended draw, set for the opaque one; allow-to-be-killed stays set.
  #expect(records[0].state.flags0 & 1 == 1)
  #expect(records[1].state.flags0 & 1 == 0)
  #expect(records[1].state.flags0 & 2 == 2)
}

@Test func sharedShadersAreLaidOutOnce() throws {
  let (img, records, _) = try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(), registers: regs, scoreboards: sbs)
  #expect(records[0].vertexSPD == records[1].vertexSPD && records[0].fragmentSPD == records[1].fragmentSPD)
  let vspd = Int(records[0].vertexSPD - base)
  let fspd = Int(records[0].fragmentSPD - base)
  #expect(img.memory.load32(at: vspd) >> 4 & 15 == 3 && img.memory.load32(at: fspd) >> 4 & 15 == 2)
}

@Test func aShaderWithAStackNeedsThreadStorageInThePassTSD() throws {
  // 48 bytes of stack: field ceil(log2(3)) = 2, 64 bytes a thread, packed addressing (04 sections 4.5.2 and 4.7.2).
  let (img, records, _) = try RenderPass.build(
    at: base, capacity: 16384, request: texturedDraws(stack: 48, storage: 0x1000_0000), registers: regs, scoreboards: sbs)
  let tsd = Int(img.localStorage - base)
  #expect(img.memory.load32(at: tsd) == 2)
  #expect(img.memory.load32(at: tsd + 8) == 0x0010_0000 && img.memory.load32(at: tsd + 12) == 0x1000_0000)
  #expect(records[0].state.vertexTSD == img.localStorage && records[0].state.fragmentTSD == img.localStorage)
  #expect(throws: RenderError.needsThreadStorage) {
    try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(stack: 48), registers: regs, scoreboards: sbs)
  }
  #expect(throws: RenderError.descriptor(.misaligned)) {
    try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(stack: 48, storage: 0x1000_0100), registers: regs, scoreboards: sbs)
  }
  // No stack: the empty record, as the triangle's.
  let (plain, _, _) = try RenderPass.build(at: base, capacity: 16384, request: texturedDraws(), registers: regs, scoreboards: sbs)
  #expect(plain.memory.load32(at: Int(plain.localStorage - base)) == 0)
}
