// SPDX-License-Identifier: BSD-3-Clause

// One warp and the machinery every instruction shares: sources, the
// destination, the dependency-slot model, the active set.
//
// The model (valhall 10 §10.1, 13 §13.1):
//   - 16 lanes, 64 32-bit registers each. An instruction runs for the lanes
//     of its context's mask; a context is a set of lanes at one pc.
//   - A conditional branch some lanes take splits a context in two. Paths
//     run one at a time, the lowest pc first; the hardware's order is
//     unspecified (13 §13.5.1) and a shader must not depend on it.
//   - `reconverge` (13 §13.5.2) is on the last instruction of a block that
//     has a join block as a successor. After it, the lanes of that
//     instruction wait at their next pc, and lanes arriving there from the
//     other paths join them; when every path is waiting, the lowest pc
//     resumes. Without the flag, paths run on separately: each lane still
//     computes the right values, but an instruction that looks across lanes
//     sees fewer of them.
//   - Messages (memory) are asynchronous (10 §10.9.1): the result is held
//     back, and written when a flow wait names the message's slot; a wait takes effect after its
//     carrier (the board: docs/gpu/valhall-board-findings.md), so the carrier's own reads still fault. Reading
//     or overwriting a register with a result in flight is a `Fault`.

struct Pending {
  var slot: Int
  var lane: Int
  var reg: Int
  var value: UInt32
}

struct Ctx {
  var pc: Int
  var mask: UInt16
  var parked = false
}

enum StepResult {
  case ran, barrier, finished
}

final class Warp {
  let index: Int
  var regs = [UInt32](repeating: 0, count: 16 * 64)
  var dead = [Bool](repeating: false, count: 16 * 64)
  var pendReg = [Int8](repeating: -1, count: 64)
  var pending: [Pending] = []
  var busy = [Int](repeating: 0, count: 8)
  var ctxs: [Ctx]
  var discarded: UInt16 = 0
  var steps = 0
  var atBarrier = false
  /// Per-instruction scratch: registers read with a last-use mark, registers written.
  var lastUse: [Int] = []
  var wrote: [Int] = []

  init(index: Int, mask: UInt16) {
    self.index = index
    ctxs = mask == 0 ? [] : [Ctx(pc: 0, mask: mask)]
  }

  var finished: Bool { ctxs.isEmpty }

  func reg(_ lane: Int, _ r: Int) -> UInt32 { regs[lane * 64 + r] }

  /// Host-side access, for tests that look inside a warp.
  func lanes(_ mask: UInt16) -> [Int] { (0..<16).filter { mask & (1 << UInt16($0)) != 0 } }
}

extension Executor {
  // MARK: Sources (10 §10.5)

  func page(_ ins: Instr) -> Int { Int(ins.fauPage) }

  func userWord(_ ins: Instr, byte: UInt8, extra: Int = 0) throws -> UInt32 {
    let slot = page(ins) * 32 + Int((byte >> 1) & 31)
    let word = slot * 2 + Int(byte & 1) + extra
    guard word < cfg.fau.count else { throw Fault.fauOutOfRange(slot: slot) }
    return cfg.fau[word]
  }

  /// The 64-bit value of a special entry for `lane` of `w`.
  func specialValue(_ w: Warp, _ lane: Int, _ ins: Instr, entry: Int) throws -> UInt64 {
    switch (page(ins), entry) {
    case (0, 2): return UInt64(w.index)
    case (0, 5): return 0
    case (0, 6): return cfg.samplePositionTable
    case (0, 8...15): return 0
    case (1, 1):
      let inv = UInt64(workgroupLinear) * UInt64(cfg.workgroupSize.count) + UInt64(w.index * 16 + lane)
      return cfg.tlsBase &+ inv &* UInt64(cfg.threadLocalBytes)
    case (1, 3): return cfg.sharedBase &+ UInt64(workgroupLinear) &* UInt64(cfg.sharedBytes)
    case (1, 7): return cfg.resourceTable
    case (3, 1): return UInt64(lane)
    case (3, 3): return 0
    case (3, 4): return UInt64(cfg.shaderOutput)
    case (3, 15): return cfg.codeBase &+ UInt64(currentPc + 1) &* 8
    case let (p, e): throw Fault.reservedSpecial(page: p, entry: e)
    }
  }

  /// A 32-bit source. Register reads are checked against messages in flight and last-use marks.
  func src32(_ w: Warp, _ lane: Int, _ ins: Instr, _ byte: UInt8) throws -> UInt32 {
    switch byte >> 5 {
    case 0b000, 0b001, 0b010, 0b011:
      let r = Int(byte & 63)
      try checkRead(w, lane, r)
      if byte & 0x40 != 0 { w.lastUse.append(r) }
      return w.reg(lane, r)
    case 0b100, 0b101:
      return try userWord(ins, byte: byte)
    case 0b110:
      return smallConstants[Int(byte & 31)]
    default:
      let v = try specialValue(w, lane, ins, entry: Int((byte >> 1) & 15))
      return byte & 1 == 0 ? UInt32(truncatingIfNeeded: v) : UInt32(truncatingIfNeeded: v >> 32)
    }
  }

  /// A 64-bit source: an even register pair, a whole FAU slot, a special entry, or a small constant
  /// (zero-extended) (10 §10.5.4).
  func src64(_ w: Warp, _ lane: Int, _ ins: Instr, _ byte: UInt8) throws -> UInt64 {
    switch byte >> 5 {
    case 0b000, 0b001, 0b010, 0b011:
      let r = Int(byte & 63)
      guard r % 2 == 0 else { throw Fault.invalid("64-bit source names the odd register r\(r)") }
      try checkRead(w, lane, r)
      try checkRead(w, lane, r + 1)
      if byte & 0x40 != 0 { w.lastUse.append(r); w.lastUse.append(r + 1) }
      return UInt64(w.reg(lane, r)) | UInt64(w.reg(lane, r + 1)) << 32
    case 0b100, 0b101:
      guard byte & 1 == 0 else { throw Fault.invalid("64-bit FAU source with bit 0 set") }
      return UInt64(try userWord(ins, byte: byte)) | UInt64(try userWord(ins, byte: byte, extra: 1)) << 32
    case 0b110:
      return UInt64(smallConstants[Int(byte & 31)])
    default:
      guard byte & 1 == 0 else { throw Fault.invalid("64-bit special source with bit 0 set") }
      return try specialValue(w, lane, ins, entry: Int((byte >> 1) & 15))
    }
  }

  func checkRead(_ w: Warp, _ lane: Int, _ r: Int) throws {
    if w.pendReg[r] >= 0 { throw Fault.readBeforeWait(register: r, slot: Int(w.pendReg[r])) }
    if cfg.strictLastUse && w.dead[lane * 64 + r] { throw Fault.readAfterLastUse(register: r) }
  }

  // MARK: Destinations (10 §10.6.1)

  func putReg(_ w: Warp, _ lane: Int, _ r: Int, _ v: UInt32) throws {
    if w.pendReg[r] >= 0 { throw Fault.writeBeforeWait(register: r, slot: Int(w.pendReg[r])) }
    w.regs[lane * 64 + r] = v
    w.dead[lane * 64 + r] = false
    w.wrote.append(r)
  }

  /// Writes a 32-bit result under the destination width: `h0` the low half of `v` into the low half of
  /// the register, `h1` the high half into the high half, the other half unchanged (11b §11b.1.4).
  func writeDst(_ w: Warp, _ lane: Int, _ ins: Instr, _ v: UInt32) throws {
    let r = Int(ins.dst)
    let old = w.reg(lane, r)
    switch ins.dstWidth {
    case 1: try putReg(w, lane, r, (old & 0xFFFF_0000) | (v & 0xFFFF))
    case 2: try putReg(w, lane, r, (old & 0xFFFF) | (v & 0xFFFF_0000))
    default: try putReg(w, lane, r, v)
    }
  }

  /// A 16-bit result: `h0` or `h1` write that half only; `none` and `h01` write it to both halves
  /// (the "replicate" and "narrow" forms of 10 §10.6.1, whose `h01` the spec leaves open).
  func writeHalf(_ w: Warp, _ lane: Int, _ ins: Instr, _ h: UInt16) throws {
    let r = Int(ins.dst)
    let old = w.reg(lane, r)
    switch ins.dstWidth {
    case 1: try putReg(w, lane, r, (old & 0xFFFF_0000) | UInt32(h))
    case 2: try putReg(w, lane, r, (old & 0xFFFF) | UInt32(h) << 16)
    default: try putReg(w, lane, r, UInt32(h) | UInt32(h) << 16)
    }
  }

  func writeDst64(_ w: Warp, _ lane: Int, _ ins: Instr, _ v: UInt64) throws {
    let r = Int(ins.dst)
    guard r % 2 == 0 else { throw Fault.invalid("64-bit destination r\(r) is odd") }
    try putReg(w, lane, r, UInt32(truncatingIfNeeded: v))
    try putReg(w, lane, r + 1, UInt32(truncatingIfNeeded: v >> 32))
  }

  // MARK: Dependency slots (10 §10.9)

  /// Completes the messages of the slots in `slots`: their results reach the registers.
  func completeSlots(_ w: Warp, _ slots: UInt8) {
    guard slots != 0 else { return }
    var rest: [Pending] = []
    for p in w.pending {
      if slots & (1 << UInt8(p.slot)) != 0 {
        w.regs[p.lane * 64 + p.reg] = p.value
        w.dead[p.lane * 64 + p.reg] = false
      } else {
        rest.append(p)
      }
    }
    w.pending = rest
    for r in 0..<64 where w.pendReg[r] >= 0 && slots & (1 << UInt8(w.pendReg[r])) != 0 { w.pendReg[r] = -1 }
    for s in 0..<8 where slots & (1 << UInt8(s)) != 0 { w.busy[s] = 0 }
  }
}
