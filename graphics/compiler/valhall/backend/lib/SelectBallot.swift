// SPDX-License-Identifier: BSD-3-Clause

// The ballot (valhall 13.9.2, 13.9.4). The one place a ballot is made, so the open question of 13.9.4 (whether WMASK counts the
// lanes executing it or every lane launched) is one switch.

#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  /// The ballot of a bool in a register: bit `i` set when lane `i` is executing the instruction and its operand is true. By
  /// default one WMASK (13.9.3). With `ballotWithoutWMASK`, the operand's low bit is permuted in from each of the 16 lanes
  /// (CLPER of a constant lane, which gives zero for a lane that is not executing, 13.9.1.2) and shifted into place: right
  /// whichever lanes WMASK counts, for thirty-odd instructions more.
  mutating func ballot(_ x: Opd, into d: Int) {
    guard opts.ballotWithoutWMASK else {
      alu("WMASK", "", dst: .reg(d, 0), x)
      return
    }
    let bit = newReg()
    alu("AND_IMM", "i32", dst: .reg(bit, 0), x, set: [("imm", 1)])
    var acc: Opd = .const(0)
    for j in 0..<16 {
      let (amt, lane) = shiftAmount(j)!
      let got = newReg()
      alu("CLPER", "", dst: .reg(got, 0), .reg(bit, 0), amt, set: [("wd1", lane)])
      let next = j == 15 ? d : newReg()
      alu("LSHIFT_OR", "i32", dst: .reg(next, 0), .reg(got, 0), amt, acc, set: [("wd1", lane)])
      acc = .reg(next, 0)
    }
  }
}
