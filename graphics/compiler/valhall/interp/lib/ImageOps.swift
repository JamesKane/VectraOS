// SPDX-License-Identifier: BSD-3-Clause

// Storage image access over a test model (valhall 12b.10): LD_TEX, LEA_TEX and ST_CVT.
//
// The hardware reads the image's descriptor (03 section 3.8.6) from the resource table. The interpreter has no
// tables: a run gives `DispatchConfig.storageImage`, which maps a handle to the image's base address, size, pitches and
// format, and the instructions work as the spec says over that:
//
//  - `LD_TEX`: the texel at the coordinates of 12b.10.1 (x and y packed in X, z and the layer in Z), converted from the
//    image's format to 32-bit register values, the first `n` channels in order, `n` the instruction's vector size plus
//    one. The handle is one value for the warp (12b.2.1). A coordinate outside the image reads zeros: that is a model
//    choice, the hardware's value is open (12b.10.5, S2): only that it is harmless is known.
//  - `LEA_TEX`: word 0 and 1 the texel's byte address, word 2 the conversion word. The model's conversion word is the
//    format's code (`StorageFormat.rawValue`), 0 for a coordinate outside the image: the pixel format of 12b.12 is a
//    22-bit code of 05 that the compiler never reads, only passes from LEA_TEX to ST_CVT.
//  - `ST_CVT`: converts the staging block's channels to the format the conversion word names and writes the texel at
//    the address; a conversion word of 0 (outside the image) writes nothing. An integer value above the format's range
//    is saturated (the spec leaves wrap or saturate open, 12b.10.4); a float above it is clamped.
//
// LD_TEX takes the explicit register format of the shader's type (f32, u32 or s32) and ST_CVT auto32; the model converts in the format's own terms.

/// The formats the model converts: what a storage image of the Mali heap can hold.
public enum StorageFormat: UInt32, Sendable, CaseIterable {
  case rgba8Unorm = 1, bgra8Unorm, r8Unorm, rgba8Uint, r32Uint, r32Sint, r32Float, rgba16Float, rgba32Float, rgba32Uint
  case rgba8Snorm, rgba8Sint, r16Sint, r16Uint

  /// Channels and bytes of a texel.
  public var channels: Int {
    switch self {
    case .rgba8Unorm, .bgra8Unorm, .rgba8Uint, .rgba16Float, .rgba32Float, .rgba32Uint, .rgba8Snorm, .rgba8Sint: return 4
    case .r8Unorm, .r32Uint, .r32Sint, .r32Float, .r16Sint, .r16Uint: return 1
    }
  }
  public var bytes: Int {
    switch self {
    case .rgba8Unorm, .bgra8Unorm, .rgba8Uint, .r32Uint, .r32Sint, .r32Float, .rgba8Snorm, .rgba8Sint: return 4
    case .r8Unorm: return 1
    case .r16Sint, .r16Uint: return 2
    case .rgba16Float: return 8
    case .rgba32Float, .rgba32Uint: return 16
    }
  }
}

/// A storage image as the model has it: linear, one level, `layers` layers.
public struct StorageImageModel: Sendable {
  public var base: UInt64
  public var width: Int
  public var height: Int
  public var layers: Int
  public var rowPitch: Int
  public var layerPitch: Int
  public var format: StorageFormat

  public init(
    base: UInt64, width: Int, height: Int = 1, layers: Int = 1, rowPitch: Int? = nil, layerPitch: Int? = nil,
    format: StorageFormat
  ) {
    self.base = base
    self.width = width
    self.height = height
    self.layers = layers
    self.rowPitch = rowPitch ?? width * format.bytes
    self.layerPitch = layerPitch ?? (rowPitch ?? width * format.bytes) * height
    self.format = format
  }

  /// The byte address of a texel, or nil outside the image.
  func address(x: Int, y: Int, z: Int, layer: Int) -> UInt64? {
    guard x < width, y < height, z == 0, layer < layers else { return nil }
    return base &+ UInt64(layer * layerPitch + y * rowPitch + x * format.bytes)
  }
}

extension Executor {
  /// The coordinates of 12b.10.1.
  private func imageCoordinates(_ w: Warp, _ lane: Int, _ ins: Instr) throws -> (x: Int, y: Int, z: Int, layer: Int) {
    let xy = try src32(w, lane, ins, ins.s0)
    let zl = try src32(w, lane, ins, ins.s1)
    return (Int(xy & 0xFFFF), Int(xy >> 16), Int(zl & 0xFFFF), Int(zl >> 16))
  }

  /// The one image handle of the instruction's lanes (12b.2.1).
  private func imageOfWarp(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws -> StorageImageModel? {
    guard let model = cfg.storageImage else { throw Fault.invalid("\(ins.op): the run has no storage image model") }
    var handle: UInt32?
    for lane in w.lanes(ctx.mask) {
      let h = try src32(w, lane, ins, ins.s2)
      if let seen = handle, seen != h {
        throw Fault.invalid("an image handle that differs between the lanes of a warp (12b.2.1): \(seen) and \(h)")
      }
      handle = h
    }
    guard let h = handle else { return nil }
    guard let image = model(h) else { throw Fault.invalid("\(ins.op): image handle \(h) names no image of the model") }
    return image
  }

  /// LD_TEX and LEA_TEX.
  func imageAccess(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    guard let image = try imageOfWarp(w, ctx, ins) else { return }
    for lane in w.lanes(ctx.mask) {
      let c = try imageCoordinates(w, lane, ins)
      let at = image.address(x: c.x, y: c.y, z: c.z, layer: c.layer)
      if ins.op == .leaTex {
        let a = at ?? 0
        let conv: UInt32 = at == nil ? 0 : image.format.rawValue
        try issueResult(
          w, lane, first: Int(ins.dst), [UInt32(truncatingIfNeeded: a), UInt32(truncatingIfNeeded: a >> 32), conv],
          slot: Int(ins.slot))
        continue
      }
      let n = Int(ins.imm)
      var out = [UInt32](repeating: 0, count: n)
      if let a = at {
        let texel = decodeTexel(try readMem(a, image.format.bytes), image.format)
        for k in 0..<min(n, texel.count) { out[k] = texel[k] }
      }
      try issueResult(w, lane, first: Int(ins.dst), out, slot: Int(ins.slot))
    }
  }

  /// ST_CVT.
  func storeConverted(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let addr = try address(w, lane, ins)
    let conv = try src32(w, lane, ins, ins.s2)
    let n = Int(ins.imm)
    let block = try stagingBlock(w, lane, first: Int(ins.dst), count: n)
    w.busy[Int(ins.slot)] = 1
    if isDiscarded(w, lane) && ins.access != 3 { return }
    guard conv != 0 else { return }
    guard let format = StorageFormat(rawValue: conv & 0x3F_FFFF) else {
      throw Fault.invalid("ST_CVT: conversion word \(conv) is not a model format")
    }
    try writeMem(addr, encodeTexel(block, format))
  }

  private func decodeTexel(_ b: [UInt8], _ f: StorageFormat) -> [UInt32] {
    func u32(_ at: Int) -> UInt32 {
      UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
    func unorm(_ v: UInt8) -> UInt32 { (Float(v) / 255).bitPattern }
    switch f {
    case .rgba8Unorm: return (0..<4).map { unorm(b[$0]) }
    case .bgra8Unorm: return [unorm(b[2]), unorm(b[1]), unorm(b[0]), unorm(b[3])]
    case .r8Unorm: return [unorm(b[0])]
    case .rgba8Uint: return (0..<4).map { UInt32(b[$0]) }
    case .rgba8Snorm: return (0..<4).map { max(Float(Int8(bitPattern: b[$0])) / 127, -1).bitPattern }
    case .rgba8Sint: return (0..<4).map { UInt32(bitPattern: Int32(Int8(bitPattern: b[$0]))) }
    case .r16Sint: return [UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8)))]
    case .r16Uint: return [UInt32(b[0]) | UInt32(b[1]) << 8]
    case .r32Uint, .r32Sint, .r32Float: return [u32(0)]
    case .rgba32Float, .rgba32Uint: return (0..<4).map { u32(4 * $0) }
    case .rgba16Float:
      return (0..<4).map { k in
        let h = UInt32(b[2 * k]) | UInt32(b[2 * k + 1]) << 8
        return Float(FPFormat.f16.decode(h)).bitPattern
      }
    }
  }

  private func encodeTexel(_ v: [UInt32], _ f: StorageFormat) -> [UInt8] {
    func le(_ x: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: x >> UInt32(8 * $0)) } }
    func unorm(_ bits: UInt32) -> UInt8 {
      let x = Float(bitPattern: bits)
      if x.isNaN { return 0 }
      return UInt8(min(max((x * 255).rounded(.toNearestOrEven), 0), 255))
    }
    func channel(_ k: Int) -> UInt32 { k < v.count ? v[k] : 0 }
    switch f {
    case .rgba8Unorm: return (0..<4).map { unorm(channel($0)) }
    case .bgra8Unorm: return [unorm(channel(2)), unorm(channel(1)), unorm(channel(0)), unorm(channel(3))]
    case .r8Unorm: return [unorm(channel(0))]
    case .rgba8Uint: return (0..<4).map { UInt8(min(channel($0), 255)) }
    case .rgba8Snorm:
      return (0..<4).map { k -> UInt8 in
        let x = Float(bitPattern: channel(k))
        return x.isNaN ? 0 : UInt8(bitPattern: Int8(min(max((x * 127).rounded(.toNearestOrEven), -127), 127)))
      }
    // Narrow integers saturate here: that is a model choice (whether ST_CVT saturates or wraps is open, valhall 12b.10.5, S3).
    case .rgba8Sint: return (0..<4).map { UInt8(bitPattern: Int8(min(max(Int32(bitPattern: channel($0)), -128), 127))) }
    case .r16Sint:
      let h = UInt16(bitPattern: Int16(min(max(Int32(bitPattern: channel(0)), -32768), 32767)))
      return [UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8)]
    case .r16Uint:
      let h = UInt16(min(channel(0), 65535))
      return [UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8)]
    case .r32Uint, .r32Sint, .r32Float: return le(channel(0))
    case .rgba32Float, .rgba32Uint: return (0..<4).flatMap { le(channel($0)) }
    case .rgba16Float:
      return (0..<4).flatMap { k -> [UInt8] in
        let h = FPFormat.f16.encode(Double(Float(bitPattern: channel(k))), .nearestEven)
        return [UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8)]
      }
    }
  }
}
