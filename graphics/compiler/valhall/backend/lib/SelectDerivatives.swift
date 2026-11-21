// SPDX-License-Identifier: BSD-3-Clause

// Derivatives across a fragment quad (valhall 13.10.2): there is no derivative instruction, the reference builds one from
// `CLPER.subgroup4` and a subtraction. A quad is four consecutive lanes, bit 0 the column and bit 1 the row (13.10.1).
//
//  - coarse d/dx: lane 1's value less lane 0's (two `CLPER` with the lane operation `none` and selectors 1 and 0), the same
//    in all four lanes; coarse d/dy uses lane 2;
//  - fine d/dx: the neighbour's value (`CLPER` with `xor` and selector 1) less this lane's, its sign flipped in the odd lanes
//    by exclusive-oring the lane id shifted into the sign position; fine d/dy uses selector 2 and bit 1.
// The selector is the small constant 0x03020100, whose bytes 0, 1 and 2 are 0, 1 and 2 (10.5.2): the instruction's lane field
// picks the byte. The permute needs the helper lanes of the quad alive (13.10.3), which a fragment shader's `discard`
// placement guarantees here (the shader carries no `discard` flow, so helpers live to the end).

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  /// `CLPER.subgroup4` of `v`: the byte `byte` (0 to 3) of 0x03020100 picks the lane (or the exclusive-or mask).
  mutating func quadPermute(_ v: Opd, byte: Int, xor: Bool) -> Opd {
    let d = newReg()
    alu("CLPER", "", dst: .reg(d, 0), v, .const(8), set: [("subgroup", 1), ("lane_op", xor ? 1 : 0), ("wd1", 4 + byte)])
    return .reg(d, 0)
  }

  mutating func selectDeriv(_ i: Inst) {
    let v = reg32(i.args[0])
    let y = i.imm & 1 != 0
    let fine = i.imm & 2 != 0
    let d = def32(i)
    if !fine {
      let left = quadPermute(v, byte: 0, xor: false)
      let right = quadPermute(v, byte: y ? 2 : 1, xor: false)
      alu("FADD", "f32", dst: d, right, left, set: [("neg1", 1)])
      return
    }
    let neighbour = quadPermute(v, byte: y ? 2 : 1, xor: true)
    let diff = newReg()
    alu("FADD", "f32", dst: .reg(diff, 0), neighbour, v, set: [("neg1", 1)])
    // The odd lane of the pair has the neighbour minus itself backwards: flip the sign with the lane id's bit.
    mf.usesLaneID = true
    let lane = newReg()
    alu("MOV", "i32", dst: .reg(lane, 0), .special(3, 1, 0))
    var bit: Opd = .reg(lane, 0)
    var shift = 31
    if y {
      let t = newReg()
      alu("AND_IMM", "i32", dst: .reg(t, 0), .reg(lane, 0), set: [("imm", 2)])
      bit = .reg(t, 0)
      shift = 30
    }
    guard let (amt, ln) = shiftAmount(shift) else { return }
    alu("LSHIFT_XOR", "i32", dst: d, bit, amt, .reg(diff, 0), set: [("wd1", ln)])
  }
}
