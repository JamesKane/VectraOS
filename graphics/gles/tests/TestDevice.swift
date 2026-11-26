// SPDX-License-Identifier: BSD-3-Clause

// A device for GL's host tests: it keeps the core's rules (every list is judged by `validate`, the timeline by
// `TimelineRule`), as the core's own tests' fake does, and it runs the part of a list a test can check without a GPU:
// clears, copies between memory and an image's first level, and the present copy. Draws are recorded, with their root
// blocks, which are host memory (an address is its pointer).

import GPUCore

final class TestQueue: GPUQueue {
  unowned let device: TestDevice
  init(_ device: TestDevice) { self.device = device }
  func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = list.validate(limits: device.limits) { throw e }
    if let e = device.rule.accept(wait: wait, signal: signal) { throw e }
    device.run(list)
    device.submitted.append(list)
    device.reached = signal
  }
  func bindSparse(_ bindings: SparseBindings, wait: UInt64, signal: UInt64) throws(GPUError) { throw .unsupported("sparse") }
}

final class TestDevice: GPUDevice {
  let name = "test"
  let backend = "test"
  var limits: DeviceLimits
  var rule = TimelineRule()
  var reached: UInt64 = 0
  var submitted: [GPUCommandList] = []
  var nextHandle: UInt64 = 1
  var pipelines: [UInt64: GraphicsPipelineDescriptor] = [:]
  var textures: [UInt32: GPUImage] = [:]
  var samplers: [UInt32: SamplerDescriptor] = [:]
  var memories: [UInt64: GPUMemory] = [:]
  var freed: [UInt64] = []
  var destroyedImages: [UInt64] = []
  /// Each image's first level of its first layer, as rgba8 (or its format's) bytes.
  var contents: [UInt64: [UInt8]] = [:]
  var images: [UInt64: GPUImage] = [:]
  var queue: TestQueue!

  init(heapSamplers: UInt32 = 16) {
    var l = DeviceLimits()
    l.features.indexedDraw = true
    l.features.sampledImages = true
    l.features.loadAttachments = true
    l.features.multipleDrawsPerPass = true
    l.features.depth = true
    l.features.stencil = true
    l.features.mipmaps = true
    l.features.arrayImages = true
    l.features.cubeImages = true
    l.features.imageViews = true
    l.features.cullModes = true
    l.features.generalBlend = true
    l.features.dynamicState = true
    l.features.depthBias = true
    l.features.extendedTopologies = true
    l.features.copyImage = true
    l.features.blitImage = true
    l.features.imageRegionCopies = true
    l.features.clearAttachments = true
    l.features.alphaToCoverage = true
    l.heapTextures = 4096
    l.heapSamplers = heapSamplers
    l.maxImageDimension = 4096
    l.maxImageArrayLayers = 6
    for f in [PixelFormat.rgba8, .bgra8] { l.setFormat(f, .colorTarget) }
    var depth = FormatCapabilities()
    depth.depthTarget = true
    depth.sampled = true
    depth.filterable = true
    depth.blitSource = true
    for f in [PixelFormat.depth16, .depth32f, .depth24stencil8, .stencil8] { l.setFormat(f, depth) }
    limits = l
    queue = TestQueue(self)
  }

  var graphicsQueue: any GPUQueue { queue }
  var computeQueue: (any GPUQueue)? { nil }

  func handle() -> UInt64 {
    defer { nextHandle += 1 }
    return nextHandle
  }

  func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard bytes > 0 else { throw .invalid("an allocation of no bytes") }
    let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
    p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    let m = unsafe GPUMemory(handle: handle(), address: UInt64(UInt(bitPattern: p)), pointer: intent == .device ? nil : p,
                             size: bytes, intent: intent)
    memories[m.handle] = m
    return m
  }

  func free(_ memory: GPUMemory) { freed.append(memory.handle) }

  func makeImage(_ d: ImageDescriptor) throws(GPUError) -> GPUImage {
    if let e = d.check(limits: limits) { throw e }
    let i = GPUImage(handle: handle(), descriptor: d)
    images[i.handle] = i
    contents[i.handle] = [UInt8](repeating: 0, count: Int(d.width) * Int(d.height) * d.format.texelBlock.bytes)
    return i
  }

  func destroy(_ image: GPUImage) { destroyedImages.append(image.handle) }
  func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < limits.heapTextures else { throw .invalid("a texture slot past the heap") }
    textures[index] = image
  }
  func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < limits.heapSamplers else { throw .invalid("a sampler slot past the heap") }
    samplers[index] = sampler
  }
  func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) { throw .unsupported("storage images") }

  func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    guard d.vertex.count >= 20, d.vertex.count % 4 == 0, d.fragment.count >= 20, d.fragment.count % 4 == 0 else {
      throw .invalid("not SPIR-V")
    }
    if let e = d.check(limits: limits) { throw e }
    let p = GPUPipeline(handle: handle(), kind: .graphics, targets: d.targets)
    pipelines[p.handle] = d
    return p
  }
  func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline { throw .unsupported("compute") }
  func destroy(_ pipeline: GPUPipeline) {}
  func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet { throw .unsupported("queries") }
  func destroy(_ set: GPUQuerySet) {}
  func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] { [] }

  var completed: UInt64 { reached }
  func wait(_ value: UInt64) throws(GPUError) {
    guard value <= reached else { throw .invalid("a wait for \(value), the timeline is at \(reached)") }
  }

  /// A window's images are staged: the memory they are copied into is exported.
  var exports = 0
  func exportHandle(_ memory: GPUMemory) -> UInt32? {
    exports += 1
    return UInt32(100 + exports)
  }

  // MARK: Running a list

  var draws: [(pipeline: GPUPipeline, root: UInt64, indexed: Bool, count: UInt32)] = []
  var passes: [RenderingInfo] = []

  func run(_ list: GPUCommandList) {
    var pass: RenderingInfo?
    for c in list.commands {
      switch c {
      case .beginRendering(let info):
        pass = info
        passes.append(info)
        for a in info.colors {
          if case .clear(let r, let g, let b, let al) = a.load { fill(a.view.image, [r, g, b, al], nil) }
        }
      case .endRendering: pass = nil
      case .clearAttachments(let attachments, let rects):
        guard let p = pass else { continue }
        for a in attachments {
          if case .color(let i, .float(let r, let g, let b, let al)) = a { for rect in rects { fill(p.colors[i].view.image, [r, g, b, al], rect) } }
        }
      case .draw(let p, let root, let count, _, _, _): draws.append((p, root, false, count))
      case .drawIndexed(let p, let root, _, _, _, let count, _, _, _, _): draws.append((p, root, true, count))
      case .copyBufferToImageRegions(let m, let image, let regions):
        for r in regions where r.subresource.mip == 0 && r.subresource.baseLayer == 0 { copy(m, r, image, toImage: true) }
      case .copyImageToBufferRegions(let image, let m, let regions):
        for r in regions where r.subresource.mip == 0 && r.subresource.baseLayer == 0 { copy(m, r, image, toImage: false) }
      case .copyImageToBuffer(let image, let m, let offset):
        let bytes = contents[image.handle] ?? []
        bytes.withUnsafeBytes { unsafe (m.pointer! + offset).copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
      default: break
      }
    }
  }

  func fill(_ image: GPUImage, _ color: [Float], _ rect: ClearRect?) {
    guard image.format == .rgba8 || image.format == .bgra8 else { return }
    var v = color.map { UInt8(($0 * 255).rounded()) }
    if image.format == .bgra8 { v = [v[2], v[1], v[0], v[3]] }
    let w = Int(image.width), h = Int(image.height)
    let x0 = Int(rect?.x ?? 0), y0 = Int(rect?.y ?? 0)
    let x1 = rect.map { x0 + Int($0.width) } ?? w, y1 = rect.map { y0 + Int($0.height) } ?? h
    for y in y0..<y1 {
      for x in x0..<x1 {
        for c in 0..<4 { contents[image.handle]![(y * w + x) * 4 + c] = v[c] }
      }
    }
  }

  func copy(_ m: GPUMemory, _ r: BufferImageRegion, _ image: GPUImage, toImage: Bool) {
    let texel = image.format.texelBlock.bytes
    let w = Int(image.width)
    let rowLength = r.bufferRowLength == 0 ? Int(r.imageExtent.width) : Int(r.bufferRowLength)
    for y in 0..<Int(r.imageExtent.height) {
      for x in 0..<Int(r.imageExtent.width) {
        let at = ((Int(r.imageOffset.y) + y) * w + Int(r.imageOffset.x) + x) * texel
        let from = r.bufferOffset + (y * rowLength + x) * texel
        for b in 0..<texel {
          if toImage {
            contents[image.handle]![at + b] = unsafe m.pointer!.load(fromByteOffset: from + b, as: UInt8.self)
          } else {
            unsafe m.pointer!.storeBytes(of: contents[image.handle]![at + b], toByteOffset: from + b, as: UInt8.self)
          }
        }
      }
    }
  }

  /// The colour commands of every list submitted, in order: what the tests count.
  var commands: [Command] { submitted.flatMap(\.commands) }
}
