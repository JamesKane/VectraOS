// SPDX-License-Identifier: BSD-3-Clause

// The GLSL.std.450 angle conversions and geometric functions (LowerGeometry.swift) on the IR interpreter, against CPU
// references written as the lowering computes them (a multiply and fused multiply-adds for each dot product).

import ShaderCompiler
import ShaderTestKit
import Testing

/// layout(set=0, binding=0) readonly buffer In { vec4 in_[]; };   // a.xyz, then b.xyz, per invocation
/// layout(set=0, binding=1) buffer Out { vec4 out_[]; };          // ten results per invocation
private let geometry = """
  OpCapability Shader
  %glsl = OpExtInstImport "GLSL.std.450"
  OpMemoryModel Logical GLSL450
  OpEntryPoint GLCompute %main "main" %gid
  OpExecutionMode %main LocalSize 8 1 1
  OpDecorate %gid BuiltIn GlobalInvocationId
  OpDecorate %varr ArrayStride 16
  OpMemberDecorate %In 0 Offset 0
  OpDecorate %In Block
  OpMemberDecorate %Out 0 Offset 0
  OpDecorate %Out Block
  OpDecorate %inv DescriptorSet 0
  OpDecorate %inv Binding 0
  OpDecorate %outv DescriptorSet 0
  OpDecorate %outv Binding 1
  \(Corpus.prelude)
  %v3float = OpTypeVector %float 3
  %u5 = OpConstant %uint 5
  %u6 = OpConstant %uint 6
  %u7 = OpConstant %uint 7
  %u8 = OpConstant %uint 8
  %u9 = OpConstant %uint 9
  %eta = OpConstant %float 0.75f
  %gid = OpVariable %ptr_in_v3uint Input
  %varr = OpTypeRuntimeArray %v4float
  %In = OpTypeStruct %varr
  %Out = OpTypeStruct %varr
  %ptr_sb_In = OpTypePointer StorageBuffer %In
  %ptr_sb_Out = OpTypePointer StorageBuffer %Out
  %inv = OpVariable %ptr_sb_In StorageBuffer
  %outv = OpVariable %ptr_sb_Out StorageBuffer
  %main = OpFunction %void None %fn
  %entry = OpLabel
  %gp = OpAccessChain %ptr_in_uint %gid %u0
  %i = OpLoad %uint %gp
  %i2 = OpIMul %uint %i %u2
  %i2b = OpIAdd %uint %i2 %u1
  %pa = OpAccessChain %ptr_sb_v4float %inv %u0 %i2
  %pb = OpAccessChain %ptr_sb_v4float %inv %u0 %i2b
  %a4 = OpLoad %v4float %pa
  %b4 = OpLoad %v4float %pb
  %a = OpVectorShuffle %v3float %a4 %a4 0 1 2
  %b = OpVectorShuffle %v3float %b4 %b4 0 1 2
  %ax = OpCompositeExtract %float %a 0
  %rad = OpExtInst %float %glsl 11 %ax
  %deg = OpExtInst %float %glsl 12 %ax
  %len = OpExtInst %float %glsl 66 %a
  %dist = OpExtInst %float %glsl 67 %a %b
  %lenx = OpExtInst %float %glsl 66 %ax
  %r0 = OpCompositeConstruct %v4float %rad %deg %len %dist
  %cross = OpExtInst %v3float %glsl 68 %a %b
  %norm = OpExtInst %v3float %glsl 69 %a
  %ff = OpExtInst %v3float %glsl 70 %a %b %a
  %refl = OpExtInst %v3float %glsl 71 %a %norm
  %bn = OpExtInst %v3float %glsl 69 %b
  %refr = OpExtInst %v3float %glsl 72 %norm %bn %eta
  %normx = OpExtInst %float %glsl 69 %ax
  %r1 = OpCompositeConstruct %v4float %cross %lenx
  %r2 = OpCompositeConstruct %v4float %norm %normx
  %r3 = OpCompositeConstruct %v4float %ff %f0
  %r4 = OpCompositeConstruct %v4float %refl %f0
  %r5 = OpCompositeConstruct %v4float %refr %f0
  %o = OpIMul %uint %i %u6
  %o1 = OpIAdd %uint %o %u1
  %o2 = OpIAdd %uint %o %u2
  %o3 = OpIAdd %uint %o %u3
  %o4 = OpIAdd %uint %o %u4
  %o5 = OpIAdd %uint %o %u5
  %q0 = OpAccessChain %ptr_sb_v4float %outv %u0 %o
  %q1 = OpAccessChain %ptr_sb_v4float %outv %u0 %o1
  %q2 = OpAccessChain %ptr_sb_v4float %outv %u0 %o2
  %q3 = OpAccessChain %ptr_sb_v4float %outv %u0 %o3
  %q4 = OpAccessChain %ptr_sb_v4float %outv %u0 %o4
  %q5 = OpAccessChain %ptr_sb_v4float %outv %u0 %o5
  OpStore %q0 %r0
  OpStore %q1 %r1
  OpStore %q2 %r2
  OpStore %q3 %r3
  OpStore %q4 %r4
  OpStore %q5 %r5
  OpReturn
  OpFunctionEnd
  """

private func dot(_ a: [Float], _ b: [Float]) -> Float {
  var acc = a[0] * b[0]
  for k in 1..<a.count { acc = acc.addingProduct(a[k], b[k]) }
  return acc
}

private func references(_ a: [Float], _ b: [Float]) -> [Float] {
  let rad = a[0] * Float(Double.pi / 180)
  let deg = a[0] * Float(180 / Double.pi)
  let len = dot(a, a).squareRoot()
  let d = (0..<3).map { a[$0] - b[$0] }
  let dist = dot(d, d).squareRoot()
  var cross: [Float] = []
  for (p, q) in [(1, 2), (2, 0), (0, 1)] { cross.append((-(a[q] * b[p])).addingProduct(a[p], b[q])) }
  let s = 1 / dot(a, a).squareRoot()
  let norm = a.map { $0 * s }
  let normx = a[0] * (1 / (a[0] * a[0]).squareRoot())
  let ff = dot(a, b) < 0 ? a : a.map { -$0 }
  let dn = dot(norm, a) * -2
  let refl = (0..<3).map { a[$0].addingProduct(dn, norm[$0]) }
  let sb = 1 / dot(b, b).squareRoot()
  let bn = b.map { $0 * sb }
  let eta: Float = 0.75
  let di = dot(bn, norm)
  let k = 1 - eta * eta * (1 - di * di)
  let t = k.squareRoot().addingProduct(eta, di)
  let refr = k < 0 ? [0, 0, 0] : (0..<3).map { eta * norm[$0] - t * bn[$0] }
  return [rad, deg, len, dist] + cross + [abs(a[0])] + norm + [normx] + ff + [0] + refl + [0] + refr + [0]
}

@Suite struct GeometryTests {
  @Test func theGeometricInstructions() throws {
    let n = 8
    var input: [Float] = []
    for i in 0..<n {
      let f = Float(i)
      input += [f * 0.5 - 1.75, 1.25 - f * 0.25, f * f * 0.125 + 0.5, 0, 0.75 - f * 0.5, f * 0.375 - 1, 2 - f * 0.125, 0]
    }
    for (name, ir) in try variants(geometry) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, bytes(input))
      mc.setBuffer(0, 1, [UInt8](repeating: 0, count: n * 6 * 16))
      try mc.dispatch(groups: (1, 1, 1))
      let got = floats(mc.storage[1]!)
      for i in 0..<n {
        let a = Array(input[(i * 8)..<(i * 8 + 3)])
        let b = Array(input[(i * 8 + 4)..<(i * 8 + 7)])
        let want = references(a, b)
        let have = Array(got[(i * 24)..<(i * 24 + 24)])
        for k in 0..<24 {
          // The interpreter's square root and reciprocal square root are the CPU's, and the passes may contract or
          // reorder a multiply, so allow a few units in the last place.
          let tol = max(abs(want[k]), 1) * 4e-6
          #expect(abs(have[k] - want[k]) <= tol, "\(name), invocation \(i), result \(k): \(have[k]) != \(want[k])")
        }
      }
    }
  }
}
