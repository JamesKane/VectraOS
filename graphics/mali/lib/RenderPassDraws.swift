// SPDX-License-Identifier: BSD-3-Clause

// A render pass of compiled draws (D174 step 3): the pass of RenderPass.swift with a list of draws in place of its one
// triangle. Each draw has its own shaders, push constants, blend descriptor and heap handles; they run one after the
// other in the one tiler pass, so a later draw blends over an earlier one in the tile buffer (a pass that loads its
// target from memory needs frame shaders, 08, which this recipe does not make). Textures are the descriptor heap
// (Images.swift): the caller lays the heap, its texels and its plane descriptors in memory of its own and tells the
// recipe where the heap is; the recipe makes the resource table (one 64-byte block, the heap as table 1) and gives
// the fragment stage its address as `FRAGMENT_SRT`. The streams are RenderPass.build's (02 section 2.6).

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

/// What to draw and where, as RenderPassRequest has it, with draws.
public struct DrawPassRequest: Sendable {
  public var width: Int
  public var height: Int
  public var format: ColourFormat
  public var colourAddress: UInt64
  public var clear: [Float]
  public var draws: [PassDraw]
  /// The descriptor heap in GPU memory (64-byte aligned) and its size in bytes; nil when no draw samples.
  public var heapAddress: UInt64?
  public var heapBytes: Int
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

  /// The most stack any shader of the pass needs.
  public var stackBytes: UInt32 {
    var most: UInt32 = 0
    for d in draws { most = max(most, d.vertexShader.stackBytes, d.fragmentShader.stackBytes) }
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
      guard d.vertexCount >= 3, d.instanceCount >= 1, d.blend.renderTarget == 0 else { throw .badRequest }
    }
    guard let plan = TilePlan.make(r.tileBuffer, bytesPerSample: [ColourFormat.bytesPerPixel], samples: 1) else {
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
    let fbdAt = place(groupBytes, 64)
    let samplesAt = place(SamplePatterns.tableBytes, 64)
    let tableAt = r.heapAddress == nil ? -1 : place(DescriptorHeap.tableEntries * ResourceTable.entrySize, ResourceTable.alignment)
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
      blendAt.append(place(BlendDescriptor.size, 64))
      vfauAt.append(place(8 * max(d.vertexShader.layout.slots, 1), 8))
      ffauAt.append(place(8 * d.fragmentShader.layout.slots, 8))
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
    let framebuffer = FramebufferParameters(
      width: r.width, height: r.height, samplePattern: SamplePatterns.single,
      sampleLocations: va(samplesAt) + UInt64(SamplePatterns.blockBytes) * UInt64(SamplePatterns.single),
      effectiveTileLog2: plan.tileLog2, colourAllocationKiB: plan.allocationField, tiler: va(tilerAt))

    var states: [IDVSState] = []
    var records: [DrawRecords] = []
    var fbdPointer: UInt64 = 0
    var resourcePointer: UInt64 = 0
    do throws(DescriptorError) {
      fbdPointer = FramebufferParameters.taggedPointer(address: va(fbdAt), extensionPresent: false, renderTargetCount: 1)
      if tableAt >= 0 { resourcePointer = try ResourceTable.pointer(address: va(tableAt), entryCount: DescriptorHeap.tableEntries) }
      for (n, d) in r.draws.enumerated() {
        var s = IDVSState()
        s.vertexFAU = try FAUPointer.value(address: va(vfauAt[n]), words: max(d.vertexShader.layout.slots, 1))
        if d.fragmentShader.layout.slots > 0 {
          s.fragmentFAU = try FAUPointer.value(address: va(ffauAt[n]), words: d.fragmentShader.layout.slots)
        }
        s.blend = try BlendDescriptor.register(address: va(blendAt[n]), count: 1)
        s.tilerContext = va(tilerAt)
        s.fragmentSRT = resourcePointer
        s.vertexSPD = va(shaders[vslot[n]].spd)
        s.fragmentSPD = va(shaders[fslot[n]].spd)
        s.vertexTSD = va(tsdAt)
        s.fragmentTSD = va(tsdAt)
        s.indexCount = UInt32(d.vertexCount)
        s.instanceCount = UInt32(d.instanceCount)
        s.varySize = d.varyingBytes ?? d.vertexShader.varyingBytes
        s.scissor = ScissorBox(width: r.width, height: r.height)
        s.viewport = Viewport(rectangle: s.scissor, minDepth: 0, maxDepth: 1)
        s.depthStencil = va(zsdAt)
        s.tilerFlags = PrimitiveFlags(secondaryShader: s.varySize > 0).word
        // 6.10.3: a fragment of this draw may kill an earlier one only if the draw neither reads the destination nor can
        // discard.
        var flags = DrawFlags0.colourOnly
        flags.allowForwardPixelToKill = !d.blend.blend.loadDestination && !d.fragmentShader.discards
        // 6.9.1 `[20]`: the shader writes the sample mask or may discard.
        flags.shaderModifiesCoverage = d.fragmentShader.discards
        s.flags0 = flags.word
        s.flags1 = DrawFlags1.word(renderTargetMask: 1)
        s.flags2 = DrawFlags2.word(writeMask: 1)
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

    var streams: [CSStream] = []
    var b0 = CSBuilder(address: va(stream0At), capacityBytes: max(capacity - stream0At, 0), registers: registers,
                       scoreboards: scoreboards)
    if r.layout == .singleQueue {
      prologue(&b0, resources: resourcesTiling | .fragment)
      tiling(&b0)
      b0.wait(mask: tilingMask | b0.scoreboards.slotMask(CSScoreboards.deferredSyncSlot))
      fragment(&b0)
      tail(&b0)
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
    var m = MemoryImage()
    m.extend(to: total)
    do throws(DescriptorError) {
      m.store(words: tsd.words, at: tsdAt)
      m.store(words: DepthStencilDescriptor.disabled, at: zsdAt)
      m.store(words: try tiler.words(), at: tilerAt)
      m.store(words: try heap.words(), at: heapAt)
      m.store(words: try framebuffer.words(), at: fbdAt)
      m.store(words: try renderTarget.words(), at: fbdAt + FramebufferParameters.size)
      if let heapAddress = r.heapAddress {
        m.store(bytes: try DescriptorHeap.resourceTable(heapAddress: heapAddress, heapBytes: r.heapBytes), at: tableAt)
      }
    } catch { throw .descriptor(error) }
    m.store(bytes: SamplePatterns.table(), at: samplesAt)
    for s in shaders { m.store(words: s.code, at: s.at) }
    for (n, d) in r.draws.enumerated() {
      let vs = d.vertexShader
      let fs = d.fragmentShader
      let viewport = ViewportTransform(width: Float(r.width), height: Float(r.height))
      let vblock = vs.layout.block(viewport: viewport, push: d.push)
      for (i, w) in vblock.enumerated() { m.store(w, at: vfauAt[n] + 8 * i) }
      let handles = d.images.map { (set: $0.set, binding: $0.binding, handle: $0.handle) }
      let fblock = fs.layout.block(push: d.push, images: handles, dummySampler: d.dummySampler)
      for (i, w) in fblock.enumerated() { m.store(w, at: ffauAt[n] + 8 * i) }
      m.store(words: d.blend.words, at: blendAt[n])
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
      heapDescriptor: va(heapAt), framebuffer: va(fbdAt), renderTarget: va(fbdAt + FramebufferParameters.size),
      sampleTable: va(samplesAt), blend: va(blendAt[0]), depthStencil: va(zsdAt), vertexTable: 0,
      vertexShader: va(shaders[vslot[vslot.count - 1]].at), fragmentShader: va(shaders[fslot[fslot.count - 1]].at),
      vertexSPD: last.vertexSPD, fragmentSPD: last.fragmentSPD, localStorage: va(tsdAt), syncObject: syncVA, draw: last,
      fragmentPointer: fbdPointer)
    return (image, records, resourcePointer)
  }
}
