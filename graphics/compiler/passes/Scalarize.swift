// SPDX-License-Identifier: BSD-3-Clause

// The scalarisation pass: after it no value is a vector. Valhall's ALU works
// on scalars (or two 16-bit lanes, which a backend forms from adjacent
// scalars), so every vector instruction becomes one scalar instruction a lane:
//   - elementwise operations, compares, selects, conversions and phis split;
//   - vecbuild, extract, insert and shuffle vanish into the lane tables;
//   - a vector load or store becomes scalar accesses at consecutive element
//     offsets (a backend may merge adjacent ones);
//   - a vector builtin or stage input becomes its component builtins, a vector stage output one store a component.
// Calls with vector parameters or results are refused: parameter lists would
// have to change across the module.

extension Function {
  /// Replace vectors with scalars. Throws for a vector parameter, return or
  /// bitcast between different lane counts.
  public mutating func scalarize() throws(CompileError) {
    var hasVector = false
    for v in values where v.type.isVector { hasVector = true }
    if !hasVector { return }
    for t in params where t.isVector { throw CompileError("scalarize \(name): a vector parameter is not supported yet") }
    if returns.isVector { throw CompileError("scalarize \(name): a vector return value is not supported yet") }

    var lanes = [[ValueID]](repeating: [], count: values.count)  // by old vector value
    var map = [ValueID](repeating: -1, count: values.count)  // old scalar value -> new
    var pendingPhis: [(old: Int, new: [Int])] = []

    func laneValues(_ f: inout Function, _ v: ValueID, _ lanes: [[ValueID]]) throws(CompileError) -> [ValueID] {
      guard v < lanes.count else {
        // A value created by this pass: already scalar.
        return [v]
      }
      if !lanes[v].isEmpty { return lanes[v] }
      switch f.values[v].kind {
      case .constVec(let es): return es
      case .undef:
        guard case .vector(let s, let n) = f.values[v].type else { return [v] }
        var r: [ValueID] = []
        for _ in 0..<n { r.append(f.undef(.scalar(s))) }
        return r
      default:
        throw CompileError("scalarize \(f.name): vector value %v\(v) used before its definition")
      }
    }

    func scalar(_ v: ValueID) -> ValueID { v < map.count && map[v] >= 0 ? map[v] : v }

    for bi in 0..<blocks.count {
      var newList: [Int] = []
      func add(_ f: inout Function, _ inst: Inst) -> ValueID {
        let id = f.makeInst(inst)
        newList.append(id)
        return f.insts[id].result
      }
      for id in blocks[bi].insts {
        var i = insts[id]
        let isVec = i.type.isVector || i.args.contains { values[$0].type.isVector }
        if !isVec {
          for k in 0..<i.args.count { i.args[k] = scalar(i.args[k]) }
          insts[id].args = i.args
          newList.append(id)
          continue
        }
        let n = i.type.isVector ? i.type.lanes : values[i.args.first(where: { values[$0].type.isVector })!].type.lanes
        let elem = i.type.element
        switch i.op {
        case .vecbuild:
          var l: [ValueID] = []
          for a in i.args { l.append(scalar(a)) }
          lanes[i.result] = l
        case .extract:
          let l = try laneValues(&self, i.args[0], lanes)
          map[i.result] = l[i.imm]
        case .insert:
          var l = try laneValues(&self, i.args[0], lanes)
          l[i.imm] = scalar(i.args[1])
          lanes[i.result] = l
        case .shuffle:
          let a = try laneValues(&self, i.args[0], lanes)
          let b = try laneValues(&self, i.args[1], lanes)
          var l: [ValueID] = []
          for m in i.payload { l.append(Int(m) < a.count ? a[Int(m)] : b[Int(m) - a.count]) }
          lanes[i.result] = l
        case .load:
          guard case .ptr = values[i.args[0]].type, case .vector(let s, _) = i.type else { fatalError("vector load") }
          let p = scalar(i.args[0])
          let space = values[p].type
          var l: [ValueID] = []
          let esz = max(1, s.bits / 8)
          for k in 0..<n {
            var ptr = p
            if k > 0 {
              guard case .ptr(let sp) = space else { fatalError() }
              ptr = add(&self, Inst(.ptradd, space, [p, constant(sp.offsetType, UInt64(k * esz))]))
            }
            l.append(add(&self, Inst(.load, .scalar(s), [ptr], imm: min(i.imm, esz), imm2: i.imm2)))
          }
          lanes[i.result] = l
        case .store:
          let p = scalar(i.args[0])
          let space = values[p].type
          let vl = try laneValues(&self, i.args[1], lanes)
          guard case .vector(let s, _) = values[i.args[1]].type else { fatalError("vector store") }
          let esz = max(1, s.bits / 8)
          for k in 0..<vl.count {
            var ptr = p
            if k > 0 {
              guard case .ptr(let sp) = space else { fatalError() }
              ptr = add(&self, Inst(.ptradd, space, [p, constant(sp.offsetType, UInt64(k * esz))]))
            }
            _ = add(&self, Inst(.store, .void, [ptr, scalar(vl[k])], imm: min(i.imm, esz), imm2: i.imm2))
          }
        case .builtin:
          var l: [ValueID] = []
          for k in 0..<n { l.append(add(&self, Inst(.builtin, elem, [], imm: i.imm, imm2: k))) }
          lanes[i.result] = l
        case .stageIn:
          var l: [ValueID] = []
          for k in 0..<n { l.append(add(&self, Inst(.stageIn, elem, [], imm: i.imm, imm2: k))) }
          lanes[i.result] = l
        case .stageOut:
          let vl = try laneValues(&self, i.args[0], lanes)
          for k in 0..<vl.count { _ = add(&self, Inst(.stageOut, .void, [scalar(vl[k])], imm: i.imm, imm2: k)) }
        case .phi:
          var ids: [Int] = []
          var l: [ValueID] = []
          for _ in 0..<n {
            let pid = makeInst(Inst(.phi, elem, []))
            newList.append(pid)
            ids.append(pid)
            l.append(insts[pid].result)
          }
          lanes[i.result] = l
          pendingPhis.append((id, ids))
        case .bitcast:
          guard values[i.args[0]].type.lanes == n else {
            throw CompileError("scalarize \(name): a bitcast between different lane counts")
          }
          let a = try laneValues(&self, i.args[0], lanes)
          var l: [ValueID] = []
          for k in 0..<n { l.append(add(&self, Inst(.bitcast, elem, [a[k]]))) }
          lanes[i.result] = l
        case .call, .ret, .atomic, .alloca, .arraylen, .ptradd:
          throw CompileError("scalarize \(name): a vector operand of \(i.op.rawValue) is not supported")
        default:
          // Elementwise.
          var al: [[ValueID]] = []
          for a in i.args {
            if values[a].type.isVector { al.append(try laneValues(&self, a, lanes)) } else { al.append([scalar(a)]) }
          }
          var l: [ValueID] = []
          for k in 0..<n {
            var args: [ValueID] = []
            for x in al { args.append(x.count == 1 ? x[0] : x[k]) }
            var s = i
            s.args = args
            s.type = elem
            s.result = -1
            l.append(add(&self, s))
          }
          lanes[i.result] = l
        }
      }
      blocks[bi].insts = newList
    }
    for p in pendingPhis {
      let old = insts[p.old]
      for (leaf, pid) in p.new.enumerated() {
        var args: [ValueID] = []
        for a in old.args {
          let l = try laneValues(&self, a, lanes)
          args.append(l[leaf])
        }
        insts[pid].args = args
        insts[pid].blocks = old.blocks
      }
    }
    // Scalar operands defined by now-removed extracts still point at them.
    var repl = [ValueID](repeating: -1, count: values.count)
    for (k, m) in map.enumerated() where m >= 0 { repl[k] = m }
    apply(repl)
  }
}

extension IRModule {
  /// Scalarize every function.
  public mutating func scalarize() throws(CompileError) {
    for k in 0..<functions.count { try functions[k].scalarize() }
  }
}
