// SPDX-License-Identifier: BSD-3-Clause

// The hand-assembled varying probes of gpu-test (drivers/gpu/tests/native/Textured.swift) as words
// (drivers/gpu/tests/native/generated/HandProbes.swift): a vertex shader that stores a constant varying and a fragment
// shader that loads it and outputs it, with the compiler out of the loop. Every program is assembled, validated for its
// stage and encoded here (the ISA's assembler reads Characters, which the device can't link); the test regenerates the
// file's text and fails when the committed file differs (`VX_REGENERATE_SHADERS=1 swift test --filter VaryingProbeTests`).
//
// The vertex shaders read a window-space position from the table at FAU slot 0 (the triangle's position shader, 12c.4.2)
// and store the position record in the position group; the varying (0.25, 0.5, 0, 1) goes out in the generic group in
// one of five ways, which differ only in where it is stored and whether `shader_output` is asked.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import Testing
import ValhallISA

/// The prologue: the position loaded from the table, the varying's four registers set.
private let vertexHead = """
  SHADD.u64 r0:r1, u0, r60:r61.w0, shift:4
  LOAD.i128.slot0 @r4:r5:r6:r7, [r0:r1], offset:0
  MOV_IMM.i32 r12, #0x3E800000
  MOV_IMM.i32 r13, #0x3F000000
  MOV_IMM.i32 r14, #0x0
  MOV_IMM.i32 r15, #0x3F800000

  """

/// The position group, then the generic group at `buffer`, `offset`; `tested` asks `shader_output` bit 2.
private func vertex(buffer: Int, offset: Int, tested: Bool, inPositionGroup: Bool = false) -> String {
  var t = vertexHead
  t += "AND_IMM.i32 r2, shader_output.w0, #1\n"
  if inPositionGroup {
    // The position, then the varying in the same group (the record shared), at `offset` of buffer 0.
    t += "BRANCH.not.reconverge r2, offset:7\n"
    t += "LEA_BUF_IMM.slot1 @r8:r9, r59, index:0, table:13\n"
    t += "NOP.wait01\n"
    t += "STORE.i128.istream.slot0 @r4:r5:r6:r7, [r8:r9], offset:0\n"
    t += "NOP.wait0\n"
    t += "STORE.i128.estream.slot2 @r12:r13:r14:r15, [r8:r9], offset:\(offset)\n"
    t += "NOP.wait2\n"
    t += "NOP.reconverge\n"
    t += "NOP.end\n"
    return t
  }
  t += "BRANCH.not.reconverge r2, offset:5\n"
  t += "LEA_BUF_IMM.slot1 @r8:r9, r59, index:0, table:13\n"
  t += "NOP.wait01\n"
  t += "STORE.i128.istream.slot0 @r4:r5:r6:r7, [r8:r9], offset:0\n"
  t += "NOP.wait0\n"
  t += "NOP.reconverge\n"
  // The join: a wait on a NOP before the first instruction that needs it (13.6.1).
  t += "NOP.wait01\n"
  if tested {
    t += "AND_IMM.i32 r2, shader_output.w0, #4\n"
  } else {
    t += "MOV_IMM.i32 r2, #0x4\n"
  }
  t += "BRANCH.not.reconverge r2, offset:5\n"
  t += "LEA_BUF_IMM.slot1 @r8:r9, r59, index:\(buffer), table:13\n"
  t += "NOP.wait1\n"
  t += "STORE.i128.estream.slot0 @r12:r13:r14:r15, [r8:r9], offset:\(offset)\n"
  t += "NOP.wait0\n"
  t += "NOP.reconverge\n"
  t += "NOP.end\n"
  return t
}

/// A vertex shader that reports where table 61's buffers are: for each vertex and pass it stores, at the client buffer
/// FAU slot 1 names plus 64 bytes a vertex id and 32 a pass bit (shader_output bit 0), the words r59, shader_output,
/// the 64-bit address `LEA_BUF_IMM` gives for table 61 index 0, the same for index 1, the vertex id and a marker.
/// Then it stores the position (index 0) and the constant varying (index 1) as the others do.
private func addressProbe(tested: Bool) -> String {
  var t = vertexHead
  t += "AND_IMM.i32 r2, shader_output.w0, #1\n"
  t += "LEA_BUF_IMM.slot1 @r8:r9, r59, index:0, table:13\n"
  t += "LEA_BUF_IMM.slot2 @r10:r11, r59, index:1, table:13\n"
  t += "SHADD.u64 r16:r17, u1, r60:r61.w0, shift:6\n"
  t += "SHADD.u64 r16:r17, r16:r17, r2:r3.w0, shift:5\n"
  t += "AND_IMM.i32 r21, shader_output.w0, #0xFFFF\n"
  t += "MOV.i32 r20, r59\n"
  t += "MOV.i32 r26, r60\n"
  t += "MOV_IMM.i32 r27, #0xC0DE\n"
  t += "NOP.wait012\n"
  t += "MOV.i32 r22, r8\n"
  t += "MOV.i32 r23, r9\n"
  t += "MOV.i32 r24, r10\n"
  t += "MOV.i32 r25, r11\n"
  t += "STORE.i128.slot1 @r20:r21:r22:r23, [r16:r17], offset:0\n"
  t += "NOP.wait1\n"
  t += "STORE.i128.slot2 @r24:r25:r26:r27, [r16:r17], offset:16\n"
  t += "NOP.wait012\n"
  t += "AND_IMM.i32 r2, shader_output.w0, #1\n"
  t += "BRANCH.not.reconverge r2, offset:3\n"
  t += "STORE.i128.istream.slot0 @r4:r5:r6:r7, [r8:r9], offset:0\n"
  t += "NOP.wait0\n"
  t += "NOP.reconverge\n"
  t += "NOP.wait0\n"
  t += tested ? "AND_IMM.i32 r2, shader_output.w0, #4\n" : "MOV_IMM.i32 r2, #0x4\n"
  t += "BRANCH.not.reconverge r2, offset:3\n"
  t += "STORE.i128.estream.slot0 @r12:r13:r14:r15, [r10:r11], offset:0\n"
  t += "NOP.wait0\n"
  t += "NOP.reconverge\n"
  t += "NOP.end\n"
  return t
}

private func fragment(_ load: String) -> String {
  """
  \(load)
  NOP.wait0126
  ATEST @r60, r60, r3, atest_datum.w0
  NOP.wait
  BLEND.f32.slot0.end @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:0

  """
}

let handVertexes: [(name: String, text: String)] = [
  ("varyingBuffer1", vertex(buffer: 1, offset: 0, tested: true)),
  ("varyingBuffer1Always", vertex(buffer: 1, offset: 0, tested: false)),
  ("varyingBuffer0After", vertex(buffer: 0, offset: 16, tested: true)),
  ("varyingInPositionGroup", vertex(buffer: 0, offset: 16, tested: true, inPositionGroup: true)),
  ("addressProbeTested", addressProbe(tested: true)),
  ("addressProbeAlways", addressProbe(tested: false)),
]

let handFragments: [(name: String, text: String)] = [
  ("interpolated", fragment("LD_VAR_BUF_IMM.f32.v4.src_f32.slot0.center.store @r0:r1:r2:r3, 0x0, offset:0")),
  ("flat", fragment("LD_VAR_BUF_IMM.f32.v4.src_flat32.slot0.center.retrieve @r0:r1:r2:r3, 0x0, offset:0")),
  ("interpolatedAt16", fragment("LD_VAR_BUF_IMM.f32.v4.src_f32.slot0.center.store @r0:r1:r2:r3, 0x0, offset:16")),
]

private func words(_ text: String, stage: ShaderStage) throws -> [UInt64] {
  let isa = ISATable.shared
  let program = try isa.assemble(program: text)
  let found = isa.validate(program, options: ValidatorOptions(arch: 12, stage: stage, registerClass: .class64))
  #expect(found.isEmpty, "\(found.map { $0.rule + " at " + String($0.instruction) + ": " + $0.message })")
  return try program.map { try isa.encode($0) }
}

func handProbesSwift() throws -> String {
  var out = """
    // SPDX-License-Identifier: BSD-3-Clause
    //
    // Generated from graphics/compiler/valhall/backend/tests/VaryingProbeTests.swift by that test. Do not edit;
    // regenerate (VX_REGENERATE_SHADERS=1 swift test --filter VaryingProbeTests).
    // Hand-assembled vertex and fragment shaders for gpu-test's varying probes (Textured.swift).

    enum HandProbes {

    """
  func emit(_ name: String, _ w: [UInt64]) {
    out += "  static let \(name): [UInt64] = [\n"
    for x in w {
      var h = String(x, radix: 16)
      while h.count < 16 { h = "0" + h }
      out += "    0x\(h),\n"
    }
    out += "  ]\n"
  }
  for (n, t) in handVertexes { emit("vertex_" + n, try words(t, stage: .vertex)) }
  for (n, t) in handFragments { emit("fragment_" + n, try words(t, stage: .fragment)) }
  return out + "}\n"
}

@Suite struct VaryingProbeTests {
  @Test func theCommittedWordsAreTheProbesAssembled() throws {
    let text = try handProbesSwift()
    var path = #filePath
    if let r = realpath(path, nil) {
      path = String(cString: r)
      free(r)
    }
    for _ in 0..<6 { path = String(path[..<path.lastIndex(of: "/")!]) }
    path += "/drivers/gpu/tests/native/generated/HandProbes.swift"
    if getenv("VX_REGENERATE_SHADERS") != nil {
      guard let f = fopen(path, "wb") else {
        Issue.record("can't write \(path)")
        return
      }
      _ = Array(text.utf8).withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, f) }
      fclose(f)
    }
    var committed: String?
    if let f = fopen(path, "rb") {
      var bytes: [UInt8] = []
      var chunk = [UInt8](repeating: 0, count: 4096)
      while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { bytes += chunk[..<n] }
      fclose(f)
      committed = String(decoding: bytes, as: UTF8.self)
    }
    #expect(committed == text, "regenerate with VX_REGENERATE_SHADERS=1 swift test --filter VaryingProbeTests")
  }
}
