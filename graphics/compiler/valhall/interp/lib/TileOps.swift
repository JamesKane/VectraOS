// SPDX-License-Identifier: BSD-3-Clause

// LD_TILE (valhall 12c.7.1) and the opaque BLEND of a blend shader (09 section 9.10 step 6) over the model's tile buffer:
// one packed RGBA8 pixel per lane and render target (the tile buffer's R8G8B8A8, 09 section 9.6.2). The conversion operand
// names the memory format (word 3 of the target's descriptor: the format at `[19:12]`, the sRGB bit at 20); the model knows the
// 8-bit unorm format (237) and its sRGB form. The register format is the instruction's: f32 (four registers) or f16 (two).

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum TileFormat {
  static let rgba8: UInt32 = 237

  static func srgbDecode(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
  static func srgbEncode(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

  /// The tile pixel as the four channels a load gives, as doubles.
  static func decode(_ pixel: UInt32, conversion: UInt32) throws -> [Double] {
    guard (conversion >> 12) & 0xFF == rgba8 else { throw Fault.invalid("the interpreter's tile buffer holds RGBA8 only") }
    let srgb = conversion & (1 << 20) != 0
    var out: [Double] = []
    for c in 0..<4 {
      let v = Double((pixel >> UInt32(8 * c)) & 0xFF) / 255
      out.append(srgb && c < 3 ? srgbDecode(v) : v)
    }
    return out
  }

  /// The tile pixel from the staged colour (saturating, rounded to nearest even): `half` the colour is four f16 in two registers,
  /// else four f32.
  static func encode(_ block: [UInt32], half: Bool, conversion: UInt32) throws -> UInt32 {
    guard (conversion >> 12) & 0xFF == rgba8 else { throw Fault.invalid("the interpreter's tile buffer holds RGBA8 only") }
    let srgb = conversion & (1 << 20) != 0
    var pixel: UInt32 = 0
    for c in 0..<4 {
      var v: Double
      if half {
        v = FPFormat.f16.decode((block[c / 2] >> UInt32(16 * (c % 2))) & 0xFFFF)
      } else {
        v = Double(Float(bitPattern: block[c]))
      }
      if v.isNaN { v = 0 }
      v = min(max(v, 0), 1)
      if srgb && c < 3 { v = srgbEncode(v) }
      pixel |= UInt32((v * 255).rounded(.toNearestOrEven)) << UInt32(8 * c)
    }
    return pixel
  }
}

extension Executor {
  /// LD_TILE: the destination of the pixel the index word names, for the active lanes, in the register format.
  func tileLoad(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    let m = try fragmentModel(ins)
    for lane in w.lanes(ctx.mask) {
      let index = try src32(w, lane, ins, ins.s0)
      _ = try src32(w, lane, ins, ins.s1)
      let conversion = try src32(w, lane, ins, ins.s2)
      guard index >> 24 == 0xFF, index & 0xFF == 0 else {
        throw Fault.invalid("the interpreter's tile load is of the current pixel, sample 0 (index word 0x\(String(index, radix: 16)))")
      }
      let target = Int((index >> 8) & 0xFF)
      let channels = try TileFormat.decode(m.tile[lane][target] ?? 0, conversion: conversion)
      var out: [UInt32] = []
      switch ins.special {
      case 2:
        for c in 0..<Int(ins.imm) { out.append(Float(channels[c]).bitPattern) }
      case 3:
        // Two channels to a register, the first in the low half.
        var half: [UInt32] = []
        for c in 0..<Int(ins.imm) { half.append(FPFormat.f16.encode(channels[c], .nearestEven)) }
        var k = 0
        while k < half.count {
          out.append(half[k] | (k + 1 < half.count ? half[k + 1] << 16 : 0))
          k += 2
        }
      default: throw Fault.invalid("the interpreter's tile load gives f32 or f16")
      }
      try issueResult(w, lane, first: Int(ins.dst), out, slot: Int(ins.slot))
    }
  }
}
