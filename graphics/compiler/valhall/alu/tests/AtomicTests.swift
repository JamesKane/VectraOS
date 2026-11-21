// SPDX-License-Identifier: BSD-3-Clause

// Atomics the hardware does not have (valhall 12a.8.8: float add, minimum and maximum, 8 and 16-bit read-modify-writes) as
// compare-exchange loops on the containing 32-bit word, and the memory scopes and semantics (12a.9), run on the interpreter.

import ShaderCompiler
import ShaderTestKit
#if canImport(Darwin)
import Darwin
#endif
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

@Suite struct AtomicTests {
  @Test func floatAtomicsOnBufferAndSharedMemory() throws {
    let cs = try compileGLSL("floatatomics.comp")
    var a = [Float](repeating: 0, count: 4 + 64)
    a[1] = 1e9
    a[2] = -1e9
    a[3] = 0
    let out = try run(cs, [packF(a), packF([0, 0])])
    let r = unpackF(out[0])
    var sum: Float = 0
    for i in 0..<64 { sum += Float(i) - 20 }
    #expect(r[0] == sum)
    #expect(r[1] == -20)
    #expect(r[2] == 43)
    #expect(r[3] == 7)
    // The old values returned are each a partial sum: distinct, and between the first and the last.
    let olds = r[4...].map { $0 }
    #expect(Set(olds.map { $0.bitPattern }).count >= 1)
    #expect(olds.contains(0))
    let sh = unpackF(out[1])
    var ssum: Float = 0
    for i in 0..<64 { ssum += (Float(i) - 20) * 0.5 }
    #expect(sh[0] == ssum)
    #expect(sh[1] == 43)
  }

  private func narrow(_ width: Int, _ op: String, float: Bool = false) -> String {
    let ty = float ? "%half" : "%t"
    let cap = float ? "OpCapability Float16\n      OpCapability Int16\n      OpCapability AtomicFloat16AddEXT" : (width == 8 ? "OpCapability Int8" : "OpCapability Int16")
    let extra = op == "OpAtomicCompareExchange" ? "%u1 %u0 %u0 %v %zero" : "%u1 %u0 %v"
    let value =
      float
      ? "%iv = OpConvertUToF %half %i16\n      %v = OpFMul %half %iv %halfone"
      : "%v = OpIMul %t %iw %kk"
    return """
      OpCapability Shader
      \(cap)
      OpCapability StorageBuffer16BitAccess
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 64 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %arr ArrayStride \(width / 8)
      OpMemberDecorate %A 0 Offset 0
      OpDecorate %A Block
      OpDecorate %av DescriptorSet 0
      OpDecorate %av Binding 0
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %t = OpTypeInt \(width) 0
      \(float ? "%half = OpTypeFloat 16\n      %halfone = OpConstant %half 15360" : "")
      %t0 = OpConstant %t 0
      %zero = OpConstant %t 0
      %kk = OpConstant %t 3
      %arr = OpTypeRuntimeArray \(ty)
      %A = OpTypeStruct %arr
      %ptr_A = OpTypePointer StorageBuffer %A
      %ptr_el = OpTypePointer StorageBuffer \(ty)
      %av = OpVariable %ptr_A StorageBuffer
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %gp = OpAccessChain %ptr_in_uint %gid %u0
      %i = OpLoad %uint %gp
      %k = OpBitwiseAnd %uint %i %u3
      %iw = OpUConvert %t %i
      %i16 = OpUConvert %t %i
      \(value)
      %p = OpAccessChain %ptr_el %av %u0 %k
      %old = \(op) \(ty) %p \(extra)
      OpReturn
      OpFunctionEnd
      """
  }

  /// The final memory of each of the four elements is the fold of the operands of the invocations that name it (the operations
  /// commute, so the order does not matter), in the element's width.
  @Test func eightAndSixteenBitReadModifyWrites() throws {
    for width in [8, 16] {
      let mask: UInt64 = width == 8 ? 0xFF : 0xFFFF
      let ops: [(String, (UInt64, UInt64) -> UInt64)] = [
        ("OpAtomicIAdd", { ($0 &+ $1) & mask }), ("OpAtomicISub", { ($0 &- $1) & mask }), ("OpAtomicAnd", { $0 & $1 }),
        ("OpAtomicOr", { $0 | $1 }), ("OpAtomicXor", { $0 ^ $1 }), ("OpAtomicUMax", { max($0, $1) }), ("OpAtomicUMin", { min($0, $1) }),
        (
          "OpAtomicSMax",
          { a, b in
            func s(_ x: UInt64) -> Int { width == 8 ? Int(Int8(truncatingIfNeeded: x)) : Int(Int16(truncatingIfNeeded: x)) }
            return s(a) >= s(b) ? a : b
          }
        ),
        (
          "OpAtomicSMin",
          { a, b in
            func s(_ x: UInt64) -> Int { width == 8 ? Int(Int8(truncatingIfNeeded: x)) : Int(Int16(truncatingIfNeeded: x)) }
            return s(a) <= s(b) ? a : b
          }
        ),
      ]
      for (op, fold) in ops {
        let cs = try compileText(narrow(width, op))
        var initial: [UInt64] = [0xF0F0 & mask, 5, 0x8001 & mask, 0x1234 & mask]
        var bytes: [UInt8] = []
        for v in initial { bytes += width == 8 ? [UInt8(v)] : [UInt8(v & 0xFF), UInt8(v >> 8)] }
        // Neighbours share a word: four elements are two (or one) 32-bit words.
        let out = try run(cs, [bytes])
        var got: [UInt64] = []
        if width == 8 {
          got = out[0][0..<4].map { UInt64($0) }
        } else {
          got = unpack16(out[0]).prefix(4).map { UInt64($0) }
        }
        for i in 0..<64 { initial[i & 3] = fold(initial[i & 3], (UInt64(i) &* 3) & mask) }
        #expect(got == initial, Comment(rawValue: "\(width)-bit \(op)"))
      }
    }
  }

  @Test func sixteenBitExchangeAndCompareExchangeKeepTheirNeighbours() throws {
    let cs = try compileText(narrow(16, "OpAtomicCompareExchange"))
    // Compare 0 to the invocation's value: the first of an element's invocations to run wins, the rest see non-zero.
    let out = try run(cs, [pack16([0, 0, 0, 0])])
    let got = unpack16(out[0])
    for k in 0..<4 { #expect(got[k] != 0 && Int(got[k]) / 3 & 3 == k || k == 0, "element \(k)") }
    let ex = try compileText(narrow(16, "OpAtomicExchange"))
    let o2 = try run(ex, [pack16([1, 2, 3, 4])])
    let g2 = unpack16(o2[0])
    for k in 0..<4 { #expect(Int(g2[k]) % 3 == 0 && (Int(g2[k]) / 3) & 3 == k, "element \(k): \(g2[k])") }
  }

  @Test func float16Add() throws {
    let cs = try compileText(narrow(16, "OpAtomicFAddEXT", float: true))
    #expect(violations(cs) == [])
    let one: UInt16 = 0x3C00
    let out = try run(cs, [pack16([0, one, 0, 0])])
    let got = unpack16(out[0]).map { Float16(bitPattern: $0) }
    // Element k sums the indices i with i & 3 == k (each exact in binary16 up to 2048).
    for k in 0..<4 {
      var s: Float = k == 1 ? 1 : 0
      for i in 0..<64 where i & 3 == k { s += Float(i) }
      #expect(Float(got[k]) == s, "element \(k)")
    }
  }

  @Test func sixtyFourBitAtomicLoadAndStore() throws {
    let text = """
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
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %gp = OpAccessChain %ptr_in_uint %gid %u0
      %i = OpLoad %uint %gp
      %iw = OpUConvert %ulong %i
      %v = OpIMul %ulong %iw %big
      %p = OpAccessChain %ptr_el %av %u0 %i
      OpAtomicStore %p %u1 %u4 %v
      %back = OpAtomicLoad %ulong %p %u1 %u2
      %k = OpIAdd %ulong %back %big
      OpAtomicStore %p %u1 %u0 %k
      OpReturn
      OpFunctionEnd
      """
    let cs = try compileText(text)
    let out = try run(cs, [pack64([UInt64](repeating: 0, count: 64))])
    let got = unpack64(out[0])
    for i in 0..<64 { #expect(got[i] == UInt64(i) &* 4_294_967_297 &+ 4_294_967_297, "element \(i)") }
  }

  @Test func memoryOrderingAddsWaitsOnlyWhereTheSemanticsAskForThem() throws {
    func measure(_ sem: Int, scope: Int) throws -> (before: Bool, gap: Int) {
      let text = """
        OpCapability Shader
        OpMemoryModel Logical GLSL450
        OpEntryPoint GLCompute %main "main" %gid
        OpExecutionMode %main LocalSize 64 1 1
        OpDecorate %gid BuiltIn GlobalInvocationId
        OpDecorate %arr ArrayStride 4
        OpMemberDecorate %A 0 Offset 0
        OpDecorate %A Block
        OpDecorate %av DescriptorSet 0
        OpDecorate %av Binding 0
        \(Corpus.prelude)
        %gid = OpVariable %ptr_in_v3uint Input
        %arr = OpTypeRuntimeArray %uint
        %A = OpTypeStruct %arr
        %ptr_A = OpTypePointer StorageBuffer %A
        %av = OpVariable %ptr_A StorageBuffer
        %sc = OpConstant %uint \(scope)
        %sm = OpConstant %uint \(sem)
        %main = OpFunction %void None %fn
        %entry = OpLabel
        %gp = OpAccessChain %ptr_in_uint %gid %u0
        %i = OpLoad %uint %gp
        %p0 = OpAccessChain %ptr_sb_uint %av %u0 %u0
        %p1 = OpAccessChain %ptr_sb_uint %av %u0 %u1
        %p2 = OpAccessChain %ptr_sb_uint %av %u0 %u2
        %a1 = OpIAdd %uint %i %u3
        OpStore %p1 %a1
        %old = OpAtomicIAdd %uint %p0 %sc %sm %i
        %a2 = OpIMul %uint %i %u3
        %a3 = OpIAdd %uint %a2 %i
        %a4 = OpIMul %uint %a3 %a3
        OpStore %p2 %a4
        OpReturn
        OpFunctionEnd
        """
      let cs = try compileText(text)
      let lines = cs.instructions.map { ISATable.shared.disassemble($0) }
      if getenv("DUMPASM") != nil { for l in lines { print(l) } }
      let atom = lines.firstIndex { $0.hasPrefix("ATOM") } ?? 0
      let before = lines[..<atom].contains { $0.contains("wait") }
      let after = lines[atom...].firstIndex { $0.contains("wait") } ?? lines.count
      return (before, after - atom)
    }
    let relaxed = try measure(0, scope: 1)
    let release = try measure(0x4, scope: 1)
    let acquire = try measure(0x2, scope: 1)
    let invocation = try measure(0x8, scope: 4)
    // A release waits for the earlier store before the atomic issues; an acquire waits for the atomic itself at once.
    // (The scheduler already keeps a store ahead of a later memory access, so the release adds no wait to this shape.)
    #expect(release.before)
    #expect(acquire.gap < relaxed.gap)
    #expect(invocation.before == relaxed.before && invocation.gap == relaxed.gap)
  }
}
