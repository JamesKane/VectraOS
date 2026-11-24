// SPDX-License-Identifier: BSD-3-Clause

// Sparse resources on Mali (gpucore(2); valhall 02 section 2.9.4, 05 section 5.7.3, 16 section 16.8.6; panthor 04 section 4.8.3).
// The hardware has no residency of its own: a sparse buffer or image is a range of the VM's addresses, reserved when it is
// made and never moved, whose pages the GPU's MMU maps one bind at a time.
//
// - A bind of memory maps a range of that memory's pages at the resource's addresses (the driver's MAP of part of a buffer); a
//   bind to nothing maps the range to the client's dummy (the driver's sparse MAP), never leaves it unmapped: an access to an
//   unmapped page is an MMU fault, fatal to the work. A resource used partly bound is mapped to the dummy over its whole range
//   when it is made; one bound only as a whole stays unmapped until it is bound. Its destruction unmaps the range.
// - Every range bound to the dummy repeats one 2 MiB buffer of the driver's (VA x at x mod 2 MiB), so a read there gives what
//   the last write through any of them left, not zero (`residencyNonResidentStrict` false).
// - Buffers and images bound only as a whole are bound by 4 KiB pages (the GPU's smallest). An image used partly bound is laid
//   out in 64 KiB tiles (05 section 5.7), each tile one block: 256 x 256 texels of 1 byte down to 64 x 64 of 16, one slice deep
//   for a volume (not Vulkan's standard 3D shape). Every level is whole tiles, so the mip tail is the last level of each layer.
// - A bind is ordered as a submission is (this backend runs one at a time): it starts when everything submitted before it has
//   finished, which includes what `wait` names, and the timeline reaches `signal` when it is done.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

/// A sparse resource's range of addresses: no pages of its own (`bindSparse` maps memory's there) and no CPU mapping.
final class SparseRange: MaliBuffer {
  let size: Int
  init(size: Int) { self.size = size }
  var pointer: UnsafeMutableRawPointer { preconditionFailure("a sparse resource has no CPU mapping") }
  func store(_ value: UInt64, at offset: Int) { preconditionFailure("a sparse resource has no CPU mapping") }
  var cpuCached: Bool { false }
  func cleanInvalidate() {}
  func exportVMO() -> UInt32? { nil }
}

extension MaliDevice {
  /// The GPU's smallest page: what a sparse buffer, and an image bound only as a whole, are bound by.
  static let sparsePage = 4096
  /// An image used partly bound is bound by 64 KiB tiles, its blocks.
  static let sparseBlock = 65536

  /// What the reference reports from arch 10 (valhall 16 section 16.8.6): binding, residency of buffers and of 2D and 3D images;
  /// not multisampled residency, aliasing, residency in shaders or strict residency.
  func enableSparse() {
    guard transport.info.arch >= 10 else { return }
    baseLimits.features.sparseBinding = true
    baseLimits.features.sparseResidencyBuffer = true
    baseLimits.features.sparseResidencyImage2D = true
    baseLimits.features.sparseResidencyImage3D = true
    baseLimits.sparse.residencyStandard2DBlockShape = true
    baseLimits.sparseAddressSpaceSize = userRange != 0 ? userRange : 1 << 47
  }

  /// A range of the VM's addresses for a sparse resource of `bytes`, whole pages of `page`, aligned to 2 MiB from 2 MiB on (02
  /// section 2.9.4); with residency, mapped to the dummy over the whole range now.
  func reserveSparse(_ bytes: Int, page: Int, flags: SparseFlags) throws(GPUError) -> Region {
    reclaim()
    let size = (bytes + page - 1) / page * page
    let address = try takeAddress(size, alignment: UInt64(size >= 2 << 20 ? 2 << 20 : page))
    if flags.contains(.residency) { try transport.bindDummy(vm: vm, address: address, size: size, gpuCacheable: true) }
    let region = Region(buffer: SparseRange(size: size), address: address, size: size)
    region.sparse = flags
    return region
  }

  public func makeSparseBuffer(bytes: Int, flags: SparseFlags) throws(GPUError) -> GPUMemory {
    if let e = sparseBufferError(bytes: bytes, flags: flags, limits: limits) { throw e }
    let region = try reserveSparse(bytes, page: Self.sparsePage, flags: flags)
    return unsafe GPUMemory(handle: memories.insert(region), address: region.address, pointer: nil, size: bytes, intent: .device,
                            sparse: flags)
  }

  public func sparseRequirements(_ buffer: GPUMemory) throws(GPUError) -> SparseMemoryRequirements {
    guard let r = memories[buffer.handle] else { throw .invalid("memory that isn't this device's") }
    guard !r.sparse.isEmpty else { throw .invalid("requirements of memory that isn't a sparse buffer") }
    return SparseMemoryRequirements(size: r.size, pageBytes: Self.sparsePage)
  }

  public func sparseRequirements(_ image: GPUImage) throws(GPUError) -> SparseMemoryRequirements {
    guard let r = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard !r.region.sparse.isEmpty else { throw .invalid("requirements of an image that isn't sparse") }
    return SparseMemoryRequirements(size: r.region.size, pageBytes: r.region.sparse.contains(.residency) ? Self.sparseBlock : Self.sparsePage)
  }

  /// The block a 64 KiB tile is, in texels, for a plane's format (05 section 5.7.3): the tile's elements times a compressed
  /// format's block.
  func sparseBlockShape(_ texel: TexelFormat) -> Extent3D? {
    guard let tile = ImageLayout.tile64K(bytes: texel.bytesPerTexel) else { return nil }
    return Extent3D(width: UInt32(tile.width * texel.blockWidth), height: UInt32(tile.height * texel.blockHeight), depth: 1)
  }

  /// Why an image of `d` can't be sparse here, nil where it can. Bound only as a whole, any image this backend makes; used partly
  /// bound (05 section 5.7.3), a 2D, cube or 3D image of one sample and one aspect whose texel is 1 to 16 bytes, a power of two,
  /// sampled, stored to, copied and drawn into as a colour target (not a depth or stencil target here).
  func sparseImageError(_ d: ImageDescriptor) -> GPUError? {
    guard d.sparse.contains(.residency) else { return nil }
    if d.dimension == .d1 { return .unsupported("a 1D image used partly bound") }
    if d.samples != 1 { return .unsupported("an image of \(d.samples) samples used partly bound") }
    let aspects = singleAspects(d.format.aspects)
    guard aspects.count == 1, let texel = d.format.texelFormat(aspect: aspects[0]) else {
      return .unsupported("an image of \(d.format) used partly bound")
    }
    if texel.blockWidth > 1 || texel.blockHeight > 1 { return .unsupported("a compressed image used partly bound") }
    guard sparseBlockShape(texel) != nil else { return .unsupported("an image of \(d.format) used partly bound") }
    let allowed = ImageUsage.sampled | .storage | .copySource | .copyDestination | .renderTarget
    if d.usage.rawValue & ~allowed.rawValue != 0 { return .unsupported("an image used partly bound with usage \(d.usage.rawValue)") }
    return nil
  }

  public func sparseImageFormats(_ format: PixelFormat, dimension: ImageDimension, samples: UInt32, usage: ImageUsage)
    -> [SparseImageFormatProperties]
  {
    guard baseLimits.features.sparseBinding else { return [] }
    let d = ImageDescriptor(format: format, width: 1, height: 1, samples: samples, dimension: dimension, usage: usage,
                            sparse: .binding | .residency)
    if sparseImageError(d) != nil { return [] }
    if usage.contains(.renderTarget) && !(format == .rgba8 || format == .bgra8 || format == .bgra8srgb) { return [] }
    let aspect = format.firstAspect
    guard let texel = format.texelFormat(aspect: aspect), let shape = sparseBlockShape(texel) else { return [] }
    return [SparseImageFormatProperties(aspects: aspect, blockShape: shape, nonStandardBlockSize: dimension == .d3)]
  }

  public func sparseImageRequirements(_ image: GPUImage) throws(GPUError) -> [SparseImageRequirements] {
    guard let r = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard !r.region.sparse.isEmpty else { throw .invalid("requirements of an image that isn't sparse") }
    guard r.region.sparse.contains(.residency) else { return [] }
    var out: [SparseImageRequirements] = []
    for p in r.planes {
      guard let shape = sparseBlockShape(p.texel) else { continue }
      // The tail is the last level of each layer (05 section 5.7.3): from its offset to the layer's end, the layer stride apart.
      let last = p.layout.levels.count - 1
      let offset = p.offset + p.layout.levels[last].offset
      out.append(SparseImageRequirements(
        format: SparseImageFormatProperties(aspects: p.aspect, blockShape: shape, nonStandardBlockSize: r.descriptor.dimension == .d3),
        mipTailFirstLevel: UInt32(last), mipTailSize: p.layout.arrayStride - p.layout.levels[last].offset, mipTailOffset: offset,
        mipTailStride: p.layout.arrayStride))
    }
    return out
  }

  /// A sparse image (Resources.swift's `makeImage` for one with `sparse`): its range reserved (with residency, mapped to the dummy),
  /// and its plane descriptors, which can't live in a range with no pages, in a region of their own.
  func makeSparseImage(_ d: ImageDescriptor, planes: [AspectPlane], bytes: Int, planeBytes: Int) throws(GPUError) -> GPUImage {
    let page = d.sparse.contains(.residency) ? Self.sparseBlock : Self.sparsePage
    let region = try reserveSparse(bytes, page: page, flags: d.sparse)
    let layout = planes[0].layout
    var planeRegion: Region?
    if planeBytes > 0 {
      let descriptors: Region
      do { descriptors = try makeRegion(planeBytes) } catch {
        release([region])
        throw error
      }
      do throws(DescriptorError) {
        var at = 0
        for p in layout.planes(base: region.address) {
          store(try p.words(), in: descriptors, at: at)
          at += PlaneDescriptor.size
        }
      } catch {
        release([region, descriptors])
        throw .invalid("an image the texture unit can't describe")
      }
      planeRegion = descriptors
    }
    let record = ImageRecord(region: region, descriptor: d, rowStride: layout.levels[0].rowStride, layout: layout,
                             planeAt: planeRegion == nil ? nil : 0)
    record.planes = planes
    record.planeRegion = planeRegion
    return GPUImage(handle: images.insert(record), descriptor: d)
  }

  // MARK: Binds

  /// The memory a bind maps: ordinary memory of this device (never a sparse resource), at an offset on its pages.
  func sparseMemory(_ m: GPUMemory?, _ offset: Int, page: Int) throws(GPUError) -> Region? {
    guard let m else { return nil }
    guard let r = memories[m.handle] else { throw .invalid("memory that isn't this device's") }
    if !r.sparse.isEmpty { throw .invalid("sparse memory bound into a sparse resource") }
    if offset % page != 0 { throw .invalid("a sparse bind from memory off its pages of \(page) bytes") }
    return r
  }

  /// Maps `size` bytes at `address` to `memory`'s pages from `offset`, or to the dummy.
  func sparseMap(_ address: UInt64, _ size: Int, _ memory: Region?, _ offset: Int) throws(GPUError) {
    if let memory {
      if offset + size > memory.size { throw .invalid("a sparse bind past its memory") }
      try transport.bind(vm: vm, buffer: memory.buffer, offset: offset, size: size, address: address, gpuCacheable: true)
    } else {
      try transport.bindDummy(vm: vm, address: address, size: size, gpuCacheable: true)
    }
  }

  /// A range of a resource's bytes bound: whole pages, or to the end of its range.
  func sparseRange(_ r: Region, _ offset: Int, _ size: Int, page: Int) throws(GPUError) -> Int {
    if offset % page != 0 || offset < 0 || size <= 0 { throw .invalid("a sparse bind off the resource's pages of \(page) bytes") }
    let rounded = (size + page - 1) / page * page
    if size % page != 0 && offset + size != r.size && offset + rounded != r.size {
      throw .invalid("a sparse bind off the resource's pages of \(page) bytes")
    }
    if offset + rounded > r.size { throw .invalid("a sparse bind past its resource") }
    return rounded
  }

  public func bindSparse(_ bindings: SparseBindings, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = bindings.validate(limits: limits) { throw e }
    if let e = rule.check(wait: wait, signal: signal) { throw e }
    // Everything submitted before has finished (what `wait` names among it), as a submission starts here.
    try self.wait(rule.lastSignalled)
    // Each bind's pages, checked before any is made.
    var maps: [(address: UInt64, size: Int, memory: Region?, offset: Int)] = []
    for b in bindings.buffers {
      guard let r = memories[b.buffer.handle], !r.sparse.isEmpty else { throw .invalid("memory that isn't this device's sparse buffer") }
      let size = try sparseRange(r, b.offset, b.size, page: Self.sparsePage)
      maps.append((r.address + UInt64(b.offset), size, try sparseMemory(b.memory, b.memoryOffset, page: Self.sparsePage), b.memoryOffset))
    }
    for b in bindings.opaque {
      guard let i = images[b.image.handle], !i.region.sparse.isEmpty else { throw .invalid("an image that isn't this device's sparse image") }
      if b.metadata { throw .invalid("a bind of metadata, which this device's images haven't") }
      let page = i.region.sparse.contains(.residency) ? Self.sparseBlock : Self.sparsePage
      let size = try sparseRange(i.region, b.offset, b.size, page: page)
      maps.append((i.region.address + UInt64(b.offset), size, try sparseMemory(b.memory, b.memoryOffset, page: page), b.memoryOffset))
    }
    for b in bindings.images {
      guard let i = images[b.image.handle], i.region.sparse.contains(.residency) else {
        throw .invalid("a block bind into an image that isn't this device's, used partly bound")
      }
      guard let p = plane(i, b.aspects), let shape = sparseBlockShape(p.texel) else { throw .invalid("a block bind of an aspect its image hasn't") }
      let mip = Int(b.mip)
      // The tail (the last level) is bound by bytes.
      if mip >= p.layout.levels.count - 1 { throw .invalid("a block bind of level \(mip), which is in the mip tail") }
      let level = p.layout.levels[mip]
      let bw = Int(shape.width), bh = Int(shape.height)
      let x0 = Int(b.offset.x), y0 = Int(b.offset.y), z0 = Int(b.offset.z)
      let x1 = x0 + Int(b.extent.width), y1 = y0 + Int(b.extent.height), z1 = z0 + Int(b.extent.depth)
      if x0 % bw != 0 || y0 % bh != 0 || (x1 % bw != 0 && x1 != level.width) || (y1 % bh != 0 && y1 != level.height) {
        throw .invalid("a block bind off the image's blocks of \(bw) x \(bh)")
      }
      let memory = try sparseMemory(b.memory, b.memoryOffset, page: Self.sparseBlock)
      // One 64 KiB tile a block, x fastest, then y, then z (05 section 5.7.3), the memory a tile further each.
      var at = b.memoryOffset
      let base = p.offset + Int(b.layer) * p.layout.arrayStride + level.offset
      for z in z0..<z1 {
        for by in (y0 / bh)..<((y1 + bh - 1) / bh) {
          for bx in (x0 / bw)..<((x1 + bw - 1) / bw) {
            let offset = base + z * level.surfaceStride + by * level.rowStride + bx * Self.sparseBlock
            maps.append((i.region.address + UInt64(offset), Self.sparseBlock, memory, at))
            at += Self.sparseBlock
          }
        }
      }
    }
    if let e = rule.accept(wait: wait, signal: signal) { throw e }
    // The timeline reaches the signal even where the driver refused a map, so nothing waits for it forever.
    var failure: GPUError?
    for m in maps {
      do { try sparseMap(m.address, m.size, m.memory, m.offset) } catch {
        failure = error
        break
      }
    }
    transport.raiseSync(timeline, to: signal)
    if let failure { throw failure }
  }
}
