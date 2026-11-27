// SPDX-License-Identifier: BSD-3-Clause

// Running a list on a Mali GPU: `submit` validates it (the core's rules),
// turns it into steps (a compute dispatch, a render pass of its draws, or a
// transfer's kernel, Transfers.swift), and runs the steps in order. The streams
// are MaliCore's recipes (ComputeDispatch, RenderPass) laid out in memory of
// this process's VM (the arena's, Arena.swift), a block a step, on the queues of
// one group; each step waits on the GPU for the one before it through the
// device's chain (StepChain), so what follows sees what it wrote, and the whole
// list is one submission to the driver, which signals the timeline when it is done.
// See MaliDevice.swift for what this v0 refuses.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

/// A render pass of its draws, run one after the other in the one tiler pass.
struct DrawPass {
  var target: ImageRecord
  var clear: [Float]
  var draws: [PassDraw]
  /// Whether a fragment shader reads the heap, which the pass is then given a copy of.
  var usesHeap: Bool
  /// Whether a fragment shader names a storage image.
  var usesStorage: Bool = false
  /// The pass keeps the target's contents: its first pre-frame shader loads them into each tile.
  var load: Bool = false
  /// The reports of the occlusion queries begun in the pass (zeroed by the GPU before the pass's fragment work).
  var queries: [UInt64] = []
  /// The colour targets after the first, and the colours they start from.
  var extra: [(image: ImageRecord, clear: [Float])] = []
  /// The depth and stencil target.
  var zs: ZSBinding?
  /// Samples of every attachment (valhall 08 section 8.3).
  var samples: Int = 1
  /// Whether each colour target is stored (`StoreAction.store`), and the single-sample images it is resolved into as the pass ends.
  var stores: [Bool] = []
  var resolves: [(of: Int, image: ImageRecord, view: ImageView)] = []
  /// The colour attachments' views (the first is `target`'s), the depth and stencil attachment's, and the layers drawn.
  var views: [ImageView] = []
  var zsView: ImageView?
  var layers: Int = 1
  /// A multiview pass's views (bit i: view i into layer i); 0 for none.
  var viewMask: UInt32 = 0
}

/// A pass's depth and stencil attachment as a pass plans it.
struct ZSBinding {
  var image: ImageRecord
  var clearDepth: Float
  var clearStencil: UInt32
  var storeDepth: Bool
  var storeStencil: Bool
  /// The pass keeps the plane's contents: the second pre-frame shader loads it into each tile.
  var loadDepth = false
  var loadStencil = false
  /// The single-sample image and view a multisampled attachment is resolved into as the pass ends: sample 0 of each plane (valhall
  /// 08 section 8.10.5: depth and stencil resolve only by sample 0).
  var resolve: (image: ImageRecord, view: ImageView)?
}

enum Step {
  /// With `indirect`, the grid is the three words at that address when the dispatch runs. A transfer's kernel names itself
  /// (`kernel`), and the blit kernel its own heap of samplers and textures (`heap`: the table's address and bytes).
  case dispatch(ComputeShader, FauLayout, root: UInt64, grid: Dim3, indirect: UInt64?, heap: (address: UInt64, bytes: Int)? = nil,
                kernel: TransferKernel? = nil)
  case render(DrawPass)
  /// The system timestamp, stored at this address once everything before has finished.
  case timestamp(UInt64)
}

extension MaliDevice {
  public func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError) {
    // A submission is laid out while the one before it runs; the one before that is done first, so at most two are on the GPU.
    try self.wait(previousSignal)
    let start = clock()
    lastProfile = SubmitProfile()
    defer { lastProfile.totalNanoseconds = clock() &- start }
    if let e = list.validate(features: baseLimits.features) { throw e }
    let before = rule.lastSignalled
    if let e = rule.accept(wait: wait, signal: signal) { throw e }
    var held: [Region] = []
    let started = (renderStarted, computeSlotsReady, computeResourceRequested)
    let lastQueue = chainQueue
    do {
      let steps = try plan(list, held: &held)
      lastProfile.planNanoseconds = clock() &- start
      lastProfile.steps = steps.count
      if steps.isEmpty {
        // Nothing for the GPU: the value is reached when what was submitted before it is.
        if before > completed { try self.wait(before) }
        transport.raiseSync(timeline, to: signal)
      } else {
        // Every step is the GPU's, each waiting on the GPU for the one before it, the first for the last step submitted
        // before (the chain counts every step ever submitted); one submit of them all, which signals the timeline.
        let chain = try chainSync()
        let base = chainValue
        var jobs = try queueStartJobs(held: &held)
        for (i, step) in steps.enumerated() {
          gpuMayHaveWritten(step)
          let k = base + UInt64(i)
          // A stream on the queue the step before ended on needs no wait: the queue runs its jobs in order, each to its last
          // slot's wait, and the next job starts with the driver's clean and invalidate of the caches. Only a stream on
          // another queue waits on the chain (and a wait costs the GPU some 18 us: loinnir-test's frame budgets).
          var c = StepChain(address: chain.address, waitAbove: k == 0 ? nil : k - 1, cleansForHost: i == steps.count - 1)
          let queue: UInt32
          if case .render = step, singleQueuePasses {
            // The pass is one stream on the tiler's queue.
            queue = Self.tilerQueue
            if chainQueue == queue {
              c.waitAbove = nil
              c.invalidates = k > 0
            }
          } else if case .render = step {
            queue = Self.tilerQueue + 1
            if chainQueue == queue { c.fragmentWaits = false }
          } else {
            queue = Self.computeQueue
            if chainQueue == queue {
              c.waitAbove = nil
              c.invalidates = k > 0
            }
          }
          jobs += try self.jobs(step, chain: c, held: &held)
          chainQueue = queue
        }
        try launch(group: try workGroup(), jobs: try oneJobAQueue(jobs, held: &held), signal: signal)
        chainValue = base + UInt64(steps.count)
      }
    } catch {
      // Streams that never reached the GPU set no queue's state, nor which queue the last step ended on.
      (renderStarted, computeSlotsReady, computeResourceRequested) = started
      chainQueue = lastQueue
      // Whoever waits for the value is not left waiting for ever, nor sees it before what came first is done.
      if before > completed { try? self.wait(before) }
      transport.raiseSync(timeline, to: signal)
      retire(held)
      previousSignal = before
      throw error
    }
    retire(held)
    previousSignal = before
  }

  /// The chain's sync object: 8 bytes of a buffer of its own, made at the first step, which every step adds one to.
  func chainSync() throws(GPUError) -> Region {
    if let c = chainRegion { return c }
    let c = try makeRegion(4096)
    c.buffer.store(UInt64(0), at: 0)
    chainRegion = c
    chainValue = 0
    return c
  }

  /// The sample patterns' table (valhall 07 section 7.9), made at first use and kept: every pass points at it.
  func sampleTable() throws(GPUError) -> Region {
    if let t = samplePatterns { return t }
    let t = try makeRegion(SamplePatterns.tableBytes)
    let bytes = SamplePatterns.table()
    var words = [UInt32](repeating: 0, count: bytes.count / 4)
    for i in 0..<words.count {
      words[i] = UInt32(bytes[4 * i]) | UInt32(bytes[4 * i + 1]) << 8 | UInt32(bytes[4 * i + 2]) << 16 | UInt32(bytes[4 * i + 3]) << 24
    }
    store(words, in: t, at: 0)
    samplePatterns = t
    return t
  }

  /// The one group, made at first use.
  func workGroup() throws(GPUError) -> UInt32 {
    if let g = renderGroup { return g }
    let g = try transport.createGroup(vm: vm, ringSizes: [Self.ringBytes, Self.ringBytes, Self.ringBytes])
    renderGroup = g
    return g
  }

  static let tilerQueue: UInt32 = 0
  static let computeQueue: UInt32 = 2

  /// The streams that start the group's queues, before any step of theirs: each queue's slot state, and its resources asked
  /// for (the tiler's and the vertex shading's, the fragment work's, compute's; 02 sections 2.2.3 and 2.9.3), all three at
  /// once, before any queue waits on the chain, so no queue asks for its resources while another holds its own waiting.
  /// None once they have run; the steps' own streams then start nothing.
  func queueStartJobs(held: inout [Region]) throws(GPUError) -> [MaliJob] {
    if renderStarted && computeSlotsReady && computeResourceRequested { return [] }
    let info = transport.info
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    let region = try scratch(3 * 256, held: &held)
    var jobs: [MaliJob] = []
    // With a pass on one queue, that queue asks for the fragment work's resources too.
    let tiling = singleQueuePasses ? CSResources.tiler | .idvs | .fragment : CSResources.tiler | .idvs
    for (q, resources) in [(Self.tilerQueue, tiling), (Self.tilerQueue + 1, .fragment), (Self.computeQueue, .compute)] {
      var b = CSBuilder(address: region.address + UInt64(q) * 256, capacityBytes: 256, registers: registers, scoreboards: scoreboards)
      b.initialiseSlotState()
      b.requestResources(resources)
      let stream: CSStream
      do throws(CSBuildError) { stream = try b.finish() } catch { throw .unsupported("a queue's start stream refused: \(error)") }
      for (i, w) in stream.words.enumerated() { region.buffer.store(w, at: Int(q) * 256 + i * 8) }
      jobs.append(MaliJob(queue: q, address: stream.address, size: UInt32(stream.size)))
    }
    renderStarted = true
    computeSlotsReady = true
    computeResourceRequested = true
    return jobs
  }

  // MARK: The plan

  /// The steps of a list; a transfer's parameters are laid out in memory now, held until the submission is done.
  func plan(_ list: GPUCommandList, held: inout [Region]) throws(GPUError) -> [Step] {
    var steps: [Step] = []
    func transfer(_ t: Transfer) throws(GPUError) {
      // A kernel that writes an image changes its bytes behind its CRC table (valhall 08 section 8.6.4).
      switch t {
      case .bufferToImage(_, let i, _), .clearColor(let i, _, _), .clearDepthStencil(let i, _, _, _): i.invalidateCRC()
      case .copyImage(_, let i, _), .blit(_, let i, _, _), .resolve(_, let i, _): i.invalidateCRC()
      default: break
      }
      steps += try transferSteps(t, held: &held)
    }
    var target: ImageRecord?
    var clear: [Float] = []
    var draws: [PassDraw] = []
    var usesHeap = false
    var loads = false
    /// The address of the counter of the occlusion query that is active (0: none).
    var activeQuery: UInt64 = 0
    var queryReports: [UInt64] = []
    var queryCells: [(QueryRecord, Int)] = []
    var zs: ZSBinding?
    var dyn = DynamicValues()
    var extraTargets: [(image: ImageRecord, clear: [Float])] = []
    var samples = 1
    var stores: [Bool] = []
    var resolves: [(of: Int, image: ImageRecord, view: ImageView)] = []
    var views: [ImageView] = []
    var zsView: ImageView?
    var layers = 1
    var viewMask: UInt32 = 0
    for command in list.commands {
      switch command {
      case .beginRendering(let info):
        guard info.colors.count >= 1 && info.colors.count <= 8 else { throw .unsupported("a pass with \(info.colors.count) attachments") }
        let a = info.colors[0]
        guard let record = images[a.image.handle] else { throw .invalid("an image that isn't this device's") }
        target = record
        extraTargets = []
        planTargets = [record]
        planPass &+= 1
        samples = Int(info.samples)
        stores = []
        resolves = []
        views = info.colors.map { $0.view }
        planSize = (Int(info.width), Int(info.height))
        zsView = info.depthStencil?.view
        // A multiview pass covers the layers up to its highest view; only the views in its mask are drawn.
        viewMask = info.viewMask
        layers = info.viewMask != 0 ? 32 - info.viewMask.leadingZeroBitCount : Int(info.layerCount)
        for (i, c) in info.colors.enumerated() {
          stores.append(c.store == .store || c.resolve == nil)
          if let v = c.resolve {
            guard let r = images[v.image.handle] else { throw .invalid("an image that isn't this device's") }
            resolves.append((i, r, v))
          }
        }
        for (i, c) in info.colors.enumerated() where i > 0 {
          guard let r = images[c.image.handle] else { throw .invalid("an image that isn't this device's") }
          for t in planTargets where t === r { throw .invalid("an image attached twice to a pass") }
          switch c.load {
          case .clear(let red, let green, let blue, let alpha): extraTargets.append((r, [red, green, blue, alpha]))
          case .dontCare: extraTargets.append((r, [0, 0, 0, 0]))
          case .load: throw .unsupported("keeping the contents of one of several colour attachments: the frame shader loads one")
          }
          planTargets.append(r)
        }
        loads = false
        switch a.load {
        case .clear(let r, let g, let b, let alpha): clear = [r, g, b, alpha]
        case .dontCare: clear = [0, 0, 0, 0]
        case .load:
          // The tile is filled from the image by the pass's first pre-frame shader; the clear colour is never seen.
          clear = [0, 0, 0, 0]
          loads = true
        }
        draws = []
        queryReports = []
        queryCells = []
        usesHeap = false
        dyn = DynamicValues()
        dynVersion &+= 1
        zs = nil
        if let ds = info.depthStencil {
          guard let image = images[ds.view.image.handle] else { throw .invalid("an image that isn't this device's") }
          let f = image.descriptor.format
          zs = ZSBinding(image: image, clearDepth: ds.clearDepth, clearStencil: ds.clearStencil,
                         storeDepth: f.hasDepth && ds.depthStore == .store, storeStencil: f.hasStencil && ds.stencilStore == .store,
                         loadDepth: f.hasDepth && ds.depthLoad == .load, loadStencil: f.hasStencil && ds.stencilLoad == .load)
          if let v = ds.resolve {
            guard let r = images[v.image.handle] else { throw .invalid("an image that isn't this device's") }
            zs!.resolve = (r, v)
          }
          if zs!.loadDepth && zs!.loadStencil {
            throw .unsupported("keeping both the depth and the stencil of one image: the frame shader loads one plane")
          }
        }
      case .endRendering:
        guard let record = target else { throw .invalid("a pass ends that didn't begin") }
        guard activeQuery == 0 else { throw .invalid("a pass ends inside an occlusion query") }
        // A pass over an AFBC attachment that draws nothing still runs, with its clears drawn: AFBC is written by a pass only (no
        // clear kernel writes its headers, valhall 05 section 5.11.10.1).
        let afbc = record.layout.kind == .afbc || zs?.image.planes.contains(where: { $0.layout.kind == .afbc }) == true
          || extraTargets.contains(where: { $0.image.layout.kind == .afbc })
        if draws.isEmpty && afbc {
          var cleared: [ClearAttachment] = []
          if !loads { cleared.append(.color(index: 0, .float(clear[0], clear[1], clear[2], clear[3]))) }
          for (i, e) in extraTargets.enumerated() { cleared.append(.color(index: i + 1, .float(e.clear[0], e.clear[1], e.clear[2], e.clear[3]))) }
          if let z = zs, !z.loadDepth && !z.loadStencil {
            let f = z.image.descriptor.format
            var aspects = ImageAspects(rawValue: 0)
            if f.hasDepth { aspects = aspects | .depth }
            if f.hasStencil { aspects = aspects | .stencil }
            cleared.append(.depthStencil(aspects: aspects, depth: z.clearDepth, stencil: z.clearStencil))
          }
          if !cleared.isEmpty {
            try appendClears(cleared, [ClearRect(width: UInt32(planSize.width), height: UInt32(planSize.height), layerCount: UInt32(layers))],
                             into: &draws, target: target, zs: zs, view: views.first, layers: viewMask != 0 ? 1 : layers, viewMask: viewMask)
          }
        }
        if draws.isEmpty {
          // A pass that keeps the contents and draws nothing changes nothing.
          // The clear kernel clears what the views cover: their level and the pass's layers.
          func range(_ v: ImageView, _ aspects: ImageAspects = .color) -> [ImageSubresourceRange] {
            if viewMask == 0 {
              return [ImageSubresourceRange(aspects: aspects, baseMip: v.baseMip, mipCount: 1, baseLayer: v.baseLayer, layerCount: UInt32(layers))]
            }
            var out: [ImageSubresourceRange] = []
            for b in 0..<8 where viewMask >> UInt32(b) & 1 == 1 {
              out.append(ImageSubresourceRange(aspects: aspects, baseMip: v.baseMip, mipCount: 1, baseLayer: v.baseLayer + UInt32(b), layerCount: 1))
            }
            return out
          }
          func clearStep(_ image: ImageRecord, _ view: ImageView, _ c: [Float]) throws(GPUError) {
            try transfer(.clearColor(image, .float(c[0], c[1], c[2], c[3]), range(view)))
          }
          if !loads { try clearStep(record, views[0], clear) }
          // A pass that draws nothing resolves its clear (or what it kept) into each resolve image.
          for v in resolves {
            if v.of == 0 && loads {
              try transfer(.resolve(record, v.image, [ImageCopyRegion(
                srcSubresource: ImageSubresourceLayers(mip: views[0].baseMip, baseLayer: views[0].baseLayer, layerCount: UInt32(layers)),
                dstSubresource: ImageSubresourceLayers(mip: v.view.baseMip, baseLayer: v.view.baseLayer, layerCount: UInt32(layers)),
                extent: Extent3D(width: UInt32(views[0].width), height: UInt32(views[0].height)))]))
            } else {
              try clearStep(v.image, v.view, v.of == 0 ? clear : extraTargets[v.of - 1].clear)
            }
          }
          // No fragment work runs for the queries of a pass with no draw: a fill zeroes them, in order with the rest.
          for (q, index) in queryCells { try transfer(.fill(q.region, index * 8, 8, 0)) }
          for (i, e) in extraTargets.enumerated() { try clearStep(e.image, views[i + 1], e.clear) }
          if let z = zs, let v = zsView, !z.loadDepth && !z.loadStencil {
            let f = z.image.descriptor.format
            var aspects = ImageAspects(rawValue: 0)
            if f.hasDepth && z.storeDepth { aspects = aspects | .depth }
            if f.hasStencil && z.storeStencil { aspects = aspects | .stencil }
            if !aspects.isEmpty {
              try transfer(.clearDepthStencil(z.image, z.clearDepth, z.clearStencil, range(v, aspects)))
            }
            if let r = z.resolve {
              try transfer(.clearDepthStencil(r.image, z.clearDepth, z.clearStencil, range(r.view, f.aspects)))
            }
          } else if let z = zs, let v = zsView, let r = z.resolve {
            // Kept and drawn nothing: sample 0 of what is there.
            try transfer(.copyImage(z.image, r.image, [zsResolveRegion(z, v, r.view, layers: layers)]))
          }
        } else {
          var storage = false
          for d in draws where d.fragmentShader.layout.imageBindings.contains(where: { $0.binding >= 2 && $0.binding <= 4 }) { storage = true }
          steps.append(.render(DrawPass(
            target: record, clear: clear, draws: draws, usesHeap: usesHeap, usesStorage: storage, load: loads,
            queries: queryReports, extra: extraTargets, zs: zs, samples: samples, stores: stores, resolves: resolves, views: views,
            zsView: zsView, layers: layers, viewMask: viewMask)))
          // A plane both stored and resolved: the pass writes every sample, and sample 0 is copied to the resolve image after it.
          if let z = zs, let v = zsView, let r = z.resolve, z.storeDepth || z.storeStencil {
            try transfer(.copyImage(z.image, r.image, [zsResolveRegion(z, v, r.view, layers: layers)]))
          }
        }
        target = nil
        zs = nil
      case .setViewport(let x, let y, let w, let h):
        dynVersion &+= 1
        guard target != nil else { throw .invalid("a viewport outside a pass") }
        dyn.viewport = DrawViewport(x: x, y: y, width: w, height: h)
      case .setScissor(let x, let y, let w, let h):
        dynVersion &+= 1
        guard target != nil else { throw .invalid("a scissor outside a pass") }
        dyn.scissor = PipelineMapping.scissorBox(x: Int(x), y: Int(y), width: Int(w), height: Int(h), targetWidth: planSize.width, targetHeight: planSize.height)
      // Viewports and scissors from `first`, each with its depth range: the first is the draw's own, the rest the scissor array's
      // (RenderPassDraws) for a vertex shader that picks one.
      case .setViewports(let first, let vs):
        dynVersion &+= 1
        guard target != nil else { throw .invalid("a viewport outside a pass") }
        for (k, v) in vs.enumerated() {
          let at = Int(first) + k
          let viewport = DrawViewport(x: v.x, y: v.y, width: v.width, height: v.height, minDepth: v.minDepth, maxDepth: v.maxDepth)
          while dyn.viewports.count <= at { dyn.viewports.append(nil) }
          dyn.viewports[at] = viewport
          if at == 0 { dyn.viewport = viewport }
        }
      case .setScissors(let first, let rs):
        dynVersion &+= 1
        guard target != nil else { throw .invalid("a scissor outside a pass") }
        for (k, r) in rs.enumerated() {
          let at = Int(first) + k
          let box = PipelineMapping.scissorBox(x: Int(r.x), y: Int(r.y), width: Int(r.width), height: Int(r.height),
                                               targetWidth: planSize.width, targetHeight: planSize.height)
          while dyn.scissors.count <= at { dyn.scissors.append(nil) }
          dyn.scissors[at] = box
          if at == 0 { dyn.scissor = box }
        }
      case .setBlendConstants(let k):
        dynVersion &+= 1
        dyn.constants = k
      case .setStencilReference(let faces, let v):
        dynVersion &+= 1
        if faces.rawValue & 1 != 0 { dyn.frontReference = v }
        if faces.rawValue & 2 != 0 { dyn.backReference = v }
      case .setStencilCompareMask(let faces, let v):
        dynVersion &+= 1
        if faces.rawValue & 1 != 0 { dyn.frontCompareMask = v }
        if faces.rawValue & 2 != 0 { dyn.backCompareMask = v }
      case .setStencilWriteMask(let faces, let v):
        dynVersion &+= 1
        if faces.rawValue & 1 != 0 { dyn.frontWriteMask = v }
        if faces.rawValue & 2 != 0 { dyn.backWriteMask = v }
      case .setDepthBias(let c, let clamp, let slope):
        dynVersion &+= 1
        dyn.biasConstant = c
        dyn.biasClamp = clamp
        dyn.biasSlope = slope
      case .setLineWidth(let w):
        dynVersion &+= 1
        dyn.lineWidth = w
      case .draw(let p, let root, let vertices, let instances, let firstVertex, let firstInstance):
        // A draw of too few vertices for its topology, or of no instances, makes no primitive (appendDraw).
        if instances == 0 { break }
        try appendDraw(
          p, root: root, into: &draws, usesHeap: &usesHeap, target: target, vertices: Int(vertices), instances: Int(instances),
          vertexOffset: Int32(truncatingIfNeeded: firstVertex), firstInstance: firstInstance, query: activeQuery, dynamic: dyn, zs: zs)
      case .drawIndexed(let p, let root, let indices, let indexOffset, let type, let count, let instances, let firstIndex,
                        let vertexOffset, let firstInstance):
        if instances == 0 { break }
        let source = try indexSource(indices, indexOffset, type)
        try appendDraw(
          p, root: root, into: &draws, usesHeap: &usesHeap, target: target, vertices: Int(count), instances: Int(instances),
          vertexOffset: vertexOffset, firstInstance: firstInstance, indices: source, firstIndex: firstIndex, query: activeQuery, dynamic: dyn, zs: zs)
      case .drawIndirect(let p, let root, let arguments, let offset, let count, let stride):
        guard let m = memories[arguments.handle] else { throw .invalid("memory that isn't this device's") }
        for i in 0..<Int(count) {
          let at = m.address + UInt64(offset) + UInt64(i) * UInt64(stride)
          try appendDraw(
            p, root: root, into: &draws, usesHeap: &usesHeap, target: target, vertices: 0, instances: 0, vertexOffset: 0,
            firstInstance: 0, indirect: IndirectArguments(address: at), query: activeQuery, dynamic: dyn, zs: zs)
        }
      case .drawIndexedIndirect(let p, let root, let indices, let indexOffset, let type, let arguments, let offset, let count,
                                let stride):
        guard let m = memories[arguments.handle] else { throw .invalid("memory that isn't this device's") }
        let source = try indexSource(indices, indexOffset, type)
        for i in 0..<Int(count) {
          let at = m.address + UInt64(offset) + UInt64(i) * UInt64(stride)
          try appendDraw(
            p, root: root, into: &draws, usesHeap: &usesHeap, target: target, vertices: 0, instances: 0, vertexOffset: 0,
            firstInstance: 0, indices: source, indirect: IndirectArguments(address: at), query: activeQuery, dynamic: dyn, zs: zs)
        }
      case .beginQuery(let set, let index):
        guard target != nil else { throw .invalid("an occlusion query outside a pass") }
        guard activeQuery == 0 else { throw .invalid("an occlusion query begins inside another") }
        guard let q = queries[set.handle] else { throw .invalid("a query set that isn't this device's") }
        // The counter starts at zero (06 section 6.11.1): the pass's fragment queue stores it, then flushes the store.
        activeQuery = q.region.address + UInt64(index * 8)
        if !queryReports.contains(activeQuery) {
          queryReports.append(activeQuery)
          queryCells.append((q, index))
        }
      case .endQuery(let set, let index):
        guard let q = queries[set.handle] else { throw .invalid("a query set that isn't this device's") }
        guard activeQuery == q.region.address + UInt64(index * 8) else { throw .invalid("a query ends that wasn't begun in this pass") }
        activeQuery = 0
      case .writeTimestamp(let set, let index, _):
        // Every step waits for the one before it to finish, so a timestamp is of everything before it, whatever stages it names.
        guard let q = queries[set.handle] else { throw .invalid("a query set that isn't this device's") }
        steps.append(.timestamp(q.region.address + UInt64(index * 8)))
      case .dispatch(let p, let root, let x, let y, let z):
        guard case .compute(let shader, let layout)? = pipelines[p.handle] else {
          throw .invalid("a pipeline that isn't this device's compute pipeline")
        }
        steps.append(.dispatch(shader, layout, root: root, grid: Dim3(x, y, z), indirect: nil))
      case .dispatchIndirect(let p, let root, let arguments, let offset):
        guard case .compute(let shader, let layout)? = pipelines[p.handle] else {
          throw .invalid("a pipeline that isn't this device's compute pipeline")
        }
        guard let m = memories[arguments.handle] else { throw .invalid("memory that isn't this device's") }
        steps.append(.dispatch(shader, layout, root: root, grid: Dim3(1, 1, 1), indirect: m.address + UInt64(offset)))
      case .barrier:
        break  // every step already waits for the one before it
      case .copyBuffer(let from, let fromOffset, let to, let toOffset, let bytes):
        guard let a = memories[from.handle], let b = memories[to.handle] else { throw .invalid("memory that isn't this device's") }
        try transfer(.copyBuffer(a, fromOffset, b, toOffset, bytes))
      case .copyBufferToImage(let m, let offset, let image):
        guard let a = memories[m.handle], let i = images[image.handle] else { throw .invalid("a resource that isn't this device's") }
        try transfer(.bufferToImage(a, i, [wholeLevel(i, offset)]))
      case .copyImageToBuffer(let image, let m, let offset):
        guard let a = memories[m.handle], let i = images[image.handle] else { throw .invalid("a resource that isn't this device's") }
        try transfer(.imageToBuffer(i, a, [wholeLevel(i, offset)]))
      case .copyImage(let src, let dst, let regions):
        guard let a = images[src.handle], let b = images[dst.handle] else { throw .invalid("an image that isn't this device's") }
        try transfer(.copyImage(a, b, regions))
      case .blitImage(let src, let dst, let regions, let filter):
        guard let a = images[src.handle], let b = images[dst.handle] else { throw .invalid("an image that isn't this device's") }
        try transfer(.blit(a, b, regions, filter))
      case .copyBufferToImageRegions(let m, let image, let regions):
        guard let a = memories[m.handle], let i = images[image.handle] else { throw .invalid("a resource that isn't this device's") }
        try transfer(.bufferToImage(a, i, regions))
      case .copyImageToBufferRegions(let image, let m, let regions):
        guard let a = memories[m.handle], let i = images[image.handle] else { throw .invalid("a resource that isn't this device's") }
        try transfer(.imageToBuffer(i, a, regions))
      case .fillBuffer(let m, let offset, let bytes, let value):
        guard let a = memories[m.handle] else { throw .invalid("memory that isn't this device's") }
        try transfer(.fill(a, offset, bytes, value))
      case .updateBuffer(let m, let offset, let data):
        guard let a = memories[m.handle] else { throw .invalid("memory that isn't this device's") }
        try transfer(.update(a, offset, data))
      case .clearColorImage(let image, let color, let ranges):
        guard let i = images[image.handle] else { throw .invalid("an image that isn't this device's") }
        try transfer(.clearColor(i, color, ranges))
      case .resolveImage(let src, let dst, let regions):
        guard let a = images[src.handle], let b = images[dst.handle] else { throw .invalid("an image that isn't this device's") }
        try transfer(.resolve(a, b, regions))
      case .clearDepthStencilImage(let image, let depth, let stencil, let ranges):
        guard let i = images[image.handle] else { throw .invalid("an image that isn't this device's") }
        try transfer(.clearDepthStencil(i, depth, stencil, ranges))
      case .clearAttachments(let attachments, let rects):
        try appendClears(attachments, rects, into: &draws, target: target, zs: zs, view: views.first, layers: viewMask != 0 ? 1 : layers,
                         viewMask: viewMask)
      case .imageBarrier:
        break
      default:
        throw .unsupported("this command (validate keeps the features it needs off)")
      }
    }
    return steps
  }

  /// The region of a plain copy between a buffer and an image: tightly packed texels of the first level and layer, every slice of a volume,
  /// of the colour aspect or the depth.
  func wholeLevel(_ image: ImageRecord, _ offset: Int) -> BufferImageRegion {
    let d = image.descriptor
    return BufferImageRegion(
      bufferOffset: offset, subresource: ImageSubresourceLayers(aspects: d.format.aspects.contains(.color) ? .color : .depth),
      imageExtent: Extent3D(width: UInt32(d.width), height: UInt32(d.height), depth: UInt32(d.dimension == .d3 ? d.depth : 1)))
  }

  /// The index data of a draw: from `offset` in `memory` to its end.
  func indexSource(_ memory: GPUMemory, _ offset: Int, _ type: IndexType) throws(GPUError) -> IndexSource {
    guard let m = memories[memory.handle] else { throw .invalid("memory that isn't this device's") }
    return IndexSource(address: m.address + UInt64(offset), bytes: UInt32(truncatingIfNeeded: memory.size - offset),
                       size: type == .uint16 ? .u16 : .u32)
  }

  /// The copy of sample 0 of a depth and stencil attachment's view into its resolve view (copyImages reads sample 0 at slice 0).
  func zsResolveRegion(_ z: ZSBinding, _ v: ImageView, _ r: ImageView, layers: Int) -> ImageCopyRegion {
    ImageCopyRegion(
      srcSubresource: ImageSubresourceLayers(aspects: z.image.descriptor.format.aspects, mip: v.baseMip, baseLayer: v.baseLayer,
                                             layerCount: UInt32(layers)),
      dstSubresource: ImageSubresourceLayers(aspects: z.image.descriptor.format.aspects, mip: r.baseMip, baseLayer: r.baseLayer,
                                             layerCount: UInt32(layers)),
      extent: Extent3D(width: UInt32(v.width), height: UInt32(v.height)))
  }

  /// One draw of the pass being planned.
  func appendDraw(
    _ p: GPUPipeline, root: UInt64, into draws: inout [PassDraw], usesHeap: inout Bool, target: ImageRecord?, vertices: Int,
    instances: Int, vertexOffset: Int32, firstInstance: UInt32, indices: IndexSource? = nil, firstIndex: UInt32 = 0,
    indirect: IndirectArguments? = nil, query: UInt64, dynamic dyn: DynamicValues, zs: ZSBinding?
  ) throws(GPUError) {
    let t0 = clock()
    defer { lastProfile.drawNanoseconds &+= clock() &- t0 }
    guard let record = target else { throw .invalid("a draw outside a pass") }
    // The draw before's, for a draw of the same pipeline in the same pass with the same dynamic state: its template (shared, not
    // copied) with this draw's counts, offsets and push words. Nothing of the pipeline's record is read again.
    let probing = probeScissorArrayLength != nil || probeScissorMode != 0 || probeViewports != nil || probeScissors != nil
      || probeScissorArrayFill != nil || probeFlags0.or != 0 || probeFlags0.clear != 0
    if !probing, let i = drawCache.firstIndex(where: { $0.pipeline == p.handle && $0.version == dynVersion && $0.pass == planPass }),
      let template = drawCache[i].template
    {
      if indirect == nil && vertices < template.state.minimumVertices { return }
      usesHeap = usesHeap || drawCache[i].heapDraw
      var draw = PassDraw(sharingState: template, vertexCount: vertices, instanceCount: instances,
                          push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)])
      draw.indices = indices
      draw.firstIndex = firstIndex
      draw.vertexOffset = vertexOffset
      draw.firstInstance = firstInstance
      draw.indirect = indirect
      draw.occlusionQuery = query
      draws.append(draw)
      return
    }
    guard case .graphics(let vs, let fs, let format, var blend, let state)? = pipelines[p.handle] else {
      throw .invalid("a pipeline that isn't this device's graphics pipeline")
    }
    guard state.formats.count == planTargets.count else { throw .invalid("a pipeline of \(state.formats.count) colour targets in a pass of \(planTargets.count)") }
    for (i, t) in planTargets.enumerated() where state.formats[i] != t.descriptor.format {
      throw .invalid("a pipeline for \(state.formats[i]) drawing into another format")
    }
    _ = format
    guard state.depthStencilFormat == zs?.image.descriptor.format else {
      throw .invalid("a pipeline for a depth and stencil target of another format than the pass's")
    }
    // Rasterizer discard: nothing is rasterized, and the vertex stage has no output but the position, so there is nothing to run.
    if state.raster.rasterizerDiscard { return }
    _ = record
    // What the draw's pipeline, the pass's dynamic values and its size make (the pipeline state, the blends and their shaders):
    // the last draw's while those are the same, as they are for most draws of a pass.
    let constants = state.dynamic.contains(.blendConstants) ? dyn.constants : state.constants
    let cached = drawCache.first { $0.pipeline == p.handle && $0.version == dynVersion && $0.width == planSize.width
      && $0.height == planSize.height && $0.constants == constants }
    var pipelineState: DrawPipelineState
    var blendShaders: [Int: [UInt64]] = [:]
    var extraBlends: [BlendDescriptor] = []
    if let c = cached {
      pipelineState = c.state
      blend = c.blend
      extraBlends = c.extra
      blendShaders = c.shaders
    } else {
      pipelineState = PipelineMapping.drawState(state, dyn, width: planSize.width, height: planSize.height)
      // The blend of each target with the constants in force (09 section 9.7.1): a target the blender can't do has a blend shader,
      // which the pass's block holds (RenderPass.build), the fragment shader calls, and reads the constants from its FAU.
      let targets = PipelineMapping.blendTargets(state, constants: constants)
      blend = targets[0].descriptor
      extraBlends = targets.dropFirst().map { $0.descriptor }
      for (i, t) in targets.enumerated() {
        guard let spec = t.shader, i == 0 || fs.colourTargets.contains(i) else { continue }
        guard fs.layout.blendConstantWord >= 0 else { throw .invalid("a draw that needs a blend shader of a fragment shader that doesn't call one") }
        blendShaders[i] = try blendShader(spec).code
      }
      if drawCache.count >= 16 { drawCache.removeFirst() }
      drawCache.append(DrawCache(pipeline: p.handle, version: dynVersion, width: planSize.width, height: planSize.height,
                                 constants: constants, state: pipelineState, blend: blend, extra: extraBlends, shaders: blendShaders))
    }
    pipelineState.scissorArrayLength = probeScissorArrayLength
    pipelineState.scissorProbe = probeScissorMode
    if let vs = probeViewports {
      pipelineState.viewports = vs.map { DrawViewport(x: Float($0.0), y: Float($0.1), width: Float($0.2), height: Float($0.3)) }
      pipelineState.viewport = pipelineState.viewports.first ?? nil
    }
    if let ss = probeScissors {
      pipelineState.scissors = ss.map {
        PipelineMapping.scissorBox(x: $0.0, y: $0.1, width: $0.2, height: $0.3, targetWidth: planSize.width, targetHeight: planSize.height)
      }
      pipelineState.scissor = pipelineState.scissors.first ?? nil
    }
    if probeScissorMode == 6 {
      // The array at an address whose bits 31:0 are zero, made once and written for each draw (one draw a pass in the probe).
      if probeArrayRegion == nil {
        let address = try takeAddress(4096, alignment: 1 << 32)
        let buffer = try transport.createBuffer(size: 4096, cpuCached: false)
        try transport.bind(vm: vm, buffer: buffer, address: address, gpuCacheable: false)
        probeArrayRegion = Region(buffer: buffer, address: address, size: buffer.size)
      }
      let r = probeArrayRegion!
      store(ScissorArray(state: pipelineState, width: planSize.width, height: planSize.height).words(), in: r, at: 0)
      pipelineState.scissorArrayAddress = r.address
    }
    pipelineState.scissorArrayFill = probeScissorArrayFill.map { ScissorBox(minX: $0.0, minY: $0.1, maxX: $0.2, maxY: $0.3) }
    // Too few vertices for the topology makes no primitive.
    if indirect == nil && vertices < pipelineState.minimumVertices { return }
    // The fragment or the vertex shader samples the heap (the vertex stage reads the same table, RenderPassDraws).
    let heapDraw = !fs.layout.imageBindings.isEmpty || fs.layout.dummySamplerWord >= 0 || !vs.layout.imageBindings.isEmpty
      || vs.layout.dummySamplerWord >= 0
    usesHeap = usesHeap || heapDraw
    // A binding's element 0: the textures' array is binding 0 and the samplers' binding 1 (Loinnir's, and the one
    // layout of every pipeline).
    // Binding 2 is the storage images' array, table 2 of the resource table, and bindings 3 and 4 the texel buffers', after it in the
    // same table (MaliTexelBuffers.swift): the same handles for every draw, made once.
    let handles = heapDraw ? bindingHandles.heap : bindingHandles.none
    var draw = PassDraw(
      vertexShader: vs, fragmentShader: fs, vertexCount: vertices, instanceCount: instances,
      push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)], blend: blend,
      images: handles,
      dummySampler: heapDraw ? DescriptorHeap.handle(index: Heap.samplerBase) : 0)
    draw.indices = indices
    draw.firstIndex = firstIndex
    draw.vertexOffset = vertexOffset
    draw.firstInstance = firstInstance
    draw.indirect = indirect
    draw.occlusionQuery = query
    draw.extraBlends = extraBlends
    draw.blendShaders = blendShaders
    draw.blendConstants = [constants.red, constants.green, constants.blue, constants.alpha]
    draw.state = pipelineState
    draw.flags0Or = probeFlags0.or
    draw.flags0Clear = probeFlags0.clear
    if !probing, let i = drawCache.firstIndex(where: { $0.pipeline == p.handle && $0.version == dynVersion && $0.width == planSize.width
      && $0.height == planSize.height && $0.constants == constants }) {
      drawCache[i].template = draw
      drawCache[i].pass = planPass
      drawCache[i].heapDraw = heapDraw
    }
    draws.append(draw)
  }

  // MARK: Steps

  /// The streams of a step, laid out in memory, as jobs of the one group's queues.
  func jobs(_ step: Step, chain: StepChain?, held: inout [Region]) throws(GPUError) -> [MaliJob] {
    switch step {
    case .dispatch(let shader, let layout, let root, let grid, let indirect, let heap, let kernel):
      if let k = kernel { transferKernelRan?(k, root, grid, heap) }
      return try dispatchJobs(shader, layout, root: root, grid: grid, indirect: indirect, heap: heap, chain: chain, held: &held)
    case .timestamp(let address):
      return try timestampJobs([address], chain: chain, held: &held)
    case .render(let pass):
      return try renderJobs(pass, chain: chain, held: &held)
    }
  }

  /// Runs `jobs` in `group`, in pieces of as many as the driver takes at once; with a signal, the timeline's when the last is
  /// done, and without one, the CPU waits for them (a step run alone, outside a submission).
  func launch(group: UInt32, jobs given: [MaliJob], signal: UInt64?) throws(GPUError) {
    let t0 = clock()
    var jobs = given
    if probeFlushToken != 0 {
      for i in (probeFlushTokenFirstJob ? 0 : 1)..<max(jobs.count, 1) where i < jobs.count { jobs[i].flush = probeFlushToken }
    }
    if let signal {
      var at = 0
      while at < jobs.count {
        let n = min(jobs.count - at, Self.jobsPerSubmit)
        lastProfile.submits += 1
        try transport.submit(group: group, jobs: Array(jobs[at..<(at + n)]), waits: [],
                             signals: at + n == jobs.count ? [(timeline, signal)] : [])
        at += n
      }
      lastProfile.submitNanoseconds &+= clock() &- t0
      return
    }
    lastProfile.submits += 1
    stepValue += 1
    try transport.submit(group: group, jobs: jobs, waits: [], signals: [(stepSync, stepValue)])
    let t1 = clock()
    lastProfile.submitNanoseconds &+= t1 &- t0
    defer { lastProfile.waitNanoseconds &+= clock() &- t1 }
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

  /// The submission's jobs as one job a queue: a stream that CALLs each of the queue's streams in order (valhall 01 section 1.1.3; the
  /// kernel's wrapper is one frame of the call stack, this a second). A queue runs its jobs in order either way, and every stream
  /// ends by draining its slots; one job saves the driver's ring sequence, its cache flush, its completion and its interrupt for
  /// each of the others. A queue with one job keeps it.
  func oneJobAQueue(_ jobs: [MaliJob], held: inout [Region]) throws(GPUError) -> [MaliJob] {
    var queues: [UInt32] = []
    for j in jobs where !queues.contains(j.queue) { queues.append(j.queue) }
    guard mergesQueueJobs, queues.count < jobs.count else { return jobs }
    let info = transport.info
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    var out: [MaliJob] = []
    for q in queues {
      let mine = jobs.filter { $0.queue == q }
      if mine.count == 1 {
        out.append(mine[0])
        continue
      }
      let bytes = mine.count * 24 + 64
      let region = try scratch(bytes, held: &held)
      var b = CSBuilder(address: region.address, capacityBytes: region.size, registers: registers, scoreboards: scoreboards)
      for j in mine { b.call(address: j.address, size: j.size) }
      let stream: CSStream
      do throws(CSBuildError) { stream = try b.finish() } catch { throw .unsupported("a queue's calling stream refused: \(error)") }
      for (i, w) in stream.words.enumerated() { region.buffer.store(w, at: i * 8) }
      out.append(MaliJob(queue: q, address: stream.address, size: UInt32(stream.size)))
    }
    return out
  }

  /// The jobs the driver takes in one submit (its `maxJobs`).
  static let jobsPerSubmit = 256

  /// A group that faulted is of no more use: its queues are gone and the next pass makes a group of its own, whose
  /// queues start again. The steps it never ran added nothing to the chain, which starts again from the count submitted.
  func dropGroup(_ group: UInt32) {
    guard group == renderGroup else { return }
    transport.destroyGroup(group)
    renderGroup = nil
    renderStarted = false
    computeSlotsReady = false
    computeResourceRequested = false
    chainRegion?.buffer.store(chainValue, at: 0)
    chainQueue = nil
  }

  /// A group that ended, in words (the driver reports the group's state, not the fault's address).
  func faulted(_ state: UInt32) -> GPUError {
    .failed("a pass ended its group (group state \(state), bit 1 is a fatal fault)", code: Int32(truncatingIfNeeded: state))
  }

  /// The timestamps of the system's counter, stored at `addresses` once the compute queue has drained, on the compute
  /// group's queue (a stream of its own: the steps before it have all finished).
  func timestampJobs(_ addresses: [UInt64], chain: StepChain?, held: inout [Region]) throws(GPUError) -> [MaliJob] {
    let info = transport.info
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    let region = try scratch(1024, held: &held)
    let stream: CSStream
    do throws(CSBuildError) {
      stream = try TimestampStream.build(
        at: region.address, capacity: region.size, addresses: addresses, initialiseQueue: !computeSlotsReady,
        registers: registers, scoreboards: scoreboards, chain: chain)
    } catch { throw .unsupported("the timestamp stream refused: \(error)") }
    for (i, w) in stream.words.enumerated() { region.buffer.store(w, at: i * 8) }
    computeSlotsReady = true
    return [MaliJob(queue: Self.computeQueue, address: stream.address, size: UInt32(stream.size))]
  }

  /// Timestamps stored at once, the CPU waiting for them: outside any submission (the calibration's), after every step
  /// submitted before.
  func runTimestamps(_ addresses: [UInt64], held: inout [Region]) throws(GPUError) {
    let chain = chainValue == 0 ? nil : StepChain(address: try chainSync().address, waitAbove: chainValue - 1, signal: false)
    let jobs = try queueStartJobs(held: &held) + timestampJobs(addresses, chain: chain, held: &held)
    try launch(group: try workGroup(), jobs: jobs, signal: nil)
  }

  /// A dispatch; with `heap`, a transfer kernel's own heap (Transfers.swift): its samplers from entry 0 (binding 1), its textures
  /// from entry 2 (every other binding), in place of the device's heap.
  func dispatchJobs(_ shader: ComputeShader, _ layout: FauLayout, root: UInt64, grid: Dim3, indirect: UInt64? = nil,
                    heap own: (address: UInt64, bytes: Int)? = nil, chain: StepChain?, held: inout [Region]) throws(GPUError) -> [MaliJob] {
    let info = transport.info
    var threadStorage: UInt64 = 0
    var workgroupMemory: UInt64 = 0
    if let limits = computeLimits {
      let sizing = ComputeSizing.of(shader: shader, grid: indirect == nil ? grid : nil, limits: limits)
      if shader.stackBytes != 0 {
        threadStorage = try stepStorage(Int(sizing.tlsBytes), workgroup: false, held: &held)
      }
      if shader.workgroupMemoryBytes != 0 {
        workgroupMemory = try stepStorage(Int(sizing.wlsBytes), workgroup: true, held: &held)
      }
    }
    // The storage images' element 0 is table 2's, the textures' and the samplers' the heap's (binding 0 and 1 of set 0, as the
    // fragment stage names them).
    let ownHeap = own != nil
    let fau = layout.block(address: { _, _ in 0 }, size: { _, _ in 0 },
                           push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)],
                           workgroups: (grid.x, grid.y, grid.z),
                           imageHandle: { _, binding in
                             if ownHeap { return DescriptorHeap.handle(index: binding == 1 ? 0 : 2) }
                             if binding == 0 { return DescriptorHeap.handle(index: Heap.textureBase) }
                             if binding == 1 { return DescriptorHeap.handle(index: Heap.samplerBase) }
                             let base = binding == 3 ? Heap.texelBufferBase : binding == 4 ? Heap.storageTexelBufferBase : Heap.storageBase
                             return ResourceTable.handle(table: DescriptorHeap.storageTableNumber, index: base)
                           },
                           dummySampler: DescriptorHeap.handle(index: ownHeap ? 0 : Heap.samplerBase))
    var request = ComputeDispatchRequest(
      shader: shader, grid: grid, fau: fau, threadStorage: threadStorage, workgroupMemory: workgroupMemory,
      limits: computeLimits, requestComputeResource: !computeResourceRequested, initialiseQueue: !computeSlotsReady)
    if let own {
      request.heapTable = (own.address, own.bytes)
    } else if layout.imageBindings.contains(where: { $0.binding >= 2 }) {
      // The storage images' descriptors as they stand now: table 2 of the dispatch's resource table.
      let s = try snapshotStorage(held: &held)
      request.storageTable = (s.region.address, s.bytes)
    }
    if !ownHeap && (layout.imageBindings.contains(where: { $0.binding < 2 }) || layout.dummySamplerWord >= 0) {
      // The textures and samplers as they stand now: table 1.
      let heap = try snapshotHeap(held: &held)
      request.heapTable = (heap.address, (samplerWords.count + textureWords.count) * 4)
    }
    request.indirectGrid = indirect
    request.numWorkgroupsWord = layout.numWorkgroupsWord
    request.chain = chain
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    var capacity = shader.code.count * 8 + 8192
    var region = try scratch(capacity, held: &held)
    var image: ComputeDispatchImage?
    var attempts = 0
    while image == nil {
      do throws(DispatchError) {
        image = try ComputeDispatch.build(at: region.address, capacity: region.size, request: request, registers: registers,
                                         scoreboards: scoreboards, arch: info.arch)
      } catch {
        if case .noRoom(let needed, _) = error, attempts == 0 {
          attempts += 1
          capacity = needed
          region = try scratch(capacity, held: &held)
          continue
        }
        throw .unsupported("the dispatch recipe refused it: \(error)")
      }
    }
    guard let built = image else { throw .invalid("no dispatch") }
    put(built.memory, into: region)
    trimTransient(region, used: built.memory.count)
    computeSlotsReady = true
    computeResourceRequested = true
    return [MaliJob(queue: Self.computeQueue, address: built.stream.address, size: UInt32(built.stream.size))]
  }

  /// The pre-frame shader that loads `target`: the shader (compiled once), and a heap of its own made for this pass: the
  /// nearest sampler (entry 0) and the target as a texture (entry 1), whose plane descriptor follows at 64 bytes.
  func preload(of target: ImageRecord, view: ImageView, layers: Int, held: inout [Region]) throws(GPUError) -> FramePreload {
    // A multisampled target is loaded a sample at a time (08 section 8.10.4: the sample index, per-sample shading).
    let shader = try frameShader(target.descriptor.samples > 1 ? MaliShaders.preloadMSFrag : MaliShaders.preloadFrag,
                                 key: target.descriptor.samples > 1 ? 1 : 0)
    guard let texel = target.descriptor.format.texelFormat else { throw .unsupported("loading an image of \(target.descriptor.format)") }
    let region = try frameHeap(target.layout, plane: 0, view: view, layers: layers, held: &held)
    _ = texel
    return FramePreload(
      shader: shader, heapAddress: region.address, heapBytes: 64,
      images: [
        BindingHandle(set: 0, binding: 0, handle: DescriptorHeap.handle(index: 1)),
        BindingHandle(set: 0, binding: 1, handle: DescriptorHeap.handle(index: 0)),
      ], dummySampler: DescriptorHeap.handle(index: 0), isSRGB: target.descriptor.format == .bgra8srgb)
  }

  /// A frame shader's heap, for this pass: the nearest sampler (entry 0) and, as a 2D array texture (entry 1), the `layers` layers
  /// of the view's level of a plane whose layout is `layout`, `plane` bytes into the view's image's region; their plane descriptors follow at
  /// 64 bytes. The shaders read the layer they run for (its frame argument, 08 section 8.12) and the sample (05 section 5.9.1).
  func frameHeap(_ layout: ImageLayout, plane: Int, view: ImageView, layers: Int, held: inout [Region]) throws(GPUError) -> Region {
    let record = self.images[view.image.handle]
    guard let owner = record else { throw .invalid("an image that isn't this device's") }
    let planeAt = 64
    let mip = Int(view.baseMip)
    let base = Int(view.baseLayer)
    let region = try scratch(planeAt + PlaneDescriptor.size * layers, held: &held)
    do throws(DescriptorError) {
      var at = planeAt
      for p in layout.planes(base: owner.region.address + UInt64(plane), levels: mip..<(mip + 1), layers: base..<(base + layers)) {
        store(try p.words(), in: region, at: at)
        at += PlaneDescriptor.size
      }
      let sampler = try SamplerWords(wrapS: .clampToEdge, wrapT: .clampToEdge, wrapR: .clampToEdge, minFilter: .nearest,
                                     magFilter: .nearest).words()
      store(sampler, in: region, at: 0)
      let level = layout.levels[mip]
      let texture = try TextureDescriptor(
        format: layout.format, width: level.width, height: level.height, layout: layout.kind, layers: layers,
        sampleCountLog2: UInt32(layout.samples.trailingZeroBitCount), surfaces: region.address + UInt64(planeAt)).words()
      store(texture, in: region, at: 32)
    } catch { throw .unsupported("the texture unit can't describe the attachment to load") }
    return region
  }

  /// A frame shader of MaliShaders, compiled at first use and kept under `key`.
  func frameShader(_ code: [UInt8], key: Int) throws(GPUError) -> FragmentShader {
    if let s = frameShaders[key] { return s }
    guard let fs = try compile(code).fragment else { throw .invalid("a frame shader's module has no fragment shader") }
    frameShaders[key] = fs
    return fs
  }

  /// The second pre-frame shader that loads a depth or a stencil plane (08 section 8.2.1.1): the shader (compiled once) and a heap
  /// of its own for this pass, as `preload`'s: the nearest sampler (entry 0) and the plane as a texture (entry 1).
  func zsPreload(of image: ImageRecord, view: ImageView, layers: Int, stencil: Bool, held: inout [Region]) throws(GPUError) -> FramePreload {
    let ms = image.descriptor.samples > 1
    let code = stencil ? (ms ? MaliShaders.preloadStencilMSFrag : MaliShaders.preloadStencilFrag)
      : (ms ? MaliShaders.preloadDepthMSFrag : MaliShaders.preloadDepthFrag)
    let shader = try frameShader(code, key: (stencil ? 4 : 2) + (ms ? 1 : 0))
    guard let plane = image.planes.first(where: { $0.aspect == (stencil ? ImageAspects.stencil : .depth) }) ?? image.planes.first else {
      throw .unsupported("loading an image with no plane")
    }
    let region = try frameHeap(plane.layout, plane: plane.offset, view: view, layers: layers, held: &held)
    return FramePreload(
      shader: shader, heapAddress: region.address, heapBytes: 64,
      images: [
        BindingHandle(set: 0, binding: 0, handle: DescriptorHeap.handle(index: 1)),
        BindingHandle(set: 0, binding: 1, handle: DescriptorHeap.handle(index: 0)),
      ], dummySampler: DescriptorHeap.handle(index: 0))
  }

  /// Where a view of an image is drawn: the first layer's level of the plane of `aspect`, its rows, the distance between its samples'
  /// surfaces and between its layers, and the level's size.
  func placement(_ image: ImageRecord, _ view: ImageView, aspect: ImageAspects = .color)
    -> (address: UInt64, rowStride: Int, surfaceStride: Int, layerStride: Int, width: Int, height: Int)
  {
    let plane = image.planes.first(where: { $0.aspect == aspect }) ?? image.planes.first
    let layout = plane?.layout ?? image.layout
    let level = layout.levels[min(Int(view.baseMip), layout.levels.count - 1)]
    let offset = (plane?.offset ?? 0) + Int(view.baseLayer) * layout.arrayStride + level.offset
    // An AFBC plane's "surface stride" slot is its body's offset from the header area (valhall 08 sections 8.4.4 and 8.5.1).
    let surface = layout.kind == .afbc ? level.bodyOffset : level.surfaceStride
    return (image.region.address + UInt64(offset), level.rowStride, surface, layout.arrayStride, level.width, level.height)
  }

  func renderJobs(_ pass: DrawPass, chain: StepChain?, held: inout [Region]) throws(GPUError) -> [MaliJob] {
    let info = transport.info
    let target = pass.target
    // Each attachment is its view: the first layer's level of its plane, drawn at the level's size (valhall 08 section 8.4.4: a
    // descriptor names one layer of one level; a pass of layers has a group each, the layer stride apart).
    let main = placement(target, pass.views[0])
    let width = main.width, height = main.height
    // The device's one tiler heap: the context, the first chunk and the geometry buffer are made once and every pass
    // uses them (the kernel's heap is a group's too), so a later pass never names memory an earlier one let go.
    let tiler = try tilerMemory()
    let chunkBytes = Self.tilerChunkBytes
    var request = DrawPassRequest(
      width: width, height: height, format: target.descriptor.format.colourFormat, colourAddress: main.address,
      clear: pass.clear, draws: pass.draws, heapContext: tiler.context.address, heapChunk: tiler.chunk.address,
      heapChunkBytes: chunkBytes, geometryBuffer: tiler.geometry.address, layout: singleQueuePasses ? .singleQueue : .splitQueues, initialiseQueues: !renderStarted)
    // The target's own rows: packed for a window's image, LinearLayout's for any other.
    request.rowStride = main.rowStride
    request.colourSurfaceStride = main.surfaceStride
    request.colourLayerStride = main.layerStride
    request.layers = pass.layers
    request.viewMask = pass.viewMask
    request.finishLastContextOnly = probeFinishLastContextOnly
    if probePassStamps { request.stamps = try chainSync().address + UInt64(Self.stampsOffset) }
    // Multisampled (valhall 08 section 8.3): the tile holds every sample; a stored target writes each to its surface (Layered),
    // a resolved one the mean to the resolve image (Average), and one both stored and resolved gets a second descriptor over the
    // same tile for the mean.
    request.samples = pass.samples
    var targets: [ExtraColourTarget] = []
    for (i, image) in ([target] + pass.extra.map { $0.image }).enumerated() {
      let at = placement(image, pass.views[i])
      var t = ExtraColourTarget(format: image.descriptor.format.colourFormat, address: at.address, clear: i == 0 ? pass.clear : pass.extra[i - 1].clear,
                                rowStride: at.rowStride)
      t.surfaceStride = at.surfaceStride
      t.layerStride = at.layerStride
      t.blockFormat = image.layout.kind.blockFormat
      if pass.samples > 1 {
        t.msaa = 3
        if let v = pass.resolves.first(where: { $0.of == i }) {
          let r = placement(v.image, v.view)
          var resolve = ExtraColourTarget(format: v.image.descriptor.format.colourFormat, address: r.address, clear: t.clear,
                                          rowStride: r.rowStride)
          resolve.surfaceStride = r.surfaceStride
          resolve.layerStride = r.layerStride
          resolve.blockFormat = v.image.layout.kind.blockFormat
          if i < pass.stores.count && pass.stores[i] {
            request.resolves.append((i, resolve))
          } else {
            resolve.msaa = 1
            t = resolve
          }
        }
      }
      targets.append(t)
    }
    request.colourMSAA = targets[0].msaa
    request.colourBlockFormat = targets[0].blockFormat
    request.colourAddress = targets[0].address
    request.rowStride = targets[0].rowStride
    request.colourSurfaceStride = targets[0].surfaceStride
    request.colourLayerStride = targets[0].layerStride
    request.extraTargets = Array(targets.dropFirst())
    // Transaction elimination (valhall 08 section 8.6) for target 0 where the pass covers its level 0 whole, one layer, one sample:
    // a tile whose checksum matches the one stored is not written back. Any other pass that writes a target with a table changes
    // its bytes behind it, and invalidates it.
    let v0 = pass.views[0]
    if let c = target.crc, pass.samples == 1, pass.layers == 1, pass.viewMask == 0, v0.baseMip == 0, v0.baseLayer == 0,
      width == Int(target.descriptor.width), height == Int(target.descriptor.height), pass.resolves.isEmpty {
      request.crc = CRCTable(address: c.region.address, rowStride: c.rowStride, counter: target.crcCounter)
    } else {
      target.invalidateCRC()
    }
    for e in pass.extra { e.image.invalidateCRC() }
    for r in pass.resolves { r.image.invalidateCRC() }
    request.queryReports = probeSkipQueryZero ? [] : pass.queries
    if probeQueryReadback && !pass.queries.isEmpty {
      let r = try makeRegion(4096)
      if let old = queryReadbackRegion { retire([old]) }
      request.queryReadback = r.address
      queryReadbackRegion = r
    }
    // Stack and spills of any shader live in thread storage the pass's TSD names.
    let stack = request.stackBytes
    if stack != 0 {
      guard let limits = computeLimits else { throw .unsupported("a shader with a stack: the driver reports no thread limits") }
      request.threadStorage = try stepStorage(Int(ThreadStorageSizing.tlsTotal(stackBytes: stack, limits: limits)), workgroup: false, held: &held)
      request.limits = limits
    }
    if let z = pass.zs, let view = pass.zsView {
      let f = z.image.descriptor.format
      // A depth and stencil format is two planes, the depth's (D24X8 or D32) and the stencil's (S8): valhall 08 section 8.5.1.
      let depthFormat: DepthFormat? = switch f {
      case .depth16: .d16
      case .depth24stencil8: .d24
      case .depth32f, .depth32fstencil8: .d32f
      default: nil
      }
      var target = ZSTarget(depthFormat: depthFormat, hasStencil: f.hasStencil)
      // A plane not stored but resolved writes its sample 0 into the resolve image (writeback Single, 08 section 8.3.2).
      let resolveOnly = z.resolve != nil && !z.storeDepth && !z.storeStencil
      let planeImage = resolveOnly ? z.resolve!.image : z.image
      let planeView = resolveOnly ? z.resolve!.view : view
      if (z.storeDepth || resolveOnly) && f.hasDepth {
        let at = placement(planeImage, planeView, aspect: .depth)
        target.depthAddress = at.address
        target.depthRowStride = at.rowStride
        target.depthSurfaceStride = at.surfaceStride
        target.depthLayerStride = at.layerStride
        target.depthAFBC = planeImage.planes.first(where: { $0.aspect == .depth })?.layout.kind == .afbc
      }
      if (z.storeStencil || resolveOnly) && f.hasStencil {
        let at = placement(planeImage, planeView, aspect: .stencil)
        target.stencilAddress = at.address
        target.stencilRowStride = at.rowStride
        target.stencilSurfaceStride = at.surfaceStride
        target.stencilLayerStride = at.layerStride
      }
      target.clearDepth = z.clearDepth
      target.clearStencil = z.clearStencil
      // Every sample of a multisampled plane to its surface (08 section 8.5.1: depth is never averaged).
      if pass.samples > 1 && !resolveOnly {
        target.depthMSAA = 3
        target.stencilMSAA = 3
      }
      request.zs = target
    }
    if pass.load { request.preload = try preload(of: target, view: pass.views[0], layers: pass.layers, held: &held) }
    if let z = pass.zs, let view = pass.zsView, z.loadDepth || z.loadStencil {
      request.zsPreload = try zsPreload(of: z.image, view: view, layers: pass.layers, stencil: z.loadStencil, held: &held)
    }
    if pass.usesStorage {
      let s = try snapshotStorage(held: &held)
      request.storageAddress = s.region.address
      request.storageBytes = s.bytes
    }
    if pass.usesHeap {
      let heap = try snapshotHeap(held: &held)
      request.heapAddress = heap.address
      request.heapBytes = (samplerWords.count + textureWords.count) * 4
    }
    let registers = CSRegisterMap(workRegisters: info.workRegisters, unpreserved: info.unpreservedRegisters)
    let scoreboards = CSScoreboards(count: info.scoreboards)
    // Each distinct program is laid out once (RenderPass.build), so the block's room is for those: a pass of hundreds of draws of a
    // few pipelines needs room for a few.
    var codeWords = 0
    var programs: [[UInt64]] = []
    func count(_ code: [UInt64], extra: Int = 0) {
      if programs.contains(where: { $0 == code }) { return }
      programs.append(code)
      codeWords += code.count + extra
    }
    for d in pass.draws {
      count(d.vertexShader.code)
      count(d.fragmentShader.code)
      for (_, code) in d.blendShaders { count(code, extra: 16) }
    }
    request.chain = chain
    request.sampleTable = try sampleTable().address
    // The pass's block is within one 4 GiB window (the arena's are): a blend shader's address is 32 bits and the fragment shader
    // jumps to it (09 section 9.9.1). What a draw takes is a few hundred bytes; a pass that needs more is laid out again.
    var capacity = codeWords * 8 + 32768 + 2048 * pass.draws.count
    var region = try scratch(capacity, held: &held)
    var image: RenderPassImage?
    var attempts = 0
    while image == nil {
      do throws(RenderError) {
        let t0 = clock()
        defer { lastProfile.recipeNanoseconds &+= clock() &- t0 }
        let made = try RenderPass.build(at: region.address, capacity: region.size, request: request, registers: registers,
                                        scoreboards: scoreboards, arch: info.arch)
        image = made.image
        if probeScissorMode != 0 {
          probeLastDraws = made.records.map { d in
            [("scissor", d.state.scissorArray ?? 0), ("tiler", d.state.tilerContext), ("zsd", d.state.depthStencil), ("blend", d.blend),
             ("vfau", d.vertexFAU), ("ffau", d.fragmentFAU), ("vspd", d.vertexSPD), ("fspd", d.fragmentSPD), ("vtsd", d.state.vertexTSD),
             ("fsrt", d.state.fragmentSRT), ("index", d.state.indexBuffer)]
          }
        }
      } catch {
        if case .noRoom(let needed, _) = error, attempts == 0 {
          attempts += 1
          capacity = needed
          region = try scratch(capacity, held: &held)
          continue
        }
        throw .unsupported("the render pass recipe refused it: \(error)")
      }
    }
    guard let built = image else { throw .invalid("no render pass") }
    let t1 = clock()
    put(built.memory, into: region)
    lastProfile.copyNanoseconds &+= clock() &- t1
    trimTransient(region, used: built.memory.count)
    var jobs: [MaliJob] = []
    probeLastPass = (region.address, region.size, built.streams.map { ($0.address, $0.size) })
    for (queue, s) in built.streams.enumerated() {
      jobs.append(MaliJob(queue: Self.tilerQueue + UInt32(queue), address: s.address, size: UInt32(s.size)))
    }
    renderStarted = true
    return jobs
  }
}
