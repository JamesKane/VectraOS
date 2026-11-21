// SPDX-License-Identifier: BSD-3-Clause

// A small SPIR-V assembler for the tests, written from the SPIR-V
// specification (the binary form: a word count and an opcode in the first
// word, then the result type, the result id, the operands).
//
// Text: one instruction a line, `;` starts a comment.
//   %name = OpIAdd %uint %a %b      ids are %names, numbered in first-use order
//   OpName %main "main"             strings are quoted
//   OpConstant %uint 7              integers are one word; `5L` two words;
//   OpConstant %float 1.5f          `1.5f` a float word, `1.5d` two words
//   OpEntryPoint GLCompute ...      bare words are enumerants (Shader, Block, ...)
// `Scope.Workgroup` names a scope where the bare word would be a storage class.

public struct AsmError: Error, CustomStringConvertible {
  public var description: String
}

private let opTable: [String: (code: UInt32, kind: Character)] = {
  // name code kind: T result type and id, R result id only, - neither
  let text = """
    OpNop 0 - OpUndef 1 T OpSource 3 - OpName 5 - OpMemberName 6 - OpString 7 R OpExtension 10 -
    OpExtInstImport 11 R OpExtInst 12 T OpMemoryModel 14 - OpEntryPoint 15 - OpExecutionMode 16 -
    OpCapability 17 - OpTypeVoid 19 R OpTypeBool 20 R OpTypeInt 21 R OpTypeFloat 22 R OpTypeVector 23 R
    OpTypeMatrix 24 R OpTypeImage 25 R OpTypeSampler 26 R OpTypeSampledImage 27 R OpTypeArray 28 R
    OpTypeRuntimeArray 29 R OpTypeStruct 30 R OpTypePointer 32 R OpTypeFunction 33 R OpTypeForwardPointer 39 -
    OpConstantTrue 41 T OpConstantFalse 42 T OpConstant 43 T OpConstantComposite 44 T OpConstantNull 46 T
    OpSpecConstantTrue 48 T OpSpecConstantFalse 49 T OpSpecConstant 50 T OpSpecConstantComposite 51 T
    OpSpecConstantOp 52 T OpFunction 54 T OpFunctionParameter 55 T OpFunctionEnd 56 - OpFunctionCall 57 T
    OpVariable 59 T OpLoad 61 T OpStore 62 - OpAccessChain 65 T OpInBoundsAccessChain 66 T
    OpPtrAccessChain 67 T OpArrayLength 68 T OpDecorate 71 - OpMemberDecorate 72 -
    OpVectorExtractDynamic 77 T OpVectorInsertDynamic 78 T OpVectorShuffle 79 T OpCompositeConstruct 80 T
    OpCompositeExtract 81 T OpCompositeInsert 82 T OpCopyObject 83 T OpConvertFToU 109 T OpConvertFToS 110 T
    OpConvertSToF 111 T OpConvertUToF 112 T OpUConvert 113 T OpSConvert 114 T OpFConvert 115 T
    OpConvertPtrToU 117 T OpConvertUToPtr 120 T OpBitcast 124 T OpSNegate 126 T OpFNegate 127 T OpIAdd 128 T
    OpFAdd 129 T OpISub 130 T OpFSub 131 T OpIMul 132 T OpFMul 133 T OpUDiv 134 T OpSDiv 135 T OpFDiv 136 T
    OpUMod 137 T OpSRem 138 T OpSMod 139 T OpFRem 140 T OpFMod 141 T OpVectorTimesScalar 142 T OpDot 148 T
    OpAny 154 T OpAll 155 T OpIsNan 156 T OpIsInf 157 T OpLogicalEqual 164 T OpLogicalNotEqual 165 T
    OpLogicalOr 166 T OpLogicalAnd 167 T OpLogicalNot 168 T OpSelect 169 T OpIEqual 170 T OpINotEqual 171 T
    OpUGreaterThan 172 T OpSGreaterThan 173 T OpUGreaterThanEqual 174 T OpSGreaterThanEqual 175 T
    OpULessThan 176 T OpSLessThan 177 T OpULessThanEqual 178 T OpSLessThanEqual 179 T OpFOrdEqual 180 T
    OpFUnordEqual 181 T OpFOrdNotEqual 182 T OpFUnordNotEqual 183 T OpFOrdLessThan 184 T OpFUnordLessThan 185 T
    OpFOrdGreaterThan 186 T OpFUnordGreaterThan 187 T OpFOrdLessThanEqual 188 T OpFUnordLessThanEqual 189 T
    OpFOrdGreaterThanEqual 190 T OpFUnordGreaterThanEqual 191 T OpShiftRightLogical 194 T
    OpShiftRightArithmetic 195 T OpShiftLeftLogical 196 T OpBitwiseOr 197 T OpBitwiseXor 198 T
    OpBitwiseAnd 199 T OpNot 200 T OpControlBarrier 224 - OpMemoryBarrier 225 - OpAtomicLoad 227 T
    OpAtomicStore 228 - OpAtomicExchange 229 T OpAtomicCompareExchange 230 T OpAtomicIIncrement 232 T
    OpAtomicIDecrement 233 T OpAtomicIAdd 234 T OpAtomicISub 235 T OpAtomicSMin 236 T OpAtomicUMin 237 T
    OpAtomicSMax 238 T OpAtomicUMax 239 T OpAtomicAnd 240 T OpAtomicOr 241 T OpAtomicXor 242 T OpPhi 245 T
    OpLoopMerge 246 - OpSelectionMerge 247 - OpLabel 248 R OpBranch 249 - OpBranchConditional 250 -
    OpSwitch 251 - OpKill 252 - OpReturn 253 - OpReturnValue 254 - OpUnreachable 255 -
    OpImageSampleImplicitLod 87 T OpImageWrite 99 - OpCopyMemory 63 - OpCopyLogical 400 T
    """
  var t: [String: (code: UInt32, kind: Character)] = [:]
  let words = text.split(whereSeparator: { $0 == " " || $0.isNewline })
  var i = 0
  while i + 2 < words.count {
    t[String(words[i])] = (UInt32(words[i + 1])!, words[i + 2].first!)
    i += 3
  }
  return t
}()

private let enums: [String: UInt32] = [
  // Capabilities
  "Matrix": 0, "Shader": 1, "Float16": 9, "Float64": 10, "Int64": 11, "Int16": 22, "Int8": 39,
  "PhysicalStorageBufferAddresses": 5347, "Geometry": 2, "ImageQuery": 50, "GroupNonUniform": 61,
  // Addressing and memory models
  "Logical": 0, "PhysicalStorageBuffer64": 5348, "GLSL450": 1, "Vulkan": 3,
  // Execution models and modes
  "Vertex": 0, "Fragment": 4, "GLCompute": 5, "Kernel": 6, "OriginUpperLeft": 7, "OriginLowerLeft": 8, "EarlyFragmentTests": 9, "LocalSize": 17,
  // Storage classes
  "UniformConstant": 0, "Input": 1, "Uniform": 2, "Output": 3, "Workgroup": 4, "CrossWorkgroup": 5,
  "Private": 6, "Function": 7, "Generic": 8, "PushConstant": 9, "StorageBuffer": 12,
  "PhysicalStorageBuffer": 5349,
  // Function, selection and loop control
  "None": 0, "Inline": 1, "DontInline": 2, "Pure": 4, "Const": 8, "Flatten": 1, "DontFlatten": 2,
  "Unroll": 1, "DontUnroll": 2,
  // Decorations
  "SpecId": 1, "Block": 2, "BufferBlock": 3, "ArrayStride": 6, "BuiltIn": 11, "Flat": 14, "NoPerspective": 13, "Centroid": 16, "Restrict": 19,
  "Aliased": 20, "Volatile": 21, "Coherent": 23, "NonWritable": 24, "NonReadable": 25, "Location": 30,
  "Binding": 33, "DescriptorSet": 34, "Offset": 35, "RelaxedPrecision": 0,
  // Builtins
  "Position": 0, "PointSize": 1, "ClipDistance": 3, "CullDistance": 4, "VertexIndex": 42, "InstanceIndex": 43, "FragCoord": 15,
  "FrontFacing": 17, "NumWorkgroups": 24, "WorkgroupSize": 25, "WorkgroupId": 26, "LocalInvocationId": 27,
  "GlobalInvocationId": 28, "LocalInvocationIndex": 29, "SubgroupSize": 36, "SubgroupId": 40,
  "SubgroupLocalInvocationId": 41,
  // Memory access
  "Aligned": 2,
  // Scopes
  "Scope.CrossDevice": 0, "Scope.Device": 1, "Scope.Workgroup": 2, "Scope.Subgroup": 3, "Scope.Invocation": 4,
]

/// Assemble text to SPIR-V words (the header included).
public func assemble(_ text: String, version: UInt32 = 0x0001_0600) throws -> [UInt32] {
  var ids: [String: UInt32] = [:]
  var next: UInt32 = 1
  func id(_ name: String) -> UInt32 {
    if let v = ids[name] { return v }
    let v = next
    next += 1
    ids[name] = v
    return v
  }
  func tokens(_ line: Substring) throws -> [String] {
    var out: [String] = []
    var cur = ""
    var inString = false
    for c in line {
      if inString {
        cur.append(c)
        if c == "\"" {
          inString = false
          out.append(cur)
          cur = ""
        }
      } else if c == "\"" {
        inString = true
        cur.append(c)
      } else if c == ";" {
        break
      } else if c == " " || c == "\t" {
        if !cur.isEmpty { out.append(cur) }
        cur = ""
      } else {
        cur.append(c)
      }
    }
    if inString { throw AsmError(description: "unterminated string in: \(line)") }
    if !cur.isEmpty { out.append(cur) }
    return out
  }
  func stringWords(_ s: String) -> [UInt32] {
    var bytes = Array(s.utf8)
    bytes.append(0)
    while bytes.count % 4 != 0 { bytes.append(0) }
    var w: [UInt32] = []
    var k = 0
    while k < bytes.count {
      w.append(
        UInt32(bytes[k]) | UInt32(bytes[k + 1]) << 8 | UInt32(bytes[k + 2]) << 16 | UInt32(bytes[k + 3]) << 24)
      k += 4
    }
    return w
  }
  func operand(_ t: String) throws -> [UInt32] {
    if t.hasPrefix("%") { return [id(String(t.dropFirst()))] }
    if t.hasPrefix("\"") { return stringWords(String(t.dropFirst().dropLast())) }
    if t.hasSuffix("L"), let v = UInt64(t.dropLast()) { return [UInt32(truncatingIfNeeded: v), UInt32(v >> 32)] }
    if t.hasSuffix("f"), let v = Float(t.dropLast()) { return [v.bitPattern] }
    if t.hasSuffix("d"), let v = Double(t.dropLast()) {
      return [UInt32(truncatingIfNeeded: v.bitPattern), UInt32(v.bitPattern >> 32)]
    }
    if let v = Int64(t) { return [UInt32(truncatingIfNeeded: v)] }
    if t.hasPrefix("0x"), let v = UInt32(t.dropFirst(2), radix: 16) { return [v] }
    if let e = enums[t] { return [e] }
    throw AsmError(description: "unknown operand \(t)")
  }
  var body: [UInt32] = []
  for line in text.split(whereSeparator: { $0.isNewline }) {
    var toks = try tokens(line)
    if toks.isEmpty { continue }
    var result: UInt32? = nil
    if toks.count >= 2 && toks[0].hasPrefix("%") && toks[1] == "=" {
      result = id(String(toks[0].dropFirst()))
      toks.removeFirst(2)
    }
    guard let info = opTable[toks[0]] else { throw AsmError(description: "unknown opcode \(toks[0])") }
    var words: [UInt32] = []
    var rest = Array(toks.dropFirst())
    if info.kind == "T" {
      guard let r = result, !rest.isEmpty else { throw AsmError(description: "\(toks[0]) needs a result and a type") }
      words.append(contentsOf: try operand(rest.removeFirst()))
      words.append(r)
    } else if info.kind == "R" {
      guard let r = result else { throw AsmError(description: "\(toks[0]) needs a result") }
      words.append(r)
    } else if result != nil {
      throw AsmError(description: "\(toks[0]) has no result")
    }
    for t in rest { words.append(contentsOf: try operand(t)) }
    body.append((UInt32(words.count + 1) << 16) | info.code)
    body.append(contentsOf: words)
  }
  return [0x0723_0203, version, 0, next, 0] + body
}
