// SPDX-License-Identifier: BSD-3-Clause

// Register allocation (valhall 15.2): liveness over the blocks, one interval
// for each virtual register, linear scan over the registers of class 32
// (r0 to r15 and r48 to r63) and then class 64, and spilling to the thread's
// stack (12a.1.7, 14.9) when even class 64 is not enough.

#if canImport(ValhallISA)
  import ValhallISA
#endif

struct Allocation {
  /// The first physical register of each virtual register, or -1 for one that is never named.
  var phys: [Int]
  var class32: Bool
  var highest: Int
}

struct Liveness {
  /// Live at the end of each block, as a bit set over the virtual registers.
  var liveOut: [[UInt64]]
  var liveIn: [[UInt64]]
}

extension MFunc {
  static func bit(_ s: [UInt64], _ i: Int) -> Bool { s[i >> 6] & (1 << UInt64(i & 63)) != 0 }

  func liveness() -> Liveness {
    let nv = vregs.count
    let words = (nv + 63) / 64
    let nb = blocks.count
    var use = [[UInt64]](repeating: [UInt64](repeating: 0, count: words), count: nb)
    var def = use
    for b in 0..<nb {
      for m in blocks[b].insts {
        var r: [Int] = []
        m.reads(&r)
        for v in r where def[b][v >> 6] & (1 << UInt64(v & 63)) == 0 { use[b][v >> 6] |= 1 << UInt64(v & 63) }
        var w: [Int] = []
        m.writes(&w)
        for v in w {
          def[b][v >> 6] |= 1 << UInt64(v & 63)
        }
      }
    }
    var liveIn = use
    var liveOut = [[UInt64]](repeating: [UInt64](repeating: 0, count: words), count: nb)
    var changed = true
    var rounds = 0
    while changed && rounds < 10_000 {
      changed = false
      rounds += 1
      var b = nb - 1
      while b >= 0 {
        var out = [UInt64](repeating: 0, count: words)
        for s in blocks[b].succs { for w in 0..<words { out[w] |= liveIn[s][w] } }
        for w in 0..<words {
          let inn = use[b][w] | (out[w] & ~def[b][w])
          if inn != liveIn[b][w] || out[w] != liveOut[b][w] {
            liveIn[b][w] = inn
            liveOut[b][w] = out[w]
            changed = true
          }
        }
        b -= 1
      }
    }
    return Liveness(liveOut: liveOut, liveIn: liveIn)
  }

  struct Interval {
    var start = Int.max
    var end = -1
    mutating func touch(_ p: Int) {
      if p < start { start = p }
      if p > end { end = p }
    }
  }

  /// Try to give every virtual register a place in `regs` (in preference order).
  func scan(regs: [Int], live: Liveness) -> (Allocation?, Int, [Interval]) {
    let nv = vregs.count
    var iv = [Interval](repeating: Interval(), count: nv)
    var pos = 0
    for b in 0..<blocks.count {
      let first = pos
      for m in blocks[b].insts {
        var r: [Int] = []
        m.reads(&r)
        for v in r { iv[v].touch(2 * pos) }
        var w: [Int] = []
        m.writes(&w)
        for v in w { iv[v].touch(m.kind == .message ? 2 * pos : 2 * pos + 1) }
        pos += 1
      }
      if pos > first {
        for v in 0..<nv {
          if MFunc.bit(live.liveIn[b], v) { iv[v].touch(2 * first) }
          if MFunc.bit(live.liveOut[b], v) { iv[v].touch(2 * pos - 1) }
        }
      }
    }
    for v in 0..<nv where vregs[v].fixed >= 0 && iv[v].end >= 0 { iv[v].start = 0 }
    var order: [Int] = []
    for v in 0..<nv where iv[v].end >= 0 { order.append(v) }
    // By start; a fixed register first among equals.
    order.sort { a, b in
      if iv[a].start != iv[b].start { return iv[a].start < iv[b].start }
      if (vregs[a].fixed >= 0) != (vregs[b].fixed >= 0) { return vregs[a].fixed >= 0 }
      return a < b
    }
    var allowed = [Bool](repeating: false, count: 64)
    for r in regs { allowed[r] = true }
    var busy = [Int](repeating: -1, count: 64)
    var phys = [Int](repeating: -1, count: nv)
    var highest = -1
    for v in order {
      let size = vregs[v].size
      let align = vregs[v].align
      if vregs[v].fixed >= 0 {
        let r = vregs[v].fixed
        if !allowed[r] { return (nil, v, iv) }
        phys[v] = r
        busy[r] = max(busy[r], iv[v].end)
        highest = max(highest, r)
        continue
      }
      var chosen = -1
      for r in regs where r % align == 0 && r + size <= 64 {
        var ok = true
        for k in 0..<size where !allowed[r + k] || busy[r + k] >= iv[v].start { ok = false }
        if ok {
          chosen = r
          break
        }
      }
      if chosen < 0 { return (nil, v, iv) }
      phys[v] = chosen
      for k in 0..<size { busy[chosen + k] = iv[v].end }
      highest = max(highest, chosen + size - 1)
    }
    return (Allocation(phys: phys, class32: false, highest: highest), -1, iv)
  }

  /// Allocate, spilling when the registers run out.
  mutating func allocate(_ opts: BackendOptions) throws(BackendError) -> Allocation {
    var rounds = 0
    while rounds < 512 {
      rounds += 1
      let live = liveness()
      var regs32: [Int] = []
      var regs64: [Int] = []
      for r in 0..<64 {
        regs64.append(r)
        if r < 16 || r >= 48 { regs32.append(r) }
      }
      if let lim = opts.registerLimit {
        // The limit is on the registers the allocator chooses; the preloaded ones stay.
        regs32 = regs32.filter { $0 < lim || ($0 >= 55 && $0 <= 62) }
        regs64 = regs64.filter { $0 < lim || ($0 >= 55 && $0 <= 62) }
      }
      if opts.preferClass32 {
        let (a, _, _) = scan(regs: regs32, live: live)
        if var a { a.class32 = true; return a }
      }
      let (a, failed, iv) = scan(regs: regs64, live: live)
      if var a {
        a.class32 = false
        return a
      }
      // Spill the interval that lives longest among those over the failing point.
      let at = iv[failed].start
      var victim = -1
      for v in 0..<vregs.count where iv[v].end >= 0 && !vregs[v].noSpill && vregs[v].fixed < 0 {
        if iv[v].start <= at && iv[v].end >= at || v == failed {
          if victim < 0 || iv[v].end > iv[victim].end { victim = v }
        }
      }
      if victim < 0 { throw BackendError.outOfRegisters }
      try spill(victim)
    }
    throw BackendError.outOfRegisters
  }

  /// Give `v` a stack slot: every write stores, every read fills (12a.1.7).
  mutating func spill(_ v: Int) throws(BackendError) {
    let size = vregs[v].size
    stackBytes = (stackBytes + 7) / 8 * 8
    let slot = stackBytes
    stackBytes += (size * 4 + 7) / 8 * 8
    spillSlots += 1
    if stackBytes > 32000 { throw BackendError.stackOverflow }
    let width = size == 1 ? "i32" : size == 2 ? "i64" : size == 3 ? "i96" : "i128"
    for b in 0..<blocks.count {
      var out: [MInst] = []
      for var m in blocks[b].insts {
        var reads: [Int] = []
        m.reads(&reads)
        var writes: [Int] = []
        m.writes(&writes)
        var partial = false
        if case .reg(let dv, let off) = m.dst, dv == v, off != 0 || size > 1 && !m.inst.destinationIs64Bit { partial = true }
        let r = reads.contains(v) || partial
        let w = writes.contains(v)
        if !r && !w {
          out.append(m)
          continue
        }
        let t = newTemp(size)
        vregs[t].align = vregs[v].align
        if r {
          var l = MInst(Instruction("LOAD", width)!, .message)
          l.src[0] = .special(1, 1, 0)
          l.stageWrite = .reg(t, 0)
          l.memory = 1
          l.inst.put("offset", slot)
          l.inst.put("access", "force")
          out.append(l)
        }
        replace(&m, v, with: t)
        out.append(m)
        if w {
          var s = MInst(Instruction("STORE", width)!, .message)
          s.src[0] = .special(1, 1, 0)
          s.stageRead = .reg(t, 0)
          s.memory = 2
          s.inst.put("offset", slot)
          s.inst.put("access", "force")
          out.append(s)
        }
      }
      blocks[b].insts = out
    }
  }

  mutating func newTemp(_ size: Int) -> Int {
    let t = newReg(size: size)
    vregs[t].noSpill = true
    return t
  }

  func replace(_ m: inout MInst, _ v: Int, with t: Int) {
    func fix(_ o: Opd) -> Opd {
      if case .reg(let r, let off) = o, r == v { return .reg(t, off) }
      return o
    }
    for n in 0..<4 { m.src[n] = fix(m.src[n]) }
    m.dst = fix(m.dst)
    m.stageRead = fix(m.stageRead)
    m.stageWrite = fix(m.stageWrite)
  }
}
