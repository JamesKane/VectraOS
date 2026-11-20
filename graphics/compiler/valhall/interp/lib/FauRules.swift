// SPDX-License-Identifier: BSD-3-Clause

// FAU access limits (valhall 10 §10.5.6), checked on every instruction as
// the validator's second line.

extension Executor {
  func isWide(_ ins: Instr, _ i: Int) -> Bool {
    switch ins.op {
    case .load, .store, .atom, .atom1, .atom1Return, .atomReturn, .acmpxchg: return i == 0
    case .shadd, .segAdd: return i < 2
    case .iadd, .isub, .imul: return (ins.dataType == .u64 || ins.dataType == .s64) && i < 2
    case .shift: return (ins.dataType == .u64 || ins.dataType == .s64) && i < 3
    default: return false
    }
  }

  func isMessage(_ op: Opcode) -> Bool {
    switch op {
    case .load, .store, .atom, .atom1, .atom1Return, .atomReturn, .acmpxchg, .barrier: true
    default: false
    }
  }

  /// An ALU instruction reads at most two distinct 32-bit words from FAU and small constants (the zero
  /// constant is free), all user words from one 64-bit slot, and not a user word with a special entry. A
  /// message instruction must not read `warp_id` or a page 3 special.
  func checkFau(_ ins: Instr) throws {
    let bytes = [ins.s0, ins.s1, ins.s2, ins.s3]
    var words = Set<UInt64>()
    var slots = Set<Int>()
    var user = false
    var special = false
    let pg = page(ins)
    for (i, b) in bytes.enumerated() {
      let wide = isWide(ins, i)
      switch b >> 5 {
      case 0b100, 0b101:
        user = true
        let slot = pg * 32 + Int((b >> 1) & 31)
        slots.insert(slot)
        if wide {
          words.insert(UInt64(slot * 2))
          words.insert(UInt64(slot * 2 + 1))
        } else {
          words.insert(UInt64(slot * 2 + Int(b & 1)))
        }
      case 0b110:
        if b & 31 != 0 { words.insert(0x1_0000_0000 | UInt64(b & 31)) }
      case 0b111:
        special = true
        let entry = Int((b >> 1) & 15)
        if isMessage(ins.op) && (pg == 3 || (pg == 0 && entry == 2)) {
          throw Fault.invalid("a message instruction reads warp_id or a page 3 special entry (10 §10.5.6)")
        }
        let base = 0x2_0000_0000 | UInt64(pg * 64 + entry * 2)
        if wide {
          words.insert(base)
          words.insert(base + 1)
        } else {
          words.insert(base + UInt64(b & 1))
        }
      default: break
      }
    }
    if isMessage(ins.op) { return }
    if words.count > 2 { throw Fault.invalid("an ALU instruction reads \(words.count) FAU words, at most 2 (10 §10.5.6)") }
    if slots.count > 1 { throw Fault.invalid("an ALU instruction reads two FAU slots (10 §10.5.6)") }
    if user && special { throw Fault.invalid("an ALU instruction combines a user FAU word with a special entry (10 §10.5.6)") }
  }
}
