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
}
