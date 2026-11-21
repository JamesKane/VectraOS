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
  init(buffer: any MaliBuffer, address: UInt64, size: Int) {
    self.buffer = buffer
    self.address = address
    self.size = size
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
    }
  }

  /// The render target's format, for the formats it can be.
  var colourFormat: ColourFormat {
    switch self {
    case .rgba8: .rgba8
    case .bgra8: .bgra8
    case .bgra8srgb: .bgra8srgb
    case .r8: .rgba8  // never a target (makeImage refuses it)
    }
  }
}

/// The device's one heap as a resource table has it: the samplers first, then the textures. A shader names an
/// entry by its place in the table, so a binding's handle is its array's first entry.
enum Heap {
  static let samplerSlots = 16
  static let textureSlots = 4096
  static let samplerBase = 0
  static let textureBase = samplerSlots
  static let entryWords = 8
}

enum PipelineRecord {
  case compute(ComputeShader, FauLayout)
  case graphics(vertex: VertexShader, fragment: FragmentShader, format: PixelFormat, blend: BlendDescriptor)
}

public final class MaliDevice: GPUDevice, GPUQueue {
  public let name: String
  public let backend = "mali"
  public private(set) var limits = DeviceLimits()
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
  /// The timeline, and the sync the passes of one submission signal between themselves.
  let timeline: UInt32
  let stepSync: UInt32
  var stepValue: UInt64 = 0
  var renderGroup: UInt32?
  var computeGroup: UInt32?
  /// Whether a group's queues have had their slot state set (the first stream of each does).
  var renderStarted = false
  var computeStarted = false
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
    limits = l
  }

  deinit {
    try? wait(rule.lastSignalled)
    if let g = renderGroup { transport.destroyGroup(g) }
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
  func makeRegion(_ bytes: Int, window: Bool = false) throws(GPUError) -> Region {
    let size = max((bytes + 4095) & ~4095, 4096)
    let address = try takeAddress(size, window: window)
    let buffer = try transport.createBuffer(size: size)
    do { try transport.bind(vm: vm, buffer: buffer, address: address) } catch {
      transport.destroyBuffer(buffer)
      throw error
    }
    return Region(buffer: buffer, address: address, size: buffer.size)
  }

  func release(_ regions: [Region]) {
    for r in regions {
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

  public func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard bytes > 0 else { throw .invalid("an allocation of no bytes") }
    reclaim()
    let region = try makeRegion(bytes)
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
    guard d.width > 0, d.height > 0, d.width <= limits.maxImageDimension, d.height <= limits.maxImageDimension else {
      throw .unsupported("an image of \(d.width) x \(d.height)")
    }
    if d.usage.contains(.storage) { throw .unsupported("storage images: MaliCore has no image descriptors yet") }
    if d.usage.contains(.renderTarget) && d.format == .r8 { throw .unsupported("a one-channel render target") }
    reclaim()
    // Every image is linear: the render target writes it so, and the texture unit reads it so.
    guard let texel = d.format.texelFormat else { throw .unsupported("an image of \(d.format)") }
    let layout = ImageLayout(format: texel, kind: .linear, width: Int(d.width), height: Int(d.height))
    let surface = layout.levels[0].surfaceStride
    let sampled = d.usage.contains(.sampled)
    // A sampled image's plane descriptor follows its texels (32 bytes at a 64-byte boundary).
    let region = try makeRegion(surface + (sampled ? PlaneDescriptor.size : 0))
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
    guard let planeAt = record.planeAt else { throw .invalid("a texture that isn't sampled") }
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
    let filter: SamplerWords.Filter = sampler.filter == .linear ? .linear : .nearest
    let wrap: SamplerWords.Wrap
    switch sampler.addressMode {
    case .clampToEdge: wrap = .clampToEdge
    case .repeat: wrap = .repeat
    case .mirroredRepeat: wrap = .mirroredRepeat
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

  public func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    throw .unsupported("the heap's storage images: MaliCore has no image descriptors yet")
  }

  // MARK: Pipelines

  public func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
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
    throw .unsupported("queries: the GPU's counters are not driven yet")
  }

  public func destroy(_ set: GPUQuerySet) {}

  public func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] {
    throw .unsupported("queries: the GPU's counters are not driven yet")
  }

  // MARK: The timeline

  public var completed: UInt64 { transport.readSync(timeline) }

  public func wait(_ value: UInt64) throws(GPUError) {
    guard value > 0 else { return }
    guard transport.wait(sync: timeline, value: value, timeoutNanoseconds: 60_000_000_000) else {
      if let g = renderGroup, transport.groupState(g) != 0 { throw .lost }
      if let g = computeGroup, transport.groupState(g) != 0 { throw .lost }
      throw .failed("a wait of the timeline for \(value)", code: 0)
    }
    reclaim()
  }
}
