// SPDX-License-Identifier: BSD-3-Clause

// Storage images to IR (valhall 12b.10, 12b.11): OpImageRead, OpImageWrite and OpImageTexelPointer on 1D and 2D images
// (arrayed or not) whose format is declared, from the heap's binding of storage images.
//
// An image is followed at compile time as an `Opaque` (LowerImage.swift). A read becomes one `imgload` for each channel
// the format has, a write one `imgstore` of those channels, a texel pointer one `imgaddr` (the texel's address, which the
// atomics then use as a global pointer, 12b.11). The hardware converts between the descriptor's pixel format and the
// registers, so the compiler needs only the format's channel count and whether its values are float (or normalised),
// unsigned or signed: `storageFormat`.
//
// Refused, by name: formats Unknown (the format is then in the descriptor, and the access does not say it), 3D, cube,
// buffer, multisampled and depth storage images and image operands (Lod, Sample, MakeTexelVisible...); the queries are
// arithmetic on `descword`s, the words of the descriptor (12b.13.5).

/// The channels and the kind of value (0 float or normalised, 1 unsigned, 2 signed) a SPIR-V storage image format has.
func storageFormat(_ format: UInt32) -> (channels: Int, kind: Int)? {
  switch format {
  case 1, 2, 4, 5, 10, 11, 16: return (4, 0)
  case 3, 9, 14, 15, 19, 20: return (1, 0)
  case 6, 7, 12, 13, 17, 18: return (2, 0)
  case 8: return (3, 0)
  case 21, 22, 23: return (4, 2)
  case 24, 28, 29: return (1, 2)
  case 25, 26, 27: return (2, 2)
  case 30, 31, 32, 34: return (4, 1)
  case 33, 38, 39: return (1, 1)
  case 35, 36, 37: return (2, 1)
  default: return nil
  }
}

struct StorageAddress {
  var flags: Int
  /// The element index, the coordinates and the layer.
  var args: [ValueID]
  var key: UInt64
  var channels: Int
  var kind: Int
  var texel: Scalar
}

extension Lowerer {
  /// Whether an image operand mask is SignExtend or ZeroExtend and nothing else: a texel of 32 bits has nothing to extend, so the
  /// operand changes nothing (glslang writes ZeroExtend on every unsigned image access).
  func extensionOnly(_ mask: UInt32) -> Bool { mask != 0 && mask & ~0x3000 == 0 }

  mutating func storageAddress(_ ref: Opaque, coordinate: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> StorageAddress {
    guard let image = ref.image else { throw fail(i, "not an image") }
    guard case .image(let sampledType, let dim, let depth, let arrayed, let ms, let usage, let format)? = m.type(ref.imageType) else {
      throw fail(i, "the image type is unknown")
    }
    guard usage == 2 else { throw fail(i, "a sampled image is not a storage image") }
    guard dim <= 1 || dim == 5 else { throw fail(i, "a storage image of a dimension other than 1D, 2D and buffer is not supported") }
    guard !ms, depth != 1 else { throw fail(i, "a multisampled or depth storage image is not supported") }
    guard let (channels, kind) = storageFormat(format) else {
      throw fail(i, "a storage image whose format is Unknown (or not known to the compiler) is not supported: the format is the descriptor's")
    }
    let texel: Scalar
    switch m.type(sampledType) {
    case .float(32)?:
      texel = .f32
    case .int(32, let signed)?:
      texel = .i32
      guard signed == (kind == 2) else { throw fail(i, "the sampled type's signedness is not the format's") }
    default: throw fail(i, "a storage image texel type other than 32-bit float or integer is not supported")
    }
    guard (kind == 0) == (texel == .f32) else { throw fail(i, "the sampled type is not the format's") }
    let isBuffer = dim == 5
    let dims = isBuffer ? 1 : Int(dim) + 1
    let comps = dims + (arrayed ? 1 : 0)
    let c = try val(coordinate, i)
    var parts: [ValueID] = []
    if comps == 1 {
      parts = [c]
    } else {
      guard f.type(c).lanes == comps else { throw fail(i, "the coordinate has \(f.type(c).lanes) components, the image needs \(comps)") }
      let es = f.type(c).element
      for k in 0..<comps { parts.append(emit(.extract, es, [c], imm: k)) }
    }
    for p in parts where f.type(p) != .i32 { throw fail(i, "a storage image's coordinates are 32-bit integers") }
    return StorageAddress(
      flags: ImgFlags.make(dims: dims, arrayed: arrayed, channels: channels, kind: kind) | (isBuffer ? ImgFlags.buffer : 0),
      args: [image.index] + parts,
      key: UInt64(image.set) << 32 | UInt64(image.binding), channels: channels, kind: kind, texel: texel)
  }

  mutating func lowerStorageImage(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    switch i.op {
    case Op.imageRead:
      guard o.count >= 2, let ref = opaque[Int(o[0])] else { throw fail(i, "needs an image and coordinates") }
      guard o.count == 2 || o.count == 3 && extensionOnly(o[2]) else { throw fail(i, "an image operand of OpImageRead is not supported") }
      let a = try storageAddress(ref, coordinate: o[1], i)
      guard case .vector(let rs, 4) = try irType(i.type, i), rs == a.texel else {
        throw fail(i, "the result is not a vector of four texels")
      }
      var comps: [ValueID] = []
      for k in 0..<4 {
        if k < a.channels {
          comps.append(f.append(Inst(.imgload, .scalar(a.texel), a.args, imm: a.flags, imm2: k, payload: [a.key]), to: cur))
        } else {
          // The channels the format lacks read (0, 0, 1) (12b.10.2).
          let one = a.texel == .f32 ? UInt64(Float(1).bitPattern) : 1
          comps.append(f.constant(a.texel, k == 3 ? one : 0))
        }
      }
      lv[Int(i.result)] = [emit(.vecbuild, .vector(a.texel, 4), comps)]
    case Op.imageWrite:
      guard o.count >= 3, let ref = opaque[Int(o[0])] else { throw fail(i, "needs an image, coordinates and a texel") }
      guard o.count == 3 || o.count == 4 && extensionOnly(o[3]) else { throw fail(i, "an image operand of OpImageWrite is not supported") }
      let a = try storageAddress(ref, coordinate: o[1], i)
      let t = try val(o[2], i)
      guard f.type(t).scalarKind == a.texel, f.type(t).lanes >= a.channels else {
        throw fail(i, "the texel is not \(a.channels) or more \(a.texel.name) components")
      }
      var values: [ValueID] = []
      for k in 0..<a.channels {
        values.append(f.type(t).isVector ? emit(.extract, .scalar(a.texel), [t], imm: k) : t)
      }
      f.append(Inst(.imgstore, .void, a.args + values, imm: a.flags, payload: [a.key]), to: cur)
    case Op.imageTexelPointer:
      guard o.count == 3 else { throw fail(i, "needs an image, coordinates and a sample") }
      var ref: Opaque
      if let known = opaque[Int(o[0])] { ref = known } else { ref = try opaquePointer(o[0], i) }
      let a = try storageAddress(ref, coordinate: o[1], i)
      guard a.channels == 1, a.kind != 0, a.texel == .i32 else {
        throw fail(i, "an atomic needs a single-channel integer storage image (R32ui or R32i)")
      }
      guard try evalInt(o[2], i) == 0 else { throw fail(i, "a multisampled image is not supported") }
      lv[Int(i.result)] = [f.append(Inst(.imgaddr, .ptr(.global), a.args, imm: a.flags, payload: [a.key]), to: cur)]
    default:
      try lowerStorageQuery(i)
    }
  }

  /// OpImageQuerySize, OpImageQueryLevels and OpImageQuerySamples: fields of the image's descriptor, read with `descword`
  /// (valhall 12b.13.5). Every field is stored minus one, and a null descriptor (the low half of word 0 zero) gives 0.
  mutating func lowerStorageQuery(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    guard o.count == 1, let ref = opaque[Int(o[0])], let image = ref.image else { throw fail(i, "needs an image") }
    if case .image(_, _, _, _, _, let u, _)? = m.type(ref.imageType), u == 1 {
      try lowerSampledQuery(i)
      return
    }
    guard case .image(_, let dim, let depth, let arrayed, let ms, let usage, _)? = m.type(ref.imageType), usage == 2 else {
      throw fail(i, "the image query is for a storage image here")
    }
    guard dim <= 1, !ms, depth != 1 else {
      throw fail(i, "a storage image of a dimension other than 1D and 2D, a multisampled or a depth one is not supported")
    }
    let key = UInt64(image.set) << 32 | UInt64(image.binding)
    let i32 = IRType.i32
    let zero = f.constant(.i32, 0), one = f.constant(.i32, 1)
    func word(_ n: Int) -> ValueID {
      f.append(Inst(.descword, .i32, [image.index], imm: n, payload: [key]), to: cur)
    }
    let isNull = emit(.icmp, .bool, [emit(.and, i32, [word(0), f.constant(.i32, 0xFFFF)]), zero], imm: ICmpPred.eq)
    func field(_ w: ValueID, shift: Int, mask: UInt64, plusOne: Bool) -> ValueID {
      var v = shift == 0 ? w : emit(.lshr, i32, [w, f.constant(.i32, UInt64(shift))])
      v = emit(.and, i32, [v, f.constant(.i32, mask)])
      if plusOne { v = emit(.iadd, i32, [v, one]) }
      return emit(.select, i32, [isNull, zero, v])
    }
    switch i.op {
    case Op.imageQueryLevels:
      lv[Int(i.result)] = [field(word(2), shift: 16, mask: 31, plusOne: true)]
    case Op.imageQuerySamples:
      // 1 shifted left by bits 15:13 of word 3.
      let log = emit(.and, i32, [emit(.lshr, i32, [word(3), f.constant(.i32, 13)]), f.constant(.i32, 7)])
      lv[Int(i.result)] = [emit(.select, i32, [isNull, zero, emit(.shl, i32, [one, log])])]
    default:
      var comps: [ValueID] = [field(word(1), shift: 0, mask: 0xFFFF, plusOne: true)]
      if dim >= 1 { comps.append(field(word(1), shift: 16, mask: 0xFFFF, plusOne: true)) }
      if arrayed { comps.append(field(word(6), shift: 0, mask: 0xFFFF, plusOne: true)) }
      let want = try irType(i.type, i)
      guard want.lanes == comps.count, want.scalarKind == .i32 else {
        throw fail(i, "the result has \(want.lanes) components, the image has \(comps.count)")
      }
      lv[Int(i.result)] = [comps.count == 1 ? comps[0] : emit(.vecbuild, want, comps)]
    }
  }
}
