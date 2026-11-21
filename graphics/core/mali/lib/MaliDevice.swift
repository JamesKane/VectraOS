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
//  - not yet: the heap (sampled images, samplers, storage images: MaliCore's
//    texture descriptors land at `writeTexture`), indirect and indexed work,
//    several draws in a pass, loading an attachment's contents, queries.
//    Alpha blending is accepted and not applied: the fragment replaces.
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

/// A linear image: its memory, and where its rows are.
final class ImageRecord {
  let region: Region
  let descriptor: ImageDescriptor
  let rowStride: Int
  init(region: Region, descriptor: ImageDescriptor, rowStride: Int) {
    self.region = region
    self.descriptor = descriptor
    self.rowStride = rowStride
  }
}

enum PipelineRecord {
  case compute(ComputeShader, FauLayout)
  case graphics(vertex: VertexShader, fragment: FragmentShader, format: PixelFormat)
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
    // Nothing of the heap, indirect or indexed work, queries or kept attachments yet (see this file's header).
    l.maxImageDimension = 4096
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
    if d.usage.contains(.sampled) { throw .unsupported("sampled images: MaliCore has no texture descriptors yet") }
    if d.usage.contains(.storage) { throw .unsupported("storage images: MaliCore has no image descriptors yet") }
    if d.format == .bgra8srgb { throw .unsupported("sRGB images: no conversion in the render target yet") }
    if d.usage.contains(.renderTarget) && d.format == .r8 { throw .unsupported("a one-channel render target") }
    reclaim()
    let layout = LinearLayout(width: Int(d.width), height: Int(d.height), bytesPerPixel: d.format.bytesPerPixel)
    let region = try makeRegion(layout.surfaceStride)
    let handle = images.insert(ImageRecord(region: region, descriptor: d, rowStride: layout.rowStride))
    return GPUImage(handle: handle, descriptor: d)
  }

  public func destroy(_ image: GPUImage) {
    guard let record = images.remove(image.handle) else { return }
    retire([record.region])
  }

  // MARK: The heap (MaliCore's textures land here)

  public func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    throw .unsupported("the heap's textures: MaliCore has no texture descriptors yet")
  }

  public func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    throw .unsupported("the heap's samplers: MaliCore has no sampler descriptors yet")
  }

  public func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    throw .unsupported("the heap's storage images: MaliCore has no image descriptors yet")
  }

  // MARK: Pipelines

  public func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    guard d.colorFormats.count == 1 else { throw .unsupported("a pipeline with \(d.colorFormats.count) colour targets") }
    guard d.colorFormats[0] == .rgba8 || d.colorFormats[0] == .bgra8 else {
      throw .unsupported("a pipeline that draws into \(d.colorFormats[0])")
    }
    guard d.topology == .triangleList else { throw .unsupported("a topology other than a triangle list") }
    // d.blend: .alpha is accepted and the fragment replaces; MaliCore's blend work lands here.
    let fragment = try compile(d.fragment)
    guard let fs = fragment.fragment else { throw .invalid("the fragment module has no fragment shader") }
    let vertex = try compile(d.vertex, nonPerspective: fs.nonPerspectiveMask)
    guard let vs = vertex.vertex else { throw .invalid("the vertex module has no vertex shader") }
    return GPUPipeline(handle: pipelines.insert(.graphics(vertex: vs, fragment: fs, format: d.colorFormats[0])), kind: .graphics)
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
