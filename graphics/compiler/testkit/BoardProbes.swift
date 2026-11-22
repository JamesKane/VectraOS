// SPDX-License-Identifier: BSD-3-Clause

// The SPIR-V of gpu-test's hardware probes (drivers/gpu/tests/native, HardwareProbes.swift): shaders whose results on the
// board are reported, not judged. They are compiled on the device like the rest of gpu-test's (CompilerShaders.swift is
// generated from them). Each says in its comment the question it asks of the hardware.

public enum BoardProbes {
  private static func head(_ extra: String = "", size: String = "64 1 1") -> String {
    """
    OpCapability Shader
    \(extra)
    OpMemoryModel Logical GLSL450
    OpEntryPoint GLCompute %main "main" %gid
    OpExecutionMode %main LocalSize \(size)
    OpDecorate %gid BuiltIn GlobalInvocationId
    """
  }

  /// A contended compare-exchange loop on a float: every invocation of the grid adds 1.0 to one counter (binding 0, word
  /// 0), which the backend does as a loop on the word (the hardware has no float atomic). Exact up to 2^24.
  public static let contendedFloatAdd = """
    \(head("OpCapability AtomicFloat32AddEXT"))
    OpMemberDecorate %A 0 Offset 0
    OpDecorate %A Block
    OpDecorate %av DescriptorSet 0
    OpDecorate %av Binding 0
    \(Corpus.prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %A = OpTypeStruct %float
    %ptr_A = OpTypePointer StorageBuffer %A
    %av = OpVariable %ptr_A StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %p = OpAccessChain %ptr_sb_float %av %u0
    %old = OpAtomicFAddEXT %float %p %u1 %u0 %f1
    OpReturn
    OpFunctionEnd
    """

  /// The same with a 16-bit integer: every invocation adds 1 to the low half of word 0, a loop on the containing word.
  public static let contendedHalfAdd = """
    \(head("OpCapability Int16\nOpCapability StorageBuffer16BitAccess"))
    OpDecorate %arr ArrayStride 2
    OpMemberDecorate %A 0 Offset 0
    OpDecorate %A Block
    OpDecorate %av DescriptorSet 0
    OpDecorate %av Binding 0
    \(Corpus.prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %t = OpTypeInt 16 0
    %one = OpConstant %t 1
    %arr = OpTypeRuntimeArray %t
    %A = OpTypeStruct %arr
    %ptr_A = OpTypePointer StorageBuffer %A
    %ptr_el = OpTypePointer StorageBuffer %t
    %av = OpVariable %ptr_A StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %p = OpAccessChain %ptr_el %av %u0 %u0
    %old = OpAtomicIAdd %t %p %u1 %u0 %one
    OpReturn
    OpFunctionEnd
    """

  /// The control: the hardware's own atomic add on a 32-bit counter, contended the same way.
  public static let contendedWordAdd = """
    \(head())
    OpMemberDecorate %A 0 Offset 0
    OpDecorate %A Block
    OpDecorate %av DescriptorSet 0
    OpDecorate %av Binding 0
    \(Corpus.prelude)
    %gid = OpVariable %ptr_in_v3uint Input
    %A = OpTypeStruct %uint
    %ptr_A = OpTypePointer StorageBuffer %A
    %av = OpVariable %ptr_A StorageBuffer
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %p = OpAccessChain %ptr_sb_uint %av %u0
    %old = OpAtomicIAdd %uint %p %u1 %u0 %u1
    OpReturn
    OpFunctionEnd
    """

  /// Stores of integers into a one-channel integer storage image: invocation i stores word i of the buffer (binding 0) at
  /// texel (i, 0) of the image (binding 1). The question is what the conversion does to a value the format can't hold
  /// (saturate or wrap), and whether the 8 and 16-bit signed formats store a value they can hold exactly (`ST_CVT` with the
  /// register format `auto32`). `spirvFormat` is SPIR-V's image format number: R8i 29, R8ui 39, R16i 28, R16ui 38.
  public static func integerImageStore(spirvFormat: Int, signed: Bool) -> String {
    let st = signed ? "int" : "uint"
    return """
      \(head("OpCapability StorageImageExtendedFormats", size: "16 1 1"))
      OpDecorate %uarr ArrayStride 4
      OpMemberDecorate %B 0 Offset 0
      OpDecorate %B Block
      OpDecorate %buf DescriptorSet 0
      OpDecorate %buf Binding 0
      OpDecorate %img DescriptorSet 0
      OpDecorate %img Binding 1
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %v2int = OpTypeVector %int 2
      %v4\(st) = OpTypeVector %\(st) 4
      %i0 = OpConstant %int 0
      %uarr = OpTypeRuntimeArray %uint
      %B = OpTypeStruct %uarr
      %ptr_sb_B = OpTypePointer StorageBuffer %B
      %buf = OpVariable %ptr_sb_B StorageBuffer
      %imgT = OpTypeImage %\(st) 1 0 0 0 2 \(spirvFormat)
      %ptr_img = OpTypePointer UniformConstant %imgT
      %img = OpVariable %ptr_img UniformConstant
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %g = OpLoad %v3uint %gid
      %gx = OpCompositeExtract %uint %g 0
      %xs = OpBitcast %int %gx
      %coord = OpCompositeConstruct %v2int %xs %i0
      %pv = OpAccessChain %ptr_sb_uint %buf %u0 %gx
      %raw = OpLoad %uint %pv
      \(signed ? "%val = OpBitcast %int %raw" : "%val = OpCopyObject %uint %raw")
      %texel = OpCompositeConstruct %v4\(st) %val %val %val %val
      %im = OpLoad %imgT %img
      OpImageWrite %im %coord %texel
      OpReturn
      OpFunctionEnd
      """
  }

  /// Out of bounds accesses to a 32-bit unsigned one-channel image (binding 2: R32ui, 8 x 8): invocation i takes the
  /// coordinates (word 2i, word 2i + 1) of the buffer at binding 0 as ints, and
  /// - mode 0 loads the texel and stores its four channels at words 4i to 4i + 3 of the buffer at binding 1;
  /// - mode 1 stores 0xDEAD0000 + i;
  /// - mode 2 adds 0x1000 atomically and stores the old value at word 4i.
  /// The questions: what an out of bounds load reads, and whether a store or an atomic through the same address changes
  /// any memory (the image's buffer is filled with a sentinel around the texels).
  public static func imageBounds(mode: Int) -> String {
    let body: String
    switch mode {
    case 0:
      body = """
        %t = OpImageRead %v4uint %im %coord
        %t0 = OpCompositeExtract %uint %t 0
        %t1 = OpCompositeExtract %uint %t 1
        %t2 = OpCompositeExtract %uint %t 2
        %t3 = OpCompositeExtract %uint %t 3
        %o0 = OpAccessChain %ptr_sb_uint %out %u0 %q
        OpStore %o0 %t0
        %q1 = OpIAdd %uint %q %u1
        %o1 = OpAccessChain %ptr_sb_uint %out %u0 %q1
        OpStore %o1 %t1
        %q2 = OpIAdd %uint %q %u2
        %o2 = OpAccessChain %ptr_sb_uint %out %u0 %q2
        OpStore %o2 %t2
        %q3 = OpIAdd %uint %q %u3
        %o3 = OpAccessChain %ptr_sb_uint %out %u0 %q3
        OpStore %o3 %t3
        """
    case 1:
      body = """
        %mark = OpIAdd %uint %dead %gx
        %texel = OpCompositeConstruct %v4uint %mark %mark %mark %mark
        OpImageWrite %im %coord %texel
        %o0 = OpAccessChain %ptr_sb_uint %out %u0 %q
        OpStore %o0 %u1
        """
    default:
      body = """
        %tp = OpImageTexelPointer %ptr_img_uint %img %coord %u0
        %old = OpAtomicIAdd %uint %tp %u1 %u0 %amount
        %o0 = OpAccessChain %ptr_sb_uint %out %u0 %q
        OpStore %o0 %old
        """
    }
    return """
      \(head("OpCapability StorageImageExtendedFormats", size: "16 1 1"))
      OpDecorate %uarr ArrayStride 4
      OpMemberDecorate %B 0 Offset 0
      OpDecorate %B Block
      OpDecorate %buf DescriptorSet 0
      OpDecorate %buf Binding 0
      OpDecorate %out DescriptorSet 0
      OpDecorate %out Binding 1
      OpDecorate %img DescriptorSet 0
      OpDecorate %img Binding 2
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      %v2int = OpTypeVector %int 2
      %v4uint = OpTypeVector %uint 4
      %dead = OpConstant %uint 3735879680
      %amount = OpConstant %uint 4096
      %uarr = OpTypeRuntimeArray %uint
      %B = OpTypeStruct %uarr
      %ptr_sb_B = OpTypePointer StorageBuffer %B
      %buf = OpVariable %ptr_sb_B StorageBuffer
      %out = OpVariable %ptr_sb_B StorageBuffer
      %imgT = OpTypeImage %uint 1 0 0 0 2 33
      %ptr_img = OpTypePointer UniformConstant %imgT
      %ptr_img_uint = OpTypePointer Image %uint
      %img = OpVariable %ptr_img UniformConstant
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %g = OpLoad %v3uint %gid
      %gx = OpCompositeExtract %uint %g 0
      %two = OpIMul %uint %gx %u2
      %two1 = OpIAdd %uint %two %u1
      %px = OpAccessChain %ptr_sb_uint %buf %u0 %two
      %py = OpAccessChain %ptr_sb_uint %buf %u0 %two1
      %rx = OpLoad %uint %px
      %ry = OpLoad %uint %py
      %xs = OpBitcast %int %rx
      %ys = OpBitcast %int %ry
      %coord = OpCompositeConstruct %v2int %xs %ys
      %q = OpIMul %uint %gx %u4
      %im = OpLoad %imgT %img
      \(body)
      OpReturn
      OpFunctionEnd
      """
  }
}
