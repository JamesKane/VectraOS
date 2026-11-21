// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V's opcodes, numbered as the Khronos SPIR-V specification (unified
// 1.6) numbers them: the ones the reader handles as constants, and a table
// of every opcode it knows with its name, whether it has a result type and
// a result id, and whether the compiler supports it. An opcode not in the
// table is refused by number.

/// A compile error: what was refused and why. Errors about an instruction
/// name it (`OpIAdd %12: ...`).
public struct CompileError: Error, Equatable, CustomStringConvertible {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
}

public enum Op {
  public static let nop: UInt16 = 0
  public static let undef: UInt16 = 1
  public static let sourceContinued: UInt16 = 2
  public static let source: UInt16 = 3
  public static let sourceExtension: UInt16 = 4
  public static let name: UInt16 = 5
  public static let memberName: UInt16 = 6
  public static let string: UInt16 = 7
  public static let line: UInt16 = 8
  public static let extension_: UInt16 = 10
  public static let extInstImport: UInt16 = 11
  public static let extInst: UInt16 = 12
  public static let memoryModel: UInt16 = 14
  public static let entryPoint: UInt16 = 15
  public static let executionMode: UInt16 = 16
  public static let capability: UInt16 = 17
  public static let typeVoid: UInt16 = 19
  public static let typeBool: UInt16 = 20
  public static let typeInt: UInt16 = 21
  public static let typeFloat: UInt16 = 22
  public static let typeVector: UInt16 = 23
  public static let typeMatrix: UInt16 = 24
  public static let typeImage: UInt16 = 25
  public static let typeSampler: UInt16 = 26
  public static let typeSampledImage: UInt16 = 27
  public static let typeArray: UInt16 = 28
  public static let typeRuntimeArray: UInt16 = 29
  public static let typeStruct: UInt16 = 30
  public static let typeOpaque: UInt16 = 31
  public static let typePointer: UInt16 = 32
  public static let typeFunction: UInt16 = 33
  public static let typeForwardPointer: UInt16 = 39
  public static let constantTrue: UInt16 = 41
  public static let constantFalse: UInt16 = 42
  public static let constant: UInt16 = 43
  public static let constantComposite: UInt16 = 44
  public static let constantNull: UInt16 = 46
  public static let specConstantTrue: UInt16 = 48
  public static let specConstantFalse: UInt16 = 49
  public static let specConstant: UInt16 = 50
  public static let specConstantComposite: UInt16 = 51
  public static let specConstantOp: UInt16 = 52
  public static let function: UInt16 = 54
  public static let functionParameter: UInt16 = 55
  public static let functionEnd: UInt16 = 56
  public static let functionCall: UInt16 = 57
  public static let variable: UInt16 = 59
  public static let load: UInt16 = 61
  public static let store: UInt16 = 62
  public static let copyMemory: UInt16 = 63
  public static let accessChain: UInt16 = 65
  public static let inBoundsAccessChain: UInt16 = 66
  public static let ptrAccessChain: UInt16 = 67
  public static let arrayLength: UInt16 = 68
  public static let inBoundsPtrAccessChain: UInt16 = 70
  public static let decorate: UInt16 = 71
  public static let memberDecorate: UInt16 = 72
  public static let vectorExtractDynamic: UInt16 = 77
  public static let vectorInsertDynamic: UInt16 = 78
  public static let vectorShuffle: UInt16 = 79
  public static let compositeConstruct: UInt16 = 80
  public static let compositeExtract: UInt16 = 81
  public static let compositeInsert: UInt16 = 82
  public static let copyObject: UInt16 = 83
  public static let convertFToU: UInt16 = 109
  public static let convertFToS: UInt16 = 110
  public static let convertSToF: UInt16 = 111
  public static let convertUToF: UInt16 = 112
  public static let uConvert: UInt16 = 113
  public static let sConvert: UInt16 = 114
  public static let fConvert: UInt16 = 115
  public static let convertPtrToU: UInt16 = 117
  public static let convertUToPtr: UInt16 = 120
  public static let bitcast: UInt16 = 124
  public static let sNegate: UInt16 = 126
  public static let fNegate: UInt16 = 127
  public static let iAdd: UInt16 = 128
  public static let fAdd: UInt16 = 129
  public static let iSub: UInt16 = 130
  public static let fSub: UInt16 = 131
  public static let iMul: UInt16 = 132
  public static let fMul: UInt16 = 133
  public static let uDiv: UInt16 = 134
  public static let sDiv: UInt16 = 135
  public static let fDiv: UInt16 = 136
  public static let uMod: UInt16 = 137
  public static let sRem: UInt16 = 138
  public static let sMod: UInt16 = 139
  public static let fRem: UInt16 = 140
  public static let fMod: UInt16 = 141
  public static let vectorTimesScalar: UInt16 = 142
  public static let dot: UInt16 = 148
  public static let any: UInt16 = 154
  public static let all: UInt16 = 155
  public static let isNan: UInt16 = 156
  public static let isInf: UInt16 = 157
  public static let logicalEqual: UInt16 = 164
  public static let logicalNotEqual: UInt16 = 165
  public static let logicalOr: UInt16 = 166
  public static let logicalAnd: UInt16 = 167
  public static let logicalNot: UInt16 = 168
  public static let select: UInt16 = 169
  public static let iEqual: UInt16 = 170
  public static let iNotEqual: UInt16 = 171
  public static let uGreaterThan: UInt16 = 172
  public static let sGreaterThan: UInt16 = 173
  public static let uGreaterThanEqual: UInt16 = 174
  public static let sGreaterThanEqual: UInt16 = 175
  public static let uLessThan: UInt16 = 176
  public static let sLessThan: UInt16 = 177
  public static let uLessThanEqual: UInt16 = 178
  public static let sLessThanEqual: UInt16 = 179
  public static let fOrdEqual: UInt16 = 180
  public static let fUnordEqual: UInt16 = 181
  public static let fOrdNotEqual: UInt16 = 182
  public static let fUnordNotEqual: UInt16 = 183
  public static let fOrdLessThan: UInt16 = 184
  public static let fUnordLessThan: UInt16 = 185
  public static let fOrdGreaterThan: UInt16 = 186
  public static let fUnordGreaterThan: UInt16 = 187
  public static let fOrdLessThanEqual: UInt16 = 188
  public static let fUnordLessThanEqual: UInt16 = 189
  public static let fOrdGreaterThanEqual: UInt16 = 190
  public static let fUnordGreaterThanEqual: UInt16 = 191
  public static let shiftRightLogical: UInt16 = 194
  public static let shiftRightArithmetic: UInt16 = 195
  public static let shiftLeftLogical: UInt16 = 196
  public static let bitwiseOr: UInt16 = 197
  public static let bitwiseXor: UInt16 = 198
  public static let bitwiseAnd: UInt16 = 199
  public static let not: UInt16 = 200
  public static let controlBarrier: UInt16 = 224
  public static let memoryBarrier: UInt16 = 225
  public static let atomicLoad: UInt16 = 227
  public static let atomicStore: UInt16 = 228
  public static let atomicExchange: UInt16 = 229
  public static let atomicCompareExchange: UInt16 = 230
  public static let atomicIIncrement: UInt16 = 232
  public static let atomicIDecrement: UInt16 = 233
  public static let atomicIAdd: UInt16 = 234
  public static let atomicISub: UInt16 = 235
  public static let atomicSMin: UInt16 = 236
  public static let atomicUMin: UInt16 = 237
  public static let atomicSMax: UInt16 = 238
  public static let atomicUMax: UInt16 = 239
  public static let atomicAnd: UInt16 = 240
  public static let atomicOr: UInt16 = 241
  public static let atomicXor: UInt16 = 242
  public static let phi: UInt16 = 245
  public static let loopMerge: UInt16 = 246
  public static let selectionMerge: UInt16 = 247
  public static let label: UInt16 = 248
  public static let branch: UInt16 = 249
  public static let branchConditional: UInt16 = 250
  public static let switch_: UInt16 = 251
  public static let kill: UInt16 = 252
  public static let return_: UInt16 = 253
  public static let returnValue: UInt16 = 254
  public static let unreachable: UInt16 = 255
  public static let noLine: UInt16 = 317
  public static let copyLogical: UInt16 = 400
  public static let sampledImage: UInt16 = 86
  public static let imageSampleImplicitLod: UInt16 = 87
  public static let imageSampleExplicitLod: UInt16 = 88
  public static let imageFetch: UInt16 = 95
  public static let imageTexelPointer: UInt16 = 60
  public static let imageRead: UInt16 = 98
  public static let imageWrite: UInt16 = 99
  public static let imageQuerySize: UInt16 = 104
  public static let imageQueryLevels: UInt16 = 106
  public static let imageQuerySamples: UInt16 = 107
  public static let image: UInt16 = 100
  public static let demoteToHelperInvocation: UInt16 = 5380
}

/// What the reader knows of an opcode.
struct OpInfo {
  var name: String
  var hasType: Bool
  var hasResult: Bool
  /// Known to SPIR-V and parsed, but refused by the compiler.
  var refused: Bool
}

enum OpTable {
  /// Indexed by opcode (all the opcodes the reader knows are below 512).
  static let table: [OpInfo?] = {
    var t = [OpInfo?](repeating: nil, count: 512)
    // flags: 1 type, 2 result, 4 refused
    func add(_ code: UInt16, _ name: String, _ flags: Int) {
      t[Int(code)] = OpInfo(name: name, hasType: flags & 1 != 0, hasResult: flags & 2 != 0, refused: flags & 4 != 0)
    }
    // No type, no result.
    for (c, n) in [
      (Op.nop, "OpNop"), (Op.sourceContinued, "OpSourceContinued"), (Op.source, "OpSource"),
      (Op.sourceExtension, "OpSourceExtension"), (Op.name, "OpName"), (Op.memberName, "OpMemberName"),
      (Op.line, "OpLine"), (Op.extension_, "OpExtension"), (Op.memoryModel, "OpMemoryModel"),
      (Op.entryPoint, "OpEntryPoint"), (Op.executionMode, "OpExecutionMode"),
      (Op.capability, "OpCapability"), (Op.functionEnd, "OpFunctionEnd"), (Op.store, "OpStore"),
      (Op.decorate, "OpDecorate"), (Op.memberDecorate, "OpMemberDecorate"),
      (Op.controlBarrier, "OpControlBarrier"), (Op.memoryBarrier, "OpMemoryBarrier"),
      (Op.atomicStore, "OpAtomicStore"), (Op.imageWrite, "OpImageWrite"), (Op.loopMerge, "OpLoopMerge"),
      (Op.selectionMerge, "OpSelectionMerge"), (Op.branch, "OpBranch"),
      (Op.branchConditional, "OpBranchConditional"), (Op.switch_, "OpSwitch"), (Op.kill, "OpKill"),
      (Op.return_, "OpReturn"), (Op.returnValue, "OpReturnValue"), (Op.unreachable, "OpUnreachable"),
      (Op.noLine, "OpNoLine"), (Op.typeForwardPointer, "OpTypeForwardPointer"),
    ] as [(UInt16, String)] { add(c, n, 0) }
    // A result id only.
    for (c, n) in [
      (Op.string, "OpString"), (Op.extInstImport, "OpExtInstImport"), (Op.typeVoid, "OpTypeVoid"),
      (Op.typeBool, "OpTypeBool"), (Op.typeInt, "OpTypeInt"), (Op.typeFloat, "OpTypeFloat"),
      (Op.typeVector, "OpTypeVector"), (Op.typeArray, "OpTypeArray"),
      (Op.typeRuntimeArray, "OpTypeRuntimeArray"), (Op.typeStruct, "OpTypeStruct"),
      (Op.typePointer, "OpTypePointer"), (Op.typeFunction, "OpTypeFunction"), (Op.label, "OpLabel"),
      (Op.typeImage, "OpTypeImage"), (Op.typeSampler, "OpTypeSampler"), (Op.typeSampledImage, "OpTypeSampledImage"),
    ] as [(UInt16, String)] { add(c, n, 2) }
    // A result type and a result id.
    for (c, n) in [
      (Op.undef, "OpUndef"), (Op.extInst, "OpExtInst"), (Op.constantTrue, "OpConstantTrue"),
      (Op.constantFalse, "OpConstantFalse"), (Op.constant, "OpConstant"),
      (Op.constantComposite, "OpConstantComposite"), (Op.constantNull, "OpConstantNull"),
      (Op.specConstantTrue, "OpSpecConstantTrue"), (Op.specConstantFalse, "OpSpecConstantFalse"),
      (Op.specConstant, "OpSpecConstant"), (Op.specConstantComposite, "OpSpecConstantComposite"),
      (Op.specConstantOp, "OpSpecConstantOp"), (Op.function, "OpFunction"),
      (Op.functionParameter, "OpFunctionParameter"), (Op.functionCall, "OpFunctionCall"),
      (Op.variable, "OpVariable"), (Op.load, "OpLoad"), (Op.accessChain, "OpAccessChain"),
      (Op.inBoundsAccessChain, "OpInBoundsAccessChain"), (Op.ptrAccessChain, "OpPtrAccessChain"),
      (Op.arrayLength, "OpArrayLength"), (Op.inBoundsPtrAccessChain, "OpInBoundsPtrAccessChain"),
      (Op.vectorExtractDynamic, "OpVectorExtractDynamic"), (Op.vectorInsertDynamic, "OpVectorInsertDynamic"),
      (Op.vectorShuffle, "OpVectorShuffle"), (Op.compositeConstruct, "OpCompositeConstruct"),
      (Op.compositeExtract, "OpCompositeExtract"), (Op.compositeInsert, "OpCompositeInsert"),
      (Op.copyObject, "OpCopyObject"), (Op.convertFToU, "OpConvertFToU"), (Op.convertFToS, "OpConvertFToS"),
      (Op.convertSToF, "OpConvertSToF"), (Op.convertUToF, "OpConvertUToF"), (Op.uConvert, "OpUConvert"),
      (Op.sConvert, "OpSConvert"), (Op.fConvert, "OpFConvert"), (Op.convertPtrToU, "OpConvertPtrToU"),
      (Op.convertUToPtr, "OpConvertUToPtr"), (Op.bitcast, "OpBitcast"), (Op.sNegate, "OpSNegate"),
      (Op.fNegate, "OpFNegate"), (Op.iAdd, "OpIAdd"), (Op.fAdd, "OpFAdd"), (Op.iSub, "OpISub"),
      (Op.fSub, "OpFSub"), (Op.iMul, "OpIMul"), (Op.fMul, "OpFMul"), (Op.uDiv, "OpUDiv"),
      (Op.sDiv, "OpSDiv"), (Op.fDiv, "OpFDiv"), (Op.uMod, "OpUMod"), (Op.sRem, "OpSRem"),
      (Op.sMod, "OpSMod"), (Op.fRem, "OpFRem"), (Op.fMod, "OpFMod"),
      (Op.vectorTimesScalar, "OpVectorTimesScalar"), (Op.dot, "OpDot"), (Op.any, "OpAny"),
      (Op.all, "OpAll"), (Op.isNan, "OpIsNan"), (Op.isInf, "OpIsInf"),
      (Op.logicalEqual, "OpLogicalEqual"), (Op.logicalNotEqual, "OpLogicalNotEqual"),
      (Op.logicalOr, "OpLogicalOr"), (Op.logicalAnd, "OpLogicalAnd"), (Op.logicalNot, "OpLogicalNot"),
      (Op.select, "OpSelect"), (Op.iEqual, "OpIEqual"), (Op.iNotEqual, "OpINotEqual"),
      (Op.uGreaterThan, "OpUGreaterThan"), (Op.sGreaterThan, "OpSGreaterThan"),
      (Op.uGreaterThanEqual, "OpUGreaterThanEqual"), (Op.sGreaterThanEqual, "OpSGreaterThanEqual"),
      (Op.uLessThan, "OpULessThan"), (Op.sLessThan, "OpSLessThan"),
      (Op.uLessThanEqual, "OpULessThanEqual"), (Op.sLessThanEqual, "OpSLessThanEqual"),
      (Op.fOrdEqual, "OpFOrdEqual"), (Op.fUnordEqual, "OpFUnordEqual"),
      (Op.fOrdNotEqual, "OpFOrdNotEqual"), (Op.fUnordNotEqual, "OpFUnordNotEqual"),
      (Op.fOrdLessThan, "OpFOrdLessThan"), (Op.fUnordLessThan, "OpFUnordLessThan"),
      (Op.fOrdGreaterThan, "OpFOrdGreaterThan"), (Op.fUnordGreaterThan, "OpFUnordGreaterThan"),
      (Op.fOrdLessThanEqual, "OpFOrdLessThanEqual"), (Op.fUnordLessThanEqual, "OpFUnordLessThanEqual"),
      (Op.fOrdGreaterThanEqual, "OpFOrdGreaterThanEqual"),
      (Op.fUnordGreaterThanEqual, "OpFUnordGreaterThanEqual"),
      (Op.shiftRightLogical, "OpShiftRightLogical"), (Op.shiftRightArithmetic, "OpShiftRightArithmetic"),
      (Op.shiftLeftLogical, "OpShiftLeftLogical"), (Op.bitwiseOr, "OpBitwiseOr"),
      (Op.bitwiseXor, "OpBitwiseXor"), (Op.bitwiseAnd, "OpBitwiseAnd"), (Op.not, "OpNot"),
      (Op.atomicLoad, "OpAtomicLoad"), (Op.atomicExchange, "OpAtomicExchange"),
      (Op.atomicCompareExchange, "OpAtomicCompareExchange"), (Op.atomicIIncrement, "OpAtomicIIncrement"),
      (Op.atomicIDecrement, "OpAtomicIDecrement"), (Op.atomicIAdd, "OpAtomicIAdd"),
      (Op.atomicISub, "OpAtomicISub"), (Op.atomicSMin, "OpAtomicSMin"), (Op.atomicUMin, "OpAtomicUMin"),
      (Op.atomicSMax, "OpAtomicSMax"), (Op.atomicUMax, "OpAtomicUMax"), (Op.atomicAnd, "OpAtomicAnd"),
      (Op.atomicOr, "OpAtomicOr"), (Op.atomicXor, "OpAtomicXor"), (Op.phi, "OpPhi"),
      (Op.sampledImage, "OpSampledImage"), (Op.imageSampleImplicitLod, "OpImageSampleImplicitLod"),
      (Op.imageSampleExplicitLod, "OpImageSampleExplicitLod"), (Op.imageFetch, "OpImageFetch"), (Op.image, "OpImage"),
      (Op.copyLogical, "OpCopyLogical"), (Op.imageRead, "OpImageRead"), (Op.imageQuerySize, "OpImageQuerySize"),
      (Op.imageTexelPointer, "OpImageTexelPointer"), (Op.imageQueryLevels, "OpImageQueryLevels"),
      (Op.imageQuerySamples, "OpImageQuerySamples"),
    ] as [(UInt16, String)] where c < 512 { add(c, n, 3) }
    // Parsed, refused by name.
    for (c, n) in [
      (Op.typeMatrix, "OpTypeMatrix"), (Op.typeOpaque, "OpTypeOpaque"),
    ] as [(UInt16, String)] { add(c, n, 2 | 4) }
    for (c, n) in [
      (73, "OpDecorationGroup"), (84, "OpTranspose"), 
      (89, "OpImageSampleDrefImplicitLod"), (90, "OpImageSampleDrefExplicitLod"),
      (91, "OpImageSampleProjImplicitLod"), (92, "OpImageSampleProjExplicitLod"),
      (96, "OpImageGather"), (97, "OpImageDrefGather"),
      (101, "OpImageQueryFormat"), (103, "OpImageQuerySizeLod"),
      (116, "OpQuantizeToF16"), (118, "OpSatConvertSToU"),
      (119, "OpSatConvertUToS"), (143, "OpMatrixTimesScalar"), (144, "OpVectorTimesMatrix"),
      (145, "OpMatrixTimesVector"), (146, "OpMatrixTimesMatrix"), (147, "OpOuterProduct"),
      (149, "OpIAddCarry"), (150, "OpISubBorrow"), (151, "OpUMulExtended"), (152, "OpSMulExtended"),
      (201, "OpBitFieldInsert"), (202, "OpBitFieldSInsert"), (203, "OpBitFieldUExtract"),
      (204, "OpBitFieldSExtract"), (205, "OpBitReverse"), (206, "OpBitCount"), (207, "OpDPdx"),
      (208, "OpDPdy"), (209, "OpFwidth"), (231, "OpAtomicCompareExchangeWeak"),
    ] as [(UInt16, String)] { add(c, n, 3 | 4) }
    for (c, n) in [
      (64, "OpCopyMemorySized"), (74, "OpGroupDecorate"), (75, "OpGroupMemberDecorate"),
      (218, "OpEmitVertex"), (219, "OpEndPrimitive"), (256, "OpLifetimeStart"),
      (257, "OpLifetimeStop"),
    ] as [(UInt16, String)] { add(c, n, 4) }
    add(Op.copyMemory, "OpCopyMemory", 4)
    // Supported (the image samples, gathers and queries of LowerTexture.swift, the derivatives): over the refused list above.
    for (c, n) in [
      (89, "OpImageSampleDrefImplicitLod"), (90, "OpImageSampleDrefExplicitLod"), (91, "OpImageSampleProjImplicitLod"),
      (92, "OpImageSampleProjExplicitLod"), (93, "OpImageSampleProjDrefImplicitLod"), (94, "OpImageSampleProjDrefExplicitLod"),
      (96, "OpImageGather"), (97, "OpImageDrefGather"), (103, "OpImageQuerySizeLod"), (105, "OpImageQueryLod"),
      (207, "OpDPdx"), (208, "OpDPdy"), (209, "OpFwidth"), (210, "OpDPdxFine"), (211, "OpDPdyFine"), (212, "OpFwidthFine"),
      (213, "OpDPdxCoarse"), (214, "OpDPdyCoarse"), (215, "OpFwidthCoarse"),
    ] as [(UInt16, String)] { add(c, n, 3) }
    return t
  }()

  static let demote = OpInfo(name: "OpDemoteToHelperInvocation", hasType: false, hasResult: false, refused: false)

  static func info(_ op: UInt16) -> OpInfo? {
    if op == Op.demoteToHelperInvocation { return demote }
    if op == 5381 { return OpInfo(name: "OpIsHelperInvocationEXT", hasType: true, hasResult: true, refused: false) }
    return Int(op) < table.count ? table[Int(op)] : nil
  }

  static func name(_ op: UInt16) -> String {
    if let i = info(op) { return i.name }
    switch op {
    case 5380: return "OpDemoteToHelperInvocation"
    case 5381: return "OpIsHelperInvocationEXT"
    default: return "Op#\(op)"
    }
  }
}
