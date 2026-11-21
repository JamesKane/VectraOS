// SPDX-License-Identifier: BSD-3-Clause

// Constant folding and copy propagation. Folding evaluates an instruction
// whose operands are all constants (a lane at a time for vectors) in the
// target's own arithmetic: wrapping integers, IEEE f32 and f64. f16 values
// and operations whose result the IR leaves undefined (a division by zero,
// an oversized shift, an out-of-range float to integer conversion) are left
// for the backend. Copy propagation removes the instructions that only
// forward a value: a phi of one value, a select of two equal arms, an
// extract of a vector just built, an identity such as x + 0.

private func sx(_ v: UInt64, _ w: Int) -> Int64 {
  w >= 64 ? Int64(bitPattern: v) : Int64(bitPattern: v << UInt64(64 - w)) >> Int64(64 - w)
}

private func mk(_ v: UInt64, _ w: Int) -> UInt64 { w >= 64 ? v : v & ((1 << UInt64(w)) - 1) }

private func toDouble(_ k: Scalar, _ b: UInt64) -> Double? {
  switch k {
  case .f32: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: b)))
  case .f64: return Double(bitPattern: b)
  default: return nil
  }
}

private func fromDouble(_ k: Scalar, _ d: Double) -> UInt64 {
  k == .f32 ? UInt64(Float(d).bitPattern) : d.bitPattern
}

private func fmin_(_ a: Double, _ b: Double) -> Double { a.isNaN ? b : b.isNaN ? a : (b < a ? b : a) }
private func fmax_(_ a: Double, _ b: Double) -> Double { a.isNaN ? b : b.isNaN ? a : (b > a ? b : a) }

/// One lane of an operation on constants; nil when it isn't folded.
private func evalLane(_ op: IROp, imm: Int, result: Scalar, args k: [Scalar], _ v: [UInt64]) -> UInt64? {
  let w = k.isEmpty ? result.bits : k[0].bits
  switch op {
  case .iadd: return mk(v[0] &+ v[1], w)
  case .isub: return mk(v[0] &- v[1], w)
  case .imul: return mk(v[0] &* v[1], w)
  case .ineg: return mk(0 &- v[0], w)
  case .and: return v[0] & v[1]
  case .or: return v[0] | v[1]
  case .xor: return v[0] ^ v[1]
  case .not: return mk(~v[0], w)
  case .udiv: return v[1] == 0 ? nil : v[0] / v[1]
  case .urem: return v[1] == 0 ? nil : v[0] % v[1]
  case .sdiv:
    if v[1] == 0 || (sx(v[0], w) == Int64.min >> Int64(64 - w) && sx(v[1], w) == -1) { return nil }
    return mk(UInt64(bitPattern: sx(v[0], w) / sx(v[1], w)), w)
  case .srem:
    if v[1] == 0 || (sx(v[0], w) == Int64.min >> Int64(64 - w) && sx(v[1], w) == -1) { return nil }
    return mk(UInt64(bitPattern: sx(v[0], w) % sx(v[1], w)), w)
  case .shl: return v[1] >= UInt64(w) ? nil : mk(v[0] << v[1], w)
  case .lshr: return v[1] >= UInt64(w) ? nil : v[0] >> v[1]
  case .ashr: return v[1] >= UInt64(w) ? nil : mk(UInt64(bitPattern: sx(v[0], w) >> Int64(v[1])), w)
  case .smin: return sx(v[0], w) <= sx(v[1], w) ? v[0] : v[1]
  case .smax: return sx(v[0], w) >= sx(v[1], w) ? v[0] : v[1]
  case .umin: return v[0] <= v[1] ? v[0] : v[1]
  case .umax: return v[0] >= v[1] ? v[0] : v[1]
  case .icmp:
    let a = v[0]
    let b = v[1]
    let sa = sx(a, w)
    let sb = sx(b, w)
    switch imm {
    case ICmpPred.eq: return a == b ? 1 : 0
    case ICmpPred.ne: return a != b ? 1 : 0
    case ICmpPred.ult: return a < b ? 1 : 0
    case ICmpPred.ule: return a <= b ? 1 : 0
    case ICmpPred.ugt: return a > b ? 1 : 0
    case ICmpPred.uge: return a >= b ? 1 : 0
    case ICmpPred.slt: return sa < sb ? 1 : 0
    case ICmpPred.sle: return sa <= sb ? 1 : 0
    case ICmpPred.sgt: return sa > sb ? 1 : 0
    default: return sa >= sb ? 1 : 0
    }
  case .zext: return v[0]
  case .sext: return mk(UInt64(bitPattern: sx(v[0], w)), result.bits)
  case .trunc: return mk(v[0], result.bits)
  case .bitcast: return v[0]
  case .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax:
    guard let a = toDouble(k[0], v[0]), let b = toDouble(k[0], v[1]) else { return nil }
    switch op {
    case .fadd: return fromDouble(result, a + b)
    case .fsub: return fromDouble(result, a - b)
    case .fmul: return fromDouble(result, a * b)
    case .fdiv: return fromDouble(result, a / b)
    case .fmin: return fromDouble(result, fmin_(a, b))
    default: return fromDouble(result, fmax_(a, b))
    }
  case .fma:
    guard k[0] == .f32, let a = toDouble(k[0], v[0]), let b = toDouble(k[0], v[1]), let c = toDouble(k[0], v[2])
    else { return nil }
    return fromDouble(result, a * b + c)
  case .fneg:
    guard k[0] == .f32 || k[0] == .f64 else { return nil }
    return v[0] ^ (1 << UInt64(k[0].bits - 1))
  case .fabs:
    guard k[0] == .f32 || k[0] == .f64 else { return nil }
    return v[0] & ~(1 << UInt64(k[0].bits - 1))
  case .ffloor, .fceil, .ftrunc, .fround, .fsqrt:
    guard let a = toDouble(k[0], v[0]) else { return nil }
    switch op {
    case .ffloor: return fromDouble(result, a.rounded(.down))
    case .fceil: return fromDouble(result, a.rounded(.up))
    case .ftrunc: return fromDouble(result, a.rounded(.towardZero))
    case .fround: return fromDouble(result, a.rounded(.toNearestOrEven))
    default: return fromDouble(result, a.squareRoot())
    }
  case .fcmp:
    guard let a = toDouble(k[0], v[0]), let b = toDouble(k[0], v[1]) else { return nil }
    let un = a.isNaN || b.isNaN
    switch imm {
    case FCmpPred.oeq: return !un && a == b ? 1 : 0
    case FCmpPred.one: return !un && a != b ? 1 : 0
    case FCmpPred.olt: return !un && a < b ? 1 : 0
    case FCmpPred.ole: return !un && a <= b ? 1 : 0
    case FCmpPred.ogt: return !un && a > b ? 1 : 0
    case FCmpPred.oge: return !un && a >= b ? 1 : 0
    case FCmpPred.ueq: return un || a == b ? 1 : 0
    case FCmpPred.une: return un || a != b ? 1 : 0
    case FCmpPred.ult: return un || a < b ? 1 : 0
    case FCmpPred.ule: return un || a <= b ? 1 : 0
    case FCmpPred.ugt: return un || a > b ? 1 : 0
    case FCmpPred.uge: return un || a >= b ? 1 : 0
    case FCmpPred.ord: return un ? 0 : 1
    default: return un ? 1 : 0
    }
  case .sitofp, .uitofp:
    guard result == .f32 || result == .f64 else { return nil }
    if op == .sitofp {
      let s = sx(v[0], w)
      return result == .f32 ? UInt64(Float(s).bitPattern) : Double(s).bitPattern
    }
    return result == .f32 ? UInt64(Float(v[0]).bitPattern) : Double(v[0]).bitPattern
  case .fptosi, .fptoui:
    guard let a = toDouble(k[0], v[0]), a.isFinite else { return nil }
    let t = a.rounded(.towardZero)
    let rw = result.bits
    if op == .fptosi {
      let lo = -Double(sign: .plus, exponent: rw - 1, significand: 1)
      let hi = Double(sign: .plus, exponent: rw - 1, significand: 1)
      guard t >= lo && t < hi else { return nil }
      return mk(UInt64(bitPattern: Int64(t)), rw)
    }
    guard t >= 0 && t < Double(sign: .plus, exponent: rw, significand: 1) else { return nil }
    return UInt64(t)
  case .fpext, .fptrunc:
    guard let a = toDouble(k[0], v[0]), result == .f32 || result == .f64 else { return nil }
    return fromDouble(result, a)
  default: return nil
  }
}

extension Function {
  /// Evaluate instructions whose operands are constants, and a select with a
  /// constant condition. Returns whether anything changed.
  @discardableResult
  public mutating func foldConstants() -> Bool {
    var repl = [ValueID](repeating: -1, count: values.count)
    var changed = false
    for bi in 0..<blocks.count {
      for id in blocks[bi].insts {
        for k in 0..<insts[id].args.count { insts[id].args[k] = resolve(insts[id].args[k], repl) }
        let i = insts[id]
        guard i.result >= 0, let r = fold(i) else { continue }
        repl[i.result] = r
        changed = true
      }
    }
    if changed {
      apply(repl)
      eliminateDeadCode()
    }
    return changed
  }

  private mutating func fold(_ i: Inst) -> ValueID? {
    switch i.op {
    case .select:
      if let c = constantBits(i.args[0]) { return c != 0 ? i.args[1] : i.args[2] }
      if i.args[1] == i.args[2] { return i.args[1] }
      if i.type.isVector, i.type.lanes == values[i.args[0]].type.lanes, let cl = constantLanes(self, i.args[0]) {
        // A constant vector condition choosing among constant lanes.
        guard let a = constantLanes(self, i.args[1]), let b = constantLanes(self, i.args[2]) else { return nil }
        var out: [ValueID] = []
        let s = i.type.scalarKind!
        for k in 0..<cl.count { out.append(constant(s, cl[k] != 0 ? a[k] : b[k])) }
        return constVector(out)
      }
      return nil
    case .extract:
      if case .constVec(let es) = values[i.args[0]].kind { return es[i.imm] }
      if let d = def(i.args[0]) {
        if d.op == .vecbuild { return d.args[i.imm] }
        if d.op == .insert { return d.imm == i.imm ? d.args[1] : nil }
      }
      return nil
    case .vecbuild:
      var all = true
      for a in i.args where constantBits(a) == nil { all = false }
      return all ? constVector(i.args) : nil
    case .insert:
      guard case .constVec(let es) = values[i.args[0]].kind, constantBits(i.args[1]) != nil else { return nil }
      var n = es
      n[i.imm] = i.args[1]
      return constVector(n)
    case .shuffle:
      guard let a = constantLanes(self, i.args[0]), let b = constantLanes(self, i.args[1]) else { return nil }
      let s = i.type.scalarKind!
      var out: [ValueID] = []
      for l in i.payload { out.append(constant(s, Int(l) < a.count ? a[Int(l)] : b[Int(l) - a.count])) }
      return constVector(out)
    case .load, .store, .ptradd, .alloca, .atomic, .barrier, .membar, .builtin, .arraylen, .call, .phi, .ptrtoint,
      .inttoptr, .br, .condbr, .switch_, .ret, .unreachable, .stageIn, .stageOut, .kill, .demote, .tex, .imgload, .imgstore, .imgaddr, .descword:
      return nil
    default: break
    }
    // Lane-wise evaluation.
    guard let rk = i.type.scalarKind else { return nil }
    var cl: [[UInt64]] = []
    var kinds: [Scalar] = []
    for a in i.args {
      guard let l = constantLanes(self, a), let k = values[a].type.scalarKind else { return nil }
      cl.append(l)
      kinds.append(k)
    }
    if (rk == .f16) || kinds.contains(.f16) { return nil }
    let n = i.type.lanes
    var out: [UInt64] = []
    for lane in 0..<n {
      var v: [UInt64] = []
      for l in cl { v.append(l.count == 1 ? l[0] : l[lane]) }
      guard let r = evalLane(i.op, imm: i.imm, result: rk, args: kinds, v) else { return nil }
      out.append(r)
    }
    if n == 1 { return constant(rk, out[0]) }
    var es: [ValueID] = []
    for r in out { es.append(constant(rk, r)) }
    return constVector(es)
  }

  /// Forward values through instructions that only copy them.
  @discardableResult
  public mutating func propagateCopies() -> Bool {
    var repl = [ValueID](repeating: -1, count: values.count)
    var changed = false
    // Phis may feed each other: iterate until the table stops growing.
    var again = true
    while again {
      again = false
      for bi in 0..<blocks.count {
        for id in blocks[bi].insts {
          for k in 0..<insts[id].args.count { insts[id].args[k] = resolve(insts[id].args[k], repl) }
          let i = insts[id]
          guard i.result >= 0, repl[i.result] < 0, let r = forwarded(i) else { continue }
          if r == i.result { continue }
          repl[i.result] = r
          changed = true
          again = true
        }
      }
    }
    if changed {
      apply(repl)
      eliminateDeadCode()
    }
    return changed
  }

  private mutating func forwarded(_ i: Inst) -> ValueID? {
    func isInt(_ v: ValueID, _ n: UInt64) -> Bool {
      guard let b = constantBits(v) else { return false }
      return b == n
    }
    let width = i.type.scalarKind?.bits ?? 0
    let ones: UInt64 = width >= 64 ? UInt64.max : (1 << UInt64(width)) - 1
    switch i.op {
    case .phi:
      var same = -1
      for a in i.args where a != i.result {
        if same < 0 { same = a } else if same != a { return nil }
      }
      return same >= 0 ? same : nil
    case .select:
      return i.args[1] == i.args[2] ? i.args[1] : nil
    case .bitcast:
      return values[i.args[0]].type == i.type ? i.args[0] : nil
    case .ptradd:
      return isInt(i.args[1], 0) ? i.args[0] : nil
    case .zext, .sext, .trunc, .fpext, .fptrunc:
      return values[i.args[0]].type == i.type ? i.args[0] : nil
    case .extract:
      if let d = def(i.args[0]) {
        if d.op == .vecbuild { return d.args[i.imm] }
        if d.op == .insert && d.imm == i.imm { return d.args[1] }
      }
      return nil
    case .vecbuild:
      // Every lane an extract of the same vector, in order.
      guard let first = def(i.args[0]), first.op == .extract else { return nil }
      let src = first.args[0]
      for (k, a) in i.args.enumerated() {
        guard let d = def(a), d.op == .extract, d.args[0] == src, d.imm == k else { return nil }
      }
      return values[src].type == i.type ? src : nil
    case .iadd, .or, .xor:
      if isInt(i.args[1], 0) { return i.args[0] }
      if isInt(i.args[0], 0) { return i.args[1] }
      return nil
    case .isub, .shl, .lshr, .ashr:
      return isInt(i.args[1], 0) ? i.args[0] : nil
    case .imul:
      if isInt(i.args[1], 1) { return i.args[0] }
      if isInt(i.args[0], 1) { return i.args[1] }
      return nil
    case .udiv, .sdiv:
      return isInt(i.args[1], 1) ? i.args[0] : nil
    case .and:
      if i.type.scalarKind?.isInt == true || i.type.scalarKind == .bool {
        if isInt(i.args[1], ones) { return i.args[0] }
        if isInt(i.args[0], ones) { return i.args[1] }
      }
      return nil
    case .fmul:
      let one = i.type.scalarKind == .f32 ? UInt64(Float(1).bitPattern) : i.type.scalarKind == .f64 ? Double(1).bitPattern : 1
      if isInt(i.args[1], one) && i.type.scalarKind != .f16 { return i.args[0] }
      if isInt(i.args[0], one) && i.type.scalarKind != .f16 { return i.args[1] }
      return nil
    default: return nil
    }
  }
}
