// SPDX-License-Identifier: BSD-3-Clause

// The dispatch runner and the instruction step: contexts, branches,
// reconvergence, discard, barriers (valhall 13), over the warps of one
// workgroup at a time. Deterministic: workgroups run in grid order (x
// fastest), warps in index order, each until it ends or reaches a barrier.

/// Runs `shader` over every workgroup of the grid and returns what it did. `memory` is changed in place.
public func runDispatch(_ shader: Shader, _ config: DispatchConfig, memory: GpuMemory) throws -> RunReport {
  var report = RunReport()
  let g = config.grid
  var linear = 0
  for z in 0..<g.z {
    for y in 0..<g.y {
      for x in 0..<g.x {
        let ex = Executor(shader: shader, cfg: config, mem: memory, wg: Dim3(x, y, z), linear: linear)
        try ex.runWorkgroup(&report)
        linear += 1
      }
    }
  }
  return report
}

final class Executor {
  let code: [Instr]
  let cfg: DispatchConfig
  let mem: GpuMemory
  let wg: Dim3
  let workgroupLinear: Int
  var currentPc = 0
  var instructions = 0
  var barriers = 0

  init(shader: Shader, cfg: DispatchConfig, mem: GpuMemory, wg: Dim3, linear: Int) {
    code = shader.code
    self.cfg = cfg
    self.mem = mem
    self.wg = wg
    workgroupLinear = linear
  }

  func runWorkgroup(_ report: inout RunReport) throws {
    let size = cfg.workgroupSize.count
    let count = (size + 15) / 16
    if cfg.sharedBytes > 0 {
      let base = cfg.sharedBase &+ UInt64(workgroupLinear) &* UInt64(cfg.sharedBytes)
      mem.map(base, size: cfg.sharedBytes, fill: cfg.poison ?? 0)
      if cfg.poison != nil { fillPoison(base, cfg.sharedBytes) }
    }
    if cfg.threadLocalBytes > 0 {
      let first = UInt64(workgroupLinear) * UInt64(size)
      let base = cfg.tlsBase &+ first &* UInt64(cfg.threadLocalBytes)
      let bytes = size * cfg.threadLocalBytes
      mem.map(base, size: bytes, fill: cfg.poison ?? 0)
      if cfg.poison != nil { fillPoison(base, bytes) }
    }
    var warps: [Warp] = []
    for i in 0..<count {
      let n = min(16, size - 16 * i)
      let w = Warp(index: i, mask: n == 16 ? 0xFFFF : UInt16((1 << n) - 1))
      w.discarded = cfg.helperMask & w.ctxs[0].mask
      preload(w)
      warps.append(w)
    }
    report.workgroups += 1
    report.warps += count
    while true {
      var anyBarrier = false
      var anyFinished = false
      for w in warps where !w.finished && !w.atBarrier {
        while true {
          let r: StepResult
          do {
            r = try step(w)
          } catch let f as Fault {
            throw InterpError(fault: f, workgroup: wg, warp: w.index, pc: currentPc)
          }
          if r == .barrier || r == .finished { break }
        }
      }
      for w in warps {
        if w.atBarrier { anyBarrier = true }
        if w.finished { anyFinished = true }
      }
      if !anyBarrier { break }
      if anyFinished {
        let w = warps.first { $0.atBarrier }!
        throw InterpError(fault: .barrierNotUniform, workgroup: wg, warp: w.index, pc: currentPc)
      }
      for w in warps { w.atBarrier = false }
      barriers += 1
    }
    for w in warps { completeSlots(w, 0xFF) }
    if cfg.captureFirstWarp && workgroupLinear == 0 { report.firstWarpRegisters = warps[0].regs }
    report.instructions += instructions
    report.barriers += barriers
    instructions = 0
    barriers = 0
  }

  private func fillPoison(_ base: UInt64, _ bytes: Int) {
    guard let p = cfg.poison else { return }
    for i in 0..<bytes { mem.writeLE(base &+ UInt64(i), size: 1, value: UInt64(p)) }
  }

  /// The compute ABI's preloaded registers (14 §14.2.1).
  private func preload(_ w: Warp) {
    let s = cfg.workgroupSize
    for lane in 0..<16 {
      let idx = UInt32(w.index * 16 + lane)
      let lx = idx % s.x
      let ly = (idx / s.x) % s.y
      let lz = idx / (s.x * s.y)
      func set(_ r: Int, _ v: UInt32) { w.regs[lane * 64 + r] = v }
      set(55, lx | ly << 16)
      set(56, lz)
      set(57, wg.x)
      set(58, wg.y)
      set(59, wg.z)
      set(60, wg.x &* s.x &+ lx)
      set(61, wg.y &* s.y &+ ly)
      set(62, wg.z &* s.z &+ lz)
      if let hook = cfg.registerInit {
        var regs = Array(w.regs[(lane * 64)..<(lane * 64 + 64)])
        hook(w.index * 16 + lane, &regs)
        for r in 0..<64 { set(r, regs[r]) }
      }
    }
  }

  // MARK: One instruction

  func pick(_ w: Warp) -> Int? {
    var best: Int?
    for (i, c) in w.ctxs.enumerated() where !c.parked && (best == nil || c.pc < w.ctxs[best!].pc) { best = i }
    if best == nil {
      for (i, c) in w.ctxs.enumerated() where best == nil || c.pc < w.ctxs[best!].pc { best = i }
      if let b = best { w.ctxs[b].parked = false }
    }
    return best
  }

  func step(_ w: Warp) throws -> StepResult {
    guard let ci = pick(w) else { return .finished }
    let ctx = w.ctxs[ci]
    currentPc = ctx.pc
    guard ctx.pc >= 0 && ctx.pc < code.count else { throw Fault.pcOutOfRange(ctx.pc) }
    w.steps += 1
    if w.steps > cfg.maxStepsPerWarp { throw Fault.stepLimit }
    instructions += 1
    let ins = code[ctx.pc]
    if ins.op == .barrier {
      let general = UInt8(truncatingIfNeeded: w.busy.enumerated().reduce(0) { $0 | ($1.1 > 0 && $1.0 < 3 ? 1 << $1.0 : 0) })
      if general != 0 { throw Fault.barrierWithBusySlots(slots: general) }
      if w.ctxs.count != 1 { throw Fault.barrierNotUniform }
    }
    try checkFau(ins)
    w.lastUse.removeAll(keepingCapacity: true)
    w.wrote.removeAll(keepingCapacity: true)
    var next: [Ctx] = []
    var result = StepResult.ran
    let mask = ctx.mask
    switch ins.op {
    case .nop:
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .branch, .jump:
      next = try branch(w, ctx, ins)
    case .discard:
      try forLanes(w, mask) { lane in
        let a = try src32(w, lane, ins, ins.s0)
        let b = try src32(w, lane, ins, ins.s1)
        if fcmpTest(ins, a: a, b: b) { w.discarded |= 1 << UInt16(lane) }
      }
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .barrier:
      result = .barrier
      w.atBarrier = true
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .clper, .wmask:
      try crossLane(w, ctx, ins)
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .texFetch:
      if cfg.textures != nil { try texFetchModel(w, ctx, ins) } else { try texFetch(w, ctx, ins) }
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .texSingle:
      try texSample(w, ctx, ins)
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .texGather:
      try texGatherOp(w, ctx, ins)
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .texGradient:
      try texGradientOp(w, ctx, ins)
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .ldVarBufImm, .ldVarSpecial:
      try varyingLoad(w, ctx, ins)
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .atest, .zsEmit, .blend:
      try fragmentOutput(w, ctx, ins)
      // A BLEND that writes skips forward by its offset (the call sequence of a blend shader, 09 section 9.8.2); in mode Shader it
      // does nothing and the next instruction follows.
      next = [Ctx(pc: ctx.pc + 1 + (ins.op == .blend && !blendIsShader(ins) ? Int(ins.offset) : 0), mask: mask)]
    case .ldTile:
      try tileLoad(w, ctx, ins)
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    case .ldTex, .leaTex:
      try imageAccess(w, ctx, ins)
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    default:
      try forLanes(w, mask) { lane in try execLane(w, lane, ins) }
      next = [Ctx(pc: ctx.pc + 1, mask: mask)]
    }
    // A wait in the flow field takes effect after its instruction (the board; docs/gpu/valhall-board-findings.md), and
    // covers the message that instruction issues on a slot it names.
    completeSlots(w, ins.flow.waitSlots)
    if cfg.strictLastUse {
      for lane in w.lanes(mask) {
        for r in w.lastUse where !w.wrote.contains(r) { w.dead[lane * 64 + r] = true }
      }
    }
    w.ctxs.remove(at: ci)
    switch ins.flow {
    case .end where ins.op == .blend && blendIsShader(ins):
      // The flow `end` and the offset are ignored in mode Shader (09 section 9.8.1).
      break
    case .end:
      next = []
    case .reconverge:
      for i in next.indices { next[i].parked = true }
    default: break
    }
    for n in next where n.mask != 0 { w.ctxs.append(n) }
    if ins.flow == .discard {
      let d = w.discarded
      for i in w.ctxs.indices { w.ctxs[i].mask &= ~d }
      w.ctxs.removeAll { $0.mask == 0 }
    }
    mergeParked(w)
    if w.finished { return .finished }
    return result
  }

  func forLanes(_ w: Warp, _ mask: UInt16, _ body: (Int) throws -> Void) throws {
    for lane in 0..<16 where mask & (1 << UInt16(lane)) != 0 { try body(lane) }
  }

  /// Parked contexts at one pc become one.
  func mergeParked(_ w: Warp) {
    var out: [Ctx] = []
    for c in w.ctxs {
      if c.parked, let i = out.firstIndex(where: { $0.parked && $0.pc == c.pc }) {
        out[i].mask |= c.mask
      } else {
        out.append(c)
      }
    }
    w.ctxs = out
  }

  // MARK: Branches (13 §13.4)

  func branchTaken(_ ins: Instr, _ v: UInt32) -> Bool {
    let c: Bool
    switch ins.combine {
    case 1: c = v & 0xFFFF != 0
    case 2: c = v >> 16 != 0
    case 3: c = v == 0xFFFF_FFFF
    case 4:
      let m = (v >> 3) & 0x3FFFF
      c = m != 0 && m != 0x3FFFF
    default: c = v != 0
    }
    return ins.not ? !c : c
  }

  func branch(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws -> [Ctx] {
    var targets: [Int: UInt16] = [:]
    var fall: UInt16 = 0
    var ended: UInt16 = 0
    try forLanes(w, ctx.mask) { lane in
      let bit = UInt16(1) << UInt16(lane)
      guard branchTaken(ins, try src32(w, lane, ins, ins.s0)) else {
        fall |= bit
        return
      }
      if ins.op == .branch {
        targets[ctx.pc + 1 + Int(ins.offset), default: 0] |= bit
      } else {
        let addr = UInt64(try src32(w, lane, ins, ins.s1))
        if addr == 0 {
          ended |= bit  // a jump to address 0 ends the thread (13 §13.4.2)
        } else {
          guard addr >= cfg.codeBase, (addr - cfg.codeBase) % 8 == 0 else { throw Fault.invalid("jump target \(addr)") }
          targets[Int((addr - cfg.codeBase) / 8), default: 0] |= bit
        }
      }
    }
    var out: [Ctx] = []
    if fall != 0 { out.append(Ctx(pc: ctx.pc + 1, mask: fall)) }
    for t in targets.keys.sorted() { out.append(Ctx(pc: t, mask: targets[t]!)) }
    return out
  }
}
