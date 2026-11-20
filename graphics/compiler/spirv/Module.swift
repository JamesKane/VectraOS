// SPDX-License-Identifier: BSD-3-Clause

// A parsed SPIR-V module: what `SPIRVModule.parse` returns once the reader
// has validated its structure. Ids index the arrays; an id not of that kind
// has nil (or 0) in its slot.

public enum StorageClass {
  public static let uniformConstant: UInt32 = 0
  public static let input: UInt32 = 1
  public static let uniform: UInt32 = 2
  public static let output: UInt32 = 3
  public static let workgroup: UInt32 = 4
  public static let crossWorkgroup: UInt32 = 5
  public static let private_: UInt32 = 6
  public static let function: UInt32 = 7
  public static let generic: UInt32 = 8
  public static let pushConstant: UInt32 = 9
  public static let atomicCounter: UInt32 = 10
  public static let image: UInt32 = 11
  public static let storageBuffer: UInt32 = 12
  public static let physicalStorageBuffer: UInt32 = 5349

  public static func name(_ c: UInt32) -> String {
    switch c {
    case 0: return "UniformConstant"
    case 1: return "Input"
    case 2: return "Uniform"
    case 3: return "Output"
    case 4: return "Workgroup"
    case 5: return "CrossWorkgroup"
    case 6: return "Private"
    case 7: return "Function"
    case 8: return "Generic"
    case 9: return "PushConstant"
    case 10: return "AtomicCounter"
    case 11: return "Image"
    case 12: return "StorageBuffer"
    case 5349: return "PhysicalStorageBuffer"
    default: return "StorageClass#\(c)"
    }
  }
}

public enum Decor {
  public static let specId: UInt32 = 1
  public static let block: UInt32 = 2
  public static let bufferBlock: UInt32 = 3
  public static let arrayStride: UInt32 = 6
  public static let builtIn: UInt32 = 11
  public static let nonWritable: UInt32 = 24
  public static let nonReadable: UInt32 = 25
  public static let location: UInt32 = 30
  public static let binding: UInt32 = 33
  public static let descriptorSet: UInt32 = 34
  public static let offset: UInt32 = 35
}

public enum BuiltInId {
  public static let numWorkgroups: UInt32 = 24
  public static let workgroupSize: UInt32 = 25
  public static let workgroupId: UInt32 = 26
  public static let localInvocationId: UInt32 = 27
  public static let globalInvocationId: UInt32 = 28
  public static let localInvocationIndex: UInt32 = 29
  public static let subgroupSize: UInt32 = 36
  public static let numSubgroups: UInt32 = 38
  public static let subgroupId: UInt32 = 40
  public static let subgroupLocalInvocationId: UInt32 = 41

  public static func name(_ b: UInt32) -> String {
    switch b {
    case 0: return "Position"
    case 1: return "PointSize"
    case 5: return "VertexId"
    case 6: return "InstanceId"
    case 15: return "FragCoord"
    case 17: return "FrontFacing"
    case 22: return "FragDepth"
    case 24: return "NumWorkgroups"
    case 25: return "WorkgroupSize"
    case 26: return "WorkgroupId"
    case 27: return "LocalInvocationId"
    case 28: return "GlobalInvocationId"
    case 29: return "LocalInvocationIndex"
    case 36: return "SubgroupSize"
    case 38: return "NumSubgroups"
    case 40: return "SubgroupId"
    case 41: return "SubgroupLocalInvocationId"
    case 42: return "VertexIndex"
    case 43: return "InstanceIndex"
    default: return "BuiltIn#\(b)"
    }
  }
}

public enum SPIRVType: Equatable {
  case void
  case bool
  case int(width: Int, signed: Bool)
  case float(width: Int)
  case vector(element: UInt32, count: Int)
  case array(element: UInt32, length: UInt32)  // length: a constant's id
  case runtimeArray(element: UInt32)
  case structure(members: [UInt32])
  case pointer(storage: UInt32, pointee: UInt32)
  case function(returns: UInt32, params: [UInt32])
}

public enum SPIRVConstantKind: Equatable {
  case bool(Bool)
  case scalar(UInt64)  // the bit pattern, in the low `width` bits
  case composite([UInt32])
  case null
  /// OpSpecConstantOp: the opcode and its operand words (ids, then literals).
  case specOp(opcode: UInt16, operands: [UInt32])
}

public struct SPIRVConstant: Equatable {
  public var type: UInt32
  public var kind: SPIRVConstantKind
  /// The SpecId decoration, for a specialization constant.
  public var specId: UInt32?
  public var isSpec: Bool
}

public struct SPIRVVariable {
  public var id: UInt32
  public var type: UInt32  // the pointer type
  public var storage: UInt32
  public var initializer: UInt32  // a constant's id, or 0
}

public struct SPIRVEntryPoint {
  public var model: UInt32  // 5: GLCompute
  public var function: UInt32
  public var name: String
  public var interface: [UInt32]
}

public struct SPIRVExecutionMode {
  public var function: UInt32
  public var mode: UInt32
  public var operands: [UInt32]
}

public struct SPIRVDecoration {
  public var target: UInt32
  public var member: Int  // -1: the id itself
  public var kind: UInt32
  public var operands: [UInt32]
}

public struct SPIRVInstruction {
  public var op: UInt16
  public var type: UInt32  // the result type id, or 0
  public var result: UInt32  // the result id, or 0
  public var operands: [UInt32]

  public var name: String { OpTable.name(op) }
}

public struct SPIRVBlock {
  public var label: UInt32
  public var instructions: [SPIRVInstruction]  // after the OpLabel, ending in the terminator
}

public struct SPIRVFunction {
  public var id: UInt32
  public var returnType: UInt32
  public var control: UInt32
  public var type: UInt32  // the function type
  public var parameters: [(id: UInt32, type: UInt32)]
  public var blocks: [SPIRVBlock]
}

public struct SPIRVModule {
  public var version: UInt32 = 0
  public var generator: UInt32 = 0
  public var bound: UInt32 = 0
  public var capabilities: [UInt32] = []
  public var extensions: [String] = []
  public var extInstImports: [(id: UInt32, name: String)] = []
  public var addressingModel: UInt32 = 0  // 0 Logical, 2 Physical64, 5348 PhysicalStorageBuffer64
  public var memoryModel: UInt32 = 0  // 1 GLSL450, 3 Vulkan
  public var entryPoints: [SPIRVEntryPoint] = []
  public var executionModes: [SPIRVExecutionMode] = []
  public var names: [(id: UInt32, member: Int, name: String)] = []
  public var decorations: [SPIRVDecoration] = []
  /// By id.
  public var types: [SPIRVType?] = []
  public var constants: [SPIRVConstant?] = []
  /// The result type of every id that has one (values, constants, variables).
  public var idType: [UInt32] = []
  /// Index into `variables`, or -1.
  public var variableIndex: [Int32] = []
  public var variables: [SPIRVVariable] = []
  public var functions: [SPIRVFunction] = []
  /// Index into `functions`, or -1.
  public var functionIndex: [Int32] = []

  public init() {}

  public func hasCapability(_ c: UInt32) -> Bool { capabilities.contains(c) }

  /// The operands of an id's first decoration of this kind.
  public func decoration(_ id: UInt32, _ kind: UInt32) -> [UInt32]? {
    for d in decorations where d.target == id && d.member < 0 && d.kind == kind { return d.operands }
    return nil
  }

  public func memberDecoration(_ id: UInt32, _ member: Int, _ kind: UInt32) -> [UInt32]? {
    for d in decorations where d.target == id && d.member == member && d.kind == kind { return d.operands }
    return nil
  }

  /// The debug name of an id (OpName), if it has one.
  public func name(of id: UInt32) -> String? {
    for n in names where n.id == id && n.member < 0 { return n.name }
    return nil
  }

  public func type(_ id: UInt32) -> SPIRVType? {
    Int(id) < types.count ? types[Int(id)] : nil
  }

  public func constant(_ id: UInt32) -> SPIRVConstant? {
    Int(id) < constants.count ? constants[Int(id)] : nil
  }

  /// The words one OpSwitch case takes (its literal, then the label) for a
  /// selector id: the literal is as wide as the selector.
  public func switchWords(_ selector: UInt32) -> Int {
    guard Int(selector) < idType.count, case .int(let width, _)? = type(idType[Int(selector)]) else { return 2 }
    return width == 64 ? 3 : 2
  }

  /// The value of an integer constant (a scalar's low bits), if it is one.
  public func constantInt(_ id: UInt32) -> UInt64? {
    guard let c = constant(id), case .scalar(let v) = c.kind else { return nil }
    return v
  }
}
