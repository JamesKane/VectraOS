// SPDX-License-Identifier: BSD-3-Clause

// The backend's own form between the IR and the words: Valhall instructions
// (`ValhallISA.Instruction`, with every modifier set) whose registers are
// still virtual. Selection makes it, legalisation fits it to the FAU rules,
// allocation gives each virtual register its place, the scheduler adds the
// waits, and emission fills the registers in.

import ValhallISA

/// A virtual register: one or more consecutive 32-bit registers.
struct VRegInfo {
  /// Registers it covers: 1 for a 32-bit value, 2 for a 64-bit pair, up to 4 for a staging block.
  var size: Int
  /// 2 where it must start at an even register (a pair, a block of two or more, a lone register read as `.w0` of a pair).
  var align: Int
  /// The physical register a preload fixes it to, or -1.
  var fixed: Int
  /// Made by the spiller: it has to stay in a register.
  var noSpill: Bool
}

/// An operand of a source field or a register field.
enum Opd: Equatable {
  case none
  /// Register `offset` of a virtual register (0 for all of it, 1 for the high word of a pair).
  case reg(Int, Int)
  /// Word `word` of user FAU slot `slot` (0 to 127).
  case user(Int, Int)
  /// A special entry (valhall 10.5.3) of a page, word 0 or 1.
  case special(Int, Int, Int)
  /// A small constant, index 0 to 31 of 10.5.2.
  case const(Int)

  var isFAU: Bool {
    switch self {
    case .user, .special: return true
    default: return false
    }
  }
}

enum MKind {
  /// Anything that issues in order and signals nothing.
  case alu
  /// A message instruction: it has a slot, and its result is not there until the slot is waited on.
  case message
  /// A conditional or unconditional `BRANCH` to a block.
  case branch
  /// `BARRIER`.
  case barrier
  /// Every message in flight must have completed before the next instruction (a memory barrier).
  case fence
  /// The end of the shader on this path.
  case end
}

struct MInst {
  var inst: Instruction
  var kind: MKind
  /// The register field `dst` (an ALU instruction's destination).
  var dst: Opd = .none
  /// The source fields, by index.
  var src: [Opd] = [.none, .none, .none, .none]
  /// The staging block read, and the block written.
  var stageRead: Opd = .none
  var stageWrite: Opd = .none
  /// The block a branch goes to.
  var target = -1
  /// The memory access kind of a message: 1 load, 2 store or atomic.
  var memory = 0

  init(_ inst: Instruction, _ kind: MKind) {
    self.inst = inst
    self.kind = kind
  }

  /// The virtual registers the instruction reads.
  func reads(_ out: inout [Int]) {
    for s in src { if case .reg(let v, _) = s { out.append(v) } }
    if case .reg(let v, _) = stageRead { out.append(v) }
  }

  /// The virtual registers it writes.
  func writes(_ out: inout [Int]) {
    if case .reg(let v, _) = dst { out.append(v) }
    if case .reg(let v, _) = stageWrite { out.append(v) }
  }
}

struct MBlock {
  var insts: [MInst] = []
  /// The IR block it came from.
  var ir = -1
  /// The blocks control can go to next (for liveness and the join rules).
  var succs: [Int] = []
}

/// A machine function: the blocks in layout order, the virtual registers, and the stack.
struct MFunc {
  var blocks: [MBlock] = []
  var vregs: [VRegInfo] = []
  /// Bytes of stack the IR's allocas and private variables use, then the spill slots after them.
  var stackBytes = 0
  var spillSlots = 0
  /// Preload mask bits (bit n: r(48 + n)).
  var preload: UInt16 = 0
  var usesBarrier = false
  var usesWorkgroupMemory = false
  var usesLaneID = false

  mutating func newReg(size: Int = 1, align: Int = 1, fixed: Int = -1) -> Int {
    vregs.append(VRegInfo(size: size, align: size >= 2 ? 2 : align, fixed: fixed, noSpill: false))
    return vregs.count - 1
  }
}

// MARK: instruction construction

/// A cache of `(mnemonic, variant)` to definition index: the table's lookup scans every definition.
struct OpCache {
  var names: [String] = []
  var ids: [Int] = []

  mutating func id(_ mnemonic: String, _ variant: String, arch: Int) -> Int {
    let key = variant.isEmpty ? mnemonic : mnemonic + "." + variant
    var i = 0
    while i < names.count {
      if names[i] == key { return ids[i] }
      i += 1
    }
    let op = ISATable.shared.lookup(mnemonic: mnemonic, variant: variant, arch: arch) ?? 0
    names.append(key)
    ids.append(op)
    return op
  }
}

extension Instruction {
  /// Set a field by name; a bug in the backend when the instruction has none such.
  mutating func put(_ name: String, _ value: Int) {
    if !set(name, UInt64(bitPattern: Int64(value))) { fatalError("no field " + name) }
  }

  mutating func put(_ name: String, _ valueName: String) {
    if !set(name, named: valueName) { fatalError("no field " + name + " or value " + valueName) }
  }
}
