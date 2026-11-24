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
  /// The code of the blend shader of each colour target whose descriptor is in mode Shader (by target; 09 section 9.9). The recipe
  /// places each in the pass's block, so it lies in the fragment shader's 4 GiB region, and puts its address in the descriptor.
  public var blendShaders: [Int: [UInt64]] = [:]
  /// The blend constants (red, green, blue, alpha) the blend shaders read from the fragment FAU (`GraphicsFauLayout.blendConstantWord`).
  public var blendConstants: [Float] = []

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
  /// Its row stride in bytes, where it isn't `LinearLayout`'s.
  public var rowStride: Int?
  /// A multisampled target's writeback (08 section 8.3.2: 3, every sample to its surface, `surfaceStride` apart; 1, the average).
  public var msaa: UInt32 = 0
  public var surfaceStride: Int?
  /// Bytes from one layer to the next, for a pass of layers.
  public var layerStride = 0
  /// Its block format (08 section 8.4.3): 2 linear, 8 the 64 KiB interleaved layout.
  public var blockFormat: UInt32 = 2
  public init(format: ColourFormat, address: UInt64, clear: [Float], rowStride: Int? = nil) {
    self.format = format
    self.address = address
    self.clear = clear
    self.rowStride = rowStride
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
  /// The depth and stencil target's contents are loaded into the tile first by the second pre-frame shader (08 sections 8.2.1.1
  /// and 8.10), whose shader writes the depth (FragDepth) or the stencil (the stencil reference); nil: the clear values fill it.
  public var zsPreload: FramePreload?
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
  /// The colour target's row stride in bytes, where it isn't `LinearLayout`'s (a window's image, whose rows are packed).
  public var rowStride: Int?
  /// Samples of every attachment's pixel (08 section 8.3): 1, 2, 4, 8 or 16.
  public var samples: Int = 1
  /// Layers the pass draws (08 section 8.12): a descriptor group and a fragment run each, a tiler context for each eight (07 section
  /// 7.8), and the first colour target's bytes from one layer to the next.
  public var layers: Int = 1
  public var colourLayerStride = 0
  /// A multiview pass (07 section 7.8.2): bit i draws view i into layer i, in one tiler context, each draw's primitive flags naming
  /// the views; a group and a fragment run for each view in the mask only. 0 for a pass that isn't multiview (`layers` then counts).
  public var viewMask: UInt32 = 0
  /// A probe of the hardware: hand back only the last context's chunk list (the leak of 07 section 7.10), to see what shows it.
  public var finishLastContextOnly = false
  /// The first colour target's writeback (08 section 8.3.2) and the distance between its sample surfaces.
  public var colourMSAA: UInt32 = 0
  /// The first colour target's block format (08 section 8.4.3): 2 linear, 8 the 64 KiB interleaved layout.
  public var colourBlockFormat: UInt32 = 2
  public var colourSurfaceStride: Int?
  /// Single-sample images the pass resolves colour targets into as it ends: a render-target descriptor each after the targets,
  /// in writeback mode Average (8.3.2), at the internal buffer offset of the target `of` (the tile's samples are written twice:
  /// to the target, and averaged to the resolve). The blend descriptors stay the shader's targets'.
  public var resolves: [(of: Int, target: ExtraColourTarget)] = []

  /// The most stack any shader of the pass needs.
  public var stackBytes: UInt32 {
    var most: UInt32 = 0
    for d in draws { most = max(most, d.vertexShader.stackBytes, d.fragmentShader.stackBytes) }
    if let p = preload { most = max(most, p.shader.stackBytes) }
    if let p = zsPreload { most = max(most, p.shader.stackBytes) }
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
      r.height <= 4096, r.layers >= 1, r.layers <= 256
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
    guard r.zsPreload == nil || r.zs != nil else { throw .badRequest }
    for d in r.draws { guard d.extraBlends.count == targetCount - 1 else { throw .badRequest } }
    // A target in mode Shader has its shader (and a draw with a shader has the constants' words in its FAU).
    for d in r.draws {
      for (i, b) in ([d.blend] + d.extraBlends).enumerated() where b.mode == .shader {
        guard let code = d.blendShaders[i], !code.isEmpty, d.fragmentShader.layout.blendConstantWord >= 0 else { throw .badRequest }
      }
    }
    for t in r.extraTargets { guard t.clear.count == 4, t.address & 63 == 0 else { throw .badRequest } }
    guard let pattern = SamplePatterns.pattern(samples: r.samples) else { throw .badRequest }
    for v in r.resolves { guard v.of >= 0 && v.of < targetCount && v.target.address & 63 == 0 else { throw .badRequest } }
    let descriptorCount = targetCount + r.resolves.count
    guard descriptorCount <= 8 else { throw .badRequest }
    guard let plan = TilePlan.make(r.tileBuffer, bytesPerSample: [Int](repeating: ColourFormat.bytesPerPixel, count: targetCount), samples: r.samples) else {
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
    // A tiler context for each eight layers, in one array (07 section 7.8), and a descriptor group for each layer (08 section 8.12).
    // The layers that have a group: every layer, or the views of the mask (at most eight on arch 10 to 13, one context).
    var layerList: [Int] = []
    if r.viewMask != 0 {
      guard r.viewMask < 1 << 8 else { throw .badRequest }
      for v in 0..<8 where r.viewMask >> UInt32(v) & 1 == 1 { layerList.append(v) }
    } else {
      layerList = Array(0..<r.layers)
    }
    let contexts = r.viewMask != 0 ? 1 : (r.layers + 7) / 8
    let tilerAt = place(TilerContext.size * contexts, TilerContext.alignment)
    let heapAt = place(TilerHeapDescriptor.size, TilerHeapDescriptor.alignment)
    let zsExtension = r.zs != nil
    let groupSize = alignUp(groupBytes + (zsExtension ? ZSTarget.size : 0) + 64 * (descriptorCount - 1), 64)
    let fbdAt = place(groupSize * layerList.count, 64)
    // A draw whose state has a depth/stencil test has a descriptor of its own.
    var drawZSDAt: [Int] = []
    func zsState(_ d: PassDraw) -> ZSDescriptorState? {
      // A shader that writes the depth takes the depth source from the shader (6.8.3), whatever the state.
      var z = d.state.depthStencil
      if r.zs != nil && d.fragmentShader.writesDepth {
        z = z ?? ZSDescriptorState()
        z!.depthFromShader = true
      }
      // A shader that writes the stencil reference gives it to the stencil test, where the test is on (6.8, word 0 `[30]`).
      if d.fragmentShader.writesStencil && z?.stencilTest == true { z!.stencilFromShader = true }
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
    // The blend shaders (09 section 9.9): each distinct program once, 16-byte aligned, in this block.
    var blendCodes: [(code: [UInt64], at: Int)] = []
    var blendCodeAt: [[Int: Int]] = []
    for d in r.draws {
      var at: [Int: Int] = [:]
      for (target, code) in d.blendShaders.sorted(by: { $0.key < $1.key }) {
        if let k = blendCodes.firstIndex(where: { $0.code == code }) {
          at[target] = blendCodes[k].at
        } else {
          let p = place(code.count * 8, 64)
          blendCodes.append((code, p))
          at[target] = p
        }
      }
      blendCodeAt.append(at)
    }
    var blendAt: [Int] = []
    var vfauAt: [Int] = []
    var ffauAt: [Int] = []
    // A draw whose vertex shader writes ViewportIndex: its viewports' transforms (ViewportTable) and its scissor array (06 section 6.2),
    // 256 boxes, so whatever byte the shader writes names one in memory.
    var viewportsAt: [Int] = []
    var scissorsAt: [Int] = []
    for d in r.draws {
      blendAt.append(place(BlendDescriptor.size * targetCount, 64))
      vfauAt.append(place(8 * max(d.vertexShader.layout.slots, 1), 8))
      ffauAt.append(place(8 * d.fragmentShader.layout.slots, 8))
      viewportsAt.append(d.vertexShader.layout.viewportTableWord >= 0 ? place(ViewportTable.bytes, 16) : -1)
      scissorsAt.append(d.vertexShader.storesViewportIndex && d.state.scissorProbe >= 2 && d.state.scissorProbe <= 5
        ? place(ScissorArray.entries * (d.state.scissorProbe == 3 ? 16 : 8), d.state.scissorProbe == 4 ? 4096 : 64) : -1)
    }
    // The first pre-frame shader (08 section 8.10): the three frame shaders' draw descriptors (the other two never run),
    // its blend descriptor, push words, resource table (its own heap), program descriptor and code.
    var dcdAt = 0, preBlendAt = 0, preFAUAt = 0, preTableAt = 0, preSPDAt = 0, preCodeAt = 0
    if r.preload != nil || r.zsPreload != nil { dcdAt = place(3 * 128, 64) }
    if let p = r.preload {
      preBlendAt = place(BlendDescriptor.size, 64)
      preFAUAt = place(8 * max(p.shader.layout.slots, 1), 8)
      preTableAt = place(DescriptorHeap.tableEntries * ResourceTable.entrySize, ResourceTable.alignment)
      preSPDAt = place(ShaderProgramDescriptor.size, ShaderProgramDescriptor.alignment)
      preCodeAt = place(p.shader.code.count * 8, 128)
    }
    // The second pre-frame shader (08 section 8.10.3): its depth/stencil descriptor, push words, resource table, program and code.
    var zsPreZSDAt = 0, zsPreFAUAt = 0, zsPreTableAt = 0, zsPreSPDAt = 0, zsPreCodeAt = 0
    if let p = r.zsPreload {
      zsPreZSDAt = place(DepthStencilDescriptor.size, DepthStencilDescriptor.alignment)
      zsPreFAUAt = place(8 * max(p.shader.layout.slots, 1), 8)
      zsPreTableAt = place(DescriptorHeap.tableEntries * ResourceTable.entrySize, ResourceTable.alignment)
      zsPreSPDAt = place(ShaderProgramDescriptor.size, ShaderProgramDescriptor.alignment)
      zsPreCodeAt = place(p.shader.code.count * 8, 128)
    }
    let syncAt = r.layout == .splitQueues ? place(16, 64) : 0
    let stream0At = place(0, 64)

    func va(_ at: Int) -> UInt64 { base + UInt64(at) }

    let tiler = TilerContext(
      hierarchyMask: mask, samplePattern: pattern, firstProvokingVertex: true,
      effectiveTileLog2: plan.tileLog2, width: r.width, height: r.height, heap: va(heapAt),
      geometryBuffer: r.geometryBuffer)
    let heap = TilerHeapDescriptor(chunkBytes: r.heapChunkBytes, firstChunk: r.heapChunk)
    let layout = LinearLayout(width: r.width, height: r.height, bytesPerPixel: ColourFormat.bytesPerPixel)
    // A target's strides: LinearLayout's, or its own row stride (a multiple of the pixel's bytes, 05 section 5.5.4).
    let height = r.height
    var renderTarget = RenderTargetDescriptor(
      format: r.format, internalBufferOffset: plan.offsets[0], address: r.colourAddress, rowStride: r.rowStride ?? layout.rowStride,
      surfaceStride: r.colourSurfaceStride ?? r.rowStride.map { alignUp($0 * height, 64) } ?? layout.surfaceStride,
      clearWord: ColourFormat.packedClear(
        red: r.clear[0], green: r.clear[1], blue: r.clear[2], alpha: r.clear[3], srgb: r.format.isSRGB))
    renderTarget.msaa = r.colourMSAA
    renderTarget.blockFormat = r.colourBlockFormat
    let rtAt = fbdAt + FramebufferParameters.size + (zsExtension ? ZSTarget.size : 0)
    var framebuffer = FramebufferParameters(
      width: r.width, height: r.height, sampleCountLog2: UInt32(log2Floor(UInt64(r.samples))), samplePattern: pattern,
      sampleLocations: va(samplesAt) + UInt64(SamplePatterns.blockBytes) * UInt64(pattern),
      effectiveTileLog2: plan.tileLog2, colourAllocationKiB: plan.allocationField, tiler: va(tilerAt))
    framebuffer.zs = r.zs
    framebuffer.renderTargetCount = descriptorCount
    if r.preload != nil {
      framebuffer.preFrame0Mode = 1
      framebuffer.frameShaderDCDs = va(dcdAt)
    }
    if r.zsPreload != nil {
      // 8.10.1: depth and stencil loads use Early ZS Always on arch 10 to 12.
      framebuffer.preFrame1Mode = 3
      framebuffer.frameShaderDCDs = va(dcdAt)
    }
    /// The second frame shader's draw descriptor, its depth/stencil state and its blocks (8.10.3, 8.10.3.2).
    var zsPreDCD = [UInt32](repeating: 0, count: 32)
    var zsPreFAUWords: [UInt64] = []
    var zsPreTableBytes: [UInt8] = []
    var zsPreSPDWords: [UInt32] = []
    var zsPreState = ZSDescriptorState()
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
      fbdPointer = FramebufferParameters.taggedPointer(address: va(fbdAt), extensionPresent: zsExtension, renderTargetCount: descriptorCount)
      if tableAt >= 0 { resourcePointer = try ResourceTable.pointer(address: va(tableAt), entryCount: DescriptorHeap.tableEntries) }
      if let p = r.preload {
        // Colour only, forced early, forward pixel kill allowed both ways, and the shader's output counts as writing the
        // tile (clean fragment write, flags 0 `[9]`): the table of 8.10.3.
        var f0 = DrawFlags0.colourOnly
        f0.pixelKill = .forceEarly
        f0.zsUpdate = .forceEarly
        f0.multisample = r.samples > 1
        // 8.10.3: evaluate per sample when the shader uses the sample index.
        preDCD[0] = f0.word | 1 << 9 | (r.samples > 1 && p.shader.perSampleShading ? 1 << 11 : 0)
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
      if let p = r.zsPreload {
        // 8.10.3: kill and update Force Late (the shader writes depth or stencil), no forward pixel kill of others, its own
        // fragments may be killed, a clean fragment write, no colour (no blend descriptors), every sample.
        var f0 = DrawFlags0.colourOnly
        f0.allowForwardPixelToKill = false
        f0.pixelKill = .forceLate
        f0.zsUpdate = .forceLate
        f0.multisample = r.samples > 1
        zsPreDCD[0] = f0.word | 1 << 9 | (r.samples > 1 && p.shader.perSampleShading ? 1 << 11 : 0)
        zsPreDCD[1] = DrawFlags1.word(renderTargetMask: 0)
        zsPreDCD[5] = DrawFlags2.word(writeMask: 0)
        // 8.10.3.2: depth Always, written from the shader when it writes depth; the stencil test Always, Replace, from the shader,
        // when it writes stencil; every mask 0xFF; depth cull off.
        zsPreState.depthFunction = 7
        zsPreState.depthClip = false
        if p.shader.writesDepth {
          zsPreState.depthWrite = true
          zsPreState.depthFromShader = true
        }
        if p.shader.writesStencil {
          var face = StencilFaceWords()
          face.function = 7
          face.failOperation = 1
          face.depthFailOperation = 1
          face.passOperation = 1
          zsPreState.stencilTest = true
          zsPreState.stencilFromShader = true
          zsPreState.front = face
          zsPreState.back = face
        }
        let zsd = va(zsPreZSDAt)
        zsPreDCD[10] = UInt32(truncatingIfNeeded: zsd)
        zsPreDCD[11] = UInt32(truncatingIfNeeded: zsd >> 32)
        let table = try ResourceTable.pointer(address: va(zsPreTableAt), entryCount: DescriptorHeap.tableEntries)
        zsPreDCD[24] = UInt32(truncatingIfNeeded: table)
        zsPreDCD[25] = UInt32(truncatingIfNeeded: table >> 32)
        let spd = va(zsPreSPDAt)
        zsPreDCD[26] = UInt32(truncatingIfNeeded: spd)
        zsPreDCD[27] = UInt32(truncatingIfNeeded: spd >> 32)
        let tsdPointer = va(tsdAt)
        zsPreDCD[28] = UInt32(truncatingIfNeeded: tsdPointer)
        zsPreDCD[29] = UInt32(truncatingIfNeeded: tsdPointer >> 32)
        if p.shader.layout.slots > 0 {
          let fau = try FAUPointer.value(address: va(zsPreFAUAt), words: p.shader.layout.slots)
          zsPreDCD[30] = UInt32(truncatingIfNeeded: fau)
          zsPreDCD[31] = UInt32(truncatingIfNeeded: fau >> 32)
        }
        let handles = p.images.map { (set: $0.set, binding: $0.binding, handle: $0.handle) }
        zsPreFAUWords = p.shader.layout.block(push: p.push, images: handles, dummySampler: p.dummySampler)
        zsPreTableBytes = try DescriptorHeap.resourceTable(heapAddress: p.heapAddress, heapBytes: p.heapBytes)
        zsPreSPDWords = ShaderProgramDescriptor(
          stage: .fragment, registerClass: p.shader.registerClass, preloadMask: p.shader.preloadMask, binary: va(zsPreCodeAt),
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
        if scissorsAt[n] >= 0 {
          // A probe of the scissor array: the register names it; the viewport registers hold every viewport's rectangle and depth range.
          let a = ScissorArray(state: d.state, width: r.width, height: r.height)
          s.scissorArray = va(scissorsAt[n]) | UInt64(a.lengthField & 0xFF) << 56
          s.viewport = a.viewport
        } else if d.vertexShader.storesViewportIndex && d.state.scissorProbe == 6, let at = d.state.scissorArrayAddress {
          // The array somewhere of the caller's (an address whose bits 31:0 are zero: the register is also a box from (0, 0)).
          let a = ScissorArray(state: d.state, width: r.width, height: r.height)
          s.scissorArray = at | UInt64(a.lengthField & 0xFF) << 56
          s.viewport = a.viewport
        } else if d.vertexShader.storesViewportIndex && d.state.scissorProbe == 7 {
          // The first scissor's box itself (the probe makes its maximum y 256 or more: read as an array, a length byte of 1 or more).
        }
        s.depthStencil = va(zsState(d) != nil ? drawZSDAt[n] : zsdAt)
        s.tilerFlags = PrimitiveFlags(
          mode: d.state.mode, indexType: d.indices?.size.rawValue ?? 0, lowDepthCull: d.state.depthStencil?.depthClip ?? true,
          highDepthCull: d.state.depthStencil?.depthClip ?? true, primitiveRestart: d.state.primitiveRestart,
          positionFIFOFormat: d.vertexShader.extendedRecord ? 2 : 1, viewMask: r.viewMask, secondaryShader: s.varySize > 0,
          layerIndex: d.vertexShader.writesLayer, scissorArray: d.vertexShader.storesViewportIndex && d.state.scissorProbe >= 1 && d.state.scissorProbe != 5).word
        s.primitiveSize = d.state.primitiveSize.bitPattern
        // 6.10.3: a fragment of this draw may kill an earlier one only if the draw neither reads the destination nor can
        // discard.
        var flags = DrawFlags0.colourOnly
        var readsDestination = d.blend.blend.loadDestination
        for b in d.extraBlends where b.blend.loadDestination { readsDestination = true }
        flags.allowForwardPixelToKill = !readsDestination && !d.fragmentShader.discards
        // 6.9.1 `[20]`: the shader writes the sample mask or may discard, or alpha to coverage (6.9.4).
        flags.shaderModifiesCoverage = d.fragmentShader.discards || d.fragmentShader.writesSampleMask || d.state.alphaToCoverage
        if d.state.alphaToCoverage { flags.allowForwardPixelToKill = false }
        // 6.9.1 `[19]`: rasterise at the samples of a multisampled pass.
        flags.multisample = r.samples > 1
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
            sw: d.fragmentShader.writesDepth || d.fragmentShader.writesStencil, wzo: (zsd?.writes ?? false) || d.occlusionQuery != 0,
            ac: d.state.alphaToCoverage, lc: d.fragmentShader.discards || d.fragmentShader.writesSampleMask || d.state.alphaToCoverage, se: storage,
            eft: d.fragmentShader.earlyFragmentTests, pass: zsd == nil || (zsd!.depthAlwaysPasses && zsd!.stencilAlwaysPasses))
          flags.pixelKill = ops.kill
          flags.zsUpdate = ops.update
          if d.fragmentShader.writesDepth || d.fragmentShader.writesStencil { flags.allowForwardPixelToKill = false }
        }
        if d.occlusionQuery != 0 {
          // 6.10.2: an active query is a write (WZO), so a shader that can alter coverage updates late. A fragment that
          // a later one kills would not be counted, so the draw is not one that kills (a count is of samples that pass).
          if d.fragmentShader.discards { flags.zsUpdate = .forceLate }
          flags.allowForwardPixelToKill = false
        }
        // 6.9.1 `[11]`: per sample where the state or the shader asks, or a blend shader runs, in a pass of more than one sample;
        // `[22]`: alpha to coverage.
        let perSample = r.samples > 1 && (d.state.perSample || d.fragmentShader.perSampleShading || !d.blendShaders.isEmpty)
        let extra: UInt32 = (perSample ? 1 << 11 : 0) | (d.state.alphaToCoverage ? 1 << 22 : 0)
        s.flags0 = (flags.word | extra | (d.occlusionQuery != 0 ? 3 << 14 : 0) | d.flags0Or) & ~d.flags0Clear
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
      for k in 0..<contexts {
      for (n, var s) in states.enumerated() {
        if k > 0 && !r.draws[n].vertexShader.writesLayer { continue }
        s.tilerContext = va(tilerAt) + UInt64(k * TilerContext.size)
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
      }
      b.emit(CSInstruction.finishTiling)
      b.emit(CSInstruction.heapOperation(.vertexTilerCompleted, waitMask: tilingMask, signalSlot: CSScoreboards.deferredSyncSlot))
    }
    func fragment(_ b: inout CSBuilder) {
      b.emit(CSInstruction.setState(.endpointSlot, immediate: UInt32(fragmentSlot)))
      let box = framebuffer.boundingBoxRegisters
      // A fragment run for each layer, its group's tagged pointer (08 section 8.12).
      for g in 0..<layerList.count {
        b.move64(40, fbdPointer + UInt64(g * groupSize))
        b.move32(42, box.min)
        b.move32(43, box.max)
        b.emit(CSInstruction.runFragment())
      }
      // 01 section 1.9.7, 07 section 7.10: each context's chunk list goes back by a FINISH_FRAGMENT of its own, from context 0 up,
      // with that context's completed top and bottom. One context: its FINISH_FRAGMENT bumps the fragment-completed counter; several:
      // none does, and one HEAP_OPERATION after them does. Every one waits only for the pass's runs and signals the finish slot:
      // none may wait on the slot it signals (01 section 1.11; a chain that did stalled the queue for 5 s on the board).
      let only = r.finishLastContextOnly ? [contexts - 1] : Array(0..<contexts)
      for k in only {
        b.move64(completedAddressRegister, va(tilerAt) + UInt64(k * TilerContext.size + TilerContext.completedOffset))
        b.emit(CSInstruction.loadMultiple(base: completedTopRegister, address: completedAddressRegister, mask: 0xF))
        b.wait(mask: b.scoreboards.slotMask(dataSlot))
        b.emit(CSInstruction.finishFragment(
          firstChunkPair: completedTopRegister, lastChunkPair: completedBottomRegister, incrementFragmentCompleted: only.count == 1,
          waitMask: fragmentMask, signalSlot: finishSlot))
      }
      if only.count > 1 {
        b.emit(CSInstruction.heapOperation(.fragmentCompleted, waitMask: fragmentMask, signalSlot: finishSlot))
      }
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
      for k in 0..<contexts {
        var t = tiler
        t.layerCount = r.viewMask != 0 ? (layerList.last ?? 0) + 1 : min(8, r.layers - 8 * k)
        t.layerOffset = -8 * k
        m.store(words: try t.words(), at: tilerAt + k * TilerContext.size)
      }
      m.store(words: try heap.words(), at: heapAt)
      for (gi, l) in layerList.enumerated() {
      let g = gi * groupSize
      var layerFramebuffer = framebuffer
      layerFramebuffer.internalLayerIndex = UInt32(l % 8)
      layerFramebuffer.frameArgument = UInt64(l)
      layerFramebuffer.tiler = va(tilerAt) + UInt64((l / 8) * TilerContext.size)
      m.store(words: try layerFramebuffer.words(), at: fbdAt + g)
      if let z = r.zs { m.store(words: try z.words(layer: l), at: fbdAt + g + FramebufferParameters.size) }
      var layerTarget = renderTarget
      layerTarget.address += UInt64(l * r.colourLayerStride)
      m.store(words: try layerTarget.words(), at: rtAt + g)
      for (i, t) in r.extraTargets.enumerated() {
        var extra = RenderTargetDescriptor(
          format: t.format, internalBufferOffset: plan.offsets[i + 1], address: t.address, rowStride: t.rowStride ?? layout.rowStride,
          surfaceStride: t.surfaceStride ?? t.rowStride.map { alignUp($0 * height, 64) } ?? layout.surfaceStride,
          clearWord: ColourFormat.packedClear(red: t.clear[0], green: t.clear[1], blue: t.clear[2], alpha: t.clear[3], srgb: t.format.isSRGB))
        extra.msaa = t.msaa
        extra.blockFormat = t.blockFormat
        extra.address += UInt64(l * t.layerStride)
        m.store(words: try extra.words(), at: rtAt + g + 64 * (i + 1))
      }
      // The resolves: the tile of target `of`, averaged into a single-sample image (8.3.2).
      for (k, v) in r.resolves.enumerated() {
        let t = v.target
        let clear = v.of == 0 ? r.clear : r.extraTargets[v.of - 1].clear
        var resolve = RenderTargetDescriptor(
          format: t.format, internalBufferOffset: plan.offsets[v.of], address: t.address, rowStride: t.rowStride ?? layout.rowStride,
          surfaceStride: t.surfaceStride ?? t.rowStride.map { alignUp($0 * height, 64) } ?? layout.surfaceStride,
          clearWord: ColourFormat.packedClear(red: clear[0], green: clear[1], blue: clear[2], alpha: clear[3], srgb: t.format.isSRGB))
        resolve.msaa = 1
        resolve.blockFormat = t.blockFormat
        resolve.address += UInt64(l * t.layerStride)
        m.store(words: try resolve.words(), at: rtAt + g + 64 * (targetCount + k))
      }
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
    if let p = r.zsPreload {
      m.store(words: zsPreDCD, at: dcdAt + 128)
      m.store(words: zsPreState.words, at: zsPreZSDAt)
      for (i, w) in zsPreFAUWords.enumerated() { m.store(w, at: zsPreFAUAt + 8 * i) }
      m.store(bytes: zsPreTableBytes, at: zsPreTableAt)
      m.store(words: zsPreSPDWords, at: zsPreSPDAt)
      m.store(words: p.shader.code, at: zsPreCodeAt)
    }
    for s in shaders { m.store(words: s.code, at: s.at) }
    for b in blendCodes { m.store(words: b.code, at: b.at) }
    for (n, d) in r.draws.enumerated() {
      let vs = d.vertexShader
      let fs = d.fragmentShader
      let vp = d.state.viewport ?? DrawViewport(x: 0, y: 0, width: Float(r.width), height: Float(r.height))
      let viewport = ViewportTransform(x: vp.x, y: vp.y, width: vp.width, height: vp.height, minDepth: vp.minDepth, maxDepth: vp.maxDepth)
      let vblock = vs.layout.block(viewport: viewport, push: d.push, viewportTable: viewportsAt[n] >= 0 ? va(viewportsAt[n]) : 0)
      for (i, w) in vblock.enumerated() { m.store(w, at: vfauAt[n] + 8 * i) }
      if viewportsAt[n] >= 0 {
        var transforms: [ViewportTransform] = []
        for k in 0..<max(d.state.viewports.count, 1) {
          let v = (k < d.state.viewports.count ? d.state.viewports[k] : nil) ?? DrawViewport(x: 0, y: 0, width: Float(r.width), height: Float(r.height))
          transforms.append(ViewportTransform(x: v.x, y: v.y, width: v.width, height: v.height, minDepth: v.minDepth, maxDepth: v.maxDepth))
        }
        m.store(words: ViewportTable.words(transforms), at: viewportsAt[n])
      }
      if scissorsAt[n] >= 0 { m.store(words: ScissorArray(state: d.state, width: r.width, height: r.height).words(stride: d.state.scissorProbe == 3 ? 16 : 8), at: scissorsAt[n]) }
      let handles = d.images.map { (set: $0.set, binding: $0.binding, handle: $0.handle) }
      let fblock = fs.layout.block(push: d.push, images: handles, dummySampler: d.dummySampler, blendConstants: d.blendConstants)
      for (i, w) in fblock.enumerated() { m.store(w, at: ffauAt[n] + 8 * i) }
      func withShader(_ b: BlendDescriptor, _ target: Int) -> [UInt32] {
        var b = b
        if b.mode == .shader, let p = blendCodeAt[n][target] { b.shaderAddress = UInt32(truncatingIfNeeded: va(p)) }
        return b.words
      }
      m.store(words: withShader(d.blend, 0), at: blendAt[n])
      // A target the shader doesn't write has a descriptor that is off (09 section 9.3).
      for (i, b) in d.extraBlends.enumerated() {
        var written = false
        for l in d.fragmentShader.colourTargets where l == i + 1 { written = true }
        m.store(words: written ? withShader(b, i + 1) : [0, 0, 3, 0], at: blendAt[n] + BlendDescriptor.size * (i + 1))
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
