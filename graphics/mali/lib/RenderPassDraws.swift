// SPDX-License-Identifier: BSD-3-Clause

// A render pass of compiled draws (D174 step 3): the pass of RenderPass.swift with a list of draws in place of its one
// triangle. Each draw has its own shaders, push constants, blend descriptor and heap handles; they run one after the
// other in the one tiler pass, so a later draw blends over an earlier one in the tile buffer (a pass that loads its
// target from memory needs frame shaders, 08, which this recipe does not make). Textures are the descriptor heap
// (Images.swift): the caller lays the heap, its texels and its plane descriptors in memory of its own and tells the
// recipe where the heap is; the recipe makes the resource table (one 64-byte block, the heap as table 1) and gives
// the fragment stage its address as `FRAGMENT_SRT`. The streams are RenderPass.build's (02 section 2.6).

/// An index buffer's width: the tiler's index type (06 section 6.4.2, flags `[10:8]`: 2 is 16 bits, 3 is 32).
public enum IndexSize: UInt32, Sendable {
  case u16 = 2
  case u32 = 3
  public var bytes: Int { self == .u16 ? 2 : 4 }
}

/// The index data of an indexed draw: where it starts (not advanced by the first index), and the bytes from there to
/// the end of the bound range (`INDEX_BUFFER_SIZE`).
public struct IndexSource: Sendable, Equatable {
  public var address: UInt64
  public var bytes: UInt32
  public var size: IndexSize
  public init(address: UInt64, bytes: UInt32, size: IndexSize) {
    self.address = address
    self.bytes = bytes
    self.size = size
  }
}

/// A draw whose counts the stream loads from memory when it runs (02 section 2.6: the stream reads argument buffers
/// itself): the words at `address` are one draw's arguments, `vertexCount, instanceCount, firstVertex,
/// firstInstance` (four words) or, with an index source, `indexCount, instanceCount, firstIndex, vertexOffset,
/// firstInstance` (five).
public struct IndirectArguments: Sendable, Equatable {
  public var address: UInt64
  public init(address: UInt64) { self.address = address }
}

/// One draw of a pass.
public struct PassDraw: Sendable {
  public var vertexShader: VertexShader
  public var fragmentShader: FragmentShader
  /// The vertices (non-indexed) and the instances.
  public var vertexCount: Int
  public var instanceCount: Int
  /// The push constants, the same words for both stages.
  public var push: [UInt32]
  /// The blend descriptor of the pass's one colour target (09: the position must equal the target).
  public var blend: BlendDescriptor
  /// The heap handle of element 0 of each image and sampler binding the fragment shader names, and the dummy sampler's.
  public var images: [BindingHandle]
  public var dummySampler: UInt32
  /// `RUN_IDVS2`'s vertex shading mode (01 section 1.9.3): early (false, the reference driver's) or deferred.
  public var deferredShading = false
  /// `VARY_SIZE` when it is not the vertex shader's own `varyingBytes` (06 section 6.6.2), for probes.
  public var varyingBytes: UInt32?
  /// The index data (an indexed draw), the first index and the base vertex added to each index; for a draw with no
  /// index data, `vertexOffset` is the first vertex (06 section 6.4.2).
  public var indices: IndexSource?
  public var firstIndex: UInt32 = 0
  public var vertexOffset: Int32 = 0
  public var firstInstance: UInt32 = 0
  /// Counts read from memory by the stream (then `vertexCount` and `instanceCount` are unused).
  public var indirect: IndirectArguments?
  /// The address of the 64-bit counter of the active occlusion query (06 section 6.11), or 0: the draw counts the samples
  /// that pass into it.
  public var occlusionQuery: UInt64 = 0
  /// Bits of draw flags 0 to set and to clear after the recipe has made the word, for probes.
  public var flags0Or: UInt32 = 0
  public var flags0Clear: UInt32 = 0
  /// The fixed-function state beyond the colour-only opaque triangle list (PipelineState.swift): the primitive mode, culling, the
  /// depth/stencil test, a viewport and scissor.
  public var state = DrawPipelineState()
  /// The blend descriptors of the pass's colour targets after the first, in order (each one's `renderTarget` is its index, 09 section 9.2.3).
  public var extraBlends: [BlendDescriptor] = []

  public init(
    vertexShader: VertexShader, fragmentShader: FragmentShader, vertexCount: Int, instanceCount: Int = 1, push: [UInt32] = [],
    blend: BlendDescriptor = BlendDescriptor(renderTarget: 0), images: [BindingHandle] = [], dummySampler: UInt32 = 0
  ) {
    self.vertexShader = vertexShader
    self.fragmentShader = fragmentShader
    self.vertexCount = vertexCount
    self.instanceCount = instanceCount
    self.push = push
    self.blend = blend
    self.images = images
    self.dummySampler = dummySampler
  }
}

/// A colour target after the first (08 section 8.4): a pass has up to eight, each its own image of the same size.
public struct ExtraColourTarget: Sendable {
  public var format: ColourFormat
  public var address: UInt64
  public var clear: [Float]
  public init(format: ColourFormat, address: UInt64, clear: [Float]) {
    self.format = format
    self.address = address
    self.clear = clear
  }
}

/// A binding's element 0 in the heap: the handle (`DescriptorHeap.handle(index:)`).
public struct BindingHandle: Equatable, Sendable {
  public var set: Int
  public var binding: Int
  public var handle: UInt32
  public init(set: Int, binding: Int, handle: UInt32) {
    self.set = set
    self.binding = binding
    self.handle = handle
  }
}

/// A pass's first pre-frame shader (08 section 8.10): a fragment shader the hardware runs once for each tile before the
/// pass's draws, through a draw descriptor. It loads the target's colour from the image into the tile (it reads the
/// image through a heap of its own and writes the colour the opaque blend stores in the tile), so the pass draws over what
/// was there.
public struct FramePreload: Sendable {
  public var shader: FragmentShader
  /// The shader's heap in GPU memory (64-byte aligned) and its size in bytes, and the handles of its bindings' element 0.
  public var heapAddress: UInt64
  public var heapBytes: Int
  public var images: [BindingHandle]
  public var dummySampler: UInt32
  /// The shader's push words.
  public var push: [UInt32]
  /// Whether the target is an sRGB format (its blend descriptor decodes and encodes).
  public var isSRGB: Bool

  public init(shader: FragmentShader, heapAddress: UInt64, heapBytes: Int, images: [BindingHandle], dummySampler: UInt32 = 0,
              push: [UInt32] = [], isSRGB: Bool = false) {
    self.shader = shader
    self.heapAddress = heapAddress
    self.heapBytes = heapBytes
    self.images = images
    self.dummySampler = dummySampler
    self.push = push
    self.isSRGB = isSRGB
  }
}

/// What to draw and where, as RenderPassRequest has it, with draws.
public struct DrawPassRequest: Sendable {
  /// The target's contents are loaded into the tile first (nil: the clear colour fills it).
  public var preload: FramePreload?
  public var width: Int
  public var height: Int
  public var format: ColourFormat
  public var colourAddress: UInt64
  public var clear: [Float]
  public var draws: [PassDraw]
  /// The descriptor heap in GPU memory (64-byte aligned) and its size in bytes; nil when no draw samples.
  public var heapAddress: UInt64?
  public var heapBytes: Int
  /// The storage images' descriptors (table 2) in GPU memory (64-byte aligned) and their size in bytes; nil when no
  /// draw names a storage image.
  public var storageAddress: UInt64?
  public var storageBytes: Int = 0
  public var heapContext: UInt64
  public var heapChunk: UInt64
  public var heapChunkBytes: UInt64
  public var geometryBuffer: UInt64
  public var tileBuffer: TileBuffer
  public var layout: RenderQueueLayout
  public var initialiseQueues: Bool
  /// Thread storage for the stack and spills of the draws' shaders (04 section 4.7.2): the one TSD of the pass covers the
  /// largest `stackBytes` of any shader, and `threadStorage` is `ThreadStorageSizing.tlsTotal` bytes at a 4096-byte
  /// aligned address (0 when no shader has a stack). `limits` are the GPU's thread limits.
  public var threadStorage: UInt64
  public var limits: ComputeLimits?
  /// The 64-bit reports of the pass's occlusion queries (06 section 6.11.1): the fragment queue zeroes each with a store
  /// and flushes the stores before its fragment work, so a report starts at zero in the GPU's own view of memory.
  public var queryReports: [UInt64] = []
  /// For a probe of the hardware (06 section 6.11.1's next experiment): where the fragment queue, after its clean flush,
  /// loads the first report through the GPU and stores the two 32-bit words it read (the report) at this address, to tell a lost update from a missing flush.
  public var queryReadback: UInt64?
  /// The depth and stencil target; nil for a pass with none (PipelineState.swift).
  public var zs: ZSTarget?
  /// The colour targets after the first (08 section 8.4); with any, a pass can't keep its target's contents.
  public var extraTargets: [ExtraColourTarget] = []

  /// The most stack any shader of the pass needs.
  public var stackBytes: UInt32 {
    var most: UInt32 = 0
    for d in draws { most = max(most, d.vertexShader.stackBytes, d.fragmentShader.stackBytes) }
    if let p = preload { most = max(most, p.shader.stackBytes) }
    return most
  }

  public init(
    width: Int, height: Int, format: ColourFormat, colourAddress: UInt64, clear: [Float] = [0, 0, 0, 1], draws: [PassDraw],
    heapAddress: UInt64? = nil, heapBytes: Int = 0, heapContext: UInt64, heapChunk: UInt64, heapChunkBytes: UInt64,
    geometryBuffer: UInt64, tileBuffer: TileBuffer = .g720, layout: RenderQueueLayout = .splitQueues, initialiseQueues: Bool = true,
    threadStorage: UInt64 = 0, limits: ComputeLimits? = nil
  ) {
    self.threadStorage = threadStorage
    self.limits = limits
    self.width = width
    self.height = height
    self.format = format
    self.colourAddress = colourAddress
    self.clear = clear
    self.draws = draws
    self.heapAddress = heapAddress
    self.heapBytes = heapBytes
    self.heapContext = heapContext
    self.heapChunk = heapChunk
    self.heapChunkBytes = heapChunkBytes
    self.geometryBuffer = geometryBuffer
    self.tileBuffer = tileBuffer
    self.layout = layout
    self.initialiseQueues = initialiseQueues
  }
}

extension RenderPass {
  /// Where the records of a draw are, for the tests: the blend descriptor, the two FAU blocks and the shaders' SPDs.
  public struct DrawRecords: Equatable, Sendable {
    public var blend: UInt64
    public var vertexFAU: UInt64
    public var fragmentFAU: UInt64
    public var vertexSPD: UInt64
    public var fragmentSPD: UInt64
    public var state: IDVSState
  }

  /// The pass's draws, laid out in GPU memory at `base`; `image.draw` is the last draw's state and `records` each.
  public static func build(
    at base: UInt64, capacity: Int, request r: DrawPassRequest, registers: CSRegisterMap, scoreboards: CSScoreboards, arch: Int = 12
  ) throws(RenderError) -> (image: RenderPassImage, records: [DrawRecords], resourceTable: UInt64) {
    guard arch >= 12, arch <= 13 else { throw .arch(arch) }
    guard !r.draws.isEmpty, r.draws.count <= 16, r.clear.count == 4, r.width >= 1, r.height >= 1, r.width <= 4096,
      r.height <= 4096
    else { throw .badRequest }
    guard base & 63 == 0 else { throw .descriptor(.misaligned) }
    for d in r.draws {
      guard d.indirect != nil || (d.vertexCount >= d.state.minimumVertices && d.instanceCount >= 1), d.blend.renderTarget == 0 else {
        throw .badRequest
      }
      guard d.occlusionQuery & 7 == 0 else { throw .badRequest }
      if let i = d.indirect { guard i.address & 3 == 0 else { throw .badRequest } }
    }
    let targetCount = 1 + r.extraTargets.count
    guard targetCount <= 8, r.preload == nil || targetCount == 1 else { throw .badRequest }
    for d in r.draws { guard d.extraBlends.count == targetCount - 1 else { throw .badRequest } }
    for t in r.extraTargets { guard t.clear.count == 4, t.address & 63 == 0 else { throw .badRequest } }
    guard let plan = TilePlan.make(r.tileBuffer, bytesPerSample: [Int](repeating: ColourFormat.bytesPerPixel, count: targetCount), samples: 1) else {
      throw .badRequest
    }
    guard let mask = HierarchyMask.select(width: r.width, height: r.height, tilePixels: plan.tilePixels, maxLevels: 4,
                                         chunkBytes: Int(r.heapChunkBytes), arch: arch)
    else { throw .badRequest }
    // The thread storage descriptor of the pass: no stack, or the one the largest shader needs, packed (04 section 4.5.2).
    var tsd = LocalStorageDescriptor.none
    if r.stackBytes != 0 {
      guard r.limits != nil, r.threadStorage != 0 else { throw .needsThreadStorage }
      guard r.threadStorage & 4095 == 0 else { throw .descriptor(.misaligned) }
      tsd.tlsSize = ThreadStorageSizing.tlsField(stackBytes: r.stackBytes)
      tsd.tlsBase = r.threadStorage
      tsd.addressMode = .packed
    }

    var offset = 0
    func place(_ size: Int, _ align: Int) -> Int {
      offset = alignUp(offset, align)
      let at = offset
      offset += size
      return at
    }
    // The shared records, then each distinct shader's SPD and code, then each draw's blend and FAU blocks.
    let tsdAt = place(LocalStorageDescriptor.size, LocalStorageDescriptor.alignment)
    let zsdAt = place(DepthStencilDescriptor.size, DepthStencilDescriptor.alignment)
    let tilerAt = place(TilerContext.size, TilerContext.alignment)
    let heapAt = place(TilerHeapDescriptor.size, TilerHeapDescriptor.alignment)
    let zsExtension = r.zs != nil
    let fbdAt = place(groupBytes + (zsExtension ? ZSTarget.size : 0) + 64 * (targetCount - 1), 64)
    // A draw whose state has a depth/stencil test has a descriptor of its own.
    var drawZSDAt: [Int] = []
    func zsState(_ d: PassDraw) -> ZSDescriptorState? {
      // A shader that writes the depth takes the depth source from the shader (6.8.3), whatever the state.
      var z = d.state.depthStencil
      if r.zs != nil && d.fragmentShader.writesDepth {
        z = z ?? ZSDescriptorState()
        z!.depthFromShader = true
      }
      return z
    }
    for d in r.draws { drawZSDAt.append(zsState(d) != nil ? place(DepthStencilDescriptor.size, DepthStencilDescriptor.alignment) : -1) }
    let samplesAt = place(SamplePatterns.tableBytes, 64)
    let tableAt = r.heapAddress == nil && r.storageAddress == nil ? -1 : place(DescriptorHeap.tableEntries * ResourceTable.entrySize, ResourceTable.alignment)
    var shaders: [(code: [UInt64], spd: Int, at: Int)] = []
    func shaderSlot(_ code: [UInt64]) -> Int {
      for (n, s) in shaders.enumerated() where s.code == code { return n }
      let spd = place(ShaderProgramDescriptor.size, ShaderProgramDescriptor.alignment)
      shaders.append((code, spd, 0))
      return shaders.count - 1
    }
    var vslot: [Int] = []
    var fslot: [Int] = []
    for d in r.draws {
      vslot.append(shaderSlot(d.vertexShader.code))
      fslot.append(shaderSlot(d.fragmentShader.code))
    }
    for n in 0..<shaders.count { shaders[n].at = place(shaders[n].code.count * 8, 128) }
    var blendAt: [Int] = []
    var vfauAt: [Int] = []
    var ffauAt: [Int] = []
    for d in r.draws {
      blendAt.append(place(BlendDescriptor.size * targetCount, 64))
      vfauAt.append(place(8 * max(d.vertexShader.layout.slots, 1), 8))
      ffauAt.append(place(8 * d.fragmentShader.layout.slots, 8))
    }
    // The first pre-frame shader (08 section 8.10): the three frame shaders' draw descriptors (the other two never run),
    // its blend descriptor, push words, resource table (its own heap), program descriptor and code.
    var dcdAt = 0, preBlendAt = 0, preFAUAt = 0, preTableAt = 0, preSPDAt = 0, preCodeAt = 0
    if let p = r.preload {
      dcdAt = place(3 * 128, 64)
      preBlendAt = place(BlendDescriptor.size, 64)
      preFAUAt = place(8 * max(p.shader.layout.slots, 1), 8)
      preTableAt = place(DescriptorHeap.tableEntries * ResourceTable.entrySize, ResourceTable.alignment)
      preSPDAt = place(ShaderProgramDescriptor.size, ShaderProgramDescriptor.alignment)
      preCodeAt = place(p.shader.code.count * 8, 128)
    }
    let syncAt = r.layout == .splitQueues ? place(16, 64) : 0
    let stream0At = place(0, 64)

    func va(_ at: Int) -> UInt64 { base + UInt64(at) }

    let tiler = TilerContext(
      hierarchyMask: mask, samplePattern: SamplePatterns.single, firstProvokingVertex: true,
      effectiveTileLog2: plan.tileLog2, width: r.width, height: r.height, heap: va(heapAt),
      geometryBuffer: r.geometryBuffer)
    let heap = TilerHeapDescriptor(chunkBytes: r.heapChunkBytes, firstChunk: r.heapChunk)
    let layout = LinearLayout(width: r.width, height: r.height, bytesPerPixel: ColourFormat.bytesPerPixel)
    let renderTarget = RenderTargetDescriptor(
      format: r.format, internalBufferOffset: plan.offsets[0], address: r.colourAddress, rowStride: layout.rowStride,
      surfaceStride: layout.surfaceStride,
      clearWord: ColourFormat.packedClear(
        red: r.clear[0], green: r.clear[1], blue: r.clear[2], alpha: r.clear[3], srgb: r.format.isSRGB))
    let rtAt = fbdAt + FramebufferParameters.size + (zsExtension ? ZSTarget.size : 0)
    var framebuffer = FramebufferParameters(
      width: r.width, height: r.height, samplePattern: SamplePatterns.single,
      sampleLocations: va(samplesAt) + UInt64(SamplePatterns.blockBytes) * UInt64(SamplePatterns.single),
      effectiveTileLog2: plan.tileLog2, colourAllocationKiB: plan.allocationField, tiler: va(tilerAt))
    framebuffer.zs = r.zs
    framebuffer.renderTargetCount = targetCount
    if r.preload != nil {
      framebuffer.preFrame0Mode = 1
      framebuffer.frameShaderDCDs = va(dcdAt)
    }
    /// The first frame shader's draw descriptor (06 section 6.13; 08 section 8.10.3), when there is one.
    var preDCD = [UInt32](repeating: 0, count: 32)
    var preFAUWords: [UInt64] = []
    var preTableBytes: [UInt8] = []
    var preSPDWords: [UInt32] = []

    var states: [IDVSState] = []
    var records: [DrawRecords] = []
    var fbdPointer: UInt64 = 0
    var resourcePointer: UInt64 = 0
    do throws(DescriptorError) {
      fbdPointer = FramebufferParameters.taggedPointer(address: va(fbdAt), extensionPresent: zsExtension, renderTargetCount: targetCount)
      if tableAt >= 0 { resourcePointer = try ResourceTable.pointer(address: va(tableAt), entryCount: DescriptorHeap.tableEntries) }
      if let p = r.preload {
        // Colour only, forced early, forward pixel kill allowed both ways, and the shader's output counts as writing the
        // tile (clean fragment write, flags 0 `[9]`): the table of 8.10.3.
        var f0 = DrawFlags0.colourOnly
        f0.pixelKill = .forceEarly
        f0.zsUpdate = .forceEarly
        preDCD[0] = f0.word | 1 << 9
        preDCD[1] = DrawFlags1.word(renderTargetMask: 1)
        preDCD[5] = DrawFlags2.word(writeMask: 1)
        let zsd = va(zsdAt)
        preDCD[10] = UInt32(truncatingIfNeeded: zsd)
        preDCD[11] = UInt32(truncatingIfNeeded: zsd >> 32)
        let blendRegister = try BlendDescriptor.register(address: va(preBlendAt), count: 1)
        preDCD[12] = UInt32(truncatingIfNeeded: blendRegister)
        preDCD[13] = UInt32(truncatingIfNeeded: blendRegister >> 32)
        let table = try ResourceTable.pointer(address: va(preTableAt), entryCount: DescriptorHeap.tableEntries)
        preDCD[24] = UInt32(truncatingIfNeeded: table)
        preDCD[25] = UInt32(truncatingIfNeeded: table >> 32)
        let spd = va(preSPDAt)
        preDCD[26] = UInt32(truncatingIfNeeded: spd)
        preDCD[27] = UInt32(truncatingIfNeeded: spd >> 32)
        let tsdPointer = va(tsdAt)
        preDCD[28] = UInt32(truncatingIfNeeded: tsdPointer)
        preDCD[29] = UInt32(truncatingIfNeeded: tsdPointer >> 32)
        if p.shader.layout.slots > 0 {
          let fau = try FAUPointer.value(address: va(preFAUAt), words: p.shader.layout.slots)
          preDCD[30] = UInt32(truncatingIfNeeded: fau)
          preDCD[31] = UInt32(truncatingIfNeeded: fau >> 32)
        }
        let handles = p.images.map { (set: $0.set, binding: $0.binding, handle: $0.handle) }
        preFAUWords = p.shader.layout.block(push: p.push, images: handles, dummySampler: p.dummySampler)
        preTableBytes = try DescriptorHeap.resourceTable(heapAddress: p.heapAddress, heapBytes: p.heapBytes)
        preSPDWords = ShaderProgramDescriptor(
          stage: .fragment, registerClass: p.shader.registerClass, preloadMask: p.shader.preloadMask, binary: va(preCodeAt),
          coverageBitmaskType: 1).words
      }
      for (n, d) in r.draws.enumerated() {
        var s = IDVSState()
        s.vertexFAU = try FAUPointer.value(address: va(vfauAt[n]), words: max(d.vertexShader.layout.slots, 1))
        if d.fragmentShader.layout.slots > 0 {
          s.fragmentFAU = try FAUPointer.value(address: va(ffauAt[n]), words: d.fragmentShader.layout.slots)
        }
        s.blend = try BlendDescriptor.register(address: va(blendAt[n]), count: targetCount)
        s.tilerContext = va(tilerAt)
        s.fragmentSRT = resourcePointer
        s.vertexSPD = va(shaders[vslot[n]].spd)
        s.fragmentSPD = va(shaders[fslot[n]].spd)
        s.vertexTSD = va(tsdAt)
        s.fragmentTSD = va(tsdAt)
        s.indexCount = UInt32(max(d.vertexCount, 0))
        s.instanceCount = UInt32(max(d.instanceCount, 0))
        s.indexOffset = d.firstIndex
        s.vertexOffset = UInt32(bitPattern: d.vertexOffset)
        s.instanceOffset = d.firstInstance
        if let ix = d.indices {
          s.indexBuffer = ix.address
          s.indexBufferSize = ix.bytes
        }
        s.occlusionQuery = d.occlusionQuery
        s.varySize = d.varyingBytes ?? d.vertexShader.varyingBytes
        let whole = ScissorBox(width: r.width, height: r.height)
        s.scissor = d.state.scissor ?? whole
        let vp = d.state.viewport
        s.viewport = Viewport(
          rectangle: vp?.box(width: r.width, height: r.height) ?? whole, minDepth: vp?.minDepth ?? 0, maxDepth: vp?.maxDepth ?? 1)
        s.depthStencil = va(zsState(d) != nil ? drawZSDAt[n] : zsdAt)
        s.tilerFlags = PrimitiveFlags(
          mode: d.state.mode, indexType: d.indices?.size.rawValue ?? 0, lowDepthCull: d.state.depthStencil?.depthClip ?? true,
          highDepthCull: d.state.depthStencil?.depthClip ?? true, primitiveRestart: d.state.primitiveRestart,
          secondaryShader: s.varySize > 0).word
        s.primitiveSize = d.state.primitiveSize.bitPattern
        // 6.10.3: a fragment of this draw may kill an earlier one only if the draw neither reads the destination nor can
        // discard.
        var flags = DrawFlags0.colourOnly
        var readsDestination = d.blend.blend.loadDestination
        for b in d.extraBlends where b.blend.loadDestination { readsDestination = true }
        flags.allowForwardPixelToKill = !readsDestination && !d.fragmentShader.discards
        // 6.9.1 `[20]`: the shader writes the sample mask or may discard.
        flags.shaderModifiesCoverage = d.fragmentShader.discards || d.fragmentShader.writesSampleMask
        let triangles = d.state.mode == .triangles || d.state.mode == .triangleStrip || d.state.mode == .triangleFan
        flags.frontFaceCCW = d.state.frontFaceCCW
        flags.cullFront = triangles && d.state.cullFront
        flags.cullBack = triangles && d.state.cullBack
        if r.zs != nil {
          // 6.10.2: early or late, from the shader and the state.
          let zsd = zsState(d)
          var storage = false
          for b in d.fragmentShader.layout.imageBindings where b.binding == 2 { storage = true }
          let ops = PixelOperations.derive(
            sw: d.fragmentShader.writesDepth, wzo: (zsd?.writes ?? false) || d.occlusionQuery != 0, ac: false,
            lc: d.fragmentShader.discards || d.fragmentShader.writesSampleMask, se: storage,
            eft: d.fragmentShader.earlyFragmentTests, pass: zsd == nil || (zsd!.depthAlwaysPasses && zsd!.stencilAlwaysPasses))
          flags.pixelKill = ops.kill
          flags.zsUpdate = ops.update
          if d.fragmentShader.writesDepth { flags.allowForwardPixelToKill = false }
        }
        if d.occlusionQuery != 0 {
          // 6.10.2: an active query is a write (WZO), so a shader that can alter coverage updates late. A fragment that
          // a later one kills would not be counted, so the draw is not one that kills (a count is of samples that pass).
          if d.fragmentShader.discards { flags.zsUpdate = .forceLate }
          flags.allowForwardPixelToKill = false
        }
        s.flags0 = (flags.word | (d.occlusionQuery != 0 ? 3 << 14 : 0) | d.flags0Or) & ~d.flags0Clear
        // The render targets the fragment shader writes (06 section 6.9.2): one target, the colour output; several, the outputs' locations.
        var written: UInt32 = 1
        if targetCount > 1 {
          written = 0
          for l in d.fragmentShader.colourTargets where l >= 0 && l < targetCount { written |= 1 << UInt32(l) }
        }
        s.flags1 = DrawFlags1.word(sampleMask: d.state.sampleMask, renderTargetMask: written)
        s.flags2 = DrawFlags2.word(writeMask: written)
        states.append(s)
        records.append(
          DrawRecords(
            blend: va(blendAt[n]), vertexFAU: va(vfauAt[n]), fragmentFAU: va(ffauAt[n]), vertexSPD: s.vertexSPD,
            fragmentSPD: s.fragmentSPD, state: s))
      }
    } catch { throw .descriptor(error) }

    // The streams (02 section 2.6): the tiling phase, the draws one after the other, and the fragment phase.
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
      for (n, s) in states.enumerated() {
        s.load(into: &b)
        if let a = r.draws[n].indirect {
          // The counts come from memory when the stream runs: the words land in the count registers (33 to 37) and the
          // run waits for the load (01 section 1.4.2, a load signals the load/store slot).
          b.move64(heapContextRegister, a.address)
          if r.draws[n].indices != nil {
            b.emit(CSInstruction.loadMultiple(base: IDVSState.Register.indexCount, address: heapContextRegister, mask: 0b11111))
          } else {
            // vertexCount, instanceCount, firstVertex, firstInstance: registers 33, 34, 36 and 37.
            b.emit(CSInstruction.loadMultiple(base: IDVSState.Register.indexCount, address: heapContextRegister, mask: 0b11011))
          }
          b.wait(mask: b.scoreboards.slotMask(dataSlot))
        }
        if r.draws[n].indirect != nil {
          // 06 section 6.4.7: what the hardware does for a zero count is no source's to say, so the stream does not issue
          // the run for one: it branches over it when the count of vertices or indices, or of instances, is zero.
          b.emit(CSInstruction.branch(.equal, register: IDVSState.Register.indexCount, offset: 2))
          b.emit(CSInstruction.branch(.equal, register: IDVSState.Register.instanceCount, offset: 1))
        }
        b.emit(CSInstruction.runIDVS2(deferredShading: r.draws[n].deferredShading))
      }
      b.emit(CSInstruction.finishTiling)
      b.emit(CSInstruction.heapOperation(.vertexTilerCompleted, waitMask: tilingMask, signalSlot: CSScoreboards.deferredSyncSlot))
    }
    func fragment(_ b: inout CSBuilder) {
      b.emit(CSInstruction.setState(.endpointSlot, immediate: UInt32(fragmentSlot)))
      b.move64(40, fbdPointer)
      let box = framebuffer.boundingBoxRegisters
      b.move32(42, box.min)
      b.move32(43, box.max)
      b.emit(CSInstruction.runFragment())
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
    // 06 section 6.11.1 item 3: a query's report is zeroed by a store on the fragment queue, followed by a flush of
    // stores, before the pass's fragment work; the clean flush of the tail after it hands the count to the CPU.
    func zeroReports(_ b: inout CSBuilder) {
      guard !r.queryReports.isEmpty else { return }
      let address = 72  // the completed-chunk registers (72 to 77), which the fragment run loads after this
      b.move32(address + 2, 0)
      b.move32(address + 3, 0)
      for report in r.queryReports {
        b.move64(address, report)
        b.emit(CSInstruction.storeMultiple(base: address + 2, address: address, mask: 0b11))
        b.wait(mask: b.scoreboards.slotMask(dataSlot))
      }
      b.cleanCachesForHost()
    }

    func readbackReport(_ b: inout CSBuilder) {
      guard let into = r.queryReadback, let report = r.queryReports.first else { return }
      let address = 72  // the completed-chunk registers (72 to 77), which the fragment run loads after this
      b.move64(address, report)
      b.emit(CSInstruction.loadMultiple(base: address + 4, address: address, mask: 0b11))
      b.wait(mask: b.scoreboards.slotMask(dataSlot))
      b.move64(address + 2, into)
      b.emit(CSInstruction.storeMultiple(base: address + 4, address: address + 2, mask: 0b11))
      b.wait(mask: b.scoreboards.slotMask(dataSlot))
      b.cleanCachesForHost()
    }

    var streams: [CSStream] = []
    var b0 = CSBuilder(address: va(stream0At), capacityBytes: max(capacity - stream0At, 0), registers: registers,
                       scoreboards: scoreboards)
    if r.layout == .singleQueue {
      prologue(&b0, resources: resourcesTiling | .fragment)
      tiling(&b0)
      b0.wait(mask: tilingMask | b0.scoreboards.slotMask(CSScoreboards.deferredSyncSlot))
      zeroReports(&b0)
      fragment(&b0)
      tail(&b0)
      readbackReport(&b0)
      let s0: CSStream
      do throws(CSBuildError) { s0 = try b0.finish() } catch { throw .stream(error) }
      streams = [s0]
    } else {
      prologue(&b0, resources: resourcesTiling)
      tiling(&b0)
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
      b1.move64(syncAddressRegister, syncVA)
      b1.move64(syncValueRegister, 1)
      zeroReports(&b1)
      b1.emit(CSInstruction.syncWait64(address: syncAddressRegister, reference: syncValueRegister, condition: .greater))
      fragment(&b1)
      tail(&b1)
      readbackReport(&b1)
      let s1: CSStream
      do throws(CSBuildError) { s1 = try b1.finish() } catch { throw .stream(error) }
      streams = [s0, s1]
    }

    let total = (streams.count == 2 ? Int(streams[1].address - base) : stream0At) + (streams.last?.size ?? 0)
    guard total <= capacity else { throw .noRoom(needed: total, capacity: capacity) }

    // The block's bytes.
    var m = MemoryImage()
    m.extend(to: total)
    do throws(DescriptorError) {
      m.store(words: tsd.words, at: tsdAt)
      m.store(words: DepthStencilDescriptor.disabled, at: zsdAt)
      m.store(words: try tiler.words(), at: tilerAt)
      m.store(words: try heap.words(), at: heapAt)
      m.store(words: try framebuffer.words(), at: fbdAt)
      if let z = r.zs { m.store(words: try z.words(), at: fbdAt + FramebufferParameters.size) }
      m.store(words: try renderTarget.words(), at: rtAt)
      for (i, t) in r.extraTargets.enumerated() {
        let extra = RenderTargetDescriptor(
          format: t.format, internalBufferOffset: plan.offsets[i + 1], address: t.address, rowStride: layout.rowStride,
          surfaceStride: layout.surfaceStride,
          clearWord: ColourFormat.packedClear(red: t.clear[0], green: t.clear[1], blue: t.clear[2], alpha: t.clear[3], srgb: t.format.isSRGB))
        m.store(words: try extra.words(), at: rtAt + 64 * (i + 1))
      }
      for (n, d) in r.draws.enumerated() { if let z = zsState(d) { m.store(words: z.words, at: drawZSDAt[n]) } }
      if tableAt >= 0 {
        m.store(
          bytes: try DescriptorHeap.resourceTable(
            textures: r.heapAddress.map { ($0, r.heapBytes) }, storage: r.storageAddress.map { ($0, r.storageBytes) }),
          at: tableAt)
      }
    } catch { throw .descriptor(error) }
    m.store(bytes: SamplePatterns.table(), at: samplesAt)
    if let p = r.preload {
      m.store(words: preDCD, at: dcdAt)
      m.store(words: BlendDescriptor(renderTarget: 0, isSRGB: p.isSRGB).words, at: preBlendAt)
      for (i, w) in preFAUWords.enumerated() { m.store(w, at: preFAUAt + 8 * i) }
      m.store(bytes: preTableBytes, at: preTableAt)
      m.store(words: preSPDWords, at: preSPDAt)
      m.store(words: p.shader.code, at: preCodeAt)
    }
    for s in shaders { m.store(words: s.code, at: s.at) }
    for (n, d) in r.draws.enumerated() {
      let vs = d.vertexShader
      let fs = d.fragmentShader
      let vp = d.state.viewport ?? DrawViewport(x: 0, y: 0, width: Float(r.width), height: Float(r.height))
      let viewport = ViewportTransform(x: vp.x, y: vp.y, width: vp.width, height: vp.height, minDepth: vp.minDepth, maxDepth: vp.maxDepth)
      let vblock = vs.layout.block(viewport: viewport, push: d.push)
      for (i, w) in vblock.enumerated() { m.store(w, at: vfauAt[n] + 8 * i) }
      let handles = d.images.map { (set: $0.set, binding: $0.binding, handle: $0.handle) }
      let fblock = fs.layout.block(push: d.push, images: handles, dummySampler: d.dummySampler)
      for (i, w) in fblock.enumerated() { m.store(w, at: ffauAt[n] + 8 * i) }
      m.store(words: d.blend.words, at: blendAt[n])
      // A target the shader doesn't write has a descriptor that is off (09 section 9.3).
      for (i, b) in d.extraBlends.enumerated() {
        var written = false
        for l in d.fragmentShader.colourTargets where l == i + 1 { written = true }
        m.store(words: written ? b.words : [0, 0, 3, 0], at: blendAt[n] + BlendDescriptor.size * (i + 1))
      }
    }
    for (n, s) in shaders.enumerated() {
      // Each shader's program descriptor: the stage of the draws that use it.
      var stage = ShaderProgramDescriptor.Stage.vertex
      var cls = RegisterClass.r64
      var preload: UInt16 = 0
      for (k, d) in r.draws.enumerated() {
        if vslot[k] == n {
          stage = .vertex
          cls = d.vertexShader.registerClass
          preload = d.vertexShader.preloadMask
        }
        if fslot[k] == n {
          stage = .fragment
          cls = d.fragmentShader.registerClass
          preload = d.fragmentShader.preloadMask
        }
      }
      let spd = ShaderProgramDescriptor(
        stage: stage, registerClass: cls, preloadMask: preload, binary: va(s.at), coverageBitmaskType: stage == .fragment ? 1 : 0)
      m.store(words: spd.words, at: s.spd)
    }
    if r.layout == .splitQueues { m.store(UInt64(1), at: syncAt) }
    for s in streams { m.store(words: s.words, at: Int(s.address - base)) }

    let last = states[states.count - 1]
    let image = RenderPassImage(
      memory: m, base: base, streams: streams, plan: plan, hierarchyMask: mask, tilerContext: va(tilerAt),
      heapDescriptor: va(heapAt), framebuffer: va(fbdAt), renderTarget: va(rtAt),
      sampleTable: va(samplesAt), blend: va(blendAt[0]), depthStencil: va(zsdAt), vertexTable: 0,
      vertexShader: va(shaders[vslot[vslot.count - 1]].at), fragmentShader: va(shaders[fslot[fslot.count - 1]].at),
      vertexSPD: last.vertexSPD, fragmentSPD: last.fragmentSPD, localStorage: va(tsdAt), syncObject: syncVA, draw: last,
      fragmentPointer: fbdPointer)
    return (image, records, resourcePointer)
  }
}
