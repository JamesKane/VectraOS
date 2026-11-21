// SPDX-License-Identifier: BSD-3-Clause

// Legalisation: what valhall 10.5.6 and 15.6 allow an instruction to read from
// the FAU and the small constants. Whatever an instruction may not read is
// moved into a register first (15.6.3).

import ValhallISA

struct FAUUse {
  /// Distinct 32-bit words: user words by `slot * 2 + word`, special by `1000 + entry * 2 + word`, constants
  /// (not zero) by `2000 + index`.
  var words: [Int] = []
  var users: [Int] = []
  var specials: [Int] = []
  var pages: [Int] = []

  mutating func add(_ o: Opd, wide: Bool) {
    func word(_ k: Int) { if !words.contains(k) { words.append(k) } }
    func page(_ p: Int) { if !pages.contains(p) { pages.append(p) } }
    switch o {
    case .user(let slot, let w):
      if !users.contains(slot) { users.append(slot) }
      page(slot / 32)
      if wide {
        word(slot * 2)
        word(slot * 2 + 1)
      } else {
        word(slot * 2 + w)
      }
    case .special(let p, let e, let w):
      if !specials.contains(p * 16 + e) { specials.append(p * 16 + e) }
      page(p)
      if wide {
        word(1000 + e * 2)
        word(1000 + e * 2 + 1)
      } else {
        word(1000 + e * 2 + w)
      }
    case .const(let c):
      if c != 0 { word(2000 + c) }
    default: break
    }
  }

  func ok(message: Bool) -> Bool {
    if words.count > 2 || pages.count > 1 { return false }
    if message {
      if users.count > 1 || specials.count > 1 { return false }
      for s in specials where s / 16 == 3 || s == 2 { return false }
      return true
    }
    return users.count + specials.count <= 1
  }
}

extension MFunc {
  /// Fit every instruction's FAU and constant sources to the rules; new registers come from `newReg`.
  mutating func legalize() {
    for b in 0..<blocks.count {
      var out: [MInst] = []
      for var m in blocks[b].insts {
        let d = m.inst.def
        var use = FAUUse()
        let message = d.unit == .msg
        var n = 0
        while n < 4 {
          let o = m.src[n]
          if o != .none, case let fi = d.fieldIndex(role: .source(n)), fi >= 0 {
            let wide = d.fields[fi].kind != .src32
            var trial = use
            trial.add(o, wide: wide)
            if trial.ok(message: message) {
              use = trial
            } else if o.isFAU || { if case .const = o { return true }; return false }() {
              // Move it into a register.
              if case .const = o, !wide {
                // A constant: keep it in the budget by loading it as a register copy.
              }
              let r = newReg(size: wide ? 2 : 1)
              if wide {
                out.append(movFrom(o, to: .reg(r, 0), word: 0))
                out.append(movFrom(o, to: .reg(r, 1), word: 1))
              } else {
                out.append(movFrom(o, to: .reg(r, 0), word: -1))
              }
              m.src[n] = .reg(r, 0)
            }
          }
          n += 1
        }
        out.append(m)
      }
      blocks[b].insts = out
    }
  }

  func movFrom(_ o: Opd, to d: Opd, word: Int) -> MInst {
    var src = o
    switch o {
    case .user(let s, let w): src = word < 0 ? .user(s, w) : .user(s, word)
    case .special(let p, let e, let w): src = word < 0 ? .special(p, e, w) : .special(p, e, word)
    case .const: if word == 1 { src = .const(0) }
    default: break
    }
    var i = Instruction("MOV", "i32")!
    i.fauPage = 0
    var m = MInst(i, .alu)
    m.dst = d
    m.src[0] = src
    return m
  }
}
