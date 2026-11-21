// SPDX-License-Identifier: BSD-3-Clause

// The texel formats of valhall 05 section 5.3 as pixel format words (index, component order, sRGB) and plane clump formats:
// every row of the table in 5.3.1 the core names, the depth and stencil planes of 5.3.2, and the block-compressed formats of
// 5.3.4. Pure data; which of them a GPU has is the TEXTURE_FEATURES word's (`CompressedFeatures`).

extension TexelFormat {
  // MARK: Colour (05 section 5.3.1)

  // The numeric families: index = group + 8 * (N - 1) + slot, groups SNORM 96, UINT 128, UNORM 160, SINT-or-F16 192; slots 3
  // (8 bits), 4 (16), 5 (32), 7 (float).
  public static let r8snorm = TexelFormat(index: 99, order: 16, bytesPerTexel: 1)
  public static let rg8 = TexelFormat(index: 171, order: 16, bytesPerTexel: 2)
  public static let rg8snorm = TexelFormat(index: 107, order: 16, bytesPerTexel: 2)
  public static let rg8ui = TexelFormat(index: 139, order: 16, bytesPerTexel: 2)
  public static let rg8i = TexelFormat(index: 203, order: 16, bytesPerTexel: 2)
  public static let rgba8snorm = TexelFormat(index: 123, order: 0, bytesPerTexel: 4)
  public static let rgba8ui = TexelFormat(index: 155, order: 0, bytesPerTexel: 4)
  public static let rgba8i = TexelFormat(index: 219, order: 0, bytesPerTexel: 4)
  public static let r16f = TexelFormat(index: 199, order: 16, bytesPerTexel: 2)
  public static let rg16f = TexelFormat(index: 207, order: 16, bytesPerTexel: 4)
  public static let rg16ui = TexelFormat(index: 140, order: 16, bytesPerTexel: 4)
  public static let rg16i = TexelFormat(index: 204, order: 16, bytesPerTexel: 4)
  public static let rgba16f = TexelFormat(index: 223, order: 0, bytesPerTexel: 8)
  public static let rgba16ui = TexelFormat(index: 156, order: 0, bytesPerTexel: 8)
  public static let rgba16i = TexelFormat(index: 220, order: 0, bytesPerTexel: 8)
  public static let r32f = TexelFormat(index: 167, order: 16, bytesPerTexel: 4)
  public static let r32ui = TexelFormat(index: 133, order: 16, bytesPerTexel: 4)
  public static let r32i = TexelFormat(index: 197, order: 16, bytesPerTexel: 4)
  public static let rg32f = TexelFormat(index: 175, order: 16, bytesPerTexel: 8)
  public static let rg32ui = TexelFormat(index: 141, order: 16, bytesPerTexel: 8)
  public static let rg32i = TexelFormat(index: 205, order: 16, bytesPerTexel: 8)
  public static let rgba32f = TexelFormat(index: 191, order: 0, bytesPerTexel: 16)
  public static let rgba32ui = TexelFormat(index: 157, order: 0, bytesPerTexel: 16)
  public static let rgba32i = TexelFormat(index: 221, order: 0, bytesPerTexel: 16)
  /// RGB10 A2 UNORM, red in the low bits (Vulkan's A2B10G10R10: 5.2.2.1).
  public static let rgb10a2 = TexelFormat(index: 67, order: 0, bytesPerTexel: 4)
  /// R11 G11 B10 float (B10G11R11 in Vulkan's name).
  public static let rg11b10f = TexelFormat(index: 89, order: 16, bytesPerTexel: 4)
  /// R9 G9 B9 E5 (E5B9G9R9).
  public static let rgb9e5 = TexelFormat(index: 91, order: 16, bytesPerTexel: 4)

  // MARK: Depth and stencil (05 sections 5.3.2 and 5.3.2.1)

  /// 16-bit depth, 32-bit float depth, and a 24-bit depth in the low bits of a 32-bit word, each its own plane; stencil is
  /// pixel format 93 with order GRBA (2), whose first component is the stencil and whose plane clump format is S8 (22).
  public static let depth16 = TexelFormat(index: 75, order: 0, bytesPerTexel: 2)
  public static let depth32f = TexelFormat(index: 76, order: 0, bytesPerTexel: 4)
  public static let depth24 = TexelFormat(index: 77, order: 0, bytesPerTexel: 4)
  public static let stencil8 = TexelFormat(index: 93, order: 2, bytesPerTexel: 1, clump: 22)

  // MARK: Block-compressed (05 section 5.3.4: the decoded interchange format, the plane's clump format)

  public static let etc2rgb8 = TexelFormat(index: 187, order: 16, bytesPerTexel: 8, clump: 32, blockWidth: 4, blockHeight: 4)
  public static let etc2rgb8srgb = TexelFormat(index: 187, order: 16, srgb: true, bytesPerTexel: 8, clump: 32, blockWidth: 4, blockHeight: 4)
  public static let etc2rgb8a1 = TexelFormat(index: 187, order: 0, bytesPerTexel: 8, clump: 38, blockWidth: 4, blockHeight: 4)
  public static let etc2rgb8a1srgb = TexelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 8, clump: 38, blockWidth: 4, blockHeight: 4)
  public static let etc2rgba8 = TexelFormat(index: 187, order: 0, bytesPerTexel: 16, clump: 37, blockWidth: 4, blockHeight: 4)
  public static let etc2rgba8srgb = TexelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 16, clump: 37, blockWidth: 4, blockHeight: 4)
  public static let eacR11 = TexelFormat(index: 164, order: 16, bytesPerTexel: 8, clump: 33, blockWidth: 4, blockHeight: 4)
  public static let eacR11snorm = TexelFormat(index: 100, order: 16, bytesPerTexel: 8, clump: 34, blockWidth: 4, blockHeight: 4)
  public static let eacRG11 = TexelFormat(index: 172, order: 16, bytesPerTexel: 16, clump: 35, blockWidth: 4, blockHeight: 4)
  public static let eacRG11snorm = TexelFormat(index: 108, order: 16, bytesPerTexel: 16, clump: 36, blockWidth: 4, blockHeight: 4)

  public static let bc1rgb = TexelFormat(index: 187, order: 16, bytesPerTexel: 8, clump: 48, blockWidth: 4, blockHeight: 4)
  public static let bc1rgbsrgb = TexelFormat(index: 187, order: 16, srgb: true, bytesPerTexel: 8, clump: 48, blockWidth: 4, blockHeight: 4)
  public static let bc1rgba = TexelFormat(index: 187, order: 0, bytesPerTexel: 8, clump: 48, blockWidth: 4, blockHeight: 4)
  public static let bc1rgbasrgb = TexelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 8, clump: 48, blockWidth: 4, blockHeight: 4)
  public static let bc2 = TexelFormat(index: 187, order: 0, bytesPerTexel: 16, clump: 49, blockWidth: 4, blockHeight: 4)
  public static let bc2srgb = TexelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 16, clump: 49, blockWidth: 4, blockHeight: 4)
  public static let bc3 = TexelFormat(index: 187, order: 0, bytesPerTexel: 16, clump: 50, blockWidth: 4, blockHeight: 4)
  public static let bc3srgb = TexelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 16, clump: 50, blockWidth: 4, blockHeight: 4)
  public static let bc4 = TexelFormat(index: 164, order: 16, bytesPerTexel: 8, clump: 51, blockWidth: 4, blockHeight: 4)
  public static let bc4snorm = TexelFormat(index: 100, order: 16, bytesPerTexel: 8, clump: 52, blockWidth: 4, blockHeight: 4)
  public static let bc5 = TexelFormat(index: 172, order: 16, bytesPerTexel: 16, clump: 53, blockWidth: 4, blockHeight: 4)
  public static let bc5snorm = TexelFormat(index: 108, order: 16, bytesPerTexel: 16, clump: 54, blockWidth: 4, blockHeight: 4)
  public static let bc6hu = TexelFormat(index: 223, order: 16, bytesPerTexel: 16, clump: 55, blockWidth: 4, blockHeight: 4)
  public static let bc6hs = TexelFormat(index: 223, order: 16, bytesPerTexel: 16, clump: 56, blockWidth: 4, blockHeight: 4)
  public static let bc7 = TexelFormat(index: 187, order: 0, bytesPerTexel: 16, clump: 57, blockWidth: 4, blockHeight: 4)
  public static let bc7srgb = TexelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 16, clump: 57, blockWidth: 4, blockHeight: 4)

  /// An ASTC 2D LDR format: the linear one decodes to 16-bit floats (index 223), the sRGB one to 8 bits (187 with the sRGB bit);
  /// the plane carries the block size.
  public static func astc(blockWidth: Int, blockHeight: Int, srgb: Bool) -> TexelFormat {
    TexelFormat(
      index: srgb ? 187 : 223, order: 0, srgb: srgb, bytesPerTexel: 16, clump: 4, blockWidth: blockWidth, blockHeight: blockHeight,
      astc: ASTCPlaneFields(blockWidth: blockWidth, blockHeight: blockHeight, wide: !srgb))
  }

  /// This format as another view of the same texels (a sRGB view of the linear bytes, or the reverse).
  public func withSRGB(_ on: Bool) -> TexelFormat {
    var f = self
    f.srgb = on
    return f
  }
}

/// The `TEXTURE_FEATURES[0]` bits of 05 section 5.4.2: which compressed formats the GPU has. A driver must not expose a
/// compressed format whose bit is clear.
public struct CompressedFeatures: Equatable, Sendable {
  public var word: UInt32
  public init(word: UInt32) { self.word = word }

  func has(_ bit: Int) -> Bool { word & (1 << UInt32(bit)) != 0 }
  public var etc2rgb8: Bool { has(1) }
  public var etc2r11: Bool { has(2) }
  public var etc2rgba8: Bool { has(3) }
  public var etc2rg11: Bool { has(4) }
  public var bc1: Bool { has(7) }
  public var bc2: Bool { has(8) }
  public var bc3: Bool { has(9) }
  public var bc4unorm: Bool { has(10) }
  public var bc4snorm: Bool { has(11) }
  public var bc5unorm: Bool { has(12) }
  public var bc5snorm: Bool { has(13) }
  public var bc6hu: Bool { has(14) }
  public var bc6hs: Bool { has(15) }
  public var bc7: Bool { has(16) }
  public var etc2r11snorm: Bool { has(17) }
  public var etc2rg11snorm: Bool { has(18) }
  public var etc2rgb8a1: Bool { has(19) }
  public var astcLDR: Bool { has(22) }
  public var astcHDR: Bool { has(23) }

  /// Every ETC2 and EAC format.
  public var etc2: Bool {
    etc2rgb8 && etc2r11 && etc2rgba8 && etc2rg11 && etc2r11snorm && etc2rg11snorm && etc2rgb8a1
  }
  /// Every BC format.
  public var bc: Bool {
    bc1 && bc2 && bc3 && bc4unorm && bc4snorm && bc5unorm && bc5snorm && bc6hu && bc6hs && bc7
  }
}
