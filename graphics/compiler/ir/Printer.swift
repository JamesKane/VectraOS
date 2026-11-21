// SPDX-License-Identifier: BSD-3-Clause

// The IR's stable text form, for tests and for reading a compiled shader.
// Values are numbered in layout order (parameters, then results block by
// block), so the text doesn't depend on what the passes left in the arenas.

func hex(_ v: UInt64) -> String {
  let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
  if v == 0 { return "0x0" }
  var x = v
  var s: [Character] = []
  while x != 0 {
    s.append(digits[Int(x & 15)])
    x >>= 4
  }
  return "0x" + String(s.reversed())
}

extension Function {
  /// The function in text form.
  public func text(module: IRModule? = nil) -> String {
    var number = [Int](repeating: -1, count: values.count)
    var next = 0
    for p in 0..<params.count {
      number[p] = next
      next += 1
    }
    for b in blocks {
      for id in b.insts where insts[id].result >= 0 {
        number[insts[id].result] = next
        next += 1
      }
    }
    func name(_ v: ValueID) -> String {
      switch values[v].kind {
      case .inst, .param: return "%\(number[v])"
      case .constant(let b):
        let t = values[v].type
        if t == .bool { return b == 0 ? "false" : "true" }
        if let s = t.scalarKind, s.isFloat { return "\(t.name) \(hex(b))" }
        return "\(t.name) \(signed(b, t.scalarKind?.bits ?? 32))"
      case .constVec(let es):
        var parts = ""
        for (k, e) in es.enumerated() { parts += (k > 0 ? ", " : "") + name(e) }
        return "<\(parts)>"
      case .undef: return "undef:\(values[v].type.name)"
      case .global(let g):
        if let m = module, g < m.globals.count { return "@\(m.globals[g].name)" }
        return "@g\(g)"
      case .resource(let s, let b): return "@res(\(s),\(b)):\(values[v].type.name)"
      case .pushConstants: return "@push"
      }
    }
    func signed(_ b: UInt64, _ w: Int) -> String {
      if w >= 64 { return "\(Int64(bitPattern: b))" }
      let v = Int64(bitPattern: b << UInt64(64 - w)) >> Int64(64 - w)
      return "\(v)"
    }
    func list(_ vs: [ValueID]) -> String {
      var s = ""
      for (k, v) in vs.enumerated() { s += (k > 0 ? ", " : "") + name(v) }
      return s
    }
    var out = "fn \(self.name)("
    for (k, t) in params.enumerated() { out += (k > 0 ? ", " : "") + "%\(k): \(t.name)" }
    out += ") -> \(returns.name) {\n"
    for (bi, b) in blocks.enumerated() {
      out += "bb\(bi):"
      switch b.kind {
      case .plain: break
      case .selection: out += "  ; selection merge=bb\(b.merge)"
      case .loop: out += "  ; loop merge=bb\(b.merge) continue=bb\(b.continueTarget)"
      }
      out += "\n"
      for id in b.insts {
        let i = insts[id]
        var line = "  "
        if i.result >= 0 { line += "%\(number[i.result]) = " }
        line += i.op.rawValue
        switch i.op {
        case .icmp: line += " \(ICmpPred.names[i.imm])"
        case .fcmp: line += " \(FCmpPred.names[i.imm])"
        case .atomic: line += " \(AtomicKind.names[i.imm])"
        default: break
        }
        switch i.op {
        case .phi:
          for (k, a) in i.args.enumerated() { line += (k > 0 ? "," : "") + " [\(name(a)), bb\(i.blocks[k])]" }
        case .br: line += " bb\(i.blocks[0])"
        case .condbr: line += " \(name(i.args[0])), bb\(i.blocks[0]), bb\(i.blocks[1])"
        case .switch_:
          line += " \(name(i.args[0])), default bb\(i.blocks[0])"
          for (k, c) in i.payload.enumerated() { line += ", \(Int64(bitPattern: c)): bb\(i.blocks[k + 1])" }
        case .builtin:
          line += " \(IRBuiltin.names[i.imm])"
          if i.imm2 >= 0 { line += ".\(["x", "y", "z", "w"][i.imm2])" }
        case .stageIn, .stageOut:
          line += " #\(i.imm)"
          if i.imm2 >= 0 { line += ".\(["x", "y", "z", "w"][i.imm2])" }
          if !i.args.isEmpty { line += " " + list(i.args) }
        case .call: line += " f\(i.imm)(\(list(i.args)))"
        default:
          if !i.args.isEmpty { line += " " + list(i.args) }
        }
        switch i.op {
        case .extract, .insert: line += " [\(i.imm)]"
        case .shuffle:
          line += " ["
          for (k, l) in i.payload.enumerated() { line += (k > 0 ? ", " : "") + "\(l)" }
          line += "]"
        case .load, .store: line += " align \(i.imm)" + (i.imm2 & 1 != 0 ? " volatile" : "")
        case .alloca: line += " size \(i.imm) align \(i.imm2)"
        case .atomic: line += " scope \(i.imm2 >> 32) sem \(i.imm2 & 0xffff_ffff)"
        case .barrier: line += " exec \(i.imm) mem \(i.imm2 >> 32) sem \(i.imm2 & 0xffff_ffff)"
        case .membar: line += " mem \(i.imm2 >> 32) sem \(i.imm2 & 0xffff_ffff)"
        case .arraylen: line += " offset \(i.imm) stride \(i.imm2)"
        default: break
        }
        if i.result >= 0 { line += " : \(i.type.name)" }
        out += line + "\n"
      }
    }
    out += "}\n"
    return out
  }
}

extension IRModule {
  /// The module in text form.
  public var text: String {
    var s = "module entry=\(entryName) local_size=\(localSize.x),\(localSize.y),\(localSize.z)\n"
    for sp in specializations { s += "spec \(sp.id) \(sp.type.name) \(hex(sp.bits))\n" }
    for g in globals { s += "global @\(g.name) \(g.space.name) size \(g.size) align \(g.align)\n" }
    for f in functions { s += f.text(module: self) }
    return s
  }
}
