// SPDX-License-Identifier: BSD-3-Clause

// The glyph atlas (M6h): glyphs' bitmaps (coverage, a byte a pixel) or
// distance fields (four bytes a texel) packed into one texture, which a
// renderer uploads (the dirty rectangle since it last asked) and samples.
// Entries are placed on shelves (rows as tall as the first glyph put on
// them, the next placed beside the last), a texel of gap between them so
// that filtering never reads a neighbour. Found by key through an open
// addressing table over parallel arrays: no Dictionary, which tier 0
// can't have. When the atlas is full it's cleared and its generation
// moves on: a renderer finds its glyphs again each frame (cheap: a hash
// and a compare), so nothing it holds goes stale.

/// What an entry holds: a font (the caller's number for it), a glyph, a
/// size, a subpixel position, and whether it's coverage or a field.
public struct GlyphKey: Equatable, Sendable {
  public var font: UInt32
  public var glyph: UInt32
  /// Pixels per em in 64ths (coverage), or texels per em (a field).
  public var size: UInt32
  /// The pen's x position in quarter pixels (coverage), 0 for a field.
  public var subpixel: UInt8
  public var field: Bool

  public init(font: UInt32, glyph: UInt32, size: UInt32, subpixel: UInt8 = 0, field: Bool = false) {
    self.font = font
    self.glyph = glyph
    self.size = size
    self.subpixel = subpixel
    self.field = field
  }

  var hash: UInt64 {
    func mix(_ h: UInt64, _ v: UInt64) -> UInt64 {
      let m = (h ^ v) &* 0x100_0000_01B3
      return m ^ m >> 29
    }
    let h = mix(mix(mix(0xCBF2_9CE4_8422_2325, UInt64(font)), UInt64(glyph)), UInt64(size))
    return mix(h, UInt64(subpixel) << 1 | (field ? 1 : 0))
  }
}

/// Where an entry is: its rectangle in the atlas, and where it goes
/// against the pen and the baseline (as its bitmap's `left` and `top`).
public struct AtlasRegion: Equatable, Sendable {
  public var x: UInt16
  public var y: UInt16
  public var width: UInt16
  public var height: UInt16
  public var left: Int16
  public var top: Int16
}

public struct Atlas: Sendable {
  public let width: Int
  public let height: Int
  public let bytesPerPixel: Int
  /// Rows from the top, `width * bytesPerPixel` bytes each.
  public private(set) var pixels: [UInt8]
  /// Moves on each time the atlas is cleared.
  public private(set) var generation = 0
  /// What changed since `takeDirty`: x, y, width, height.
  var dirty: (x0: Int, y0: Int, x1: Int, y1: Int)?

  struct Shelf {
    var y: Int
    var height: Int
    var x: Int
  }

  var shelves: [Shelf] = []
  var keys: [GlyphKey] = []
  var regions: [AtlasRegion] = []
  /// Indices into keys and regions, -1 for none; a power of two long.
  var table: [Int32]

  public init(width: Int, height: Int, bytesPerPixel: Int) {
    self.width = width
    self.height = height
    self.bytesPerPixel = bytesPerPixel
    pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    table = [Int32](repeating: -1, count: 1024)
  }

  public var count: Int { keys.count }

  /// The entry for `key`, if the atlas holds it.
  public func find(_ key: GlyphKey) -> AtlasRegion? {
    let mask = table.count - 1
    var slot = Int(truncatingIfNeeded: key.hash) & mask
    while true {
      let i = Int(table[slot])
      if i < 0 { return nil }
      if keys[i] == key { return regions[i] }
      slot = (slot + 1) & mask
    }
  }

  /// Places a `w` by `h` image whose rows `row(y, into:)` writes (its
  /// `w * bytesPerPixel` bytes from the given offset of `pixels`), placed
  /// against the pen as `left`, `top`. Nil if it can't fit even an empty
  /// atlas; if only this one is full, it's cleared first.
  public mutating func add(_ key: GlyphKey, width w: Int, height h: Int, left: Int, top: Int,
                           rows: (Int, inout [UInt8], Int) -> Void) -> AtlasRegion?
  {
    guard w + 1 <= width, h + 1 <= height, w < 65536, h < 65536 else { return nil }
    var place = allocate(w, h)
    if place == nil {
      clear()
      place = allocate(w, h)
    }
    guard let (x, y) = place else { return nil }
    for r in 0..<h { rows(r, &pixels, ((y + r) * width + x) * bytesPerPixel) }
    let region = AtlasRegion(x: UInt16(x), y: UInt16(y), width: UInt16(w), height: UInt16(h),
                             left: Int16(clamping: left), top: Int16(clamping: top))
    if let d = dirty {
      dirty = (min(d.x0, x), min(d.y0, y), max(d.x1, x + w), max(d.y1, y + h))
    } else {
      dirty = (x, y, x + w, y + h)
    }
    if (keys.count + 1) * 2 > table.count { grow() }
    keys.append(key)
    regions.append(region)
    insert(keys.count - 1)
    return region
  }

  /// The rectangle changed since the last call (x, y, width, height), to
  /// upload; nil if nothing has.
  public mutating func takeDirty() -> (x: Int, y: Int, width: Int, height: Int)? {
    defer { dirty = nil }
    return dirty.map { ($0.x0, $0.y0, $0.x1 - $0.x0, $0.y1 - $0.y0) }
  }

  /// Empties the atlas (its pixels too, so stale texels never show).
  public mutating func clear() {
    shelves.removeAll(keepingCapacity: true)
    keys.removeAll(keepingCapacity: true)
    regions.removeAll(keepingCapacity: true)
    for i in 0..<table.count { table[i] = -1 }
    for i in 0..<pixels.count { pixels[i] = 0 }
    dirty = (0, 0, width, height)
    generation += 1
  }

  /// A place for `w` by `h` (and a texel's gap right and below): on the
  /// first shelf it fits (no more than a third taller than it needs), else
  /// on a new shelf.
  mutating func allocate(_ w: Int, _ h: Int) -> (Int, Int)? {
    let gw = w + 1, gh = h + 1
    for k in 0..<shelves.count where shelves[k].height >= gh && shelves[k].height * 3 <= gh * 4 + 3
      && shelves[k].x + gw <= width
    {
      let x = shelves[k].x
      shelves[k].x += gw
      return (x, shelves[k].y)
    }
    let y = shelves.last.map { $0.y + $0.height } ?? 0
    guard y + gh <= height else { return nil }
    shelves.append(Shelf(y: y, height: gh, x: gw))
    return (0, y)
  }

  mutating func insert(_ i: Int) {
    let mask = table.count - 1
    var slot = Int(truncatingIfNeeded: keys[i].hash) & mask
    while table[slot] >= 0 { slot = (slot + 1) & mask }
    table[slot] = Int32(i)
  }

  mutating func grow() {
    table = [Int32](repeating: -1, count: table.count * 2)
    for i in 0..<keys.count { insert(i) }
  }
}
