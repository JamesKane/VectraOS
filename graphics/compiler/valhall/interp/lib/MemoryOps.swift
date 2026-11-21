// SPDX-License-Identifier: BSD-3-Clause

// Memory instructions (valhall 12a): LOAD and STORE of every width,
// atomics, and the subgroup instructions CLPER and WMASK (13 §13.9).
//
// MESSAGE MODEL. A load or atomic with a result reads memory when it
// issues, and holds the result back until a flow wait, carried by it or an earlier instruction and taking effect after its carrier, names its slot
// (10 §10.9.1); a store or atomic without a result writes memory at issue
// but keeps its slot busy until waited on. The hardware's ordering is
// weaker than this (12a §12a.1.5), so a shader that is right here and
// follows the spec's wait rules is right there; a missed wait before a
// read of the result, or before a `BARRIER`, is reported.
//
// Choices where the spec is open: a load with access `none` runs in a
// discarded lane (12a §12a.1.4); the bits of an `i24`/`i48` load above
// the loaded value are zero; an out-of-range lane number of `CLPER` is
// taken modulo the subgroup size; `WMASK` of a subgroup smaller than 16
// gives each group its own mask in the low bits, over the lanes active in
// the current context.

extension Executor {
  func execLane(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    switch ins.op {
    case .fadd, .faddImm, .faddLscale, .fma, .fmaRscale, .fmin, .fmax, .fcmp, .csel, .flush, .fround, .ldexp:
      try execFloat(w, lane, ins)
    case .iadd, .isub, .imul, .iaddImm, .andImm, .orImm, .xorImm, .idpadd, .iabs, .icmp, .icmpMulti, .mux,
      .shift, .mov, .mkvecV2i16, .mkvecV2i8, .clz, .popcount, .bitrev, .shadd, .segAdd:
      try execInt(w, lane, ins)
    case .s8ToS32, .u8ToU32, .s16ToS32, .u16ToU32, .v2s8ToV2s16, .v2u8ToV2u16, .s32ToF32, .u32ToF32, .f32ToS32,
      .f32ToU32, .f16ToF32:
      try execConvert(w, lane, ins)
    case .frcp, .frsq, .flogd, .flog, .fexp, .fpow, .frexpm, .frexpe, .fsinTable, .fcosTable, .fexpTable:
      try execSpecial(w, lane, ins)
    case .load: try load(w, lane, ins)
    case .leaBufImm:
      let index = Int(ins.imm)
      guard index < cfg.hardwareBuffers.count else { throw Fault.invalid("LEA_BUF_IMM names buffer \(index), which the run has no model of") }
      let b = cfg.hardwareBuffers[index]
      let element = UInt64(try src32(w, lane, ins, ins.s0))
      let a = b.base &+ element &* b.stride
      try issueResult(w, lane, first: Int(ins.dst), [UInt32(truncatingIfNeeded: a), UInt32(truncatingIfNeeded: a >> 32)], slot: Int(ins.slot))
    case .store: try store(w, lane, ins)
    case .atom, .atom1, .atom1Return, .atomReturn, .acmpxchg: try atomic(w, lane, ins)
    default: throw Fault.invalid("\(ins.op) reached the lane executor")
    }
  }

  // MARK: Addresses and bytes

  func address(_ w: Warp, _ lane: Int, _ ins: Instr) throws -> UInt64 {
    try src64(w, lane, ins, ins.s0) &+ UInt64(bitPattern: Int64(ins.offset))
  }

  func readMem(_ addr: UInt64, _ n: Int) throws -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(n)
    for i in 0..<n {
      guard let b = mem.byte(addr &+ UInt64(i)) else { throw Fault.unmapped(address: addr &+ UInt64(i)) }
      out.append(b)
    }
    return out
  }

  func writeMem(_ addr: UInt64, _ bytes: [UInt8]) throws {
    guard mem.isMapped(addr, size: bytes.count) else {
      var a = addr
      while mem.byte(a) != nil { a &+= 1 }
      throw Fault.unmapped(address: a)
    }
    for (i, b) in bytes.enumerated() { mem.writeLE(addr &+ UInt64(i), size: 1, value: UInt64(b)) }
  }

  /// Byte count of a memory width code, and the registers of its staging block.
  func widthBytes(_ code: UInt8) -> Int { [1, 2, 3, 4, 6, 8, 12, 16][Int(code & 7)] }
  func widthRegs(_ code: UInt8) -> Int { [1, 1, 1, 1, 2, 2, 3, 4][Int(code & 7)] }

  func isDiscarded(_ w: Warp, _ lane: Int) -> Bool { w.discarded & (1 << UInt16(lane)) != 0 }

  /// Holds `values` for registers `first...` of `lane` until `slot` is waited on.
  func issueResult(_ w: Warp, _ lane: Int, first: Int, _ values: [UInt32], slot: Int) throws {
    for (i, v) in values.enumerated() {
      let r = first + i
      guard r < 64 else { throw Fault.invalid("staging block runs past r63") }
      if w.pending.contains(where: { $0.lane == lane && $0.reg == r }) {
        throw Fault.writeBeforeWait(register: r, slot: Int(w.pendReg[r]))
      }
      w.pending.append(Pending(slot: slot, lane: lane, reg: r, value: v))
      w.pendReg[r] = Int8(slot)
    }
    w.busy[slot] = 1
  }

  func stagingBlock(_ w: Warp, _ lane: Int, first: Int, count: Int) throws -> [UInt32] {
    guard count <= 1 || first % 2 == 0 else { throw Fault.invalid("staging block of \(count) starts at odd r\(first)") }
    return try (0..<count).map { i in
      guard first + i < 64 else { throw Fault.invalid("staging block runs past r63") }
      try checkRead(w, lane, first + i)
      return w.reg(lane, first + i)
    }
  }

  // MARK: LOAD and STORE (12a §12a.3, §12a.4)

  func load(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let addr = try address(w, lane, ins)
    let n = widthBytes(ins.memWidth)
    let bytes = try readMem(addr, n)
    var raw: UInt64 = 0
    for (i, b) in bytes.prefix(8).enumerated() { raw |= UInt64(b) << UInt64(8 * i) }
    let first = Int(ins.dst)
    let old = w.reg(lane, first)
    var out: [UInt32]
    func ext(_ bits: Int) -> UInt64 {
      ins.zeroExtend ? raw & laneMask(bits) : UInt64(bitPattern: signExtend(raw, bits: bits))
    }
    switch ins.memWidth {
    case 0, 1:
      let bits = ins.memWidth == 0 ? 8 : 16
      let l = Int(ins.lane)
      if ins.memWidth == 0 && l < 4 {
        let sh = UInt32(8 * l)
        out = [(old & ~(0xFF << sh)) | UInt32(raw & 0xFF) << sh]
      } else if ins.memWidth == 1 && l < 2 {
        let sh = UInt32(16 * l)
        out = [(old & ~(0xFFFF << sh)) | UInt32(raw & 0xFFFF) << sh]
      } else {
        let kind = ins.memWidth == 0 ? l : l + 4  // normalise to the 3-bit family: 4 h0, 5 h1, 6 w0, 7 d0
        switch kind {
        case 4, 5:
          let sh = UInt32(16 * (kind - 4))
          out = [(old & ~(0xFFFF << sh)) | UInt32(truncatingIfNeeded: ext(bits) & 0xFFFF) << sh]
        case 6: out = [UInt32(truncatingIfNeeded: ext(bits))]
        case 7: out = [UInt32(truncatingIfNeeded: ext(bits)), UInt32(truncatingIfNeeded: ext(bits) >> 32)]
        default: throw Fault.invalid("load lane \(ins.lane) for width \(ins.memWidth)")
        }
      }
    case 3:
      if ins.lane & 1 == 1 {
        out = [UInt32(truncatingIfNeeded: ext(32)), UInt32(truncatingIfNeeded: ext(32) >> 32)]
      } else {
        out = [UInt32(truncatingIfNeeded: raw)]
      }
    default:
      out = []
      for r in 0..<widthRegs(ins.memWidth) {
        var v: UInt32 = 0
        for b in 0..<4 where 4 * r + b < n { v |= UInt32(bytes[4 * r + b]) << UInt32(8 * b) }
        out.append(v)
      }
    }
    guard first % 2 == 0 || out.count == 1 else { throw Fault.invalid("staging block of \(out.count) starts at odd r\(first)") }
    try issueResult(w, lane, first: first, out, slot: Int(ins.slot))
  }

  func store(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let addr = try address(w, lane, ins)
    let block = try stagingBlock(w, lane, first: Int(ins.dst), count: widthRegs(ins.memWidth))
    w.busy[Int(ins.slot)] = 1
    if isDiscarded(w, lane) && ins.access != 3 { return }
    var bytes: [UInt8] = []
    switch ins.memWidth {
    case 0: bytes = [UInt8(truncatingIfNeeded: block[0] >> UInt32(8 * (ins.lane & 3)))]
    case 1:
      let h = UInt16(truncatingIfNeeded: block[0] >> UInt32(16 * (ins.lane & 1)))
      bytes = [UInt8(h & 0xFF), UInt8(h >> 8)]
    default:
      for v in block { for b in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(8 * b))) } }
      bytes = Array(bytes.prefix(widthBytes(ins.memWidth)))
    }
    try writeMem(addr, bytes)
  }

  // MARK: Atomics (12a §12a.8)

  func atomic(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let wide = ins.memWidth == 5
    guard wide || ins.memWidth == 3 else { throw Fault.invalid("atomic width \(ins.memWidth)") }
    let size = wide ? 8 : 4
    guard ins.offset >= 0 && ins.offset < 256 && Int(ins.offset) % size == 0 else {
      throw Fault.invalid("atomic offset \(ins.offset) is not a multiple of \(size) in 0..255")
    }
    let addr = try address(w, lane, ins)
    guard addr % UInt64(size) == 0 else { throw Fault.misaligned(address: addr) }
    let slot = Int(ins.slot)
    let returns = ins.op == .atom1Return || ins.op == .atomReturn || ins.op == .acmpxchg
    let retFirst = ins.op == .atom1Return ? Int(ins.dst) : Int(ins.writeReg)
    let retCount = wide ? 2 : 1
    if isDiscarded(w, lane) {
      w.busy[slot] = 1
      if returns { try issueResult(w, lane, first: retFirst, [UInt32](repeating: 0, count: retCount), slot: slot) }
      return
    }
    guard let oldRaw = mem.readLE(addr, size: size) else { throw Fault.unmapped(address: addr) }
    let mask = laneMask(size * 8)
    var new = oldRaw
    switch ins.op {
    case .atom1, .atom1Return:
      switch ins.atomOp {
      case 0: new = (oldRaw &+ 1) & mask
      case 1: new = (oldRaw &- 1) & mask
      case 2: new = max(oldRaw, 1)
      case 3: new = signedMax(oldRaw, 1, bits: size * 8)
      case 4: new = oldRaw | 1
      default: throw Fault.invalid("implicit-operand atomic \(ins.atomOp)")
      }
    case .acmpxchg:
      let regs = wide ? 4 : 2
      let block = try stagingBlock(w, lane, first: Int(ins.dst), count: regs)
      let per = wide ? 2 : 1
      func val(_ i: Int) -> UInt64 { wide ? UInt64(block[2 * i]) | UInt64(block[2 * i + 1]) << 32 : UInt64(block[i]) }
      _ = per
      if oldRaw == val(1) { new = val(0) }
    default:
      let isAdd32 = wide && (ins.atomOp == 0 || ins.atomOp == 1)
      let block = try stagingBlock(w, lane, first: Int(ins.dst), count: isAdd32 ? 1 : (wide ? 2 : 1))
      var d = wide && !isAdd32 ? UInt64(block[0]) | UInt64(block[1]) << 32 : UInt64(block[0])
      switch ins.atomOp {
      case 0: new = oldRaw &+ d
      case 1:
        d = UInt64(bitPattern: Int64(Int32(bitPattern: block[0])))
        new = oldRaw &+ d
      case 2: new = oldRaw &+ d
      case 8: new = signedMin(oldRaw, d, bits: size * 8)
      case 9: new = signedMax(oldRaw, d, bits: size * 8)
      case 10: new = min(oldRaw, d)
      case 11: new = max(oldRaw, d)
      case 12: new = oldRaw & d
      case 13: new = oldRaw | d
      case 14: new = oldRaw ^ d
      case 15:
        guard ins.op == .atomReturn else { throw Fault.invalid("axchg has no no-result form") }
        new = d
      default: throw Fault.invalid("atomic operation \(ins.atomOp)")
      }
      if ins.atomOp == 0 && !wide || ins.atomOp == 1 && !wide { throw Fault.invalid("aaddu/aadds are 64-bit only") }
    }
    mem.writeLE(addr, size: size, value: new & mask)
    w.busy[slot] = 1
    if returns {
      let old = wide ? [UInt32(truncatingIfNeeded: oldRaw), UInt32(truncatingIfNeeded: oldRaw >> 32)] : [UInt32(oldRaw)]
      try issueResult(w, lane, first: retFirst, old, slot: slot)
    }
  }

  func signedMin(_ a: UInt64, _ b: UInt64, bits: Int) -> UInt64 {
    signExtend(a, bits: bits) <= signExtend(b, bits: bits) ? a : b
  }

  func signedMax(_ a: UInt64, _ b: UInt64, bits: Int) -> UInt64 {
    signExtend(a, bits: bits) >= signExtend(b, bits: bits) ? a : b
  }

  // MARK: TEX_FETCH (12b), over a test model

  /// The handle `H` is one value for the warp (12b.2.1: word 0 the sampler's, word 1 the texture's): the lanes that run
  /// the instruction must agree on the texture. The coordinates are the first two words of the staging read block, the
  /// result the channels of `imm` (the write mask) in order.
  func texFetch(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    guard let fetch = cfg.textureFetch else { throw Fault.invalid("TEX_FETCH: the run has no texture model") }
    var texture: UInt32?
    for lane in w.lanes(ctx.mask) {
      let t = UInt32(truncatingIfNeeded: try src64(w, lane, ins, ins.s0) >> 32)
      if let seen = texture, seen != t {
        throw Fault.invalid("a texture handle that differs between the lanes of a warp (12b.2.1): \(seen) and \(t)")
      }
      texture = t
    }
    guard let handle = texture else { return }
    for lane in w.lanes(ctx.mask) {
      let at = try stagingBlock(w, lane, first: Int(ins.dst), count: 2)
      let texel = fetch(handle, at[0], at[1])
      var out: [UInt32] = []
      for c in 0..<4 where ins.imm & (1 << UInt32(c)) != 0 { out.append(c < texel.count ? texel[c] : 0) }
      try issueResult(w, lane, first: Int(ins.writeReg), out, slot: Int(ins.slot))
    }
  }

  // MARK: Subgroup (13 §13.9)

  static let inactiveResults: [UInt32] = [
    0, 0xFFFF_FFFF, 1, 0x0001_0001, 0x8000_0000, 0x7FFF_FFFF, 0x8000_8000, 0x7FFF_7FFF, 0x8080_8080, 0x7F7F_7F7F,
    0x3F80_0000, 0x3C00_3C00, 0xFF80_0000, 0x7F80_0000, 0xFC00_FC00, 0x7C00_7C00,
  ]

  func crossLane(_ w: Warp, _ ctx: Ctx, _ ins: Instr) throws {
    let size = 2 << Int(ins.subgroup & 3)
    var data = [UInt32](repeating: 0, count: 16)
    for lane in w.lanes(ctx.mask) { data[lane] = try src32(w, lane, ins, ins.s0) }
    if ins.op == .clper {
      for lane in w.lanes(ctx.mask) {
        let sel = try src32(w, lane, ins, ins.s1)
        guard (4...7).contains(ins.widen1) else { throw Fault.invalid("CLPER lane field \(ins.widen1)") }
        let k = Int((sel >> UInt32(8 * (ins.widen1 - 4))) & 0xFF) % size
        let n = lane % size
        let target: Int
        switch ins.laneOp {
        case 0: target = k
        case 1: target = (n ^ k) % size
        default: throw Fault.invalid("CLPER lane operation \(ins.laneOp) is not modelled")
        }
        let src = lane - n + target
        let v = ctx.mask & (1 << UInt16(src)) != 0 ? data[src] : Executor.inactiveResults[Int(ins.inactive & 15)]
        try writeDst(w, lane, ins, v)
      }
    } else {
      for lane in w.lanes(ctx.mask) {
        let base = lane - lane % size
        var m: UInt32 = 0
        for i in 0..<size where ctx.mask & (1 << UInt16(base + i)) != 0 && data[base + i] != 0 { m |= 1 << UInt32(i) }
        try writeDst(w, lane, ins, m)
      }
    }
  }
}
