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
//  - not yet: storage images, textures in compute shaders and the vertex
//    stage, indirect and indexed work, several draws in a pass, loading an
//    attachment's contents, queries. Alpha blending is accepted and not
//    applied: the fragment replaces.
//
// This v0 runs one submission at a time: a submission starts when the one
// before it has finished, so the lists need no ordering between the render
// and compute groups, and a CPU copy sees what the GPU wrote. Copies and
// clears with no draw are done by the CPU, in order with the GPU's passes.

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
  init(region: Region, descriptor: ImageDescriptor, rowStride: Int, layout: ImageLayout, planeAt: Int?) {
    self.region = region
    self.descriptor = descriptor
    self.rowStride = rowStride
    self.layout = layout
    self.planeAt = planeAt
  }
}

extension PixelFormat {
  /// The texture unit's format for the image, nil for one it isn't given here.
  var texelFormat: TexelFormat? {
    switch self {
    case .rgba8: .rgba8
    case .bgra8: .bgra8
    case .bgra8srgb: .bgra8srgb
    case .r8: .r8
    case .r8uint: .r8ui
    case .r8sint: .r8i
    case .r16uint: .r16ui
    case .r16sint: .r16i
    default: nil
    }
  }

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
  case graphics(vertex: VertexShader, fragment: FragmentShader, format: PixelFormat, blend: BlendDescriptor)
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
  var rule = TimelineRule()
  /// The heap's descriptors as the client has written them: the samplers' words, and the textures' up to the highest
  /// one written. A draw gets a copy.
  var samplerWords = [UInt32](repeating: 0, count: Heap.samplerSlots * Heap.entryWords)
  var textureWords: [UInt32] = []
  /// The storage images' descriptors (table 2), up to the highest slot written.
  var storageWords: [UInt32] = []
  /// The timeline, and the sync the passes of one submission signal between themselves.
  let timeline: UInt32
  let stepSync: UInt32
  var stepValue: UInt64 = 0
  var renderGroup: UInt32?
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
  /// The compiled shader that loads an attachment's contents into the tile (MaliShaders.preloadFrag), made at first use.
  var preloadShader: FragmentShader?
  /// Turns the occlusion query commands on for a probe of the hardware (loinnir-test's): the counts are not the samples
  /// passed (see BUGS in gpucore(2)), so `limits` doesn't say it has them.
  public func probeOcclusionQueries() { baseLimits.features.occlusionQueries = true }
  /// Bits of every draw's flags 0 to set and to clear, for probes of the hardware (gpu-test's, loinnir-test's).
  public var probeFlags0: (or: UInt32, clear: UInt32) = (0, 0)
  /// A probe of the hardware: after a pass with occlusion queries the fragment queue loads the first report through the GPU
  /// and stores what it read in memory the CPU then reads (`probeReadbackWords`), to tell a lost update from a missing flush.
  public var probeQueryReadback = false
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
    // Occlusion queries stay off: the counter mode counts nothing on the G720 (0 for 768 samples), and only the predicate
    // mode answers (1 where a sample passed). See BUGS in gpucore(2); `probeOcclusionQueries` lets a probe use them.
    l.features.loadAttachments = true
    l.features.storageImages = true
    l.heapStorageImages = UInt32(Heap.storageSlots)
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
  }

  deinit {
    try? wait(rule.lastSignalled)
    if let g = renderGroup { transport.destroyGroup(g) }
    if let t = tilerHeap { release([t.context, t.chunk, t.geometry]) }
    if let g = computeGroup { transport.destroyGroup(g) }
    for r in retired { release(r.regions) }
    for r in memories.all { release([r]) }
    for i in images.all { release([i.region]) }
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

  /// A buffer of at least `bytes`, mapped and bound.
  func makeRegion(_ bytes: Int, window: Bool = false, cpuCached: Bool = false) throws(GPUError) -> Region {
    let size = max((bytes + 4095) & ~4095, 4096)
    let address = try takeAddress(size, window: window)
    let buffer = try transport.createBuffer(size: size, cpuCached: cpuCached)
    do { try transport.bind(vm: vm, buffer: buffer, address: address) } catch {
      transport.destroyBuffer(buffer)
      throw error
    }
    return Region(buffer: buffer, address: address, size: buffer.size)
  }

  /// The tiler's memory, made on first use.
  func tilerMemory() throws(GPUError) -> (context: Region, chunk: Region, geometry: Region) {
    if let t = tilerHeap { return t }
    let context = try makeRegion(4096)
    let chunk = try makeRegion(Int(Self.tilerChunkBytes))
    let geometry = try makeRegion(TilerContext.defaultGeometryUnits * 4096)
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
    let region = try makeRegion(bytes, cpuCached: intent == .readback)
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

  public func makeImage(_ d: ImageDescriptor) throws(GPUError) -> GPUImage {
    guard d.width > 0, d.height > 0, d.width <= baseLimits.maxImageDimension, d.height <= baseLimits.maxImageDimension else {
      throw .unsupported("an image of \(d.width) x \(d.height)")
    }
    if let e = d.check(limits: baseLimits) { throw e }
    if d.usage.contains(.renderTarget) && d.format == .r8 { throw .unsupported("a one-channel render target") }
    reclaim()
    // Every image is linear: the render target writes it so, and the texture unit reads it so.
    guard let texel = d.format.texelFormat else { throw .unsupported("an image of \(d.format)") }
    let layout = ImageLayout(format: texel, kind: .linear, width: Int(d.width), height: Int(d.height))
    let surface = layout.levels[0].surfaceStride
    // A storage image has its plane descriptor as a sampled one does (03 section 3.8.6: the same texture descriptor).
    let sampled = d.usage.contains(.sampled) || d.usage.contains(.storage)
    // A sampled image's plane descriptor follows its texels (32 bytes at a 64-byte boundary). An image the GPU draws
    // into and the CPU only reads (a target copied out of) is mapped cached by the CPU, and maintained (syncCached).
    let readOnlyByCPU = !sampled && !d.usage.contains(.copyDestination) && !d.usage.contains(.storage)
      && !d.usage.contains(.scanout)
    let region = try makeRegion(surface + (sampled ? PlaneDescriptor.size : 0), cpuCached: readOnlyByCPU)
    var planeAt: Int?
    if sampled {
      let words: [UInt32]
      do throws(DescriptorError) { words = try layout.planes(base: region.address)[0].words() } catch {
        release([region])
        throw .invalid("an image the texture unit can't describe")
      }
      store(words, in: region, at: surface)
      planeAt = surface
    }
    let handle = images.insert(
      ImageRecord(region: region, descriptor: d, rowStride: layout.levels[0].rowStride, layout: layout, planeAt: planeAt))
    return GPUImage(handle: handle, descriptor: d)
  }

  /// A scanout image's VMO for a display: rows of `width * 4` bytes, as the display reads them (the layer's stride is its
  /// width times four), which the image's rows are where they are a multiple of 64 bytes.
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

  public func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < UInt32(Heap.textureSlots) else { throw .invalid("texture slot \(index)") }
    guard let record = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard record.descriptor.usage.contains(.sampled), let planeAt = record.planeAt else { throw .invalid("a texture that isn't sampled") }
    let words: [UInt32]
    do throws(DescriptorError) {
      words = try TextureDescriptor(image: record.layout, surfaces: record.region.address + UInt64(planeAt)).words()
    } catch { throw .invalid("an image the texture unit can't describe") }
    let first = Int(index) * Heap.entryWords
    if textureWords.count < first + Heap.entryWords {
      textureWords.append(contentsOf: [UInt32](repeating: 0, count: first + Heap.entryWords - textureWords.count))
    }
    for (i, w) in words.enumerated() { textureWords[first + i] = w }
  }

  public func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < UInt32(Heap.samplerSlots) else { throw .invalid("sampler slot \(index)") }
    if let e = sampler.check(limits: baseLimits) { throw e }
    let filter: SamplerWords.Filter = sampler.filter == .linear ? .linear : .nearest
    let wrap: SamplerWords.Wrap
    switch sampler.addressMode {
    case .clampToEdge: wrap = .clampToEdge
    case .repeat: wrap = .repeat
    case .mirroredRepeat: wrap = .mirroredRepeat
    case .mirrorClampToEdge, .clampToBorder: throw .unsupported("an addressing mode other than clamp, repeat and mirror")
    }
    let words: [UInt32]
    do throws(DescriptorError) {
      words = try SamplerWords(wrapS: wrap, wrapT: wrap, wrapR: wrap, minFilter: filter, magFilter: filter).words()
    } catch { throw .invalid("a sampler the texture unit can't describe") }
    for (i, w) in words.enumerated() { samplerWords[Int(index) * Heap.entryWords + i] = w }
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
  public func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < UInt32(Heap.storageSlots) else { throw .invalid("storage image slot \(index)") }
    guard let record = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard record.descriptor.usage.contains(.storage), let planeAt = record.planeAt else {
      throw .invalid("a storage image that isn't a storage image")
    }
    let words: [UInt32]
    do throws(DescriptorError) {
      words = try TextureDescriptor(image: record.layout, surfaces: record.region.address + UInt64(planeAt)).words()
    } catch { throw .invalid("an image the texture unit can't describe") }
    let first = Int(index) * Heap.entryWords
    if storageWords.count < first + Heap.entryWords {
      storageWords.append(contentsOf: [UInt32](repeating: 0, count: first + Heap.entryWords - storageWords.count))
    }
    for (i, w) in words.enumerated() { storageWords[first + i] = w }
  }

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
    guard d.colorFormats.count == 1 else { throw .unsupported("a pipeline with \(d.colorFormats.count) colour targets") }
    guard d.colorFormats[0] != .r8 else {
      throw .unsupported("a pipeline that draws into \(d.colorFormats[0])")
    }
    guard d.topology == .triangleList else { throw .unsupported("a topology other than a triangle list") }
    // The blend descriptor of the target's one colour attachment: the fragment replaces (opaque), or straight
    // alpha, in light for an sRGB target.
    let srgb = d.colorFormats[0] == .bgra8srgb
    var blend = BlendDescriptor(renderTarget: 0, isSRGB: srgb)
    if d.blend == .alpha {
      do throws(BlendRefusal) {
        blend = try BlendDescriptor(state: BlendState(enabled: true, equation: .alpha), renderTarget: 0, isSRGB: srgb)
      } catch { throw .unsupported("a blend the fixed-function stage can't do") }
    }
    let fragment = try compile(d.fragment)
    guard let fs = fragment.fragment else { throw .invalid("the fragment module has no fragment shader") }
    let vertex = try compile(d.vertex, nonPerspective: fs.nonPerspectiveMask)
    guard let vs = vertex.vertex else { throw .invalid("the vertex module has no vertex shader") }
    return GPUPipeline(handle: pipelines.insert(.graphics(vertex: vs, fragment: fs, format: d.colorFormats[0], blend: blend)), kind: .graphics)
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

  func compile(_ bytes: [UInt8], nonPerspective: UInt32? = 0) throws(GPUError) -> CompiledGraphicsShader {
    let words = try spirvWords(bytes)
    do {
      return try ValhallBackend.compileGraphics(
        spirv: words, options: BackendOptions(arch: transport.info.arch, nonPerspectiveMask: nonPerspective))
    } catch {
      throw .unsupported("the compiler refused the shader: " + describe(error))
    }
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
    let region = try makeRegion(count * 8)
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
