// SPDX-License-Identifier: BSD-3-Clause

// A corpus of compute shaders, hand-written in SPIR-V assembly (the GLSL each
// one stands for is in its comment). ExecTests runs each on the IR
// interpreter, before and after the passes, against a CPU reference.

public enum Corpus {
  /// The types and constants most shaders share (unused ones are harmless).
  public static let prelude = """
    %void = OpTypeVoid
    %fn = OpTypeFunction %void
    %bool = OpTypeBool
    %uint = OpTypeInt 32 0
    %int = OpTypeInt 32 1
    %float = OpTypeFloat 32
    %v3uint = OpTypeVector %uint 3
    %v4float = OpTypeVector %float 4
    %ptr_in_v3uint = OpTypePointer Input %v3uint
    %ptr_in_uint = OpTypePointer Input %uint
    %ptr_sb_uint = OpTypePointer StorageBuffer %uint
    %ptr_sb_float = OpTypePointer StorageBuffer %float
    %ptr_sb_v4float = OpTypePointer StorageBuffer %v4float
    %ptr_wg_uint = OpTypePointer Workgroup %uint
    %ptr_fn_uint = OpTypePointer Function %uint
    %ptr_pc_float = OpTypePointer PushConstant %float
    %ptr_pc_uint = OpTypePointer PushConstant %uint
    %u0 = OpConstant %uint 0
    %u1 = OpConstant %uint 1
    %u2 = OpConstant %uint 2
    %u3 = OpConstant %uint 3
    %u4 = OpConstant %uint 4
    %u10 = OpConstant %uint 10
    %u20 = OpConstant %uint 20
    %u30 = OpConstant %uint 30
    %u32 = OpConstant %uint 32
    %u64 = OpConstant %uint 64
    %f0 = OpConstant %float 0.0f
    %f1 = OpConstant %float 1.0f
    %f2 = OpConstant %float 2.0f
    """

  /// The bring-up shader as SPIR-V: each invocation stores its global invocation id at its own index.
  /// layout(local_size_x = 16) in;
  /// layout(set=0, binding=0) buffer B { uint data[]; };
  /// void main() { uint i = gl_GlobalInvocationID.x; data[i] = i; }
  public static let globalID = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 16 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %B 0 Offset 0
    OpDecorate %B Block
    OpDecorate %buf DescriptorSet 0
    OpDecorate %buf Binding 0
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %uarr = OpTypeRuntimeArray %uint
    %B = OpTypeStruct %uarr
    %ptr_sb_B = OpTypePointer StorageBuffer %B
    %buf = OpVariable %ptr_sb_B StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %px = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %px
    %p = OpAccessChain %ptr_sb_uint %buf %u0 %i
    OpStore %p %i
    OpReturn
    OpFunctionEnd
    """

  /// layout(local_size_x = 64) in;
  /// layout(set=0, binding=0) buffer B { uint data[]; };
  /// void main() { uint i = gl_GlobalInvocationID.x; data[i] = i * 3u + 1u; }
  public static let fill = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpName %main "main"
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %B 0 Offset 0
    OpDecorate %B Block
    OpDecorate %buf DescriptorSet 0
    OpDecorate %buf Binding 0
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %uarr = OpTypeRuntimeArray %uint
    %B = OpTypeStruct %uarr
    %ptr_sb_B = OpTypePointer StorageBuffer %B
    %buf = OpVariable %ptr_sb_B StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %px = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %px
    %m = OpIMul %uint %i %u3
    %v = OpIAdd %uint %m %u1
    %p = OpAccessChain %ptr_sb_uint %buf %u0 %i
    OpStore %p %v
    OpReturn
    OpFunctionEnd
    """

  /// layout(push_constant) uniform PC { float a; uint n; } pc;
  /// layout(set=0, binding=0) readonly buffer X { float x[]; };
  /// layout(set=0, binding=1) buffer Y { float y[]; };
  /// void main() { uint i = gl_GlobalInvocationID.x;
  ///   if (i < pc.n) y[i] = pc.a * x[i] + y[i]; }
  public static let saxpy = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpMemberDecorate %PC 0 Offset 0
    OpMemberDecorate %PC 1 Offset 4
    OpDecorate %PC Block
    OpDecorate %farr ArrayStride 4
    OpMemberDecorate %X 0 Offset 0
    OpMemberDecorate %X 0 NonWritable
    OpDecorate %X Block
    OpMemberDecorate %Y 0 Offset 0
    OpDecorate %Y Block
    OpDecorate %xv DescriptorSet 0
    OpDecorate %xv Binding 0
    OpDecorate %yv DescriptorSet 0
    OpDecorate %yv Binding 1
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %PC = OpTypeStruct %float %uint
    %ptr_pc_PC = OpTypePointer PushConstant %PC
    %pc = OpVariable %ptr_pc_PC PushConstant
    %farr = OpTypeRuntimeArray %float
    %X = OpTypeStruct %farr
    %Y = OpTypeStruct %farr
    %ptr_sb_X = OpTypePointer StorageBuffer %X
    %ptr_sb_Y = OpTypePointer StorageBuffer %Y
    %xv = OpVariable %ptr_sb_X StorageBuffer
    %yv = OpVariable %ptr_sb_Y StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %gp
    %pn = OpAccessChain %ptr_pc_uint %pc %u1
    %n = OpLoad %uint %pn
    %inb = OpULessThan %bool %i %n
    OpSelectionMerge %end None
    OpBranchConditional %inb %body %end
    %body = OpLabel
    %pa = OpAccessChain %ptr_pc_float %pc %u0
    %a = OpLoad %float %pa
    %px = OpAccessChain %ptr_sb_float %xv %u0 %i
    %xval = OpLoad %float %px
    %py = OpAccessChain %ptr_sb_float %yv %u0 %i
    %yval = OpLoad %float %py
    %ax = OpFMul %float %a %xval
    %r = OpFAdd %float %ax %yval
    OpStore %py %r
    OpBranch %end
    %end = OpLabel
    OpReturn
    OpFunctionEnd
    """

  /// A workgroup sum with shared memory and barriers.
  /// layout(local_size_x = 64) in;
  /// layout(set=0, binding=0) readonly buffer In { uint in_[]; };
  /// layout(set=0, binding=1) buffer Out { uint out_[]; };
  /// shared uint sh[64];
  /// void main() {
  ///   uint lid = gl_LocalInvocationID.x;
  ///   sh[lid] = in_[gl_GlobalInvocationID.x];
  ///   barrier();
  ///   for (uint s = 32; s > 0; s >>= 1) {
  ///     if (lid < s) sh[lid] += sh[lid + s];
  ///     barrier();
  ///   }
  ///   if (lid == 0) out_[gl_WorkGroupID.x] = sh[0];
  /// }
  public static let reduce = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid %lidv %widv
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %lidv BuiltIn LocalInvocationId
    OpDecorate %widv BuiltIn WorkgroupId
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %In 0 Offset 0
    OpDecorate %In Block
    OpMemberDecorate %Out 0 Offset 0
    OpDecorate %Out Block
    OpDecorate %inv DescriptorSet 0
    OpDecorate %inv Binding 0
    OpDecorate %outv DescriptorSet 0
    OpDecorate %outv Binding 1
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %lidv = OpVariable %ptr_in_v3uint Input
    %widv = OpVariable %ptr_in_v3uint Input
    %wg = OpConstant %uint 2
    %sem = OpConstant %uint 264
    %uarr = OpTypeRuntimeArray %uint
    %In = OpTypeStruct %uarr
    %Out = OpTypeStruct %uarr
    %ptr_sb_In = OpTypePointer StorageBuffer %In
    %ptr_sb_Out = OpTypePointer StorageBuffer %Out
    %inv = OpVariable %ptr_sb_In StorageBuffer
    %outv = OpVariable %ptr_sb_Out StorageBuffer
    %arr64 = OpTypeArray %uint %u64
    %ptr_wg_arr = OpTypePointer Workgroup %arr64
    %sh = OpVariable %ptr_wg_arr Workgroup
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %s = OpVariable %ptr_fn_uint Function
    %lp = OpAccessChain %ptr_in_uint %lidv %u0
    %lid = OpLoad %uint %lp
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %g = OpLoad %uint %gp
    %pin = OpAccessChain %ptr_sb_uint %inv %u0 %g
    %vin = OpLoad %uint %pin
    %psh = OpAccessChain %ptr_wg_uint %sh %lid
    OpStore %psh %vin
    OpControlBarrier %wg %wg %sem
    OpStore %s %u32
    OpBranch %head
    %head = OpLabel
    OpLoopMerge %merge %cont None
    OpBranch %cond
    %cond = OpLabel
    %sv = OpLoad %uint %s
    %gt = OpUGreaterThan %bool %sv %u0
    OpBranchConditional %gt %loopbody %merge
    %loopbody = OpLabel
    %sv2 = OpLoad %uint %s
    %lt = OpULessThan %bool %lid %sv2
    OpSelectionMerge %ifend None
    OpBranchConditional %lt %then %ifend
    %then = OpLabel
    %idx2 = OpIAdd %uint %lid %sv2
    %pa = OpAccessChain %ptr_wg_uint %sh %lid
    %pb = OpAccessChain %ptr_wg_uint %sh %idx2
    %va = OpLoad %uint %pa
    %vb = OpLoad %uint %pb
    %sum = OpIAdd %uint %va %vb
    OpStore %pa %sum
    OpBranch %ifend
    %ifend = OpLabel
    OpControlBarrier %wg %wg %sem
    OpBranch %cont
    %cont = OpLabel
    %sv4 = OpLoad %uint %s
    %sh1 = OpShiftRightLogical %uint %sv4 %u1
    OpStore %s %sh1
    OpBranch %head
    %merge = OpLabel
    %is0 = OpIEqual %bool %lid %u0
    OpSelectionMerge %fin None
    OpBranchConditional %is0 %w %fin
    %w = OpLabel
    %p0 = OpAccessChain %ptr_wg_uint %sh %u0
    %v0 = OpLoad %uint %p0
    %wp = OpAccessChain %ptr_in_uint %widv %u0
    %wid = OpLoad %uint %wp
    %po = OpAccessChain %ptr_sb_uint %outv %u0 %wid
    OpStore %po %v0
    OpBranch %fin
    %fin = OpLabel
    OpReturn
    OpFunctionEnd
    """

  /// A loop with a branch in it.
  /// void main() { uint g = gl_GlobalInvocationID.x; uint acc = 0;
  ///   for (uint i = 0; i < g; i++) { if ((i & 1) == 0) acc += i; else acc ^= i * 3; }
  ///   out_[g] = acc; }
  public static let loopsum = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %B 0 Offset 0
    OpDecorate %B Block
    OpDecorate %buf DescriptorSet 0
    OpDecorate %buf Binding 0
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %uarr = OpTypeRuntimeArray %uint
    %B = OpTypeStruct %uarr
    %ptr_sb_B = OpTypePointer StorageBuffer %B
    %buf = OpVariable %ptr_sb_B StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %acc = OpVariable %ptr_fn_uint Function
    %i = OpVariable %ptr_fn_uint Function
    %px = OpAccessChain %ptr_in_uint %gid %u0
    %gidv = OpLoad %uint %px
    OpStore %acc %u0
    OpStore %i %u0
    OpBranch %head
    %head = OpLabel
    OpLoopMerge %merge %cont None
    OpBranch %cond
    %cond = OpLabel
    %iv = OpLoad %uint %i
    %lt = OpULessThan %bool %iv %gidv
    OpBranchConditional %lt %body %merge
    %body = OpLabel
    %iv2 = OpLoad %uint %i
    %and = OpBitwiseAnd %uint %iv2 %u1
    %even = OpIEqual %bool %and %u0
    OpSelectionMerge %ifend None
    OpBranchConditional %even %then %else
    %then = OpLabel
    %a1 = OpLoad %uint %acc
    %a2 = OpIAdd %uint %a1 %iv2
    OpStore %acc %a2
    OpBranch %ifend
    %else = OpLabel
    %a3 = OpLoad %uint %acc
    %m3 = OpIMul %uint %iv2 %u3
    %a4 = OpBitwiseXor %uint %a3 %m3
    OpStore %acc %a4
    OpBranch %ifend
    %ifend = OpLabel
    OpBranch %cont
    %cont = OpLabel
    %iv3 = OpLoad %uint %i
    %inc = OpIAdd %uint %iv3 %u1
    OpStore %i %inc
    OpBranch %head
    %merge = OpLabel
    %res = OpLoad %uint %acc
    %po = OpAccessChain %ptr_sb_uint %buf %u0 %gidv
    OpStore %po %res
    OpReturn
    OpFunctionEnd
    """

  /// Vectors and extended instructions.
  /// layout(set=0, binding=0) readonly buffer In { vec4 in_[]; };
  /// layout(set=0, binding=1) buffer Out { vec4 out_[]; };
  /// void main() { uint i = gl_GlobalInvocationID.x; vec4 a = in_[i];
  ///   out_[i] = vec4(sqrt(dot(a, a)), min(a.x, a.y), abs(a.z), clamp(a.w, 0.0, 1.0)); }
  public static let vec = """
    OpCapability Shader
    %glsl = OpExtInstImport "GLSL.std.450"
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
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
    \(prelude)
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
    %p = OpAccessChain %ptr_sb_v4float %inv %u0 %i
    %a = OpLoad %v4float %p
    %d = OpDot %float %a %a
    %s = OpExtInst %float %glsl 31 %d
    %ax = OpCompositeExtract %float %a 0
    %ay = OpCompositeExtract %float %a 1
    %az = OpCompositeExtract %float %a 2
    %aw = OpCompositeExtract %float %a 3
    %mn = OpExtInst %float %glsl 37 %ax %ay
    %ab = OpExtInst %float %glsl 4 %az
    %cl = OpExtInst %float %glsl 43 %aw %f0 %f1
    %r = OpCompositeConstruct %v4float %s %mn %ab %cl
    %q = OpAccessChain %ptr_sb_v4float %outv %u0 %i
    OpStore %q %r
    OpReturn
    OpFunctionEnd
    """

  /// The GLSL.std.450 instructions the lowering knows, one result each:
  /// out_f[i * 22 + k] and out_u[i * 5 + k] for the instruction named in
  /// `mathFloat` and `mathInt`, from x = in_[i] (float) and i.
  public static let mathFloat: [(name: String, ext: Int, args: String)] = [
    ("FAbs", 4, "%nx"), ("FMin", 37, "%x %f1"), ("FMax", 40, "%x %f1"), ("FClamp", 43, "%x %q75 %q125"),
    ("Floor", 8, "%x3"), ("Fract", 10, "%x3"), ("Sqrt", 31, "%x"), ("InverseSqrt", 32, "%x"),
    ("Exp2", 29, "%x"), ("Log2", 30, "%x"), ("Pow", 26, "%x %c25"), ("Sin", 13, "%x"), ("Cos", 14, "%x"),
    ("Fma", 50, "%x %x %f1"), ("FMix", 46, "%x %f2 %q25"), ("Step", 48, "%f1 %x"), ("Exp", 27, "%x"),
    ("Log", 28, "%x"), ("SmoothStep", 49, "%q5 %q15 %x"), ("Ceil", 9, "%x3"), ("Trunc", 3, "%nx3"),
    ("RoundEven", 2, "%x3"),
  ]
  public static let mathInt: [(name: String, ext: Int, args: String)] = [
    ("SAbs", 5, "%si"), ("SMin", 39, "%si %s2"), ("UMax", 41, "%i %u7"), ("UClamp", 44, "%i %u3 %u9"),
    ("SSign", 7, "%si"),
  ]

  public static var math: String {
    var t = """
      OpCapability Shader
      %glsl = OpExtInstImport "GLSL.std.450"
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 64 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %farr ArrayStride 4
      OpDecorate %uarr ArrayStride 4
      OpMemberDecorate %In 0 Offset 0
      OpDecorate %In Block
      OpMemberDecorate %OutF 0 Offset 0
      OpDecorate %OutF Block
      OpMemberDecorate %OutU 0 Offset 0
      OpDecorate %OutU Block
      OpDecorate %inv DescriptorSet 0
      OpDecorate %inv Binding 0
      OpDecorate %outf DescriptorSet 0
      OpDecorate %outf Binding 1
      OpDecorate %outu DescriptorSet 0
      OpDecorate %outu Binding 2
      \(prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %farr = OpTypeRuntimeArray %float
      %uarr = OpTypeRuntimeArray %uint
      %In = OpTypeStruct %farr
      %OutF = OpTypeStruct %farr
      %OutU = OpTypeStruct %uarr
      %ptr_sb_In = OpTypePointer StorageBuffer %In
      %ptr_sb_OutF = OpTypePointer StorageBuffer %OutF
      %ptr_sb_OutU = OpTypePointer StorageBuffer %OutU
      %inv = OpVariable %ptr_sb_In StorageBuffer
      %outf = OpVariable %ptr_sb_OutF StorageBuffer
      %outu = OpVariable %ptr_sb_OutU StorageBuffer
      %q25 = OpConstant %float 0.25f
      %q5 = OpConstant %float 0.5f
      %q75 = OpConstant %float 0.75f
      %q125 = OpConstant %float 1.25f
      %q15 = OpConstant %float 1.5f
      %c25 = OpConstant %float 2.5f
      %f3 = OpConstant %float 3.0f
      %s2 = OpConstant %int 2
      %s5 = OpConstant %int 5
      %u7 = OpConstant %uint 7
      %u9 = OpConstant %uint 9
      %n22 = OpConstant %uint 22
      %n5 = OpConstant %uint 5
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %gp = OpAccessChain %ptr_in_uint %gid %u0
      %i = OpLoad %uint %gp
      %px = OpAccessChain %ptr_sb_float %inv %u0 %i
      %x = OpLoad %float %px
      %nx = OpFNegate %float %x
      %x3 = OpFMul %float %x %f3
      %nx3 = OpFNegate %float %x3
      %ii = OpBitcast %int %i
      %si = OpISub %int %ii %s5
      %base = OpIMul %uint %i %n22
      %ubase = OpIMul %uint %i %n5

      """
    for (k, m) in mathFloat.enumerated() {
      t += "%rf\(k) = OpExtInst %float %glsl \(m.ext) \(m.args)\n"
      t += "%kf\(k) = OpIAdd %uint %base %k\(k)\n"
      t += "%pf\(k) = OpAccessChain %ptr_sb_float %outf %u0 %kf\(k)\n"
      t += "OpStore %pf\(k) %rf\(k)\n"
    }
    for (k, m) in mathInt.enumerated() {
      let ty = m.name.hasPrefix("S") ? "%int" : "%uint"
      t += "%ru\(k) = OpExtInst \(ty) %glsl \(m.ext) \(m.args)\n"
      t += "%rb\(k) = OpBitcast %uint %ru\(k)\n"
      t += "%ku\(k) = OpIAdd %uint %ubase %k\(k)\n"
      t += "%pu\(k) = OpAccessChain %ptr_sb_uint %outu %u0 %ku\(k)\n"
      t += "OpStore %pu\(k) %rb\(k)\n"
    }
    t += "OpReturn\nOpFunctionEnd\n"
    // The offsets 0 ... 21 as constants.
    var consts = ""
    for k in 0..<22 { consts += "%k\(k) = OpConstant %uint \(k)\n" }
    return t.replacingOccurrences(of: "%main = OpFunction %void None %fn", with: consts + "%main = OpFunction %void None %fn")
  }

  /// An atomic counter and a switch.
  /// layout(set=0, binding=0) buffer C { uint cnt; uint ord[]; };
  /// layout(set=0, binding=1) buffer O { uint out_[]; };
  /// void main() { uint i = gl_GlobalInvocationID.x; ord[i] = atomicAdd(cnt, 1u);
  ///   uint x; switch (i & 3u) { case 0u: x = 10u; break; case 1u: x = 20u; break; default: x = 30u; }
  ///   out_[i] = x; }
  public static let atomics = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %C 0 Offset 0
    OpMemberDecorate %C 1 Offset 4
    OpDecorate %C Block
    OpMemberDecorate %O 0 Offset 0
    OpDecorate %O Block
    OpDecorate %cv DescriptorSet 0
    OpDecorate %cv Binding 0
    OpDecorate %ov DescriptorSet 0
    OpDecorate %ov Binding 1
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %uarr = OpTypeRuntimeArray %uint
    %C = OpTypeStruct %uint %uarr
    %O = OpTypeStruct %uarr
    %ptr_sb_C = OpTypePointer StorageBuffer %C
    %ptr_sb_O = OpTypePointer StorageBuffer %O
    %cv = OpVariable %ptr_sb_C StorageBuffer
    %ov = OpVariable %ptr_sb_O StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %gp
    %pc = OpAccessChain %ptr_sb_uint %cv %u0
    %old = OpAtomicIAdd %uint %pc %u1 %u0 %u1
    %po = OpAccessChain %ptr_sb_uint %cv %u1 %i
    OpStore %po %old
    %sel = OpBitwiseAnd %uint %i %u3
    OpSelectionMerge %swend None
    OpSwitch %sel %swdef 0 %c0 1 %c1
    %c0 = OpLabel
    OpBranch %swend
    %c1 = OpLabel
    OpBranch %swend
    %swdef = OpLabel
    OpBranch %swend
    %swend = OpLabel
    %x = OpPhi %uint %u10 %c0 %u20 %c1 %u30 %swdef
    %pq = OpAccessChain %ptr_sb_uint %ov %u0 %i
    OpStore %pq %x
    OpReturn
    OpFunctionEnd
    """

  /// A specialization constant, one made with an operation, and 64-bit integers.
  /// layout(constant_id = 0) const uint K = 5; layout(constant_id = 1) const bool ZERO = false;
  /// void main() { uint i = gl_GlobalInvocationID.x;
  ///   uint r = uint(uint64_t(i) * uint64_t(K + 1u)); out_[i] = ZERO ? 0u : r; }
  public static let spec64 = """
    OpCapability Shader
    OpCapability Int64
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %K SpecId 0
    OpDecorate %ZERO SpecId 1
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %O 0 Offset 0
    OpDecorate %O Block
    OpDecorate %ov DescriptorSet 0
    OpDecorate %ov Binding 0
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %ulong = OpTypeInt 64 0
    %K = OpSpecConstant %uint 5
    %ZERO = OpSpecConstantFalse %bool
    %K1 = OpSpecConstantOp %uint 128 %K %u1
    %uarr = OpTypeRuntimeArray %uint
    %O = OpTypeStruct %uarr
    %ptr_sb_O = OpTypePointer StorageBuffer %O
    %ov = OpVariable %ptr_sb_O StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %gp
    %iw = OpUConvert %ulong %i
    %kw = OpUConvert %ulong %K1
    %pr = OpIMul %ulong %iw %kw
    %r = OpUConvert %uint %pr
    %res = OpSelect %uint %ZERO %u0 %r
    %pq = OpAccessChain %ptr_sb_uint %ov %u0 %i
    OpStore %pq %res
    OpReturn
    OpFunctionEnd
    """

  /// Calls.
  /// uint helper(uint a, uint b) { return a * b + 1u; }
  /// void main() { uint i = gl_GlobalInvocationID.x; out_[i] = helper(helper(i, 3u), i); }
  public static let calls = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %O 0 Offset 0
    OpDecorate %O Block
    OpDecorate %ov DescriptorSet 0
    OpDecorate %ov Binding 0
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %uarr = OpTypeRuntimeArray %uint
    %O = OpTypeStruct %uarr
    %ptr_sb_O = OpTypePointer StorageBuffer %O
    %ov = OpVariable %ptr_sb_O StorageBuffer
    %fn_uu = OpTypeFunction %uint %uint %uint
    %helper = OpFunction %uint None %fn_uu
    %a = OpFunctionParameter %uint
    %b = OpFunctionParameter %uint
    %hentry = OpLabel
    %m = OpIMul %uint %a %b
    %r = OpIAdd %uint %m %u1
    OpReturnValue %r
    OpFunctionEnd
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %gp
    %c1 = OpFunctionCall %uint %helper %i %u3
    %c2 = OpFunctionCall %uint %helper %c1 %i
    %pq = OpAccessChain %ptr_sb_uint %ov %u0 %i
    OpStore %pq %c2
    OpReturn
    OpFunctionEnd
    """

  /// A local array indexed dynamically, and a local struct indexed by constants.
  /// struct S { uint a; float b; };
  /// void main() { uint i = gl_GlobalInvocationID.x; uint arr[4]; S s;
  ///   arr[0] = i; arr[1] = i + 1u; arr[2] = i * 2u; arr[3] = 7u;
  ///   s.a = i; s.b = float(i) * 0.5;
  ///   out_[i] = arr[i & 3u] + arr[(i + 1u) & 3u] + s.a + uint(s.b); }
  public static let locals = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize 64 1 1
    OpDecorate %gid BuiltIn GlobalInvocationId
    OpDecorate %uarr ArrayStride 4
    OpMemberDecorate %O 0 Offset 0
    OpDecorate %O Block
    OpDecorate %ov DescriptorSet 0
    OpDecorate %ov Binding 0
    \(prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %uarr = OpTypeRuntimeArray %uint
    %O = OpTypeStruct %uarr
    %ptr_sb_O = OpTypePointer StorageBuffer %O
    %ov = OpVariable %ptr_sb_O StorageBuffer
    %arr4 = OpTypeArray %uint %u4
    %ptr_fn_arr4 = OpTypePointer Function %arr4
    %S = OpTypeStruct %uint %float
    %ptr_fn_S = OpTypePointer Function %S
    %ptr_fn_float = OpTypePointer Function %float
    %fhalf = OpConstant %float 0.5f
    %u7 = OpConstant %uint 7
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %arr = OpVariable %ptr_fn_arr4 Function
    %s = OpVariable %ptr_fn_S Function
    %gp = OpAccessChain %ptr_in_uint %gid %u0
    %i = OpLoad %uint %gp
    %a0 = OpAccessChain %ptr_fn_uint %arr %u0
    OpStore %a0 %i
    %a1 = OpAccessChain %ptr_fn_uint %arr %u1
    %i1 = OpIAdd %uint %i %u1
    OpStore %a1 %i1
    %a2 = OpAccessChain %ptr_fn_uint %arr %u2
    %i2 = OpIMul %uint %i %u2
    OpStore %a2 %i2
    %a3 = OpAccessChain %ptr_fn_uint %arr %u3
    OpStore %a3 %u7
    %sa = OpAccessChain %ptr_fn_uint %s %u0
    OpStore %sa %i
    %sb = OpAccessChain %ptr_fn_float %s %u1
    %fi = OpConvertUToF %float %i
    %hb = OpFMul %float %fi %fhalf
    OpStore %sb %hb
    %k0 = OpBitwiseAnd %uint %i %u3
    %k1x = OpIAdd %uint %i %u1
    %k1 = OpBitwiseAnd %uint %k1x %u3
    %pk0 = OpAccessChain %ptr_fn_uint %arr %k0
    %pk1 = OpAccessChain %ptr_fn_uint %arr %k1
    %v0 = OpLoad %uint %pk0
    %v1 = OpLoad %uint %pk1
    %sv = OpLoad %uint %sa
    %fb = OpLoad %float %sb
    %ub = OpConvertFToU %uint %fb
    %t0 = OpIAdd %uint %v0 %v1
    %t1 = OpIAdd %uint %t0 %sv
    %t2 = OpIAdd %uint %t1 %ub
    %pq = OpAccessChain %ptr_sb_uint %ov %u0 %i
    OpStore %pq %t2
    OpReturn
    OpFunctionEnd
    """

  // MARK: vertex and fragment shaders

  /// The types the graphics shaders share.
  public static let graphicsPrelude = """
    %void = OpTypeVoid
    %fn = OpTypeFunction %void
    %bool = OpTypeBool
    %uint = OpTypeInt 32 0
    %int = OpTypeInt 32 1
    %float = OpTypeFloat 32
    %v2float = OpTypeVector %float 2
    %v4float = OpTypeVector %float 4
    %i0 = OpConstant %int 0
    %i1 = OpConstant %int 1
    %f0 = OpConstant %float 0.0f
    %f1 = OpConstant %float 1.0f
    %fhalf = OpConstant %float 0.5f
    %ptr_out_v4 = OpTypePointer Output %v4float
    %ptr_in_int = OpTypePointer Input %int
    %ptr_in_v4 = OpTypePointer Input %v4float
    """

  /// The triangle's position shader: the clip position of each vertex read through the root pointer, which is the
  /// first push constant (Loinnir's pipeline layout, D174 section 1).
  /// layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Positions { vec4 p[]; };
  /// layout(push_constant) uniform Root { Positions positions; } root;
  /// void main() { gl_Position = root.positions.p[gl_VertexIndex]; }
  public static let triangleVertex = """
    OpCapability Shader
    OpCapability PhysicalStorageBufferAddresses
    OpMemoryModel PhysicalStorageBuffer64 GLSL450
    OpEntryPoint Vertex %main "main" %out %vidx
    OpDecorate %vidx BuiltIn VertexIndex
    OpMemberDecorate %PerVertex 0 BuiltIn Position
    OpDecorate %PerVertex Block
    OpDecorate %parr ArrayStride 16
    OpMemberDecorate %Positions 0 Offset 0
    OpDecorate %Positions Block
    OpMemberDecorate %Root 0 Offset 0
    OpDecorate %Root Block
    OpTypeForwardPointer %ptr_psb_Positions PhysicalStorageBuffer
    \(graphicsPrelude)
    %PerVertex = OpTypeStruct %v4float
    %ptr_out_PerVertex = OpTypePointer Output %PerVertex
    %out = OpVariable %ptr_out_PerVertex Output
    %vidx = OpVariable %ptr_in_int Input
    %parr = OpTypeRuntimeArray %v4float
    %Positions = OpTypeStruct %parr
    %ptr_psb_Positions = OpTypePointer PhysicalStorageBuffer %Positions
    %Root = OpTypeStruct %ptr_psb_Positions
    %ptr_pc_Root = OpTypePointer PushConstant %Root
    %root = OpVariable %ptr_pc_Root PushConstant
    %ptr_pc_psb = OpTypePointer PushConstant %ptr_psb_Positions
    %ptr_psb_v4 = OpTypePointer PhysicalStorageBuffer %v4float
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %pp = OpAccessChain %ptr_pc_psb %root %i0
    %positions = OpLoad %ptr_psb_Positions %pp
    %idx = OpLoad %int %vidx
    %ep = OpAccessChain %ptr_psb_v4 %positions %i0 %idx
    %pos = OpLoad %v4float %ep Aligned 16
    %gp = OpAccessChain %ptr_out_v4 %out %i0
    OpStore %gp %pos
    OpReturn
    OpFunctionEnd
    """

  /// layout(location = 0) out vec4 outColor;
  /// void main() { outColor = vec4(1.0, 0.5, 0.0, 1.0); }
  public static let triangleFragment = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Fragment %main "main" %col
    OpExecutionMode %main OriginUpperLeft
    OpDecorate %col Location 0
    \(graphicsPrelude)
    %col = OpVariable %ptr_out_v4 Output
    %c = OpConstantComposite %v4float %f1 %fhalf %f0 %f1
    %main = OpFunction %void None %fn
    %entry = OpLabel
    OpStore %col %c
    OpReturn
    OpFunctionEnd
    """

  /// Loinnir's triangle.vert: a vertex of a position and a colour, read through the root pointer, the colour a varying.
  /// struct Vertex { vec2 position; vec4 color; };   // std430: 32 bytes
  /// layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Vertices { Vertex v[]; };
  /// layout(push_constant) uniform Root { Vertices vertices; } root;
  /// layout(location = 0) out vec4 color;
  /// void main() { Vertex v = root.vertices.v[gl_VertexIndex];
  ///   gl_Position = vec4(v.position, 0.0, 1.0); color = v.color; }
  public static let varyingVertex = """
    OpCapability Shader
    OpCapability PhysicalStorageBufferAddresses
    OpMemoryModel PhysicalStorageBuffer64 GLSL450
    OpEntryPoint Vertex %main "main" %out %vidx %color
    OpDecorate %vidx BuiltIn VertexIndex
    OpDecorate %color Location 0
    OpMemberDecorate %PerVertex 0 BuiltIn Position
    OpDecorate %PerVertex Block
    OpMemberDecorate %Vertex 0 Offset 0
    OpMemberDecorate %Vertex 1 Offset 16
    OpDecorate %varr ArrayStride 32
    OpMemberDecorate %Vertices 0 Offset 0
    OpDecorate %Vertices Block
    OpMemberDecorate %Root 0 Offset 0
    OpDecorate %Root Block
    OpTypeForwardPointer %ptr_psb_Vertices PhysicalStorageBuffer
    \(graphicsPrelude)
    %PerVertex = OpTypeStruct %v4float
    %ptr_out_PerVertex = OpTypePointer Output %PerVertex
    %out = OpVariable %ptr_out_PerVertex Output
    %color = OpVariable %ptr_out_v4 Output
    %vidx = OpVariable %ptr_in_int Input
    %Vertex = OpTypeStruct %v2float %v4float
    %varr = OpTypeRuntimeArray %Vertex
    %Vertices = OpTypeStruct %varr
    %ptr_psb_Vertices = OpTypePointer PhysicalStorageBuffer %Vertices
    %Root = OpTypeStruct %ptr_psb_Vertices
    %ptr_pc_Root = OpTypePointer PushConstant %Root
    %root = OpVariable %ptr_pc_Root PushConstant
    %ptr_pc_psb = OpTypePointer PushConstant %ptr_psb_Vertices
    %ptr_psb_v2 = OpTypePointer PhysicalStorageBuffer %v2float
    %ptr_psb_v4 = OpTypePointer PhysicalStorageBuffer %v4float
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %pp = OpAccessChain %ptr_pc_psb %root %i0
    %vertices = OpLoad %ptr_psb_Vertices %pp
    %idx = OpLoad %int %vidx
    %pxy = OpAccessChain %ptr_psb_v2 %vertices %i0 %idx %i0
    %xy = OpLoad %v2float %pxy Aligned 16
    %pc = OpAccessChain %ptr_psb_v4 %vertices %i0 %idx %i1
    %c = OpLoad %v4float %pc Aligned 16
    %x = OpCompositeExtract %float %xy 0
    %y = OpCompositeExtract %float %xy 1
    %pos = OpCompositeConstruct %v4float %x %y %f0 %f1
    %gp = OpAccessChain %ptr_out_v4 %out %i0
    OpStore %gp %pos
    OpStore %color %c
    OpReturn
    OpFunctionEnd
    """

  /// layout(location = 0) in vec4 color; layout(location = 0) out vec4 outColor;
  /// void main() { outColor = color; }
  public static let varyingFragment = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Fragment %main "main" %col %in
    OpExecutionMode %main OriginUpperLeft
    OpDecorate %col Location 0
    OpDecorate %in Location 0
    \(graphicsPrelude)
    %col = OpVariable %ptr_out_v4 Output
    %in = OpVariable %ptr_in_v4 Input
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %c = OpLoad %v4float %in
    OpStore %col %c
    OpReturn
    OpFunctionEnd
    """

  /// A fragment shader that reads a no-perspective vec2, a flat uint, the window position and the facing, discards
  /// the first column of pixels and writes two colour targets.
  /// layout(location = 0) noperspective in vec2 uv; layout(location = 1) flat in uint id;
  /// layout(location = 0) out vec4 c0; layout(location = 1) out vec4 c1;
  /// void main() {
  ///   if (gl_FragCoord.x < 1.0) discard;
  ///   c0 = vec4(uv, gl_FragCoord.z * gl_FragCoord.w, gl_FrontFacing ? 1.0 : 0.0);
  ///   c1 = vec4(float(id)); }
  public static let fragmentFeatures = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Fragment %main "main" %c0 %c1 %uv %id %fc %ff
    OpExecutionMode %main OriginUpperLeft
    OpDecorate %c0 Location 0
    OpDecorate %c1 Location 1
    OpDecorate %uv Location 0
    OpDecorate %uv NoPerspective
    OpDecorate %id Location 1
    OpDecorate %id Flat
    OpDecorate %fc BuiltIn FragCoord
    OpDecorate %ff BuiltIn FrontFacing
    \(graphicsPrelude)
    %ptr_out_v4b = OpTypePointer Output %v4float
    %ptr_in_v2 = OpTypePointer Input %v2float
    %ptr_in_uint = OpTypePointer Input %uint
    %ptr_in_bool = OpTypePointer Input %bool
    %ptr_in_float = OpTypePointer Input %float
    %u0 = OpConstant %uint 0
    %u2 = OpConstant %uint 2
    %u3 = OpConstant %uint 3
    %c0 = OpVariable %ptr_out_v4 Output
    %c1 = OpVariable %ptr_out_v4b Output
    %uv = OpVariable %ptr_in_v2 Input
    %id = OpVariable %ptr_in_uint Input
    %fc = OpVariable %ptr_in_v4 Input
    %ff = OpVariable %ptr_in_bool Input
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %pfx = OpAccessChain %ptr_in_float %fc %u0
    %fx = OpLoad %float %pfx
    %first = OpFOrdLessThan %bool %fx %f1
    OpSelectionMerge %cont None
    OpBranchConditional %first %kill %cont
    %kill = OpLabel
    OpKill
    %cont = OpLabel
    %uvv = OpLoad %v2float %uv
    %pfz = OpAccessChain %ptr_in_float %fc %u2
    %fz = OpLoad %float %pfz
    %pfw = OpAccessChain %ptr_in_float %fc %u3
    %fw = OpLoad %float %pfw
    %zw = OpFMul %float %fz %fw
    %front = OpLoad %bool %ff
    %facing = OpSelect %float %front %f1 %f0
    %u = OpCompositeExtract %float %uvv 0
    %v = OpCompositeExtract %float %uvv 1
    %col0 = OpCompositeConstruct %v4float %u %v %zw %facing
    OpStore %c0 %col0
    %idv = OpLoad %uint %id
    %idf = OpConvertUToF %float %idv
    %col1 = OpCompositeConstruct %v4float %idf %idf %idf %idf
    OpStore %c1 %col1
    OpReturn
    OpFunctionEnd
    """

  /// A vertex shader with attributes, the instance index, a point size, a component of the position written on its own
  /// and a flat integer varying; the gl_PerVertex block declares the clip and cull distances too, as glslang's does.
  /// layout(location = 0) in vec2 inPos; layout(location = 1) in vec4 inColor;
  /// layout(location = 0) out vec4 color; layout(location = 1) flat out uint instance;
  /// void main() { gl_Position = vec4(inPos, 0.0, 1.0); gl_Position.y = -gl_Position.y; gl_PointSize = 4.0;
  ///   color = inColor; instance = uint(gl_InstanceIndex); }
  public static let vertexFeatures = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Vertex %main "main" %out %inPos %inColor %color %instance %iidx
    OpDecorate %iidx BuiltIn InstanceIndex
    OpMemberDecorate %PerVertex 0 BuiltIn Position
    OpMemberDecorate %PerVertex 1 BuiltIn PointSize
    OpMemberDecorate %PerVertex 2 BuiltIn ClipDistance
    OpMemberDecorate %PerVertex 3 BuiltIn CullDistance
    OpDecorate %PerVertex Block
    OpDecorate %inPos Location 0
    OpDecorate %inColor Location 1
    OpDecorate %color Location 0
    OpDecorate %instance Location 1
    OpDecorate %instance Flat
    \(graphicsPrelude)
    %u1 = OpConstant %uint 1
    %f4 = OpConstant %float 4.0f
    %carr = OpTypeArray %float %u1
    %PerVertex = OpTypeStruct %v4float %float %carr %carr
    %ptr_out_PerVertex = OpTypePointer Output %PerVertex
    %ptr_out_float = OpTypePointer Output %float
    %ptr_out_uint = OpTypePointer Output %uint
    %ptr_in_v2 = OpTypePointer Input %v2float
    %out = OpVariable %ptr_out_PerVertex Output
    %inPos = OpVariable %ptr_in_v2 Input
    %inColor = OpVariable %ptr_in_v4 Input
    %color = OpVariable %ptr_out_v4 Output
    %instance = OpVariable %ptr_out_uint Output
    %iidx = OpVariable %ptr_in_int Input
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %xy = OpLoad %v2float %inPos
    %x = OpCompositeExtract %float %xy 0
    %y = OpCompositeExtract %float %xy 1
    %pos = OpCompositeConstruct %v4float %x %y %f0 %f1
    %pp = OpAccessChain %ptr_out_v4 %out %i0
    OpStore %pp %pos
    %py = OpAccessChain %ptr_out_float %out %i0 %i1
    %ny = OpFNegate %float %y
    OpStore %py %ny
    %ps = OpAccessChain %ptr_out_float %out %i1
    OpStore %ps %f4
    %c = OpLoad %v4float %inColor
    OpStore %color %c
    %ii = OpLoad %int %iidx
    %iu = OpBitcast %uint %ii
    OpStore %instance %iu
    OpReturn
    OpFunctionEnd
    """
  // MARK: images

  /// A fetch from a plain image (no sampler) at a level other than zero.
  /// layout(set = 0, binding = 0) uniform texture2D tex; layout(location = 0) flat in ivec2 at;
  /// layout(location = 0) out vec4 outColor;
  /// void main() { outColor = texelFetch(tex, at, 2); }
  public static let plainFetch = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Fragment %main "main" %col %at
    OpExecutionMode %main OriginUpperLeft
    OpDecorate %col Location 0
    OpDecorate %at Location 0
    OpDecorate %at Flat
    OpDecorate %tex DescriptorSet 0
    OpDecorate %tex Binding 0
    \(graphicsPrelude)
    %v2int = OpTypeVector %int 2
    %img = OpTypeImage %float 1 0 0 0 1 0
    %ptr_uc_img = OpTypePointer UniformConstant %img
    %ptr_in_v2int = OpTypePointer Input %v2int
    %tex = OpVariable %ptr_uc_img UniformConstant
    %at = OpVariable %ptr_in_v2int Input
    %col = OpVariable %ptr_out_v4 Output
    %lvl = OpConstant %int 2
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %image = OpLoad %img %tex
    %coord = OpLoad %v2int %at
    %t = OpImageFetch %v4float %image %coord 2 %lvl
    OpStore %col %t
    OpReturn
    OpFunctionEnd
    """

  /// A vertex shader that samples, which the compiler refuses: the heap's handles are a fragment stage's.
  public static let vertexSample = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Vertex %main "main" %out
    OpMemberDecorate %PerVertex 0 BuiltIn Position
    OpDecorate %PerVertex Block
    OpDecorate %tex DescriptorSet 0
    OpDecorate %tex Binding 0
    OpDecorate %smp DescriptorSet 0
    OpDecorate %smp Binding 1
    \(graphicsPrelude)
    %PerVertex = OpTypeStruct %v4float
    %ptr_out_PerVertex = OpTypePointer Output %PerVertex
    %out = OpVariable %ptr_out_PerVertex Output
    %img = OpTypeImage %float 1 0 0 0 1 0
    %samp = OpTypeSampler
    %simg = OpTypeSampledImage %img
    %ptr_uc_img = OpTypePointer UniformConstant %img
    %ptr_uc_samp = OpTypePointer UniformConstant %samp
    %tex = OpVariable %ptr_uc_img UniformConstant
    %smp = OpVariable %ptr_uc_samp UniformConstant
    %c = OpConstantComposite %v2float %f0 %f0
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %image = OpLoad %img %tex
    %sampler = OpLoad %samp %smp
    %si = OpSampledImage %simg %image %sampler
    %t = OpImageSampleExplicitLod %v4float %si %c 2 %f0
    %gp = OpAccessChain %ptr_out_v4 %out %i0
    OpStore %gp %t
    OpReturn
    OpFunctionEnd
    """
  /// A fragment shader that shows its texture coordinates: red the first, green the second. The board's first look at
  /// a varying that is interpolated.
  /// layout(location = 0) in vec2 uv; layout(location = 0) out vec4 outColor;
  /// void main() { outColor = vec4(uv, 0.0, 1.0); }
  public static let uvFragment = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Fragment %main "main" %col %in
    OpExecutionMode %main OriginUpperLeft
    OpDecorate %col Location 0
    OpDecorate %in Location 0
    \(graphicsPrelude)
    %ptr_in_v2 = OpTypePointer Input %v2float
    %col = OpVariable %ptr_out_v4 Output
    %in = OpVariable %ptr_in_v2 Input
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %uv = OpLoad %v2float %in
    %u = OpCompositeExtract %float %uv 0
    %v = OpCompositeExtract %float %uv 1
    %c = OpCompositeConstruct %v4float %u %v %f0 %f1
    OpStore %col %c
    OpReturn
    OpFunctionEnd
    """
}
