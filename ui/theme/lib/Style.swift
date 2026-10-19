// SPDX-License-Identifier: BSD-3-Clause

// A theme's resolved form (D109): a style per class, as todhchai's UICore
// kept it (theming.md §11), every colour already 0xAARRGGBB. What the
// file says by role, the resolver has turned into colours here.

/// The typefaces a theme sets text in.
public enum FontRole: UInt8, Sendable {
  /// Headings and menus' titles.
  case display
  /// Running text.
  case body
  /// Data, code, the terminal, numbers.
  case mono
  /// Labels, tabs, buttons, column headers.
  case ui
}

/// How a surface is filled, beyond a flat colour (theming.md §2.2).
/// Resolved and checked now, drawn once the renderer has materials.
public enum Material: Equatable, Sendable {
  /// From the first colour to the second, at an angle in degrees (0 is
  /// left to right, 90 top to bottom).
  case gradient(UInt32, UInt32, angle: Float)
  /// A bevel `width` logical pixels wide, lit from the theme's light.
  case bevel(BevelKind, width: Float)
  /// Stripes, checks or dots of two colours, `pitch` logical pixels apart.
  case pattern(PatternKind, UInt32, UInt32, pitch: Float)
  /// A shadow offset by (x, y), blurred over `blur`.
  case shadow(UInt32, x: Float, y: Float, blur: Float)
}

public enum BevelKind: UInt8, Sendable { case raised, inset, groove }
public enum PatternKind: UInt8, Sendable { case stripes, checks, dots }

public struct Style: Equatable, Sendable {
  /// Background, border and text, 0xAARRGGBB (alpha 0: none).
  public var fill: UInt32
  public var stroke: UInt32
  public var ink: UInt32
  public var border: Float
  public var radius: Float
  /// Corner cuts, in pixels along each side: top left, top right, bottom
  /// right, bottom left, a byte each from the low one (UIQuad's).
  public var cuts: UInt32
  public var glow: Float
  public var glowColor: UInt32
  public var font: FontRole
  public var weight: Int
  /// Text size, in pixels an em.
  public var textSize: Float
  /// Line height, as a multiple of the size.
  public var lineHeight: Float
  /// Letter spacing, in ems (CSS's letter-spacing).
  public var tracking: Float
  public var uppercase: Bool
  /// Space between the edge and what's inside: top, right, bottom, left.
  public var padding: (top: Float, right: Float, bottom: Float, left: Float)
  /// Materials over the fill, the first drawn first.
  public var materials: [Material]

  public init(fill: UInt32 = 0, stroke: UInt32 = 0, ink: UInt32, border: Float = 0, radius: Float = 0,
              cuts: UInt32 = 0, glow: Float = 0, glowColor: UInt32 = 0, font: FontRole = .ui, weight: Int = 500,
              textSize: Float = 14.7, lineHeight: Float = 1.35, tracking: Float = 0, uppercase: Bool = false,
              padding: (Float, Float, Float, Float) = (0, 0, 0, 0), materials: [Material] = [])
  {
    self.fill = fill
    self.stroke = stroke
    self.ink = ink
    self.border = border
    self.radius = radius
    self.cuts = cuts
    self.glow = glow
    self.glowColor = glowColor
    self.font = font
    self.weight = weight
    self.textSize = textSize
    self.lineHeight = lineHeight
    self.tracking = tracking
    self.uppercase = uppercase
    self.padding = (padding.0, padding.1, padding.2, padding.3)
    self.materials = materials
  }

  public static func == (a: Style, b: Style) -> Bool {
    a.fill == b.fill && a.stroke == b.stroke && a.ink == b.ink && a.border == b.border && a.radius == b.radius
      && a.cuts == b.cuts && a.glow == b.glow && a.glowColor == b.glowColor && a.font == b.font
      && a.weight == b.weight && a.textSize == b.textSize && a.lineHeight == b.lineHeight && a.tracking == b.tracking
      && a.uppercase == b.uppercase && a.padding == b.padding && a.materials == b.materials
  }

  /// A cut at each corner, in pixels, packed as `cuts` is.
  public static func cuts(topLeft: Float = 0, topRight: Float = 0, bottomRight: Float = 0, bottomLeft: Float = 0)
    -> UInt32
  {
    func b(_ v: Float) -> UInt32 { UInt32(min(max(v + 0.5, 0), 255)) }
    return b(topLeft) | b(topRight) << 8 | b(bottomRight) << 16 | b(bottomLeft) << 24
  }

  /// Pressed, for a class whose theme doesn't say (todhchai's rule, kept):
  /// lit, its ink at 20% inside, edge and label in the ink.
  public var held: Style {
    var p = self
    p.fill = withAlpha(ink | 0xFF00_0000, percent: 20)
    p.stroke = ink
    return p
  }
}

/// A typeface for one of the roles: its family, weight and width.
public struct Typeface: Equatable, Sendable {
  public var family: String
  public var weight: Int
  /// The width axis, as a percentage of normal (100).
  public var width: Int

  public init(family: String, weight: Int = 400, width: Int = 100) {
    self.family = family
    self.weight = weight
    self.width = width
  }

  public static func == (a: Typeface, b: Typeface) -> Bool {
    a.family.utf8.elementsEqual(b.family.utf8) && a.weight == b.weight && a.width == b.width
  }
}
