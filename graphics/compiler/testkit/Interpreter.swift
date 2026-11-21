// SPDX-License-Identifier: BSD-3-Clause

// An interpreter for the IR, for tests: it runs a compute dispatch, one
// workgroup at a time, with every invocation of the group stepping to its
// next barrier before any goes on. It shares nothing with the compiler's own
// constant folder, so a shader run before and after the passes, against a CPU
// reference, checks lowering and passes together.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderCompiler

public struct InterpError: Error, CustomStringConvertible {
  public var description: String
}

private struct Frame {
  var fn: Int
  var vals: [[UInt64]]
  var block = 0
  var pos = 0
  var prev = -1
}

private enum Outcome {
  case done([UInt64])
  case barrier
}

private final class Invocation {
  var frame: Frame
  var priv: [[UInt8]] = []
  var local: [[UInt8]] = []
  var gid: [UInt64] = [0, 0, 0]
  var lid: [UInt64] = [0, 0, 0]
  var wid: [UInt64] = [0, 0, 0]
  var nwg: [UInt64] = [0, 0, 0]
  var lindex: UInt64 = 0
  var finished = false
  init(frame: Frame) { self.frame = frame }
}

public final class Machine {
  public let m: IRModule
  public var storage: [Int: [UInt8]] = [:]
  public var push: [UInt8] = []
  /// A vertex shader's VertexIndex and InstanceIndex.
  public var vertexIndex: UInt64 = 0
  public var instanceIndex: UInt64 = 0
  /// A vertex or fragment shader's inputs and what it wrote to its outputs, by index into the module's `inputs` and
  /// `outputs`: each one's components as bits.
  public var stageInputs: [Int: [UInt64]] = [:]
  public var stageOutputs: [Int: [UInt64]] = [:]
  /// What a texel access reads: the image's and the sampler's element (the heap slots), the coordinates and other words
  /// of the access, and the component wanted.
  public var texelModel: ((_ image: UInt64, _ sampler: UInt64, _ operands: [UInt64], _ component: Int) -> UInt64)?
  /// The fragment's position (FragCoord, four floats' bits).
  public var fragCoord: [UInt64] = [0, 0, 0, 0]
  private var shared: [[UInt8]] = []
  /// Instructions executed (all invocations).
  public var steps = 0

  public init(_ module: IRModule) { m = module }

  public func setBuffer(_ set: Int, _ binding: Int, _ bytes: [UInt8]) { storage[set << 8 | binding] = bytes }

  public func dispatch(groups: (Int, Int, Int)) throws {
    let ls = m.localSize
    for gz in 0..<groups.2 {
      for gy in 0..<groups.1 {
        for gx in 0..<groups.0 {
          shared = m.globals.map { $0.space == .workgroup ? [UInt8](repeating: 0, count: $0.size) : [] }
          var invs: [Invocation] = []
          for lz in 0..<Int(ls.z) {
            for ly in 0..<Int(ls.y) {
              for lx in 0..<Int(ls.x) {
                let f = m.functions[m.entry]
                let inv = Invocation(frame: Frame(fn: m.entry, vals: [[UInt64]](repeating: [], count: f.values.count)))
                inv.priv = m.globals.map { $0.space == .private_ ? [UInt8](repeating: 0, count: $0.size) : [] }
                inv.lid = [UInt64(lx), UInt64(ly), UInt64(lz)]
                inv.wid = [UInt64(gx), UInt64(gy), UInt64(gz)]
                inv.nwg = [UInt64(groups.0), UInt64(groups.1), UInt64(groups.2)]
                inv.gid = [
                  UInt64(gx * Int(ls.x) + lx), UInt64(gy * Int(ls.y) + ly), UInt64(gz * Int(ls.z) + lz),
                ]
                inv.lindex = UInt64((lz * Int(ls.y) + ly) * Int(ls.x) + lx)
                invs.append(inv)
              }
            }
          }
          while invs.contains(where: { !$0.finished }) {
            var atBarrier = 0
            var done = 0
            for inv in invs where !inv.finished {
              switch try run(inv, &inv.frame, barriers: true) {
              case .done: inv.finished = true
              case .barrier: atBarrier += 1
              }
            }
            for inv in invs where inv.finished { done += 1 }
            if atBarrier > 0 && done > 0 && done < invs.count {
              // Some invocations ended while others wait at a barrier.
              throw InterpError(description: "a barrier reached by only part of the workgroup")
            }
          }
        }
      }
    }
  }

  // MARK: values

  private func lanes(_ t: IRType) -> Int { t.lanes }

  private func tagged(_ tag: UInt64, _ base: Int, _ off: UInt64) -> UInt64 { tag << 60 | UInt64(base) << 32 | (off & 0xffff_ffff) }

  private func get(_ f: Function, _ fr: Frame, _ v: ValueID) -> [UInt64] {
    switch f.values[v].kind {
    case .inst, .param: return fr.vals[v]
    case .constant(let b): return [b]
    case .constVec(let es): return es.map { f.constantBits($0) ?? 0 }
    case .undef: return [UInt64](repeating: 0, count: f.values[v].type.lanes)
    case .global(let g): return [tagged(m.globals[g].space == .workgroup ? 3 : 4, g, 0)]
    case .resource(let s, let b): return [tagged(1, s << 8 | b, 0)]
    case .pushConstants: return [tagged(2, 0, 0)]
    }
  }

  // MARK: memory

  private func read(_ inv: Invocation, _ ptr: UInt64, _ n: Int) throws -> UInt64 {
    let tag = ptr >> 60
    let base = Int((ptr >> 32) & 0x0fff_ffff)
    let off = Int(ptr & 0xffff_ffff)
    var bytes: [UInt8]
    switch tag {
    case 1: bytes = storage[base] ?? []
    case 2: bytes = push
    case 3: bytes = shared[base]
    case 4: bytes = inv.priv[base]
    case 5: bytes = inv.local[base]
    default: throw InterpError(description: "bad pointer \(ptr)")
    }
    guard off + n <= bytes.count else { throw InterpError(description: "read of \(n) bytes at \(off) outside \(bytes.count)") }
    var v: UInt64 = 0
    for k in 0..<n { v |= UInt64(bytes[off + k]) << UInt64(8 * k) }
    return v
  }

  private func write(_ inv: Invocation, _ ptr: UInt64, _ n: Int, _ v: UInt64) throws {
    let tag = ptr >> 60
    let base = Int((ptr >> 32) & 0x0fff_ffff)
    let off = Int(ptr & 0xffff_ffff)
    func put(_ b: inout [UInt8]) throws {
      guard off + n <= b.count else { throw InterpError(description: "write of \(n) bytes at \(off) outside \(b.count)") }
      for k in 0..<n { b[off + k] = UInt8(truncatingIfNeeded: v >> UInt64(8 * k)) }
    }
    switch tag {
    case 1:
      var b = storage[base] ?? []
      try put(&b)
      storage[base] = b
    case 3: try put(&shared[base])
    case 4: try put(&inv.priv[base])
    case 5: try put(&inv.local[base])
    default: throw InterpError(description: "store to bad pointer \(ptr)")
    }
  }

  private func bytes(_ t: IRType) -> Int { max(1, t.element.totalBits / 8) }

  // MARK: execution

  private func run(_ inv: Invocation, _ fr: inout Frame, barriers: Bool) throws -> Outcome {
    let f = m.functions[fr.fn]
    while true {
      let blk = f.blocks[fr.block]
      if fr.pos == 0 {
        // Phis read their values on entry, together.
        var phiVals: [(ValueID, [UInt64])] = []
        for id in blk.insts where f.insts[id].op == .phi {
          let i = f.insts[id]
          guard let k = i.blocks.firstIndex(of: fr.prev) else {
            throw InterpError(description: "phi without an incoming value for bb\(fr.prev)")
          }
          phiVals.append((i.result, get(f, fr, i.args[k])))
        }
        for (r, v) in phiVals { fr.vals[r] = v }
      }
      while fr.pos < blk.insts.count {
        let i = f.insts[blk.insts[fr.pos]]
        fr.pos += 1
        if i.op == .phi { continue }
        steps += 1
        if steps > 50_000_000 { throw InterpError(description: "step limit") }
        let a = i.args.map { get(f, fr, $0) }
        switch i.op {
        case .br:
          fr.prev = fr.block
          fr.block = i.blocks[0]
          fr.pos = 0
        case .condbr:
          fr.prev = fr.block
          fr.block = a[0][0] != 0 ? i.blocks[0] : i.blocks[1]
          fr.pos = 0
        case .switch_:
          fr.prev = fr.block
          var target = i.blocks[0]
          for (k, c) in i.payload.enumerated() where c == a[0][0] { target = i.blocks[k + 1]; break }
          fr.block = target
          fr.pos = 0
        case .ret:
          return .done(a.first ?? [])
        case .unreachable:
          throw InterpError(description: "reached unreachable")
        case .barrier:
          guard barriers else { throw InterpError(description: "a barrier in a called function") }
          return .barrier
        case .membar: break
        case .alloca:
          inv.local.append([UInt8](repeating: 0, count: i.imm))
          fr.vals[i.result] = [tagged(5, inv.local.count - 1, 0)]
        case .ptradd:
          fr.vals[i.result] = [a[0][0] & ~0xffff_ffff | ((a[0][0] &+ a[1][0]) & 0xffff_ffff)]
        case .load:
          let n = bytes(i.type)
          var out: [UInt64] = []
          for k in 0..<i.type.lanes { out.append(try read(inv, a[0][0] &+ UInt64(k * n), n)) }
          fr.vals[i.result] = out
        case .store:
          let t = f.values[i.args[1]].type
          let n = bytes(t)
          for k in 0..<t.lanes { try write(inv, a[0][0] &+ UInt64(k * n), n, a[1][k]) }
        case .atomic:
          let n = bytes(i.type == .void ? f.values[i.args[1]].type : i.type)
          let old = try read(inv, a[0][0], n)
          let w = n * 8
          func sext(_ v: UInt64) -> Int64 { w >= 64 ? Int64(bitPattern: v) : Int64(bitPattern: v << UInt64(64 - w)) >> Int64(64 - w) }
          var new = old
          switch i.imm {
          case AtomicKind.load: break
          case AtomicKind.store, AtomicKind.xchg: new = a[1][0]
          case AtomicKind.add: new = old &+ a[1][0]
          case AtomicKind.sub: new = old &- a[1][0]
          case AtomicKind.and: new = old & a[1][0]
          case AtomicKind.or: new = old | a[1][0]
          case AtomicKind.xor: new = old ^ a[1][0]
          case AtomicKind.smin: new = sext(old) <= sext(a[1][0]) ? old : a[1][0]
          case AtomicKind.smax: new = sext(old) >= sext(a[1][0]) ? old : a[1][0]
          case AtomicKind.umin: new = min(old, a[1][0])
          case AtomicKind.umax: new = max(old, a[1][0])
          default: new = old == a[1][0] ? a[2][0] : old  // cmpxchg: (cmp, new)
          }
          if w < 64 { new &= (1 << UInt64(w)) - 1 }
          if i.imm != AtomicKind.load { try write(inv, a[0][0], n, new) }
          if i.result >= 0 { fr.vals[i.result] = [old] }
        case .builtin:
          let src: [UInt64]
          switch i.imm {
          case IRBuiltin.numWorkgroups: src = inv.nwg
          case IRBuiltin.workgroupId: src = inv.wid
          case IRBuiltin.localInvocationId: src = inv.lid
          case IRBuiltin.globalInvocationId: src = inv.gid
          case IRBuiltin.localInvocationIndex: src = [inv.lindex]
          case IRBuiltin.vertexIndex: src = [vertexIndex]
          case IRBuiltin.instanceIndex: src = [instanceIndex]
          case IRBuiltin.fragCoord: src = fragCoord
          case IRBuiltin.subgroupSize: src = [1]
          case IRBuiltin.numSubgroups: src = [UInt64(m.localSize.x * m.localSize.y * m.localSize.z)]
          default: src = [0]
          }
          fr.vals[i.result] = i.imm2 >= 0 ? [src[i.imm2]] : src
        case .call:
          let callee = m.functions[i.imm]
          var cf = Frame(fn: i.imm, vals: [[UInt64]](repeating: [], count: callee.values.count))
          for (k, v) in a.enumerated() { cf.vals[k] = v }
          let r = try run(inv, &cf, barriers: false)
          if case .done(let v) = r, i.result >= 0 { fr.vals[i.result] = v }
        case .stageIn:
          let v = stageInputs[i.imm] ?? []
          fr.vals[i.result] = i.imm2 >= 0 ? [v[i.imm2]] : v
        case .stageOut:
          if i.imm2 >= 0 {
            var v = stageOutputs[i.imm] ?? []
            while v.count <= i.imm2 { v.append(0) }
            v[i.imm2] = a[0][0]
            stageOutputs[i.imm] = v
          } else {
            stageOutputs[i.imm] = a[0]
          }
        case .tex:
          guard let model = texelModel else { throw InterpError(description: "a texel access, and no texel model") }
          fr.vals[i.result] = [model(a[0][0], a[1][0], a.dropFirst(2).map { $0[0] }, i.imm2)]
        case .extract: fr.vals[i.result] = [a[0][i.imm]]
        case .insert:
          var v = a[0]
          v[i.imm] = a[1][0]
          fr.vals[i.result] = v
        case .vecbuild: fr.vals[i.result] = a.map { $0[0] }
        case .shuffle:
          let both = a[0] + a[1]
          fr.vals[i.result] = i.payload.map { both[Int($0)] }
        case .arraylen:
          let base = Int((a[0][0] >> 32) & 0x0fff_ffff)
          fr.vals[i.result] = [UInt64(((storage[base]?.count ?? 0) - i.imm) / i.imm2)]
        default:
          fr.vals[i.result] = try elementwise(f, i, a)
        }
        if i.op.isTerminator { break }
      }
    }
  }

  // MARK: arithmetic

  private func elementwise(_ f: Function, _ i: Inst, _ a: [[UInt64]]) throws -> [UInt64] {
    let n = i.type.lanes
    var out: [UInt64] = []
    let kinds = i.args.map { f.values[$0].type.scalarKind ?? .i64 }
    for k in 0..<n {
      var v: [UInt64] = []
      for x in a { v.append(x.count == 1 ? x[0] : x[k]) }
      out.append(try scalarOp(i, kinds, v))
    }
    return out
  }

  private func scalarOp(_ i: Inst, _ kinds: [Scalar], _ v: [UInt64]) throws -> UInt64 {
    let rk = i.type.scalarKind ?? .i64
    let w = kinds.first?.bits ?? rk.bits
    func mask(_ x: UInt64, _ bits: Int) -> UInt64 { bits >= 64 ? x : x & ((1 << UInt64(bits)) - 1) }
    func s(_ x: UInt64) -> Int64 { w >= 64 ? Int64(bitPattern: x) : Int64(bitPattern: x << UInt64(64 - w)) >> Int64(64 - w) }
    func fl(_ x: UInt64) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: x)) }
    func fb(_ x: Float) -> UInt64 { UInt64(x.bitPattern) }
    func db(_ x: UInt64) -> Double { Double(bitPattern: x) }
    let isD = kinds.first == .f64 || rk == .f64
    func fop(_ ff: (Float) -> Float, _ dd: (Double) -> Double) -> UInt64 {
      isD ? dd(db(v[0])).bitPattern : fb(ff(fl(v[0])))
    }
    func fop2(_ ff: (Float, Float) -> Float, _ dd: (Double, Double) -> Double) -> UInt64 {
      isD ? dd(db(v[0]), db(v[1])).bitPattern : fb(ff(fl(v[0]), fl(v[1])))
    }
    switch i.op {
    case .iadd: return mask(v[0] &+ v[1], w)
    case .isub: return mask(v[0] &- v[1], w)
    case .imul: return mask(v[0] &* v[1], w)
    case .udiv: return v[1] == 0 ? 0 : v[0] / v[1]
    case .sdiv: return v[1] == 0 ? 0 : mask(UInt64(bitPattern: s(v[0]).dividedReportingOverflow(by: s(v[1])).partialValue), w)
    case .urem: return v[1] == 0 ? 0 : v[0] % v[1]
    case .srem: return v[1] == 0 ? 0 : mask(UInt64(bitPattern: s(v[0]).remainderReportingOverflow(dividingBy: s(v[1])).partialValue), w)
    case .ineg: return mask(0 &- v[0], w)
    case .and: return v[0] & v[1]
    case .or: return v[0] | v[1]
    case .xor: return v[0] ^ v[1]
    case .not: return kinds[0] == .bool ? (v[0] ^ 1) : mask(~v[0], w)
    case .shl: return mask(v[0] << (v[1] & UInt64(w - 1)), w)
    case .lshr: return v[0] >> (v[1] & UInt64(w - 1))
    case .ashr: return mask(UInt64(bitPattern: s(v[0]) >> Int64(v[1] & UInt64(w - 1))), w)
    case .smin: return s(v[0]) <= s(v[1]) ? v[0] : v[1]
    case .smax: return s(v[0]) >= s(v[1]) ? v[0] : v[1]
    case .umin: return min(v[0], v[1])
    case .umax: return max(v[0], v[1])
    case .fadd: return fop2(+, +)
    case .fsub: return fop2(-, -)
    case .fmul: return fop2(*, *)
    case .fdiv: return fop2(/, /)
    case .fmin: return fop2({ $0.isNaN ? $1 : $1.isNaN ? $0 : Swift.min($0, $1) }, { $0.isNaN ? $1 : $1.isNaN ? $0 : Swift.min($0, $1) })
    case .fmax: return fop2({ $0.isNaN ? $1 : $1.isNaN ? $0 : Swift.max($0, $1) }, { $0.isNaN ? $1 : $1.isNaN ? $0 : Swift.max($0, $1) })
    case .fneg: return fop({ -$0 }, { -$0 })
    case .fabs: return fop({ abs($0) }, { abs($0) })
    case .fma:
      return isD ? db(v[2]).addingProduct(db(v[0]), db(v[1])).bitPattern : fb(fl(v[2]).addingProduct(fl(v[0]), fl(v[1])))
    case .ffloor: return fop({ $0.rounded(.down) }, { $0.rounded(.down) })
    case .fceil: return fop({ $0.rounded(.up) }, { $0.rounded(.up) })
    case .ftrunc: return fop({ $0.rounded(.towardZero) }, { $0.rounded(.towardZero) })
    case .fround: return fop({ $0.rounded(.toNearestOrEven) }, { $0.rounded(.toNearestOrEven) })
    case .fsqrt: return fop({ $0.squareRoot() }, { $0.squareRoot() })
    case .frsq: return fop({ 1 / $0.squareRoot() }, { 1 / $0.squareRoot() })
    case .fexp2: return fop({ exp2($0) }, { exp2($0) })
    case .flog2: return fop({ log2($0) }, { log2($0) })
    case .fsin: return fop({ sin($0) }, { sin($0) })
    case .fcos: return fop({ cos($0) }, { cos($0) })
    case .icmp:
      let (a, b) = (v[0], v[1])
      let r: Bool
      switch i.imm {
      case ICmpPred.eq: r = a == b
      case ICmpPred.ne: r = a != b
      case ICmpPred.ult: r = a < b
      case ICmpPred.ule: r = a <= b
      case ICmpPred.ugt: r = a > b
      case ICmpPred.uge: r = a >= b
      case ICmpPred.slt: r = s(a) < s(b)
      case ICmpPred.sle: r = s(a) <= s(b)
      case ICmpPred.sgt: r = s(a) > s(b)
      default: r = s(a) >= s(b)
      }
      return r ? 1 : 0
    case .fcmp:
      let x = isD || kinds[0] == .f64 ? db(v[0]) : Double(fl(v[0]))
      let y = isD || kinds[0] == .f64 ? db(v[1]) : Double(fl(v[1]))
      let un = x.isNaN || y.isNaN
      let r: Bool
      switch i.imm {
      case FCmpPred.oeq: r = !un && x == y
      case FCmpPred.one: r = !un && x != y
      case FCmpPred.olt: r = !un && x < y
      case FCmpPred.ole: r = !un && x <= y
      case FCmpPred.ogt: r = !un && x > y
      case FCmpPred.oge: r = !un && x >= y
      case FCmpPred.ueq: r = un || x == y
      case FCmpPred.une: r = un || x != y
      case FCmpPred.ult: r = un || x < y
      case FCmpPred.ule: r = un || x <= y
      case FCmpPred.ugt: r = un || x > y
      case FCmpPred.uge: r = un || x >= y
      case FCmpPred.ord: r = !un
      default: r = un
      }
      return r ? 1 : 0
    case .select: return v[0] != 0 ? v[1] : v[2]
    case .zext: return v[0]
    case .sext: return mask(UInt64(bitPattern: s(v[0])), rk.bits)
    case .trunc: return mask(v[0], rk.bits)
    case .bitcast, .ptrtoint, .inttoptr: return v[0]
    case .sitofp: return rk == .f64 ? Double(s(v[0])).bitPattern : fb(Float(s(v[0])))
    case .uitofp: return rk == .f64 ? Double(v[0]).bitPattern : fb(Float(v[0]))
    case .fptosi:
      let d = kinds[0] == .f64 ? db(v[0]) : Double(fl(v[0]))
      return mask(UInt64(bitPattern: Int64(d)), rk.bits)
    case .fptoui:
      let d = kinds[0] == .f64 ? db(v[0]) : Double(fl(v[0]))
      return UInt64(d)
    case .fpext: return Double(fl(v[0])).bitPattern
    case .fptrunc: return fb(Float(db(v[0])))
    default: throw InterpError(description: "the interpreter doesn't run \(i.op.rawValue)")
    }
  }
}

// MARK: buffers

public func bytes(_ words: [UInt32]) -> [UInt8] {
  var b: [UInt8] = []
  for w in words { for k in 0..<4 { b.append(UInt8(truncatingIfNeeded: w >> UInt32(8 * k))) } }
  return b
}

public func bytes(_ floats: [Float]) -> [UInt8] { bytes(floats.map { $0.bitPattern }) }

public func words(_ b: [UInt8]) -> [UInt32] {
  var w: [UInt32] = []
  var k = 0
  while k + 3 < b.count {
    w.append(UInt32(b[k]) | UInt32(b[k + 1]) << 8 | UInt32(b[k + 2]) << 16 | UInt32(b[k + 3]) << 24)
    k += 4
  }
  return w
}

public func floats(_ b: [UInt8]) -> [Float] { words(b).map { Float(bitPattern: $0) } }
