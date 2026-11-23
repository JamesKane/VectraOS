// SPDX-License-Identifier: BSD-3-Clause

// The core over a Mali GPU's command streams (D174 sections 2 and 5;
// gpucore(2)): memory, images and pipelines on MaliCore (the command-stream
// builder, descriptors and recipes of graphics/mali), the compiler's Valhall
// backend (graphics/compiler) for SPIR-V, and the `csf` capset's client
// through `MaliTransport`. Execute.swift runs a list.
//
// What it does now, and what it refuses (each refusal says so in words):
//  - memory by intent, bound at 64-bit addresses of one VM;
//  - linear images of rgba8, bgra8 and r8 to render into and copy from;
//  - compute pipelines (one SPIR-V module, no descriptor buffers: the core's
//    layout is the heap and a root pointer) and graphics pipelines (a vertex
//    and a fragment module); dispatches and render passes of one draw;
//  - the heap: sampled images (linear, which the texture unit reads as they
//    are) and samplers, for the fragment stage of a draw; a draw is given a
//    copy of the heap as it stands when its pass is built;
//  - pipeline state (PipelineMapping.swift): depth and stencil targets, culling,
//    the topologies, line width, blend factors, masks and constants (fixed
//    function only), dynamic state, viewports and scissors, and up to eight
//    colour targets; gpucore(2) says what is refused (polygon
//    modes) and what is not yet (textures in compute
//    shaders and the vertex stage, queries, loading depth).
//
// This v0 runs one submission at a time: a submission starts when the one
// before it has finished, so the lists need no ordering between the render
// and compute groups. Copies, blits, fills and clears with no draw are compute
// kernels of the GPU's (Transfers.swift), in order with its passes.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ValhallBackend)
  import ValhallBackend
#endif

/// A table of records, whose index (plus one) is the handle a client holds.
struct Slots<T> {
  var items: [T?] = []
  var free: [Int] = []

  mutating func insert(_ t: T) -> UInt64 {
    if let i = free.popLast() {
      items[i] = t
      return UInt64(i + 1)
    }
    items.append(t)
    return UInt64(items.count)
  }

  subscript(handle: UInt64) -> T? {
    guard handle >= 1, Int(handle) <= items.count else { return nil }
    return items[Int(handle) - 1]
  }

  mutating func remove(_ handle: UInt64) -> T? {
    guard handle >= 1, Int(handle) <= items.count, let t = items[Int(handle) - 1] else { return nil }
    items[Int(handle) - 1] = nil
    free.append(Int(handle) - 1)
    return t
  }

  var all: [T] { items.compactMap { $0 } }
}

/// A buffer bound in the VM.
final class Region {
  let buffer: any MaliBuffer
  let address: UInt64
  let size: Int
  /// Whether the CPU maps it cached (results it reads: readback memory, and the images the GPU draws into that the
  /// CPU only reads), and whether the CPU's cache may then hold lines the GPU has since changed or the CPU has dirtied.
  let cached: Bool
  var touched = false
  init(buffer: any MaliBuffer, address: UInt64, size: Int) {
    self.buffer = buffer
    self.address = address
    self.size = size
    cached = buffer.cpuCached
  }
}

/// A linear image: its memory, and where its rows are. A sampled image's region ends with its plane descriptor
/// (`planeAt`, what a texture descriptor's surface array points at), written when the image is made.
final class ImageRecord {
  let region: Region
  let descriptor: ImageDescriptor
  let rowStride: Int
  let layout: ImageLayout
  let planeAt: Int?
  /// The image's planes: one for a colour format, and one for each aspect of a depth or stencil format (`layout` is the first).
  var planes: [AspectPlane] = []
  init(region: Region, descriptor: ImageDescriptor, rowStride: Int, layout: ImageLayout, planeAt: Int?) {
    self.region = region
    self.descriptor = descriptor
    self.rowStride = rowStride
    self.layout = layout
    self.planeAt = planeAt
  }
}

extension PixelFormat {
  /// The texture unit's format for the image's first plane, nil for one it isn't given here.
  var texelFormat: TexelFormat? { texelFormat(aspect: firstAspect) }

  /// The render target's format, for the formats it can be.
  var colourFormat: ColourFormat {
    switch self {
    case .rgba8: .rgba8
    case .bgra8: .bgra8
    case .bgra8srgb: .bgra8srgb
    case .r8: .rgba8  // never a target (makeImage refuses it)
    default: .rgba8  // never a target (makeImage refuses it)
    }
  }
}

/// The device's one heap as a resource table has it: the samplers first, then the textures. A shader names an
/// entry by its place in the table, so a binding's handle is its array's first entry.
enum Heap {
  static let samplerSlots = 16
  static let textureSlots = 4096
  /// The storage images' own array, table 2 (their handles are `handle(table: 2, index: slot)`).
  static let storageSlots = 1024
  static let storageBase = 0
  /// The texel buffers' arrays follow the storage images in table 2 (MaliTexelBuffers.swift): bindings 3 and 4 of the heap.
  static let texelBufferSlots = 1024
  static let storageTexelBufferSlots = 1024
  static let texelBufferBase = storageSlots
  static let storageTexelBufferBase = storageSlots + texelBufferSlots
  static let samplerBase = 0
  static let textureBase = samplerSlots
  static let entryWords = 8
}

/// A set of queries: a 64-bit word each.
final class QueryRecord {
  let region: Region
  let kind: QueryKind
  let count: Int
  init(region: Region, kind: QueryKind, count: Int) {
    self.region = region
    self.kind = kind
    self.count = count
  }
}

enum PipelineRecord {
  case compute(ComputeShader, FauLayout)
  case graphics(vertex: VertexShader, fragment: FragmentShader, format: PixelFormat, blend: BlendDescriptor, state: GraphicsState)
}

public final class MaliDevice: GPUDevice, GPUQueue {
  public let name: String
  public let backend = "mali"
  var baseLimits = DeviceLimits()
  var calibrated = false
  /// What the device can do. Timestamps need the counter's period: the GPU's counter runs at the CPU's architected counter's
  /// frequency (CNTFRQ_EL0, valhall 16 section 16.8.5), and where that reads 0 the period is measured
  /// (`calibrateTimestamps`), so the first read of the limits then runs two small streams on the GPU; a GPU whose counter
  /// can't be read has no timestamp queries.
  public var limits: DeviceLimits {
    calibrate()
    return baseLimits
  }

  func calibrate() {
    guard !calibrated else { return }
    calibrated = true
    let hertz = transport.counterFrequency()
    if hertz > 0 {
      baseLimits.features.timestampQueries = true
      baseLimits.timestampPeriodPicoseconds = 1_000_000_000_000 / hertz
    } else if let period = calibrateTimestamps() {
      baseLimits.features.timestampQueries = true
      baseLimits.timestampPeriodPicoseconds = period
    }
  }
  let transport: any MaliTransport
  let vm: UInt32
  let userRange: UInt64
  var nextAddress: UInt64 = 0x10_0000
  var memories = Slots<Region>()
  var images = Slots<ImageRecord>()
  var pipelines = Slots<PipelineRecord>()
  /// The blend shaders made so far, by what they compute (09 section 9.10): one program for every draw and pipeline that needs it.
  var blendShaders: [(spec: BlendShaderSpec, shader: BlendShader)] = []
  var rule = TimelineRule()
  /// The heap's descriptors as the client has written them: the samplers' words, and the textures' up to the highest
  /// one written. A draw gets a copy.
  var samplerWords = [UInt32](repeating: 0, count: Heap.samplerSlots * Heap.entryWords)
  var textureWords: [UInt32] = []
  /// The storage images' descriptors (table 2), up to the highest slot written.
  var storageWords: [UInt32] = []
  /// The plane arrays of the slots whose views are not the whole image of a colour format.
  var textureArrays: [Region?] = []
  var storageArrays: [Region?] = []
  /// The timeline, and the sync the passes of one submission signal between themselves.
  let timeline: UInt32
  let stepSync: UInt32
  var stepValue: UInt64 = 0
  var renderGroup: UInt32?
  /// The colour targets of the pass `plan` is on (the draws are checked against them).
  var planTargets: [ImageRecord] = []
  /// The size of the pass `plan` is on: its attachments' views' level.
  var planSize = (width: 0, height: 0)
  /// The tiler's memory, made with the first pass and kept: the heap context (zero, 4 KiB), the first chunk and the
  /// geometry buffer (the context and chunk are the firmware's to keep between passes).
  var tilerHeap: (context: Region, chunk: Region, geometry: Region)?
  static let tilerChunkBytes: UInt64 = 8 << 20
  var computeGroup: UInt32?
  /// Whether a group's queues have had their slot state set (the first stream of each does).
  var renderStarted = false
  /// The compute queue's slot state is set (any first stream does it), and its compute resource requested (a dispatch's).
  var computeSlotsReady = false
  var computeResourceRequested = false
  var queries = Slots<QueryRecord>()
  /// The shaders of `clearAttachments` (ClearAttachments.swift), made at first use.
  /// The frame shaders that load a target (Execute.swift's `frameShader`): colour, depth and stencil, single and multisampled.
  var frameShaders: [Int: FragmentShader] = [:]
  var clearPrograms: (vertex: VertexShader, layered: VertexShader, fragments: [FragmentShader])?
  /// The clear's vertex shader for each view mask a multiview pass has cleared in, made at first use.
  var clearMultiview: [(mask: UInt32, vertex: VertexShader)] = []
  /// The transfers' compute kernels (Transfers.swift), compiled at first use, by `TransferKernel`'s raw value.
  var transferPrograms: [Int: (shader: ComputeShader, layout: FauLayout)] = [:]
  /// Host tests only: called for each transfer kernel as it is launched (its root pointer, grid and own heap), so a test can run it
  /// on the interpreter over the fake transport's memory.
  var transferKernelRan: ((TransferKernel, UInt64, Dim3, (address: UInt64, bytes: Int)?) -> Void)?
  /// Bits of every draw's flags 0 to set and to clear, for probes of the hardware (gpu-test's, loinnir-test's).
  public var probeFlags0: (or: UInt32, clear: UInt32) = (0, 0)
  /// A probe of the hardware: after a pass with occlusion queries the fragment queue loads the first report through the GPU
  /// and stores what it read in memory the CPU then reads (`probeReadbackWords`), to tell a lost update from a missing flush.
  public var probeQueryReadback = false
  /// A probe of the hardware: the fragment queue does not zero the reports (the CPU did, at the query set's making).
  public var probeSkipQueryZero = false
  /// A probe of the hardware: passes hand back only their last tiler context's chunks (07 section 7.10's leak).
  public var probeFinishLastContextOnly = false
  /// The tiler heap's memory as the GPU left it, for a check that a pass hands back what it used: the heap context's eight words
  /// and the first chunk's 64-byte header (nil before the first pass).
  public var probeHeapWords: [UInt32]? {
    guard let t = tilerHeap else { return nil }
    var out: [UInt32] = []
    for i in 0..<8 { out.append(unsafe t.context.buffer.pointer.load(fromByteOffset: 4 * i, as: UInt32.self)) }
    for i in 0..<16 { out.append(unsafe t.chunk.buffer.pointer.load(fromByteOffset: 4 * i, as: UInt32.self)) }
    return out
  }
  /// Whether the memory of occlusion query sets made from now on is mapped cacheable for the GPU.
  public var probeQueryCacheable = true
  var queryReadbackRegion: Region?
  /// What the GPU read from the first report of the last pass with queries, once the pass has finished.
  public var probeReadbackReport: UInt64? {
    guard let r = queryReadbackRegion else { return nil }
    let low = unsafe r.buffer.pointer.load(fromByteOffset: 0, as: UInt32.self)
    let high = unsafe r.buffer.pointer.load(fromByteOffset: 4, as: UInt32.self)
    return UInt64(low) | UInt64(high) << 32
  }
  /// What a submission made and freed, released once the timeline reaches its value.
  var retired: [(value: UInt64, regions: [Region])] = []
  let computeLimits: ComputeLimits?

  public init(transport: any MaliTransport) throws(GPUError) {
    self.transport = transport
    let info = transport.info
    name = info.name
    let made = try transport.createVM()
    vm = made.id
    userRange = made.userRange
    timeline = try transport.createSync()
    stepSync = try transport.createSync()
    if let t = info.maxThreads, let w = info.maxWorkgroupSize, let f = info.threadFeatures {
      computeLimits = ComputeLimits(maxThreads: t, maxWorkgroupSize: w, threadFeatures: f, shaderPresent: info.shaderPresent)
    } else {
      computeLimits = nil
    }
    var l = DeviceLimits()
    // No storage images, indirect or indexed work, queries or kept attachments yet (see this file's header). A pass
    // of several draws is one tiler pass; a second pass over an image clears it (or doesn't care) as the first did.
    l.maxImageDimension = 4096
    l.features.sampledImages = true
    l.features.multipleDrawsPerPass = true
    l.heapTextures = UInt32(Heap.textureSlots)
    l.heapSamplers = UInt32(Heap.samplerSlots)
    l.features.indexedDraw = true
    l.features.indirectDraw = true
    l.features.indirectDispatch = true
    // Occlusion counts accumulate in the GPU's caches, so a query set's memory is mapped cacheable for the GPU (a count in
    // write-combining memory stays 0); with it the counter mode counts the samples (768 for 768 pixels).
    l.features.occlusionQueries = true
    l.features.loadAttachments = true
    // A clear inside a pass is a draw of it (ClearAttachments.swift).
    l.features.clearAttachments = true
    l.features.storageImages = true
    // A window's frames are scanout images whose own pages the window maps (Import.swift's `exportWindowHandle`), so a
    // frame is never staged.
    l.features.presentDirect = true
    l.heapStorageImages = UInt32(Heap.storageSlots)
    // 32-bit atomics on memory and storage images, which are mapped cacheable for the GPU (an atomic in write-combining memory
    // raises GPU_CACHEABILITY_FAULT and does nothing); judged by loinnir-test on the board. The 64-bit ones wait for the
    // compiler's 64-bit integers to be claimed and judged.
    l.features.shaderAtomic32 = true
    l.features.shaderImageAtomics = true
    // Texel buffers: Buffer descriptors in table 2 after the storage images (MaliTexelBuffers.swift); `enableTexelBuffers` fills the limits.
    // The fixed function of the pipeline (PipelineMapping.swift; valhall 06, 08, 09).
    l.features.depth = true
    l.features.stencil = true
    l.features.cullModes = true
    l.features.rasterizerDiscard = true
    // Blend: the fixed-function stage does an equation of one multiplier; a blend shader (valhall 09 section 9.9, made by the compiler and
    // placed in the pass's block) does the rest: minimum and maximum, the saturated source alpha, constants that differ between
    // channels, dual-source blending and logic operations.
    l.features.generalBlend = true
    l.features.dualSourceBlend = true
    l.features.logicOps = true
    l.features.extendedTopologies = true
    l.features.primitiveRestart = true
    l.features.dynamicState = true
    l.features.multipleColorAttachments = true
    l.features.independentBlend = true
    l.maxColorAttachments = 8
    l.features.depthBias = true
    l.features.depthClamp = true
    l.features.wideLines = true
    l.maxLineWidth = PipelineMapping.maxLineWidth
    for f in [PixelFormat.depth16, .depth32f, .stencil8] {
      var c = FormatCapabilities()
      c.depthTarget = true
      l.setFormat(f, c)
    }
    // The formats it has: sampled, filtered, drawn into and blended in light, except the one-channel r8, which it only samples.
    // The sRGB format is a view the texture unit decodes, not one a shader's stores encode, so it has no storage.
    var withStorage = FormatCapabilities.colorTarget
    withStorage.storage = true
    for f in [PixelFormat.rgba8, .bgra8] { l.setFormat(f, withStorage) }
    l.setFormat(.bgra8srgb, .colorTarget)
    var sampledOnly = withStorage
    sampledOnly.renderTarget = false
    sampledOnly.blendable = false
    l.setFormat(.r8, sampledOnly)
    // The one-channel 8 and 16-bit integer formats, as storage images only (a shader's `ST_CVT` and `LD_TEX` convert them; the
    // texture unit's integer sampling and the render targets are not driven).
    var storageOnly = FormatCapabilities()
    storageOnly.storage = true
    for f in [PixelFormat.r8uint, .r8sint, .r16uint, .r16sint] { l.setFormat(f, storageOnly) }
    baseLimits = l
    installResourceCapabilities(&baseLimits)
    enableTexelBuffers()
    enableMultisampling()
    enableLayers()
    enableMultiview()
  }

  /// Multisampling (valhall 08 section 8.3, 07 section 7.9): 2, 4, 8 and 16 samples, the patterns Vulkan's standard locations
  /// are; the render targets and the depth and stencil targets, sampled too (a fetch of a sample); resolves by the pass (the
  /// writeback's average) and by `resolveImage`; the sample mask, sample shading (binary, 06 section 6.9.4), alpha to coverage
  /// (the hardware's mapping) and alpha to one (a blend shader, 09 section 9.2.2).
  func enableMultisampling() {
    let all = SampleCounts(rawValue: 31)
    for f in [PixelFormat.rgba8, .bgra8, .bgra8srgb, .depth16, .depth32f, .stencil8] {
      var c = baseLimits.formats(f)
      if c.renderTarget { c.renderSamples = all }
      if c.depthTarget { c.depthSamples = all }
      if c.sampled { c.sampledSamples = all }
      baseLimits.setFormat(f, c)
    }
    baseLimits.maxSamples = 16
    baseLimits.features.multisample = true
    baseLimits.features.resolveAttachments = true
    baseLimits.features.resolveImage = true
    baseLimits.features.depthStencilResolve = true
    baseLimits.features.sampleShading = true
    baseLimits.features.shaderSampleRateShading = true
    baseLimits.features.alphaToCoverage = true
    baseLimits.features.alphaToOne = true
  }

  /// Passes of layers (valhall 08 section 8.12, 07 section 7.8): a descriptor group and a fragment run each, a tiler context for each
  /// eight, the draws issued once a context where the vertex stage writes Layer (`shaderViewportIndexLayer`), and the frame shaders
  /// reading each layer at its own (the frame argument).
  func enableLayers() {
    baseLimits.features.shaderViewportIndexLayer = true
  }

  /// Multiview (valhall 07 section 7.8.2): up to eight views in one tiler context, the vertex shader replicated for each view of the
  /// mask by the compiler, a descriptor group and a fragment run for each view.
  func enableMultiview() {
    baseLimits.features.multiview = true
    baseLimits.maxMultiviewViews = 8
  }

  deinit {
    try? wait(rule.lastSignalled)
    if let g = renderGroup { transport.destroyGroup(g) }
    if let t = tilerHeap { release([t.context, t.chunk, t.geometry]) }
    if let g = computeGroup { transport.destroyGroup(g) }
    for r in retired { release(r.regions) }
    for r in memories.all { release([r]) }
    for i in images.all { release([i.region]) }
    for r in textureArrays { if let r { release([r]) } }
    for r in storageArrays { if let r { release([r]) } }
    transport.destroySync(timeline)
    transport.destroySync(stepSync)
    transport.destroyVM(vm)
  }

  public var graphicsQueue: any GPUQueue { self }
  public var computeQueue: (any GPUQueue)? { nil }

  // MARK: Memory

  /// The next address of the VM for `size` bytes, a page-aligned run; inside one 4 GiB window when `window`
  /// (workgroup memory is addressed by a 32-bit offset from its base).
  func takeAddress(_ size: Int, window: Bool = false) throws(GPUError) -> UInt64 {
    var at = (nextAddress + 4095) & ~4095
    if window && at >> 32 != (at + UInt64(size) - 1) >> 32 { at = ((at >> 32) + 1) << 32 }
    guard userRange == 0 || at + UInt64(size) <= userRange else { throw .outOfMemory("the GPU's address space") }
    nextAddress = at + UInt64(size)
    return at
  }

  /// A buffer of at least `bytes`, mapped and bound; `gpuCacheable`, mapped cacheable for the GPU (panthor 04 section 4.7.3):
  /// a client's memory, a storage image's and an occlusion query set's, where shader atomics and the counters work. The CPU sees
  /// what the GPU wrote there after the stream's clean (`CSBuilder.cleanCachesForHost`), and the GPU what the CPU wrote since
  /// after the clean and invalidate that begins each job (the driver's ring); streams, descriptors and code stay uncached.
  func makeRegion(_ bytes: Int, window: Bool = false, cpuCached: Bool = false, gpuCacheable: Bool = false) throws(GPUError) -> Region {
    let size = max((bytes + 4095) & ~4095, 4096)
    let address = try takeAddress(size, window: window)
    let buffer = try transport.createBuffer(size: size, cpuCached: cpuCached)
    do { try transport.bind(vm: vm, buffer: buffer, address: address, gpuCacheable: gpuCacheable) } catch {
      transport.destroyBuffer(buffer)
      throw error
    }
    return Region(buffer: buffer, address: address, size: buffer.size)
  }

  /// The tiler's memory, made on first use.
  func tilerMemory() throws(GPUError) -> (context: Region, chunk: Region, geometry: Region) {
    if let t = tilerHeap { return t }
    let context = try makeRegion(4096, gpuCacheable: false)
    let chunk = try makeRegion(Int(Self.tilerChunkBytes), gpuCacheable: false)
    let geometry = try makeRegion(TilerContext.defaultGeometryUnits * 4096, gpuCacheable: false)
    // What the firmware expects zero: the heap context's descriptor and the chunk's header.
    var i = 0
    while i < 64 {
      context.buffer.store(UInt64(0), at: i)
      chunk.buffer.store(UInt64(0), at: i)
      i += 8
    }
    tilerHeap = (context, chunk, geometry)
    return (context, chunk, geometry)
  }

  func release(_ regions: [Region]) {
    for r in regions {
      // Dirty lines the CPU holds must not be written back over what another buffer puts in these pages.
      if r.cached { r.buffer.cleanInvalidate() }
      transport.unbind(vm: vm, address: r.address, size: r.size)
      transport.destroyBuffer(r.buffer)
    }
  }

  /// Hands `regions` back once the work submitted so far has finished.
  func retire(_ regions: [Region]) {
    retired.append((rule.lastSignalled, regions))
    reclaim()
  }

  func reclaim() {
    let done = completed
    retired.removeAll { r in
      guard r.value <= done else { return false }
      release(r.regions)
      return true
    }
  }

  /// The cached regions the step may have written, whose lines in the CPU's cache are now stale: a pass wrote its
  /// target; a dispatch may have written any memory.
  func gpuMayHaveWritten(_ step: Step) {
    if case .render(let pass) = step {
      if pass.target.region.cached { pass.target.region.touched = true }
      for e in pass.extra where e.image.region.cached { e.image.region.touched = true }
      return
    }
    if case .timestamp = step { return }
    for r in memories.all where r.cached { r.touched = true }
    for i in images.all where i.region.cached { i.region.touched = true }
  }

  /// Cleans and invalidates the CPU's cache over each cached region that is touched, so the CPU reads what the GPU
  /// wrote and the GPU's own writes are not overwritten by dirty lines the CPU still holds.
  func syncCached() {
    for r in memories.all where r.cached && r.touched {
      r.buffer.cleanInvalidate()
      r.touched = false
    }
    for i in images.all where i.region.cached && i.region.touched {
      i.region.buffer.cleanInvalidate()
      i.region.touched = false
    }
  }

  public func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard bytes > 0 else { throw .invalid("an allocation of no bytes") }
    reclaim()
    // Readback memory is for the CPU to read: cached there, and maintained (syncCached).
    let region = try makeRegion(bytes, cpuCached: intent == .readback, gpuCacheable: true)
    let handle = memories.insert(region)
    // The CPU's pointer where the intent allows it (the mapping is write-combining).
    return unsafe GPUMemory(handle: handle, address: region.address, pointer: intent == .device ? nil : region.buffer.pointer,
                            size: bytes, intent: intent)
  }

  public func free(_ memory: GPUMemory) {
    guard let region = memories.remove(memory.handle) else { return }
    retire([region])
  }

  // MARK: Images

  /// A scanout image's VMO for a display: rows of `width * 4` bytes, as the display reads them (the layer's stride is its
  /// width times four), where that is a multiple of 64 bytes.
  public func exportHandle(_ image: GPUImage) -> UInt32? {
    guard let r = images[image.handle], r.descriptor.usage.contains(.scanout), r.descriptor.format.bytesPerPixel == 4,
      r.rowStride == Int(r.descriptor.width) * 4
    else { return nil }
    return r.region.buffer.exportVMO()
  }

  public func destroy(_ image: GPUImage) {
    guard let record = images.remove(image.handle) else { return }
    retire([record.region])
  }

  // MARK: The heap (MaliCore's textures land here)

  /// Stores 32-bit words into a region, a pair at a time (the words are an even number).
  func store(_ words: [UInt32], in region: Region, at offset: Int) {
    var i = 0
    while i + 1 < words.count {
      region.buffer.store(UInt64(words[i]) | UInt64(words[i + 1]) << 32, at: offset + 4 * i)
      i += 2
    }
  }

  /// A copy of the heap as it stands, in memory of the VM: the samplers, then the textures up to the highest written.
  func snapshotHeap(held: inout [Region]) throws(GPUError) -> Region {
    let words = samplerWords + textureWords
    let region = try makeRegion(words.count * 4)
    held.append(region)
    store(words, in: region, at: 0)
    return region
  }

  /// A storage image's descriptor is the texture descriptor of 03 section 3.8.6 (one level, identity swizzle, a generic
  /// linear plane), in the storage array that is table 2.
  /// A copy of the storage images' descriptors as they stand, up to the highest written (at least one entry).
  func snapshotStorage(held: inout [Region]) throws(GPUError) -> (region: Region, bytes: Int) {
    let words = storageWords.isEmpty ? [UInt32](repeating: 0, count: Heap.entryWords) : storageWords
    let region = try makeRegion(words.count * 4)
    held.append(region)
    store(words, in: region, at: 0)
    return (region, words.count * 4)
  }

  // MARK: Pipelines

  public func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    if let e = d.check(limits: baseLimits) { throw e }
    for c in d.colorFormats where c == .r8 { throw .unsupported("a pipeline that draws into \(c)") }
    _ = try PipelineMapping.mode(d.topology)
    // The blend of each colour attachment (09 section 9.7.1): fixed function where the blender can do it, a blend shader where it
    // can't. A draw decides again with the constants it has (appendDraw); here only whether the fragment shader may have to call one.
    let srgb = d.colorFormats[0] == .bgra8srgb
    var state = GraphicsState(
      topology: d.topology, restart: d.primitiveRestart, raster: d.rasterization, depthStencil: d.depthStencil,
      depthStencilFormat: d.depthStencilFormat, blend: d.effectiveBlends[0], formats: d.colorFormats, blends: d.effectiveBlends,
      constants: d.blendConstants, dynamic: d.dynamic, srgb: srgb, logicOp: d.logicOp.map { PipelineMapping.logic($0) },
      fragmentCalls: false, multisample: d.multisample)
    state.fragmentCalls = PipelineMapping.mayNeedBlendShader(state)
    let blend = PipelineMapping.blendTargets(state, constants: d.blendConstants)[0].descriptor
    let fragment = try compile(d.fragment, blendShaders: state.fragmentCalls)
    guard let fs = fragment.fragment else { throw .invalid("the fragment module has no fragment shader") }
    // A multiview pipeline's vertex shader stores its outputs for each view of the mask (valhall 07 section 7.8.2).
    let vertex = try compile(d.vertex, nonPerspective: fs.nonPerspectiveMask, viewMask: d.viewMask)
    guard let vs = vertex.vertex else { throw .invalid("the vertex module has no vertex shader") }
    return GPUPipeline(handle: pipelines.insert(.graphics(vertex: vs, fragment: fs, format: d.colorFormats[0], blend: blend, state: state)), kind: .graphics)
  }

  public func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline {
    let words = try spirvWords(spirv)
    let compiled: CompiledShader
    do { compiled = try ValhallBackend.compile(spirv: words, options: BackendOptions(arch: transport.info.arch)) } catch {
      throw .unsupported("the compiler refused the shader: " + describe(error))
    }
    guard compiled.layout.bindings.isEmpty else {
      throw .unsupported("a compute shader with descriptor buffers: the core's layout is the heap and a root pointer")
    }
    return GPUPipeline(handle: pipelines.insert(.compute(compiled.shader, compiled.layout)), kind: .compute)
  }

  public func destroy(_ pipeline: GPUPipeline) { _ = pipelines.remove(pipeline.handle) }

  func spirvWords(_ bytes: [UInt8]) throws(GPUError) -> [UInt32] {
    guard bytes.count % 4 == 0, bytes.count >= 20 else { throw .invalid("not SPIR-V (\(bytes.count) bytes)") }
    var words: [UInt32] = []
    words.reserveCapacity(bytes.count / 4)
    var i = 0
    while i < bytes.count {
      words.append(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
      i += 4
    }
    guard words[0] == 0x0723_0203 else { throw .invalid("not SPIR-V (the magic is 0x\(String(words[0], radix: 16)))") }
    return words
  }

  func compile(_ bytes: [UInt8], nonPerspective: UInt32? = 0, blendShaders: Bool = false, viewMask: UInt32 = 0) throws(GPUError)
    -> CompiledGraphicsShader
  {
    let words = try spirvWords(bytes)
    var options = BackendOptions(arch: transport.info.arch, nonPerspectiveMask: nonPerspective)
    options.blendShaders = blendShaders
    options.viewMask = viewMask
    do {
      return try ValhallBackend.compileGraphics(spirv: words, options: options)
    } catch {
      throw .unsupported("the compiler refused the shader: " + describe(error))
    }
  }

  /// The blend shader for `spec` (09 sections 9.9 and 9.10), made once.
  func blendShader(_ spec: BlendShaderSpec) throws(GPUError) -> BlendShader {
    for b in blendShaders where b.spec == spec { return b.shader }
    let made: BlendShader
    do { made = try ValhallBackend.compileBlendShader(spec, options: BackendOptions(arch: transport.info.arch)) } catch {
      throw .unsupported("the compiler refused a blend shader: " + describe(error))
    }
    blendShaders.append((spec, made))
    return made
  }

  func describe(_ e: BackendError) -> String {
    switch e {
    case .unsupported(let s): return "unsupported: " + s
    case .invalidIR(let s): return "invalid IR: " + s
    case .outOfRegisters: return "out of registers"
    case .fauOverflow: return "the FAU block overflows"
    case .stackOverflow: return "the stack overflows"
    case .invalidOutput(let s): return "invalid output: " + s
    case .frontEnd(let s): return "front end: " + s
    }
  }

  // MARK: Queries

  public func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet {
    switch kind {
    case .timestamp:
      calibrate()
      guard baseLimits.features.timestampQueries else { throw .unsupported("timestamp queries: the GPU's counter can't be read") }
    case .occlusion: guard baseLimits.features.occlusionQueries else { throw .unsupported("occlusion queries") }
    case .pipelineStatistics: throw .unsupported("pipeline statistics queries: the GPU's counters are not driven")
    }
    guard count > 0, count <= 1 << 16 else { throw .invalid("a query set of \(count) queries") }
    reclaim()
    // One 64-bit word a query, in memory the CPU maps write-combining and the GPU writes (the counters live in the GPU's
    // cache until a clean, which every stream's tail does).
    // Occlusion counts accumulate in the GPU's caches (06 section 6.11.1), so their memory is mapped cacheable for the GPU.
    let region = try makeRegion(count * 8, gpuCacheable: kind == .occlusion && probeQueryCacheable)
    var i = 0
    while i < count {
      region.buffer.store(UInt64(0), at: i * 8)
      i += 1
    }
    return GPUQuerySet(handle: queries.insert(QueryRecord(region: region, kind: kind, count: count)), kind: kind, count: count)
  }

  public func destroy(_ set: GPUQuerySet) {
    guard let q = queries.remove(set.handle) else { return }
    retire([q.region])
  }

  public func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] {
    guard let q = queries[set.handle] else { throw .invalid("a query set that isn't this device's") }
    guard first >= 0, count >= 0, first + count <= q.count else { throw .invalid("results past the query set") }
    var out: [UInt64] = []
    out.reserveCapacity(count)
    for i in first..<(first + count) { out.append(unsafe q.region.buffer.pointer.load(fromByteOffset: i * 8, as: UInt64.self)) }
    return out
  }

  /// The period of the GPU's timestamp counter in picoseconds as `calibrateTimestamps` measures it, and the CPU counter's
  /// frequency the device uses when it reads one (0: the measured period is what the device uses). For a test that the two
  /// agree.
  public func measuredTimestampPeriodPicoseconds() -> UInt64? { calibrateTimestamps() }
  public var counterFrequencyHertz: UInt64 { transport.counterFrequency() }

  /// The period of the GPU's timestamp counter, in picoseconds, measured against the system clock: two timestamps 40 ms
  /// apart. The counter runs at the system timer's frequency (panthor 03 section 3.10), which the driver doesn't report
  /// to its clients, so the frequency is the measured one rounded to a MHz. Nil when it can't be measured.
  func calibrateTimestamps() -> UInt64? {
    guard let scratch = try? makeRegion(4096) else { return nil }
    var held: [Region] = []
    defer {
      retire([scratch] + held)
    }
    func sample() -> (ns: UInt64, ticks: UInt64)? {
      scratch.buffer.store(UInt64(0), at: 0)
      let before = transport.nanoseconds()
      do { try runTimestamps([scratch.address], signal: nil, held: &held) } catch { return nil }
      let after = transport.nanoseconds()
      return ((before + after) / 2, unsafe scratch.buffer.pointer.load(fromByteOffset: 0, as: UInt64.self))
    }
    // The first stream makes the compute group, which takes a while that the bracket of a sample must not include.
    guard sample() != nil, let a = sample() else { return nil }
    transport.pause(nanoseconds: 40_000_000)
    guard let b = sample(), b.ticks > a.ticks, b.ns > a.ns else { return nil }
    let hertz = (b.ticks - a.ticks) * 1_000_000_000 / (b.ns - a.ns)
    let rounded = (hertz + 500_000) / 1_000_000 * 1_000_000
    guard rounded > 0 else { return nil }
    return 1_000_000_000_000 / rounded
  }

  // MARK: The timeline

  public var completed: UInt64 { transport.readSync(timeline) }

  /// The timeline's sync is a kernel counter of the client's that the driver raises to each signalled value: a new handle to
  /// it that reads and waits.
  public func timelineHandle() -> UInt32? { transport.syncHandle(timeline) }

  public func wait(_ value: UInt64) throws(GPUError) {
    guard value > 0 else { return }
    defer { syncCached() }
    guard transport.wait(sync: timeline, value: value, timeoutNanoseconds: 60_000_000_000) else {
      if let g = renderGroup, transport.groupState(g) != 0 {
        dropGroup(g)
        throw .lost
      }
      if let g = computeGroup, transport.groupState(g) != 0 {
        dropGroup(g)
        throw .lost
      }
      throw .failed("a wait of the timeline for \(value)", code: 0)
    }
    reclaim()
  }
}
