// SPDX-License-Identifier: BSD-3-Clause

// 64-bit integers to and from binary32 (valhall 11c.13.1.1), and the refusal of Float64, compiled for Valhall and run on the
// interpreter against Swift: the conversion is correctly rounded (nearest even), so Swift's `Float(x)` is the reference.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

private func shader(_ op: String, from: String, to: String, wideIn: Bool, wideOut: Bool) -> String {
  """
  OpCapability Shader
  OpCapability Int64
  OpMemoryModel Logical GLSL450
  OpEntryPoint GLCompute %main "main" %gid
  OpExecutionMode %main LocalSize 64 1 1
  OpDecorate %gid BuiltIn GlobalInvocationId
  OpDecorate %arrIn ArrayStride \(wideIn ? 8 : 4)
  OpDecorate %arrOut ArrayStride \(wideOut ? 8 : 4)
  OpMemberDecorate %A 0 Offset 0
  OpDecorate %A Block
  OpMemberDecorate %C 0 Offset 0
  OpDecorate %C Block
  OpDecorate %av DescriptorSet 0
  OpDecorate %av Binding 0
  OpDecorate %cv DescriptorSet 0
  OpDecorate %cv Binding 1
  \(Corpus.prelude)
  %gid = OpVariable %ptr_in_v3uint Input
  %ulong = OpTypeInt 64 0
  %long = OpTypeInt 64 1
  %arrIn = OpTypeRuntimeArray \(from)
  %arrOut = OpTypeRuntimeArray \(to)
  %A = OpTypeStruct %arrIn
  %C = OpTypeStruct %arrOut
  %ptr_A = OpTypePointer StorageBuffer %A
  %ptr_C = OpTypePointer StorageBuffer %C
  %ptr_in = OpTypePointer StorageBuffer \(from)
  %ptr_out = OpTypePointer StorageBuffer \(to)
  %av = OpVariable %ptr_A StorageBuffer
  %cv = OpVariable %ptr_C StorageBuffer
  %main = OpFunction %void None %fn
  %entry = OpLabel
  %gp = OpAccessChain %ptr_in_uint %gid %u0
  %i = OpLoad %uint %gp
  %pa = OpAccessChain %ptr_in %av %u0 %i
  %a = OpLoad \(from) %pa
  %r = \(op) \(to) %a
  %pc = OpAccessChain %ptr_out %cv %u0 %i
  OpStore %pc %r
  OpReturn
  OpFunctionEnd
  """
}

private func bytes64(_ v: [UInt64]) -> [UInt8] {
  v.flatMap { x in (0..<8).map { UInt8(truncatingIfNeeded: x >> UInt64(8 * $0)) } }
}

private func get64(_ b: [UInt8]) -> [UInt64] {
  stride(from: 0, to: b.count, by: 8).map { k in (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[k + $1]) << UInt64(8 * $1) } }
}

@Suite struct ConversionTests {
  /// Zero, powers of two and their neighbours, values that round at every width, ties, the limits, and a seeded run.
  private func values() -> [UInt64] {
    var v: [UInt64] = [0, 1, 2, 3, 0xFFFF_FFFF, 0x1_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, ~0, ~0 - 1]
    for k in 0..<64 {
      let p = UInt64(1) << UInt64(k)
      v += [p, p &- 1, p &+ 1, p | (p >> 1), p &+ (p >> 24), p &+ (p >> 23) &+ 1]
    }
    // Ties: 24 significant bits then exactly a half, with the low bit of the kept part odd and even.
    for k in 25..<64 {
      let half = UInt64(1) << UInt64(k - 25)
      v += [(UInt64(0x80_0001) << UInt64(k - 24)) | half, (UInt64(0x80_0000) << UInt64(k - 24)) | half]
    }
    var s: UInt64 = 7
    for _ in 0..<200 {
      s = s &* 6364136223846793005 &+ 1442695040888963407
      v.append(s >> UInt64(s % 61))
    }
    while v.count % 64 != 0 { v.append(UInt64(v.count)) }
    return v
  }

  @Test func integersToFloatRoundToNearestEven() throws {
    let v = values()
    for (op, type) in [("OpConvertUToF", "%ulong"), ("OpConvertSToF", "%long")] {
      let cs = try ValhallBackend.compile(try lowered(shader(op, from: type, to: "%float", wideIn: true, wideOut: false)))
      #expect(violations(cs) == [])
      let out = try HostRun.dispatch(
        cs, buffers: [Buffer(binding: 0, bytes: bytes64(v)), Buffer(binding: 1, bytes: [UInt8](repeating: 0, count: 4 * v.count))],
        grid: (UInt32(v.count / 64), 1, 1))
      let got = words(out[1].bytes)
      for (k, x) in v.enumerated() {
        let want = op == "OpConvertUToF" ? Float(x) : Float(Int64(bitPattern: x))
        if got[k] != want.bitPattern {
          Issue.record(Comment(rawValue: "\(op) \(x): got \(Float(bitPattern: got[k])), want \(want)"))
          break
        }
      }
    }
  }

  @Test func floatsToIntegersTruncate() throws {
    var f: [Float] = [0, 1, 1.5, 2.9, 0.99, 4294967296, 4294967040, 1e10, 1.2345e15, 9.2e18, 1.8e19, 16777216, 16777217, 33554432]
    var s: UInt64 = 11
    for _ in 0..<200 {
      s = s &* 6364136223846793005 &+ 1442695040888963407
      f.append(Float(s >> UInt64(s % 60)) * (s & 1 == 0 ? 0.37 : 1))
    }
    // The signed forms also take negatives (in range, below 2^63).
    var signedInputs = f.filter { $0 < 9.2e18 }
    signedInputs += signedInputs.map { -$0 }
    for (op, type, inputs) in [("OpConvertFToU", "%ulong", f), ("OpConvertFToS", "%long", signedInputs)] {
      var v = inputs
      while v.count % 64 != 0 { v.append(Float(v.count)) }
      let cs = try ValhallBackend.compile(try lowered(shader(op, from: "%float", to: type, wideIn: false, wideOut: true)))
      #expect(violations(cs) == [])
      let out = try HostRun.dispatch(
        cs, buffers: [Buffer(binding: 0, bytes: bytes(v)), Buffer(binding: 1, bytes: [UInt8](repeating: 0, count: 8 * v.count))],
        grid: (UInt32(v.count / 64), 1, 1))
      let got = get64(out[1].bytes)
      for (k, x) in v.enumerated() {
        let want = op == "OpConvertFToU" ? UInt64(x) : UInt64(bitPattern: Int64(x))
        if got[k] != want {
          Issue.record(Comment(rawValue: "\(op) \(x): got \(got[k]), want \(want)"))
          break
        }
      }
    }
  }

  @Test func float64IsRefusedByName() throws {
    let text = """
      OpCapability Shader
      OpCapability Float64
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 1 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %arr ArrayStride 8
      OpMemberDecorate %A 0 Offset 0
      OpDecorate %A Block
      OpDecorate %av DescriptorSet 0
      OpDecorate %av Binding 0
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %double = OpTypeFloat 64
      %arr = OpTypeRuntimeArray %double
      %A = OpTypeStruct %arr
      %ptr_A = OpTypePointer StorageBuffer %A
      %ptr_d = OpTypePointer StorageBuffer %double
      %av = OpVariable %ptr_A StorageBuffer
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %p = OpAccessChain %ptr_d %av %u0 %u0
      %x = OpLoad %double %p
      %y = OpFAdd %double %x %x
      OpStore %p %y
      OpReturn
      OpFunctionEnd
      """
    do {
      _ = try ValhallBackend.compile(try lowered(text))
      Issue.record("Float64 compiled")
    } catch let e as BackendError {
      #expect(e == .unsupported("Float64: the hardware has no double-precision float (valhall 15.15)"))
    }
  }
}
