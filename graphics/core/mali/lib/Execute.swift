// SPDX-License-Identifier: BSD-3-Clause

// Running a list on a Mali GPU: `submit` validates it (the core's rules),
// turns it into steps (a compute dispatch, a render pass of its draws, or a
// CPU copy or clear), and runs the steps in order. The streams are MaliCore's
// recipes (ComputeDispatch, RenderPass) laid out in memory of this process's
// VM, a block a step; the last GPU step signals the timeline itself, and
// each step before it is waited for, so what follows sees what it wrote.
// See MaliDevice.swift for what this v0 refuses.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

/// A render pass of up to 80 draws, run one after the other in the one tiler pass.
struct DrawPass {
  var target: ImageRecord
  var clear: [Float]
  var draws: [PassDraw]
  /// Whether a fragment shader reads the heap, which the pass is then given a copy of.
  var usesHeap: Bool
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
      var gpuRan = false
      for (i, step) in steps.enumerated() {
        let last = i == steps.count - 1
        // A step of the CPU's reads what the GPU wrote before it: the CPU's cache is brought up to date first.
        if !step.onGPU && gpuRan {
          syncCached()
          gpuRan = false
        }
        if step.onGPU {
          gpuMayHaveWritten(step)
          gpuRan = true
        }
        try run(step, signal: last && step.onGPU ? signal : nil, held: &held)
      }
      if steps.isEmpty || !(steps.last!.onGPU) {
        // Done, and the CPU's caches too, before the value says so.
        syncCached()
        transport.raiseSync(timeline, to: signal)
      }
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
    var draws: [PassDraw] = []
    var usesHeap = false
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
        usesHeap = false
      case .endRendering:
        guard let record = target else { throw .invalid("a pass ends that didn't begin") }
        if draws.isEmpty {
          steps.append(.clear(record, clear))
        } else {
          steps.append(.render(DrawPass(target: record, clear: clear, draws: draws, usesHeap: usesHeap)))
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
        guard case .graphics(let vs, let fs, let format, let blend)? = pipelines[p.handle] else {
          throw .invalid("a pipeline that isn't this device's graphics pipeline")
        }
        guard format == record.descriptor.format else { throw .invalid("a pipeline for \(format) drawing into another format") }
        guard firstVertex == 0, firstInstance == 0 else { throw .unsupported("a draw from a first vertex or instance") }
        let heapDraw = !fs.layout.imageBindings.isEmpty || fs.layout.dummySamplerWord >= 0
        // A draw of fewer than three vertices, or of no instances, makes no primitive.
        if vertices < 3 || instances == 0 { break }
        guard draws.count < 80 else { throw .unsupported("a pass of more than 80 draws") }
        usesHeap = usesHeap || heapDraw
        // A binding's element 0: the textures' array is binding 0 and the samplers' binding 1 (Loinnir's, and the one
        // layout of every pipeline).
        draws.append(PassDraw(
          vertexShader: vs, fragmentShader: fs, vertexCount: Int(vertices), instanceCount: Int(instances),
          push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)], blend: blend,
          images: heapDraw
            ? [
              BindingHandle(set: 0, binding: 0, handle: DescriptorHeap.handle(index: Heap.textureBase)),
              BindingHandle(set: 0, binding: 1, handle: DescriptorHeap.handle(index: Heap.samplerBase)),
            ] : [],
          dummySampler: heapDraw ? DescriptorHeap.handle(index: Heap.samplerBase) : 0))
        draws[draws.count - 1].allowForwardPixelToBeKilled = unsafe !GPUDiagnostics.noForwardPixelKill
        draws[draws.count - 1].lateKill = unsafe GPUDiagnostics.lateKill
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
      image.region.touched = true
      clearImage(image, color)
    case .copyBuffer(let a, let ao, let b, let bo, let bytes):
      b.touched = true
      unsafe (b.buffer.pointer + bo).copyMemory(from: UnsafeRawPointer(a.buffer.pointer + ao), byteCount: bytes)
    case .copyBufferToImage(let m, let offset, let image):
      image.region.touched = true
      let row = Int(image.descriptor.width) * image.descriptor.format.bytesPerPixel
      for y in 0..<Int(image.descriptor.height) {
        unsafe (image.region.buffer.pointer + y * image.rowStride)
          .copyMemory(from: UnsafeRawPointer(m.buffer.pointer + offset + y * row), byteCount: row)
      }
    case .copyImageToBuffer(let image, let m, let offset):
      m.touched = true
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
    if image.descriptor.format == .bgra8srgb {
      // The colour channels are stored encoded; the alpha never is.
      for c in 0..<3 { pixel[c] = UInt8(min(max(ColourFormat.srgbEncode(min(max(color[c], 0), 1)), 0), 1) * 255 + 0.5) }
    }
    if image.descriptor.format == .bgra8 || image.descriptor.format == .bgra8srgb { pixel.swapAt(0, 2) }
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
      let state = transport.groupState(group)
      if state != 0 { dropGroup(group) }
      throw state != 0 ? faulted(state) : .failed("a pass didn't finish within 10 s", code: 0)
    }
    let state = transport.groupState(group)
    guard state == 0 else {
      dropGroup(group)
      throw faulted(state)
    }
  }

  /// A group that faulted is of no more use: its queues are gone and the next pass makes a group of its own, whose
  /// queues start again.
  func dropGroup(_ group: UInt32) {
    if group == renderGroup {
      transport.destroyGroup(group)
      renderGroup = nil
      renderStarted = false
    } else if group == computeGroup {
      transport.destroyGroup(group)
      computeGroup = nil
      computeStarted = false
    }
  }

  /// A group that ended, in words (the driver reports the group's state, not the fault's address).
  func faulted(_ state: UInt32) -> GPUError {
    .failed("a pass ended its group (group state \(state), bit 1 is a fatal fault)", code: Int32(truncatingIfNeeded: state))
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
    // The device's one tiler heap: the context, the first chunk and the geometry buffer are made once and every pass
    // uses them (the kernel's heap is a group's too), so a later pass never names memory an earlier one let go.
    let tiler = try tilerMemory()
    let chunkBytes = Self.tilerChunkBytes
    var request = DrawPassRequest(
      width: width, height: height, format: target.descriptor.format.colourFormat, colourAddress: target.region.address,
      clear: pass.clear, draws: pass.draws, heapContext: tiler.context.address, heapChunk: tiler.chunk.address,
      heapChunkBytes: chunkBytes, geometryBuffer: tiler.geometry.address, layout: .splitQueues, initialiseQueues: !renderStarted)
    // Stack and spills of any shader live in thread storage the pass's TSD names.
    let stack = request.stackBytes
    if stack != 0 {
      guard let limits = computeLimits else { throw .unsupported("a shader with a stack: the driver reports no thread limits") }
      let r = try makeRegion(Int(ThreadStorageSizing.tlsTotal(stackBytes: stack, limits: limits)))
      held.append(r)
      request.threadStorage = r.address
      request.limits = limits
    }
    if pass.usesHeap {
      let heap = try snapshotHeap(held: &held)
      request.heapAddress = heap.address
      request.heapBytes = (samplerWords.count + textureWords.count) * 4
    }
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    var codeWords = 0
    for d in pass.draws { codeWords += d.vertexShader.code.count + d.fragmentShader.code.count }
    var capacity = (codeWords * 8 + 16384 * pass.draws.count + 4095) & ~4095
    var region = try makeRegion(capacity)
    var image: RenderPassImage?
    var attempts = 0
    while image == nil {
      do throws(RenderError) {
        image = try RenderPass.build(at: region.address, capacity: region.size, request: request, registers: registers,
                                     scoreboards: scoreboards, arch: info.arch).image
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
