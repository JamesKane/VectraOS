// SPDX-License-Identifier: BSD-3-Clause

// Pixel formats (D174 section 1 and its amendment; gpucore(2)): the formats a
// device may offer, each describing itself (its texel block, its aspects, whether
// it is compressed), and the capability query a backend fills in
// (`DeviceLimits.formats(_:)`). A format that a device doesn't list has no
// capabilities there: nothing can be made with it.

/// The aspects of an image: what a texel holds. A colour format has the colour aspect, a depth or stencil
/// format has the depth aspect, the stencil aspect or both.
public struct ImageAspects: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let color = ImageAspects(rawValue: 1)
  public static let depth = ImageAspects(rawValue: 2)
  public static let stencil = ImageAspects(rawValue: 4)
  public static let depthStencil = ImageAspects(rawValue: 6)

  public var isEmpty: Bool { rawValue == 0 }
  public func contains(_ other: ImageAspects) -> Bool { rawValue & other.rawValue == other.rawValue }
  public static func | (a: ImageAspects, b: ImageAspects) -> ImageAspects { ImageAspects(rawValue: a.rawValue | b.rawValue) }
}

/// The size of a format's texel block: `width` by `height` texels held in `bytes` bytes. An uncompressed format's
/// block is one texel.
public struct TexelBlock: Sendable, Equatable {
  public var width: Int
  public var height: Int
  public var bytes: Int
  public init(width: Int, height: Int, bytes: Int) {
    self.width = width
    self.height = height
    self.bytes = bytes
  }
}

/// How a format's texels are read and written by a shader, which the clears and the blits are held to.
public enum ChannelClass: Sendable, Equatable {
  /// Read as floating point: unorm, snorm, sRGB and float formats, and depth.
  case float
  case uint
  case sint
}

/// The numeric type of a format's colour channels (the Vulkan spec's numeric formats).
public enum NumericType: Sendable, Equatable {
  case unorm, snorm, uint, sint, float, ufloat, srgb
}

/// An ASTC block's size in texels.
public enum ASTCBlock: Sendable, Equatable {
  case b4x4, b5x4, b5x5, b6x5, b6x6, b8x5, b8x6, b8x8, b10x5, b10x6, b10x8, b10x10, b12x10, b12x12

  public var width: Int {
    switch self {
    case .b4x4: 4
    case .b5x4, .b5x5: 5
    case .b6x5, .b6x6: 6
    case .b8x5, .b8x6, .b8x8: 8
    case .b10x5, .b10x6, .b10x8, .b10x10: 10
    case .b12x10, .b12x12: 12
    }
  }

  public var height: Int {
    switch self {
    case .b4x4, .b5x4: 4
    case .b5x5, .b6x5, .b8x5, .b10x5: 5
    case .b6x6, .b8x6, .b10x6: 6
    case .b8x8, .b10x8: 8
    case .b10x10, .b12x10: 10
    case .b12x12: 12
    }
  }

  public static var all: [ASTCBlock] {
    [.b4x4, .b5x4, .b5x5, .b6x5, .b6x6, .b8x5, .b8x6, .b8x8, .b10x5, .b10x6, .b10x8, .b10x10, .b12x10, .b12x12]
  }
}

/// The families of compressed formats a device may offer.
public enum CompressedFamily: Sendable, Equatable { case astc, etc2, bc }

public enum PixelFormat: Sendable, Equatable {
  // One byte a channel.
  case r8, r8snorm, r8uint, r8sint
  case rg8, rg8snorm, rg8uint, rg8sint
  case rgba8, rgba8snorm, rgba8uint, rgba8sint
  /// rgba8 whose bytes are sRGB.
  case rgba8srgb
  case bgra8
  /// bgra8 whose bytes are sRGB: sampled and blended in light (D110).
  case bgra8srgb
  // Two bytes a channel.
  case r16float, r16uint, r16sint
  case rg16float, rg16uint, rg16sint
  case rgba16float, rgba16uint, rgba16sint
  // Four bytes a channel.
  case r32float, r32uint, r32sint
  case rg32float, rg32uint, rg32sint
  case rgba32float, rgba32uint, rgba32sint
  // Packed.
  /// Ten bits of each colour channel and two of alpha (Vulkan's A2B10G10R10).
  case rgb10a2unorm
  /// Unsigned floats of eleven, eleven and ten bits (B10G11R11).
  case rg11b10float
  /// Three nine-bit mantissas with a shared five-bit exponent (E5B9G9R9).
  case rgb9e5
  // Depth and stencil.
  case depth16, depth32f, depth24stencil8, depth32fstencil8, stencil8
  // Compressed.
  case astc(ASTCBlock)
  case astcSRGB(ASTCBlock)
  case etc2rgb8, etc2rgb8srgb, etc2rgb8a1, etc2rgb8a1srgb, etc2rgba8, etc2rgba8srgb
  case eacR11, eacR11snorm, eacRG11, eacRG11snorm
  case bc1rgb, bc1rgbsrgb, bc1rgba, bc1rgbasrgb, bc2, bc2srgb, bc3, bc3srgb
  case bc4, bc4snorm, bc5, bc5snorm, bc6hufloat, bc6hsfloat, bc7, bc7srgb

  /// Every format the core names.
  public static var all: [PixelFormat] {
    var f: [PixelFormat] = [
      .r8, .r8snorm, .r8uint, .r8sint, .rg8, .rg8snorm, .rg8uint, .rg8sint,
      .rgba8, .rgba8snorm, .rgba8uint, .rgba8sint, .rgba8srgb, .bgra8, .bgra8srgb,
      .r16float, .r16uint, .r16sint, .rg16float, .rg16uint, .rg16sint, .rgba16float, .rgba16uint, .rgba16sint,
      .r32float, .r32uint, .r32sint, .rg32float, .rg32uint, .rg32sint, .rgba32float, .rgba32uint, .rgba32sint,
      .rgb10a2unorm, .rg11b10float, .rgb9e5,
      .depth16, .depth32f, .depth24stencil8, .depth32fstencil8, .stencil8,
      .etc2rgb8, .etc2rgb8srgb, .etc2rgb8a1, .etc2rgb8a1srgb, .etc2rgba8, .etc2rgba8srgb,
      .eacR11, .eacR11snorm, .eacRG11, .eacRG11snorm,
      .bc1rgb, .bc1rgbsrgb, .bc1rgba, .bc1rgbasrgb, .bc2, .bc2srgb, .bc3, .bc3srgb,
      .bc4, .bc4snorm, .bc5, .bc5snorm, .bc6hufloat, .bc6hsfloat, .bc7, .bc7srgb,
    ]
    for b in ASTCBlock.all {
      f.append(.astc(b))
      f.append(.astcSRGB(b))
    }
    return f
  }

  /// The texel block: its extent in texels and its size in bytes, as the Vulkan specification gives them (a combined
  /// depth and stencil format's is the whole texel: five bytes for depth32fstencil8).
  public var texelBlock: TexelBlock {
    switch self {
    case .r8, .r8snorm, .r8uint, .r8sint, .stencil8: TexelBlock(width: 1, height: 1, bytes: 1)
    case .rg8, .rg8snorm, .rg8uint, .rg8sint, .r16float, .r16uint, .r16sint, .depth16:
      TexelBlock(width: 1, height: 1, bytes: 2)
    case .rgba8, .rgba8snorm, .rgba8uint, .rgba8sint, .rgba8srgb, .bgra8, .bgra8srgb, .rg16float, .rg16uint, .rg16sint,
      .r32float, .r32uint, .r32sint, .rgb10a2unorm, .rg11b10float, .rgb9e5, .depth32f, .depth24stencil8:
      TexelBlock(width: 1, height: 1, bytes: 4)
    case .rgba16float, .rgba16uint, .rgba16sint, .rg32float, .rg32uint, .rg32sint:
      TexelBlock(width: 1, height: 1, bytes: 8)
    case .rgba32float, .rgba32uint, .rgba32sint: TexelBlock(width: 1, height: 1, bytes: 16)
    case .depth32fstencil8: TexelBlock(width: 1, height: 1, bytes: 5)
    case .astc(let b), .astcSRGB(let b): TexelBlock(width: b.width, height: b.height, bytes: 16)
    case .etc2rgb8, .etc2rgb8srgb, .etc2rgb8a1, .etc2rgb8a1srgb, .eacR11, .eacR11snorm, .bc1rgb, .bc1rgbsrgb, .bc1rgba,
      .bc1rgbasrgb, .bc4, .bc4snorm:
      TexelBlock(width: 4, height: 4, bytes: 8)
    case .etc2rgba8, .etc2rgba8srgb, .eacRG11, .eacRG11snorm, .bc2, .bc2srgb, .bc3, .bc3srgb, .bc5, .bc5snorm, .bc6hufloat,
      .bc6hsfloat, .bc7, .bc7srgb:
      TexelBlock(width: 4, height: 4, bytes: 16)
    }
  }

  /// What a texel holds.
  public var aspects: ImageAspects {
    switch self {
    case .depth16, .depth32f: .depth
    case .depth24stencil8, .depth32fstencil8: .depthStencil
    case .stencil8: .stencil
    default: .color
    }
  }

  public var isCompressed: Bool { family != nil }

  /// The compressed family of the format, nil for the others.
  public var family: CompressedFamily? {
    switch self {
    case .astc, .astcSRGB: .astc
    case .etc2rgb8, .etc2rgb8srgb, .etc2rgb8a1, .etc2rgb8a1srgb, .etc2rgba8, .etc2rgba8srgb, .eacR11, .eacR11snorm, .eacRG11,
      .eacRG11snorm:
      .etc2
    case .bc1rgb, .bc1rgbsrgb, .bc1rgba, .bc1rgbasrgb, .bc2, .bc2srgb, .bc3, .bc3srgb, .bc4, .bc4snorm, .bc5, .bc5snorm,
      .bc6hufloat, .bc6hsfloat, .bc7, .bc7srgb:
      .bc
    default: nil
    }
  }

  public var hasDepth: Bool { aspects.contains(.depth) }
  public var hasStencil: Bool { aspects.contains(.stencil) }
  public var isDepthStencil: Bool { !aspects.contains(.color) }

  /// The numeric type of the format's colour channels (a depth format's is the depth's; a stencil's is uint).
  public var numericType: NumericType {
    switch self {
    case .r8, .rg8, .rgba8, .bgra8, .rgb10a2unorm, .depth16, .depth24stencil8, .eacR11, .eacRG11, .bc4, .bc5, .bc7, .bc1rgb,
      .bc1rgba, .bc2, .bc3, .etc2rgb8, .etc2rgb8a1, .etc2rgba8, .astc:
      .unorm
    case .r8snorm, .rg8snorm, .rgba8snorm, .eacR11snorm, .eacRG11snorm, .bc4snorm, .bc5snorm: .snorm
    case .r8uint, .rg8uint, .rgba8uint, .r16uint, .rg16uint, .rgba16uint, .r32uint, .rg32uint, .rgba32uint, .stencil8: .uint
    case .r8sint, .rg8sint, .rgba8sint, .r16sint, .rg16sint, .rgba16sint, .r32sint, .rg32sint, .rgba32sint: .sint
    case .r16float, .rg16float, .rgba16float, .r32float, .rg32float, .rgba32float, .depth32f, .depth32fstencil8, .bc6hsfloat:
      .float
    case .rg11b10float, .rgb9e5, .bc6hufloat: .ufloat
    case .rgba8srgb, .bgra8srgb, .etc2rgb8srgb, .etc2rgb8a1srgb, .etc2rgba8srgb, .bc1rgbsrgb, .bc1rgbasrgb, .bc2srgb,
      .bc3srgb, .bc7srgb, .astcSRGB:
      .srgb
    }
  }

  public var isSRGB: Bool { numericType == .srgb }

  /// How a shader reads and a clear writes the format's channels.
  public var channelClass: ChannelClass {
    switch numericType {
    case .uint: .uint
    case .sint: .sint
    default: .float
    }
  }

  /// Bytes of a texel of an uncompressed colour format: the size of its block. A compressed format has no such size
  /// (0): its sizes are in blocks (`texelBlock`, `ImageDescriptor.byteSize`).
  public var bytesPerPixel: Int { isCompressed ? 0 : texelBlock.bytes }

  /// Bytes of one texel of one aspect in a buffer, for the copies that name an aspect: depth32fstencil8's depth is four
  /// bytes and its stencil one, depth24stencil8's depth is four (the 24 bits in the low of 32) and its stencil one.
  /// 0 where the format lacks the aspect or the aspect is not one.
  public func bytesPerTexel(aspect: ImageAspects) -> Int {
    if aspect == .color { return aspects.contains(.color) && !isCompressed ? texelBlock.bytes : 0 }
    if aspect == .stencil { return hasStencil ? 1 : 0 }
    if aspect == .depth {
      switch self {
      case .depth16: return 2
      case .depth32f, .depth24stencil8, .depth32fstencil8: return 4
      default: return 0
      }
    }
    return 0
  }

  /// Blocks across and down a `width` by `height` extent (the last block may be partly outside it).
  public func blocks(width: Int, height: Int) -> (across: Int, down: Int) {
    let b = texelBlock
    return ((width + b.width - 1) / b.width, (height + b.height - 1) / b.height)
  }

  /// Bytes of a tightly packed `width` by `height` by `depth` extent of one aspect, each row of whole blocks.
  public func byteSize(width: Int, height: Int, depth: Int = 1, aspect: ImageAspects? = nil) -> Int {
    let (across, down) = blocks(width: width, height: height)
    if isCompressed || aspect == nil || aspects == .color { return across * down * depth * texelBlock.bytes }
    return across * down * depth * bytesPerTexel(aspect: aspect!)
  }
}

// MARK: Format capabilities

/// The sample counts a device offers, as a set of the powers of two from 1 to 64.
public struct SampleCounts: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let none = SampleCounts(rawValue: 0)
  public static let one = SampleCounts(rawValue: 1)
  public static let two = SampleCounts(rawValue: 2)
  public static let four = SampleCounts(rawValue: 4)
  public static let eight = SampleCounts(rawValue: 8)
  public static let sixteen = SampleCounts(rawValue: 16)
  /// 1, 2, 4 and 8.
  public static let upToEight = SampleCounts(rawValue: 15)
  /// 1 and 2.
  public static let upToTwo = SampleCounts(rawValue: 3)
  /// 1, 2 and 4.
  public static let upToFour = SampleCounts(rawValue: 7)

  /// Whether `samples` (1, 2, 4, 8, 16, 32 or 64) is in the set.
  public func contains(_ samples: UInt32) -> Bool {
    guard samples > 0, samples <= 64, samples & (samples - 1) == 0 else { return false }
    return rawValue & samples != 0
  }

  /// The most samples in the set (0 for the empty set).
  public var maximum: UInt32 { rawValue == 0 ? 0 : UInt32(1) << UInt32(31 - rawValue.leadingZeroBitCount) }
}

/// What a device does with a format. Each is false for a format the device doesn't list. The sample counts are the
/// counts each use offers (always including one).
public struct FormatCapabilities: Sendable, Equatable {
  /// A shader can sample an image of this format (`ImageUsage.sampled`).
  public var sampled = false
  /// A sampler may filter it linearly (and a blit may).
  public var filterable = false
  /// A colour attachment (`ImageUsage.renderTarget`).
  public var renderTarget = false
  /// A colour attachment of the format can be blended into.
  public var blendable = false
  /// A shader can read and write it as a storage image (`ImageUsage.storage`).
  public var storage = false
  /// A shader can use atomic operations on it as a storage image.
  public var storageAtomic = false
  /// A depth or stencil attachment (`ImageUsage.depthStencilTarget`).
  public var depthTarget = false
  /// The source and destination of a blit.
  public var blitSource = false
  public var blitDestination = false
  /// A `BufferView` of the format may be a uniform texel buffer (fetched by a shader).
  public var texelBuffer = false
  /// A `BufferView` of the format may be a storage texel buffer (read and written by a shader), and one that takes atomics.
  public var storageTexelBuffer = false
  public var storageTexelBufferAtomic = false
  public var sampledSamples: SampleCounts = .one
  public var renderSamples: SampleCounts = .one
  public var storageSamples: SampleCounts = .one
  public var depthSamples: SampleCounts = .one
  public init() {}

  /// The capabilities of a format a client that doesn't know more can use as a colour render target and a texture: what the
  /// core had of its four formats.
  public static var colorTarget: FormatCapabilities {
    var c = FormatCapabilities()
    c.sampled = true
    c.filterable = true
    c.renderTarget = true
    c.blendable = true
    c.blitSource = true
    c.blitDestination = true
    return c
  }
}

extension DeviceLimits {
  /// What the device does with `format`: nothing, for a format it doesn't list.
  public func formats(_ format: PixelFormat) -> FormatCapabilities {
    for e in formatTable where e.format == format { return e.capabilities }
    return FormatCapabilities()
  }

  /// Lists `format` with `capabilities` (replacing an earlier entry): what a backend does at start.
  public mutating func setFormat(_ format: PixelFormat, _ capabilities: FormatCapabilities) {
    for i in 0..<formatTable.count where formatTable[i].format == format {
      formatTable[i].capabilities = capabilities
      return
    }
    formatTable.append(FormatEntry(format: format, capabilities: capabilities))
  }
}

/// One format's place in a device's table.
public struct FormatEntry: Sendable, Equatable {
  public var format: PixelFormat
  public var capabilities: FormatCapabilities
  public init(format: PixelFormat, capabilities: FormatCapabilities) {
    self.format = format
    self.capabilities = capabilities
  }
}
