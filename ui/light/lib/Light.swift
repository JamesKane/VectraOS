// SPDX-License-Identifier: BSD-3-Clause

// Light (D110): every blend in linear light. Pixels are sRGB bytes; a
// blend decodes each channel through a table to linear light in 16 bits,
// blends there, and encodes the result's top 12 bits back through another
// table. lightgen (ui/light/gen) writes the tables from the sRGB formula
// on the host, since tier 0 has no libm, and every byte decoded encodes
// back to itself. A blend at full coverage, or none, doesn't touch them.
// Premultiplied alpha is premultiplied in light: a channel's byte encodes
// its light already times the alpha.

public enum Light {
  /// An sRGB byte (the low 8 bits of `byte`) as linear light, 0-65535.
  @inline(__always) public static func decode(_ byte: UInt32) -> UInt32 { UInt32(decodeTable[Int(byte & 0xFF)]) }

  /// Linear light (0-65535; more is 65535) as an sRGB byte.
  @inline(__always) public static func encode(_ light: UInt32) -> UInt32 {
    UInt32(encodeTable[Int(min(light, 0xFFFF) >> 4)])
  }

  /// `color` over `under` (0xRRGGBB), `coverage` of it (0-255).
  @inline(__always) public static func over(_ color: UInt32, _ under: UInt32, coverage: UInt32) -> UInt32 {
    if coverage >= 255 { return color & 0xFF_FFFF }
    if coverage == 0 { return under & 0xFF_FFFF }
    let na = 255 - coverage
    // (Swift's << binds tighter than * and /: the parentheses matter.)
    @inline(__always) func ch(_ s: UInt32) -> UInt32 {
      encode((decode(color >> s) * coverage + decode(under >> s) * na + 127) / 255) << s
    }
    return ch(16) | ch(8) | ch(0)
  }

  /// A premultiplied pixel (0xAARRGGBB) over `under` (0xRRGGBB).
  @inline(__always) public static func over(premultiplied p: UInt32, _ under: UInt32) -> UInt32 {
    let a = p >> 24
    if a >= 255 { return p & 0xFF_FFFF }
    let na = 255 - a
    @inline(__always) func ch(_ s: UInt32) -> UInt32 {
      encode(decode(p >> s) + (decode(under >> s) * na + 127) / 255) << s
    }
    return ch(16) | ch(8) | ch(0)
  }

  /// A straight pixel (0xAARRGGBB) over `under` (0xRRGGBB).
  @inline(__always) public static func over(straight p: UInt32, _ under: UInt32) -> UInt32 {
    over(p, under, coverage: p >> 24)
  }

  /// Two colours (0xAARRGGBB) mixed, `t` (0-255) of the second: the
  /// channels in light, the alpha as it is.
  public static func mix(_ a: UInt32, _ b: UInt32, _ t: UInt32) -> UInt32 {
    let t = min(t, 255)
    let alpha = ((a >> 24) * (255 - t) + (b >> 24) * t + 127) / 255
    return alpha << 24 | over(b, a, coverage: t)
  }

  /// A colour's (0xRRGGBB) luminance, in light: BT.709's weights, in
  /// ten-thousandths.
  @inline(__always) public static func luminance(_ c: UInt32) -> UInt32 {
    2126 * decode(c >> 16) + 7152 * decode(c >> 8) + 722 * decode(c)
  }

  /// A glyph's `coverage` (0-255) of `color` over `under`, at `alpha`
  /// (0-255): the coverage through `contrast`'s curve, then blended.
  @inline(__always) public static func overText(_ color: UInt32, _ under: UInt32, coverage: Int, alpha: UInt32 = 255,
                                                contrast: TextContrast) -> UInt32
  {
    guard coverage > 0 else { return under & 0xFF_FFFF }
    let c = contrast.apply(coverage, darker: luminance(color) < luminance(under))
    return over(color, under, coverage: (UInt32(c) * min(alpha, 255) + 127) / 255)
  }
}

/// The `text.contrast` knob (D110): a curve a glyph's coverage takes
/// before it is blended. Blended in light, ink darker than its ground
/// draws thinner than the bytes' blend drew it, and lighter ink bolder,
/// so the curve raises coverage, as 1 - (1 - c)^g, where the ink is
/// darker, and lowers it, as c^g, where it is lighter; g rises from 1 (the
/// coverage as it is) at setting 0 to 3 at 1. lightgen writes a table of
/// 256 for each setting in twentieths.
public struct TextContrast: Equatable, Sendable {
  /// The setting in twentieths, 0-20.
  public let step: Int

  /// The base theme's setting: its body text keeps the bytes' blend's
  /// weight (UICore's tests choose it).
  public static let standard = TextContrast(step: 12)

  public init(step: Int) { self.step = min(max(step, 0), 20) }

  /// A setting from 0 to 1, as the knob's value is written, to the
  /// nearest twentieth.
  public init(_ setting: Float) { self.init(step: Int(min(max(setting, 0), 1) * 20 + 0.5)) }

  /// Coverage (0-255) through the curve: raised for ink `darker` than
  /// what's under it, lowered otherwise.
  @inline(__always) public func apply(_ coverage: Int, darker: Bool) -> Int {
    let c = min(max(coverage, 0), 255)
    return darker ? Int(TextContrast.curves[step * 256 + c]) : 255 - Int(TextContrast.curves[step * 256 + 255 - c])
  }
}
