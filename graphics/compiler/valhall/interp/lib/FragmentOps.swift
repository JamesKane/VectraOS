// SPDX-License-Identifier: BSD-3-Clause

// The fragment stage's fixed-function side over a test model (valhall 12c.5 and 12c.6): LD_VAR_BUF_IMM, LD_VAR_SPECIAL,
// ATEST, ZS_EMIT and BLEND.
//
// The hardware reads the vertex packet and interpolates, and hands the colour to the blender. The model has a closure
// for each varying the shader loads, a closure for the special varyings, and it keeps what the shader hands on: the
// colour of each lane for each render target, the depth and stencil a lane emitted. A discarded or helper lane writes
// nothing at BLEND, and a lane with no coverage left at BLEND writes nothing either (12c.6.3, 14.4.3). ATEST forwards the
// coverage minus the discarded lanes (alpha-to-coverage is not modelled); ZS_EMIT forwards it unchanged. The hidden
// interpolation register (12c.2.4) is not modelled: the closure is given the position the load names.

/// What a fragment run's varyings are, and what it produced.
public final class FragmentModel: @unchecked Sendable {
  /// The interpolated value of `count` components at byte `offset` of the generic varying block, for `lane`, at the
  /// position the load names (0 center, 1 centroid, 2 sample).
  public var varying: @Sendable (_ lane: Int, _ offset: Int, _ count: Int, _ position: Int) -> [UInt32]
  /// The provoking vertex's raw words, for a flat varying.
  public var flat: @Sendable (_ lane: Int, _ offset: Int, _ count: Int) -> [UInt32]
  /// A special varying: 0 `point` (two components), 2 `frag_w`, 3 `frag_z` (one).
  public var special: @Sendable (_ lane: Int, _ name: Int, _ position: Int) -> [UInt32]

  /// What the run produced: by lane, the colour words of each render target.
  public var colours: [[Int: [UInt32]]] = Array(repeating: [:], count: 16)
  /// By lane, the depth and stencil a ZS_EMIT gave.
  public var depth: [UInt32?] = Array(repeating: nil, count: 16)
  public var stencil: [UInt32?] = Array(repeating: nil, count: 16)
  /// By lane, the coverage the last BLEND read.
  public var blendCoverage: [UInt32] = Array(repeating: 0, count: 16)
  /// The tile buffer, by lane: the pixel (packed RGBA8, byte 0 red) of each render target. A blend shader reads it with LD_TILE and
  /// writes it with an opaque BLEND (12c.7.1, 09 section 9.10); the run starts from what a test puts here.
  public var tile: [[Int: UInt32]] = Array(repeating: [:], count: 16)
  /// The blend descriptors the draw has, by render target: the mode of word 2 (0 shader, 1 opaque, 2 fixed function, 3 off) and
  /// words 2 and 3, which the special entries of page 0 read (09 section 9.2.3). A target with none is opaque.
  public var blendDescriptors: [Int: (mode: Int, word2: UInt32, word3: UInt32)] = [:]

  public init(
    varying: @escaping @Sendable (Int, Int, Int, Int) -> [UInt32] = { _, _, c, _ in [UInt32](repeating: 0, count: c) },
    flat: @escaping @Sendable (Int, Int, Int) -> [UInt32] = { _, _, c in [UInt32](repeating: 0, count: c) },
    special: @escaping @Sendable (Int, Int, Int) -> [UInt32] = { _, _, _ in [0, 0] }
  ) {
    self.varying = varying
    self.flat = flat
    self.special = special
  }
}

extension Executor {
  /// A BLEND whose target's descriptor is in mode Shader: it does nothing (09 section 9.8.1).
  func blendIsShader(_ ins: Instr) -> Bool {
    ins.s0 >> 5 == 0b111 && cfg.fragment?.blendDescriptors[Int((ins.s0 >> 1) & 15) - 8]?.mode == 0
  }

  func fragmentModel(_ ins: Instr) throws -> FragmentModel {
    guard let m = cfg.fragment else { throw Fault.invalid("\(ins.op): the run has no fragment model") }
    return m
  }

  /// LD_VAR_BUF_IMM and LD_VAR_SPECIAL: the lanes' values, held until the slot is waited on.
  func varyingLoad(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    let m = try fragmentModel(ins)
    let n = Int(ins.imm)
    for lane in w.lanes(ctx.mask) {
      var v: [UInt32]
      if ins.op == .ldVarSpecial {
        v = m.special(lane, n, Int(ins.special))
        v = Array(v.prefix(Int(ins.lane)))
        while v.count < Int(ins.lane) { v.append(0) }
      } else if ins.access == 1 {
        v = m.flat(lane, Int(ins.offset), n)
      } else {
        v = m.varying(lane, Int(ins.offset), n, Int(ins.special))
      }
      try issueResult(w, lane, first: Int(ins.dst), v, slot: Int(ins.slot))
    }
  }

  /// ATEST, ZS_EMIT and BLEND. The sources of every lane are read before the results are issued: a result in flight
  /// makes its register unreadable for the warp (the model's `pendReg` is not per lane).
  func fragmentOutput(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    let m = try fragmentModel(ins)
    var results: [(lane: Int, value: UInt32)] = []
    for lane in w.lanes(ctx.mask) {
      switch ins.op {
      case .atest:
        let coverage = try src32(w, lane, ins, ins.s0)
        _ = try src32(w, lane, ins, ins.s1)
        results.append((lane, isDiscarded(w, lane) ? 0 : coverage))
      case .zsEmit:
        let z = try src32(w, lane, ins, ins.s0)
        let s = try src32(w, lane, ins, ins.s1)
        let coverage = try src32(w, lane, ins, ins.s2)
        if ins.imm & 1 != 0 { m.depth[lane] = z }
        if ins.imm & 2 != 0 { m.stencil[lane] = s }
        results.append((lane, coverage))
      default:
        let coverage = try src32(w, lane, ins, ins.s2)
        w.busy[Int(ins.slot)] = 1
        if ins.s0 >> 5 == 0b111 {
          // A fragment shader's BLEND names the descriptor of its target. In mode Shader it does nothing (09 section 9.8.1): the
          // shader the descriptor names writes the tile.
          let target = Int((ins.s0 >> 1) & 15) - 8
          if m.blendDescriptors[target]?.mode == 0 { continue }
          let block = try stagingBlock(w, lane, first: Int(ins.dst), count: 4)
          m.blendCoverage[lane] = coverage
          if isDiscarded(w, lane) || coverage & 0xFFFF == 0 { continue }
          m.colours[lane][target] = block
        } else {
          // An opaque BLEND of a blend shader: the operand is words 2 and 3 of a descriptor, in a register pair (09 section 9.10).
          let operand = try src64(w, lane, ins, ins.s0)
          let half = ins.special == 3
          let block = try stagingBlock(w, lane, first: Int(ins.dst), count: half ? 2 : 4)
          m.blendCoverage[lane] = coverage
          if operand & 3 != 1 { throw Fault.invalid("a BLEND in a register pair that is not opaque: mode \(operand & 3)") }
          if isDiscarded(w, lane) || coverage & 0xFFFF == 0 { continue }
          let target = Int((operand >> 16) & 15)
          m.tile[lane][target] = try TileFormat.encode(block, half: half, conversion: UInt32(truncatingIfNeeded: operand >> 32))
        }
      }
    }
    for r in results { try issueResult(w, r.lane, first: Int(ins.dst), [r.value], slot: 0) }
  }
}
