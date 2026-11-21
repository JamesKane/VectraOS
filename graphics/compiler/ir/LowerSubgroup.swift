// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V's OpGroupNonUniform* (the GroupNonUniform capabilities) to the IR's two subgroup primitives, `lane` (valhall 13.9): the
// ballot (WMASK: a bit for each lane that executes it and has a true operand) and the lane permute (CLPER: the value in lane `k`,
// zero when that lane is not executing it). The subgroup is the warp's 16 lanes (the backend's subgroup size), scope Subgroup.
//
// The lowering follows 13.9.3, and builds what the hardware lacks from those two:
//  - ballot is the ballot; any and all are a ballot compared with zero (of the value, or of its complement); elect is the lane
//    that is the lowest bit of the active mask; broadcast, shuffle, shuffle xor, up and down and the quad operations are a permute
//    with a computed lane; broadcast first and read-first are a permute from the lowest active lane;
//  - reductions and scans (including clustered) are a loop over the 16 lanes: each active source lane that the operation includes
//    contributes its value through a constant-lane permute, and the others the identity. A butterfly or a doubling scan reads
//    lanes that are not executing, whose partial results are missing, so it is wrong in divergent code; this is right with any
//    active set, and costs 16 permutes.
// Everything on 8, 16, 32 and 64-bit values and bools is done on 32-bit words (a bool as 0 or 1, 64-bit values as two words).

extension Lowerer {
  // MARK: words

  private mutating func gsWords(_ v: ValueID, _ i: SPIRVInstruction) throws(CompileError) -> [ValueID] {
    guard case .scalar(let s) = f.type(v) else { throw fail(i, "a subgroup operation on a non-scalar") }
    switch s {
    case .i32: return [v]
    case .f32: return [emit(.bitcast, .i32, [v])]
    case .bool: return [emit(.select, .i32, [v, cInt(.i32, 1), cInt(.i32, 0)])]
    case .i8, .i16: return [emit(.zext, .i32, [v])]
    case .f16: return [emit(.zext, .i32, [emit(.bitcast, .scalar(.i16), [v])])]
    case .i64:
      let lo = emit(.trunc, .i32, [v])
      let hi = emit(.trunc, .i32, [emit(.lshr, .i64, [v, f.constant(.i64, 32)])])
      return [lo, hi]
    case .f64: throw fail(i, "a subgroup operation on a 64-bit float")
    }
  }

  private mutating func gsScalar(_ w: [ValueID], _ s: Scalar) -> ValueID {
    switch s {
    case .i32: return w[0]
    case .f32: return emit(.bitcast, .f32, [w[0]])
    case .bool: return emit(.icmp, .bool, [w[0], cInt(.i32, 0)], imm: ICmpPred.ne)
    case .i8, .i16: return emit(.trunc, .scalar(s), [w[0]])
    case .f16: return emit(.bitcast, .scalar(.f16), [emit(.trunc, .scalar(.i16), [w[0]])])
    case .i64:
      let lo = emit(.zext, .i64, [w[0]])
      let hi = emit(.shl, .i64, [emit(.zext, .i64, [w[1]]), f.constant(.i64, 32)])
      return emit(.or, .i64, [lo, hi])
    case .f64: return w[0]
    }
  }

  // MARK: primitives

  /// The mask of the lanes executing this instruction (WMASK of true): bit `i` for lane `i`.
  private mutating func gsActive() -> ValueID { emit(.lane, .i32, [f.constant(.bool, 1)], imm: 0) }

  private mutating func gsBallot(_ pred: ValueID) -> ValueID { emit(.lane, .i32, [pred], imm: 0) }

  /// The value of `w` in lane `lane` (zero when that lane is not executing).
  private mutating func gsPermute(_ w: [ValueID], lane: ValueID) -> [ValueID] {
    w.map { emit(.lane, .i32, [$0, lane], imm: 1) }
  }

  private mutating func gsLaneID() -> ValueID { emit(.builtin, .i32, [], imm: IRBuiltin.subgroupLocalId, imm2: -1) }

  /// The index of the lowest set bit of a non-zero mask below 2^24, from the exponent of its float.
  private mutating func gsLowestIndex(_ mask: ValueID) -> ValueID {
    let low = emit(.and, .i32, [mask, emit(.ineg, .i32, [mask])])
    let bits = emit(.bitcast, .i32, [emit(.uitofp, .f32, [low])])
    return emit(.isub, .i32, [emit(.lshr, .i32, [bits, cInt(.i32, 23)]), cInt(.i32, 127)])
  }

  /// The index of the highest set bit of a non-zero value below 2^24.
  private mutating func gsHighestIndex(_ x: ValueID) -> ValueID {
    let bits = emit(.bitcast, .i32, [emit(.uitofp, .f32, [x])])
    return emit(.isub, .i32, [emit(.lshr, .i32, [bits, cInt(.i32, 23)]), cInt(.i32, 127)])
  }

  /// The number of set bits of a 16-bit value.
  private mutating func gsPopCount(_ x0: ValueID) -> ValueID {
    let t = IRType.i32
    var x = emit(.and, t, [x0, cInt(.i32, 0xFFFF)])
    let a = emit(.and, t, [emit(.lshr, t, [x, cInt(.i32, 1)]), cInt(.i32, 0x5555)])
    x = emit(.isub, t, [x, a])
    let b = emit(.and, t, [x, cInt(.i32, 0x3333)])
    let c = emit(.and, t, [emit(.lshr, t, [x, cInt(.i32, 2)]), cInt(.i32, 0x3333)])
    x = emit(.iadd, t, [b, c])
    x = emit(.and, t, [emit(.iadd, t, [x, emit(.lshr, t, [x, cInt(.i32, 4)])]), cInt(.i32, 0x0F0F)])
    return emit(.and, t, [emit(.iadd, t, [x, emit(.lshr, t, [x, cInt(.i32, 8)])]), cInt(.i32, 0x1F)])
  }

  private mutating func gsIsZero(_ x: ValueID) -> ValueID { emit(.icmp, .bool, [x, cInt(.i32, 0)], imm: ICmpPred.eq) }

  // MARK: the instructions

  mutating func lowerGroupNonUniform(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    guard o.count >= 1 else { throw fail(i, "needs a scope") }
    guard try constOperand(o[0], i) == 3 else { throw fail(i, "subgroup operations take the Subgroup scope") }
    let rt = try irType(i.type, i)
    let t = IRType.i32
    switch Int(i.op) {
    case 333:  // Elect
      let m = gsActive()
      let low = emit(.and, t, [m, emit(.ineg, t, [m])])
      let mine = emit(.shl, t, [cInt(.i32, 1), gsLaneID()])
      lv[Int(i.result)] = [emit(.icmp, .bool, [mine, low], imm: ICmpPred.eq)]
    case 334, 335:  // All, Any
      guard o.count == 2 else { throw fail(i, "needs a predicate") }
      let p = try val(o[1], i)
      if i.op == 335 {
        lv[Int(i.result)] = [emit(.icmp, .bool, [gsBallot(p), cInt(.i32, 0)], imm: ICmpPred.ne)]
      } else {
        lv[Int(i.result)] = [gsIsZero(gsBallot(emit(.not, .bool, [p])))]
      }
    case 336:  // AllEqual
      guard o.count == 2 else { throw fail(i, "needs a value") }
      var all = f.constant(.bool, 1)
      let v = try val(o[1], i)
      for c in lanes(v) {
        let w = try gsWords(c, i)
        let first = gsLowestIndex(gsActive())
        let b = gsPermute(w, lane: first)
        var eq = f.constant(.bool, 1)
        if case .scalar(let s) = f.type(c), s == .f32 || s == .f16 {
          let bc = gsScalar(b, s)
          eq = emit(.fcmp, .bool, [c, bc], imm: FCmpPred.oeq)
        } else {
          for k in 0..<w.count { eq = emit(.and, .bool, [eq, emit(.icmp, .bool, [w[k], b[k]], imm: ICmpPred.eq)]) }
        }
        all = emit(.and, .bool, [all, eq])
      }
      lv[Int(i.result)] = [gsIsZero(gsBallot(emit(.not, .bool, [all])))]
    case 337, 338, 345, 346, 347, 348, 365, 366:
      try lowerPermute(i, rt)
    case 339:  // Ballot
      guard o.count == 2 else { throw fail(i, "needs a predicate") }
      let m = gsBallot(try val(o[1], i))
      let z = cInt(.i32, 0)
      lv[Int(i.result)] = [makeVector([m, z, z, z])]
    case 340, 341, 342, 343, 344:
      try lowerBallotBits(i, rt)
    default:
      try lowerGroupArithmetic(i, rt)
    }
  }

  private mutating func lowerPermute(_ i: SPIRVInstruction, _ rt: IRType) throws(CompileError) {
    let o = i.operands
    guard o.count >= 2 else { throw fail(i, "needs a value") }
    let v = try val(o[1], i)
    let t = IRType.i32
    var lane: ValueID
    switch Int(i.op) {
    case 338:
      lane = gsLowestIndex(gsActive())
    case 337, 345:
      guard o.count == 3 else { throw fail(i, "needs a lane") }
      lane = emit(.and, t, [try val(o[2], i), cInt(.i32, 15)])
    case 346:
      guard o.count == 3 else { throw fail(i, "needs a mask") }
      lane = emit(.and, t, [emit(.xor, t, [gsLaneID(), try val(o[2], i)]), cInt(.i32, 15)])
    case 347:
      guard o.count == 3 else { throw fail(i, "needs a delta") }
      lane = emit(.and, t, [emit(.isub, t, [gsLaneID(), try val(o[2], i)]), cInt(.i32, 15)])
    case 348:
      guard o.count == 3 else { throw fail(i, "needs a delta") }
      lane = emit(.and, t, [emit(.iadd, t, [gsLaneID(), try val(o[2], i)]), cInt(.i32, 15)])
    case 365:
      guard o.count == 3 else { throw fail(i, "needs an index") }
      let base = emit(.and, t, [gsLaneID(), cInt(.i32, 12)])
      lane = emit(.or, t, [base, emit(.and, t, [try val(o[2], i), cInt(.i32, 3)])])
    default:  // 366: QuadSwap, direction 0 horizontal, 1 vertical, 2 diagonal
      guard o.count == 3 else { throw fail(i, "needs a direction") }
      let d = Int(try constOperand(o[2], i))
      lane = emit(.xor, t, [gsLaneID(), cInt(.i32, d == 0 ? 1 : d == 1 ? 2 : 3)])
    }
    var out: [ValueID] = []
    for c in lanes(v) {
      guard case .scalar(let s) = f.type(c) else { throw fail(i, "a subgroup operation on a non-scalar") }
      out.append(gsScalar(gsPermute(try gsWords(c, i), lane: lane), s))
    }
    _ = rt
    lv[Int(i.result)] = [makeVector(out)]
  }

  private mutating func lowerBallotBits(_ i: SPIRVInstruction, _ rt: IRType) throws(CompileError) {
    let o = i.operands
    let t = IRType.i32
    switch Int(i.op) {
    case 340:  // InverseBallot
      guard o.count == 2 else { throw fail(i, "needs a ballot") }
      let x = lanes(try val(o[1], i))[0]
      let bit = emit(.and, t, [emit(.lshr, t, [x, gsLaneID()]), cInt(.i32, 1)])
      lv[Int(i.result)] = [emit(.icmp, .bool, [bit, cInt(.i32, 0)], imm: ICmpPred.ne)]
    case 341:  // BallotBitExtract
      guard o.count == 3 else { throw fail(i, "needs a ballot and an index") }
      let x = lanes(try val(o[1], i))[0]
      let idx = try val(o[2], i)
      let bit = emit(.and, t, [emit(.lshr, t, [x, emit(.and, t, [idx, cInt(.i32, 31)])]), cInt(.i32, 1)])
      let inRange = emit(.icmp, .bool, [idx, cInt(.i32, 16)], imm: ICmpPred.ult)
      lv[Int(i.result)] = [emit(.and, .bool, [inRange, emit(.icmp, .bool, [bit, cInt(.i32, 0)], imm: ICmpPred.ne)])]
    case 342:  // BallotBitCount
      guard o.count == 3 else { throw fail(i, "needs an operation and a ballot") }
      let op = Int(o[1])
      var x = emit(.and, t, [lanes(try val(o[2], i))[0], cInt(.i32, 0xFFFF)])
      if op == 1 {
        // up to and including this lane
        x = emit(.and, t, [x, emit(.isub, t, [emit(.shl, t, [cInt(.i32, 2), gsLaneID()]), cInt(.i32, 1)])])
      } else if op == 2 {
        x = emit(.and, t, [x, emit(.isub, t, [emit(.shl, t, [cInt(.i32, 1), gsLaneID()]), cInt(.i32, 1)])])
      } else if op != 0 {
        throw fail(i, "BallotBitCount takes Reduce, InclusiveScan or ExclusiveScan")
      }
      lv[Int(i.result)] = [gsPopCount(x)]
    case 343:  // BallotFindLSB
      guard o.count == 2 else { throw fail(i, "needs a ballot") }
      let x = emit(.and, t, [lanes(try val(o[1], i))[0], cInt(.i32, 0xFFFF)])
      let idx = gsLowestIndex(x)
      lv[Int(i.result)] = [emit(.select, t, [gsIsZero(x), cInt(.i32, -1), idx])]
    default:  // 344: BallotFindMSB
      guard o.count == 2 else { throw fail(i, "needs a ballot") }
      let x = emit(.and, t, [lanes(try val(o[1], i))[0], cInt(.i32, 0xFFFF)])
      let idx = gsHighestIndex(x)
      lv[Int(i.result)] = [emit(.select, t, [gsIsZero(x), cInt(.i32, -1), idx])]
    }
    _ = rt
  }

  /// OpGroupNonUniformIAdd .. LogicalXor: Reduce, InclusiveScan, ExclusiveScan and ClusteredReduce.
  private mutating func lowerGroupArithmetic(_ i: SPIRVInstruction, _ rt: IRType) throws(CompileError) {
    let o = i.operands
    guard o.count >= 3 else { throw fail(i, "needs an operation and a value") }
    let groupOp = Int(o[1])
    guard groupOp <= 3 else { throw fail(i, "the group operation is not supported") }
    var cluster = 16
    if groupOp == 3 {
      guard o.count == 4 else { throw fail(i, "ClusteredReduce needs a cluster size") }
      cluster = Int(try constOperand(o[3], i))
      guard cluster >= 1, cluster & (cluster - 1) == 0 else { throw fail(i, "the cluster size is not a power of two") }
      cluster = min(cluster, 16)
    }
    let t = IRType.i32
    let v = try val(o[2], i)
    let active = gsActive()
    let me = gsLaneID()
    var results: [ValueID] = []
    for c in lanes(v) {
      guard case .scalar(let s) = f.type(c) else { throw fail(i, "a subgroup operation on a non-scalar") }
      let ty = IRType.scalar(s)
      // The operation and its identity.
      var id: UInt64 = 0
      func combine(_ lowerer: inout Lowerer, _ a: ValueID, _ b: ValueID) -> ValueID {
        switch Int(i.op) {
        case 349: return lowerer.emit(.iadd, ty, [a, b])
        case 350: return lowerer.emit(.fadd, ty, [a, b])
        case 351: return lowerer.emit(.imul, ty, [a, b])
        case 352: return lowerer.emit(.fmul, ty, [a, b])
        case 353: return lowerer.emit(.smin, ty, [a, b])
        case 354: return lowerer.emit(.umin, ty, [a, b])
        case 355: return lowerer.emit(.fmin, ty, [a, b])
        case 356: return lowerer.emit(.smax, ty, [a, b])
        case 357: return lowerer.emit(.umax, ty, [a, b])
        case 358: return lowerer.emit(.fmax, ty, [a, b])
        case 359, 362: return lowerer.emit(.and, ty, [a, b])
        case 360, 363: return lowerer.emit(.or, ty, [a, b])
        default: return lowerer.emit(.xor, ty, [a, b])
        }
      }
      let bits = UInt64(s.bits)
      let ones: UInt64 = s.bits >= 64 ? UInt64.max : (1 << bits) - 1
      switch Int(i.op) {
      case 349, 360, 361, 363, 364: id = 0
      case 350: id = floatBits(s, 0)
      case 351: id = 1
      case 352: id = floatBits(s, 1)
      case 353: id = ones >> 1
      case 354, 359: id = ones
      case 355: id = floatBits(s, Double.infinity)
      case 356: id = 1 << (bits - 1)
      case 357: id = 0
      case 358: id = floatBits(s, -Double.infinity)
      case 362: id = 1
      default: throw fail(i, "the operation is not supported")
      }
      let identity = f.constant(s, id)
      let words = try gsWords(c, i)
      var acc = identity
      for j in 0..<16 {
        // Source lane j contributes when it executes this instruction and the group operation includes it.
        let runs = emit(.icmp, .bool, [emit(.and, t, [emit(.lshr, t, [active, cInt(.i32, j)]), cInt(.i32, 1)]), cInt(.i32, 0)], imm: ICmpPred.ne)
        var include = runs
        switch groupOp {
        case 1: include = emit(.and, .bool, [include, emit(.icmp, .bool, [cInt(.i32, j), me], imm: ICmpPred.ule)])
        case 2: include = emit(.and, .bool, [include, emit(.icmp, .bool, [cInt(.i32, j), me], imm: ICmpPred.ult)])
        case 3 where cluster < 16:
          let same = emit(.icmp, .bool, [emit(.and, t, [me, cInt(.i32, ~(cluster - 1) & 15)]), cInt(.i32, j & ~(cluster - 1))], imm: ICmpPred.eq)
          include = emit(.and, .bool, [include, same])
        default: break
        }
        let got = gsScalar(gsPermute(words, lane: cInt(.i32, j)), s)
        let pick = emit(.select, ty, [include, got, identity])
        acc = combine(&self, acc, pick)
      }
      results.append(acc)
    }
    _ = rt
    lv[Int(i.result)] = [makeVector(results)]
  }
}
