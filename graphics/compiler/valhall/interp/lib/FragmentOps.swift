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

  /// ATEST, ZS_EMIT and BLEND.
  func fragmentOutput(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    let m = try fragmentModel(ins)
    for lane in w.lanes(ctx.mask) {
      switch ins.op {
      case .atest:
        let coverage = try src32(w, lane, ins, ins.s0)
        _ = try src32(w, lane, ins, ins.s1)
        try issueResult(w, lane, first: Int(ins.dst), [isDiscarded(w, lane) ? 0 : coverage], slot: 0)
      case .zsEmit:
        let z = try src32(w, lane, ins, ins.s0)
        let s = try src32(w, lane, ins, ins.s1)
        let coverage = try src32(w, lane, ins, ins.s2)
        if ins.imm & 1 != 0 { m.depth[lane] = z }
        if ins.imm & 2 != 0 { m.stencil[lane] = s }
        try issueResult(w, lane, first: Int(ins.dst), [coverage], slot: 0)
      default:
        let coverage = try src32(w, lane, ins, ins.s2)
        let block = try stagingBlock(w, lane, first: Int(ins.dst), count: 4)
        let target = Int((ins.s0 >> 1) & 15) - 8
        w.busy[Int(ins.slot)] = 1
        m.blendCoverage[lane] = coverage
        if isDiscarded(w, lane) || coverage & 0xFFFF == 0 { continue }
        m.colours[lane][target] = block
      }
    }
  }
}
