// SPDX-License-Identifier: BSD-3-Clause

// A render pass as a recipe (valhall 01 sections 1.9.3 to 1.10, 02 sections
// 2.2.3, 2.3, 2.6 and 2.9.1, 07, 08): given a triangle's three window-space
// vertices, a colour and a linear colour target, it lays the tiler context,
// the heap descriptor, the framebuffer descriptor and its render target, the
// sample table, the draw state records, the two hand-assembled shaders and the
// command streams into one block of GPU memory, and returns the block's bytes
// and the streams' addresses and sizes for `CSFContext.submit`. Pure: the caller
// allocates the block, the colour target, the tiler heap's chunk and the
// geometry buffer, writes the bytes and submits. Nothing here touches the GPU.
//
// Two stream layouts (02 section 2.1 gives three queues, one per kind of
// work, and ordering between them only through sync objects):
//  - `.splitQueues` is the spec's own: queue 0 (vertex/tiler) heap-sets,
//    starts the pass, runs the draw, finishes tiling and signals a sync
//    object; queue 1 (fragment) waits for it (02 section 2.6.4 steps 3 to 6)
//    and runs the fragment pass and FINISH_FRAGMENT. The compute queue has
//    nothing to do. The group has two queues of the same ring size.
//  - `.singleQueue` is this recipe's extrapolation for bring-up, which 02
//    does not give and does not forbid: the one stream does both, waiting for
//    the tiling's endpoint slot (01 section 1.9.7: FINISH_TILING must be waited
//    for through its slot before the fragment pass consumes the lists) where
//    queue 1 would wait for the sync object. It needs one queue and no sync
//    object, and puts the fragment pass on a second rotating slot.

public enum RenderQueueLayout: Sendable {
  case singleQueue
  case splitQueues
}

/// One vertex of the table the position shader reads: a window-space position (x and y in pixels from the
/// framebuffer's origin, z in the depth range) and the reciprocal of the clip-space w (14 section 14.3.3).
public struct WindowVertex: Equatable, Sendable {
  public var x: Float
  public var y: Float
  public var z: Float
  public var reciprocalW: Float
  public init(x: Float, y: Float, z: Float = 0.5, reciprocalW: Float = 1) {
    self.x = x
    self.y = y
    self.z = z
    self.reciprocalW = reciprocalW
  }
}

public enum RenderError: Error, Equatable, Sendable {
  case descriptor(DescriptorError)
  case stream(CSBuildError)
  case noRoom(needed: Int, capacity: Int)
  /// More than 16 vertices or fewer than 3, a colour that isn't four floats, a framebuffer the tile buffer can't hold.
  case badRequest
  case arch(Int)
}

/// What to draw and where. Addresses are in the GPU's address space.
public struct RenderPassRequest: Sendable {
  public var width: Int
  public var height: Int
  public var format: ColourFormat
  /// The colour target: `LinearLayout.rowStride` bytes a row, 64-byte aligned.
  public var colourAddress: UInt64
  /// The clear colour, as the four channels (0 to 1) of the tile buffer's order: red, green, blue, alpha.
  public var clear: [Float]
  /// The triangle's vertices (3 to 16: the position shader's table has 16 entries) and its colour (R, G, B, A).
  public var vertices: [WindowVertex]
  public var colour: [Float]
  /// The heap's context (the kernel creates it, panthor 08 section 8.2: 32 bytes of zeros on a 64-byte stride),
  /// the heap's first chunk (4 KiB aligned) and its size, and the geometry buffer (4 KiB aligned, 64 KiB).
  public var heapContext: UInt64
  public var heapChunk: UInt64
  public var heapChunkBytes: UInt64
  public var geometryBuffer: UInt64
  public var tileBuffer: TileBuffer
  public var layout: RenderQueueLayout
  /// Whether the streams set the queues' slot state and request the resources first (once per queue, 02 sections
  /// 2.2.3 and 2.9.3); a later pass on the same queues leaves them out.
  public var initialiseQueues: Bool
  /// Shaders the compiler made (graphics/compiler), which replace the hand-assembled ones. The vertex shader reads
  /// clip-space positions through the root pointer, which is the first push constant: the recipe makes them from
  /// `vertices` (window space) by the inverse of the viewport transform, and fills the FAU block from the shader's
  /// own layout. The fragment shader's colour is its own: `colour` is not used.
  public var vertexShader: VertexShader?
  public var fragmentShader: FragmentShader?

  public init(
    width: Int, height: Int, format: ColourFormat, colourAddress: UInt64, clear: [Float] = [0, 0, 0, 1],
    vertices: [WindowVertex], colour: [Float], heapContext: UInt64, heapChunk: UInt64, heapChunkBytes: UInt64,
    geometryBuffer: UInt64, tileBuffer: TileBuffer = .g720, layout: RenderQueueLayout = .splitQueues,
    initialiseQueues: Bool = true, vertexShader: VertexShader? = nil, fragmentShader: FragmentShader? = nil
  ) {
    self.vertexShader = vertexShader
    self.fragmentShader = fragmentShader
    self.width = width
    self.height = height
    self.format = format
    self.colourAddress = colourAddress
    self.clear = clear
    self.vertices = vertices
    self.colour = colour
    self.heapContext = heapContext
    self.heapChunk = heapChunk
    self.heapChunkBytes = heapChunkBytes
    self.geometryBuffer = geometryBuffer
    self.tileBuffer = tileBuffer
    self.layout = layout
    self.initialiseQueues = initialiseQueues
  }
}

/// A render pass laid out in GPU memory.
public struct RenderPassImage: Equatable, Sendable {
  /// The block's bytes, to be stored at `base`.
  public var memory: MemoryImage
  public var base: UInt64
  /// The streams by queue: one for `.singleQueue`, queue 0 (vertex/tiler) and queue 1 (fragment) for `.splitQueues`.
  public var streams: [CSStream]
  public var plan: TilePlan
  public var hierarchyMask: UInt32
  public var tilerContext: UInt64
  public var heapDescriptor: UInt64
  public var framebuffer: UInt64
  public var renderTarget: UInt64
  public var sampleTable: UInt64
  public var blend: UInt64
  public var depthStencil: UInt64
  public var vertexTable: UInt64
  public var vertexShader: UInt64
  public var fragmentShader: UInt64
  public var vertexSPD: UInt64
  public var fragmentSPD: UInt64
  public var localStorage: UInt64
  /// The queue-0 sync object of `.splitQueues` (16 bytes: sequence 1, status 0), else 0.
  public var syncObject: UInt64
  /// The staging registers the draw sets, and the tagged framebuffer pointer, as the stream decoder reads them back.
  public var draw: IDVSState
  public var fragmentPointer: UInt64
}

public enum RenderPass {
  /// Scoreboard slots the recipe uses beyond 02 section 2.3.1's roles: the tiling (and, on the split layout, the
  /// fragment work) runs on the first rotating slot; a single stream's fragment pass on the next.
  public static let tilingSlot = CSScoreboards.firstRotating
  public static let singleFragmentSlot = CSScoreboards.firstRotating + 1
  /// The slot FINISH_FRAGMENT signals, past both.
  public static let finishSlot = CSScoreboards.firstRotating + 2

  /// The registers the stream uses beyond the staging registers 0 to 65 (02 section 2.10): the heap context's pair,
  /// the sync object's address and the value 1 as pairs, the completed pointers' address and the four words
  /// loaded from it (the top pair, then the bottom pair).
  static let heapContextRegister = 66
  static let syncAddressRegister = 68
  static let syncValueRegister = 70
  static let completedAddressRegister = 72
  static let completedTopRegister = 74
  static let completedBottomRegister = 76

  /// The framebuffer group the fragment run reads: the parameters block and one render target.
  public static let groupBytes = 128 + 64

  static func bits(_ f: Float) -> UInt32 { f.bitPattern }

  public static func build(
    at base: UInt64, capacity: Int, request r: RenderPassRequest, registers: CSRegisterMap, scoreboards: CSScoreboards,
    arch: Int = 12
  ) throws(RenderError) -> RenderPassImage {
    guard arch >= 12, arch <= 13 else { throw .arch(arch) }
    guard r.vertices.count >= 3, r.vertices.count <= TriangleShaders.positionTableEntries, r.colour.count == 4,
      r.clear.count == 4, r.width >= 1, r.height >= 1, r.width <= 4096, r.height <= 4096
    else { throw .badRequest }
    guard base & 63 == 0 else { throw .descriptor(.misaligned) }
    guard let plan = TilePlan.make(r.tileBuffer, bytesPerSample: [ColourFormat.bytesPerPixel], samples: 1) else {
      throw .badRequest
    }

    // The hierarchy mask: the automatic one where its bin pointers fit the chunk (07 section 7.6.3, step 1).
    guard let mask = HierarchyMask.select(width: r.width, height: r.height, tilePixels: plan.tilePixels, maxLevels: 4,
                                         chunkBytes: Int(r.heapChunkBytes), arch: arch)
    else { throw .badRequest }

    // Layout, relative to the base: the records at their alignments, the shader binaries at 128, the streams last.
    var offset = 0
    func place(_ size: Int, _ align: Int) -> Int {
      offset = alignUp(offset, align)
      let at = offset
      offset += size
      return at
    }
    let vspdAt = place(ShaderProgramDescriptor.size, ShaderProgramDescriptor.alignment)
    let fspdAt = place(ShaderProgramDescriptor.size, ShaderProgramDescriptor.alignment)
    let tsdAt = place(LocalStorageDescriptor.size, LocalStorageDescriptor.alignment)
    let blendAt = place(BlendDescriptor.size, 64)
    let zsdAt = place(DepthStencilDescriptor.size, DepthStencilDescriptor.alignment)
    let tilerAt = place(TilerContext.size, TilerContext.alignment)
    let heapAt = place(TilerHeapDescriptor.size, TilerHeapDescriptor.alignment)
    let fbdAt = place(groupBytes, 64)
    let samplesAt = place(SamplePatterns.tableBytes, 64)
    let vertexSlots = r.vertexShader.map { max($0.layout.slots, 1) } ?? 1
    let fauAt = place(8 * vertexSlots, 8)
    let tableAt = place(TriangleShaders.positionTableEntries * TriangleShaders.positionBytes, 64)
    let vertexWords = r.vertexShader?.code ?? TriangleShaders.positionWords
    let vcodeAt = place(vertexWords.count * 8, 128)
    let fragmentWords = r.fragmentShader?.code ?? TriangleShaders.fragmentWords(colour: r.colour.map { $0.bitPattern })
    let fragmentSlots = r.fragmentShader?.layout.slots ?? 0
    let ffauAt = place(8 * fragmentSlots, 8)
    let fcodeAt = place(fragmentWords.count * 8, 128)
    let syncAt = r.layout == .splitQueues ? place(16, 64) : 0
    let stream0At = place(0, 64)

    func va(_ at: Int) -> UInt64 { base + UInt64(at) }

    // The records.
    let tiler = TilerContext(
      hierarchyMask: mask, samplePattern: SamplePatterns.single, firstProvokingVertex: true,
      effectiveTileLog2: plan.tileLog2, width: r.width, height: r.height, heap: va(heapAt),
      geometryBuffer: r.geometryBuffer)
    let heap = TilerHeapDescriptor(chunkBytes: r.heapChunkBytes, firstChunk: r.heapChunk)
    let layout = LinearLayout(width: r.width, height: r.height, bytesPerPixel: ColourFormat.bytesPerPixel)
    let renderTarget = RenderTargetDescriptor(
      format: r.format, internalBufferOffset: plan.offsets[0], address: r.colourAddress, rowStride: layout.rowStride,
      surfaceStride: layout.surfaceStride,
      clearWord: ColourFormat.packedClear(red: r.clear[0], green: r.clear[1], blue: r.clear[2], alpha: r.clear[3]))
    let framebuffer = FramebufferParameters(
      width: r.width, height: r.height, samplePattern: SamplePatterns.single,
      sampleLocations: va(samplesAt) + UInt64(SamplePatterns.blockBytes) * UInt64(SamplePatterns.single),
      effectiveTileLog2: plan.tileLog2, colourAllocationKiB: plan.allocationField, tiler: va(tilerAt))
    let vertexSPD = ShaderProgramDescriptor(
      stage: .vertex, registerClass: r.vertexShader?.registerClass ?? .r64,
      preloadMask: r.vertexShader?.preloadMask ?? TriangleShaders.positionPreloadMask, binary: va(vcodeAt))
    let fragmentSPD = ShaderProgramDescriptor(
      stage: .fragment, registerClass: r.fragmentShader?.registerClass ?? .r64,
      preloadMask: r.fragmentShader?.preloadMask ?? TriangleShaders.fragmentPreloadMask, binary: va(fcodeAt),
      coverageBitmaskType: 1)
    let blend = BlendDescriptor(renderTarget: 0, isSRGB: false)

    var state = IDVSState()
    var m = MemoryImage()
    var streams: [CSStream] = []
    var fbdPointer: UInt64 = 0
    var blendRegister: UInt64 = 0
    do throws(DescriptorError) {
      state.vertexFAU = try FAUPointer.value(address: va(fauAt), words: vertexSlots)
      if fragmentSlots > 0 { state.fragmentFAU = try FAUPointer.value(address: va(ffauAt), words: fragmentSlots) }
      blendRegister = try BlendDescriptor.register(address: va(blendAt), count: 1)
      fbdPointer = FramebufferParameters.taggedPointer(address: va(fbdAt), extensionPresent: false, renderTargetCount: 1)
      state.tilerContext = va(tilerAt)
    } catch { throw .descriptor(error) }
    state.vertexSPD = va(vspdAt)
    state.fragmentSPD = va(fspdAt)
    state.vertexTSD = va(tsdAt)
    state.fragmentTSD = va(tsdAt)
    state.indexCount = 3
    state.varySize = r.vertexShader?.varyingBytes ?? 0
    state.scissor = ScissorBox(width: r.width, height: r.height)
    state.viewport = Viewport(rectangle: state.scissor, minDepth: 0, maxDepth: 1)
    state.depthStencil = va(zsdAt)
    state.blend = blendRegister
    state.tilerFlags = PrimitiveFlags().word
    state.flags0 = DrawFlags0.colourOnly.word
    state.flags1 = DrawFlags1.word(renderTargetMask: 1)
    state.flags2 = DrawFlags2.word(writeMask: 1)

    // The streams (02 section 2.6): the tiling phase and the fragment phase.
    let tilingMask = UInt16(1) << UInt16(tilingSlot)
    let dataSlot = CSScoreboards.loadStoreSlot
    let syncVA = r.layout == .splitQueues ? va(syncAt) : 0
    let resourcesTiling: CSResources = .tiler | .idvs
    let fragmentSlot = r.layout == .singleQueue ? singleFragmentSlot : tilingSlot
    let fragmentMask = UInt16(1) << UInt16(fragmentSlot)

    func prologue(_ b: inout CSBuilder, resources: CSResources) {
      if r.initialiseQueues {
        b.initialiseSlotState()
        b.requestResources(resources)
      }
      b.move64(heapContextRegister, r.heapContext)
      b.emit(CSInstruction.heapSet(addressPair: heapContextRegister))
    }
    func tiling(_ b: inout CSBuilder) {
      b.emit(CSInstruction.setState(.endpointSlot, immediate: UInt32(tilingSlot)))
      b.emit(CSInstruction.heapOperation(.vertexTilerStarted))
      state.load(into: &b)
      b.emit(CSInstruction.runIDVS2())
      b.emit(CSInstruction.finishTiling)
      b.emit(CSInstruction.heapOperation(.vertexTilerCompleted, waitMask: tilingMask,
                                         signalSlot: CSScoreboards.deferredSyncSlot))
    }
    func fragment(_ b: inout CSBuilder) {
      b.emit(CSInstruction.setState(.endpointSlot, immediate: UInt32(fragmentSlot)))
      b.move64(40, fbdPointer)
      let box = framebuffer.boundingBoxRegisters
      b.move32(42, box.min)
      b.move32(43, box.max)
      b.emit(CSInstruction.runFragment())
      // The tiler's completed top and bottom (byte 40 and 48 of the context, 07 section 7.10), loaded once tiling is
      // done, and handed back to the heap when the pass's runs have drained (01 section 1.9.7).
      b.move64(completedAddressRegister, va(tilerAt) + UInt64(TilerContext.completedOffset))
      b.emit(CSInstruction.loadMultiple(base: completedTopRegister, address: completedAddressRegister, mask: 0xF))
      b.wait(mask: b.scoreboards.slotMask(dataSlot))
      b.emit(CSInstruction.finishFragment(
        firstChunkPair: completedTopRegister, lastChunkPair: completedBottomRegister, incrementFragmentCompleted: true,
        waitMask: fragmentMask, signalSlot: finishSlot))
    }
    func tail(_ b: inout CSBuilder) {
      b.waitAll()
      b.cleanCachesForHost()
    }

    var b0 = CSBuilder(address: va(stream0At), capacityBytes: max(capacity - stream0At, 0), registers: registers,
                       scoreboards: scoreboards)
    if r.layout == .singleQueue {
      prologue(&b0, resources: resourcesTiling | .fragment)
      tiling(&b0)
      // 01 section 1.9.7: the tiling is waited for through its endpoint slot (and the heap operation's).
      b0.wait(mask: tilingMask | b0.scoreboards.slotMask(CSScoreboards.deferredSyncSlot))
      fragment(&b0)
      tail(&b0)
      let s0: CSStream
      do throws(CSBuildError) { s0 = try b0.finish() } catch { throw .stream(error) }
      streams = [s0]
    } else {
      prologue(&b0, resources: resourcesTiling)
      tiling(&b0)
      // 02 section 2.4.3: the queue signals by adding 1 to its sync object once the tiling's slot has drained.
      b0.move64(syncAddressRegister, syncVA)
      b0.move64(syncValueRegister, 1)
      b0.emit(CSInstruction.syncAdd64(address: syncAddressRegister, value: syncValueRegister, waitMask: tilingMask,
                                      signalSlot: CSScoreboards.deferredSyncSlot, scope: .group))
      tail(&b0)
      let s0: CSStream
      do throws(CSBuildError) { s0 = try b0.finish() } catch { throw .stream(error) }
      let stream1At = alignUp(stream0At + s0.size, 64)
      var b1 = CSBuilder(address: va(stream1At), capacityBytes: max(capacity - stream1At, 0), registers: registers,
                         scoreboards: scoreboards)
      prologue(&b1, resources: .fragment)
      // 02 section 2.6.4 step 3: wait for the tiling's signal (the object starts at 1: one signal is a target of 1).
      b1.move64(syncAddressRegister, syncVA)
      b1.move64(syncValueRegister, 1)
      b1.emit(CSInstruction.syncWait64(address: syncAddressRegister, reference: syncValueRegister, condition: .greater))
      fragment(&b1)
      tail(&b1)
      let s1: CSStream
      do throws(CSBuildError) { s1 = try b1.finish() } catch { throw .stream(error) }
      streams = [s0, s1]
    }

    let total = (streams.count == 2 ? Int(streams[1].address - base) : stream0At) + (streams.last?.size ?? 0)
    guard total <= capacity else { throw .noRoom(needed: total, capacity: capacity) }

    // The block's bytes.
    m.extend(to: total)
    do throws(DescriptorError) {
      m.store(words: vertexSPD.words, at: vspdAt)
      m.store(words: fragmentSPD.words, at: fspdAt)
      m.store(words: LocalStorageDescriptor.none.words, at: tsdAt)
      m.store(words: blend.words, at: blendAt)
      m.store(words: DepthStencilDescriptor.disabled, at: zsdAt)
      m.store(words: try tiler.words(), at: tilerAt)
      m.store(words: try heap.words(), at: heapAt)
      m.store(words: try framebuffer.words(), at: fbdAt)
      m.store(words: try renderTarget.words(), at: fbdAt + FramebufferParameters.size)
    } catch { throw .descriptor(error) }
    m.store(bytes: SamplePatterns.table(), at: samplesAt)
    if let vs = r.vertexShader {
      // The root pointer is the first push constant; the table holds clip-space positions (the viewport's inverse).
      let viewport = ViewportTransform(width: Float(r.width), height: Float(r.height))
      let root = va(tableAt)
      let block = vs.layout.block(viewport: viewport, push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)])
      for (i, w) in block.enumerated() { m.store(w, at: fauAt + 8 * i) }
      for (i, v) in r.vertices.enumerated() {
        let clip = [
          (v.x - viewport.offset.x) / viewport.scale.x, (v.y - viewport.offset.y) / viewport.scale.y,
          (v.z - viewport.offset.z) / viewport.scale.z, 1 / v.reciprocalW,
        ]
        m.store(words: clip.map { bits($0) }, at: tableAt + i * TriangleShaders.positionBytes)
      }
    } else {
      m.store(va(tableAt), at: fauAt)
      for (i, v) in r.vertices.enumerated() {
        m.store(words: [bits(v.x), bits(v.y), bits(v.z), bits(v.reciprocalW)], at: tableAt + i * TriangleShaders.positionBytes)
      }
    }
    if let fs = r.fragmentShader, fragmentSlots > 0 {
      for (i, w) in fs.layout.block().enumerated() { m.store(w, at: ffauAt + 8 * i) }
    }
    m.store(words: vertexWords, at: vcodeAt)
    m.store(words: fragmentWords, at: fcodeAt)
    if r.layout == .splitQueues { m.store(UInt64(1), at: syncAt) }
    for s in streams { m.store(words: s.words, at: Int(s.address - base)) }

    return RenderPassImage(
      memory: m, base: base, streams: streams, plan: plan, hierarchyMask: mask, tilerContext: va(tilerAt),
      heapDescriptor: va(heapAt), framebuffer: va(fbdAt), renderTarget: va(fbdAt + FramebufferParameters.size),
      sampleTable: va(samplesAt), blend: va(blendAt), depthStencil: va(zsdAt), vertexTable: va(tableAt),
      vertexShader: va(vcodeAt), fragmentShader: va(fcodeAt), vertexSPD: va(vspdAt), fragmentSPD: va(fspdAt),
      localStorage: va(tsdAt), syncObject: syncVA, draw: state, fragmentPointer: fbdPointer)
  }
}
