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
