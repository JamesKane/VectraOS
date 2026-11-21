// SPDX-License-Identifier: BSD-3-Clause

// The vertex and fragment stages' built-ins beyond the position, the facing and the varyings (valhall 14.3.1, 14.4, 14.7.4):
//
//  vertex   - VertexIndex is r60, which already has the draw's first vertex or base vertex added (14.3.1); InstanceIndex is
//             r61 plus the base instance, which the driver keeps in the FAU (the reference writes zero to INSTANCE_OFFSET,
//             14.3.1); BaseVertex and BaseInstance are FAU words; DrawIndex is r62, which holds a value only when the
//             draw enables its register (`VertexShader.readsDrawIndex` says the shader needs it, 14.3.1);
//  fragment - SampleId is `(r61 >> 16) & 31` (the upper bits hold garbage, 14.4.2); SampleMask in is the low half of r61;
//             SamplePosition is the table `sample` names (14.7.2), indexed by the sample id, the 8.8 halves read as signed
//             (14.4.4 leaves the signedness open); HelperInvocation is a zero low half of r61 (14.4.2), or a lane demoted
//             since; PointCoord is LD_VAR_SPECIAL.v2 point (12c.5.4); PrimitiveId is r57 (14.4.1); Layer is the low byte
//             of the frame argument r62 (14.4.5, the driver writes it there).
//  outputs  - FragDepth is ZS_EMIT.z and SampleMask is ANDed into r60 before ATEST (12c.6.4), both in the fragment epilogue.

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
  mutating func selectInstanceIndex(_ i: Inst) throws(BackendError) {
    let r61 = preload(61)
    if isVertex && gfau.baseInstanceWord >= 0 {
      let w = gfau.baseInstanceWord
      alu("IADD", "u32", dst: def32(i), .reg(r61, 0), .user(w / 2, w % 2))
    } else {
      loc[i.result] = .reg(r61)
    }
  }

  /// The sample id into a register (14.4.2).
  mutating func sampleIdReg() -> Opd {
    let r61 = preload(61)
    let d = newReg()
    let mask = materialize(0x1F)
    if let (amt, lane) = shiftAmount(16) {
      alu("RSHIFT_AND", "i32", dst: .reg(d, 0), .reg(r61, 0), amt, mask, set: [("wd1", lane)])
    }
    return .reg(d, 0)
  }

  mutating func selectStageBuiltin(_ i: Inst) throws(BackendError) {
    let c = max(i.imm2, 0)
    switch i.imm {
    case IRBuiltin.baseVertex:
      guard gfau.baseVertexWord >= 0 else { throw BackendError.invalidIR("a base vertex with no FAU word") }
      loc[i.result] = .fau(gfau.baseVertexWord)
    case IRBuiltin.baseInstance:
      guard gfau.baseInstanceWord >= 0 else { throw BackendError.invalidIR("a base instance with no FAU word") }
      loc[i.result] = .fau(gfau.baseInstanceWord)
    case IRBuiltin.drawIndex:
      loc[i.result] = .reg(preload(62))
    case IRBuiltin.sampleId:
      loc[i.result] = .reg(sampleIdReg().regIndex)
    case IRBuiltin.sampleMaskIn:
      let r61 = preload(61)
      alu("AND_IMM", "i32", dst: def32(i), .reg(r61, 0), set: [("imm", 0xFFFF)])
    case IRBuiltin.primitiveId:
      loc[i.result] = .reg(preload(57))
    case IRBuiltin.layer:
      let r62 = preload(62)
      alu("AND_IMM", "i32", dst: def32(i), .reg(r62, 0), set: [("imm", 0xFF)])
    case IRBuiltin.helperInvocation:
      let r61 = preload(61)
      let t = newReg()
      alu("AND_IMM", "i32", dst: .reg(t, 0), .reg(r61, 0), set: [("imm", 0xFFFF)])
      if demotedReg >= 0 {
        let h = newReg()
        alu("ICMP_OR", "u32", dst: .reg(h, 0), .reg(t, 0), .const(0), .const(0), named: [("cmp", "eq"), ("rtype", "m1")])
        guard let (amt, lane) = shiftAmount(0) else { return }
        alu("LSHIFT_OR", "i32", dst: def32(i), .reg(h, 0), amt, .reg(demotedReg, 0), set: [("wd1", lane)])
      } else {
        alu("ICMP_OR", "u32", dst: def32(i), .reg(t, 0), .const(0), .const(0), named: [("cmp", "eq"), ("rtype", "m1")])
      }
    case IRBuiltin.pointCoord:
      let r = newReg(2)
      var inst = op("LD_VAR_SPECIAL")
      inst.put("name", "point")
      inst.put("fmt", "f32")
      inst.put("vsz", "v2")
      inst.put("spos", "center")
      var mi = MInst(inst, .message)
      mi.src[0] = .const(0)
      mi.stageWrite = .reg(r, 0)
      mi.hidden = true
      add(mi)
      loc[i.result] = .part(r, c)
    case IRBuiltin.samplePosition:
      // The table's entry for the sample: two 16-bit halves, x then y, with 8 fractional bits (14.4.4).
      let sid = sampleIdReg()
      let idx = evenReg(sid)
      let address = newReg(2)
      alu("SHADD", "u64", dst: .reg(address, 0), .special(0, 6, 0), idx, set: [("shift", 2)], named: [("wd1", "w0")])
      let word = newReg()
      message("LOAD", "i32", address: .reg(address, 0), offset: 0, write: .reg(word, 0), memory: 1, named: [("access", "none")])
      let half = newReg()
      alu("S16_TO_S32", "", dst: .reg(half, 0), .reg(word, 0), set: [("wd0", c)])
      let fl = newReg()
      alu("S32_TO_F32", "", dst: .reg(fl, 0), .reg(half, 0))
      let scale = materialize(0x3B80_0000)
      alu("FMA", "f32", dst: def32(i), .reg(fl, 0), scale, .const(0), set: [("neg2", 1)])
      usesSamplePositions = true
    default: throw BackendError.unsupported("a builtin")
    }
    if i.imm == IRBuiltin.sampleId || i.imm == IRBuiltin.samplePosition { perSampleShading = true }
  }
}

extension Opd {
  /// The virtual register of a plain register operand.
  var regIndex: Int {
    if case .reg(let r, _) = self { return r }
    return -1
  }
}
