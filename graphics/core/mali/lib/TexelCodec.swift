// SPDX-License-Identifier: BSD-3-Clause

// Texels as floats and as bytes, on the CPU: what the copies, blits and clears of MaliDevice do to an image's memory (the images
// are linear and CPU-visible, so a step of the CPU does them in order with the GPU's passes; gpucore(2)). One codec for every
// uncompressed colour format the core names.

import GPUCore

enum TexelCodec {
  // MARK: Half and small floats

  static func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h >> 15) << 31
    let exponent = UInt32((h >> 10) & 0x1F)
    let mantissa = UInt32(h & 0x3FF)
    if exponent == 0 {
      if mantissa == 0 { return Float(bitPattern: sign) }
      var e: UInt32 = 127 - 15 + 1
      var m = mantissa
      while m & 0x400 == 0 {
        m <<= 1
        e -= 1
      }
      return Float(bitPattern: sign | e << 23 | (m & 0x3FF) << 13)
    }
    if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | mantissa << 13) }
    return Float(bitPattern: sign | (exponent + 127 - 15) << 23 | mantissa << 13)
  }

  /// Round to nearest even.
  static func floatToHalf(_ f: Float) -> UInt16 {
    let bits = f.bitPattern
    let sign = UInt16(truncatingIfNeeded: bits >> 16) & 0x8000
    let e = Int((bits >> 23) & 0xFF)
    let m = bits & 0x7F_FFFF
    if e == 0xFF { return sign | 0x7C00 | (m != 0 ? 0x200 : 0) }
    let exp = e - 127 + 15
    if exp >= 31 { return sign | 0x7C00 }
    if exp <= 0 {
      if exp < -10 { return sign }
      let full = m | 0x80_0000
      let shift = UInt32(14 - exp)
      var half = full >> shift
      let rem = full & ((1 << shift) - 1)
      let mid: UInt32 = 1 << (shift - 1)
      if rem > mid || (rem == mid && half & 1 == 1) { half += 1 }
      return sign | UInt16(truncatingIfNeeded: half)
    }
    var half = UInt32(exp) << 10 | m >> 13
    let rem = m & 0x1FFF
    if rem > 0x1000 || (rem == 0x1000 && half & 1 == 1) { half += 1 }
    return sign | UInt16(truncatingIfNeeded: half)
  }

  static func exp2i(_ n: Int) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: n + 127) << 23) }

  /// An unsigned float of a 5-bit exponent (bias 15) and `mBits` mantissa bits: the 11 and 10-bit floats.
  static func smallFloatToFloat(_ v: UInt32, mBits: UInt32) -> Float {
    let e = (v >> mBits) & 0x1F
    let m = v & ((1 << mBits) - 1)
    if e == 0 { return Float(m) / Float(1 << mBits) * 6.103515625e-05 }
    if e == 31 { return m == 0 ? Float.infinity : Float.nan }
    return (1 + Float(m) / Float(1 << mBits)) * exp2i(Int(e) - 15)
  }

  static func floatToSmallFloat(_ f: Float, mBits: UInt32) -> UInt32 {
    if !(f > 0) { return 0 }
    let top: UInt32 = 0x1E << mBits | ((1 << mBits) - 1)
    let bits = f.bitPattern
    let e = Int((bits >> 23) & 0xFF) - 127 + 15
    if e >= 31 { return top }
    if e <= 0 {
      let scaled = f / 6.103515625e-05 * Float(1 << mBits)
      return UInt32(min(scaled + 0.5, Float((1 << mBits) - 1)))
    }
    var m = (bits & 0x7F_FFFF) >> (23 - mBits)
    let rem = bits & ((1 << (23 - mBits)) - 1)
    let half: UInt32 = 1 << (22 - mBits)
    var exp = UInt32(e)
    if rem > half || (rem == half && m & 1 == 1) { m += 1 }
    if m >> mBits != 0 {
      m = 0
      exp += 1
    }
    if exp >= 31 { return top }
    return exp << mBits | m
  }

  // MARK: sRGB

  static func srgbDecode(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
  static func srgbEncode(_ c: Float) -> Float { c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055 }

  static func powf(_ x: Float, _ y: Float) -> Float { x <= 0 ? 0 : expf(y * lnf(x)) }

  static func lnf(_ x: Float) -> Float {
    var m = x
    var e = 0
    while m >= 2 {
      m /= 2
      e += 1
    }
    while m < 1 {
      m *= 2
      e -= 1
    }
    let t = (m - 1) / (m + 1)
    let t2 = t * t
    var sum: Float = 0
    var term = t
    var k: Float = 1
    for _ in 0..<12 {
      sum += term / k
      term *= t2
      k += 2
    }
    return 2 * sum + Float(e) * 0.693_147_18
  }

  static func expf(_ x: Float) -> Float {
    let n = Int((x / 0.693_147_18).rounded())
    let r = x - Float(n) * 0.693_147_18
    var term: Float = 1
    var sum: Float = 1
    for k in 1..<12 {
      term *= r / Float(k)
      sum += term
    }
    return sum * exp2i(n)
  }

  // MARK: Channels of a format

  struct Channels {
    var count: Int
    var bits: Int
    var type: NumericType
    var swapRB = false
  }

  /// The channels of an uncompressed colour format of equal channels in memory order; nil for the packed ones.
  static func channels(_ f: PixelFormat) -> Channels? {
    switch f {
    case .r8: return Channels(count: 1, bits: 8, type: .unorm)
    case .r8snorm: return Channels(count: 1, bits: 8, type: .snorm)
    case .r8uint: return Channels(count: 1, bits: 8, type: .uint)
    case .r8sint: return Channels(count: 1, bits: 8, type: .sint)
    case .rg8: return Channels(count: 2, bits: 8, type: .unorm)
    case .rg8snorm: return Channels(count: 2, bits: 8, type: .snorm)
    case .rg8uint: return Channels(count: 2, bits: 8, type: .uint)
    case .rg8sint: return Channels(count: 2, bits: 8, type: .sint)
    case .rgba8: return Channels(count: 4, bits: 8, type: .unorm)
    case .rgba8snorm: return Channels(count: 4, bits: 8, type: .snorm)
    case .rgba8uint: return Channels(count: 4, bits: 8, type: .uint)
    case .rgba8sint: return Channels(count: 4, bits: 8, type: .sint)
    case .rgba8srgb: return Channels(count: 4, bits: 8, type: .srgb)
    case .bgra8: return Channels(count: 4, bits: 8, type: .unorm, swapRB: true)
    case .bgra8srgb: return Channels(count: 4, bits: 8, type: .srgb, swapRB: true)
    case .r16float: return Channels(count: 1, bits: 16, type: .float)
    case .r16uint: return Channels(count: 1, bits: 16, type: .uint)
    case .r16sint: return Channels(count: 1, bits: 16, type: .sint)
    case .rg16float: return Channels(count: 2, bits: 16, type: .float)
    case .rg16uint: return Channels(count: 2, bits: 16, type: .uint)
    case .rg16sint: return Channels(count: 2, bits: 16, type: .sint)
    case .rgba16float: return Channels(count: 4, bits: 16, type: .float)
    case .rgba16uint: return Channels(count: 4, bits: 16, type: .uint)
    case .rgba16sint: return Channels(count: 4, bits: 16, type: .sint)
    case .r32float: return Channels(count: 1, bits: 32, type: .float)
    case .r32uint: return Channels(count: 1, bits: 32, type: .uint)
    case .r32sint: return Channels(count: 1, bits: 32, type: .sint)
    case .rg32float: return Channels(count: 2, bits: 32, type: .float)
    case .rg32uint: return Channels(count: 2, bits: 32, type: .uint)
    case .rg32sint: return Channels(count: 2, bits: 32, type: .sint)
    case .rgba32float: return Channels(count: 4, bits: 32, type: .float)
    case .rgba32uint: return Channels(count: 4, bits: 32, type: .uint)
    case .rgba32sint: return Channels(count: 4, bits: 32, type: .sint)
    default: return nil
    }
  }

  /// Whether the codec handles the format: an uncompressed colour format.
  static func handles(_ f: PixelFormat) -> Bool {
    channels(f) != nil || f == .rgb10a2unorm || f == .rg11b10float || f == .rgb9e5
  }

  static func load(_ p: UnsafeRawPointer, _ offset: Int, bits: Int) -> UInt32 {
    switch bits {
    case 8: return UInt32(unsafe p.load(fromByteOffset: offset, as: UInt8.self))
    case 16: return UInt32(unsafe p.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    default: return unsafe p.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
    }
  }

  static func store(_ p: UnsafeMutableRawPointer, _ offset: Int, bits: Int, _ v: UInt32) {
    switch bits {
    case 8: unsafe p.storeBytes(of: UInt8(truncatingIfNeeded: v), toByteOffset: offset, as: UInt8.self)
    case 16: unsafe p.storeBytes(of: UInt16(truncatingIfNeeded: v), toByteOffset: offset, as: UInt16.self)
    default: unsafe p.storeBytes(of: v, toByteOffset: offset, as: UInt32.self)
    }
  }

  /// The texel at `p` as four values, red first: floats for the float-class formats, the integers' values for the others (exact
  /// below 2^24), the channels the format lacks (0, 0, 0, 1).
  static func decode(_ f: PixelFormat, _ p: UnsafeRawPointer) -> [Float] {
    if f == .rgb10a2unorm {
      let w = unsafe p.loadUnaligned(as: UInt32.self)
      return [Float(w & 0x3FF) / 1023, Float((w >> 10) & 0x3FF) / 1023, Float((w >> 20) & 0x3FF) / 1023, Float(w >> 30) / 3]
    }
    if f == .rg11b10float {
      let w = unsafe p.loadUnaligned(as: UInt32.self)
      return [smallFloatToFloat(w & 0x7FF, mBits: 6), smallFloatToFloat((w >> 11) & 0x7FF, mBits: 6), smallFloatToFloat(w >> 22, mBits: 5), 1]
    }
    if f == .rgb9e5 {
      let w = unsafe p.loadUnaligned(as: UInt32.self)
      let scale = exp2i(Int(w >> 27) - 15 - 9)
      return [Float(w & 0x1FF) * scale, Float((w >> 9) & 0x1FF) * scale, Float((w >> 18) & 0x1FF) * scale, 1]
    }
    guard let c = channels(f) else { return [0, 0, 0, 1] }
    var out: [Float] = [0, 0, 0, 1]
    for i in 0..<c.count {
      let raw = unsafe load(p, i * c.bits / 8, bits: c.bits)
      var v: Float
      switch c.type {
      case .unorm, .srgb: v = Float(raw) / Float((UInt64(1) << UInt64(c.bits)) - 1)
      case .snorm:
        let s = c.bits == 8 ? Int32(Int8(truncatingIfNeeded: raw)) : Int32(Int16(truncatingIfNeeded: raw))
        v = max(Float(s) / Float((1 << (c.bits - 1)) - 1), -1)
      case .uint: v = Float(raw)
      case .sint:
        switch c.bits {
        case 8: v = Float(Int8(truncatingIfNeeded: raw))
        case 16: v = Float(Int16(truncatingIfNeeded: raw))
        default: v = Float(Int32(bitPattern: raw))
        }
      case .float, .ufloat: v = c.bits == 16 ? halfToFloat(UInt16(truncatingIfNeeded: raw)) : Float(bitPattern: raw)
      }
      if c.type == .srgb && i < 3 { v = srgbDecode(v) }
      out[i] = v
    }
    if c.swapRB { out.swapAt(0, 2) }
    return out
  }

  /// Stores four values as the format holds them (to nearest, clamped as the format clamps).
  static func encode(_ f: PixelFormat, _ value: [Float], to p: UnsafeMutableRawPointer) {
    if f == .rgb10a2unorm {
      func q(_ v: Float, _ m: Float) -> UInt32 { UInt32(min(max(v, 0), 1) * m + 0.5) }
      unsafe p.storeBytes(of: q(value[0], 1023) | q(value[1], 1023) << 10 | q(value[2], 1023) << 20 | q(value[3], 3) << 30, as: UInt32.self)
      return
    }
    if f == .rg11b10float {
      let w = floatToSmallFloat(value[0], mBits: 6) | floatToSmallFloat(value[1], mBits: 6) << 11 | floatToSmallFloat(value[2], mBits: 5) << 22
      unsafe p.storeBytes(of: w, as: UInt32.self)
      return
    }
    if f == .rgb9e5 {
      let r = min(max(value[0], 0), 65408), g = min(max(value[1], 0), 65408), b = min(max(value[2], 0), 65408)
      let big = max(r, max(g, b))
      var expo = (big > 0 ? Int((big.bitPattern >> 23) & 0xFF) - 127 : -16)
      expo = max(expo, -16) + 16
      var scale = exp2i(expo - 15 - 9)
      if (big / scale).rounded() >= 512 {
        expo += 1
        scale *= 2
      }
      func m(_ v: Float) -> UInt32 { UInt32(min((v / scale).rounded(), 511)) }
      unsafe p.storeBytes(of: m(r) | m(g) << 9 | m(b) << 18 | UInt32(expo) << 27, as: UInt32.self)
      return
    }
    guard let c = channels(f) else { return }
    var v = value
    if c.swapRB { v.swapAt(0, 2) }
    for i in 0..<c.count {
      var x = v[i]
      var raw: UInt32
      switch c.type {
      case .unorm: raw = UInt32(min(max(x, 0), 1) * Float((UInt64(1) << UInt64(c.bits)) - 1) + 0.5)
      case .srgb:
        if i < 3 { x = srgbEncode(min(max(x, 0), 1)) }
        raw = UInt32(min(max(x, 0), 1) * Float((UInt64(1) << UInt64(c.bits)) - 1) + 0.5)
      case .snorm:
        let m = Float((1 << (c.bits - 1)) - 1)
        raw = UInt32(bitPattern: Int32((min(max(x, -1), 1) * m).rounded()))
      case .uint: raw = UInt32(min(max(x, 0), 4_294_967_040))
      case .sint: raw = UInt32(bitPattern: Int32(min(max(x, -2_147_483_648), 2_147_483_520)))
      case .float, .ufloat: raw = c.bits == 16 ? UInt32(floatToHalf(x)) : x.bitPattern
      }
      unsafe store(p, i * c.bits / 8, bits: c.bits, raw)
    }
  }
}
