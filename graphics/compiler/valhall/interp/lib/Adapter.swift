// SPDX-License-Identifier: BSD-3-Clause

// THE ADAPTER POINT: where ValhallISA's decoded instructions become `Instr`.
//
// ValhallISA (the encoder and decoder) is written alongside this target
// and does not exist for it to depend on yet. When it does, its decoded
// instruction type conforms to `InstrConvertible`, and
// `Shader(decoded:)` makes a shader from a decoded program. The
// conversion is a copy of fields; this table says which bits feed which
// `Instr` field (10 §10.2 to §10.7), so it can be written without
// re-reading the spec.
//
//   word bits      Instr field            notes
//   [62:59]        flow                   `Flow(rawValue:)`; 11 and 14 are reserved
//   [58:57]        fauPage
//   [56:52]        (class)                with opcode 1 and 2 chooses `op` and `dataType`
//   [51:48]        dataType               classes R2, R3_CMP, R4_CSEL, D2 (10 §10.10.1)
//   [47:46]        dstWidth               ALU classes; message classes use it as staging control
//   [45:40]        dst                    destination, or first staging register
//   [7:0] [15:8] [23:16] [31:24]   s0 s1 s2 s3      source bytes, verbatim (10 §10.5.1)
//   [38] [36] [34] neg bit 0, 1, 2        [39] [37] [35] abs bit 0, 1, 2
//   widen/swizzle  widen0 widen1 widen2   the field value of the instruction's family, verbatim;
//                                         the position is per instruction (11a to 11c)
//   [31:30]        round                  (the 2-bit field), [32:30] for the 3-bit fields
//   [33:32]        clamp                  FADD and FMA; [34:32] is `cmp` for the compare classes
//   [31:30]        sem                    FMIN and FMAX
//   [34:32]        cmp                    R3_CMP, R4_CSEL, DISCARD
//   [25:24]        combine                R3_CMP; N1/N2/N3 `[39:37]` is `combine`, `[36]` is `not`
//   [31:30]        resultType             R3_CMP
//   [30]           saturate               integer classes
//   [34:8]         offset                 BRANCH, signed, in 8-byte instructions
//   [39:8]         imm                    R1I
//   [23:8]         offset                 LOAD and STORE, signed 16 bits; atomics `[15:8]` unsigned
//   [29:27]        memWidth               S2 and S4
//   [38:36] [37:36] [36]   lane           load result and store source lane (12a §12a.1.3)
//   [39]           zeroExtend             loads
//   [26:24]        access                 S2, S3, S4
//   [32:30]        slot
//   [25:22]        atomOp                 [24:22] for ATOM1
//   [21:16]        writeReg               S2RW
//   [39:36]        subgroup               CLPER, WMASK; [35:32] laneOp, [25:22] inactive
//
// `Shader.code` is the list in program order; a `BRANCH` offset is relative to the next instruction,
// exactly as encoded, so no label resolution is needed.

public protocol InstrConvertible {
  /// This decoded instruction as the interpreter's `Instr`. Throws what the interpreter does not model.
  func interpInstr() throws -> Instr
}

extension Shader {
  /// A shader from decoded instructions, in program order.
  public init<S: Sequence>(decoded: S) throws where S.Element: InstrConvertible {
    code = try decoded.map { try $0.interpInstr() }
  }
}
