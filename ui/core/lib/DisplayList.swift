// SPDX-License-Identifier: BSD-3-Clause

// The UI Kit's display list (M6i): a frame as packed quads, in the layout
// the GPU's shader reads (64 bytes each, pinned by a test), filled again
// each frame into kept storage. A quad is a shape (a rectangle, its
// corners rounded, and any of them cut at 45° as the storyboard's chrome
// cuts one corner at a time; filled, bordered, glowing past its edge:
// drawn from its signed distance, desktop.md §6) or a glyph (a region of the
// glyph atlas: coverage, or a distance field drawn at any size) or an
// image (a region of the colour atlas: a picture or an icon), or a
// material over a shape's area (theming.md §2.2): a gradient, a bevel's
// band, or stripes, checks or dots. Colours are 0xAARRGGBB, alpha the
// opacity.

public struct UIQuad: Equatable, Sendable {
  /// The box, in pixels (a glyph's: where its atlas region goes).
  public var x: Float
  public var y: Float
  public var width: Float
  public var height: Float
  /// A shape's corner radius.
  public var corner: Float
  /// A shape's border, inside its edge; a bevel's band; a pattern's
  /// pitch.
  public var border: Float
  /// How far a shape's glow reaches past its edge.
  public var glow: Float
  /// A field glyph's texels per pixel; a gradient's angle, in degrees (0
  /// left to right, 90 top to bottom).
  public var scale: Float
  public var kind: UInt32
  public var fill: UInt32
  public var stroke: UInt32
  public var glowColor: UInt32
  /// A glyph's region of its atlas.
  public var atlasX: UInt16
  public var atlasY: UInt16
  public var atlasWidth: UInt16
  public var atlasHeight: UInt16
  /// A shape's corner cuts, in pixels along each side: top left, top
  /// right, bottom right, bottom left, a byte each from the low one.
  public var cuts: UInt32
  var pad0: UInt32 = 0

  /// Kinds: an image is a region of the colour atlas (ImageCache),
  /// texel for pixel, its alpha times `fill`'s. The materials fill a
  /// shape's area (its box, corners and cuts) and draw no border or glow:
  /// a gradient from `fill` to `stroke` at `scale` degrees, mixed in
  /// light; a bevel's band, `border` pixels inside the edge, `fill` where
  /// the edge faces the light (from the top left) and `stroke` where it
  /// faces away; stripes (at 45°, down to the right), checks or dots of
  /// `fill` and `stroke`, `border` pixels a period, from the box's corner.
  public static let shape: UInt32 = 0, coverageGlyph: UInt32 = 2, fieldGlyph: UInt32 = 3, image: UInt32 = 4,
    gradient: UInt32 = 5, bevel: UInt32 = 6, stripes: UInt32 = 7, checks: UInt32 = 8, dots: UInt32 = 9

  /// Corner cuts packed: top left, top right, bottom right, bottom left.
  public static func cuts(topLeft: Float = 0, topRight: Float = 0, bottomRight: Float = 0, bottomLeft: Float = 0)
    -> UInt32
  {
    func b(_ v: Float) -> UInt32 { UInt32(min(max(v + 0.5, 0), 255)) }
    return b(topLeft) | b(topRight) << 8 | b(bottomRight) << 16 | b(bottomLeft) << 24
  }

  /// The cut at a corner (0 top left, 1 top right, 2 bottom right, 3 bottom left).
  public func cut(_ corner: Int) -> Float { Float((cuts >> UInt32(8 * corner)) & 0xFF) }

  public init(x: Float, y: Float, width: Float, height: Float, kind: UInt32, fill: UInt32, corner: Float = 0,
              cuts: UInt32 = 0, border: Float = 0, stroke: UInt32 = 0, glow: Float = 0, glowColor: UInt32 = 0,
              scale: Float = 1, atlasX: UInt16 = 0, atlasY: UInt16 = 0, atlasWidth: UInt16 = 0, atlasHeight: UInt16 = 0)
  {
    self.cuts = cuts
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.corner = corner
    self.border = border
    self.glow = glow
    self.scale = scale
    self.kind = kind
    self.fill = fill
    self.stroke = stroke
    self.glowColor = glowColor
    self.atlasX = atlasX
    self.atlasY = atlasY
    self.atlasWidth = atlasWidth
    self.atlasHeight = atlasHeight
  }

  public var isGlyph: Bool { kind == UIQuad.coverageGlyph || kind == UIQuad.fieldGlyph }
}

/// A frame's quads in draw order, the first drawn first, and where they
/// are clipped: a side table of ranges, each from a quad's index on, with
/// a rectangle in pixels (x0, y0, x1, y1) or none (as a GPU's scissor).
public struct DisplayList: Sendable {
  public var quads: [UIQuad] = []
  public var clips: [(first: Int, x0: Float, y0: Float, x1: Float, y1: Float)] = []

  public init() {}

  /// Empties it, keeping its storage.
  public mutating func reset() {
    quads.removeAll(keepingCapacity: true)
    clips.removeAll(keepingCapacity: true)
  }

  public mutating func append(_ q: UIQuad) { quads.append(q) }

  /// The quads from here on are clipped to the rectangle (in pixels), or
  /// not at all (nil).
  public mutating func clip(_ r: (x0: Float, y0: Float, x1: Float, y1: Float)?) {
    let c = r ?? (-Float.infinity, -Float.infinity, Float.infinity, Float.infinity)
    if let last = clips.last, last.first == quads.count {
      clips[clips.count - 1] = (quads.count, c.0, c.1, c.2, c.3)
    } else {
      clips.append((quads.count, c.0, c.1, c.2, c.3))
    }
  }

  /// Whether two lists draw the same.
  public func same(as other: DisplayList) -> Bool {
    quads == other.quads && clips.count == other.clips.count
      && zip(clips, other.clips).allSatisfy { $0.first == $1.first && $0.x0 == $1.x0 && $0.y0 == $1.y0 && $0.x1 == $1.x1 && $0.y1 == $1.y1 }
  }
}
