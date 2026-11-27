// SPDX-License-Identifier: BSD-3-Clause

// From allocated machine code to the final instruction list: registers filled
// in, last uses marked (10.5.5), message slots and waits (10.9, 13.7, 15.4),
// `reconverge` and `end` (13.5.2, 13.6.6), and branch offsets (13.4.4).

#if canImport(ValhallISA)
  import ValhallISA
#endif

struct PInst {
  var inst: Instruction
  var kind: MKind
  var target = -1
  var memory = 0
  /// Registers read and written (bit sets over r0 to r63).
  var reads: UInt64 = 0
  var writes: UInt64 = 0
  var stageWrites: UInt64 = 0
  /// The block this instruction opened, for labels.
  var isNopCarrier = false
  /// Registers some message in flight at this instruction still reads as staging (after its own wait).
  var inflight: UInt64 = 0
  var hidden = false
  var hiddenRetrieve = false
  var fixedSlot = -1
}

func regMask(_ first: Int, _ count: Int) -> UInt64 {
  var m: UInt64 = 0
  var i = 0
  while i < count {
    if first + i < 64 { m |= 1 << UInt64(first + i) }
    i += 1
  }
  return m
}

extension MFunc {
  /// Fill the registers in and produce the physical instructions of every block.
  func physical(_ a: Allocation) -> [[PInst]] {
    var out: [[PInst]] = []
    for b in 0..<blocks.count {
      var list: [PInst] = []
      for m in blocks[b].insts {
        if m.inst.mnemonic.sym == "MOV", case .reg(let dv, let doff) = m.dst, case .reg(let sv, let soff) = m.src[0],
          a.phys[dv] + doff == a.phys[sv] + soff, m.src[1] == .none
        {
          continue
        }
        var inst = m.inst
        let d = inst.def
        var page = -1
        for n in 0..<4 {
          let fi = d.fieldIndex(role: .source(n))
          if fi < 0 { continue }
          var s: Source
          switch m.src[n] {
          case .none: continue
          case .reg(let v, let off):
            s = Source.register(a.phys[v] + off)
          case .user(let slot, let w):
            s = Source.user(slot: slot % 32, word: w)
            page = slot / 32
          case .special(let p, let e, let w):
            s = Source.special(entry: e, word: w)
            page = p
          case .const(let c): s = Source.constant(c)
          }
          inst.setSource(n, s)
        }
        if page >= 0 { inst.fauPage = page }
        if case .reg(let v, let off) = m.dst { inst.put("dst", a.phys[v] + off) }
        let sr = d.fieldIndex(role: .stagingRegister)
        let sw = d.fieldIndex(role: .stagingWriteRegister)
        func stage(_ o: Opd, _ idx: Int) {
          if case .reg(let v, let off) = o, idx >= 0 { inst.values[idx] = UInt64(a.phys[v] + off) }
        }
        switch d.staging {
        case .readWrite:
          stage(m.stageRead, sr)
          stage(m.stageWrite, sw)
        case .write: stage(m.stageWrite, sr)
        case .read: stage(m.stageRead, sr)
        case .none: break
        }
        ISATable.shared.normalize(&inst)
        var p = PInst(inst: inst, kind: m.kind)
        p.target = m.target
        p.memory = m.memory
        p.hidden = m.hidden
        p.hiddenRetrieve = m.hiddenRetrieve
        p.fixedSlot = m.fixedSlot
        let (r, w, sw2) = PInst.regUse(inst)
        p.reads = r
        p.writes = w
        p.stageWrites = sw2
        list.append(p)
      }
      out.append(list)
    }
    return out
  }
}

extension PInst {
  /// The registers an instruction reads, writes in full or in part, and the block it writes as a message.
  static func regUse(_ inst: Instruction) -> (UInt64, UInt64, UInt64) {
    var reads: UInt64 = 0
    var writes: UInt64 = 0
    var n = 0
    while n < 4 {
      if let op = inst.operand(n), op.source.kind == .register {
        reads |= regMask(op.source.register, op.is64Bit ? 2 : 1)
      }
      n += 1
    }
    if let r = inst.destination { writes |= regMask(r, inst.destinationIs64Bit ? 2 : 1) }
    if let b = inst.stagingRead { reads |= regMask(b.first, b.count) }
    var sw: UInt64 = 0
    if let b = inst.stagingWrite { sw = regMask(b.first, b.count) }
    return (reads, writes | sw, sw)
  }
}

struct SlotState {
  /// Registers a message in slot n still writes.
  var pending: [UInt64] = [0, 0, 0]
  var busy: [Bool] = [false, false, false]
  var loads: [Bool] = [false, false, false]
  var stores: [Bool] = [false, false, false]
  var next = 0

  mutating func wait(_ slots: UInt8) {
    for s in 0..<3 where slots & (1 << UInt8(s)) != 0 {
      pending[s] = 0
      busy[s] = false
      loads[s] = false
      stores[s] = false
    }
  }
  var busyMask: UInt8 {
    var m: UInt8 = 0
    for s in 0..<3 where busy[s] { m |= 1 << UInt8(s) }
    return m
  }
}

enum Schedule {
  /// Add slots and waits to one block's instructions.
  static func waits(_ list: [PInst]) -> [PInst] {
    var out: [PInst] = []
    var st = SlotState()
    func nop(waiting w: UInt8) -> PInst {
      var i = Instruction("NOP")!
      i.flow = Flow(rawValue: w)!
      return PInst(inst: i, kind: .alu)
    }
    var hiddenSlot = -1
    var idx = 0
    // The trailing group of branches (the block's exits) must not carry a wait: reconverge goes on them.
    var tailStart = list.count
    for (k, p) in list.enumerated() where p.kind == .branch {
      tailStart = k
      break
    }
    while idx < list.count {
      var p = list[idx]
      if idx == tailStart && st.busyMask != 0 {
        // Drain before the exits.
        let w = st.busyMask
        if out.count > 0, out[out.count - 1].inst.flow == .none, out[out.count - 1].kind == .alu {
          out[out.count - 1].inst.flow = Flow(rawValue: w)!
        } else {
          out.append(nop(waiting: w))
        }
        st.wait(w)
      }
      if p.kind == .waitFlow {
        // A wait the epilogue names: it goes on the instruction before when that one is free, else on a NOP.
        let w = p.inst.flow
        if out.count > 0, out[out.count - 1].inst.flow == .none, out[out.count - 1].kind == .alu {
          out[out.count - 1].inst.flow = w
        } else {
          out.append(nop(waiting: w.rawValue))
        }
        st.wait(w.generalSlots)
        idx += 1
        continue
      }
      var need: UInt8 = 0
      let touch = p.reads | p.writes
      for s in 0..<3 where st.pending[s] & touch != 0 { need |= 1 << UInt8(s) }
      if p.memory == 1 {
        for s in 0..<3 where st.stores[s] { need |= 1 << UInt8(s) }
      } else if p.memory == 2 {
        for s in 0..<3 where st.stores[s] || st.loads[s] { need |= 1 << UInt8(s) }
      }
      if p.kind == .barrier || p.kind == .fence { need |= st.busyMask }
      // A store into the hidden register that has been waited for is done: a later slot of the same number is another message.
      if hiddenSlot >= 0 && !st.busy[hiddenSlot] { hiddenSlot = -1 }
      // The hidden interpolation register: wait for the last load that used it before the next one does (12c.5.5).
      if p.hidden && hiddenSlot >= 0 && st.busy[hiddenSlot] { need |= 1 << UInt8(hiddenSlot) }
      if need != 0 {
        // A wait takes effect after the instruction that carries it (the board, docs/gpu/valhall-board-findings.md), so
        // it goes on the instruction before the consumer (nothing lies between), or on a NOP when that one can't carry it.
        if out.count > 0, out[out.count - 1].inst.flow == .none, out[out.count - 1].kind == .alu {
          out[out.count - 1].inst.flow = Flow(rawValue: need)!
        } else {
          out.append(nop(waiting: need))
        }
        st.wait(need)
      }
      if p.kind == .fence {
        idx += 1
        continue
      }
      if p.kind == .message {
        let s = p.fixedSlot >= 0 ? p.fixedSlot : st.next
        if p.fixedSlot < 0 { st.next = (st.next + 1) % 3 }
        if p.inst.def.fieldIndex(role: .slot) >= 0 { p.inst.put("slot", s) }
        if p.hidden && !p.hiddenRetrieve { hiddenSlot = s }
        st.busy[s] = true
        st.pending[s] |= p.stageWrites
        if p.memory == 1 { st.loads[s] = true }
        if p.memory == 2 { st.stores[s] = true }
      }
      if p.kind == .barrier { p.inst.flow = .wait }
      out.append(p)
      idx += 1
    }
    // Falling out of the block (no exits listed): drain too.
    // (A shader whose last instruction is the JUMP of a blend call has nothing after it: the jump leaves and the blend shader returns to 0.)
    if tailStart == list.count && st.busyMask != 0 && !(list.last?.kind == .end) && list.last?.inst.mnemonic.sym != "JUMP" {
      out.append(nop(waiting: st.busyMask))
    }
    // The staging blocks messages still read at each instruction (a register in one is not marked last use).
    var reads: [UInt64] = [0, 0, 0]
    for k in 0..<out.count {
      // the instruction sees every message in flight: its own wait takes effect after it
      out[k].inflight = reads[0] | reads[1] | reads[2]
      let w = out[k].inst.flow.generalSlots
      for s in 0..<3 where w & (1 << UInt8(s)) != 0 { reads[s] = 0 }
      if out[k].kind == .message, let slot = out[k].inst.slot, slot < 3, let b = out[k].inst.stagingRead {
        reads[slot] |= regMask(b.first, b.count)
      }
    }
    return out
  }
}
