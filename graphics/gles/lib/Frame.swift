// SPDX-License-Identifier: BSD-3-Clause

// The frame (gles(3), "Frames"): what a device's contexts record into and how it reaches the GPU.
//  - One open command list, into which every draw, clear and upload goes in GL's order, and one open render pass in it.
//    A pass ends only where it must: a framebuffer change, an upload or a copy into something it reads or draws, a
//    ReadPixels, a Flush, a Finish or a swap.
//  - The list is submitted at Flush, Finish, a swap and ReadPixels, signalling the next value of the device's timeline;
//    Finish waits for it.
//  - The upload ring: chunks of `.upload` memory that per-draw data (root blocks, set records, uniform blocks, client
//    arrays, constant attributes, converted indices) and uploads are written into, each chunk given back once the
//    timeline passes the last submission that read it.
//  - The heap's slots: a texture image's slot is its own while it lives; samplers are kept by their state, one slot for
//    each distinct sampler (a device has as few as 16), a slot rewritten only when nothing in the open list reads it.
//  - What the open list reads is never freed under it: a device resource let go of while the list is open is freed
//    after the list's submission (and the device keeps it until the GPU is past that).

import GPUCore


/// Bytes of the upload ring: the memory they are in, where in it, and the CPU's pointer to them.
@safe struct Upload {
  var memory: GPUMemory
  var offset: Int
  var pointer: UnsafeMutableRawPointer
  @unsafe init(memory: GPUMemory, offset: Int, pointer: UnsafeMutableRawPointer) {
    self.memory = memory
    self.offset = offset
    unsafe self.pointer = pointer
  }
  var address: UInt64 { memory.address + UInt64(offset) }
}

final class UploadRing {
  struct Chunk {
    var memory: GPUMemory
    /// The last submission that read it.
    var tag: UInt64 = 0
    /// Something in the open list reads it.
    var open = false
  }
  let device: any GPUDevice
  let chunkBytes: Int
  var current: Chunk?
  var offset = 0
  var retired: [Chunk] = []
  var spare: [Chunk] = []
  /// Memory of its own for one allocation larger than a chunk, freed after the submission that reads it.
  var oneOffs: [GPUMemory] = []
  /// Counts chunks taken back into use: an address kept from before (a program's uniform block) is good while this is
  /// the same.
  var recycles: UInt64 = 1

  init(device: any GPUDevice, chunkBytes: Int = 4 << 20) {
    self.device = device
    self.chunkBytes = chunkBytes
  }

  /// `bytes` of upload memory at an `alignment` (16 unless said).
  func allocate(_ bytes: Int, alignment: Int = 16) throws(GPUError) -> Upload {
    if bytes > chunkBytes / 4 {
      let m = try device.allocate(.upload, bytes: bytes)
      oneOffs.append(m)
      guard let p = unsafe m.pointer else { throw .invalid("upload memory with no CPU pointer") }
      return unsafe Upload(memory: m, offset: 0, pointer: p)
    }
    if current == nil || align(offset, alignment) + bytes > chunkBytes { try nextChunk() }
    offset = align(offset, alignment)
    let at = offset
    offset += bytes
    current!.open = true
    guard let p = unsafe current!.memory.pointer else { throw .invalid("upload memory with no CPU pointer") }
    return unsafe Upload(memory: current!.memory, offset: at, pointer: p + at)
  }

  private func nextChunk() throws(GPUError) {
    if let c = current { retired.append(c) }
    reclaim()
    if let c = spare.popLast() {
      current = c
      recycles &+= 1
    } else {
      current = Chunk(memory: try device.allocate(.upload, bytes: chunkBytes))
    }
    offset = 0
  }

  /// The open list was submitted as `value`: what it read is that submission's.
  func submitted(_ value: UInt64) {
    if current?.open == true {
      current!.tag = value
      current!.open = false
    }
    for i in retired.indices where retired[i].open {
      retired[i].tag = value
      retired[i].open = false
    }
    for m in oneOffs { device.free(m) }
    oneOffs = []
  }

  /// Takes back the chunks the GPU is past.
  func reclaim() {
    let done = device.completed
    var keep: [Chunk] = []
    for c in retired {
      if !c.open && c.tag <= done { spare.append(c) } else { keep.append(c) }
    }
    retired = keep
  }

  deinit {
    if let c = current { device.free(c.memory) }
    for c in retired + spare { device.free(c.memory) }
    for m in oneOffs { device.free(m) }
  }
}

/// The heap's texture and sampler slots, as the library hands them out.
final class HeapSlots {
  let device: any GPUDevice
  let limits: DeviceLimits
  private var nextTexture: UInt32 = 0
  private var freeTextures: [UInt32] = []
  /// Slots let go of while the open list may read them: free after its submission.
  private var releasing: [UInt32] = []
  struct SamplerEntry {
    var descriptor: SamplerDescriptor
    var generation: UInt64
    /// The open list's epoch that last read it.
    var openUse: UInt64
  }
  var samplers: [SamplerEntry] = []
  private var generations: UInt64 = 0
  /// Sampler slots written, for the stats.
  var writes = 0

  init(device: any GPUDevice, limits: DeviceLimits) {
    self.device = device
    self.limits = limits
  }

  func takeTextureSlot() throws(GPUError) -> UInt32 {
    if let s = freeTextures.popLast() { return s }
    guard nextTexture < limits.heapTextures else { throw .outOfMemory("the heap's \(limits.heapTextures) texture slots") }
    defer { nextTexture += 1 }
    return nextTexture
  }

  func releaseTextureSlot(_ s: UInt32) { releasing.append(s) }

  func submitted() {
    freeTextures += releasing
    releasing = []
  }

  /// The slot of a sampler of `d` for the open list of `epoch`: one there is, or one written now; nil when every slot is
  /// read by the open list (the caller submits it and asks again).
  func samplerSlot(_ d: SamplerDescriptor, epoch: UInt64) throws(GPUError) -> (slot: UInt32, generation: UInt64)? {
    for i in samplers.indices where samplers[i].descriptor == d {
      samplers[i].openUse = epoch
      return (UInt32(i), samplers[i].generation)
    }
    generations &+= 1
    if samplers.count < Int(limits.heapSamplers) {
      try device.writeSampler(UInt32(samplers.count), d)
      writes += 1
      samplers.append(SamplerEntry(descriptor: d, generation: generations, openUse: epoch))
      return (UInt32(samplers.count - 1), generations)
    }
    // The one the open list doesn't read that was read longest ago.
    var pick = -1
    for i in samplers.indices where samplers[i].openUse != epoch {
      if pick < 0 || samplers[i].openUse < samplers[pick].openUse { pick = i }
    }
    guard pick >= 0 else { return nil }
    try device.writeSampler(UInt32(pick), d)
    writes += 1
    samplers[pick] = SamplerEntry(descriptor: d, generation: generations, openUse: epoch)
    return (UInt32(pick), generations)
  }

  /// Whether slot `s` still holds generation `g`, and if it does, marks it read by the open list.
  func samplerValid(_ s: UInt32, _ g: UInt64, epoch: UInt64) -> Bool {
    guard Int(s) < samplers.count, samplers[Int(s)].generation == g else { return false }
    samplers[Int(s)].openUse = epoch
    return true
  }
}

/// What a pass draws into: its attachments, and how GL's framebuffer maps onto them.
struct RenderTarget: Equatable {
  var color: ImageView?
  var depthStencil: ImageView?
  var colorFormat: PixelFormat?
  var depthStencilFormat: PixelFormat?
  var hasDepth = false
  var hasStencil = false
  var width: Int32 = 0
  var height: Int32 = 0
  /// The depth and stencil image is a texture's, which a shader may read: what it holds is always stored.
  var depthSampled = false
  /// The colour attachment a pass has where GL's framebuffer has none: drawn into with nothing written, never stored.
  var scratch: ImageView?
  /// A window's image, whose first row is the top: drawn with the viewport flipped.
  var flipped = false
  /// The colour attachment has alpha; without, alpha isn't written and reads 1.
  var colorAlpha = true
  /// The bits GL reports.
  var redBits: GLint = 8, greenBits: GLint = 8, blueBits: GLint = 8, alphaBits: GLint = 8
  var depthBits: GLint = 0, stencilBits: GLint = 0

  /// A number for the target as the context last found it (0: none): two targets of one number are one.
  var id: UInt64 = 0

  static func == (a: RenderTarget, b: RenderTarget) -> Bool {
    if a.id != 0 && a.id == b.id { return true }
    return a.color == b.color && a.depthStencil == b.depthStencil && a.flipped == b.flipped
  }
}

/// A clear waiting for the pass it begins.
struct PendingClear {
  var color: (Float, Float, Float, Float)?
  var depth: Float?
  var stencil: UInt32?
}

/// The open pass, and the state it was last told. A pass is opened by the first clear or draw of a target, and its
/// begin is recorded at its first draw: until then a clear only changes what it loads.
final class OpenPass {
  var target: RenderTarget
  init(target: RenderTarget, reads: [UInt64] = []) {
    self.target = target
    self.reads = reads
  }
  var begun = false
  var clear = PendingClear()
  /// The pass's attachments and loads, as begun; its stores are decided as it ends.
  var info = RenderingInfo(colors: [])
  var discardColor = false
  var discardDepth = false
  var discardStencil = false
  /// What its draws and clears used of the attachments: one they didn't is neither loaded nor stored.
  var usedColor = false
  var usedDepth = false
  var usedStencil = false
  var draws = 0
  /// Images its draws read.
  var reads: [UInt64] = []
  // Dynamic state as recorded in the pass (nil: not yet).
  var viewport: Viewport?
  var scissor: RenderArea?
  var stencilReference: (UInt32, UInt32)?
  var stencilCompare: (UInt32, UInt32)?
  var stencilWrite: (UInt32, UInt32)?
  var depthBias: (Float, Float)?
  var blendConstants: BlendConstants?
  var lineWidth: Float?
}

/// A device's frame: shared by the contexts of a display, which use it one at a time.
final class Frame {
  let device: any GPUDevice
  /// The device's limits, read once: the device's getter makes a copy of them at every call.
  let limits: DeviceLimits
  let ring: UploadRing
  let heap: HeapSlots
  var list = GPUCommandList()
  /// The open list's number: what has `openUse == epoch` is read by it.
  var epoch: UInt64 = 1
  var pass: OpenPass?
  /// The last timeline value submitted. The frame is the only one submitting on its device: each submission is the next
  /// value from `valueBase`, so an epoch's value is known before it is submitted.
  var lastSubmitted: UInt64
  let valueBase: UInt64
  /// Device resources to free once the open list is submitted.
  private var releaseImages: [GPUImage] = []
  private var releaseMemory: [GPUMemory] = []
  private var releasePipelines: [GPUPipeline] = []
  /// Memory a buffer moved off, with the bytes it was for, each free once the GPU passes the value.
  var spareBuffers: [(memory: GPUMemory, bytes: Int, readyAt: UInt64)] = []
  /// A texture slot of a 1 by 1 image of (0, 0, 0, 1): what an incomplete texture reads.
  var blackTexture: (image: GPUImage, slot: UInt32)?
  var blackCube: (image: GPUImage, slot: UInt32)?
  /// The draws and passes submitted, for the budgets and the tests.
  var drawsSubmitted = 0
  var passesSubmitted = 0
  var submissions = 0
  var stats = FrameStats()
  /// Called when the list is submitted, with its value (a window's present waits for it).
  var onSubmit: ((UInt64) -> Void)?

  init(device: any GPUDevice) {
    self.device = device
    limits = device.limits
    ring = UploadRing(device: device)
    heap = HeapSlots(device: device, limits: limits)
    // The first epoch is 1.
    valueBase = device.completed
    lastSubmitted = device.completed
  }

  deinit {
    _ = try? submit()
    try? device.wait(lastSubmitted)
    for b in spareBuffers { device.free(b.memory) }
    if let b = blackTexture { device.destroy(b.image) }
    if let b = blackCube { device.destroy(b.image) }
    for s in scratchImages { device.destroy(s.image) }
  }

  func release(_ image: GPUImage) { releaseImages.append(image) }
  func release(_ memory: GPUMemory) { releaseMemory.append(memory) }
  func release(_ pipeline: GPUPipeline) { releasePipelines.append(pipeline) }

  /// Ends the open pass, if there is one: a pass that drew nothing is recorded only if it clears.
  func endPass() {
    guard var p = pass else { return }
    if !p.begun {
      guard p.clear.color != nil || p.clear.depth != nil || p.clear.stencil != nil else {
        pass = nil
        return
      }
      begin()
      p = pass!
    }
    // The begin, now that what the pass stores is known (glDiscardFramebufferEXT, a swap), then what the pass recorded.
    var info = p.info
    if p.discardColor { for i in info.colors.indices { info.colors[i].store = .discard } }
    if p.discardDepth { info.depthStencil?.depthStore = .discard }
    if p.discardStencil { info.depthStencil?.stencilStore = .discard }
    settleDepthStencil(&info, p)
    // A colour attachment no draw wrote, and no clear: what it holds stays, neither loaded nor stored.
    if !p.usedColor, p.target.color != nil {
      for i in info.colors.indices where info.colors[i].load == .load {
        info.colors[i].load = .dontCare
        info.colors[i].store = .discard
      }
    }
    list.beginRendering(info)
    list.append(contentsOf: passList)
    passList = GPUCommandList()
    list.endRendering()
    passesSubmitted += 1
    stats.passes += 1
    pass = nil
  }

  /// Clears of a depth and stencil image (a renderbuffer's or a surface's, which no shader reads) that no pass has stored
  /// yet: the pass that next uses it clears it as it begins, in place of loading it.
  var pendingClears: [(image: UInt64, depth: Float?, stencil: UInt32?)] = []

  /// Settles the pass's depth and stencil loads and stores by what its draws used: an aspect no draw used isn't loaded or
  /// stored (the image keeps what it held), and a clear of it is kept to be the load of the next pass that uses it.
  func settleDepthStencil(_ info: inout RenderingInfo, _ p: OpenPass) {
    guard var ds = info.depthStencil, !p.target.depthSampled else { return }
    let h = ds.view.image.handle
    var pending: (image: UInt64, depth: Float?, stencil: UInt32?) = pendingClears.first { $0.image == h } ?? (h, nil, nil)
    // Depth.
    if ds.view.image.format.hasDepth {
      if !p.usedDepth {
        if ds.depthLoad == .clear { pending.depth = ds.clearDepth }
        ds.depthLoad = .dontCare
        ds.depthStore = .discard
      } else {
        if ds.depthLoad == .load, let d = pending.depth {
          ds.depthLoad = .clear
          ds.clearDepth = d
        }
        if ds.depthStore == .store || ds.depthLoad != .load { pending.depth = nil }
      }
    }
    if ds.view.image.format.hasStencil {
      if !p.usedStencil {
        if ds.stencilLoad == .clear { pending.stencil = ds.clearStencil }
        ds.stencilLoad = .dontCare
        ds.stencilStore = .discard
      } else {
        if ds.stencilLoad == .load, let s = pending.stencil {
          ds.stencilLoad = .clear
          ds.clearStencil = s
        }
        if ds.stencilStore == .store || ds.stencilLoad != .load { pending.stencil = nil }
      }
    }
    pendingClears.removeAll { $0.image == h }
    if pending.depth != nil || pending.stencil != nil { pendingClears.append(pending) }
    info.depthStencil = ds
  }

  /// The open pass's commands, recorded after its begin as it ends.
  var passList = GPUCommandList()

  /// Images written in the open list since its last barrier: a pass's attachments, a copy's destination.
  var written: [UInt64] = []

  func noteWrite(_ image: GPUImage) {
    if !written.contains(image.handle) { written.append(image.handle) }
  }

  /// Records a barrier if anything in `images` was written since the last: what follows sees what was written.
  func barrier(before images: [UInt64]) {
    guard !written.isEmpty else { return }
    for h in images where written.contains(h) {
      list.barrier()
      written = []
      return
    }
  }

  /// Records the open pass's begin: each attachment cleared as the pass's clear says, else loaded.
  func begin() {
    guard var p = pass, !p.begun else { return }
    let t = p.target
    barrier(before: p.reads)
    if let c = t.color { noteWrite(c.image) }
    if let d = t.depthStencil { noteWrite(d.image) }
    var colors: [Attachment] = []
    if t.color == nil, let scratch = t.scratch { colors.append(Attachment(view: scratch, load: .dontCare, store: .discard)) }
    if let c = t.color {
      var load = LoadAction.load
      if let v = p.clear.color { load = .clear(v.0, v.1, v.2, t.colorAlpha ? v.3 : 1) }
      colors.append(Attachment(view: c, load: load, store: .store))
    }
    var ds: DepthStencilAttachment?
    if let d = t.depthStencilFormat, let view = t.depthStencil {
      // An aspect GL's framebuffer doesn't have (a combined image of a depth-only config) is neither loaded nor stored.
      let depth = d.hasDepth && t.hasDepth, stencil = d.hasStencil && t.hasStencil
      let depthLoad: AspectLoad = depth ? (p.clear.depth != nil ? .clear : .load) : .dontCare
      let stencilLoad: AspectLoad = stencil ? (p.clear.stencil != nil ? .clear : .load) : .dontCare
      ds = DepthStencilAttachment(view: view, depthLoad: depthLoad, stencilLoad: stencilLoad,
                                  depthStore: depth ? .store : .discard, stencilStore: stencil ? .store : .discard,
                                  clearDepth: p.clear.depth ?? 1, clearStencil: p.clear.stencil ?? 0)
    }
    p.info = RenderingInfo(colors: colors, depthStencil: ds)
    p.begun = true
    p.clear = PendingClear()
    pass = p
  }

  /// Submits the open list (ending its pass), signalling a new value of the timeline, and returns that value; the last
  /// value submitted if the list is empty.
  @discardableResult
  func submit() throws(GPUError) -> UInt64 {
    endPass()
    guard !list.isEmpty else { return lastSubmitted }
    let value = self.value(ofEpoch: epoch)
    let l = list
    list = GPUCommandList()
    let counting = unsafe glesStats
    var t0: UInt64 = 0
    if counting {
      t0 = unsafe glesClock()
      if stats.frameStart != 0 { stats.recordNs &+= t0 &- stats.frameStart }
      count(l)
    }
    try device.graphicsQueue.submit(l, wait: 0, signal: value)
    if counting { stats.submitNs &+= unsafe glesClock() &- t0 }
    lastSubmitted = value
    submissions += 1
    ring.submitted(value)
    heap.submitted()
    for i in releaseImages { device.destroy(i) }
    for m in releaseMemory { device.free(m) }
    for p in releasePipelines { device.destroy(p) }
    releasePipelines = []
    releaseImages = []
    releaseMemory = []
    epoch &+= 1
    onSubmit?(value)
    return value
  }

  /// Submits and waits for the GPU to finish everything.
  func finish() throws(GPUError) {
    let v = try submit()
    let counting = unsafe glesStats
    let t0 = counting ? unsafe glesClock() : 0
    if v > device.completed { try device.wait(v) }
    ring.reclaim()
    if counting {
      let t1 = unsafe glesClock()
      stats.waitNs &+= t1 &- t0
      stats.frameStart = t1
    }
  }

  /// The timeline value the list of `epoch` was (or will be) submitted as: each submission is the next value.
  func value(ofEpoch e: UInt64) -> UInt64 { valueBase + e }

  /// Whether the GPU may still read what the list of `epoch` read: it is the open list, or its submission isn't done.
  func isBusy(_ e: UInt64) -> Bool { e == epoch || value(ofEpoch: e) > device.completed }

  /// Memory for a buffer's device copy of `bytes`: one the GPU is past, of the size, or new.
  func bufferMemory(_ bytes: Int) throws(GPUError) -> GPUMemory {
    let done = device.completed
    if let i = spareBuffers.firstIndex(where: { $0.bytes == bytes && $0.readyAt <= done }) {
      return spareBuffers.remove(at: i).memory
    }
    return try device.allocate(.upload, bytes: max(bytes, 16))
  }

  /// Gives back a buffer's device copy of `bytes`, last read by the list of epoch `openUse`.
  func retireBuffer(_ m: GPUMemory, bytes: Int, openUse: UInt64) {
    if openUse == epoch {
      release(m)
      return
    }
    if spareBuffers.count >= 64 {
      // Too many kept: free the oldest (safe: the device keeps what was submitted).
      device.free(spareBuffers.removeFirst().memory)
    }
    spareBuffers.append((m, bytes, value(ofEpoch: openUse)))
  }

  /// Scratch colour images by size, for passes GL gives no colour attachment.
  var scratchImages: [(width: Int32, height: Int32, image: GPUImage)] = []

  func scratchColor(width: Int32, height: Int32) throws(GPUError) -> GPUImage {
    if let s = scratchImages.first(where: { $0.width == width && $0.height == height }) { return s.image }
    let image = try device.makeImage(ImageDescriptor(format: .rgba8, width: width, height: height, usage: .renderTarget))
    scratchImages.append((width, height, image))
    return image
  }

  /// The slot of the texture an incomplete one reads: (0, 0, 0, 1).
  func incompleteSlot(cube: Bool) throws(GPUError) -> UInt32 {
    if let b = cube ? blackCube : blackTexture { return b.slot }
    let image = try device.makeImage(ImageDescriptor(format: .rgba8, width: 1, height: 1, layers: cube ? 6 : 1,
                                                     dimension: cube ? .cube : .d2, usage: .sampled | .copyDestination))
    let staging = try ring.allocate(4 * 6)
    for i in 0..<6 { unsafe staging.pointer.storeBytes(of: 0xFF00_0000 as UInt32, toByteOffset: 4 * i, as: UInt32.self) }
    endPass()
    list.copy(staging.memory, to: image, regions: [
      BufferImageRegion(bufferOffset: staging.offset, subresource: ImageSubresourceLayers(layerCount: cube ? 6 : 1),
                        imageExtent: Extent3D(width: 1, height: 1)),
    ])
    let slot = try heap.takeTextureSlot()
    try device.writeTexture(slot, image)
    if cube { blackCube = (image, slot) } else { blackTexture = (image, slot) }
    return slot
  }
}
