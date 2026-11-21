// SPDX-License-Identifier: BSD-3-Clause

// The rewrite itself (D174 step 5): a Vulkan program's SPIR-V into the
// core's interface, against a `LoweringLayout` (Layout.swift). The pieces:
//   Lower.swift      this entry point, the analysis and the module's reassembly
//   Emit.swift       ids, types, constants and the reads of the root block and set records
//   Resources.swift  buffers, push constants, images and samplers
//   Vertex.swift     vertex input
// The page is lowering(2) (man/2/vulkanlowering).

/// `spirv` (words) rewritten for the core: its descriptor sets, push constants and (for a vertex stage) vertex
/// inputs read through the root block; the heap's arrays at set 0, bindings 0 to 2; the core's push-constant block,
/// the root, in place of the program's.
public func lower(spirv: [UInt32], stage: ShaderStage, entryPoint: String, layout: LoweringLayout)
  throws(LoweringError) -> [UInt32]
{
  var r = try Rewriter(spirv, stage: stage, entryPoint: entryPoint, layout: layout)
  try r.run()
  return r.finish()
}

/// A type as the lowering reads it.
enum TypeInfo {
  case other
  case void
  case bool
  case int(width: Int, signed: Bool)
  case float(width: Int)
  case vector(element: UInt32, count: Int)
  case matrix(column: UInt32, count: Int)
  case array(element: UInt32, length: UInt32)
  case runtimeArray(element: UInt32)
  case structure(members: [UInt32])
  case pointer(storage: UInt32, pointee: UInt32)
  case image(sampled: UInt32, dim: UInt32, depth: UInt32, arrayed: Bool, multisampled: Bool, usage: UInt32)
  case sampler
  case sampledImage(image: UInt32)
}

/// A module-level variable the lowering takes over (or drops).
struct VarInfo {
  enum Kind { case buffer, opaque, pushConstant, vertexInput }
  var id: UInt32
  /// The pointer type the program declared.
  var type: UInt32
  var kind: Kind
  var used = false
  var set: UInt32 = 0
  var binding: UInt32 = 0
  /// Where the binding's descriptors start in its set's record.
  var recordOffset: UInt32 = 0
  var descriptor: DescriptorKind = .uniformBuffer
  var arrayed = false
  /// The array's length, nil for a runtime array.
  var count: UInt32? = nil
  /// The type of the element: the Block struct, or the image, sampler or sampled image.
  var leaf: UInt32 = 0
  var location: UInt32 = 0
}

/// How a descriptor array's element is chosen.
enum ElementIndex {
  case constant(UInt64)
  case dynamic(UInt32)
}

struct Rewriter {
  var m: RawModule
  let layout: LoweringLayout
  let stage: ShaderStage
  var nextId: UInt32
  let originalBound: UInt32

  // What the program declares, by id.
  var types: [TypeInfo?]
  var idType: [UInt32]
  var constantValue: [UInt64?]
  var varOf: [Int32]
  var vars: [VarInfo] = []
  var entryFunction: UInt32 = 0
  var entryInterface: [UInt32] = []

  // Additions, in the order they are made.
  var newGlobals: [RawInst] = []
  var newVars: [RawInst] = []
  var newAnnotations: [RawInst] = []
  var extraInterface: [(id: UInt32, isInput: Bool)] = []
  var loweredPointerType: [Bool] = []
  let entryName: String
  var needNonUniform = false
  var needSampledArrayNonUniform = false
  var needStorageArrayNonUniform = false
  var needRuntimeArray = false
  var usedPSB = false

  // Types and constants made once.
  var tUint: UInt32 = 0
  var tInt: UInt32 = 0
  var tUlong: UInt32 = 0
  var tFloat: UInt32 = 0
  var tBool: UInt32 = 0
  var root = RootTypes()
  var heapVars: [HeapVar] = []
  var builtinVars: [(builtin: UInt32, variable: UInt32, signed: Bool)] = []

  // Per function.
  var pre: [RawInst] = []
  var body: [RawInst] = []
  var fnRootData: UInt32 = 0
  var fnRootAddr: UInt32 = 0
  var fnSetAddr: [UInt32] = [0, 0, 0, 0]
  var fnPointers: [(variable: Int, pointer: UInt32)] = []
  var fnDescriptors: [(pointer: UInt32, descriptor: UInt32)] = []
  var fnVertexIndex: UInt32 = 0
  var fnInstanceIndex: UInt32 = 0

  // Followed through a function's body, by the original id.
  var opaqueVar: [Int32]
  var opaqueIndex: [ElementIndex?]
  var nonUniform: [Bool]
  var fromInput: [Bool]

  init(_ words: [UInt32], stage: ShaderStage, entryPoint: String, layout: LoweringLayout) throws(LoweringError) {
    self.m = try RawModule.parse(words)
    self.layout = layout
    self.stage = stage
    self.entryName = entryPoint
    self.nextId = m.bound
    self.originalBound = m.bound
    let n = Int(m.bound)
    types = [TypeInfo?](repeating: nil, count: n)
    idType = [UInt32](repeating: 0, count: n)
    constantValue = [UInt64?](repeating: nil, count: n)
    varOf = [Int32](repeating: -1, count: n)
    opaqueVar = [Int32](repeating: -1, count: n)
    opaqueIndex = [ElementIndex?](repeating: nil, count: n)
    nonUniform = [Bool](repeating: false, count: n)
    fromInput = [Bool](repeating: false, count: n)
    try index(entryPoint)
  }

  // MARK: analysis

  func check(_ id: UInt32) -> Bool { id < originalBound }

  mutating func index(_ entryPoint: String) throws(LoweringError) {
    // The entry point.
    let want: UInt32
    switch stage {
    case .vertex: want = SPV.modelVertex
    case .fragment: want = SPV.modelFragment
    case .compute: want = SPV.modelGLCompute
    }
    var found = false
    var sawName = false
    for e in m.entryPoints {
      guard e.w.count >= 3 else { throw .malformed("OpEntryPoint needs a model, a function and a name") }
      let (next, equal) = SPV.stringAt(e.w, 2, equals: entryPoint)
      if !equal { continue }
      sawName = true
      if e.w[0] != want { continue }
      guard check(e.w[1]) else { throw .malformed("OpEntryPoint names an id outside the module's bound") }
      found = true
      entryFunction = e.w[1]
      entryInterface = Array(e.w[next...])
    }
    guard found else {
      throw .invalid(sawName ? "the entry point \(entryPoint) is not a \(stageName(stage)) shader" : "no entry point named \(entryPoint)")
    }

    // Types, constants and variables.
    for inst in m.globals {
      let w = inst.w
      let (hasType, hasResult) = SPV.resultInfo(inst.op)
      guard hasResult else { continue }
      let id = w[hasType ? 1 : 0]
      guard check(id), hasType ? w.count >= 2 : w.count >= 1 else { throw .malformed("an id outside the module's bound") }
      if hasType { idType[Int(id)] = w[0] }
      if let t = Rewriter.typeInfo(inst) { types[Int(id)] = t }
      if inst.op == SPV.opConstant, w.count >= 3 {
        var v = UInt64(w[2])
        if w.count >= 4 { v |= UInt64(w[3]) << 32 }
        constantValue[Int(id)] = v
      }
    }
    // Function bodies' values, and parameters.
    for f in m.functions {
      for inst in f {
        let (hasType, hasResult) = SPV.resultInfo(inst.op)
        guard hasResult, hasType, inst.w.count >= 2 else { continue }
        guard check(inst.w[1]) else { throw .malformed("an id outside the module's bound") }
        idType[Int(inst.w[1])] = inst.w[0]
      }
    }
    try classifyVariables()
  }

  func stageName(_ s: ShaderStage) -> String {
    switch s {
    case .vertex: "vertex"
    case .fragment: "fragment"
    case .compute: "compute"
    }
  }

  static func typeInfo(_ inst: RawInst) -> TypeInfo? {
    let w = inst.w
    switch inst.op {
    case SPV.opTypeVoid: return .void
    case SPV.opTypeBool: return .bool
    case SPV.opTypeInt: return w.count >= 3 ? .int(width: Int(w[1]), signed: w[2] != 0) : .other
    case SPV.opTypeFloat: return w.count >= 2 ? .float(width: Int(w[1])) : .other
    case SPV.opTypeVector: return w.count >= 3 ? .vector(element: w[1], count: Int(w[2])) : .other
    case SPV.opTypeMatrix: return w.count >= 3 ? .matrix(column: w[1], count: Int(w[2])) : .other
    case SPV.opTypeArray: return w.count >= 3 ? .array(element: w[1], length: w[2]) : .other
    case SPV.opTypeRuntimeArray: return w.count >= 2 ? .runtimeArray(element: w[1]) : .other
    case SPV.opTypeStruct: return .structure(members: Array(w.dropFirst()))
    case SPV.opTypePointer: return w.count >= 3 ? .pointer(storage: w[1], pointee: w[2]) : .other
    case SPV.opTypeImage:
      return w.count >= 8
        ? .image(sampled: w[1], dim: w[2], depth: w[3], arrayed: w[4] != 0, multisampled: w[5] != 0, usage: w[6]) : .other
    case SPV.opTypeSampler: return .sampler
    case SPV.opTypeSampledImage: return w.count >= 2 ? .sampledImage(image: w[1]) : .other
    default: return inst.op >= SPV.opTypeVoid && inst.op <= 38 ? TypeInfo.other : nil
    }
  }

  /// What an error calls a variable: its name, if the program has one, or its id.
  func describe(_ id: UInt32) -> String {
    for d in m.debug where d.op == SPV.opName && d.w.count >= 2 && d.w[0] == id {
      var bytes: [UInt8] = []
      var done = false
      for x in d.w[1...] where !done {
        for s in 0..<4 {
          let b = UInt8(truncatingIfNeeded: x >> UInt32(8 * s))
          if b == 0 {
            done = true
            break
          }
          bytes.append(b)
        }
      }
      return "variable " + String(decoding: bytes, as: UTF8.self)
    }
    return "variable %\(id)"
  }

  func decoration(_ id: UInt32, _ kind: UInt32) -> UInt32? {
    for a in m.annotations where a.op == SPV.opDecorate && a.w.count >= 2 && a.w[0] == id && a.w[1] == kind {
      return a.w.count >= 3 ? a.w[2] : 0
    }
    return nil
  }

  func hasDecoration(_ id: UInt32, _ kind: UInt32) -> Bool {
    for a in m.annotations where a.op == SPV.opDecorate && a.w.count >= 2 && a.w[0] == id && a.w[1] == kind { return true }
    return false
  }

  func memberDecoration(_ id: UInt32, _ member: UInt32, _ kind: UInt32) -> UInt32? {
    for a in m.annotations
    where a.op == SPV.opMemberDecorate && a.w.count >= 4 && a.w[0] == id && a.w[1] == member && a.w[2] == kind { return a.w[3] }
    return nil
  }

  func typeOf(_ id: UInt32) -> TypeInfo? { Int(id) < types.count ? types[Int(id)] : nil }

  func constant(_ id: UInt32) -> UInt64? { Int(id) < constantValue.count ? constantValue[Int(id)] : nil }

  // MARK: the whole rewrite

  mutating func run() throws(LoweringError) {
    rewriteGlobals()
    try rewriteFunctions()
  }

  /// The module's words: its sections with what the rewrite changed and added.
  mutating func finish() -> [UInt32] {
    let version15 = m.version >= 0x0001_0500
    let interfaceListsAll = m.version >= 0x0001_0400

    // Capabilities and extensions.
    func add(_ caps: inout [RawInst], _ c: UInt32) {
      for i in caps where i.w.first == c { return }
      caps.append(RawInst(SPV.opCapability, [c]))
    }
    var extensions: [String] = []
    if usedPSB {
      add(&m.capabilities, SPV.capInt64)
      add(&m.capabilities, SPV.capPhysicalStorageBufferAddresses)
      m.memoryModel.w[0] = SPV.addressingPhysicalStorageBuffer64
      extensions.append("SPV_KHR_physical_storage_buffer")
    }
    if needRuntimeArray {
      add(&m.capabilities, SPV.capRuntimeDescriptorArray)
      extensions.append("SPV_EXT_descriptor_indexing")
    }
    if needNonUniform {
      add(&m.capabilities, SPV.capShaderNonUniform)
      if needSampledArrayNonUniform { add(&m.capabilities, SPV.capSampledImageArrayNonUniformIndexing) }
      if needStorageArrayNonUniform { add(&m.capabilities, SPV.capStorageImageArrayNonUniformIndexing) }
    }
    if !version15 {
      for name in extensions {
        var have = false
        for e in m.extensions where SPV.stringAt(e.w, 0, equals: name).equal { have = true }
        if !have { m.extensions.append(RawInst(SPV.opExtension, SPV.stringWords(name))) }
      }
    }

    // The entry point: only the one lowered, its interface without the variables that are gone.
    var entry: [RawInst] = []
    for e in m.entryPoints where e.w.count >= 3 && e.w[1] == entryFunction {
      let (next, equal) = SPV.stringAt(e.w, 2, equals: entryName)
      guard equal else { continue }
      var words = Array(e.w[0..<next])
      for id in entryInterface {
        var keep = true
        if check(id), varOf[Int(id)] >= 0 {
          let v = vars[Int(varOf[Int(id)])]
          keep = interfaceListsAll && v.kind == .vertexInput && v.used
        }
        if keep { words.append(id) }
      }
      for x in extraInterface where interfaceListsAll || x.isInput { words.append(x.id) }
      if interfaceListsAll {
        for v in vars where v.kind == .vertexInput && v.used {
          var listed = false
          for id in entryInterface where id == v.id { listed = true }
          if !listed { words.append(v.id) }
        }
      }
      entry.append(RawInst(SPV.opEntryPoint, words))
      break
    }
    m.entryPoints = entry
    var modes: [RawInst] = []
    for e in m.executionModes where e.w.first == entryFunction { modes.append(e) }
    m.executionModes = modes

    // Names and decorations of what is gone.
    var gone: [UInt32] = []
    for v in vars { gone.append(v.id) }
    for id in 0..<Int(originalBound) where opaqueVar[id] >= 0 { gone.append(UInt32(id)) }
    func isGone(_ id: UInt32, _ gone: [UInt32]) -> Bool {
      for g in gone where g == id { return true }
      return false
    }
    var debug: [RawInst] = []
    for d in m.debug {
      if (d.op == SPV.opName || d.op == SPV.opMemberName), let t = d.w.first, isGone(t, gone) { continue }
      debug.append(d)
    }
    m.debug = debug
    var annotations: [RawInst] = []
    for a in m.annotations {
      if (a.op == SPV.opDecorate || a.op == SPV.opMemberDecorate), let t = a.w.first, isGone(t, gone) { continue }
      annotations.append(a)
    }
    m.annotations = annotations + newAnnotations
    m.globals += newGlobals
    m.globals += newVars
    m.bound = nextId
    return m.encode()
  }
}
