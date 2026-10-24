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

  /// A glyph's row of `coverage` (a byte a pixel, 0-255) in `ink` over
  /// `count` pixels of `target` (Light's `overText`). Pixels it doesn't
  /// cover are left as they are, eight at a time where a row is clear.
  /// The ink keeps what it gave for each coverage over what was last
  /// under it, so text on one ground blends each coverage once.
  public static func overText(_ ink: inout TextInk, coverage: UnsafePointer<UInt8>,
                              _ target: UnsafeMutablePointer<UInt32>, _ count: Int)
  {
    var i = 0
    while i < count {
      if i &+ 8 <= count, unsafe UnsafeRawPointer(coverage + i).loadUnaligned(as: UInt64.self) == 0 {
        i &+= 8
        continue
      }
      let c = Int(unsafe coverage[i])
      if c > 0 { unsafe target[i] = ink.over(unsafe target[i], coverage: c) }
      i &+= 1
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

    public init() { kept[0].generation = 1 }

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

    /// The ink over `under` at `coverage` (1-255).
    @inline(__always) mutating func over(_ under: UInt32, coverage c: Int) -> UInt32 {
      if under != self.under {
        self.under = under
        choose()
      }
      let e = blended[slot << 8 | c]
      if UInt32(truncatingIfNeeded: e >> 32) == generation { return UInt32(truncatingIfNeeded: e) }
      let p = Light.overText(color, under, coverage: c, alpha: alpha, contrast: contrast)
      blended[slot << 8 | c] = UInt64(generation) << 32 | UInt64(p)
      return p
    }
  }
}
