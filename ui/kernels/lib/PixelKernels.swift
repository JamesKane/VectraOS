// SPDX-License-Identifier: BSD-3-Clause

// PixelKernels (D129): the UI libraries' pixel work on spans, a row, or
// what a clip leaves of one, at a time. Pixels are 32-bit words,
// 0x00RRGGBB, or 0xAARRGGBB where the source has alpha. Each kernel
// gives the same bytes as its scalar reference (Reference.swift) from the
// same inputs. These are the floor tier's, eight pixels a step through
// SIMD8<UInt32>: a fill or a copy whole, and a blend whole where all
// eight pixels are opaque or clear, and pixel by pixel through Light
// otherwise, since Light's tables are gathers the floor has no
// instruction for.

#if canImport(Light)
import Light
#endif

public enum PixelKernels {
  typealias Vector = SIMD8<UInt32>

  @inline(__always) static func load(_ p: UnsafePointer<UInt32>, _ i: Int) -> Vector {
    unsafe UnsafeRawPointer(p + i).loadUnaligned(as: Vector.self)
  }

  @inline(__always) static func store(_ p: UnsafeMutablePointer<UInt32>, _ i: Int, _ v: Vector) {
    unsafe UnsafeMutableRawPointer(p + i).storeBytes(of: v, as: Vector.self)
  }

  /// Sets `count` pixels of `target` to `color`.
  public static func fill(_ target: UnsafeMutablePointer<UInt32>, _ count: Int, _ color: UInt32) {
    let v = Vector(repeating: color)
    var i = 0
    while i &+ 8 <= count {
      unsafe store(target, i, v)
      i &+= 8
    }
    while i < count {
      unsafe target[i] = color
      i &+= 1
    }
  }

  /// Copies `count` opaque pixels from `source` to `target`, their top
  /// bytes cleared.
  public static func copyOpaque(_ target: UnsafeMutablePointer<UInt32>, _ source: UnsafePointer<UInt32>, _ count: Int) {
    let mask = Vector(repeating: 0xFF_FFFF)
    var i = 0
    while i &+ 8 <= count {
      unsafe store(target, i, load(source, i) & mask)
      i &+= 8
    }
    while i < count {
      unsafe target[i] = source[i] & 0xFF_FFFF
      i &+= 1
    }
  }

  /// `count` premultiplied pixels from `source` over `target` (Light's
  /// `over(premultiplied:_:)`).
  public static func over(premultiplied source: UnsafePointer<UInt32>, _ target: UnsafeMutablePointer<UInt32>,
                          _ count: Int)
  {
    let mask = Vector(repeating: 0xFF_FFFF)
    var i = 0
    while i &+ 8 <= count {
      let s = unsafe load(source, i)
      if (s &>> 24).min() == 255 {
        unsafe store(target, i, s & mask)
      } else if s.max() == 0 {
        // Nothing over each: Light gives back what's under, its top byte
        // cleared.
        unsafe store(target, i, load(target, i) & mask)
      } else {
        for k in i..<i &+ 8 { unsafe target[k] = Light.over(premultiplied: source[k], target[k]) }
      }
      i &+= 8
    }
    while i < count {
      unsafe target[i] = Light.over(premultiplied: source[i], target[i])
      i &+= 1
    }
  }

  /// `count` straight pixels from `source` over `target` (Light's
  /// `over(straight:_:)`).
  public static func over(straight source: UnsafePointer<UInt32>, _ target: UnsafeMutablePointer<UInt32>,
                          _ count: Int)
  {
    let mask = Vector(repeating: 0xFF_FFFF)
    var i = 0
    while i &+ 8 <= count {
      let s = unsafe load(source, i)
      let alpha = s &>> 24
      if alpha.min() == 255 {
        unsafe store(target, i, s & mask)
      } else if alpha.max() == 0 {
        unsafe store(target, i, load(target, i) & mask)
      } else {
        for k in i..<i &+ 8 { unsafe target[k] = Light.over(straight: source[k], target[k]) }
      }
      i &+= 8
    }
    while i < count {
      unsafe target[i] = Light.over(straight: source[i], target[i])
      i &+= 1
    }
  }
}

extension PixelKernels {
  /// `color` (0xRRGGBB) over `count` pixels of `target`, `coverage` of it
  /// (0-255) (Light's `over(_:_:coverage:)`). A run of pixels alike under
  /// it is blended once.
  public static func over(_ color: UInt32, coverage: UInt32, _ target: UnsafeMutablePointer<UInt32>, _ count: Int) {
    if coverage >= 255 { return unsafe fill(target, count, color & 0xFF_FFFF) }
    guard count > 0 else { return }
    var under = unsafe target[0], blended = Light.over(color, under, coverage: coverage)
    for i in 0..<count {
      let p = unsafe target[i]
      if p != under {
        under = p
        blended = Light.over(color, p, coverage: coverage)
      }
      unsafe target[i] = blended
    }
  }

  /// A glyph's `rows` rows of `coverage` (a byte a pixel, 0-255) in `ink`
  /// over `count` pixels of each of `rows` rows of `target` (Light's
  /// `overText`), the rows `coverageStride` bytes and `targetStride`
  /// pixels apart: a glyph in one call. Pixels it doesn't cover are left
  /// as they are, eight at a time where a row is clear. The ink keeps
  /// what it gave for each coverage over what was last under it, so text
  /// on one ground blends each coverage once.
  public static func overText(_ ink: inout TextInk, coverage: UnsafePointer<UInt8>,
                              _ target: UnsafeMutablePointer<UInt32>, _ count: Int, rows: Int = 1,
                              coverageStride: Int = 0, targetStride: Int = 0)
  {
    // A glyph met before in this ink over this ground, all of it: its
    // pixels as they were left then.
    var keep = -1
    if !ink.blocks.isEmpty && count > 0 && rows > 0 {
      let ground = unsafe target[0]
      var uniform = true
      for r in 0..<rows where uniform {
        let row = unsafe target + r &* targetStride
        for i in 0..<count where unsafe row[i] != ground {
          uniform = false
          break
        }
      }
      if uniform {
        let size = UInt64(count) | UInt64(rows) << 16 | UInt64(UInt32(truncatingIfNeeded: coverageStride)) << 32
        let inkKey = UInt64(ink.color) | UInt64(ink.alpha) << 24 | UInt64(ink.contrast.step) << 32
        let key = TextInk.Block(coverage: UInt(bitPattern: coverage), size: size, ink: inkKey, ground: ground, at: -1)
        var mix = key.coverage ^ UInt(inkKey) &* 0x9E37_79B9
        mix ^= UInt(ground) &* 0x85EB_CA6B ^ UInt(size)
        var h = Int(truncatingIfNeeded: (mix &* 0x2545_F491) &>> 7)
        for _ in 0..<8 {
          h &= ink.blocks.count &- 1
          let b = ink.blocks[h]
          if b.at < 0 {
            keep = h
            break
          }
          if b.coverage == key.coverage, b.size == size, b.ink == inkKey, b.ground == ground {
            ink.glyphs.withUnsafeBufferPointer { kept in
              let from = unsafe kept.baseAddress! + Int(b.at)
              for r in 0..<rows { unsafe (target + r &* targetStride).update(from: from + r &* count, count: count) }
            }
            return
          }
          h &+= 1
        }
        if keep >= 0 && ink.glyphs.count &+ count &* rows <= TextInk.keeps {
          var k = key
          k.at = Int32(ink.glyphs.count)
          ink.blocks[keep] = k
        } else {
          keep = -1
        }
      }
    }
    defer {
      if keep >= 0 {
        for r in 0..<rows {
          unsafe ink.glyphs.append(contentsOf: UnsafeBufferPointer(start: target + r &* targetStride, count: count))
        }
      }
    }
    // The ink's ground, slot and generation held here through the glyph,
    // where the stores to the target can't be thought to change them.
    var under = ink.under, base = ink.slot &<< 8, generation = ink.generation
    @inline(__always) func over(_ p: UInt32, _ c: Int) -> UInt32 {
      if p != under {
        ink.under = p
        ink.choose()
        under = p
        base = ink.slot &<< 8
        generation = ink.generation
      }
      let i = (base | c) & 1023
      let e = ink.blended[i]
      if UInt32(truncatingIfNeeded: e &>> 32) == generation { return UInt32(truncatingIfNeeded: e) }
      return ink.give(p, at: i)
    }
    // Eight coverages a word, and only those not clear visited, from
    // the word's mask of them: a glyph's clear pixels fall where no
    // branch predicts.
    let low: UInt64 = 0x7F7F_7F7F_7F7F_7F7F, high: UInt64 = 0x8080_8080_8080_8080
    for r in 0..<rows {
      let coverage = unsafe coverage + r &* coverageStride, target = unsafe target + r &* targetStride
      var i = 0
      while i &+ 8 <= count {
        let w = unsafe UnsafeRawPointer(coverage + i).loadUnaligned(as: UInt64.self)
        var m = ((w & low) &+ low | w) & high
        while m != 0 {
          let k = i &+ m.trailingZeroBitCount &>> 3
          unsafe target[k] = over(unsafe target[k], Int(unsafe coverage[k]))
          m &= m &- 1
        }
        i &+= 8
      }
      while i < count {
        let c = Int(unsafe coverage[i])
        if c > 0 { unsafe target[i] = over(unsafe target[i], c) }
        i &+= 1
      }
    }
  }

  /// A glyph's colour (0xRRGGBB), alpha (0-255) and contrast, with the
  /// pixels it gave at each coverage over the grounds it met: a renderer
  /// keeps one through a frame, and sets it for each glyph.
  public struct TextInk {
    var color: UInt32 = 0, alpha: UInt32 = 0, contrast = TextContrast(step: 0)
    var under: UInt32 = 0
    // Four inks' pixels over a ground, each in a slot of 256 coverages
    // under the generation that gave them, so text that goes from one
    // colour to another and back keeps both; a slot given to another ink
    // or ground takes a new generation, so nothing need be cleared.
    struct Kept {
      var color: UInt32 = 0, alpha: UInt32 = 0, contrast = TextContrast(step: 0)
      var under: UInt32 = 0
      var generation: UInt32 = 0
    }
    var kept = InlineArray<4, Kept>(repeating: Kept())
    var slot = 0, oldest = 1
    var generation: UInt32 = 1, latest: UInt32 = 1
    var blended = InlineArray<1024, UInt64>(repeating: 0)

    // Glyphs' pixels over a ground all one pixel, each where its coverage
    // lies, its size, ink and ground found in `blocks`, its pixels row
    // after row in `glyphs`; none kept until `keepGlyphs`.
    var blocks: [Block] = []
    var glyphs: [UInt32] = []
    static let keeps = 65536

    public init() { kept[0].generation = 1 }

    /// Keeps each glyph drawn over a ground all one pixel, to copy the
    /// next time it's drawn in this ink over that ground. Coverage at an
    /// address must not change while the ink is kept: a renderer's
    /// atlas through a frame.
    public mutating func keepGlyphs() {
      blocks = Array(repeating: Block(), count: 1024)
      glyphs.reserveCapacity(8192)
    }

    /// Draws in `color` at `alpha` through `contrast` from now on.
    public mutating func set(_ color: UInt32, alpha: UInt32, contrast: TextContrast) {
      let color = color & 0xFF_FFFF, alpha = min(alpha, 255)
      guard color != self.color || alpha != self.alpha || contrast != self.contrast else { return }
      self.color = color
      self.alpha = alpha
      self.contrast = contrast
      choose()
    }

    // The slot that keeps this ink over this ground, or the one longest
    // given, taken for it.
    mutating func choose() {
      for i in 0..<kept.count {
        let k = kept[i]
        if k.generation != 0 && k.color == color && k.alpha == alpha && k.contrast == contrast && k.under == under {
          slot = i
          generation = k.generation
          return
        }
      }
      latest &+= 1
      // A generation that wrapped could meet an old one's pixels.
      if latest == 0 {
        for i in 0..<blended.count { blended[i] = 0 }
        for i in 0..<kept.count { kept[i].generation = 0 }
        latest = 1
      }
      slot = oldest
      oldest = (oldest + 1) % kept.count
      kept[slot] = Kept(color: color, alpha: alpha, contrast: contrast, under: under, generation: latest)
      generation = latest
    }

    struct Block {
      var coverage: UInt = 0, size: UInt64 = 0, ink: UInt64 = 0
      var ground: UInt32 = 0, at: Int32 = -1
    }

    /// The ink over `under` at the coverage and slot of `blended[i]`, which
    /// didn't keep it, kept there now.
    @inline(never) mutating func give(_ under: UInt32, at i: Int) -> UInt32 {
      let p = Light.overText(color, under, coverage: i & 255, alpha: alpha, contrast: contrast)
      blended[i] = UInt64(generation) << 32 | UInt64(p)
      return p
    }
  }
}
