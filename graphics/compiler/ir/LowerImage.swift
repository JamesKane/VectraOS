// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V images, samplers and sampled images to IR (D174 section 3, step 3).
//
// An image, a sampler or a sampled image is not a value in a register; the lowering follows it at compile time as an
// `Opaque`: the (set, binding) of the UniformConstant variable it came from and the element index (an i32 value, zero
// for a variable that is not an array). OpLoad of such a variable, OpAccessChain into an array of them, OpSampledImage
// and OpImage only move the record; the access (OpImageSampleImplicitLod, OpImageSampleExplicitLod, OpImageFetch)
// becomes four `tex` instructions, one a component of the texel, which the backend merges into one message.
//
// What is lowered: 1D, 2D and 3D images, arrayed or not, float and integer texels, with the Bias, Lod and ConstOffset
// image operands. What is refused, by name: cube and buffer images, multisampled images, depth images and the Dref,
// Proj and Gather forms, the Grad, Offset, ConstOffsets, Sample and MinLod operands, storage images, and an image or
// sampler passed to a function or through a phi. NonUniform changes nothing: the handle is a value a lane computes.

/// An image or a sampler as the lowering follows it: its binding and element.
struct BindingRef {
  var set: Int
  var binding: Int
  /// The element of the binding's array: an i32 value of the function being lowered.
  var index: ValueID
}

struct Opaque {
  var image: BindingRef?
  var sampler: BindingRef?
  /// The OpTypeImage id of the image (for the dimensions and the texel type).
  var imageType: UInt32 = 0
}

extension Lowerer {
  /// The type an opaque value has behind its pointers and arrays: an image, a sampler or a sampled image.
  func opaqueLeaf(_ t: UInt32) -> UInt32? {
    switch m.type(t) {
    case .image?, .sampler?, .sampledImage?: return t
    case .array(let e, _)?: return opaqueLeaf(e)
    case .runtimeArray(let e)?: return opaqueLeaf(e)
    default: return nil
    }
  }

  /// Whether a pointer operand is a UniformConstant variable of an opaque type (or already followed as one).
  func isOpaqueAccess(_ id: UInt32) -> Bool {
    if Int(id) < opaque.count, opaque[Int(id)] != nil { return true }
    guard Int(id) < m.variableIndex.count, m.variableIndex[Int(id)] >= 0 else { return false }
    let v = m.variables[Int(m.variableIndex[Int(id)])]
    guard v.storage == StorageClass.uniformConstant, case .pointer(_, let pointee)? = m.type(v.type) else { return false }
    return opaqueLeaf(pointee) != nil
  }

  /// The record of a pointer operand, made from the variable's decorations the first time.
  mutating func opaquePointer(_ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> Opaque {
    if let o = opaque[Int(id)] { return o }
    let v = m.variables[Int(m.variableIndex[Int(id)])]
    guard let set = m.decoration(v.id, Decor.descriptorSet)?.first, let binding = m.decoration(v.id, Decor.binding)?.first else {
      throw fail(i, "variable %\(v.id) has no DescriptorSet and Binding")
    }
    guard case .pointer(_, let pointee)? = m.type(v.type), let leaf = opaqueLeaf(pointee) else { throw fail(i, "not an opaque type") }
    let ref = BindingRef(set: Int(set), binding: Int(binding), index: f.constant(.i32, 0))
    var o = Opaque()
    try classify(leaf, ref, into: &o, i)
    opaque[Int(id)] = o
    return o
  }

  /// Put a binding in the record's image or sampler slot by its type.
  func classify(_ leaf: UInt32, _ ref: BindingRef, into o: inout Opaque, _ i: SPIRVInstruction) throws(CompileError) {
    switch m.type(leaf) {
    case .image?:
      o.image = ref
      o.imageType = leaf
    case .sampler?: o.sampler = ref
    case .sampledImage?:
      throw fail(i, "a combined image sampler is not supported (the heap holds textures and samplers apart)")
    default: throw fail(i, "not an image or a sampler")
    }
  }

  mutating func lowerOpaqueLoad(_ i: SPIRVInstruction) throws(CompileError) {
    let id = i.operands[0]
    if Int(id) < opaque.count, opaque[Int(id)] == nil { _ = try opaquePointer(id, i) }
    guard let o = opaque[Int(id)] else { throw fail(i, "%\(id) is not an image, sampler or array of them") }
    opaque[Int(i.result)] = o
  }

  mutating func lowerOpaqueChain(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    let base = try opaquePointer(o[0], i)
    guard o.count == 2 else { throw fail(i, "only one index into an array of images or samplers is supported") }
    let idx = try val(o[1], i)
    guard case .scalar(let s) = f.type(idx), s.isInt else { throw fail(i, "the index is not an integer") }
    var index = idx
    if s != .i32 { index = emit(s.bits < 32 ? .zext : .trunc, .i32, [idx]) }
    var r = base
    if r.image != nil { r.image?.index = index }
    if r.sampler != nil { r.sampler?.index = index }
    opaque[Int(i.result)] = r
  }

  // MARK: the operations

  mutating func lowerImageOp(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    switch i.op {
    case Op.sampledImage:
      guard o.count == 2, let image = opaque[Int(o[0])], let sampler = opaque[Int(o[1])], image.image != nil, sampler.sampler != nil
      else { throw fail(i, "needs an image and a sampler") }
      guard case .sampledImage(let it)? = m.type(i.type) else { throw fail(i, "the result is not a sampled image") }
      var r = Opaque()
      r.image = image.image
      r.sampler = sampler.sampler
      r.imageType = it
      opaque[Int(i.result)] = r
    case Op.image:
      guard o.count == 1, var r = opaque[Int(o[0])], r.image != nil else { throw fail(i, "needs a sampled image") }
      r.sampler = nil
      opaque[Int(i.result)] = r
    default:
      try lowerImageAccess(i)
    }
  }

  /// A float as the i32 an s8.8 level word holds: clamped to [-16, 16], times 256, converted (12b.5.5).
  mutating func levelWord(_ lod: ValueID) -> ValueID {
    let hi = f.constant(.f32, UInt64(Float(16).bitPattern))
    let lo = f.constant(.f32, UInt64(Float(-16).bitPattern))
    let scale = f.constant(.f32, UInt64(Float(256).bitPattern))
    let c = emit(.fmin, .f32, [emit(.fmax, .f32, [lod, lo]), hi])
    let n = emit(.fptosi, .i32, [emit(.fmul, .f32, [c, scale])])
    return emit(.and, .i32, [n, f.constant(.i32, 0xFFFF)])
  }

  mutating func lowerImageAccess(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    let fetch = i.op == Op.imageFetch
    guard o.count >= 2 else { throw fail(i, "needs an image and coordinates") }
    guard let ref = opaque[Int(o[0])], let image = ref.image else { throw fail(i, "operand %\(o[0]) is not an image") }
    guard case .image(let sampledType, let dim, let depth, let arrayed, let ms, let usage, _)? = m.type(ref.imageType) else {
      throw fail(i, "the image type is unknown")
    }
    guard dim <= 2 else { throw fail(i, "a cube, buffer or subpass image is not supported") }
    guard !ms else { throw fail(i, "a multisampled image is not supported") }
    guard depth != 1 else { throw fail(i, "a depth image is not supported") }
    guard usage == 1 else { throw fail(i, "a storage image is not supported") }
    if !fetch && ref.sampler == nil { throw fail(i, "a sample needs a sampled image") }
    let dims = Int(dim) + 1
    let texel: Int
    let texelType: Scalar
    switch m.type(sampledType) {
    case .float(32)?:
      texel = 0
      texelType = .f32
    case .int(32, let signed)?:
      texel = signed ? 2 : 1
      texelType = .i32
    default: throw fail(i, "a texel type other than 32-bit float or integer is not supported")
    }
    guard case .vector(let rs, 4) = try irType(i.type, i), rs == texelType else { throw fail(i, "the result is not a vector of four texels") }

    // The coordinates, and the layer.
    let coordinate = try val(o[1], i)
    let comps = dims + (arrayed ? 1 : 0)
    var c: [ValueID] = []
    if comps == 1 {
      c = [coordinate]
    } else {
      guard f.type(coordinate).lanes == comps else { throw fail(i, "the coordinate has \(f.type(coordinate).lanes) components, the image needs \(comps)") }
      let es = f.type(coordinate).element
      for k in 0..<comps { c.append(emit(.extract, es, [coordinate], imm: k)) }
    }
    var args: [ValueID] = [ref.image!.index, ref.sampler?.index ?? f.constant(.i32, 0)]
    _ = image
    var layer: ValueID? = nil
    if arrayed {
      let l = c.removeLast()
      if fetch {
        layer = l
      } else {
        // The layer is a float to round (the nearest, halves up).
        let half = f.constant(.f32, UInt64(Float(0.5).bitPattern))
        let r = emit(.ffloor, .f32, [emit(.fadd, .f32, [l, half])])
        layer = emit(.fptosi, .i32, [r])
      }
    }
    for v in c {
      if fetch {
        guard f.type(v) == .i32 else { throw fail(i, "a fetch needs integer coordinates") }
      } else {
        guard f.type(v) == .f32 else { throw fail(i, "a sample needs float coordinates") }
      }
    }
    args.append(contentsOf: c)
    if let l = layer { args.append(l) }

    // The image operands.
    var mask: UInt32 = 0
    var at = 2
    if o.count > 2 {
      mask = o[2]
      at = 3
    }
    var bias: UInt32? = nil
    var lod: UInt32? = nil
    var constOffset: UInt32? = nil
    for bit in 0..<8 where mask & (1 << UInt32(bit)) != 0 {
      let names = ["Bias", "Lod", "Grad", "ConstOffset", "Offset", "ConstOffsets", "Sample", "MinLod"]
      switch bit {
      case 0, 1, 3:
        guard at < o.count else { throw fail(i, "the \(names[bit]) operand is missing") }
        if bit == 0 { bias = o[at] } else if bit == 1 { lod = o[at] } else { constOffset = o[at] }
        at += 1
      default:
        throw fail(i, "the image operand \(names[bit]) is not supported")
      }
    }
    if bias != nil && i.op != Op.imageSampleImplicitLod { throw fail(i, "Bias is for an implicit level") }
    if lod != nil && i.op == Op.imageSampleImplicitLod { throw fail(i, "Lod is for an explicit level") }
    if i.op == Op.imageSampleExplicitLod && lod == nil { throw fail(i, "an explicit level needs Lod") }

    // The offset word: three signed bytes, and for a fetch the level in byte 3 (12b.5.4).
    var offsetBits: UInt32 = 0
    var haveOffset = false
    if let co = constOffset {
      guard let k = m.constant(co) else { throw fail(i, "ConstOffset must be a constant") }
      var parts: [UInt32] = []
      switch k.kind {
      case .composite(let p): parts = p
      case .scalar: parts = [co]
      case .null: parts = []
      default: throw fail(i, "ConstOffset must be a constant")
      }
      guard parts.isEmpty || parts.count == dims else { throw fail(i, "ConstOffset has \(parts.count) components, the image needs \(dims)") }
      for (n, p) in parts.enumerated() {
        let v = Int64(Int32(truncatingIfNeeded: try evalInt(p, i)))
        guard v >= -8 && v <= 7 else { throw fail(i, "a texel offset must be in -8 to 7") }
        offsetBits |= (UInt32(truncatingIfNeeded: v) & 0xFF) << UInt32(8 * n)
      }
      haveOffset = offsetBits != 0
    }
    try finishImageAccess(
      i, args, fetch: fetch, dims: dims, arrayed: arrayed, texel: texel, texelType: texelType, ref: ref, offsetBits: offsetBits,
      haveOffset: haveOffset, lod: lod, bias: bias)
  }

  mutating func finishImageAccess(
    _ i: SPIRVInstruction, _ baseArgs: [ValueID], fetch: Bool, dims: Int, arrayed: Bool, texel: Int, texelType: Scalar,
    ref: Opaque, offsetBits: UInt32, haveOffset: Bool, lod lodId: UInt32?, bias biasId: UInt32?
  ) throws(CompileError) {
    var args = baseArgs
    var kind = fetch ? TexFlags.fetch : i.op == Op.imageSampleImplicitLod ? TexFlags.implicit : TexFlags.explicit
    var offset = false
    var level = false
    if fetch {
      // The level goes in byte 3 of the offset word; with no offset and level zero the word is left out.
      var word: ValueID = f.constant(.i32, UInt64(offsetBits))
      var needed = haveOffset
      if let l = lodId {
        let lv_ = try val(l, i)
        guard f.type(lv_) == .i32 else { throw fail(i, "the level is not an integer") }
        if let bits = f.constantBits(lv_) {
          if bits != 0 {
            guard bits <= 255 else { throw fail(i, "a fetch level above 255 is not supported") }
            word = f.constant(.i32, UInt64(offsetBits) | bits << 24)
            needed = true
          }
        } else {
          let clamped = emit(.umin, .i32, [lv_, f.constant(.i32, 255)])
          let shifted = emit(.shl, .i32, [clamped, f.constant(.i32, 24)])
          word = emit(.or, .i32, [shifted, f.constant(.i32, UInt64(offsetBits))])
          needed = true
        }
      }
      if needed {
        args.append(word)
        offset = true
      }
    } else {
      if haveOffset {
        args.append(f.constant(.i32, UInt64(offsetBits)))
        offset = true
      }
      if let b = biasId {
        let bv = try val(b, i)
        guard f.type(bv) == .f32 else { throw fail(i, "the bias is not a float") }
        args.append(levelWord(bv))
        level = true
        kind = TexFlags.bias
      } else if let l = lodId {
        let lv_ = try val(l, i)
        guard f.type(lv_) == .f32 else { throw fail(i, "the level is not a float") }
        // A constant level zero is the hardware's `none` mode: no word.
        if let bits = f.constantBits(lv_), bits == 0 || bits == 0x8000_0000 {
        } else {
          args.append(levelWord(lv_))
          level = true
        }
      }
    }
    let flags = TexFlags.make(
      kind: kind, dims: dims, arrayed: arrayed, offset: offset, level: level, texel: texel, noSampler: ref.sampler == nil)
    let key = { (r: BindingRef?) -> UInt64 in r.map { UInt64($0.set) << 32 | UInt64($0.binding) } ?? UInt64.max }
    let payload = [key(ref.image), key(ref.sampler)]
    var comps: [ValueID] = []
    for k in 0..<4 {
      let id = f.makeInst(Inst(.tex, .scalar(texelType), args, imm: flags, imm2: k, payload: payload))
      f.blocks[cur].insts.append(id)
      comps.append(f.insts[id].result)
    }
    lv[Int(i.result)] = [emit(.vecbuild, .vector(texelType, 4), comps)]
  }
}
