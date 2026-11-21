// SPDX-License-Identifier: BSD-3-Clause

// 64-bit atomics (valhall 12a.8): `ATOM` with 64-bit data and the compare-exchange, on the interpreter, against the fold of the
// operands in Swift (the operations are commutative or the fold is order independent, so the final memory is exact).

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

private func bytes64(_ v: [UInt64]) -> [UInt8] {
  v.flatMap { x in (0..<8).map { UInt8(truncatingIfNeeded: x >> UInt64(8 * $0)) } }
}

private func get64(_ b: [UInt8]) -> [UInt64] {
  stride(from: 0, to: b.count, by: 8).map { k in (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[k + $1]) << UInt64(8 * $1) } }
}

@Suite struct Atomic64Tests {
  private func shader(_ op: String) -> String {
    let extra = op == "OpAtomicCompareExchange" ? "%u1 %u0 %u0 %v %zero" : "%u1 %u0 %v"
    return """
      OpCapability Shader
      OpCapability Int64
      OpCapability Int64Atomics
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 64 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %arr ArrayStride 8
      OpMemberDecorate %A 0 Offset 0
      OpDecorate %A Block
      OpDecorate %av DescriptorSet 0
      OpDecorate %av Binding 0
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %ulong = OpTypeInt 64 0
      %arr = OpTypeRuntimeArray %ulong
      %A = OpTypeStruct %arr
      %ptr_A = OpTypePointer StorageBuffer %A
      %ptr_el = OpTypePointer StorageBuffer %ulong
      %av = OpVariable %ptr_A StorageBuffer
      %big = OpConstant %ulong 1 1
      %zero = OpConstant %ulong 0 0
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %gp = OpAccessChain %ptr_in_uint %gid %u0
      %i = OpLoad %uint %gp
      %k = OpBitwiseAnd %uint %i %u3
      %iw = OpUConvert %ulong %i
      %v = OpIMul %ulong %iw %big
      %p = OpAccessChain %ptr_el %av %u0 %k
      %old = \(op) %ulong %p \(extra)
      OpReturn
      OpFunctionEnd
      """
  }

  @Test func eachOperationLeavesTheFoldOfItsOperands() throws {
    let ops: [(String, (UInt64, UInt64) -> UInt64)] = [
      ("OpAtomicIAdd", { $0 &+ $1 }), ("OpAtomicISub", { $0 &- $1 }), ("OpAtomicAnd", { $0 & $1 }), ("OpAtomicOr", { $0 | $1 }),
      ("OpAtomicXor", { $0 ^ $1 }), ("OpAtomicUMax", { max($0, $1) }), ("OpAtomicUMin", { min($0, $1) }),
      ("OpAtomicSMax", { Int64(bitPattern: $0) >= Int64(bitPattern: $1) ? $0 : $1 }),
      ("OpAtomicSMin", { Int64(bitPattern: $0) <= Int64(bitPattern: $1) ? $0 : $1 }),
    ]
    for (op, fold) in ops {
      let cs = try ValhallBackend.compile(try lowered(shader(op)))
      #expect(violations(cs) == [], Comment(rawValue: op))
      let initial: [UInt64] = [0xFFFF_0000_FFFF_0000, 5, 0x8000_0000_0000_0001, 0x0123_4567_89AB_CDEF]
      let out = try HostRun.dispatch(cs, buffers: [Buffer(binding: 0, bytes: bytes64(initial))], grid: (1, 1, 1))
      var want = initial
      for i in 0..<64 { want[i & 3] = fold(want[i & 3], UInt64(i) &* 4_294_967_297) }
      #expect(get64(out[0].bytes) == want, Comment(rawValue: op))
    }
  }

  /// A compare-exchange of 0 for the invocation's value: the first of each texel's invocations to run wins, and the rest see a
  /// non-zero memory and change nothing, whichever order the interpreter runs them in.
  @Test func aCompareExchangeStoresOnlyOnAMatch() throws {
    let cs = try ValhallBackend.compile(try lowered(shader("OpAtomicCompareExchange")))
    #expect(violations(cs) == [])
    let out = try HostRun.dispatch(cs, buffers: [Buffer(binding: 0, bytes: bytes64([0, 0, 0, 0]))], grid: (1, 1, 1))
    let got = get64(out[0].bytes)
    // The memory holds one invocation's value of its texel (k = i & 3), never a mixture.
    for k in 0..<4 { #expect(got[k] != 0 && (got[k] / 4_294_967_297) & 3 == UInt64(k) && got[k] % 4_294_967_297 == 0, "texel \(k)") }
  }
}
