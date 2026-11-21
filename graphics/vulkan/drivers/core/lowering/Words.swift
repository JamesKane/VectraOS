// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V as instructions, and back to words: what the lowering reads and writes (D174 step 5). The lowering works on
// the module's instructions in their logical sections, not on the compiler's parsed `SPIRVModule`: it must take what
// the compiler would refuse (a matrix in a uniform block) and hand on what it doesn't touch, so it keeps every
// instruction it doesn't change. Arrays only, no hashed collections: this is device code (tier 0).

/// The opcodes, storage classes, decorations and enumerants the lowering names (the SPIR-V specification's numbers).
enum SPV {
  static let magic: UInt32 = 0x0723_0203

  // Opcodes.
  static let opNop: UInt16 = 0
  static let opUndef: UInt16 = 1
  static let opSourceContinued: UInt16 = 2
  static let opSource: UInt16 = 3
  static let opSourceExtension: UInt16 = 4
  static let opName: UInt16 = 5
  static let opMemberName: UInt16 = 6
  static let opString: UInt16 = 7
  static let opLine: UInt16 = 8
  static let opExtension: UInt16 = 10
  static let opExtInstImport: UInt16 = 11
  static let opExtInst: UInt16 = 12
  static let opMemoryModel: UInt16 = 14
  static let opEntryPoint: UInt16 = 15
  static let opExecutionMode: UInt16 = 16
  static let opCapability: UInt16 = 17
  static let opTypeVoid: UInt16 = 19
  static let opTypeBool: UInt16 = 20
  static let opTypeInt: UInt16 = 21
  static let opTypeFloat: UInt16 = 22
  static let opTypeVector: UInt16 = 23
  static let opTypeMatrix: UInt16 = 24
  static let opTypeImage: UInt16 = 25
  static let opTypeSampler: UInt16 = 26
  static let opTypeSampledImage: UInt16 = 27
  static let opTypeArray: UInt16 = 28
  static let opTypeRuntimeArray: UInt16 = 29
  static let opTypeStruct: UInt16 = 30
  static let opTypePointer: UInt16 = 32
  static let opTypeFunction: UInt16 = 33
  static let opTypeForwardPointer: UInt16 = 39
  static let opConstant: UInt16 = 43
  static let opFunction: UInt16 = 54
  static let opFunctionEnd: UInt16 = 56
  static let opFunctionCall: UInt16 = 57
  static let opVariable: UInt16 = 59
  static let opImageTexelPointer: UInt16 = 60
  static let opLoad: UInt16 = 61
  static let opStore: UInt16 = 62
  static let opCopyMemory: UInt16 = 63
  static let opCopyMemorySized: UInt16 = 64
  static let opAccessChain: UInt16 = 65
  static let opInBoundsAccessChain: UInt16 = 66
  static let opPtrAccessChain: UInt16 = 67
  static let opArrayLength: UInt16 = 68
  static let opInBoundsPtrAccessChain: UInt16 = 70
  static let opDecorate: UInt16 = 71
  static let opMemberDecorate: UInt16 = 72
  static let opDecorationGroup: UInt16 = 73
  static let opGroupDecorate: UInt16 = 74
  static let opGroupMemberDecorate: UInt16 = 75
  static let opCompositeConstruct: UInt16 = 80
  static let opCopyObject: UInt16 = 83
  static let opSampledImage: UInt16 = 86
  static let opImageSampleImplicitLod: UInt16 = 87
  static let opImage: UInt16 = 100
  static let opImageRead: UInt16 = 98
  static let opImageWrite: UInt16 = 99
  static let opConvertFToU: UInt16 = 109
  static let opConvertUToF: UInt16 = 112
  static let opUConvert: UInt16 = 113
  static let opConvertPtrToU: UInt16 = 117
  static let opConvertUToPtr: UInt16 = 120
  static let opBitcast: UInt16 = 124
  static let opIAdd: UInt16 = 128
  static let opIMul: UInt16 = 132
  static let opISub: UInt16 = 130
  static let opFDiv: UInt16 = 136
  static let opUDiv: UInt16 = 134
  static let opSelect: UInt16 = 169
  static let opShiftRightLogical: UInt16 = 194
  static let opBitwiseAnd: UInt16 = 199
  static let opAtomicLoad: UInt16 = 227
  static let opAtomicStore: UInt16 = 228
  static let opAtomicXor: UInt16 = 242
  static let opPhi: UInt16 = 245
  static let opLabel: UInt16 = 248
  static let opNoLine: UInt16 = 317
  static let opModuleProcessed: UInt16 = 330
  static let opExecutionModeId: UInt16 = 331
  static let opDecorateId: UInt16 = 332
  static let opDecorateString: UInt16 = 5632
  static let opMemberDecorateString: UInt16 = 5633

  // Storage classes.
  static let uniformConstant: UInt32 = 0
  static let input: UInt32 = 1
  static let uniform: UInt32 = 2
  static let private_: UInt32 = 6
  static let pushConstant: UInt32 = 9
  static let storageBuffer: UInt32 = 12
  static let physicalStorageBuffer: UInt32 = 5349

  // Decorations.
  static let decBlock: UInt32 = 2
  static let decBufferBlock: UInt32 = 3
  static let decArrayStride: UInt32 = 6
  static let decBuiltIn: UInt32 = 11
  static let decNonWritable: UInt32 = 24
  static let decLocation: UInt32 = 30
  static let decBinding: UInt32 = 33
  static let decDescriptorSet: UInt32 = 34
  static let decOffset: UInt32 = 35
  static let decNonUniform: UInt32 = 5300

  // Built-ins.
  static let builtInVertexIndex: UInt32 = 42
  static let builtInInstanceIndex: UInt32 = 43

  // Capabilities.
  static let capInt64: UInt32 = 11
  static let capShaderNonUniform: UInt32 = 5301
  static let capRuntimeDescriptorArray: UInt32 = 5302
  static let capSampledImageArrayNonUniformIndexing: UInt32 = 5307
  static let capStorageImageArrayNonUniformIndexing: UInt32 = 5309
  static let capPhysicalStorageBufferAddresses: UInt32 = 5347

  static let addressingPhysicalStorageBuffer64: UInt32 = 5348
  static let memoryAccessAligned: UInt32 = 2

  // Execution models.
  static let modelVertex: UInt32 = 0
  static let modelTessellationControl: UInt32 = 1
  static let modelTessellationEvaluation: UInt32 = 2
  static let modelGeometry: UInt32 = 3
  static let modelFragment: UInt32 = 4
  static let modelGLCompute: UInt32 = 5

  /// Whether an instruction has a result type and a result id (word 1 and 2 of the instruction after its header).
  static func resultInfo(_ op: UInt16) -> (type: Bool, result: Bool) {
    if op >= opTypeVoid && op <= 38 { return (false, true) }
    switch op {
    case opString, opExtInstImport, opDecorationGroup, opLabel: return (false, true)
    case opNop, opSourceContinued, opSource, opSourceExtension, opName, opMemberName, opLine, opExtension,
      opMemoryModel, opEntryPoint, opExecutionMode, opCapability, opTypeForwardPointer, opFunctionEnd, opStore,
      opCopyMemory, opCopyMemorySized, opDecorate, opMemberDecorate, opGroupDecorate, opGroupMemberDecorate,
      opImageWrite, 218, 219, 224, 225, opAtomicStore, 246, 247, 249, 250, 251, 252, 253, 254, 255, 256, 257,
      opNoLine, opModuleProcessed, opExecutionModeId, opDecorateId, 4416, 5380, opDecorateString,
      opMemberDecorateString:
      return (false, false)
    default: return (true, true)
    }
  }

  /// The words of a literal string, with its terminating zero byte, padded to words.
  static func stringWords(_ s: String) -> [UInt32] {
    var bytes = Array(s.utf8)
    bytes.append(0)
    while bytes.count % 4 != 0 { bytes.append(0) }
    var out: [UInt32] = []
    var i = 0
    while i < bytes.count {
      out.append(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
      i += 4
    }
    return out
  }

  /// The index of the word after the literal string starting at `from` in `w`, and whether it equals `name`.
  static func stringAt(_ w: [UInt32], _ from: Int, equals name: String) -> (next: Int, equal: Bool) {
    let want = Array(name.utf8)
    var at = 0
    var equal = true
    var i = from
    while i < w.count {
      let x = w[i]
      i += 1
      for s in 0..<4 {
        let b = UInt8(truncatingIfNeeded: x >> UInt32(8 * s))
        if b == 0 {
          if at != want.count { equal = false }
          return (i, equal)
        }
        if at >= want.count || want[at] != b { equal = false }
        at += 1
      }
    }
    return (i, false)
  }
}

/// An instruction without its header word: its operands, starting with the result type and id where it has them.
struct RawInst {
  var op: UInt16
  var w: [UInt32]
  init(_ op: UInt16, _ w: [UInt32]) {
    self.op = op
    self.w = w
  }
}

/// A module in the logical layout's sections, in the order they are written.
struct RawModule {
  var version: UInt32 = 0
  var generator: UInt32 = 0
  var bound: UInt32 = 0
  var capabilities: [RawInst] = []
  var extensions: [RawInst] = []
  var extInstImports: [RawInst] = []
  var memoryModel = RawInst(SPV.opMemoryModel, [0, 1])
  var entryPoints: [RawInst] = []
  var executionModes: [RawInst] = []
  var debug: [RawInst] = []
  var annotations: [RawInst] = []
  /// Types, constants and global variables, in an order that defines every id before its use.
  var globals: [RawInst] = []
  /// Each function, from its OpFunction to its OpFunctionEnd.
  var functions: [[RawInst]] = []

  static func parse(_ words: [UInt32]) throws(LoweringError) -> RawModule {
    guard words.count >= 5 else { throw .malformed("shorter than SPIR-V's five-word header") }
    guard words[0] == SPV.magic else { throw .malformed("bad magic number") }
    var m = RawModule()
    m.version = words[1]
    m.generator = words[2]
    m.bound = words[3]
    guard m.bound > 0 && m.bound < 1 << 22 else { throw .malformed("id bound \(m.bound) is out of range") }
    var pos = 5
    var current: [RawInst]? = nil
    var inFunction = false
    while pos < words.count {
      let head = words[pos]
      let count = Int(head >> 16)
      let op = UInt16(truncatingIfNeeded: head)
      guard count >= 1, pos + count <= words.count else { throw .malformed("an instruction at word \(pos) is truncated") }
      let inst = RawInst(op, Array(words[(pos + 1)..<(pos + count)]))
      pos += count
      if inFunction {
        current!.append(inst)
        if op == SPV.opFunctionEnd {
          m.functions.append(current!)
          current = nil
          inFunction = false
        }
        continue
      }
      switch op {
      case SPV.opFunction:
        inFunction = true
        current = [inst]
      case SPV.opCapability: m.capabilities.append(inst)
      case SPV.opExtension: m.extensions.append(inst)
      case SPV.opExtInstImport: m.extInstImports.append(inst)
      case SPV.opMemoryModel:
        guard inst.w.count == 2 else { throw .malformed("OpMemoryModel needs two operands") }
        m.memoryModel = inst
      case SPV.opEntryPoint: m.entryPoints.append(inst)
      case SPV.opExecutionMode, SPV.opExecutionModeId: m.executionModes.append(inst)
      case SPV.opSourceContinued, SPV.opSource, SPV.opSourceExtension, SPV.opString, SPV.opName, SPV.opMemberName,
        SPV.opLine, SPV.opNoLine, SPV.opModuleProcessed:
        m.debug.append(inst)
      case SPV.opDecorate, SPV.opMemberDecorate, SPV.opDecorationGroup, SPV.opGroupDecorate,
        SPV.opGroupMemberDecorate, SPV.opDecorateId, SPV.opDecorateString, SPV.opMemberDecorateString:
        m.annotations.append(inst)
      default: m.globals.append(inst)
      }
    }
    guard !inFunction else { throw .malformed("the module ends inside a function") }
    return m
  }

  func encode() -> [UInt32] {
    var out: [UInt32] = [SPV.magic, version, generator, bound, 0]
    func put(_ list: [RawInst], _ out: inout [UInt32]) {
      for i in list {
        out.append(UInt32(i.w.count + 1) << 16 | UInt32(i.op))
        out.append(contentsOf: i.w)
      }
    }
    put(capabilities, &out)
    put(extensions, &out)
    put(extInstImports, &out)
    put([memoryModel], &out)
    put(entryPoints, &out)
    put(executionModes, &out)
    put(debug, &out)
    put(annotations, &out)
    put(globals, &out)
    for f in functions { put(f, &out) }
    return out
  }
}
