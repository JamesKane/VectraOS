// SPDX-License-Identifier: BSD-3-Clause

// Images and their views (D174 section 1 and its amendment; gpucore(2)): an image is
// a format, a size, mip levels, layers and samples; what the heap and a pass
// see of one is an `ImageView`. The device picks each image's layout and
// tiling; the interface has none.

/// What an image may be used for. The device picks its layout and tiling from this and tracks the layout itself;
/// there are no image layouts at the interface.
public struct ImageUsage: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  /// Read by shaders through the heap's textures.
  public static let sampled = ImageUsage(rawValue: 1)
  /// Drawn into by a render pass, as a colour attachment.
  public static let renderTarget = ImageUsage(rawValue: 2)
  /// Read and written by shaders through the heap's storage images.
  public static let storage = ImageUsage(rawValue: 4)
  /// The source of a copy.
  public static let copySource = ImageUsage(rawValue: 8)
  /// The destination of a copy.
  public static let copyDestination = ImageUsage(rawValue: 16)
  /// Shown by a display as it is: the device makes it a buffer another process can be given (`exportHandle`), laid out
  /// as the display reads it (rows of `width * 4` bytes), and maps it as the GPU and the display share it, not cached by
  /// the CPU. A frame drawn into it needs no copy to be shown.
  public static let scanout = ImageUsage(rawValue: 32)
  /// The depth and stencil attachment of a render pass (a depth or stencil format).
  public static let depthStencilTarget = ImageUsage(rawValue: 64)

  public func contains(_ other: ImageUsage) -> Bool { rawValue & other.rawValue == other.rawValue }
  public static func | (a: ImageUsage, b: ImageUsage) -> ImageUsage { ImageUsage(rawValue: a.rawValue | b.rawValue) }
}

/// What an image's texels are laid out as. A cube is a 2D array whose layers are the six faces of each cube. A 1D image
/// is one row of texels (its height is 1), with layers where it is an array (`DeviceFeatures.images1D`).
/// `d1` is last so that the cases before it keep their places.
public enum ImageDimension: Sendable, Equatable { case d2, d3, cube, d1 }

public struct ImageDescriptor: Sendable, Equatable {
  public var format: PixelFormat
  public var width: Int32
  public var height: Int32
  /// Texels in depth: 1 unless the image is 3D.
  public var depth: Int32
  /// Mip levels, each half the size of the one before (down to one texel), from 1 to `maxMipLevels`.
  public var mipLevels: UInt32
  /// Array layers: 1 for a 3D image, a multiple of 6 for a cube (six faces for each cube).
  public var layers: UInt32
  /// Samples a texel: 1, or 2, 4, 8, 16, 32 or 64 for a multisampled image (2D, one mip level).
  public var samples: UInt32
  public var dimension: ImageDimension
  public var usage: ImageUsage
  public init(format: PixelFormat, width: Int32, height: Int32, depth: Int32 = 1, mipLevels: UInt32 = 1, layers: UInt32 = 1,
              samples: UInt32 = 1, dimension: ImageDimension = .d2, usage: ImageUsage) {
    self.format = format
    self.width = width
    self.height = height
    self.depth = depth
    self.mipLevels = mipLevels
    self.layers = layers
    self.samples = samples
    self.dimension = dimension
    self.usage = usage
  }

  /// The most mip levels the image's size allows: one more than the log of its largest side (a 3D image's depth counts).
  public var maxMipLevels: UInt32 {
    var largest = max(width, height)
    if dimension == .d3 { largest = max(largest, depth) }
    guard largest > 0 else { return 0 }
    return UInt32(Int32.bitWidth - largest.leadingZeroBitCount)
  }

  /// The size of mip level `level`: each side halved per level, never below one.
  public func mipExtent(_ level: UInt32) -> (width: Int32, height: Int32, depth: Int32) {
    let s = Int32(truncatingIfNeeded: min(level, 31))
    return (max(1, width >> s), max(1, height >> s), dimension == .d3 ? max(1, depth >> s) : 1)
  }

  /// Bytes of mip level `level` of one layer, tightly packed, for one aspect (the format's only one, where nil).
  public func byteSize(mip level: UInt32 = 0, aspect: ImageAspects? = nil) -> Int {
    let e = mipExtent(level)
    return format.byteSize(width: Int(e.width), height: Int(e.height), depth: Int(e.depth), aspect: aspect)
  }
}

public struct GPUImage: Sendable, Equatable {
  public let handle: UInt64
  public let descriptor: ImageDescriptor
  public init(handle: UInt64, descriptor: ImageDescriptor) {
    self.handle = handle
    self.descriptor = descriptor
  }
  public var width: Int32 { descriptor.width }
  public var height: Int32 { descriptor.height }
  public var depth: Int32 { descriptor.depth }
  public var mipLevels: UInt32 { descriptor.mipLevels }
  public var layers: UInt32 { descriptor.layers }
  public var samples: UInt32 { descriptor.samples }
  public var dimension: ImageDimension { descriptor.dimension }
  public var format: PixelFormat { descriptor.format }
  public var usage: ImageUsage { descriptor.usage }
}

/// The mip level and layers of an image that a copy, a blit or a resolve reads or writes, of one aspect.
public struct ImageSubresourceLayers: Sendable, Equatable {
  public var aspects: ImageAspects
  public var mip: UInt32
  public var baseLayer: UInt32
  public var layerCount: UInt32
  public init(aspects: ImageAspects = .color, mip: UInt32 = 0, baseLayer: UInt32 = 0, layerCount: UInt32 = 1) {
    self.aspects = aspects
    self.mip = mip
    self.baseLayer = baseLayer
    self.layerCount = layerCount
  }
}

/// A range of an image's mip levels and layers, for the aspects named: a clear's and a barrier's.
public struct ImageSubresourceRange: Sendable, Equatable {
  public var aspects: ImageAspects
  public var baseMip: UInt32
  public var mipCount: UInt32
  public var baseLayer: UInt32
  public var layerCount: UInt32
  public init(aspects: ImageAspects = .color, baseMip: UInt32 = 0, mipCount: UInt32 = 1, baseLayer: UInt32 = 0,
              layerCount: UInt32 = 1) {
    self.aspects = aspects
    self.baseMip = baseMip
    self.mipCount = mipCount
    self.baseLayer = baseLayer
    self.layerCount = layerCount
  }

  /// Every mip level and layer of `image`, of all the aspects of its format.
  public init(all image: GPUImage) {
    self.init(aspects: image.format.aspects, baseMip: 0, mipCount: image.mipLevels, baseLayer: 0, layerCount: image.layers)
  }
}

/// How a view reads its image. `d1` and `d1Array` are last so that the cases before them keep their places.
public enum ImageViewDimension: Sendable, Equatable { case d2, d2Array, cube, cubeArray, d3, d1, d1Array }

/// Where a view takes one of its four components from (VkComponentSwizzle): the texel's own, a constant, or another of
/// its components.
public enum ComponentSwizzle: Sendable, Equatable { case identity, zero, one, r, g, b, a }

/// How a view maps its image's components to the ones a shader reads: each of the four is the texel's own, 0, 1 or one of
/// the texel's. The identity (the default) reads each as it is. A device that can't map (`DeviceFeatures.imageSwizzle`)
/// refuses any other. A shader reading an integer view reads the constants 0 and 1 as integers.
public struct ComponentMapping: Sendable, Equatable {
  public var r: ComponentSwizzle
  public var g: ComponentSwizzle
  public var b: ComponentSwizzle
  public var a: ComponentSwizzle
  public init(r: ComponentSwizzle = .identity, g: ComponentSwizzle = .identity, b: ComponentSwizzle = .identity,
              a: ComponentSwizzle = .identity) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  /// Every component as it is.
  public static let identity = ComponentMapping()

  /// Whether each component reads as itself (`.identity`, or its own letter): a view with such a mapping needs no device
  /// support for one.
  public var isIdentity: Bool {
    (r == .identity || r == .r) && (g == .identity || g == .g) && (b == .identity || b == .b) && (a == .identity || a == .a)
  }
}

/// An image as the heap and a pass see it: a format compatible with the image's, a range of its mip levels and layers,
/// and how to read it. `ImageView(image)` is the whole image.
public struct ImageView: Sendable, Equatable {
  public var image: GPUImage
  public var format: PixelFormat
  public var dimension: ImageViewDimension
  public var baseMip: UInt32
  public var mipCount: UInt32
  public var baseLayer: UInt32
  public var layerCount: UInt32
  /// The aspects the view reads: a depth or stencil image's view reads one of them; a colour image's is colour.
  public var aspects: ImageAspects
  /// How the view maps the image's components to the shader's (the identity unless said).
  public var swizzle: ComponentMapping

  /// A view of `image`: unless named, its format, all the mip levels from `baseMip` and all the layers from `baseLayer`,
  /// read as the image's dimension (an array where it has layers).
  public init(_ image: GPUImage, format: PixelFormat? = nil, dimension: ImageViewDimension? = nil, baseMip: UInt32 = 0,
              mipCount: UInt32? = nil, baseLayer: UInt32 = 0, layerCount: UInt32? = nil, aspects: ImageAspects? = nil,
              swizzle: ComponentMapping = ComponentMapping()) {
    self.image = image
    self.swizzle = swizzle
    self.format = format ?? image.format
    self.baseMip = baseMip
    self.mipCount = mipCount ?? (image.mipLevels > baseMip ? image.mipLevels - baseMip : 0)
    self.baseLayer = baseLayer
    let layers = layerCount ?? (image.layers > baseLayer ? image.layers - baseLayer : 0)
    self.layerCount = layers
    self.aspects = aspects ?? (format ?? image.format).aspects
    if let dimension {
      self.dimension = dimension
    } else {
      switch image.dimension {
      case .d3: self.dimension = .d3
      case .cube: self.dimension = layers == 6 ? .cube : .cubeArray
      case .d2: self.dimension = layers > 1 ? .d2Array : .d2
      case .d1: self.dimension = layers > 1 ? .d1Array : .d1
      }
    }
  }

  /// The view's size: the first mip level's.
  public var width: Int32 { image.descriptor.mipExtent(baseMip).width }
  public var height: Int32 { image.descriptor.mipExtent(baseMip).height }
  public var samples: UInt32 { image.samples }

  /// Whether the view is the whole image, as the image-only calls mean it.
  public var isWholeImage: Bool {
    // A mapping that reads each component as itself is the identity, however it is spelled.
    guard swizzle.isIdentity else { return false }
    var v = self
    v.swizzle = ComponentMapping()
    return v == ImageView(image)
  }
}

// MARK: Texel buffers

/// A range of memory read as an array of texels of one format, which a shader fetches from (`texelFetch` of a
/// `samplerBuffer`) or reads, writes and applies atomics to (an `imageBuffer`): what the heap's texel-buffer slots hold.
/// There is no sampler and no filtering, and no mip levels: texel `i` is the `i`th `format.texelBlock.bytes` of the range.
public struct BufferView: Sendable, Equatable {
  public var memory: GPUMemory
  /// Where the first texel is in `memory`, in bytes.
  public var offset: Int
  /// The bytes the view covers, a whole number of texels.
  public var range: Int
  public var format: PixelFormat

  /// A view of `memory` from `offset`: `range` bytes, or to the end of the memory where not named.
  public init(_ memory: GPUMemory, format: PixelFormat, offset: Int = 0, range: Int? = nil) {
    self.memory = memory
    self.format = format
    self.offset = offset
    self.range = range ?? max(0, memory.size - offset)
  }

  /// The bytes of one texel.
  public var texelBytes: Int { format.texelBlock.bytes }
  /// The texels a shader can address: the range over the texel's size.
  public var elementCount: Int { texelBytes > 0 ? range / texelBytes : 0 }
}
