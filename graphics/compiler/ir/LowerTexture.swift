// SPDX-License-Identifier: BSD-3-Clause

// Sampled images to IR (D174 amendment, part 2; valhall 12b, 13.10): the sampling, fetching and gathering accesses, the
// queries of a sampled image, and the derivatives.
//
// An access is a group of `tex` instructions, one for each channel the access reads (TexFlags says what it is). What is
// lowered:
//  - OpImageSampleImplicitLod, ...ExplicitLod and ...Proj{Implicit,Explicit}Lod (the projection divides the coordinates
//    here, so the hardware's projection bit is not used), the Dref forms of the first two, OpImageFetch (also of a
//    multisampled image, the sample in byte 2 of the offset word), OpImageGather and OpImageDrefGather (any component,
//    Offset, ConstOffset and ConstOffsets: four gathers, one channel from each);
//  - the image operands Bias, Lod, Grad, ConstOffset, Offset, ConstOffsets and Sample; 1D, 2D, 3D and cube images, arrayed
//    or not (a cube is read in the direction form, 12b.5.3);
//  - OpImageQuerySizeLod, OpImageQuerySize, OpImageQueryLevels and OpImageQuerySamples of a sampled image, from the
//    descriptor's words (12b.13.2, 12b.13.3), and OpImageQueryLod, from TEX_GRADIENT and the sampler's words (12b.13.4);
//  - OpDPdx, OpDPdy, OpFwidth and their Fine and Coarse forms, in a fragment shader (13.10.2), and OpIsHelperInvocationEXT.
// Refused, by name: MinLod, Grad on a cube image (12b.5.8's open question), a projective depth compare, a rectangle,
// buffer or subpass image, an array of projective samples, derivatives outside a fragment shader (the quad remap of
// 14.2.2 is not done).

extension Lowerer {
  private func offsetParts(_ id: UInt32, _ dims: Int, _ i: SPIRVInstruction) throws(CompileError) -> [Int] {
    guard let k = m.constant(id) else { throw fail(i, "a constant offset must be a constant") }
    var parts: [UInt32] = []
    switch k.kind {
    case .composite(let p): parts = p
    case .scalar: parts = [id]
    case .null: return [Int](repeating: 0, count: dims)
    default: throw fail(i, "a constant offset must be a constant")
    }
    guard parts.count == dims else { throw fail(i, "an offset has \(parts.count) components, the image needs \(dims)") }
    var out: [Int] = []
    for p in parts {
      let v = Int(Int32(truncatingIfNeeded: try evalInt(p, i)))
      guard v >= -128 && v <= 127 else { throw fail(i, "a texel offset must fit a signed byte (12b.5.4)") }
      out.append(v)
    }
    return out
  }

  private func packOffsets(_ parts: [Int]) -> UInt32 {
    var bits: UInt32 = 0
    for (n, p) in parts.enumerated() { bits |= (UInt32(truncatingIfNeeded: p) & 0xFF) << UInt32(8 * n) }
    return bits
  }

  mutating func lowerImageAccess(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    let code = Int(i.op)
    if code == 103 {
      try lowerSampledQuery(i)
      return
    }
    if code == 105 {
      try lowerQueryLod(i)
      return
    }
    let fetch = i.op == Op.imageFetch
    let gather = code == 96 || code == 97
    let dref = code == 89 || code == 90 || code == 97
    if code == 93 || code == 94 { throw fail(i, "a projective depth-compare sample is not supported") }
    let proj = code == 91 || code == 92
    let implicit = code == 87 || code == 89 || code == 91
    guard o.count >= 2 else { throw fail(i, "needs an image and coordinates") }
    guard let ref = opaque[Int(o[0])], ref.image != nil else { throw fail(i, "operand %\(o[0]) is not an image") }
    guard case .image(let sampledType, let dim, _, let arrayed, let ms, let usage, _)? = m.type(ref.imageType) else {
      throw fail(i, "the image type is unknown")
    }
    guard dim <= 3 else { throw fail(i, "a rectangle, buffer or subpass image is not supported") }
    guard usage == 1 else { throw fail(i, "a storage image is read with OpImageRead, not sampled or fetched") }
    let cube = dim == 3
    if cube && fetch { throw fail(i, "a fetch of a cube image (12b.5.2: TEX_FETCH has no cube form)") }
    if ms && !fetch { throw fail(i, "a multisampled image is read with OpImageFetch only (12b.6)") }
    if gather && !(dim == 1 || cube) { throw fail(i, "a gather is of a 2D or cube image (12b.8.1)") }
    if proj && arrayed { throw fail(i, "a projective sample of an arrayed image") }
    if !fetch && ref.sampler == nil { throw fail(i, "a sample needs a sampled image") }
    let dims = cube ? 3 : Int(dim) + 1
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
    if dref && texelType != .f32 { throw fail(i, "a depth compare of an integer image") }
    let resultType = try irType(i.type, i)
    let scalarResult: Bool
    if dref && !gather {
      guard resultType == .f32 else { throw fail(i, "the result is not a float") }
      scalarResult = true
    } else if case .scalar(let s) = resultType, s == texelType {
      scalarResult = true
    } else {
      guard case .vector(let rs, 4) = resultType, rs == texelType else { throw fail(i, "the result is not a vector of four texels") }
      scalarResult = false
    }

    // The coordinates, the projection's divisor, and the layer.
    let coordinate = try val(o[1], i)
    let comps = dims + (arrayed ? 1 : 0) + (proj ? 1 : 0)
    var c: [ValueID] = []
    if comps == 1 {
      c = [coordinate]
    } else {
      // A coordinate may have more components than the access needs (a depth reference rides in the extra one): they are ignored.
      guard f.type(coordinate).lanes >= comps else { throw fail(i, "the coordinate has \(f.type(coordinate).lanes) components, the image needs \(comps)") }
      let es = f.type(coordinate).element
      for k in 0..<comps { c.append(emit(.extract, es, [coordinate], imm: k)) }
    }
    if proj {
      let q = c.removeLast()
      guard f.type(q) == .f32 else { throw fail(i, "a projective coordinate is a float") }
      c = c.map { emit(.fdiv, .f32, [$0, q]) }
    }
    var layer: ValueID? = nil
    if arrayed {
      let l = c.removeLast()
      if fetch {
        layer = l
      } else {
        // The layer is a float to round (the nearest, halves up).
        let half = f.constant(.f32, UInt64(Float(0.5).bitPattern))
        layer = emit(.fptosi, .i32, [emit(.ffloor, .f32, [emit(.fadd, .f32, [l, half])])])
      }
    }
    for v in c {
      if fetch {
        guard f.type(v) == .i32 else { throw fail(i, "a fetch needs integer coordinates") }
      } else {
        guard f.type(v) == .f32 else { throw fail(i, "a sample needs float coordinates") }
      }
    }

    // The operands before the image operands, then the image operands (SPIR-V's order, bit by bit).
    var at = 2
    var drefValue: ValueID? = nil
    var component = 0
    if dref {
      guard o.count > at else { throw fail(i, "the depth reference is missing") }
      drefValue = try val(o[at], i)
      guard f.type(drefValue!) == .f32 else { throw fail(i, "the depth reference is not a float") }
      at += 1
    }
    if code == 96 {
      guard o.count > at else { throw fail(i, "the component is missing") }
      let k = try evalInt(o[at], i)
      guard k <= 3 else { throw fail(i, "a gather component above 3") }
      component = Int(k)
      at += 1
    }
    var mask: UInt32 = 0
    if o.count > at {
      mask = o[at]
      at += 1
    }
    var bias: UInt32?, lod: UInt32?, gradX: UInt32?, gradY: UInt32?, constOffset: UInt32?, offsetId: UInt32?
    var constOffsets: UInt32?, sampleId: UInt32?
    let names = ["Bias", "Lod", "Grad", "ConstOffset", "Offset", "ConstOffsets", "Sample", "MinLod"]
    for bit in 0..<8 where mask & (1 << UInt32(bit)) != 0 {
      let need = bit == 2 ? 2 : 1
      guard at + need <= o.count else { throw fail(i, "the \(names[bit]) operand is missing") }
      switch bit {
      case 0: bias = o[at]
      case 1: lod = o[at]
      case 2:
        gradX = o[at]
        gradY = o[at + 1]
      case 3: constOffset = o[at]
      case 4: offsetId = o[at]
      case 5: constOffsets = o[at]
      case 6: sampleId = o[at]
      default: throw fail(i, "the image operand MinLod is not supported (it needs the sparse residency feature)")
      }
      at += need
    }
    if bias != nil && !implicit { throw fail(i, "Bias is for an implicit level") }
    if (lod != nil || gradX != nil) && (implicit || gather) { throw fail(i, "Lod and Grad are for an explicit level") }
    if bias != nil && gather { throw fail(i, "Bias on a gather") }
    if !fetch && !gather && !implicit && lod == nil && gradX == nil { throw fail(i, "an explicit level needs Lod or Grad") }
    if gradX != nil && cube { throw fail(i, "Grad on a cube image: what the four derivative words of a cube mean is open (12b.5.8)") }
    if fetch && ms && sampleId == nil { throw fail(i, "a multisampled fetch needs Sample") }
    if sampleId != nil && !ms { throw fail(i, "Sample on an image that is not multisampled") }
    if (constOffsets != nil) != (gather && constOffsets != nil) { throw fail(i, "ConstOffsets is for a gather") }
    if cube && (constOffset != nil || offsetId != nil) { throw fail(i, "a texel offset on a cube image") }

    // The offset word (12b.5.4): three signed bytes; a fetch's level in byte 3 and a multisampled fetch's sample in byte 2.
    var baseBits: UInt32 = 0
    if let co = constOffset { baseBits = packOffsets(try offsetParts(co, dims, i)) }
    var dynamicWord: ValueID? = nil
    if let od = offsetId {
      let v = try val(od, i)
      guard f.type(v).scalarKind == .i32, f.type(v).lanes == dims || (dims == 1 && !f.type(v).isVector) else {
        throw fail(i, "the offset has the wrong type")
      }
      var w: ValueID = f.constant(.i32, 0)
      for k in 0..<dims {
        let e = dims == 1 ? v : emit(.extract, .i32, [v], imm: k)
        let b = emit(.and, .i32, [e, f.constant(.i32, 0xFF)])
        w = emit(.or, .i32, [w, k == 0 ? b : emit(.shl, .i32, [b, f.constant(.i32, UInt64(8 * k))])])
      }
      dynamicWord = w
    }
    var fetchExtra: ValueID? = nil
    var fetchConst: UInt32 = 0
    if fetch {
      if let l = lod {
        let lv_ = try val(l, i)
        guard f.type(lv_) == .i32 else { throw fail(i, "the level is not an integer") }
        if let bits = f.constantBits(lv_) {
          guard bits <= 255 else { throw fail(i, "a fetch level above 255 is not supported") }
          fetchConst |= UInt32(bits) << 24
        } else {
          let clamped = emit(.umin, .i32, [lv_, f.constant(.i32, 255)])
          fetchExtra = emit(.shl, .i32, [clamped, f.constant(.i32, 24)])
        }
      }
      if let sm = sampleId {
        let sv = try val(sm, i)
        guard f.type(sv) == .i32 else { throw fail(i, "the sample is not an integer") }
        if let bits = f.constantBits(sv) {
          guard bits <= 255 else { throw fail(i, "a sample index above 255") }
          fetchConst |= UInt32(bits) << 16
        } else {
          let s = emit(.shl, .i32, [emit(.and, .i32, [sv, f.constant(.i32, 255)]), f.constant(.i32, 16)])
          fetchExtra = fetchExtra.map { emit(.or, .i32, [$0, s]) } ?? s
        }
      }
    }
    func word(_ bits: UInt32, _ me: inout Lowerer) -> ValueID? {
      let total = bits | fetchConst
      var w: ValueID? = total != 0 ? me.f.constant(.i32, UInt64(total)) : nil
      for extra in [dynamicWord, fetchExtra] {
        if let e = extra { w = w.map { me.emit(.or, .i32, [$0, e]) } ?? e }
      }
      return w
    }

    // The level and the gradients.
    var kind = fetch ? TexFlags.fetch : implicit ? TexFlags.implicit : TexFlags.explicit
    var levelValue: ValueID? = nil
    var gradients: [ValueID] = []
    if let b = bias {
      let bv = try val(b, i)
      guard f.type(bv) == .f32 else { throw fail(i, "the bias is not a float") }
      levelValue = levelWord(bv)
      kind = TexFlags.bias
    } else if let l = lod, !fetch {
      let lv_ = try val(l, i)
      guard f.type(lv_) == .f32 else { throw fail(i, "the level is not a float") }
      // A constant level zero is the hardware's `none` mode: no word.
      if let bits = f.constantBits(lv_), bits == 0 || bits == 0x8000_0000 {
      } else {
        levelValue = levelWord(lv_)
      }
    }
    if let gx = gradX, let gy = gradY {
      for g in [gx, gy] {
        let gv = try val(g, i)
        guard f.type(gv).scalarKind == .f32, f.type(gv).lanes == dims || (dims == 1 && !f.type(gv).isVector) else {
          throw fail(i, "a gradient has the wrong type")
        }
        for k in 0..<dims { gradients.append(dims == 1 ? gv : emit(.extract, .f32, [gv], imm: k)) }
      }
    }

    var flagBits = 0
    if cube { flagBits |= TexFlags.cube }
    if dref { flagBits |= TexFlags.compare }
    if gather { flagBits |= TexFlags.gather | component << TexFlags.gatherShift }
    if !gradients.isEmpty { flagBits |= TexFlags.gradient }
    if ms { flagBits |= TexFlags.multisampled }
    let key = { (r: BindingRef?) -> UInt64 in r.map { UInt64($0.set) << 32 | UInt64($0.binding) } ?? UInt64.max }
    let payload = [key(ref.image), key(ref.sampler)]

    // One group of `tex` instructions: the offset word it takes, the channels it reads.
    func group(_ offsetBits: UInt32, _ channels: [Int], _ me: inout Lowerer) -> [ValueID] {
      var args: [ValueID] = [ref.image!.index, ref.sampler?.index ?? me.f.constant(.i32, 0)]
      args.append(contentsOf: c)
      if let l = layer { args.append(l) }
      if let d = drefValue { args.append(d) }
      let w = word(offsetBits, &me)
      if let w { args.append(w) }
      if let l = levelValue { args.append(l) }
      args.append(contentsOf: gradients)
      let flags = TexFlags.make(
        kind: kind, dims: dims, arrayed: arrayed, offset: w != nil, level: levelValue != nil, texel: texel, noSampler: ref.sampler == nil)
        | flagBits
      var out: [ValueID] = []
      for k in channels {
        let id = me.f.makeInst(Inst(.tex, .scalar(texelType), args, imm: flags, imm2: k, payload: payload))
        me.f.blocks[me.cur].insts.append(id)
        out.append(me.f.insts[id].result)
      }
      return out
    }

    // A gather's channels in the API's order (x0,y1), (x1,y1), (x1,y0), (x0,y0): the hardware's 2, 3, 1, 0 (12b.5.7).
    let api = [2, 3, 1, 0]
    var result: [ValueID]
    if let co = constOffsets {
      guard let k = m.constant(co), case .composite(let items) = k.kind, items.count == 4 else {
        throw fail(i, "ConstOffsets is four constant offsets")
      }
      result = []
      for j in 0..<4 {
        result.append(group(packOffsets(try offsetParts(items[j], 2, i)), [api[j]], &self)[0])
      }
    } else if gather {
      result = group(baseBits, api, &self)
    } else if scalarResult {
      result = group(baseBits, [0], &self)
    } else {
      result = group(baseBits, [0, 1, 2, 3], &self)
    }
    lv[Int(i.result)] = [scalarResult ? result[0] : emit(.vecbuild, .vector(texelType, 4), result)]
  }

  // MARK: queries of a sampled image (12b.13)

  /// OpImageQuerySizeLod, OpImageQuerySize, OpImageQueryLevels and OpImageQuerySamples of a sampled image: the descriptor's
  /// words, each stored minus one; a level above 0 is the base size halved that many times, to a minimum of one.
  mutating func lowerSampledQuery(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    let withLevel = Int(i.op) == 103
    guard o.count == (withLevel ? 2 : 1), let ref = opaque[Int(o[0])], let image = ref.image else { throw fail(i, "needs an image") }
    guard case .image(_, let dim, _, let arrayed, _, _, _)? = m.type(ref.imageType), dim <= 3 else {
      throw fail(i, "a query of a rectangle, buffer or subpass image is not supported")
    }
    let key = UInt64(image.set) << 32 | UInt64(image.binding)
    let i32 = IRType.i32
    let zero = f.constant(.i32, 0), one = f.constant(.i32, 1)
    func w(_ n: Int) -> ValueID { f.append(Inst(.descword, .i32, [image.index], imm: n, payload: [key]), to: cur) }
    let isNull = emit(.icmp, .bool, [emit(.and, i32, [w(0), f.constant(.i32, 0xFFFF)]), zero], imm: ICmpPred.eq)
    func field(_ word: ValueID, shift: Int, mask: UInt64, plusOne: Bool) -> ValueID {
      var v = shift == 0 ? word : emit(.lshr, i32, [word, f.constant(.i32, UInt64(shift))])
      v = emit(.and, i32, [v, f.constant(.i32, mask)])
      if plusOne { v = emit(.iadd, i32, [v, one]) }
      return emit(.select, i32, [isNull, zero, v])
    }
    switch Int(i.op) {
    case 106:
      lv[Int(i.result)] = [field(w(2), shift: 16, mask: 31, plusOne: true)]
    case 107:
      let log = emit(.and, i32, [emit(.lshr, i32, [w(3), f.constant(.i32, 13)]), f.constant(.i32, 7)])
      lv[Int(i.result)] = [emit(.select, i32, [isNull, zero, emit(.shl, i32, [one, log])])]
    default:
      var level: ValueID? = nil
      if withLevel {
        level = try val(o[1], i)
        guard f.type(level!) == .i32 else { throw fail(i, "the level is not an integer") }
      }
      func halved(_ base: ValueID) -> ValueID {
        guard let l = level else { return base }
        let h = emit(.lshr, i32, [base, emit(.umin, i32, [l, f.constant(.i32, 31)])])
        return emit(.umax, i32, [h, one])
      }
      var comps: [ValueID] = [halved(field(w(1), shift: 0, mask: 0xFFFF, plusOne: true))]
      if dim >= 1 { comps.append(halved(field(w(1), shift: 16, mask: 0xFFFF, plusOne: true))) }
      if dim == 2 { comps.append(halved(field(w(7), shift: 0, mask: 0xFFFF, plusOne: true))) }
      if arrayed {
        var n = field(w(6), shift: 0, mask: 0xFFFF, plusOne: true)
        // The descriptor counts cubes; the result counts layer-faces.
        if dim == 3 { n = emit(.imul, i32, [n, f.constant(.i32, 6)]) }
        comps.append(n)
      }
      let want = try irType(i.type, i)
      guard want.lanes == comps.count, want.scalarKind == .i32 else {
        throw fail(i, "the result has \(want.lanes) components, the image has \(comps.count)")
      }
      lv[Int(i.result)] = [comps.count == 1 ? comps[0] : emit(.vecbuild, want, comps)]
    }
  }

  /// OpImageQueryLod: the unclamped level of detail from a TEX_GRADIENT in coordinate mode (12b.13.4), clamped here to the
  /// sampler's limits and the texture's levels and adjusted for the sampler's mipmap mode. The result is (clamped, unclamped).
  mutating func lowerQueryLod(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    guard o.count == 2, let ref = opaque[Int(o[0])], let image = ref.image, let sampler = ref.sampler else {
      throw fail(i, "needs a sampled image and coordinates")
    }
    guard case .image(_, let dim, _, _, let ms, let usage, _)? = m.type(ref.imageType), dim <= 3, usage == 1, !ms else {
      throw fail(i, "the level of detail of this image is not supported")
    }
    let cube = dim == 3
    let dims = cube ? 3 : Int(dim) + 1
    let coordinate = try val(o[1], i)
    var c: [ValueID] = []
    if dims == 1 {
      c = [coordinate]
    } else {
      guard f.type(coordinate).lanes == dims else { throw fail(i, "the coordinate has \(f.type(coordinate).lanes) components, the image needs \(dims)") }
      for k in 0..<dims { c.append(emit(.extract, .f32, [coordinate], imm: k)) }
    }
    let key = { (r: BindingRef) -> UInt64 in UInt64(r.set) << 32 | UInt64(r.binding) }
    let args = [image.index, sampler.index] + c
    let flags = TexFlags.make(kind: TexFlags.implicit, dims: dims, arrayed: false, offset: false, level: false, texel: 2, noSampler: false)
      | TexFlags.lodQuery | (cube ? TexFlags.cube : 0)
    let rawId = f.makeInst(Inst(.tex, .i32, args, imm: flags, imm2: 0, payload: [key(image), key(sampler)]))
    f.blocks[cur].insts.append(rawId)
    let raw = f.insts[rawId].result
    let i32 = IRType.i32
    func fc(_ v: Float) -> ValueID { f.constant(.f32, UInt64(v.bitPattern)) }
    func sw(_ n: Int) -> ValueID { f.append(Inst(.descword, i32, [sampler.index], imm: n, payload: [key(sampler)]), to: cur) }
    let k256 = fc(1.0 / 256), kHalf = fc(0.5), kOne = fc(1), kZero = fc(0)
    let c16 = f.constant(.i32, 16), c1fff = f.constant(.i32, 0x1FFF), c31 = f.constant(.i32, 31)
    let w1 = sw(1), w0 = sw(0)
    let tw = f.append(Inst(.descword, i32, [image.index], imm: 2, payload: [key(image)]), to: cur)
    let shifted = emit(.shl, i32, [raw, c16])
    let signed = emit(.ashr, i32, [shifted, c16])
    let lambda = emit(.fmul, .f32, [emit(.sitofp, .f32, [signed]), k256])
    let minBits = emit(.and, i32, [w1, c1fff])
    let minLod = emit(.fmul, .f32, [emit(.uitofp, .f32, [minBits]), k256])
    let maxBits = emit(.and, i32, [emit(.lshr, i32, [w1, c16]), c1fff])
    let maxLod = emit(.fmul, .f32, [emit(.uitofp, .f32, [maxBits]), k256])
    let mode = emit(.lshr, i32, [w0, f.constant(.i32, 30)])
    let levelBits = emit(.and, i32, [emit(.lshr, i32, [tw, c16]), c31])
    let levelsMinusOne = emit(.uitofp, .f32, [levelBits])
    var clamped = emit(.fmin, .f32, [emit(.fmax, .f32, [lambda, minLod]), maxLod])
    clamped = emit(.fmin, .f32, [clamped, levelsMinusOne])
    // Mode 0 (nearest) rounds half up: the ceiling of the value plus a half, less one.
    let up = emit(.fceil, .f32, [emit(.fadd, .f32, [clamped, kHalf])])
    let nearest = emit(.fsub, .f32, [up, kOne])
    let isNone = emit(.icmp, .bool, [mode, f.constant(.i32, 1)], imm: ICmpPred.eq)
    let isNearest = emit(.icmp, .bool, [mode, f.constant(.i32, 0)], imm: ICmpPred.eq)
    let inner = emit(.select, .f32, [isNearest, nearest, clamped])
    let adjusted = emit(.select, .f32, [isNone, kZero, inner])
    lv[Int(i.result)] = [emit(.vecbuild, .vector(.f32, 2), [adjusted, lambda])]
  }

  // MARK: derivatives and helper invocations

  /// OpDPdx, OpDPdy, OpFwidth and their Fine and Coarse forms (13.10.2). OpDPdx and OpDPdy are the coarse ones, which are
  /// cheaper; OpFwidth is |dPdx| + |dPdy| of the same kind.
  mutating func lowerDerivative(_ i: SPIRVInstruction) throws(CompileError) {
    guard stageModel == 4 else {
      throw fail(i, "a derivative outside a fragment shader (a compute shader's quads need the local id remap of 14.2.2)")
    }
    let code = Int(i.op)
    let fine = code == 210 || code == 211 || code == 212
    let width = code == 209 || code == 212 || code == 215
    let y = code == 208 || code == 211 || code == 214
    let p = try val(i.operands[0], i)
    let t = f.type(p)
    guard t.scalarKind == .f32 else { throw fail(i, "a derivative of a type other than f32 (16-bit floats are not done)") }
    var out: [ValueID] = []
    for k in 0..<t.lanes {
      let e = t.isVector ? emit(.extract, .f32, [p], imm: k) : p
      func d(_ axis: Int) -> ValueID { emit(.deriv, .f32, [e], imm: axis | (fine ? 2 : 0)) }
      if width {
        out.append(emit(.fadd, .f32, [emit(.fabs, .f32, [d(0)]), emit(.fabs, .f32, [d(1)])]))
      } else {
        out.append(d(y ? 1 : 0))
      }
    }
    lv[Int(i.result)] = [t.isVector ? emit(.vecbuild, t, out) : out[0]]
  }

  mutating func lowerHelperQuery(_ i: SPIRVInstruction) throws(CompileError) {
    guard stageModel == 4 else { throw fail(i, "OpIsHelperInvocationEXT is for fragment shaders") }
    lv[Int(i.result)] = [f.append(Inst(.builtin, .bool, [], imm: IRBuiltin.helperInvocation, imm2: -1), to: cur)]
  }
}
