// SPDX-License-Identifier: BSD-3-Clause

// Running a list on a Mali GPU: `submit` validates it (the core's rules),
// turns it into steps (a compute dispatch, a render pass of one draw, or a
// CPU copy or clear), and runs the steps in order. The streams are MaliCore's
// recipes (ComputeDispatch, RenderPass) laid out in memory of this process's
// VM, a block a step; the last GPU step signals the timeline itself, and
// each step before it is waited for, so what follows sees what it wrote.
// See MaliDevice.swift for what this v0 refuses.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

/// A render pass of one draw.
struct DrawPass {
  var target: ImageRecord
  var clear: [Float]
  var vertex: VertexShader
  var fragment: FragmentShader
  /// Whether the fragment shader reads the heap, which the pass is then given a copy of.
  var usesHeap: Bool
  var root: UInt64
  var vertices: UInt32
  var instances: UInt32
}

enum Step {
  case dispatch(ComputeShader, FauLayout, root: UInt64, grid: Dim3)
  case render(DrawPass)
  case clear(ImageRecord, [Float])
  case copyBuffer(Region, Int, Region, Int, Int)
  case copyBufferToImage(Region, Int, ImageRecord)
  case copyImageToBuffer(ImageRecord, Region, Int)

  var onGPU: Bool {
    switch self {
    case .dispatch, .render: true
    default: false
    }
  }
}

extension MaliDevice {
  public func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = list.validate(features: limits.features) { throw e }
    // This v0 starts a submission when the one before it is done: what it waits for has been signalled by then.
    try self.wait(rule.lastSignalled)
    if let e = rule.accept(wait: wait, signal: signal) { throw e }
    var held: [Region] = []
    do {
      let steps = try plan(list)
      for (i, step) in steps.enumerated() {
        let last = i == steps.count - 1
        try run(step, signal: last && step.onGPU ? signal : nil, held: &held)
      }
      if steps.isEmpty || !(steps.last!.onGPU) { transport.raiseSync(timeline, to: signal) }
    } catch {
      // Whoever waits for the value is not left waiting for ever.
      transport.raiseSync(timeline, to: signal)
      retire(held)
      throw error
    }
    retire(held)
  }

  // MARK: The plan

  func plan(_ list: GPUCommandList) throws(GPUError) -> [Step] {
    var steps: [Step] = []
    var target: ImageRecord?
    var clear: [Float] = []
    var draws: [DrawPass] = []
    for command in list.commands {
      switch command {
      case .beginRendering(let info):
        guard info.colors.count == 1 else { throw .unsupported("a pass with \(info.colors.count) attachments") }
        let a = info.colors[0]
        guard let record = images[a.image.handle] else { throw .invalid("an image that isn't this device's") }
        target = record
        switch a.load {
        case .clear(let r, let g, let b, let alpha): clear = [r, g, b, alpha]
        case .dontCare: clear = [0, 0, 0, 0]
        case .load: throw .unsupported("a pass that loads its attachment's contents")
        }
        draws = []
      case .endRendering:
        guard let record = target else { throw .invalid("a pass ends that didn't begin") }
        if draws.isEmpty {
          steps.append(.clear(record, clear))
        } else {
          steps.append(.render(draws[0]))
        }
        target = nil
      case .setViewport(let x, let y, let w, let h):
        guard let record = target else { throw .invalid("a viewport outside a pass") }
        guard x == 0, y == 0, w == Float(record.descriptor.width), h == Float(record.descriptor.height) else {
          throw .unsupported("a viewport other than the whole target")
        }
      case .setScissor(let x, let y, let w, let h):
        guard let record = target else { throw .invalid("a scissor outside a pass") }
        guard x == 0, y == 0, w == UInt32(record.descriptor.width), h == UInt32(record.descriptor.height) else {
          throw .unsupported("a scissor other than the whole target")
        }
      case .draw(let p, let root, let vertices, let instances, let firstVertex, let firstInstance):
        guard let record = target else { throw .invalid("a draw outside a pass") }
        guard case .graphics(let vs, let fs, let format)? = pipelines[p.handle] else {
          throw .invalid("a pipeline that isn't this device's graphics pipeline")
        }
        guard format == record.descriptor.format else { throw .invalid("a pipeline for \(format) drawing into another format") }
        guard firstVertex == 0, firstInstance == 0 else { throw .unsupported("a draw from a first vertex or instance") }
        let usesHeap = !fs.layout.imageBindings.isEmpty || fs.layout.dummySamplerWord >= 0
        draws.append(DrawPass(target: record, clear: clear, vertex: vs, fragment: fs, usesHeap: usesHeap, root: root, vertices: vertices, instances: instances))
      case .dispatch(let p, let root, let x, let y, let z):
        guard case .compute(let shader, let layout)? = pipelines[p.handle] else {
          throw .invalid("a pipeline that isn't this device's compute pipeline")
        }
        steps.append(.dispatch(shader, layout, root: root, grid: Dim3(x, y, z)))
      case .barrier:
        break  // one submission at a time: every step is already ordered after the last
      case .copyBuffer(let from, let fromOffset, let to, let toOffset, let bytes):
        guard let a = memories[from.handle], let b = memories[to.handle] else { throw .invalid("memory that isn't this device's") }
        steps.append(.copyBuffer(a, fromOffset, b, toOffset, bytes))
      case .copyBufferToImage(let m, let offset, let image):
        guard let a = memories[m.handle], let i = images[image.handle] else { throw .invalid("a resource that isn't this device's") }
        steps.append(.copyBufferToImage(a, offset, i))
      case .copyImageToBuffer(let image, let m, let offset):
        guard let a = memories[m.handle], let i = images[image.handle] else { throw .invalid("a resource that isn't this device's") }
        steps.append(.copyImageToBuffer(i, a, offset))
      case .drawIndexed, .drawIndirect, .drawIndexedIndirect, .dispatchIndirect, .writeTimestamp, .beginQuery, .endQuery:
        throw .unsupported("this command (validate keeps the features it needs off)")
      }
    }
    return steps
  }

  // MARK: Steps

  func run(_ step: Step, signal: UInt64?, held: inout [Region]) throws(GPUError) {
    switch step {
    case .dispatch(let shader, let layout, let root, let grid):
      try runDispatch(shader, layout, root: root, grid: grid, signal: signal, held: &held)
    case .render(let pass):
      try runRender(pass, signal: signal, held: &held)
    case .clear(let image, let color):
      clearImage(image, color)
    case .copyBuffer(let a, let ao, let b, let bo, let bytes):
      unsafe (b.buffer.pointer + bo).copyMemory(from: UnsafeRawPointer(a.buffer.pointer + ao), byteCount: bytes)
    case .copyBufferToImage(let m, let offset, let image):
      let row = Int(image.descriptor.width) * image.descriptor.format.bytesPerPixel
      for y in 0..<Int(image.descriptor.height) {
        unsafe (image.region.buffer.pointer + y * image.rowStride)
          .copyMemory(from: UnsafeRawPointer(m.buffer.pointer + offset + y * row), byteCount: row)
      }
    case .copyImageToBuffer(let image, let m, let offset):
      let row = Int(image.descriptor.width) * image.descriptor.format.bytesPerPixel
      for y in 0..<Int(image.descriptor.height) {
        unsafe (m.buffer.pointer + offset + y * row)
          .copyMemory(from: UnsafeRawPointer(image.region.buffer.pointer + y * image.rowStride), byteCount: row)
      }
    }
  }

  /// Fills the image with `color` (red, green, blue, alpha), in the image's channel order.
  func clearImage(_ image: ImageRecord, _ color: [Float]) {
    func channel(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
    var pixel = [channel(color[0]), channel(color[1]), channel(color[2]), channel(color[3])]
    if image.descriptor.format == .bgra8 { pixel.swapAt(0, 2) }
    let bpp = image.descriptor.format.bytesPerPixel
    if image.descriptor.format == .r8 { pixel = [pixel[0]] }
    for y in 0..<Int(image.descriptor.height) {
      let row = unsafe image.region.buffer.pointer + y * image.rowStride
      for x in 0..<Int(image.descriptor.width) {
        for c in 0..<bpp { unsafe row.storeBytes(of: pixel[c], toByteOffset: x * bpp + c, as: UInt8.self) }
      }
    }
  }

  /// Puts a recipe's block into its region, a word at a time.
  func put(_ image: MemoryImage, into region: Region) {
    var i = 0
    while i < image.count {
      region.buffer.store(image.load64(at: i), at: i)
      i += 8
    }
  }

  /// Runs `jobs` in `group`, and when this isn't the last step waits for them.
  func launch(group: UInt32, jobs: [MaliJob], signal: UInt64?) throws(GPUError) {
    if let signal {
      try transport.submit(group: group, jobs: jobs, waits: [], signals: [(timeline, signal)])
      return
    }
    stepValue += 1
    try transport.submit(group: group, jobs: jobs, waits: [], signals: [(stepSync, stepValue)])
    guard transport.wait(sync: stepSync, value: stepValue, timeoutNanoseconds: 10_000_000_000) else {
      throw transport.groupState(group) != 0 ? .lost : .failed("a pass didn't finish within 10 s", code: 0)
    }
    guard transport.groupState(group) == 0 else { throw .lost }
  }

  func runDispatch(_ shader: ComputeShader, _ layout: FauLayout, root: UInt64, grid: Dim3, signal: UInt64?,
                   held: inout [Region]) throws(GPUError) {
    let info = transport.info
    var threadStorage: UInt64 = 0
    var workgroupMemory: UInt64 = 0
    if let limits = computeLimits {
      let sizing = ComputeSizing.of(shader: shader, grid: grid, limits: limits)
      if shader.stackBytes != 0 {
        let r = try makeRegion(Int(sizing.tlsBytes))
        held.append(r)
        threadStorage = r.address
      }
      if shader.workgroupMemoryBytes != 0 {
        let r = try makeRegion(Int(sizing.wlsBytes), window: true)
        held.append(r)
        workgroupMemory = r.address
      }
    }
    let fau = layout.block(address: { _, _ in 0 }, size: { _, _ in 0 },
                           push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)],
                           workgroups: (grid.x, grid.y, grid.z))
    let request = ComputeDispatchRequest(
      shader: shader, grid: grid, fau: fau, threadStorage: threadStorage, workgroupMemory: workgroupMemory,
      limits: computeLimits, requestComputeResource: !computeStarted, initialiseQueue: !computeStarted)
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    var capacity = (shader.code.count * 8 + 8192 + 4095) & ~4095
    var region = try makeRegion(capacity)
    var image: ComputeDispatchImage?
    var attempts = 0
    while image == nil {
      do throws(DispatchError) {
        image = try ComputeDispatch.build(at: region.address, capacity: region.size, request: request, registers: registers,
                                         scoreboards: scoreboards, arch: info.arch)
      } catch {
        if case .noRoom(let needed, _) = error, attempts == 0 {
          attempts += 1
          held.append(region)
          capacity = (needed + 4095) & ~4095
          region = try makeRegion(capacity)
          continue
        }
        held.append(region)
        throw .unsupported("the dispatch recipe refused it: \(error)")
      }
    }
    held.append(region)
    guard let built = image else { throw .invalid("no dispatch") }
    put(built.memory, into: region)
    if computeGroup == nil { computeGroup = try transport.createGroup(vm: vm, ringSizes: [4096]) }
    let job = MaliJob(queue: 0, address: built.stream.address, size: UInt32(built.stream.size))
    try launch(group: computeGroup!, jobs: [job], signal: signal)
    computeStarted = true
  }

  func runRender(_ pass: DrawPass, signal: UInt64?, held: inout [Region]) throws(GPUError) {
    let info = transport.info
    let target = pass.target
    let width = Int(target.descriptor.width), height = Int(target.descriptor.height)
    let chunkBytes: UInt64 = width * height > 512 * 512 ? 4 << 20 : TilerHeapSizing.smallPassChunkBytes
    let heapContext = try makeRegion(4096)
    held.append(heapContext)
    let chunk = try makeRegion(Int(chunkBytes))
    held.append(chunk)
    let geometry = try makeRegion(65536)
    held.append(geometry)
    // What the firmware expects zero: the heap context's descriptor and the chunk's header.
    var i = 0
    while i < 64 {
      heapContext.buffer.store(UInt64(0), at: i)
      chunk.buffer.store(UInt64(0), at: i)
      i += 8
    }
    let format: ColourFormat = target.descriptor.format == .bgra8 ? .bgra8 : .rgba8
    var request = RenderPassRequest(
      width: width, height: height, format: format, colourAddress: target.region.address, clear: pass.clear, vertices: [],
      colour: [1, 1, 1, 1], heapContext: heapContext.address, heapChunk: chunk.address, heapChunkBytes: chunkBytes,
      geometryBuffer: geometry.address, layout: .splitQueues, initialiseQueues: !renderStarted,
      vertexShader: pass.vertex, fragmentShader: pass.fragment)
    request.rootPointer = pass.root
    request.vertexCount = pass.vertices
    request.instanceCount = pass.instances
    if pass.usesHeap {
      let heap = try snapshotHeap(held: &held)
      request.heapAddress = heap.address
      request.heapBytes = (samplerWords.count + textureWords.count) * 4
      // A binding's element 0: the textures' array is binding 0 and the samplers' binding 1 (Loinnir's, and the one
      // layout of every pipeline).
      request.images = [
        BindingHandle(set: 0, binding: 0, handle: DescriptorHeap.handle(index: Heap.textureBase)),
        BindingHandle(set: 0, binding: 1, handle: DescriptorHeap.handle(index: Heap.samplerBase)),
      ]
      request.dummySampler = DescriptorHeap.handle(index: Heap.samplerBase)
    }
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    var capacity = ((pass.vertex.code.count + pass.fragment.code.count) * 8 + 16384 + 4095) & ~4095
    var region = try makeRegion(capacity)
    var image: RenderPassImage?
    var attempts = 0
    while image == nil {
      do throws(RenderError) {
        image = try RenderPass.build(at: region.address, capacity: region.size, request: request, registers: registers,
                                     scoreboards: scoreboards, arch: info.arch)
      } catch {
        if case .noRoom(let needed, _) = error, attempts == 0 {
          attempts += 1
          held.append(region)
          capacity = (needed + 4095) & ~4095
          region = try makeRegion(capacity)
          continue
        }
        held.append(region)
        throw .unsupported("the render pass recipe refused it: \(error)")
      }
    }
    held.append(region)
    guard let built = image else { throw .invalid("no render pass") }
    put(built.memory, into: region)
    if renderGroup == nil { renderGroup = try transport.createGroup(vm: vm, ringSizes: [4096, 4096]) }
    var jobs: [MaliJob] = []
    for (queue, s) in built.streams.enumerated() {
      jobs.append(MaliJob(queue: UInt32(queue), address: s.address, size: UInt32(s.size)))
    }
    try launch(group: renderGroup!, jobs: jobs, signal: signal)
    renderStarted = true
  }
}
