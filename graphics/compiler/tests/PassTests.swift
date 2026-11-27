// SPDX-License-Identifier: BSD-3-Clause

// Each pass on hand-built functions, and on the corpus.

import ShaderCompiler
import ShaderTestKit
import Testing

/// A one-function module with the given entry block's builder.
func build(_ body: (inout Function, BlockID) -> Void) -> Function {
  var f = Function(name: "t", params: [], returns: .void)
  let b = f.addBlock()
  body(&f, b)
  return f
}

/// A function ending in a store of `v` to a storage buffer, so `v` stays live.
func keep(_ f: inout Function, _ b: BlockID, _ v: ValueID) {
  let p = f.resource(set: 0, binding: 0, space: .storage)
  f.append(Inst(.store, .void, [p, v], imm: 4), to: b)
  f.append(Inst(.ret, .void, []), to: b)
}

func moduleOf(_ f: Function) -> IRModule {
  var m = IRModule()
  m.functions = [f]
  return m
}

func opCount(_ f: Function, _ op: IROp) -> Int {
  var n = 0
  for b in f.blocks { for id in b.insts where f.insts[id].op == op { n += 1 } }
  return n
}

@Suite struct ConstantFoldingTests {
  @Test func integerArithmeticFolds() throws {
    var f = build { f, b in
      let a = f.constant(.i32, 7)
      let c = f.constant(.i32, 5)
      let s = f.append(Inst(.iadd, .i32, [a, c]), to: b)
      let m = f.append(Inst(.imul, .i32, [s, c]), to: b)
      let n = f.append(Inst(.isub, .i32, [f.constant(.i32, 1), m]), to: b)  // wraps
      keep(&f, b, n)
    }
    let changed = f.foldConstants()
    #expect(changed)
    try moduleOf(f).verify()
    #expect(f.text().contains("store @res(0,0):ptr<storage>, i32 -59 align 4"), "\(f.text())")
    #expect(opCount(f, .iadd) == 0 && opCount(f, .imul) == 0)
  }

  @Test func comparesSelectsAndConversionsFold() throws {
    var f = build { f, b in
      let a = f.constant(.i32, UInt64(bitPattern: -3) & 0xffff_ffff)
      let z = f.constant(.i32, 0)
      let lt = f.append(Inst(.icmp, .bool, [a, z], imm: ICmpPred.slt), to: b)
      let ult = f.append(Inst(.icmp, .bool, [a, z], imm: ICmpPred.ult), to: b)
      let both = f.append(Inst(.and, .bool, [lt, ult]), to: b)  // true & false
      let sel = f.append(Inst(.select, .i32, [lt, f.constant(.i32, 10), f.constant(.i32, 20)]), to: b)
      let wide = f.append(Inst(.sext, .i64, [a]), to: b)
      let narrow = f.append(Inst(.trunc, .scalar(.i16), [wide]), to: b)
      let z16 = f.append(Inst(.zext, .i32, [narrow]), to: b)
      let x = f.append(Inst(.select, .i32, [both, sel, z16]), to: b)
      keep(&f, b, x)
    }
    f.foldConstants()
    try moduleOf(f).verify()
    // -3 as 16 bits, zero-extended: 65533.
    #expect(f.text().contains("store @res(0,0):ptr<storage>, i32 65533"), "\(f.text())")
    #expect(f.blocks[0].insts.count == 2)
  }

  @Test func aProductWithZeroIsZeroAndASumWithZeroTheOtherTerm() throws {
    // x * 0 + y * 1 + -0 is y (signed zeros, infinities and NaNs need not be kept): no multiply or add is left.
    var f = build { f, b in
      let p = f.resource(set: 0, binding: 1, space: .storage)
      let x = f.append(Inst(.load, .f32, [p], imm: 4), to: b)
      let y = f.append(Inst(.load, .f32, [p], imm: 4), to: b)
      let zero = f.constant(.f32, 0)
      let negZero = f.constant(.f32, UInt64(Float(-0.0).bitPattern))
      let m = f.append(Inst(.fmul, .f32, [x, zero]), to: b)
      let s = f.append(Inst(.fadd, .f32, [m, y]), to: b)
      let t = f.append(Inst(.fadd, .f32, [s, negZero]), to: b)
      let u = f.append(Inst(.fma, .f32, [negZero, x, t]), to: b)
      keep(&f, b, u)
    }
    let changed = f.propagateCopies()
    #expect(changed)
    try moduleOf(f).verify()
    #expect(opCount(f, .fmul) == 0 && opCount(f, .fadd) == 0 && opCount(f, .fma) == 0, "\(f.text())")
  }

  @Test func equalLoadsMergeUntilAStoreAndAProductUsedOnceFusesIntoItsSum() throws {
    var f = build { f, b in
      let p = f.resource(set: 0, binding: 1, space: .storage)
      let a = f.append(Inst(.load, .f32, [p], imm: 4), to: b)
      let a2 = f.append(Inst(.load, .f32, [p], imm: 4), to: b)  // the same as a
      let m = f.append(Inst(.fmul, .f32, [a, a2]), to: b)
      let s = f.append(Inst(.fadd, .f32, [m, a]), to: b)  // a * a + a: one fma
      f.append(Inst(.store, .void, [p, s], imm: 4), to: b)
      let a3 = f.append(Inst(.load, .f32, [p], imm: 4), to: b)  // after a store: read again
      keep(&f, b, a3)
    }
    let merged = f.eliminateCommonSubexpressions()
    #expect(merged)
    #expect(opCount(f, .load) == 2, "\(f.text())")
    let fused = f.contractMultiplyAdds()
    #expect(fused)
    try moduleOf(f).verify()
    #expect(opCount(f, .fmul) == 0 && opCount(f, .fadd) == 0 && opCount(f, .fma) == 1, "\(f.text())")
  }

  @Test func floatsFoldInTheirOwnWidth() throws {
    var f = build { f, b in
      let h = f.constant(.f32, UInt64(Float(0.1).bitPattern))
      let t = f.constant(.f32, UInt64(Float(0.2).bitPattern))
      let s = f.append(Inst(.fadd, .f32, [h, t]), to: b)
      let q = f.append(Inst(.fsqrt, .f32, [f.constant(.f32, UInt64(Float(16).bitPattern))]), to: b)
      let r = f.append(Inst(.fmul, .f32, [s, q]), to: b)
      let i = f.append(Inst(.fptosi, .i32, [f.constant(.f32, UInt64(Float(-2.75).bitPattern))]), to: b)
      let c = f.append(Inst(.sitofp, .f32, [i]), to: b)
      let o = f.append(Inst(.fadd, .f32, [r, c]), to: b)
      keep(&f, b, o)
    }
    f.foldConstants()
    let want = (Float(0.1) + Float(0.2)) * 4 + (-2)
    #expect(f.text().contains("f32 \(hexString(UInt64(want.bitPattern)))"), "\(f.text())")
  }

  @Test func whatIsUndefinedIsLeftAlone() throws {
    var f = build { f, b in
      let one = f.constant(.i32, 1)
      let zero = f.constant(.i32, 0)
      let d = f.append(Inst(.udiv, .i32, [one, zero]), to: b)
      let s = f.append(Inst(.shl, .i32, [one, f.constant(.i32, 40)]), to: b)
      let big = f.append(Inst(.fptosi, .i32, [f.constant(.f32, UInt64(Float(1e20).bitPattern))]), to: b)
      let x = f.append(Inst(.iadd, .i32, [f.append(Inst(.iadd, .i32, [d, s]), to: b), big]), to: b)
      keep(&f, b, x)
    }
    let again = f.foldConstants()
    #expect(!again)
    #expect(opCount(f, .udiv) == 1 && opCount(f, .shl) == 1 && opCount(f, .fptosi) == 1)
  }

  @Test func vectorsFoldALaneAtATime() throws {
    var f = build { f, b in
      let a = f.constVector([f.constant(.i32, 1), f.constant(.i32, 2), f.constant(.i32, 3)])
      let c = f.constVector([f.constant(.i32, 10), f.constant(.i32, 20), f.constant(.i32, 30)])
      let s = f.append(Inst(.iadd, .vector(.i32, 3), [a, c]), to: b)
      let e = f.append(Inst(.extract, .i32, [s], imm: 2), to: b)
      let sh = f.append(Inst(.shuffle, .vector(.i32, 2), [a, c], payload: [5, 0]), to: b)
      let e2 = f.append(Inst(.extract, .i32, [sh], imm: 0), to: b)
      let o = f.append(Inst(.iadd, .i32, [e, e2]), to: b)
      keep(&f, b, o)
    }
    f.foldConstants()
    #expect(f.text().contains("i32 63 align 4"), "\(f.text())")
  }
}

func hexString(_ v: UInt64) -> String {
  let d = Array("0123456789abcdef")
  var x = v
  var s: [Character] = []
  if x == 0 { return "0x0" }
  while x != 0 {
    s.append(d[Int(x & 15)])
    x >>= 4
  }
  return "0x" + String(s.reversed())
}

@Suite struct CopyPropagationTests {
  @Test func identitiesAndTrivialPhisForward() throws {
    var f = Function(name: "t", params: [.i32], returns: .void)
    let b0 = f.addBlock()
    let b1 = f.addBlock()
    let b2 = f.addBlock()
    let p = f.param(0)
    f.append(Inst(.br, .void, [], blocks: [b1]), to: b0)
    let z = f.constant(.i32, 0)
    let one = f.constant(.i32, 1)
    let a = f.append(Inst(.iadd, .i32, [p, z]), to: b1)
    let m = f.append(Inst(.imul, .i32, [one, a]), to: b1)
    let cond = f.append(Inst(.icmp, .bool, [m, z], imm: ICmpPred.eq), to: b1)
    f.append(Inst(.condbr, .void, [cond], blocks: [b2, b2]), to: b1)
    let ph = f.append(Inst(.phi, .i32, [m, m], blocks: [b1, b1]), to: b2)
    let s = f.append(Inst(.select, .i32, [cond, ph, ph]), to: b2)
    keep(&f, b2, s)
    let changed = f.propagateCopies()
    #expect(changed)
    try moduleOf(f).verify()
    #expect(f.text().contains("store @res(0,0):ptr<storage>, %0 align 4"), "\(f.text())")
    #expect(opCount(f, .phi) == 0 && opCount(f, .select) == 0 && opCount(f, .iadd) == 0 && opCount(f, .imul) == 0)
  }

  @Test func vectorsBuiltAndTakenApartForward() throws {
    var f = Function(name: "t", params: [.i32, .i32], returns: .void)
    let b = f.addBlock()
    let v = f.append(Inst(.vecbuild, .vector(.i32, 2), [f.param(0), f.param(1)]), to: b)
    let e0 = f.append(Inst(.extract, .i32, [v], imm: 0), to: b)
    let e1 = f.append(Inst(.extract, .i32, [v], imm: 1), to: b)
    let again = f.append(Inst(.vecbuild, .vector(.i32, 2), [e0, e1]), to: b)
    let ins = f.append(Inst(.insert, .vector(.i32, 2), [again, f.param(0)], imm: 1), to: b)
    let r = f.append(Inst(.extract, .i32, [ins], imm: 1), to: b)
    keep(&f, b, r)
    f.propagateCopies()
    try moduleOf(f).verify()
    #expect(f.text().contains("store @res(0,0):ptr<storage>, %0 align 4"), "\(f.text())")
    #expect(opCount(f, .vecbuild) == 0 && opCount(f, .extract) == 0)
  }
}

@Suite struct CSETests {
  @Test func equalInstructionsInABlockMerge() throws {
    var f = Function(name: "t", params: [.i32, .i32], returns: .void)
    let b = f.addBlock()
    let x = f.append(Inst(.iadd, .i32, [f.param(0), f.param(1)]), to: b)
    let y = f.append(Inst(.iadd, .i32, [f.param(1), f.param(0)]), to: b)  // commutes
    let z = f.append(Inst(.isub, .i32, [f.param(0), f.param(1)]), to: b)
    let w = f.append(Inst(.isub, .i32, [f.param(1), f.param(0)]), to: b)  // does not
    let r1 = f.append(Inst(.imul, .i32, [x, y]), to: b)
    let r2 = f.append(Inst(.imul, .i32, [z, w]), to: b)
    let r3 = f.append(Inst(.iadd, .i32, [r1, r2]), to: b)
    keep(&f, b, r3)
    let changed = f.eliminateCommonSubexpressions()
    #expect(changed)
    try moduleOf(f).verify()
    #expect(opCount(f, .iadd) == 2 && opCount(f, .isub) == 2)
    #expect(f.text().contains("imul %2, %2"), "\(f.text())")
  }

  @Test func loadsAndOtherBlocksAreKept() throws {
    var f = Function(name: "t", params: [.i32], returns: .void)
    let b0 = f.addBlock()
    let b1 = f.addBlock()
    let p = f.resource(set: 0, binding: 0, space: .storage)
    let l1 = f.append(Inst(.load, .i32, [p], imm: 4), to: b0)
    let l2 = f.append(Inst(.load, .i32, [p], imm: 4), to: b0)
    let a = f.append(Inst(.iadd, .i32, [l1, f.param(0)]), to: b0)
    f.append(Inst(.br, .void, [], blocks: [b1]), to: b0)
    let a2 = f.append(Inst(.iadd, .i32, [l1, f.param(0)]), to: b1)
    let s = f.append(Inst(.iadd, .i32, [a2, f.append(Inst(.iadd, .i32, [a, l2]), to: b1)]), to: b1)
    keep(&f, b1, s)
    f.eliminateCommonSubexpressions()
    // The two loads of one block merge (nothing writes memory between them); the adds of the two blocks don't.
    #expect(opCount(f, .load) == 1)
    #expect(opCount(f, .iadd) == 4)  // not merged across blocks
  }
}

@Suite struct DeadCodeTests {
  @Test func unusedPureInstructionsGoButEffectsStay() throws {
    var f = Function(name: "t", params: [.i32], returns: .void)
    let b = f.addBlock()
    let p = f.resource(set: 0, binding: 0, space: .storage)
    let dead = f.append(Inst(.imul, .i32, [f.param(0), f.param(0)]), to: b)
    _ = f.append(Inst(.iadd, .i32, [dead, dead]), to: b)
    _ = f.append(Inst(.load, .i32, [p], imm: 4), to: b)  // unused load
    _ = f.append(Inst(.load, .i32, [p], imm: 4, imm2: 1), to: b)  // volatile
    f.append(Inst(.store, .void, [p, f.param(0)], imm: 4), to: b)
    f.append(Inst(.barrier, .void, []), to: b)
    f.append(Inst(.ret, .void, []), to: b)
    let changed = f.eliminateDeadCode()
    #expect(changed)
    try moduleOf(f).verify()
    #expect(opCount(f, .imul) == 0 && opCount(f, .iadd) == 0)
    #expect(opCount(f, .load) == 1 && opCount(f, .store) == 1 && opCount(f, .barrier) == 1)
    let again = f.eliminateDeadCode()
    #expect(!again)
  }

  @Test func aPhiCycleNothingReadsGoes() throws {
    var f = Function(name: "t", params: [.i32], returns: .void)
    let b0 = f.addBlock()
    let b1 = f.addBlock()
    f.append(Inst(.br, .void, [], blocks: [b1]), to: b0)
    let phi = f.makeInst(Inst(.phi, .i32, []))
    f.blocks[b1].insts.append(phi)
    let r = f.insts[phi].result
    let next = f.append(Inst(.iadd, .i32, [r, f.constant(.i32, 1)]), to: b1)
    f.insts[phi].args = [f.param(0), next]
    f.insts[phi].blocks = [b0, b1]
    let c = f.constant(.bool, 1)
    f.append(Inst(.condbr, .void, [c], blocks: [b1, b1]), to: b1)
    // The loop never exits, but nothing uses the counter: it's all dead.
    try moduleOf(f).verify()
    let changed = f.eliminateDeadCode()
    #expect(changed)
    #expect(opCount(f, .phi) == 0 && opCount(f, .iadd) == 0)
  }
}

@Suite struct Mem2RegTests {
  @Test func theLoopsCountersBecomePhis() throws {
    let ir = try lowered(Corpus.loopsum)
    #expect(opCount(ir.functions[0], .alloca) == 2)
    var o = ir
    try o.optimize(scalarize: false)
    let f = o.functions[0]
    #expect(opCount(f, .alloca) == 0 && opCount(f, .load) == 0)
    #expect(opCount(f, .store) == 1)  // only the result
    #expect(opCount(f, .phi) == 3, "\(f.text())")  // i and acc at the header, acc at the join
  }

  @Test func aStructWithConstantAccessesSplitsAndAnArrayIndexedDynamicallyStays() throws {
    var o = try lowered(Corpus.locals)
    #expect(opCount(o.functions[0], .alloca) == 2)
    try o.optimize(scalarize: false)
    #expect(opCount(o.functions[0], .alloca) == 1, "\(o.functions[0].text())")
    #expect(o.functions[0].text().contains("alloca size 16 align 4"))
  }

  @Test func aReadBeforeAnyWriteIsUndefAndBranchesJoinWithPhis() throws {
    var f = Function(name: "t", params: [.bool], returns: .void)
    let b0 = f.addBlock()
    let bt = f.addBlock()
    let bj = f.addBlock()
    let a = f.append(Inst(.alloca, .ptr(.function), [], imm: 4, imm2: 4), to: b0)
    f.append(Inst(.condbr, .void, [f.param(0)], blocks: [bt, bj]), to: b0)
    f.blocks[b0].kind = .selection
    f.blocks[b0].merge = bj
    f.append(Inst(.store, .void, [a, f.constant(.i32, 5)], imm: 4), to: bt)
    f.append(Inst(.br, .void, [], blocks: [bj]), to: bt)
    let l = f.append(Inst(.load, .i32, [a], imm: 4), to: bj)
    keep(&f, bj, l)
    let changed = f.promoteAllocas()
    #expect(changed)
    try moduleOf(f).verify()
    #expect(opCount(f, .alloca) == 0 && opCount(f, .load) == 0)
    #expect(f.text().contains("phi [undef:i32, bb0], [i32 5, bb1]") || f.text().contains("phi [i32 5, bb1], [undef:i32, bb0]"), "\(f.text())")
  }

  @Test func anEscapingAllocaIsLeftAlone() throws {
    var f = Function(name: "t", params: [], returns: .void)
    let b = f.addBlock()
    let a = f.append(Inst(.alloca, .ptr(.function), [], imm: 4, imm2: 4), to: b)
    f.append(Inst(.store, .void, [a, f.constant(.i32, 1)], imm: 4), to: b)
    let ptr = f.resource(set: 0, binding: 0, space: .storage)
    _ = ptr
    // The pointer itself is stored: it escapes.
    let slot = f.append(Inst(.alloca, .ptr(.function), [], imm: 4, imm2: 4), to: b)
    f.append(Inst(.store, .void, [slot, a], imm: 4), to: b)
    let l = f.append(Inst(.load, .i32, [a], imm: 4), to: b)
    keep(&f, b, l)
    f.promoteAllocas()
    #expect(opCount(f, .alloca) == 1 && opCount(f, .load) == 1)  // the one never read is gone
  }
}

@Suite struct ScalarizeTests {
  @Test func noVectorSurvives() throws {
    for text in [Corpus.vec, Corpus.fill, Corpus.reduce, Corpus.atomics] {
      var m = try lowered(text)
      try m.scalarize()
      try m.verify(scalar: true)
    }
  }

  @Test func aVectorLoadAndStoreSplitIntoLanes() throws {
    var m = try lowered(Corpus.vec)
    #expect(opCount(m.functions[0], .load) == 1)
    try m.scalarize()
    let f = m.functions[0]
    #expect(opCount(f, .load) == 4 && opCount(f, .store) == 4)
    #expect(opCount(f, .vecbuild) == 0 && opCount(f, .extract) == 0)
    // Lanes sit at consecutive element offsets.
    #expect(f.text().contains("ptradd %2, i32 12"), "\(f.text())")
  }

  @Test func vectorBuiltinsBecomeComponentBuiltins() throws {
    var f = Function(name: "t", params: [], returns: .void)
    let b = f.addBlock()
    let v = f.append(Inst(.builtin, .vector(.i32, 3), [], imm: IRBuiltin.workgroupId, imm2: -1), to: b)
    let e = f.append(Inst(.extract, .i32, [v], imm: 1), to: b)
    keep(&f, b, e)
    try f.scalarize()
    try moduleOf(f).verify(scalar: true)
    #expect(opCount(f, .builtin) == 3)
    f.eliminateDeadCode()
    #expect(opCount(f, .builtin) == 1)
    #expect(f.text().contains("builtin workgroup_id.y"), "\(f.text())")
  }

  @Test func vectorPhisSplit() throws {
    var f = Function(name: "t", params: [.vector(.f32, 2), .bool], returns: .void)
    _ = f
    f = Function(name: "t", params: [.bool], returns: .void)
    let b0 = f.addBlock()
    let b1 = f.addBlock()
    let v0 = f.constVector([f.constant(.f32, 0), f.constant(.f32, 1)])
    f.append(Inst(.br, .void, [], blocks: [b1]), to: b0)
    let phi = f.makeInst(Inst(.phi, .vector(.f32, 2), []))
    f.blocks[b1].insts.append(phi)
    let r = f.insts[phi].result
    let two = f.constVector([f.constant(.f32, UInt64(Float(2).bitPattern)), f.constant(.f32, UInt64(Float(2).bitPattern))])
    let next = f.append(Inst(.fmul, .vector(.f32, 2), [r, two]), to: b1)
    f.insts[phi].args = [v0, next]
    f.insts[phi].blocks = [b0, b1]
    f.append(Inst(.condbr, .void, [f.param(0)], blocks: [b1, b1]), to: b1)
    f.blocks[b1].kind = .loop
    f.blocks[b1].merge = b0
    f.blocks[b1].continueTarget = b1
    // (Not a legal loop, so only scalarise; don't verify structure.)
    try f.scalarize()
    #expect(opCount(f, .phi) == 2 && opCount(f, .fmul) == 2)
    for b in f.blocks { for id in b.insts { #expect(!f.insts[id].type.isVector) } }
  }

  @Test func vectorParametersAreRefusedByName() {
    var f = Function(name: "helper", params: [.vector(.f32, 2)], returns: .void)
    let b = f.addBlock()
    f.append(Inst(.ret, .void, []), to: b)
    _ = f.constVector([f.constant(.f32, 0), f.constant(.f32, 0)])
    do {
      try f.scalarize()
      Issue.record("accepted")
    } catch {
      #expect(error.message.contains("helper") && error.message.contains("vector parameter"))
    }
  }
}

@Suite struct PipelineTests {
  @Test func theWholePipelineCleansTheCorpus() throws {
    var m = try lowered(Corpus.loopsum)
    try m.optimize()
    try m.verify(scalar: true)
    let f = m.functions[0]
    #expect(opCount(f, .alloca) == 0)
    #expect(f.blocks.contains { $0.kind == .loop } && f.blocks.contains { $0.kind == .selection })
  }
}
