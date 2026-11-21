// SPDX-License-Identifier: BSD-3-Clause

// Integer division and remainder (SPIR-V's OpUDiv, OpSDiv, OpUMod, OpSRem and OpSMod, 32 and 64 bits) compiled for
// Valhall, which has no divide instruction (11b.1), and run on the Valhall interpreter against Swift's arithmetic:
// every pair of a small range, the edge values, and random pairs from a fixed seed.
//
// What SPIR-V leaves undefined is defined here, so a shader never hangs or faults: x / 0 and x % 0 are 0, INT_MIN / -1
// is INT_MIN and INT_MIN % -1 is 0.

import Foundation
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

/// `C[i] = A[i] op B[i]` over 64-invocation workgroups, on 32 or 64-bit elements.
func divisionShader(op: String, wide: Bool) -> String {
  let t = wide ? "%ulong" : "%uint"
  let s = wide ? "%long" : "%int"
  let stride = wide ? 8 : 4
  let signed = op != "OpUDiv" && op != "OpUMod"
  let body =
    signed
    ? """
      %sa = OpBitcast \(s) %a
      %sb = OpBitcast \(s) %b
      %sr = \(op) \(s) %sa %sb
      %r = OpBitcast \(t) %sr
      """
    : "%r = \(op) \(t) %a %b"
  return """
    OpCapability Shader
    \(wide ? "OpCapability Int64" : "")
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %arr ArrayStride \(stride)
    OpMemberDecorate %A 0 Offset 0
    OpMemberDecorate %A 0 NonWritable
    OpDecorate %A Block
    OpMemberDecorate %B 0 Offset 0
    OpMemberDecorate %B 0 NonWritable
    OpDecorate %B Block
    OpMemberDecorate %C 0 Offset 0
    OpDecorate %C Block
    OpDecorate %av DescriptorSet 0
    OpDecorate %av Binding 0
    OpDecorate %bv DescriptorSet 0
    OpDecorate %bv Binding 1
    OpDecorate %cv DescriptorSet 0
    OpDecorate %cv Binding 2
    \(Corpus.prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    \(wide ? "%ulong = OpTypeInt 64 0" : "")
    \(wide ? "%long = OpTypeInt 64 1" : "")
    %arr = OpTypeRuntimeArray \(t)
    %A = OpTypeStruct %arr
    %B = OpTypeStruct %arr
    %C = OpTypeStruct %arr
    %ptr_A = OpTypePointer StorageBuffer %A
    %ptr_B = OpTypePointer StorageBuffer %B
    %ptr_C = OpTypePointer StorageBuffer %C
    %ptr_el = OpTypePointer StorageBuffer \(t)
    %av = OpVariable %ptr_A StorageBuffer
    %bv = OpVariable %ptr_B StorageBuffer
    %cv = OpVariable %ptr_C StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %gp
    %pa = OpAccessChain %ptr_el %av %u0 %i
    %a = OpLoad \(t) %pa
    %pb = OpAccessChain %ptr_el %bv %u0 %i
    %b = OpLoad \(t) %pb
    \(body)
    %pc = OpAccessChain %ptr_el %cv %u0 %i
    OpStore %pc %r
    OpReturn
    OpFunctionEnd
    """
}

/// The operations, in SPIR-V's names, and what Swift says each gives (the 64-bit pattern of a 64-bit result, the
/// zero-extended pattern of a 32-bit one).
private enum DivOp: CaseIterable {
  case udiv, sdiv, umod, srem, smod

  var spirv: String {
    switch self {
    case .udiv: return "OpUDiv"
    case .sdiv: return "OpSDiv"
    case .umod: return "OpUMod"
    case .srem: return "OpSRem"
    case .smod: return "OpSMod"
    }
  }

  /// The results of a zero divisor (valhall 11b.8.1.6).
  var isQuotient: Bool { self == .udiv || self == .sdiv }

  func reference64(_ a: UInt64, _ b: UInt64) -> UInt64 {
    if b == 0 { return !isQuotient ? a : self == .udiv ? ~0 : (Int64(bitPattern: a) < 0 ? 1 : ~0) }
    let sa = Int64(bitPattern: a)
    let sb = Int64(bitPattern: b)
    switch self {
    case .udiv: return a / b
    case .umod: return a % b
    case .sdiv: return UInt64(bitPattern: sa.dividedReportingOverflow(by: sb).partialValue)
    case .srem: return UInt64(bitPattern: sa.remainderReportingOverflow(dividingBy: sb).partialValue)
    case .smod:
      let r = sa.remainderReportingOverflow(dividingBy: sb).partialValue
      return UInt64(bitPattern: r != 0 && (r ^ sb) < 0 ? r &+ sb : r)
    }
  }

  func reference32(_ a: UInt32, _ b: UInt32) -> UInt32 {
    if b == 0 {
      if !isQuotient { return a }
      if a == 0 { return 2 }
      return self == .sdiv && Int32(bitPattern: a) < 0 ? a &- 1 : a &+ 1
    }
    let sa = Int32(bitPattern: a)
    let sb = Int32(bitPattern: b)
    switch self {
    case .udiv: return a / b
    case .umod: return a % b
    case .sdiv: return UInt32(bitPattern: sa.dividedReportingOverflow(by: sb).partialValue)
    case .srem: return UInt32(bitPattern: sa.remainderReportingOverflow(dividingBy: sb).partialValue)
    case .smod:
      let r = sa.remainderReportingOverflow(dividingBy: sb).partialValue
      return UInt32(bitPattern: r != 0 && (r ^ sb) < 0 ? r &+ sb : r)
    }
  }
}

/// A deterministic generator (SplitMix64).
private struct Rng {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  /// A value of a random bit length up to `bits`, so small and large operands mix.
  mutating func shaped(_ bits: Int) -> UInt64 {
    let length = Int(next() % UInt64(bits + 1))
    let v = next()
    return length == 0 ? 0 : (length >= 64 ? v : v & ((1 << UInt64(length)) - 1))
  }
}

private func pack(_ v: [UInt64], wide: Bool) -> [UInt8] {
  var out: [UInt8] = []
  for x in v {
    for k in 0..<(wide ? 8 : 4) { out.append(UInt8(truncatingIfNeeded: x >> UInt64(8 * k))) }
  }
  return out
}

private func unpack(_ b: [UInt8], wide: Bool) -> [UInt64] {
  let w = wide ? 8 : 4
  var out: [UInt64] = []
  var k = 0
  while k + w <= b.count {
    var x: UInt64 = 0
    for j in 0..<w { x |= UInt64(b[k + j]) << UInt64(8 * j) }
    out.append(x)
    k += w
  }
  return out
}

/// Run `op` over the pairs (padded to a workgroup) and return the first mismatches against Swift.
private func check(_ op: DivOp, wide: Bool, _ pairs: [(UInt64, UInt64)]) throws -> [String] {
  var a: [UInt64] = []
  var b: [UInt64] = []
  let mask: UInt64 = wide ? ~0 : 0xFFFF_FFFF
  for (x, y) in pairs {
    a.append(x & mask)
    b.append(y & mask)
  }
  while a.count % 64 != 0 {
    a.append(1)
    b.append(1)
  }
  let n = a.count
  let run = try execute(
    divisionShader(op: op.spirv, wide: wide),
    inputs: [pack(a, wide: wide), pack(b, wide: wide), pack([UInt64](repeating: 0xDEAD, count: n), wide: wide)],
    grid: (n / 64, 1, 1))
  let got = unpack(run.got[2], wide: wide)
  var bad: [String] = []
  for k in 0..<n {
    let want = wide ? op.reference64(a[k], b[k]) : UInt64(op.reference32(UInt32(a[k]), UInt32(b[k])))
    if got[k] != want && bad.count < 8 { bad.append("\(op) \(a[k]) \(b[k]): got \(got[k]), want \(want)") }
  }
  // The IR interpreter's 0 for a zero divisor is not the reference sequences' (valhall 11b.8.1.6).
  if bad.isEmpty && !b.contains(0) && run.got[2] != run.want[2] { bad.append("\(op): the IR interpreter disagrees with the Valhall run") }
  if !violations(run.shader).isEmpty { bad.append("\(op): the validator: \(violations(run.shader))") }
  return bad
}

/// Every pair of a small range (as bit patterns): all the sign combinations.
private func smallPairs(_ r: Int) -> [(UInt64, UInt64)] {
  var out: [(UInt64, UInt64)] = []
  for a in -r...r {
    for b in -r...r { out.append((UInt64(bitPattern: Int64(a)), UInt64(bitPattern: Int64(b)))) }
  }
  return out
}

/// The edges of a width: zero, one, the powers of two and their neighbours, the signed and unsigned limits.
private func edges(_ bits: Int) -> [UInt64] {
  var e: [UInt64] = [0, 1, 2, 3, 5, 7, 10, 255, 256, 65535, 65536, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x1_0000_0000]
  if bits == 64 { e += [0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_0000_0000] }
  e += [0x5555_5555, 0xAAAA_AAAA, 0xFFFF_FFFE, 0x7FFF_FFFE, 0x8000_0001, 0x00FF_FFFF, 0x0100_0001, 0x0100_0000]
  for k in stride(from: 0, to: bits, by: 3) {
    let p = UInt64(1) << UInt64(k)
    e += [p, p &- 1, p &+ 1]
  }
  let m: UInt64 = bits == 64 ? ~0 : 0xFFFF_FFFF
  var seen: [UInt64] = []
  for x in e {
    let y = x & m
    if !seen.contains(y) { seen.append(y) }
    let n = (0 &- y) & m
    if !seen.contains(n) { seen.append(n) }
  }
  return seen
}

private func edgePairs(_ bits: Int, every: Int) -> [(UInt64, UInt64)] {
  let e = edges(bits)
  var out: [(UInt64, UInt64)] = []
  var n = 0
  for x in e {
    for y in e {
      if n % every == 0 || (slow && (x == 0 || y == 0 || x == y)) || (!slow && (y == 0 && x < 4 || y == 1 && x > 0x7FFF_FFFF_FFFF_FFFF)) { out.append((x, y)) }
      n += 1
    }
  }
  return out
}

/// Random pairs of mixed lengths, and pairs built around a multiple (a = q * b + r, with r near 0 and near b).
private func randomPairs(_ bits: Int, count: Int, seed: UInt64) -> [(UInt64, UInt64)] {
  var rng = Rng(state: seed)
  var out: [(UInt64, UInt64)] = []
  let m: UInt64 = bits == 64 ? ~0 : 0xFFFF_FFFF
  while out.count < count {
    let b = rng.shaped(bits)
    switch rng.next() % 3 {
    case 0: out.append((rng.shaped(bits), b))
    case 1:
      let q = rng.shaped(bits)
      let r = rng.next() % 3
      out.append((((q &* b) &+ r) & m, b))
    default:
      let q = rng.shaped(bits)
      out.append((((q &* b) &- 1 &- (rng.next() % 2)) & m, b))
    }
  }
  return out
}

/// The exhaustive sets run with VX_SLOW_TESTS set; the default sets are a representative part (the suite stays under a minute).
private let slow = ProcessInfo.processInfo.environment["VX_SLOW_TESTS"] != nil

/// `C[i] = A[i] op c` for a constant divisor c (32 bits): the multiply-high method (valhall 11b.8.1.5).
func constantDivisionShader(op: String, divisor: UInt32) -> String {
  let signed = op != "OpUDiv" && op != "OpUMod"
  let body =
    signed
    ? "%sa = OpBitcast %int %a\n%sr = \(op) %int %sa %cs\n%r = OpBitcast %uint %sr"
    : "%r = \(op) %uint %a %cu"
  return """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %arr ArrayStride 4
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
    %cu = OpConstant %uint \(divisor)
    %cs = OpConstant %int \(divisor)
    %arr = OpTypeRuntimeArray %uint
    %A = OpTypeStruct %arr
    %C = OpTypeStruct %arr
    %ptr_A = OpTypePointer StorageBuffer %A
    %ptr_C = OpTypePointer StorageBuffer %C
    %av = OpVariable %ptr_A StorageBuffer
    %cv = OpVariable %ptr_C StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %gp
    %pa = OpAccessChain %ptr_sb_uint %av %u0 %i
    %a = OpLoad %uint %pa
    \(body)
    %pc = OpAccessChain %ptr_sb_uint %cv %u0 %i
    OpStore %pc %r
    OpReturn
    OpFunctionEnd
    """
}

@Suite struct DivisionTests {
  @Test func everyPairOfASmallRangeMatchesSwift32() throws {
    for op in DivOp.allCases { #expect(try check(op, wide: false, smallPairs(slow ? 20 : 12)) == [], "\(op)") }
  }

  @Test func everyPairOfASmallRangeMatchesSwift64() throws {
    for op in DivOp.allCases { #expect(try check(op, wide: true, smallPairs(slow ? 10 : 5)) == [], "\(op)") }
  }

  @Test func theEdgeValuesMatchSwift32() throws {
    for op in DivOp.allCases { #expect(try check(op, wide: false, edgePairs(32, every: slow ? 3 : 11)) == [], "\(op)") }
  }

  @Test func theEdgeValuesMatchSwift64() throws {
    // The 64-bit edge set is large: the pairs are every one of a shuffled stride, still across the sign and size classes.
    let thin = edgePairs(64, every: slow ? 400 : 3000)
    for op in DivOp.allCases { #expect(try check(op, wide: true, thin) == [], "\(op)") }
  }

  @Test func randomPairsMatchSwift32() throws {
    for (n, op) in DivOp.allCases.enumerated() {
      #expect(try check(op, wide: false, randomPairs(32, count: slow ? 2048 : 512, seed: 0x1234 + UInt64(n))) == [], "\(op)")
    }
  }

  @Test func randomPairsMatchSwift64() throws {
    for (n, op) in DivOp.allCases.enumerated() {
      #expect(try check(op, wide: true, randomPairs(64, count: slow ? 128 : 32, seed: 0x5678 + UInt64(n))) == [], "\(op)")
    }
  }

  /// The one lowered program the backend once refused: an array's length is a division of a 64-bit size.
  @Test func zeroAndOverflowAreDefined() throws {
    let pairs: [(UInt64, UInt64)] = [
      (7, 0), (0, 0), (0x8000_0000, 0xFFFF_FFFF), (0x8000_0000, 1), (0xFFFF_FFFF, 0xFFFF_FFFF), (0xFFFF_FFFF, 1),
    ]
    for op in DivOp.allCases { #expect(try check(op, wide: false, pairs) == [], "\(op)") }
    let wide: [(UInt64, UInt64)] = [
      (7, 0), (0, 0), (0x8000_0000_0000_0000, ~0), (0x8000_0000_0000_0000, 1), (~0, ~0), (~0, 1), (~0, 0x1_0000_0000),
    ]
    for op in DivOp.allCases { #expect(try check(op, wide: true, wide) == [], "\(op)") }
  }

  /// A constant divisor: the zero, the powers of two, the ones at and above 2^31, and the ones that need the multiply-high
  /// constants, with the edge values and a random run for the numerator.
  @Test func constantDivisorsMatchSwift() throws {
    let divisors: [UInt32] = [
      0, 1, 2, 3, 5, 6, 7, 10, 11, 13, 100, 641, 1000, 65535, 65537, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_FFFE,
      0xFFFF_FFFF, 0xFFFF_FFFD, 0xFFFF_FFF9, 0xFFFF_FF00, 0x8000_0000 + 7,
    ]
    var numerators = edges(32)
    var rng = Rng(state: 99)
    for _ in 0..<(slow ? 300 : 40) { numerators.append(rng.shaped(32)) }
    while numerators.count % 64 != 0 { numerators.append(UInt64(numerators.count)) }
    let picked = slow ? divisors : [0, 3, 7, 641, 0x7FFF_FFFF, 0x8000_0001, 0xFFFF_FFFF, 0xFFFF_FFFD, 0xFFFF_FFF9, 1, 16]
    for op in DivOp.allCases {
      for c in picked {
        let cs = try ValhallBackend.compile(try lowered(constantDivisionShader(op: op.spirv, divisor: c)))
        #expect(violations(cs) == [], "\(op) \(c)")
        let out = try HostRun.dispatch(
          cs, buffers: [Buffer(binding: 0, bytes: pack(numerators, wide: false)), Buffer(binding: 1, bytes: pack(numerators, wide: false))],
          grid: (UInt32(numerators.count / 64), 1, 1))
        let got = unpack(out[1].bytes, wide: false)
        for (k, n) in numerators.enumerated() {
          // A constant zero divisor is 0 (11b.8.1.5).
          let want = c == 0 ? UInt64(0) : UInt64(op.reference32(UInt32(n), c))
          if got[k] != want { Issue.record(Comment(rawValue: "\(op) \(n) / \(c): got \(got[k]), want \(want)")); break }
        }
      }
    }
  }
}
