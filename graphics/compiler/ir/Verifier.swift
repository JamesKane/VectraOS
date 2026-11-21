// SPDX-License-Identifier: BSD-3-Clause

// The IR verifier: types, SSA dominance, phis, terminators and the structured
// control flow a backend relies on. Run after lowering and after every pass
// in tests; a failure names the function, block and instruction.

extension IRModule {
  /// Check the module. `scalar: true` also requires that no value is a
  /// vector (after the scalarisation pass).
  public func verify(scalar: Bool = false) throws(CompileError) {
    guard entry < functions.count else { throw CompileError("verify: no entry function") }
    for (n, f) in functions.enumerated() {
      try f.verify(module: self, index: n, scalar: scalar)
    }
  }
}

extension Function {
  func verify(module: IRModule, index: Int, scalar: Bool) throws(CompileError) {
    func bad(_ b: Int, _ id: Int, _ msg: String) -> CompileError {
      let op = id >= 0 ? " \(insts[id].op.rawValue)" : ""
      return CompileError("verify \(name) bb\(b)\(op): \(msg)")
    }
    guard !blocks.isEmpty else { throw CompileError("verify \(name): no blocks") }
    // Where each instruction is.
    var blockOfInst = [Int](repeating: -1, count: insts.count)
    var posOfInst = [Int](repeating: -1, count: insts.count)
    for (b, blk) in blocks.enumerated() {
      guard let last = blk.insts.last, insts[last].op.isTerminator else {
        throw bad(b, -1, "the block does not end in a terminator")
      }
      var seenNonPhi = false
      for (k, id) in blk.insts.enumerated() {
        guard id >= 0 && id < insts.count else { throw bad(b, -1, "instruction id \(id) is out of range") }
        guard blockOfInst[id] < 0 else { throw bad(b, id, "the instruction is placed twice") }
        blockOfInst[id] = b
        posOfInst[id] = k
        if insts[id].op.isTerminator && k != blk.insts.count - 1 { throw bad(b, id, "a terminator before the block's end") }
        if insts[id].op == .phi {
          if seenNonPhi { throw bad(b, id, "a phi after another instruction") }
        } else {
          seenNonPhi = true
        }
      }
    }
    for b in 0..<blocks.count {
      for s in successors(b) where s < 0 || s >= blocks.count { throw bad(b, -1, "a branch target is out of range") }
    }
    let cfg = CFG(self)
    guard cfg.preds[0].isEmpty else { throw bad(0, -1, "the entry block has predecessors") }

    func defBlock(_ v: ValueID) -> (block: Int, pos: Int)? {
      if case .inst(let id) = values[v].kind {
        return blockOfInst[id] >= 0 ? (blockOfInst[id], posOfInst[id]) : nil
      }
      return (0, -1)  // parameters, constants, globals: available everywhere
    }

    for (b, blk) in blocks.enumerated() {
      for (k, id) in blk.insts.enumerated() {
        let i = insts[id]
        for a in i.args where a < 0 || a >= values.count { throw bad(b, id, "operand \(a) is out of range") }
        if i.result >= 0 {
          guard values[i.result].kind == .inst(id), values[i.result].type == i.type else {
            throw bad(b, id, "the result value does not match the instruction")
          }
        }
        // Dominance.
        if cfg.reachable(b) {
          if i.op == .phi {
            guard i.args.count == i.blocks.count else { throw bad(b, id, "phi has \(i.args.count) values and \(i.blocks.count) blocks") }
            var seen: [Int] = []
            for p in i.blocks {
              guard p >= 0 && p < blocks.count, cfg.preds[b].contains(p) else {
                throw bad(b, id, "incoming block bb\(p) is not a predecessor")
              }
              seen.append(p)
            }
            for p in cfg.preds[b] where !seen.contains(p) {
              throw bad(b, id, "predecessor bb\(p) has no incoming value")
            }
            for (n, a) in i.args.enumerated() {
              guard let d = defBlock(a) else { throw bad(b, id, "operand is defined by a removed instruction") }
              let pb = i.blocks[n]
              if cfg.reachable(pb) && d.pos >= 0 && !cfg.dominates(d.block, pb) {
                throw bad(b, id, "incoming value does not dominate the end of bb\(pb)")
              }
            }
          } else {
            for a in i.args {
              guard let d = defBlock(a) else { throw bad(b, id, "operand is defined by a removed instruction") }
              if d.pos >= 0 {
                let ok = d.block == b ? d.pos < k : cfg.dominates(d.block, b)
                if !ok { throw bad(b, id, "operand %v\(a) does not dominate its use") }
              }
            }
          }
        }
        try check(i, b: b, id: id, module: module, bad: bad)
        if scalar {
          if i.type.isVector { throw bad(b, id, "a vector result after scalarisation") }
          for a in i.args where values[a].type.isVector { throw bad(b, id, "a vector operand after scalarisation") }
        }
      }
    }
    try structure(cfg, bad: bad)
  }

  private func structure(_ cfg: CFG, bad: (Int, Int, String) -> CompileError) throws(CompileError) {
    var mergeOf = [Int](repeating: -1, count: blocks.count)
    for (b, blk) in blocks.enumerated() where blk.kind != .plain {
      guard let t = blk.insts.last else { continue }
      let term = insts[t].op
      guard blk.merge >= 0 && blk.merge < blocks.count, blk.merge != b else { throw bad(b, -1, "the merge block is invalid") }
      if blk.kind == .selection {
        guard term == .condbr || term == .switch_ else {
          throw bad(b, t, "a selection header must end in a conditional branch or a switch")
        }
      } else {
        guard term == .br || term == .condbr else { throw bad(b, t, "a loop header must end in br or condbr") }
        guard blk.continueTarget >= 0 && blk.continueTarget < blocks.count else {
          throw bad(b, -1, "the loop's continue block is invalid")
        }
        guard blk.continueTarget != blk.merge else { throw bad(b, -1, "a loop's continue and merge blocks are the same") }
      }
      guard mergeOf[blk.merge] < 0 else { throw bad(b, -1, "bb\(blk.merge) is the merge block of two headers") }
      mergeOf[blk.merge] = b
      if cfg.reachable(b) {
        if cfg.reachable(blk.merge) && !cfg.dominates(b, blk.merge) {
          throw bad(b, -1, "the header does not dominate its merge block bb\(blk.merge)")
        }
        if blk.kind == .loop && cfg.reachable(blk.continueTarget) {
          guard cfg.dominates(b, blk.continueTarget) else {
            throw bad(b, -1, "the header does not dominate its continue block")
          }
          var back = false
          for p in cfg.preds[b] where cfg.reachable(p) && cfg.dominates(blk.continueTarget, p) { back = true }
          guard back else { throw bad(b, -1, "the loop has no back edge from its continue construct") }
        }
      }
    }
  }

  private func check(_ i: Inst, b: Int, id: Int, module: IRModule, bad: (Int, Int, String) -> CompileError)
    throws(CompileError)
  {
    func t(_ n: Int) -> IRType { values[i.args[n]].type }
    func need(_ n: Int) throws(CompileError) {
      guard i.args.count == n else { throw bad(b, id, "needs \(n) operands, has \(i.args.count)") }
    }
    func sameAll() throws(CompileError) {
      for n in 0..<i.args.count where t(n) != i.type { throw bad(b, id, "operand \(n) has type \(t(n).name), result \(i.type.name)") }
    }
    switch i.op {
    case .iadd, .isub, .imul, .udiv, .sdiv, .urem, .srem, .smin, .smax, .umin, .umax, .shl, .lshr, .ashr:
      try need(2); try sameAll()
      guard i.type.scalarKind?.isInt == true else { throw bad(b, id, "needs integer operands") }
    case .ineg:
      try need(1); try sameAll()
      guard i.type.scalarKind?.isInt == true else { throw bad(b, id, "needs an integer operand") }
    case .and, .or, .xor:
      try need(2); try sameAll()
      guard let k = i.type.scalarKind, k.isInt || k == .bool else { throw bad(b, id, "needs integer or bool operands") }
    case .not:
      try need(1); try sameAll()
      guard let k = i.type.scalarKind, k.isInt || k == .bool else { throw bad(b, id, "needs an integer or bool operand") }
    case .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax:
      try need(2); try sameAll()
      guard i.type.scalarKind?.isFloat == true else { throw bad(b, id, "needs float operands") }
    case .fma:
      try need(3); try sameAll()
      guard i.type.scalarKind?.isFloat == true else { throw bad(b, id, "needs float operands") }
    case .fneg, .fabs, .ffloor, .fceil, .ftrunc, .fround, .fsqrt, .frsq, .fexp2, .flog2, .fsin, .fcos:
      try need(1); try sameAll()
      guard i.type.scalarKind?.isFloat == true else { throw bad(b, id, "needs a float operand") }
    case .icmp, .fcmp:
      try need(2)
      guard t(0) == t(1) else { throw bad(b, id, "the operands have different types") }
      guard i.type == t(0).with(.bool) else { throw bad(b, id, "the result is not a bool of the operands' shape") }
      if i.op == .icmp {
        guard let k = t(0).scalarKind, k.isInt || k == .bool || t(0).isPointer else { throw bad(b, id, "icmp needs integers") }
        guard i.imm >= 0 && i.imm < ICmpPred.names.count else { throw bad(b, id, "bad predicate") }
      } else {
        guard t(0).scalarKind?.isFloat == true else { throw bad(b, id, "fcmp needs floats") }
        guard i.imm >= 0 && i.imm < FCmpPred.names.count else { throw bad(b, id, "bad predicate") }
      }
    case .select:
      try need(3)
      guard t(1) == i.type, t(2) == i.type else { throw bad(b, id, "the arms must have the result type") }
      guard t(0) == .bool || t(0) == i.type.with(.bool) else { throw bad(b, id, "the condition must be a bool of the result's shape") }
    case .zext, .sext, .trunc:
      try need(1)
      guard let from = t(0).scalarKind, let to = i.type.scalarKind, t(0).lanes == i.type.lanes else {
        throw bad(b, id, "the operand and result must have the same shape")
      }
      guard from.isInt || from == .bool, to.isInt else { throw bad(b, id, "needs integers") }
      if i.op == .trunc ? from.bits <= to.bits : from.bits >= to.bits { throw bad(b, id, "the width change goes the wrong way") }
    case .fpext, .fptrunc:
      try need(1)
      guard let from = t(0).scalarKind, let to = i.type.scalarKind, from.isFloat, to.isFloat, t(0).lanes == i.type.lanes
      else { throw bad(b, id, "needs floats of the same shape") }
      if i.op == .fptrunc ? from.bits <= to.bits : from.bits >= to.bits { throw bad(b, id, "the width change goes the wrong way") }
    case .fptosi, .fptoui:
      try need(1)
      guard t(0).scalarKind?.isFloat == true, i.type.scalarKind?.isInt == true, t(0).lanes == i.type.lanes else {
        throw bad(b, id, "needs a float operand and an integer result of the same shape")
      }
    case .sitofp, .uitofp:
      try need(1)
      guard t(0).scalarKind?.isInt == true, i.type.scalarKind?.isFloat == true, t(0).lanes == i.type.lanes else {
        throw bad(b, id, "needs an integer operand and a float result of the same shape")
      }
    case .bitcast:
      try need(1)
      guard t(0).totalBits == i.type.totalBits, !t(0).isPointer, !i.type.isPointer else {
        throw bad(b, id, "needs non-pointer types of the same size")
      }
    case .ptrtoint:
      try need(1)
      guard t(0) == .ptr(.global), i.type == .i64 else { throw bad(b, id, "needs a global pointer and an i64 result") }
    case .inttoptr:
      try need(1)
      guard t(0) == .i64, i.type == .ptr(.global) else { throw bad(b, id, "needs an i64 and a global pointer result") }
    case .vecbuild:
      guard case .vector(let s, let n) = i.type, i.args.count == n else { throw bad(b, id, "needs a vector result with one scalar a lane") }
      for k in 0..<n where t(k) != .scalar(s) { throw bad(b, id, "lane \(k) is not \(IRType.scalar(s).name)") }
    case .extract:
      try need(1)
      guard case .vector(let s, let n) = t(0), i.type == .scalar(s), i.imm >= 0, i.imm < n else {
        throw bad(b, id, "needs a vector operand, an in-range lane and its element type")
      }
    case .insert:
      try need(2)
      guard case .vector(let s, let n) = t(0), i.type == t(0), t(1) == .scalar(s), i.imm >= 0, i.imm < n else {
        throw bad(b, id, "needs a vector, an in-range lane and an element")
      }
    case .shuffle:
      try need(2)
      guard case .vector(let s, let n) = t(0), t(1) == t(0), case .vector(let rs, let rn) = i.type, rs == s,
        i.payload.count == rn
      else { throw bad(b, id, "needs two equal vectors and a result with one lane per mask entry") }
      for l in i.payload where l >= UInt64(2 * n) { throw bad(b, id, "a mask lane is out of range") }
    case .load:
      try need(1)
      guard case .ptr = t(0) else { throw bad(b, id, "the operand is not a pointer") }
      guard i.type != .void, i.imm > 0 else { throw bad(b, id, "needs a type and an alignment") }
    case .store:
      try need(2)
      guard case .ptr(let sp) = t(0) else { throw bad(b, id, "the first operand is not a pointer") }
      guard sp != .uniform && sp != .pushConstant else { throw bad(b, id, "a store to read-only memory") }
      guard t(1) != .void, i.imm > 0 else { throw bad(b, id, "needs a value and an alignment") }
    case .ptradd:
      try need(2)
      guard case .ptr(let sp) = t(0), i.type == t(0), t(1) == .scalar(sp.offsetType) else {
        throw bad(b, id, "needs a pointer and a byte offset of its space's offset type")
      }
    case .alloca:
      guard i.args.isEmpty, i.type == .ptr(.function), i.imm >= 0, i.imm2 > 0 else { throw bad(b, id, "bad alloca") }
    case .atomic:
      guard let p = i.args.first, case .ptr(let sp) = values[p].type, sp == .storage || sp == .workgroup || sp == .global else {
        throw bad(b, id, "the first operand is not a pointer to shared memory")
      }
      guard i.imm >= 0 && i.imm < AtomicKind.names.count else { throw bad(b, id, "bad atomic kind") }
      let n = i.imm == AtomicKind.load ? 1 : i.imm == AtomicKind.cmpxchg ? 3 : 2
      try need(n)
      if i.imm == AtomicKind.store {
        guard i.type == .void else { throw bad(b, id, "an atomic store has no result") }
      } else {
        guard i.type.scalarKind != nil, !i.type.isVector else { throw bad(b, id, "needs a scalar result") }
        for k in 1..<n where t(k) != i.type { throw bad(b, id, "operand \(k) has type \(t(k).name), result \(i.type.name)") }
      }
    case .barrier, .membar:
      try need(0)
    case .lane:
      guard i.imm == 0 || i.imm == 1 else { throw bad(b, id, "bad lane operation") }
      try need(i.imm == 0 ? 1 : 2)
      guard i.type == .scalar(.i32) else { throw bad(b, id, "a lane operation gives an i32") }
    case .builtin:
      try need(0)
      guard i.imm >= 0 && i.imm < IRBuiltin.names.count else { throw bad(b, id, "bad builtin") }
      let lanes = IRBuiltin.lanes(i.imm)
      let s = IRBuiltin.scalar(i.imm)
      if i.imm2 >= 0 {
        guard lanes > 1, i.imm2 < lanes, i.type == .scalar(s) else {
          throw bad(b, id, "a component needs a vector builtin and a scalar result of its type")
        }
      } else {
        guard i.type == (lanes > 1 ? .vector(s, lanes) : .scalar(s)) else { throw bad(b, id, "the result type is wrong for the builtin") }
      }
    case .stageIn:
      try need(0)
      guard i.imm >= 0 && i.imm < module.inputs.count else { throw bad(b, id, "the input variable is out of range") }
      let v = module.inputs[i.imm].type
      if i.imm2 >= 0 {
        guard i.imm2 < v.lanes, i.type == v.element else { throw bad(b, id, "the component's type is wrong") }
      } else {
        guard i.type == v else { throw bad(b, id, "the result type is not the input's") }
      }
    case .stageOut:
      try need(1)
      guard i.imm >= 0 && i.imm < module.outputs.count else { throw bad(b, id, "the output variable is out of range") }
      let v = module.outputs[i.imm].type
      if i.imm2 >= 0 {
        guard i.imm2 < v.lanes, t(0) == v.element else { throw bad(b, id, "the component's type is wrong") }
      } else {
        guard t(0) == v else { throw bad(b, id, "the value's type is not the output's") }
      }
    case .kill:
      try need(0)
      guard i.blocks.isEmpty else { throw bad(b, id, "kill has no successor") }
    case .demote:
      try need(0)
      guard i.blocks.isEmpty, module.executionModel == 4 else { throw bad(b, id, "demote is for fragment shaders") }
    case .tex:
      let n = TexFlags.argumentCount(i.imm)
      try need(n)
      guard i.payload.count == 2, i.imm2 >= 0, i.imm2 < 4, i.type.scalarKind != nil, !i.type.isVector else {
        throw bad(b, id, "needs a scalar texel component and the two bindings")
      }
      for k in 0..<n where t(k) != .i32 && !(k >= 2 && k < 2 + TexFlags.dims(i.imm) && TexFlags.kind(i.imm) != TexFlags.fetch && t(k) == .f32) {
        throw bad(b, id, "operand \(k) has type \(t(k).name)")
      }
    case .imgload, .imgstore, .imgaddr:
      let a = ImgFlags.addressCount(i.imm)
      let n = a + (i.op == .imgstore ? ImgFlags.channels(i.imm) : 0)
      try need(n)
      guard i.payload.count == 1 else { throw bad(b, id, "needs the image's binding") }
      for k in 0..<a where t(k) != .i32 { throw bad(b, id, "operand \(k) has type \(t(k).name)") }
      switch i.op {
      case .imgload:
        guard i.imm2 >= 0, i.imm2 < ImgFlags.channels(i.imm), i.type.scalarKind?.bits == 32, !i.type.isVector,
          i.type.scalarKind != .bool
        else { throw bad(b, id, "needs a 32-bit scalar texel channel the format has") }
      case .imgstore:
        guard i.type == .void else { throw bad(b, id, "a store has no result") }
        for k in a..<n where t(k).scalarKind?.bits != 32 || t(k).isVector || t(k) != t(a) {
          throw bad(b, id, "operand \(k) has type \(t(k).name)")
        }
      default:
        guard i.type == .ptr(.global) else { throw bad(b, id, "needs a ptr<global> result") }
      }
    case .arraylen:
      try need(1)
      guard case .ptr = t(0), i.type == .i32 else { throw bad(b, id, "needs a pointer and an i32 result") }
    case .call:
      guard i.imm >= 0 && i.imm < module.functions.count else { throw bad(b, id, "the callee is out of range") }
      let c = module.functions[i.imm]
      guard c.params.count == i.args.count, c.returns == i.type else { throw bad(b, id, "the call doesn't match the callee's signature") }
      for k in 0..<i.args.count where t(k) != c.params[k] { throw bad(b, id, "argument \(k) has the wrong type") }
    case .phi:
      guard i.type != .void, !i.args.isEmpty else { throw bad(b, id, "needs a type and incoming values") }
      for k in 0..<i.args.count where t(k) != i.type { throw bad(b, id, "incoming value \(k) has type \(t(k).name), the phi is \(i.type.name)") }
    case .br:
      guard i.blocks.count == 1, i.args.isEmpty else { throw bad(b, id, "needs one target") }
    case .condbr:
      guard i.blocks.count == 2, i.args.count == 1, t(0) == .bool else { throw bad(b, id, "needs a bool and two targets") }
    case .switch_:
      guard i.args.count == 1, t(0).scalarKind?.isInt == true, !t(0).isVector, i.blocks.count == i.payload.count + 1 else {
        throw bad(b, id, "needs an integer selector, a default and a target a case")
      }
    case .ret:
      if returns == .void {
        guard i.args.isEmpty else { throw bad(b, id, "a void function returns a value") }
      } else {
        guard i.args.count == 1, t(0) == returns else { throw bad(b, id, "the returned value has the wrong type") }
      }
    case .unreachable:
      try need(0)
    }
  }
}
