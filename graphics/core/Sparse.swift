// SPDX-License-Identifier: BSD-3-Clause

// Sparse resources (D174's amendment, "Elsewhere"; gpucore(2)): a buffer or an image made with an address range and no
// pages, whose pages are bound later, a page at a time, by the queue (`GPUQueue.bindSparse`), in order with its
// submissions and on the one timeline. The pages bound are ranges of ordinary memory (`allocate`); a range bound to
// nothing reads as the device says (`SparseProperties.residencyNonResidentStrict`) and drops writes.
//
// The shape is the hardware's and every backend's: on Vulkan a bind is vkQueueBindSparse; on a GPU with its own
// page tables (Mali) it is a run of the memory's pages mapped at the resource's addresses, a page each, with the
// range bound to nothing mapped to a page of zeros or left unmapped. A device without sparse resources keeps the
// defaults, which refuse.

/// How a sparse resource may be bound and used.
public struct SparseFlags: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32 = 0) { self.rawValue = rawValue }
  /// The resource's pages are bound by `bindSparse`, not when it is made; it is wholly bound before work uses it
  /// (`DeviceFeatures.sparseBinding`).
  public static let binding = SparseFlags(rawValue: 1)
  /// Work may use it while only part of it is bound (`sparseResidencyBuffer`, `sparseResidencyImage2D` and the others).
  /// An image is then bound by blocks of texels (`SparseImageBind`) as well as by bytes.
  public static let residency = SparseFlags(rawValue: 2)
  /// A page of memory may be bound at more than one place at once, of this resource or another aliased one
  /// (`sparseResidencyAliased`).
  public static let aliased = SparseFlags(rawValue: 4)

  public var isEmpty: Bool { rawValue == 0 }
  public func contains(_ other: SparseFlags) -> Bool { rawValue & other.rawValue == other.rawValue }
  public static func | (a: SparseFlags, b: SparseFlags) -> SparseFlags { SparseFlags(rawValue: a.rawValue | b.rawValue) }
}

/// How the device lays out and reads sparse images (`DeviceLimits.sparse`).
public struct SparseProperties: Sendable, Equatable {
  /// Single-sampled 2D images, multisampled ones and 3D images have the standard block shapes (a 64 KiB block: 256 x 256
  /// texels of 1 byte, down to 64 x 64 of 16; and the multisampled and 3D shapes of the Vulkan specification's table).
  public var residencyStandard2DBlockShape = false
  public var residencyStandard2DMultisampleBlockShape = false
  public var residencyStandard3DBlockShape = false
  /// Mip levels whose sides aren't whole blocks go in the mip tail.
  public var residencyAlignedMipSize = false
  /// What isn't bound reads as zero (ints) or zero with the format's alpha (floats); otherwise its value is undefined.
  public var residencyNonResidentStrict = false
  public init() {}
}

/// What binds to a sparse resource cover: its range of bytes (a buffer's size, or an image's opaque size, rounded up to whole
/// pages) and the page every bind's offsets and sizes are a multiple of, in the resource and in the memory bound.
public struct SparseMemoryRequirements: Sendable, Equatable {
  public var size: Int
  public var pageBytes: Int
  public init(size: Int, pageBytes: Int) {
    self.size = size
    self.pageBytes = pageBytes
  }
}

/// How a sparse image of a format is bound, for one aspect: the block of texels one page holds, and how its mip tail is kept.
public struct SparseImageFormatProperties: Sendable, Equatable {
  public var aspects: ImageAspects
  /// Texels of one page; an image bind's offset and extent are whole blocks (but at the edges of a level).
  public var blockShape: Extent3D
  /// One mip tail for all the layers, not one for each.
  public var singleMipTail: Bool
  /// The first level whose sides aren't whole blocks starts the mip tail (`SparseProperties.residencyAlignedMipSize`).
  public var alignedMipSize: Bool
  /// The block isn't the standard shape for the format and the image's kind.
  public var nonStandardBlockSize: Bool
  public init(aspects: ImageAspects, blockShape: Extent3D, singleMipTail: Bool = false, alignedMipSize: Bool = false,
              nonStandardBlockSize: Bool = false) {
    self.aspects = aspects
    self.blockShape = blockShape
    self.singleMipTail = singleMipTail
    self.alignedMipSize = alignedMipSize
    self.nonStandardBlockSize = nonStandardBlockSize
  }
}

/// A sparse image's requirements for one aspect: its block, and where its mip tail is in the image's opaque range (the levels
/// from `mipTailFirstLevel` on are bound by bytes, an `SparseImageOpaqueBind`, not by blocks).
public struct SparseImageRequirements: Sendable, Equatable {
  public var format: SparseImageFormatProperties
  public var mipTailFirstLevel: UInt32
  public var mipTailSize: Int
  public var mipTailOffset: Int
  /// Bytes from one layer's mip tail to the next's (where the tail isn't single).
  public var mipTailStride: Int
  public init(format: SparseImageFormatProperties, mipTailFirstLevel: UInt32, mipTailSize: Int, mipTailOffset: Int, mipTailStride: Int) {
    self.format = format
    self.mipTailFirstLevel = mipTailFirstLevel
    self.mipTailSize = mipTailSize
    self.mipTailOffset = mipTailOffset
    self.mipTailStride = mipTailStride
  }
}

/// A range of a sparse buffer bound to a range of memory, or to nothing (`memory` nil): `size` bytes from `offset` of the
/// buffer, from `memoryOffset` of the memory. The range is whole pages, and may run to the end of the buffer's last page
/// (`SparseMemoryRequirements.size`).
public struct SparseBufferBind: Sendable, Equatable {
  public var buffer: GPUMemory
  public var offset: Int
  public var size: Int
  public var memory: GPUMemory?
  public var memoryOffset: Int
  public init(buffer: GPUMemory, offset: Int, size: Int, memory: GPUMemory?, memoryOffset: Int = 0) {
    self.buffer = buffer
    self.offset = offset
    self.size = size
    self.memory = memory
    self.memoryOffset = memoryOffset
  }
}

/// A range of a sparse image's opaque bytes (all of it, for an image without residency; its mip tails, for one with), bound to
/// memory or to nothing. `metadata` binds the image's metadata (an aspect the device says it has) in place of its texels.
public struct SparseImageOpaqueBind: Sendable, Equatable {
  public var image: GPUImage
  public var offset: Int
  public var size: Int
  public var memory: GPUMemory?
  public var memoryOffset: Int
  public var metadata: Bool
  public init(image: GPUImage, offset: Int, size: Int, memory: GPUMemory?, memoryOffset: Int = 0, metadata: Bool = false) {
    self.image = image
    self.offset = offset
    self.size = size
    self.memory = memory
    self.memoryOffset = memoryOffset
    self.metadata = metadata
  }
}

/// A box of texels of one level and layer of a sparse image with residency, bound by blocks to memory (one page a block, in
/// the order of the blocks: x, then y, then z) or to nothing.
public struct SparseImageBind: Sendable, Equatable {
  public var image: GPUImage
  public var aspects: ImageAspects
  public var mip: UInt32
  public var layer: UInt32
  public var offset: Offset3D
  public var extent: Extent3D
  public var memory: GPUMemory?
  public var memoryOffset: Int
  public init(image: GPUImage, aspects: ImageAspects = .color, mip: UInt32 = 0, layer: UInt32 = 0, offset: Offset3D = Offset3D(),
              extent: Extent3D, memory: GPUMemory?, memoryOffset: Int = 0) {
    self.image = image
    self.aspects = aspects
    self.mip = mip
    self.layer = layer
    self.offset = offset
    self.extent = extent
    self.memory = memory
    self.memoryOffset = memoryOffset
  }
}

/// What one `bindSparse` binds: ranges of buffers, opaque ranges of images, and blocks of images. They take effect in order,
/// a later bind of a range replacing an earlier one.
public struct SparseBindings: Sendable, Equatable {
  public var buffers: [SparseBufferBind]
  public var opaque: [SparseImageOpaqueBind]
  public var images: [SparseImageBind]
  public init(buffers: [SparseBufferBind] = [], opaque: [SparseImageOpaqueBind] = [], images: [SparseImageBind] = []) {
    self.buffers = buffers
    self.opaque = opaque
    self.images = images
  }
  public var isEmpty: Bool { buffers.isEmpty && opaque.isEmpty && images.isEmpty }
}

extension GPUQueue {
  /// The queue's default: no sparse resources.
  public func bindSparse(_ bindings: SparseBindings, wait: UInt64, signal: UInt64) throws(GPUError) {
    throw .unsupported("sparse binding")
  }
}

extension GPUDevice {
  public func makeSparseBuffer(bytes: Int, flags: SparseFlags) throws(GPUError) -> GPUMemory {
    throw .unsupported("sparse buffers")
  }
  public func sparseRequirements(_ buffer: GPUMemory) throws(GPUError) -> SparseMemoryRequirements {
    throw .unsupported("sparse buffers")
  }
  public func sparseRequirements(_ image: GPUImage) throws(GPUError) -> SparseMemoryRequirements {
    throw .unsupported("sparse images")
  }
  public func sparseImageRequirements(_ image: GPUImage) throws(GPUError) -> [SparseImageRequirements] {
    throw .unsupported("sparse images")
  }
  public func sparseImageFormats(_ format: PixelFormat, dimension: ImageDimension, samples: UInt32, usage: ImageUsage)
    -> [SparseImageFormatProperties] { [] }
}

// MARK: Rules

/// Whether a sparse buffer of `bytes` with `flags` may be made: `.invalid` for a shape no device makes, `.unsupported` for what
/// this device lacks.
public func sparseBufferError(bytes: Int, flags: SparseFlags, limits: DeviceLimits) -> GPUError? {
  if bytes <= 0 { return .invalid("a sparse buffer of \(bytes) bytes") }
  if let e = sparseFlagsError(flags) { return e }
  let f = limits.features
  if !f.sparseBinding { return .unsupported("sparse buffers") }
  if flags.contains(.residency) && !f.sparseResidencyBuffer { return .unsupported("sparse buffers used partly bound") }
  if flags.contains(.aliased) && !f.sparseResidencyAliased { return .unsupported("aliased sparse resources") }
  if UInt64(bytes) > limits.sparseAddressSpaceSize { return .unsupported("a sparse buffer of \(bytes) bytes") }
  return nil
}

func sparseFlagsError(_ flags: SparseFlags) -> GPUError? {
  if flags.rawValue & ~7 != 0 { return .invalid("sparse flags of \(flags.rawValue)") }
  if !flags.isEmpty && !flags.contains(.binding) { return .invalid("a sparse resource used partly bound or aliased that isn't bound sparsely") }
  return nil
}

extension ImageDescriptor {
  /// A sparse image's own rules, which `check(limits:)` applies: the shapes no device makes sparse, and the features each needs.
  func sparseError(_ limits: DeviceLimits) -> GPUError? {
    if sparse.isEmpty { return nil }
    if let e = sparseFlagsError(sparse) { return e }
    if usage.contains(.scanout) { return .invalid("a sparse image that is shown") }
    if sparse.contains(.residency) && dimension == .d1 { return .invalid("a 1D image used partly bound") }
    let f = limits.features
    if !f.sparseBinding { return .unsupported("sparse images") }
    if sparse.contains(.aliased) && !f.sparseResidencyAliased { return .unsupported("aliased sparse resources") }
    if sparse.contains(.residency) {
      switch dimension {
      case .d3: if !f.sparseResidencyImage3D { return .unsupported("3D images used partly bound") }
      case .d2, .cube, .d1: if !f.sparseResidencyImage2D { return .unsupported("2D images used partly bound") }
      }
      switch samples {
      case 1: break
      case 2: if !f.sparseResidency2Samples { return .unsupported("images of 2 samples used partly bound") }
      case 4: if !f.sparseResidency4Samples { return .unsupported("images of 4 samples used partly bound") }
      case 8: if !f.sparseResidency8Samples { return .unsupported("images of 8 samples used partly bound") }
      case 16: if !f.sparseResidency16Samples { return .unsupported("images of 16 samples used partly bound") }
      default: return .unsupported("images of \(samples) samples used partly bound")
      }
    }
    return nil
  }
}

extension SparseBindings {
  /// Whether the device may run the binds: `.invalid` for a bind of the wrong shape (a resource that isn't sparse, memory that
  /// is, a range past either, a block bind of an image without residency or of a level or layer it hasn't), `.unsupported` for
  /// what this device lacks. The page alignment is the backend's to judge (`sparseRequirements`).
  public func validate(limits: DeviceLimits) -> GPUError? {
    let f = limits.features
    if !isEmpty && !f.sparseBinding { return .unsupported("sparse binding") }
    func memoryError(_ memory: GPUMemory?, _ offset: Int, _ size: Int) -> GPUError? {
      guard let m = memory else { return nil }
      if !m.sparse.isEmpty { return .invalid("sparse memory bound into a sparse resource") }
      if offset < 0 || offset + size > m.size { return .invalid("a sparse bind past its memory") }
      return nil
    }
    for b in buffers {
      if b.buffer.sparse.isEmpty { return .invalid("a sparse bind into memory that isn't a sparse buffer") }
      // The end may pass the buffer's size into its last page (`SparseMemoryRequirements.size`), which the backend judges.
      if b.size <= 0 || b.offset < 0 || b.offset >= b.buffer.size { return .invalid("a sparse bind past its buffer") }
      if let e = memoryError(b.memory, b.memoryOffset, b.size) { return e }
    }
    for b in opaque {
      if b.image.descriptor.sparse.isEmpty { return .invalid("a sparse bind into an image that isn't sparse") }
      if b.size <= 0 || b.offset < 0 { return .invalid("a sparse bind of no bytes, or before its image") }
      if let e = memoryError(b.memory, b.memoryOffset, b.size) { return e }
    }
    for b in images {
      let d = b.image.descriptor
      if !d.sparse.contains(.residency) { return .invalid("a block bind into an image that isn't used partly bound") }
      if b.mip >= d.mipLevels || b.layer >= d.layers { return .invalid("a block bind past its image's levels or layers") }
      if b.aspects.isEmpty || !d.format.aspects.contains(b.aspects) { return .invalid("a block bind of an aspect its image hasn't") }
      if b.extent.width == 0 || b.extent.height == 0 || b.extent.depth == 0 { return .invalid("a block bind of no texels") }
      let e = d.mipExtent(b.mip)
      if b.offset.x < 0 || b.offset.y < 0 || b.offset.z < 0 || Int(b.offset.x) + Int(b.extent.width) > Int(e.width)
        || Int(b.offset.y) + Int(b.extent.height) > Int(e.height) || Int(b.offset.z) + Int(b.extent.depth) > Int(e.depth) {
        return .invalid("a block bind past its level")
      }
      if b.memoryOffset < 0 { return .invalid("a block bind before its memory") }
    }
    return nil
  }
}
