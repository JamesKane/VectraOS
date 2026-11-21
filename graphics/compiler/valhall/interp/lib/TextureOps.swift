// SPDX-License-Identifier: BSD-3-Clause

// TEX_SINGLE, TEX_FETCH, TEX_GATHER and TEX_GRADIENT over the texture model (Texture.swift; valhall 12b.5 to 12b.8).
//
// The handle `H` is the wide form (12b.2.1: word 0 the sampler's handle, word 1 the texture's), one value for the
// warp. The staging read block holds the operands in the order of 12b.5, absent ones left out; the result block the
// channels of the write mask in order, 32 bits each. The packed handle form and 16-bit results are not modelled, and a
// face-packed cube coordinate is not (the cube is read in the direction form).
//
// The level of detail of a computed mode is the quad's: the coordinates of lanes 4q, 4q+1 and 4q+2 differ along x and
// along y (13.10.1), the same for the four lanes of the quad (the coarse derivative). A lane of the quad not executing
// the instruction gives a zero difference (the spec leaves a quad whose neighbour is neither live nor a helper open,
// 12b.6). A discarded lane executes normally unless the instruction has `skip`, which makes its result zero (13.6.4).

/// The fields of a texture instruction (12b.4 to 12b.8), as the decoder reads them.
public struct TexFields: Sendable {
  public var wide = false
  public var project = false
  public var array = false
  public var texelOffset = false
  public var compare = false
  /// 12b.4's lod mode: 0 none, 1 computed, 3 computed force delta, 4 explicit, 5 computed bias, 6 grdesc, 7 bias force delta.
  public var lod: UInt8 = 0
  public var dim: UInt8 = 1
  public var mask: UInt8 = 15
  public var gatherComponent: UInt8 = 0
  public var integerCoordinates = false
  public var derivative = false
  public var forceDelta = false
  public var biasDisable = false
  public var clampDisable = false
  public var skip = false
  public var dst32 = true
  public init() {}
}

extension Executor {
  struct TexLane {
    var coords: [Float] = []
    var array = 0
    var compare: Float = 0
    var offset: UInt32 = 0
    var lodWord: UInt32 = 0
    var gradient: [UInt32] = []
    var ints: [UInt32] = []
  }

  /// The handles of the lanes that run the instruction, which must agree (12b.2.1).
  func texHandles(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws -> (sampler: UInt32, texture: UInt32)? {
    guard ins.tex.wide else { throw Fault.invalid("\(ins.op): the packed handle form is not modelled") }
    guard ins.tex.dst32 else { throw Fault.invalid("\(ins.op): 16-bit results are not modelled") }
    var seen: (UInt32, UInt32)?
    for lane in w.lanes(ctx.mask) {
      let h = try src64(w, lane, ins, ins.s0)
      let pair = (UInt32(truncatingIfNeeded: h), UInt32(truncatingIfNeeded: h >> 32))
      if let s = seen, s != pair {
        throw Fault.invalid("a texture or sampler handle that differs between the lanes of a warp (12b.2.1): \(s) and \(pair)")
      }
      seen = pair
    }
    return seen.map { (sampler: $0.0, texture: $0.1) }
  }

  func texModel(_ handle: UInt32, _ ins: Instr) throws -> TextureModel {
    guard let lookup = cfg.textures else { throw Fault.invalid("\(ins.op): the run has no texture model") }
    guard let t = lookup(handle) else { throw Fault.invalid("\(ins.op): texture handle \(handle) names no texture of the model") }
    return t
  }

  func samplerModel(_ handle: UInt32, _ ins: Instr) throws -> SamplerModel {
    guard let lookup = cfg.samplers else { throw Fault.invalid("\(ins.op): the run has no sampler model") }
    guard let s = lookup(handle) else { throw Fault.invalid("\(ins.op): sampler handle \(handle) names no sampler of the model") }
    return s
  }

  func f32(_ v: UInt32) -> Float { Float(bitPattern: v) }

  /// The lane's staging words, in the order of 12b.5.1 (sample), 12b.5.7 (gather) or 12b.5.8 (gradient).
  func texLane(_ w: Warp, _ lane: Int, _ ins: Instr) throws -> TexLane {
    let t = ins.tex
    let nc = [1, 2, 3, 3][Int(t.dim)]
    var count = nc
    switch ins.op {
    case .texGather:
      count = 2
      if t.project { count += 1 }
    case .texGradient:
      count = (t.dim == 3 ? 2 : nc) << (t.derivative ? 1 : 0)
      if t.project { count += 1 }
    default:
      if t.dim == 3 { count = t.project ? 3 : 2 }
      if t.project && t.dim != 3 { count += 1 }
    }
    if ins.op != .texGradient {
      if t.array { count += 1 }
      if t.compare { count += 1 }
      if t.texelOffset { count += 1 }
    }
    switch t.lod {
    case 4, 5, 7: if ins.op == .texSingle { count += 1 }
    case 6: if ins.op == .texSingle { count += 2 }
    default: break
    }
    let b = try stagingBlock(w, lane, first: Int(ins.dst), count: count)
    var lane = TexLane()
    var at = 0
    func next() -> UInt32 {
      defer { at += 1 }
      return b[at]
    }
    switch ins.op {
    case .texGradient:
      if t.derivative {
        for _ in 0..<(t.dim == 3 ? 2 : nc) * 2 { lane.gradient.append(next()) }
      } else {
        for _ in 0..<(t.dim == 3 ? 2 : nc) { lane.coords.append(f32(next())) }
      }
      if t.project { lane.coords.append(f32(next())) }
      return lane
    case .texGather:
      lane.coords = [f32(next()), f32(next())]
      if t.project { lane.coords.append(f32(next())) }
    default:
      if t.dim == 3 {
        guard t.project else { throw Fault.invalid("a cube sample in the face-packed form is not modelled") }
        lane.coords = [f32(next()), f32(next()), f32(next())]
      } else {
        for _ in 0..<nc { lane.coords.append(f32(next())) }
        if t.project {
          let q = f32(next())
          lane.coords = lane.coords.map { $0 / q }
        }
      }
    }
    if t.array { lane.array = Int(next()) }
    if t.compare { lane.compare = f32(next()) }
    if t.texelOffset { lane.offset = next() }
    switch t.lod {
    case 4, 5, 7: if ins.op == .texSingle { lane.lodWord = next() }
    case 6: if ins.op == .texSingle { lane.gradient = [next(), next()] }
    default: break
    }
    return lane
  }

  func texOffset(_ word: UInt32) -> (Int, Int, Int) {
    func s(_ b: UInt32) -> Int { Int(Int8(truncatingIfNeeded: word >> b)) }
    return (s(0), s(8), s(16))
  }

  func s88(_ v: UInt32) -> Float { Float(Int16(truncatingIfNeeded: v)) / 256 }

  func writeTexel(_ w: Warp, _ lane: Int, _ ins: Instr, _ texel: [UInt32]) throws {
    var out: [UInt32] = []
    for c in 0..<4 where ins.tex.mask & (1 << UInt8(c)) != 0 { out.append(c < texel.count ? texel[c] : 0) }
    try issueResult(w, lane, first: Int(ins.writeReg), out, slot: Int(ins.slot))
  }

  /// The base level of detail of `lane`'s quad for a computed mode, from the coordinates the quad's lanes staged.
  func quadLod(_ w: Warp, _ ctx: Ctx, _ lane: Int, _ ins: Instr, _ tex: TextureModel, _ mine: TexLane) throws -> Float {
    let q = lane & ~3
    func coords(_ l: Int) throws -> [Float]? {
      guard ctx.mask & (1 << UInt16(l)) != 0 else { return nil }
      return l == lane ? mine.coords : try texLane(w, l, ins).coords
    }
    guard let origin = try coords(q) else { return -Float.infinity }
    let n = origin.count
    func diff(_ l: Int) throws -> [Float] {
      guard let c = try coords(l) else { return [Float](repeating: 0, count: n) }
      return (0..<n).map { c[$0] - origin[$0] }
    }
    let dx = try diff(q + 1), dy = try diff(q + 2)
    if tex.dim == .cube { return tex.cubeBaseLod(origin, dx: dx, dy: dy) }
    return tex.baseLod(dx: dx, dy: dy)
  }

  /// The level of detail a sample uses, after the bias and the clamp, from its lod mode.
  func sampleLod(_ w: Warp, _ ctx: Ctx, _ lane: Int, _ ins: Instr, _ tex: TextureModel, _ s: SamplerModel, _ l: TexLane) throws -> Float {
    var lod: Float
    switch ins.tex.lod {
    case 0: lod = 0
    case 1, 3: lod = try quadLod(w, ctx, lane, ins, tex, l)
    case 5, 7: lod = try quadLod(w, ctx, lane, ins, tex, l) + s88(l.lodWord)
    case 4: lod = s88(l.lodWord)
    case 6: lod = s88(l.gradient[0])
    default: throw Fault.invalid("TEX_SINGLE: lod mode \(ins.tex.lod)")
    }
    lod += s.bias
    var lo = s.minLod
    if ins.tex.lod == 5 || ins.tex.lod == 7 { lo = max(lo, s88(l.lodWord >> 16)) }
    return min(max(lod, lo), s.maxLod)
  }

  /// TEX_SINGLE.
  func texSample(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    guard let h = try texHandles(w, ctx, ins) else { return }
    let tex = try texModel(h.texture, ins)
    let smp = try samplerModel(h.sampler, ins)
    for lane in w.lanes(ctx.mask) {
      let l = try texLane(w, lane, ins)
      if ins.tex.skip && isDiscarded(w, lane) {
        try writeTexel(w, lane, ins, [0, 0, 0, 0])
        continue
      }
      let lod = try sampleLod(w, ctx, lane, ins, tex, smp, l)
      let o = ins.tex.texelOffset ? texOffset(l.offset) : (0, 0, 0)
      try writeTexel(
        w, lane, ins, tex.sample(smp, l.coords, layer: l.array, lod: lod, offset: o, compare: ins.tex.compare ? l.compare : nil))
    }
  }

  /// TEX_GATHER.
  func texGatherOp(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    guard let h = try texHandles(w, ctx, ins) else { return }
    guard !ins.tex.integerCoordinates else { throw Fault.invalid("TEX_GATHER: integer coordinates are not modelled (12b.5.7)") }
    let tex = try texModel(h.texture, ins)
    let smp = try samplerModel(h.sampler, ins)
    for lane in w.lanes(ctx.mask) {
      let l = try texLane(w, lane, ins)
      let o = ins.tex.texelOffset ? texOffset(l.offset) : (0, 0, 0)
      try writeTexel(
        w, lane, ins,
        tex.gather(smp, l.coords, layer: l.array, component: Int(ins.tex.gatherComponent), offset: o, compare: ins.tex.compare ? l.compare : nil))
    }
  }

  /// TEX_GRADIENT: the two-word gradient descriptor (12b.5.6, 12b.13.4): the level of detail as s8.8 in the low half
  /// of word 0 (the model puts nothing in the rest).
  func texGradientOp(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    guard let h = try texHandles(w, ctx, ins) else { return }
    let tex = try texModel(h.texture, ins)
    let smp = try samplerModel(h.sampler, ins)
    for lane in w.lanes(ctx.mask) {
      let l = try texLane(w, lane, ins)
      var lod: Float
      if ins.tex.derivative {
        let n = l.gradient.count / 2
        var dx: [Float] = [], dy: [Float] = []
        for i in 0..<n {
          dx.append(f32(l.gradient[2 * i]))
          dy.append(f32(l.gradient[2 * i + 1]))
        }
        lod = tex.dim == .cube ? tex.baseLod(dx: dx, dy: dy) : tex.baseLod(dx: dx, dy: dy)
      } else {
        lod = try quadLod(w, ctx, lane, ins, tex, l)
      }
      if !ins.tex.biasDisable { lod += smp.bias }
      if !ins.tex.clampDisable { lod = min(max(lod, smp.minLod), smp.maxLod) }
      let word = UInt32(UInt16(bitPattern: Int16(min(max((lod * 256).rounded(), -32768), 32767))))
      try writeTexel(w, lane, ins, [word, 0, 0, 0])
    }
  }

  /// TEX_FETCH over the texture model: the level is byte 3 of the offset word, the sample of a multisampled texture byte 2.
  func texFetchModel(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    guard let h = try texHandles(w, ctx, ins) else { return }
    let tex = try texModel(h.texture, ins)
    let t = ins.tex
    let nc = [1, 2, 3][Int(min(t.dim, 2))]
    for lane in w.lanes(ctx.mask) {
      let count = nc + (t.array ? 1 : 0) + (t.texelOffset ? 1 : 0)
      let b = try stagingBlock(w, lane, first: Int(ins.dst), count: count)
      var c = (0..<nc).map { Int(Int32(bitPattern: b[$0])) }
      while c.count < 3 { c.append(0) }
      var layer = 0
      var at = nc
      if t.array {
        layer = Int(b[at])
        at += 1
      }
      var level = 0
      var sample = 0
      if t.texelOffset {
        let o = b[at]
        level = Int(o >> 24)
        if tex.samples > 1 {
          sample = Int(o >> 16 & 0xFF)
          c[0] += Int(Int8(truncatingIfNeeded: o))
          c[1] += Int(Int8(truncatingIfNeeded: o >> 8))
        } else {
          let off = texOffset(o)
          c[0] += off.0
          c[1] += off.1
          c[2] += off.2
        }
      }
      let texel = tex.fetch(x: c[0], y: c[1], z: c[2], layer: layer, level: level, sample: sample) ?? [0, 0, 0, 0]
      try writeTexel(w, lane, ins, texel)
    }
  }
}
