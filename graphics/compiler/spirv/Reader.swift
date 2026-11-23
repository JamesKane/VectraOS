// SPDX-License-Identifier: BSD-3-Clause

// The SPIR-V reader: parses a binary module and validates its structure
// against the subset the compiler supports (module layout, ids defined once,
// types well formed, blocks and their merges, capabilities). What it does not
// support it refuses by name; it never guesses. The semantics of each
// instruction's operands are checked where they are lowered (Lower.swift).

/// What the reader accepts. Everything else is named in a refusal.
enum Supported {
  static let capabilities: [UInt32] = [0, 1, 9, 10, 11, 22, 39, 12, 31, 49, 50, 25, 34, 43, 44, 45, 48, 51, 2, 35, 61, 69, 70, 4427, 5254, 5347, 5301, 5302, 5307, 5309, 5311, 5312, 5379, 46, 47, 5013, 4439] + aluCapabilities
  static func capabilityName(_ c: UInt32) -> String {
    switch c {
    case 0: return "Matrix"
    case 1: return "Shader"
    case 2: return "Geometry"
    case 3: return "Tessellation"
    case 4: return "Addresses"
    case 5: return "Linkage"
    case 6: return "Kernel"
    case 9: return "Float16"
    case 10: return "Float64"
    case 11: return "Int64"
    case 12: return "Int64Atomics"
    case 13: return "ImageBasic"
    case 20: return "Float16Buffer"
    case 21: return "Sampled1D"
    case 22: return "Int16"
    case 23: return "ImageGatherExtended"
    case 25: return "StorageImageExtendedFormats"
    case 32: return "ImageQuery"
    case 33: return "DerivativeControl"
    case 39: return "Int8"
    case 31: return "StorageImageArrayDynamicIndexing"
    case 49: return "StorageImageExtendedFormats"
    case 5309: return "StorageImageArrayNonUniformIndexing"
    case 5311: return "UniformTexelBufferArrayNonUniformIndexing"
    case 5312: return "StorageTexelBufferArrayNonUniformIndexing"
    case 46: return "SampledBuffer"
    case 47: return "ImageBuffer"
    case 50: return "ImageQuery"
    case 40: return "SparseResidency"
    case 61: return "GroupNonUniform"
    case 62: return "GroupNonUniformVote"
    case 63: return "GroupNonUniformArithmetic"
    case 64: return "GroupNonUniformBallot"
    case 65: return "GroupNonUniformShuffle"
    case 4433: return "StorageBuffer16BitAccess"
    case 4434: return "UniformAndStorageBuffer16BitAccess"
    case 4441: return "VariablePointersStorageBuffer"
    case 5301: return "ShaderNonUniform"
    case 5302: return "RuntimeDescriptorArray"
    case 5307: return "SampledImageArrayNonUniformIndexing"
    case 5379: return "DemoteToHelperInvocation"
    case 5013: return "StencilExportEXT"
    case 4439: return "MultiView"
    case 4442: return "VariablePointers"
    case 5345: return "VulkanMemoryModel"
    case 5347: return "PhysicalStorageBufferAddresses"
    default: return "Capability#\(c)"
    }
  }
  static func executionModelName(_ m: UInt32) -> String {
    switch m {
    case 0: return "Vertex"
    case 1: return "TessellationControl"
    case 2: return "TessellationEvaluation"
    case 3: return "Geometry"
    case 4: return "Fragment"
    case 5: return "GLCompute"
    case 6: return "Kernel"
    default: return "ExecutionModel#\(m)"
    }
  }
  /// Storage classes of variables and pointers.
  static func storageOK(_ c: UInt32) -> Bool {
    switch c {
    case 0, 1, 2, 3, 4, 6, 7, 9, 11, 12, 5349: return true
    default: return false
    }
  }
  static func decorationName(_ d: UInt32) -> String {
    switch d {
    case 5300: return "NonUniform"
    case 5355: return "RestrictPointer"
    default: return "#\(d)"
    }
  }
  static func decorationOK(_ d: UInt32) -> Bool {
    d <= 47 || d == 5300 || d == 4469 || d == 4470 || d == 5355 || d == 5356
  }
}

private struct Parser {
  var m = SPIRVModule()
  var kind: [UInt8] = []  // see `Kind`
  var words: [UInt32]
  var pos = 5

  enum Kind {
    static let none: UInt8 = 0
    static let type: UInt8 = 1
    static let const: UInt8 = 2
    static let variable: UInt8 = 3
    static let function: UInt8 = 4
    static let label: UInt8 = 5
    static let value: UInt8 = 6
    static let extImport: UInt8 = 7
    static let string: UInt8 = 8
    static let param: UInt8 = 9
  }

  init(words: [UInt32]) { self.words = words }

  func err(_ i: SPIRVInstruction, _ msg: String) -> CompileError {
    if i.result != 0 { return CompileError("\(i.name) %\(i.result): \(msg)") }
    return CompileError("\(i.name): \(msg)")
  }

  func kindOf(_ id: UInt32) -> UInt8 { Int(id) < kind.count ? kind[Int(id)] : 0 }

  /// Pointer types declared by OpTypeForwardPointer and not yet defined.
  var forward: [UInt32] = []

  mutating func define(_ i: SPIRVInstruction, _ k: UInt8) throws(CompileError) {
    guard i.result != 0, i.result < m.bound else {
      throw err(i, "result id \(i.result) is outside the module's bound \(m.bound)")
    }
    if i.op == Op.typePointer, let n = forward.firstIndex(of: i.result) {
      forward.remove(at: n)
      if i.type != 0 { m.idType[Int(i.result)] = i.type }
      return
    }
    guard kind[Int(i.result)] == Kind.none else { throw err(i, "id is defined twice") }
    kind[Int(i.result)] = k
    if i.type != 0 { m.idType[Int(i.result)] = i.type }
  }

  func needType(_ i: SPIRVInstruction, _ id: UInt32, _ what: String) throws(CompileError) -> SPIRVType {
    guard kindOf(id) == Kind.type, let t = m.type(id) else { throw err(i, "\(what) %\(id) is not a type") }
    return t
  }

  func needConst(_ i: SPIRVInstruction, _ id: UInt32, _ what: String) throws(CompileError) {
    guard kindOf(id) == Kind.const else { throw err(i, "\(what) %\(id) is not a constant") }
  }

  static func string(_ w: [UInt32], from: Int) -> (String, Int) {
    var bytes: [UInt8] = []
    var i = from
    while i < w.count {
      let x = w[i]
      i += 1
      var done = false
      for s in 0..<4 {
        let b = UInt8(truncatingIfNeeded: x >> UInt32(8 * s))
        if b == 0 {
          done = true
          break
        }
        bytes.append(b)
      }
      if done { return (String(decoding: bytes, as: UTF8.self), i) }
    }
    return (String(decoding: bytes, as: UTF8.self), i)
  }

  func requireWidth(_ i: SPIRVInstruction, int width: Int) throws(CompileError) {
    switch width {
    case 32: break
    case 64: if !m.hasCapability(11) { throw err(i, "64-bit integers need capability Int64") }
    case 16: if !m.hasCapability(22) { throw err(i, "16-bit integers need capability Int16") }
    case 8: if !m.hasCapability(39) { throw err(i, "8-bit integers need capability Int8") }
    default: throw err(i, "integer width \(width) is not supported")
    }
  }

  mutating func run() throws(CompileError) {
    guard words.count >= 5 else { throw CompileError("module: shorter than SPIR-V's 5-word header") }
    if words[0] == 0x0302_2307 { throw CompileError("module: big-endian SPIR-V is not supported") }
    guard words[0] == 0x0723_0203 else { throw CompileError("module: bad magic number \(words[0])") }
    m.version = words[1]
    m.generator = words[2]
    m.bound = words[3]
    guard m.version >= 0x0001_0000 && m.version <= 0x0001_0600 else {
      throw CompileError("module: SPIR-V version \(m.version >> 16).\((m.version >> 8) & 0xff) is not supported")
    }
    guard m.bound > 0 && m.bound <= 1 << 22 else { throw CompileError("module: id bound \(m.bound) is out of range") }
    let n = Int(m.bound)
    kind = [UInt8](repeating: 0, count: n)
    m.types = [SPIRVType?](repeating: nil, count: n)
    m.constants = [SPIRVConstant?](repeating: nil, count: n)
    m.idType = [UInt32](repeating: 0, count: n)
    m.variableIndex = [Int32](repeating: -1, count: n)
    m.functionIndex = [Int32](repeating: -1, count: n)

    var current: SPIRVFunction? = nil
    var block: SPIRVBlock? = nil
    var pendingMerge: SPIRVInstruction? = nil
    var inPhis = false

    while pos < words.count {
      let head = words[pos]
      let count = Int(head >> 16)
      let opcode = UInt16(truncatingIfNeeded: head)
      guard count >= 1, pos + count <= words.count else {
        throw CompileError("module: instruction at word \(pos) is truncated (word count \(count))")
      }
      let w = Array(words[pos..<pos + count])
      pos += count
      guard let info = OpTable.info(opcode) else {
        throw CompileError("\(OpTable.name(opcode)): not supported by the compiler")
      }
      var i = SPIRVInstruction(op: opcode, type: 0, result: 0, operands: [])
      var at = 1
      if info.hasType {
        guard count >= 3 else { throw CompileError("\(info.name): missing result type and id") }
        i.type = w[1]
        i.result = w[2]
        at = 3
        guard i.type < m.bound, kindOf(i.type) == Kind.type else {
          throw CompileError("\(info.name) %\(i.result): result type %\(i.type) is not a type")
        }
      } else if info.hasResult {
        guard count >= 2 else { throw CompileError("\(info.name): missing result id") }
        i.result = w[1]
        at = 2
      }
      i.operands = Array(w[at...])
      if info.refused { throw err(i, "not supported by the compiler") }

      // A function's body.
      if current != nil {
        switch opcode {
        case Op.functionParameter:
          guard block == nil, current!.blocks.isEmpty else { throw err(i, "a parameter after the first block") }
          try define(i, Kind.param)
          current!.parameters.append((id: i.result, type: i.type))
        case Op.label:
          guard block == nil else { throw err(i, "a block starts before the previous one ended") }
          try define(i, Kind.label)
          block = SPIRVBlock(label: i.result, instructions: [])
          inPhis = true
          pendingMerge = nil
        case Op.functionEnd:
          guard block == nil else {
            throw err(i, "the function ends in block %\(block!.label), which has no terminator")
          }
          guard !current!.blocks.isEmpty else { throw err(i, "function %\(current!.id) has no blocks") }
          try checkFunction(current!)
          m.functionIndex[Int(current!.id)] = Int32(m.functions.count)
          m.functions.append(current!)
          current = nil
        default:
          guard block != nil else {
            if opcode == Op.nop || opcode == Op.line || opcode == Op.noLine { continue }
            throw err(i, "an instruction outside a block")
          }
          if opcode == Op.line || opcode == Op.noLine || opcode == Op.nop { continue }
          if opcode != Op.phi { inPhis = false } else if !inPhis { throw err(i, "OpPhi after another instruction") }
          if info.hasResult && opcode != Op.variable { try define(i, Kind.value) }
          if opcode == Op.variable {
            guard i.operands.first == StorageClass.function else {
              throw err(i, "a variable in a function must have storage class Function")
            }
            guard current!.blocks.isEmpty else {
              throw err(i, "a Function variable outside the entry block")
            }
            try define(i, Kind.value)
            guard case .pointer(let sc, _) = try needType(i, i.type, "type"), sc == StorageClass.function else {
              throw err(i, "the type is not a Function pointer")
            }
          }
          if let pm = pendingMerge {
            guard opcode == Op.branch || opcode == Op.branchConditional || opcode == Op.switch_ else {
              throw err(pm, "must be immediately followed by a branch")
            }
            if pm.op == Op.selectionMerge && opcode == Op.branch {
              throw err(pm, "a selection merge must be followed by OpBranchConditional or OpSwitch")
            }
            pendingMerge = nil
          }
          if opcode == Op.selectionMerge || opcode == Op.loopMerge {
            guard i.operands.count >= (opcode == Op.loopMerge ? 3 : 2) else { throw err(i, "too few operands") }
            pendingMerge = i
          }
          block!.instructions.append(i)
          switch opcode {
          case Op.branch, Op.branchConditional, Op.switch_, Op.kill, Op.return_, Op.returnValue, Op.unreachable:
            try checkTerminator(i)
            current!.blocks.append(block!)
            block = nil
          default: break
          }
        }
        continue
      }

      // The module's sections.
      switch opcode {
      case Op.capability:
        guard let c = i.operands.first, i.operands.count == 1 else { throw err(i, "needs one operand") }
        guard Supported.capabilities.contains(c) else {
          if c == 32 || c == 33 || c == 5284 || c == 5285 {
            throw err(i, "capability \(c == 32 ? "ClipDistance" : c == 33 ? "CullDistance" : "FragmentBarycentric"): the hardware has no clip distance, cull distance or barycentrics (valhall 14.3.7)")
          }
          throw err(i, "capability \(Supported.capabilityName(c)) is not supported")
        }
        m.capabilities.append(c)
      case Op.extension_:
        m.extensions.append(Parser.string(i.operands, from: 0).0)
      case Op.extInstImport:
        let (s, _) = Parser.string(i.operands, from: 0)
        guard s.utf8.elementsEqual("GLSL.std.450".utf8) else { throw err(i, "extended instruction set \(s) is not supported") }
        try define(i, Kind.extImport)
        m.extInstImports.append((id: i.result, name: s))
      case Op.memoryModel:
        guard i.operands.count == 2 else { throw err(i, "needs two operands") }
        guard i.operands[0] == 0 || i.operands[0] == 5348 else {
          throw err(i, "addressing model \(i.operands[0]) is not supported (Logical and PhysicalStorageBuffer64 are)")
        }
        guard i.operands[1] == 1 || i.operands[1] == 3 else {
          throw err(i, "memory model \(i.operands[1]) is not supported (GLSL450 and Vulkan are)")
        }
        m.addressingModel = i.operands[0]
        m.memoryModel = i.operands[1]
      case Op.entryPoint:
        guard i.operands.count >= 3 else { throw err(i, "too few operands") }
        let model = i.operands[0]
        guard model == 0 || model == 4 || model == 5 else {
          throw err(i, "execution model \(Supported.executionModelName(model)) is not supported")
        }
        let (nm, next) = Parser.string(i.operands, from: 2)
        m.entryPoints.append(
          SPIRVEntryPoint(model: model, function: i.operands[1], name: nm, interface: Array(i.operands[next...])))
      case Op.executionMode:
        guard i.operands.count >= 2 else { throw err(i, "too few operands") }
        m.executionModes.append(
          SPIRVExecutionMode(function: i.operands[0], mode: i.operands[1], operands: Array(i.operands[2...])))
      case Op.source, Op.sourceContinued, Op.sourceExtension, Op.line, Op.noLine, Op.nop: break
      case Op.string:
        try define(i, Kind.string)
      case Op.name:
        guard !i.operands.isEmpty else { throw err(i, "too few operands") }
        m.names.append((id: i.operands[0], member: -1, name: Parser.string(i.operands, from: 1).0))
      case Op.memberName:
        guard i.operands.count >= 2 else { throw err(i, "too few operands") }
        m.names.append((id: i.operands[0], member: Int(i.operands[1]), name: Parser.string(i.operands, from: 2).0))
      case Op.decorate, Op.memberDecorate:
        let member = opcode == Op.memberDecorate
        guard i.operands.count >= (member ? 3 : 2) else { throw err(i, "too few operands") }
        let k = i.operands[member ? 2 : 1]
        guard Supported.decorationOK(k) else { throw err(i, "decoration \(Supported.decorationName(k)) is not supported") }
        m.decorations.append(
          SPIRVDecoration(
            target: i.operands[0], member: member ? Int(i.operands[1]) : -1, kind: k,
            operands: Array(i.operands[(member ? 3 : 2)...])))
      case Op.typeForwardPointer:
        // The pointer type is declared here and defined by an OpTypePointer later; until then it is a pointer to
        // nothing, which is all a struct that holds it needs.
        guard i.operands.count == 2, i.operands[0] < m.bound else { throw err(i, "needs a pointer type and a storage class") }
        let id = Int(i.operands[0])
        guard kind[id] == Kind.none else { throw err(i, "id is defined twice") }
        guard Supported.storageOK(i.operands[1]) else {
          throw err(i, "storage class \(StorageClass.name(i.operands[1])) is not supported")
        }
        kind[id] = Kind.type
        m.types[id] = .pointer(storage: i.operands[1], pointee: 0)
        forward.append(i.operands[0])
      case Op.typeVoid, Op.typeBool, Op.typeInt, Op.typeFloat, Op.typeVector, Op.typeArray, Op.typeRuntimeArray,
        Op.typeStruct, Op.typePointer, Op.typeFunction, Op.typeImage, Op.typeSampler, Op.typeSampledImage:
        try parseType(i)
      case Op.constantTrue, Op.constantFalse, Op.constant, Op.constantComposite, Op.constantNull,
        Op.specConstantTrue, Op.specConstantFalse, Op.specConstant, Op.specConstantComposite, Op.specConstantOp,
        Op.undef:
        try parseConstant(i)
      case Op.variable:
        try define(i, Kind.variable)
        guard let sc = i.operands.first else { throw err(i, "needs a storage class") }
        guard Supported.storageOK(sc), sc != StorageClass.function, sc != StorageClass.physicalStorageBuffer else {
          throw err(i, "storage class \(StorageClass.name(sc)) is not supported for a module variable")
        }
        guard case .pointer(let psc, _) = try needType(i, i.type, "type"), psc == sc else {
          throw err(i, "the type is not a pointer in storage class \(StorageClass.name(sc))")
        }
        var initializer: UInt32 = 0
        if i.operands.count > 1 {
          initializer = i.operands[1]
          try needConst(i, initializer, "initializer")
        }
        m.variableIndex[Int(i.result)] = Int32(m.variables.count)
        m.variables.append(SPIRVVariable(id: i.result, type: i.type, storage: sc, initializer: initializer))
      case Op.function:
        guard i.operands.count == 2 else { throw err(i, "needs a control mask and a function type") }
        try define(i, Kind.function)
        guard case .function(let ret, _) = try needType(i, i.operands[1], "function type") else {
          throw err(i, "%\(i.operands[1]) is not a function type")
        }
        guard ret == i.type else { throw err(i, "the result type is not the function type's return type") }
        current = SPIRVFunction(
          id: i.result, returnType: i.type, control: i.operands[0], type: i.operands[1], parameters: [], blocks: [])
      default:
        throw err(i, "an instruction outside a function")
      }
    }
    guard current == nil else { throw CompileError("module: ends inside function %\(current!.id)") }
    for e in m.entryPoints {
      guard kindOf(e.function) == Kind.function else {
        throw CompileError("OpEntryPoint \(e.name): %\(e.function) is not a function")
      }
    }
    for e in m.executionModes {
      guard kindOf(e.function) == Kind.function else {
        throw CompileError("OpExecutionMode: %\(e.function) is not a function")
      }
    }
    // Parameter counts and types match the function types.
    for f in m.functions {
      if case .function(_, let params) = m.type(f.type)! {
        guard params.count == f.parameters.count else {
          throw CompileError(
            "OpFunction %\(f.id): \(f.parameters.count) parameters, but its type has \(params.count)")
        }
        for (a, b) in zip(params, f.parameters) where a != b.type {
          throw CompileError("OpFunctionParameter %\(b.id): its type is not the function type's")
        }
      }
    }
  }

  mutating func parseType(_ i: SPIRVInstruction) throws(CompileError) {
    try define(i, Kind.type)
    let o = i.operands
    let id = Int(i.result)
    switch i.op {
    case Op.typeVoid: m.types[id] = .void
    case Op.typeBool: m.types[id] = .bool
    case Op.typeInt:
      guard o.count == 2 else { throw err(i, "needs a width and a signedness") }
      try requireWidth(i, int: Int(o[0]))
      m.types[id] = .int(width: Int(o[0]), signed: o[1] != 0)
    case Op.typeFloat:
      guard o.count == 1 else { throw err(i, "needs a width") }
      switch o[0] {
      case 32: break
      case 16: if !m.hasCapability(9) { throw err(i, "16-bit floats need capability Float16") }
      case 64: if !m.hasCapability(10) { throw err(i, "64-bit floats need capability Float64") }
      default: throw err(i, "float width \(o[0]) is not supported")
      }
      m.types[id] = .float(width: Int(o[0]))
    case Op.typeVector:
      guard o.count == 2 else { throw err(i, "needs a component type and a count") }
      switch try needType(i, o[0], "component type") {
      case .bool, .int, .float: break
      default: throw err(i, "the component type must be a scalar")
      }
      guard o[1] >= 2 && o[1] <= 4 else { throw err(i, "the component count must be 2, 3 or 4") }
      m.types[id] = .vector(element: o[0], count: Int(o[1]))
    case Op.typeArray:
      guard o.count == 2 else { throw err(i, "needs an element type and a length") }
      _ = try needType(i, o[0], "element type")
      try needConst(i, o[1], "length")
      m.types[id] = .array(element: o[0], length: o[1])
    case Op.typeRuntimeArray:
      guard o.count == 1 else { throw err(i, "needs an element type") }
      _ = try needType(i, o[0], "element type")
      m.types[id] = .runtimeArray(element: o[0])
    case Op.typeStruct:
      for t in o { _ = try needType(i, t, "member type") }
      m.types[id] = .structure(members: o)
    case Op.typePointer:
      guard o.count == 2 else { throw err(i, "needs a storage class and a type") }
      guard Supported.storageOK(o[0]) else {
        throw err(i, "storage class \(StorageClass.name(o[0])) is not supported")
      }
      if o[0] == StorageClass.physicalStorageBuffer && !m.hasCapability(5347) {
        throw err(i, "PhysicalStorageBuffer pointers need capability PhysicalStorageBufferAddresses")
      }
      // The pointee may be a forward reference only for a self-referencing
      // struct, which OpTypeForwardPointer would declare; not supported.
      _ = try needType(i, o[1], "pointee type")
      m.types[id] = .pointer(storage: o[0], pointee: o[1])
    case Op.typeImage:
      guard o.count >= 7 else { throw err(i, "needs a sampled type, Dim, Depth, Arrayed, MS, Sampled and a format") }
      switch try needType(i, o[0], "sampled type") {
      case .float, .int: break
      default: throw err(i, "the sampled type must be a float or an integer scalar")
      }
      m.types[id] = .image(sampled: o[0], dim: o[1], depth: o[2], arrayed: o[3] != 0, multisampled: o[4] != 0, usage: o[5], format: o[6])
    case Op.typeSampler:
      guard o.isEmpty else { throw err(i, "takes no operands") }
      m.types[id] = .sampler
    case Op.typeSampledImage:
      guard o.count == 1, case .image = try needType(i, o[0], "image type") else { throw err(i, "needs an image type") }
      m.types[id] = .sampledImage(image: o[0])
    case Op.typeFunction:
      guard !o.isEmpty else { throw err(i, "needs a return type") }
      for t in o { _ = try needType(i, t, "type") }
      m.types[id] = .function(returns: o[0], params: Array(o[1...]))
    default: break
    }
  }

  func specId(_ id: UInt32) -> UInt32? { m.decoration(id, Decor.specId)?.first }

  mutating func parseConstant(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    if i.op == Op.undef {
      // OpUndef is also legal in the types section; an undefined value is
      // any value, so it becomes null.
      try define(i, Kind.const)
      m.constants[Int(i.result)] = SPIRVConstant(type: i.type, kind: .null, specId: nil, isSpec: false)
      return
    }
    try define(i, Kind.const)
    let ty = try needType(i, i.type, "result type")
    let spec = i.op == Op.specConstantTrue || i.op == Op.specConstantFalse || i.op == Op.specConstant
      || i.op == Op.specConstantComposite || i.op == Op.specConstantOp
    var k: SPIRVConstantKind
    switch i.op {
    case Op.constantTrue, Op.specConstantTrue:
      guard case .bool = ty else { throw err(i, "the type is not bool") }
      k = .bool(true)
    case Op.constantFalse, Op.specConstantFalse:
      guard case .bool = ty else { throw err(i, "the type is not bool") }
      k = .bool(false)
    case Op.constant, Op.specConstant:
      var width = 0
      switch ty {
      case .int(let w, _): width = w
      case .float(let w): width = w
      default: throw err(i, "the type is not a scalar number")
      }
      guard o.count == (width == 64 ? 2 : 1) else { throw err(i, "needs \(width == 64 ? 2 : 1) literal words") }
      var bits = UInt64(o[0])
      if width == 64 { bits |= UInt64(o[1]) << 32 }
      if width < 32 { bits &= (1 << UInt64(width)) - 1 }
      k = .scalar(bits)
    case Op.constantComposite, Op.specConstantComposite:
      var want = -1
      switch ty {
      case .vector(_, let n): want = n
      case .structure(let ms): want = ms.count
      case .array(_, let len):
        if let n = m.constantInt(len) { want = Int(n) }
      default: throw err(i, "the type is not a composite")
      }
      if want >= 0 && o.count != want { throw err(i, "has \(o.count) constituents, the type needs \(want)") }
      for c in o { try needConst(i, c, "constituent") }
      k = .composite(o)
    case Op.constantNull:
      k = .null
    default:  // OpSpecConstantOp
      guard !o.isEmpty else { throw err(i, "needs an opcode") }
      k = .specOp(opcode: UInt16(truncatingIfNeeded: o[0]), operands: Array(o[1...]))
    }
    m.constants[Int(i.result)] = SPIRVConstant(
      type: i.type, kind: k, specId: spec ? specId(i.result) : nil, isSpec: spec)
  }

  func checkTerminator(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    switch i.op {
    case Op.branch:
      guard o.count == 1 else { throw err(i, "needs one target") }
    case Op.branchConditional:
      guard o.count == 3 || o.count == 5 else { throw err(i, "needs a condition and two targets") }
    case Op.switch_:
      guard o.count >= 2 else { throw err(i, "needs a selector and a default") }
      guard o[0] < m.bound, case .int? = m.type(m.idType[Int(o[0])]) else {
        throw err(i, "the selector is not an integer")
      }
      let per = m.switchWords(o[0])
      guard (o.count - 2) % per == 0 else { throw err(i, "its cases don't match the selector's width") }
    case Op.returnValue:
      guard o.count == 1 else { throw err(i, "needs a value") }
    case Op.kill:
      guard o.isEmpty else { throw err(i, "takes no operands") }
    default: break
    }
  }

  func checkFunction(_ f: SPIRVFunction) throws(CompileError) {
    var labels: [UInt32] = []
    for b in f.blocks { labels.append(b.label) }
    func target(_ i: SPIRVInstruction, _ id: UInt32) throws(CompileError) {
      guard labels.contains(id) else { throw err(i, "target %\(id) is not a block of function %\(f.id)") }
    }
    for b in f.blocks {
      for i in b.instructions {
        let o = i.operands
        switch i.op {
        case Op.branch: try target(i, o[0])
        case Op.branchConditional:
          try target(i, o[1])
          try target(i, o[2])
        case Op.switch_:
          try target(i, o[1])
          let per = m.switchWords(o[0])
          var k = 2 + per - 1
          while k < o.count {
            try target(i, o[k])
            k += per
          }
        case Op.selectionMerge: try target(i, o[0])
        case Op.loopMerge:
          try target(i, o[0])
          try target(i, o[1])
        case Op.phi:
          guard o.count % 2 == 0 && !o.isEmpty else { throw err(i, "needs (value, block) pairs") }
          var k = 1
          while k < o.count {
            try target(i, o[k])
            k += 2
          }
        default: break
        }
      }
    }
  }
}

extension SPIRVModule {
  /// Parse and validate a SPIR-V binary's words.
  public static func parse(words: [UInt32]) throws(CompileError) -> SPIRVModule {
    var p = Parser(words: words)
    try p.run()
    return p.m
  }

  /// Parse and validate a SPIR-V binary (little-endian bytes).
  public static func parse(bytes: [UInt8]) throws(CompileError) -> SPIRVModule {
    guard bytes.count % 4 == 0 else { throw CompileError("module: size \(bytes.count) is not a multiple of 4") }
    var words: [UInt32] = []
    words.reserveCapacity(bytes.count / 4)
    var i = 0
    while i < bytes.count {
      words.append(
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
      i += 4
    }
    return try parse(words: words)
  }

  /// Everything in a binary the compiler refuses, by name, in the order it
  /// is met and without repeats: the instructions, capabilities, execution
  /// models and decorations not supported. It scans instruction headers and
  /// never fails; empty means the reader accepts the module as far as names
  /// go (it can still refuse its structure).
  public static func unsupported(words: [UInt32]) -> [String] {
    var found: [String] = []
    func note(_ s: String) {
      for f in found where f.utf8.elementsEqual(s.utf8) { return }
      found.append(s)
    }
    var pos = 5
    while pos < words.count {
      let head = words[pos]
      let count = Int(head >> 16)
      let op = UInt16(truncatingIfNeeded: head)
      if count == 0 || pos + count > words.count { note("truncated module"); break }
      let w = Array(words[pos..<pos + count])
      pos += count
      guard let info = OpTable.info(op) else {
        note(OpTable.name(op))
        continue
      }
      if info.refused { note(info.name) }
      switch op {
      case Op.capability:
        if w.count > 1 && !Supported.capabilities.contains(w[1]) { note("capability \(Supported.capabilityName(w[1]))") }
      case Op.entryPoint:
        if w.count > 1 && w[1] != 5 && w[1] != 0 && w[1] != 4 { note("execution model \(Supported.executionModelName(w[1]))") }
      case Op.extInstImport:
        let s = Parser.string(Array(w[2...]), from: 0).0
        if !s.utf8.elementsEqual("GLSL.std.450".utf8) { note("extended instruction set \(s)") }
      case Op.decorate:
        if w.count > 2 && !Supported.decorationOK(w[2]) { note("decoration \(Supported.decorationName(w[2]))") }
      case Op.typePointer:
        if w.count > 2 && !Supported.storageOK(w[2]) { note("storage class \(StorageClass.name(w[2]))") }
      case Op.variable:
        if w.count > 3 && !Supported.storageOK(w[3]) { note("storage class \(StorageClass.name(w[3]))") }
      default: break
      }
    }
    return found
  }
}
