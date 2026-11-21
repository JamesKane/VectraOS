// SPDX-License-Identifier: BSD-3-Clause

// Instruction selection: the scalarised IR to Valhall instructions over
// virtual registers (valhall 11a, 11b, 11c, 12a, 13, and the ABI of 14).
//
// Representation choices (all of them the compiler's, valhall 15 leaves them
// to it):
//  - i32 and f32 are one register; bool is one register holding 0 or
//    0xFFFFFFFF (the compare results of 11b.1.6 `m1`, and the branch
//    condition of 13.4.1); i64 and a global pointer are an even register pair.
//  - A pointer into a buffer, workgroup memory, the stack or the push
//    constants is not a value in a register: it is a base the FAU names, a
//    constant offset and at most one run-time offset (`PtrVal`), and a load
//    or store folds the constant into its 16-bit offset field (12a.3).
//  - Push constants and the numbers of workgroups are FAU words, read in
//    place by the instructions that use them (14.7.3).

import ShaderCompiler
import ValhallISA

/// A pointer the compiler follows at compile time.
struct PtrVal {
  enum Base {
    /// A buffer: the 64-bit address in FAU slot `n`.
    case binding(Int)
    /// Workgroup memory: `workgroup_local_pointer`.
    case workgroup
    /// The thread's stack: `thread_local_pointer`.
    case stack
    /// The push constants (FAU words).
    case push
    /// A run-time 64-bit address in a register pair.
    case reg(Int)
  }
  var base: Base
  var offset: Int
  /// A run-time byte offset (a 32-bit register, used as `.w0` of a pair), shifted left by `shift`; -1: none.
  var dyn = -1
  var shift = 0
}

enum Loc {
  case none
  /// A virtual register (the value is all of it, or the low word of a pair that is truncated).
  case reg(Int)
  /// A constant: its bits.
  case const(UInt64)
  /// A 32-bit FAU word: its index from the start of the block.
  case fau(Int)
  case ptr(PtrVal)
}

struct Selector {
  let f: Function
  let m: IRModule
  let opts: BackendOptions
  var mf = MFunc()
  var ops = OpCache()
  var layout: [Int] = []
  /// IR block to MIR block.
  var blockOf: [Int] = []
  var cur = 0
  var loc: [Loc] = []
  var uses: [Int] = []
  /// An IR value (an `imul` or `shl` by a power of two) whose every use is the offset of a `ptradd`: the operand and the shift.
  var foldedShift: [Int] = []
  var foldedBase: [ValueID] = []
  /// A value known to be a zero-extended 32-bit value (its high word is zero).
  var zeroHigh: [Bool] = []
  var fau = FauLayout()
  var wgOffset: [Int] = []
  var privOffset: [Int] = []
  var workgroupBytes = 0
  var maxPushWord = -1
  /// Virtual registers of the preloaded registers, by number r48 to r63.
  var preloadReg = [Int](repeating: -1, count: 16)
  /// The builtin components made in the prologue: [builtin][component].
  var builtinReg: [[Int]] = [[Int]](repeating: [-1, -1, -1], count: 9)
  var fused: [Bool] = []
  var usedBuiltins: [Bool] = []
  var usedLid = [false, false, false]

  init(_ m: IRModule, _ f: Function, _ opts: BackendOptions) {
    self.m = m
    self.f = f
    self.opts = opts
  }

  // MARK: emission

  mutating func op(_ mnemonic: String, _ variant: String = "") -> Instruction {
    Instruction(op: ops.id(mnemonic, variant, arch: opts.arch))
  }

  mutating func add(_ i: MInst) { mf.blocks[cur].insts.append(i) }

  /// An ALU instruction.
  @discardableResult
  mutating func alu(
    _ mn: String, _ variant: String = "", dst: Opd = .none, _ s0: Opd = .none, _ s1: Opd = .none, _ s2: Opd = .none,
    _ s3: Opd = .none, set: [(String, Int)] = [], named: [(String, String)] = []
  ) -> MInst {
    var i = op(mn, variant)
    for (k, v) in set { i.put(k, v) }
    for (k, v) in named { i.put(k, v) }
    var m = MInst(i, .alu)
    m.dst = dst
    m.src = [s0, s1, s2, s3]
    add(m)
    return m
  }

  /// A message instruction (memory), with its staging blocks.
  mutating func message(
    _ mn: String, _ variant: String, address: Opd, offset: Int, read: Opd = .none, write: Opd = .none, memory: Int,
    set: [(String, Int)] = [], named: [(String, String)] = []
  ) {
    var i = op(mn, variant)
    if i.def.fieldIndex("offset") >= 0 { i.put("offset", offset) }
    for (k, v) in set { i.put(k, v) }
    for (k, v) in named { i.put(k, v) }
    var m = MInst(i, .message)
    m.src[0] = address
    m.stageRead = read
    m.stageWrite = write
    m.memory = memory
    add(m)
  }

  mutating func newReg(_ size: Int = 1) -> Int { mf.newReg(size: size) }

  // MARK: constants and operands

  /// The index of a 32-bit value in the small-constant table (10.5.2), when it has one (index 21 is not used).
  func smallConstant(_ bits: UInt32) -> Int? {
    guard let i = SmallConstants.index(of: bits), i != 21 else { return nil }
    return i
  }

  /// A 32-bit constant in a register of its own.
  mutating func materialize(_ bits: UInt32) -> Opd {
    let r = newReg()
    alu("IADD_IMM", "i32", dst: .reg(r, 0), .const(0), set: [("imm", Int(bits))])
    return .reg(r, 0)
  }

  /// Source operand for a 32-bit value (a register, a FAU word, a constant).
  mutating func opd(_ v: ValueID) -> Opd {
    switch loc[v] {
    case .reg(let r): return .reg(r, 0)
    case .const(let bits):
      let b = UInt32(truncatingIfNeeded: bits)
      if let c = smallConstant(b) { return .const(c) }
      return materialize(b)
    case .fau(let w): return .user(w / 2, w % 2)
    default: return .const(0)
    }
  }

  /// A 32-bit value in a register (a staging operand is always one: 15.3.3).
  mutating func reg32(_ v: ValueID) -> Opd {
    if case .reg(let r) = loc[v] { return .reg(r, 0) }
    let o = opd(v)
    return copyToReg(o)
  }

  mutating func copyToReg(_ o: Opd) -> Opd {
    if case .reg = o { return o }
    let r = newReg()
    alu("MOV", "i32", dst: .reg(r, 0), o)
    return .reg(r, 0)
  }

  /// A 64-bit source for an i64 value or a global pointer: a pair, a FAU slot, or a small constant (zero extended).
  mutating func opd64(_ v: ValueID) -> Opd {
    switch loc[v] {
    case .reg(let r): return .reg(r, 0)
    case .const(let bits):
      if bits >> 32 == 0, let c = smallConstant(UInt32(bits)) { return .const(c) }
      return pairConstant(bits)
    default: return .const(0)
    }
  }

  mutating func pairConstant(_ bits: UInt64) -> Opd {
    let r = newReg(2)
    alu("IADD_IMM", "i32", dst: .reg(r, 0), .const(0), set: [("imm", Int(bits & 0xFFFF_FFFF))])
    alu("IADD_IMM", "i32", dst: .reg(r, 1), .const(0), set: [("imm", Int(bits >> 32))])
    return .reg(r, 0)
  }

  /// The low and high words of a 64-bit value as 32-bit operands.
  mutating func words64(_ v: ValueID) -> (Opd, Opd) {
    switch loc[v] {
    case .reg(let r): return (.reg(r, 0), .reg(r, 1))
    case .const(let bits):
      let lo = UInt32(truncatingIfNeeded: bits)
      let hi = UInt32(truncatingIfNeeded: bits >> 32)
      let l: Opd = smallConstant(lo).map { Opd.const($0) } ?? materialize(lo)
      let h: Opd = smallConstant(hi).map { Opd.const($0) } ?? materialize(hi)
      return (l, h)
    default: return (.const(0), .const(0))
    }
  }

  /// Shift amount operand for a shift by `n` bits of the 32-bit shift family: a small constant holding `n` in a byte
  /// (constants 8 to 15 hold 0 to 31 as bytes), and the lane field that picks the byte.
  func shiftAmount(_ n: Int) -> (Opd, Int)? {
    if n < 0 || n > 31 { return nil }
    return (.const(8 + n / 4), 4 + n % 4)
  }

  // MARK: pointer values

  mutating func ptr(_ v: ValueID) -> PtrVal {
    switch loc[v] {
    case .ptr(let p): return p
    case .reg(let r): return PtrVal(base: .reg(r), offset: 0)
    default: return PtrVal(base: .stack, offset: 0)
    }
  }
}
