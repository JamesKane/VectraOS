// SPDX-License-Identifier: BSD-3-Clause

// Statements into SPIR-V's structured control flow, user functions inlined, and the entry function: the stage's
// interface variables, the prologue (attributes, adjusted built-ins, global initializers), main, and the epilogue
// (the varyings published, GL's clip space turned into Vulkan's).

extension CodeGen {
  // MARK: statements

  mutating func statements(_ ss: [Stmt]) {
    for s in ss {
      if terminated { return }
      statement(s)
    }
  }

  mutating func statement(_ s: Stmt) {
    switch s {
    case .expr(let e):
      _ = value(e)
    case .declare(let v, let i):
      let x = prog.variables[v]
      if x.storage == .constant {
        if x.value == nil, let e = i { places[v] = .value(value(e)) }
        return
      }
      let ptr = local(x.type, name: x.name)
      places[v] = .memory(ptr, StorageClass.function, laid: false, prefix: [])
      if x.precision.relaxed { b.decorate(ptr, Decoration.relaxedPrecision) }
      if let e = i { emitVoid(SpvOp.store, [ptr, value(e)]) }
    case .block(let b):
      statements(b)
    case .ifElse(let c, let a, let e):
      if let cv = c.value {
        // A constant condition: only the branch taken.
        if cv[0].bool { statement(a) } else if let e = e { statement(e) }
        return
      }
      let cond = value(c)
      let thenL = b.id()
      let merge = b.id()
      let elseL = e != nil ? b.id() : merge
      emitVoid(SpvOp.selectionMerge, [merge, 0])
      emitVoid(SpvOp.branchConditional, [cond, thenL, elseL])
      label(thenL)
      statement(a)
      let thenEnded = terminated
      branch(merge)
      var elseEnded = false
      if let e = e {
        label(elseL)
        statement(e)
        elseEnded = terminated
        branch(merge)
      }
      label(merge)
      if thenEnded && elseEnded {
        // Neither branch reaches the merge.
        emitVoid(SpvOp.unreachable, [])
        terminated = true
      }
    case .loop(let initializer, let c, let step, let body):
      if let trips = unrollable(initializer, c, step, body) {
        // Appendix A's loop with a constant count, unrolled: the index a constant in each copy of the body, so what it
        // indexes is a constant too.
        let v = trips.variable
        for k in trips.values {
          places[v] = .value(constant(prog.variables[v].type, [k]))
          statement(body)
          if terminated { return }
        }
        return
      }
      statements(initializer)
      if terminated { return }
      if let cv = c?.value, !cv[0].bool { return }
      let header = b.id()
      let condL = b.id()
      let bodyL = b.id()
      let cont = b.id()
      let merge = b.id()
      let returns = containsReturn(body)
      branch(header)
      label(header)
      emitVoid(SpvOp.loopMerge, [merge, cont, 0])
      emitVoid(SpvOp.branch, [condL])
      label(condL)
      if let c = c, c.value == nil {
        let cv = value(c)
        emitVoid(SpvOp.branchConditional, [cv, bodyL, merge])
      } else {
        emitVoid(SpvOp.branch, [bodyL])
      }
      terminated = true
      label(bodyL)
      loops.append((merge: merge, cont: cont, returns: returns))
      statement(body)
      loops.removeLast()
      branch(cont)
      label(cont)
      if let st = step { _ = value(st) }
      branch(header)
      label(merge)
      if returns { afterLoopWithReturn() }
    case .doWhile(let body, let c):
      let header = b.id()
      let bodyL = b.id()
      let cont = b.id()
      let merge = b.id()
      let returns = containsReturn(body)
      branch(header)
      label(header)
      emitVoid(SpvOp.loopMerge, [merge, cont, 0])
      emitVoid(SpvOp.branch, [bodyL])
      terminated = true
      label(bodyL)
      loops.append((merge: merge, cont: cont, returns: returns))
      statement(body)
      loops.removeLast()
      branch(cont)
      label(cont)
      let cv = value(c)
      emitVoid(SpvOp.branchConditional, [cv, header, merge])
      terminated = true
      label(merge)
      if returns { afterLoopWithReturn() }
    case .ret(let e, _):
      let f = frames[frames.count - 1]
      if let e = e, let rv = f.returnVar { emitVoid(SpvOp.store, [rv, value(e)]) }
      if loops.count > f.loopBase, let flag = f.flag {
        emitVoid(SpvOp.store, [flag, b.constant(bool: true)])
        branch(loops[loops.count - 1].merge)
      } else if let exit = f.exit {
        branch(exit)
      } else {
        errors.append("a return with nowhere to go")
      }
    case .brk:
      branch(loops[loops.count - 1].merge)
    case .cont:
      branch(loops[loops.count - 1].cont)
    case .discard:
      emitVoid(SpvOp.kill, [])
      terminated = true
    }
  }

  /// A `for` loop to unroll: its index declared and initialized by a constant, compared with a constant, stepped by a
  /// constant, written nowhere else, the body leaving the loop by no break, continue or return; and few iterations of a
  /// small body. Its index variable and the values it takes.
  func unrollable(_ initializer: [Stmt], _ c: Expr?, _ step: Expr?, _ body: Stmt) -> (variable: Int, values: [Scalar])? {
    guard initializer.count == 1, case .declare(let v, let i?) = initializer[0], let start = i.value?.first,
      let c = c, let step = step
    else { return nil }
    let t = prog.variables[v].type
    guard t == .int || t == .float else { return nil }
    // The condition: the index against a constant, either way round.
    guard case .binary(let op, let l, let r) = c.kind else { return nil }
    var bound: Scalar
    var flipped = false
    if case .variable(v) = l.kind, let x = r.value?.first {
      bound = x
    } else if case .variable(v) = r.kind, let x = l.value?.first {
      bound = x
      flipped = true
    } else {
      return nil
    }
    var delta: Scalar
    switch step.kind {
    case .increment(let inc, _, let e):
      guard case .variable(v) = e.kind else { return nil }
      delta = t == .int ? .i(inc ? 1 : -1) : .f(inc ? 1 : -1)
    case .assign(let o?, let e, let d):
      guard case .variable(v) = e.kind, o == .add || o == .sub, let x = d.value?.first else { return nil }
      switch x {
      case .i(let n): delta = .i(o == .add ? n : 0 &- n)
      case .f(let f): delta = .f(o == .add ? f : -f)
      default: return nil
      }
    default: return nil
    }
    if writes(v, body) || leaves(body) { return nil }
    var values: [Scalar] = []
    var k = start
    while values.count <= 32 {
      let a = flipped ? bound : k
      let b2 = flipped ? k : bound
      let go: Bool
      switch (a, b2) {
      case (.i(let x), .i(let y)):
        switch op {
        case .lt: go = x < y
        case .le: go = x <= y
        case .gt: go = x > y
        case .ge: go = x >= y
        case .ne: go = x != y
        default: return nil
        }
      default:
        let x = a.float
        let y = b2.float
        switch op {
        case .lt: go = x < y
        case .le: go = x <= y
        case .gt: go = x > y
        case .ge: go = x >= y
        case .ne: go = x != y
        default: return nil
        }
      }
      if !go { break }
      values.append(k)
      switch (k, delta) {
      case (.i(let x), .i(let d)): k = .i(x &+ d)
      default: k = .f(k.float + delta.float)
      }
    }
    if values.count > 32 || values.count * stmtCost(body) > 2048 { return nil }
    return (v, values)
  }

  /// The body stores to the variable (or passes it as an out or inout argument).
  func writes(_ v: Int, _ s: Stmt) -> Bool {
    func e(_ x: Expr) -> Bool {
      switch x.kind {
      case .assign(_, let l, let r): return root(l) == v || e(l) || e(r)
      case .increment(_, _, let a): return root(a) == v || e(a)
      case .call(let f, let args):
        for (p, a) in zip(prog.functions[f].params, args) where prog.variables[p].qualifier != .in && root(a) == v { return true }
        return args.contains { e($0) }
      case .swizzle(let a, _), .field(let a, _), .unary(_, let a): return e(a)
      case .index(let a, let i): return e(a) || e(i)
      case .binary(_, let a, let b), .comma(let a, let b): return e(a) || e(b)
      case .select(let a, let b, let c): return e(a) || e(b) || e(c)
      case .builtin(_, let args), .construct(let args): return args.contains { e($0) }
      case .declare(_, let i): return e(i)
      default: return false
      }
    }
    switch s {
    case .expr(let x): return e(x)
    case .declare(_, let i): return i.map { e($0) } ?? false
    case .block(let ss): return ss.contains { writes(v, $0) }
    case .ifElse(let c, let a, let b): return e(c) || writes(v, a) || (b.map { writes(v, $0) } ?? false)
    case .loop(let i, let c, let st, let b): return i.contains { writes(v, $0) } || (c.map { e($0) } ?? false) || (st.map { e($0) } ?? false) || writes(v, b)
    case .doWhile(let b, let c): return writes(v, b) || e(c)
    case .ret(let x, _): return x.map { e($0) } ?? false
    default: return false
    }
  }

  func root(_ x: Expr) -> Int? {
    switch x.kind {
    case .variable(let v): return v
    case .swizzle(let a, _), .field(let a, _), .index(let a, _): return root(a)
    default: return nil
    }
  }

  /// The statement leaves the loop it is in early: a break or a continue not inside a nested loop, or a return.
  func leaves(_ s: Stmt) -> Bool {
    switch s {
    case .brk, .cont, .ret: return true
    case .block(let ss): return ss.contains { leaves($0) }
    case .ifElse(_, let a, let b): return leaves(a) || (b.map { leaves($0) } ?? false)
    case .loop(_, _, _, let b), .doWhile(let b, _): return containsReturn(b)
    default: return false
    }
  }

  /// About how many instructions a statement makes (an expression's nodes; a call its body's; a loop's body eight
  /// times).
  func stmtCost(_ s: Stmt) -> Int {
    switch s {
    case .expr(let x): return size(x)
    case .declare(_, let i): return 1 + (i.map { size($0) } ?? 0)
    case .block(let ss): return ss.reduce(0) { $0 + stmtCost($1) }
    case .ifElse(let c, let a, let b): return size(c) + stmtCost(a) + (b.map { stmtCost($0) } ?? 0)
    case .loop(let i, let c, let st, let b):
      return 8 * (i.reduce(0) { $0 + stmtCost($1) } + (c.map { size($0) } ?? 0) + (st.map { size($0) } ?? 0) + stmtCost(b))
    case .doWhile(let b, let c): return 8 * (stmtCost(b) + size(c))
    case .ret(let x, _): return 1 + (x.map { size($0) } ?? 0)
    default: return 1
    }
  }

  func size(_ x: Expr) -> Int {
    if x.value != nil { return 1 }
    switch x.kind {
    case .constant, .variable: return 1
    case .swizzle(let a, _), .field(let a, _), .unary(_, let a), .increment(_, _, let a): return 1 + size(a)
    case .index(let a, let i): return 1 + size(a) + size(i)
    case .binary(_, let a, let b), .comma(let a, let b), .assign(_, let a, let b): return x.type.components + size(a) + size(b)
    case .select(let a, let b, let c): return 1 + size(a) + size(b) + size(c)
    case .builtin(_, let args), .construct(let args): return args.reduce(4) { $0 + size($1) }
    case .call(let f, let args): return args.reduce(prog.functions[f].body?.reduce(0) { $0 + stmtCost($1) } ?? 1) { $0 + size($1) }
    case .declare(_, let i): return 1 + size(i)
    }
  }

  /// After a loop of an inlined function that returns from inside it: a return taken goes on out.
  mutating func afterLoopWithReturn() {
    guard let f = frames.last, let flag = f.flag else { return }
    let target = loops.count > f.loopBase ? loops[loops.count - 1].merge : f.exit!
    let taken = emit(SpvOp.load, b.bool, [flag])
    let out = b.id()
    let merge = b.id()
    emitVoid(SpvOp.selectionMerge, [merge, 0])
    emitVoid(SpvOp.branchConditional, [taken, out, merge])
    label(out)
    branch(target)
    label(merge)
  }

  /// The statement cannot complete normally: each path returns, breaks, continues or discards.
  func endsWithoutFallthrough(_ s: Stmt) -> Bool {
    switch s {
    case .ret, .brk, .cont, .discard: return true
    case .block(let ss):
      for x in ss where endsWithoutFallthrough(x) { return true }
      return false
    case .ifElse(let c, let a, let e?):
      if let cv = c.value { return endsWithoutFallthrough(cv[0].bool ? a : e) }
      return endsWithoutFallthrough(a) && endsWithoutFallthrough(e)
    case .ifElse(let c, let a, nil):
      if let cv = c.value, cv[0].bool { return endsWithoutFallthrough(a) }
      return false
    default: return false
    }
  }

  func containsReturn(_ s: Stmt) -> Bool {
    switch s {
    case .ret: return true
    case .block(let ss): return ss.contains { containsReturn($0) }
    case .ifElse(_, let a, let e): return containsReturn(a) || (e.map { containsReturn($0) } ?? false)
    case .loop(let i, _, _, let body): return i.contains { containsReturn($0) } || containsReturn(body)
    case .doWhile(let body, _): return containsReturn(body)
    default: return false
    }
  }

  func countReturns(_ ss: [Stmt]) -> Int {
    var n = 0
    for s in ss {
      switch s {
      case .ret: n += 1
      case .block(let b): n += countReturns(b)
      case .ifElse(_, let a, let e): n += countReturns([a]) + (e.map { countReturns([$0]) } ?? 0)
      case .loop(let i, _, _, let body): n += countReturns(i) + countReturns([body])
      case .doWhile(let body, _): n += countReturns([body])
      default: break
      }
    }
    return n
  }

  // MARK: inlining

  /// A call of a user function, its body inlined: in parameters are their arguments' values (a variable when the body
  /// writes one), out and inout parameters variables copied back to their arguments after the body; a body that
  /// returns before its end is wrapped in a loop that runs once, each return leaving it.
  mutating func inline(_ fi: Int, _ args: [Expr]) -> UInt32? {
    let f = prog.functions[fi]
    guard let body = f.body else {
      errors.append("function '\(f.name)' is called but not defined")
      return nil
    }
    var copyBack: [(Ref, UInt32)] = []
    for (p, a) in zip(f.params, args) {
      let x = prog.variables[p]
      switch x.qualifier {
      case .in:
        if prog.hasSampler(x.type) {
          places[p] = .alias(ref(a))
        } else {
          let v = value(a)
          if x.written {
            let ptr = local(x.type, name: x.name)
            emitVoid(SpvOp.store, [ptr, v])
            places[p] = .memory(ptr, StorageClass.function, laid: false, prefix: [])
          } else {
            places[p] = .value(v)
          }
        }
      case .out, .inout:
        let r = ref(a)
        let ptr = local(x.type, name: x.name)
        if x.qualifier == .inout { emitVoid(SpvOp.store, [ptr, load(r)]) }
        places[p] = .memory(ptr, StorageClass.function, laid: false, prefix: [])
        copyBack.append((r, ptr))
      }
    }
    let returns = countReturns(body)
    var result: UInt32? = nil
    let simple = returns == 0 || (returns == 1 && { if case .ret? = body.last { return true } else { return false } }())
    if simple {
      var ss = body
      var last: Expr? = nil
      if case .ret(let e, _)? = body.last {
        ss.removeLast()
        last = e
      }
      frames.append(InlineFrame(returnVar: nil, exit: nil, flag: nil, loopBase: loops.count))
      statements(ss)
      if !terminated, let e = last { result = value(e) }
      frames.removeLast()
    } else {
      let rv = f.returnType == .void ? nil : local(f.returnType, name: f.name + ".result")
      var flag: UInt32? = nil
      if body.contains(where: { s in
        if case .loop = s { return containsReturn(s) }
        if case .doWhile = s { return containsReturn(s) }
        return containsReturn(s) && hasLoop(s)
      }) {
        flag = local(.bool, name: f.name + ".returned")
        emitVoid(SpvOp.store, [flag!, b.constant(bool: false)])
      }
      let header = b.id()
      let bodyL = b.id()
      let cont = b.id()
      let exit = b.id()
      branch(header)
      label(header)
      emitVoid(SpvOp.loopMerge, [exit, cont, 0])
      emitVoid(SpvOp.branch, [bodyL])
      terminated = true
      label(bodyL)
      frames.append(InlineFrame(returnVar: rv, exit: exit, flag: flag, loopBase: loops.count))
      statements(body)
      frames.removeLast()
      branch(cont)
      label(cont)
      emitVoid(SpvOp.branchConditional, [b.constant(bool: false), header, exit])
      terminated = true
      label(exit)
      if let rv = rv { result = emit(SpvOp.load, ty(f.returnType), [rv]) }
    }
    for (r, ptr) in copyBack {
      let t = typeAfterRef(r)
      store(r, emit(SpvOp.load, ty(t), [ptr]))
    }
    return result
  }

  func hasLoop(_ s: Stmt) -> Bool {
    switch s {
    case .loop, .doWhile: return true
    case .block(let ss): return ss.contains { hasLoop($0) }
    case .ifElse(_, let a, let e): return hasLoop(a) || (e.map { hasLoop($0) } ?? false)
    default: return false
    }
  }

  func typeAfterRef(_ r: Ref) -> GType {
    if let s = r.swizzle { return GType(basic: r.type.basic, rows: s.count) }
    return r.type
  }
}
