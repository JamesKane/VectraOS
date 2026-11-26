// SPDX-License-Identifier: BSD-3-Clause

// The SPIR-V a program arrives as (gles(3), "Shaders"): the GLSL front end's, or a binary given to glShaderBinary in
// GL_SHADER_BINARY_FORMAT_SPIR_V. Both are Vulkan-style: the default uniform block a std140 block at set 0, binding 0,
// each sampler a combined image sampler at set 0, bindings 1 on, the attributes at their locations. Here:
//  - `reflect` reads a binary's interface (its uniforms, samplers and attributes, by the names the module gives them),
//    as the front end gives a GLSL program's;
//  - `coreClipSpace` makes a vertex stage that writes GL's clip space (z from -w to w) write the core's (0 to w):
//    before each return of the entry point, Position's z becomes (z + w) / 2. y is not flipped here: a GL framebuffer's
//    first row is its bottom one, which is where the core's first row is, so only a window (whose first row is its top)
//    is drawn flipped, by its viewport (Draw.swift).

/// A program's interface, as the front end or `reflect` gives it.
public struct ActiveAttribute: Sendable, Equatable {
  public var name: String
  /// The GL type (GL_FLOAT_VEC4...).
  public var type: GLenum
  public var arraySize: Int
  public var location: UInt32
  public init(name: String, type: GLenum, arraySize: Int = 1, location: UInt32) {
    self.name = name
    self.type = type
    self.arraySize = arraySize
    self.location = location
  }
}

public struct ActiveUniform: Sendable, Equatable {
  /// "x", "x[0]" for an array, "s.m" for a structure's member.
  public var name: String
  public var type: GLenum
  public var arraySize: Int
  /// Where it is in the uniform block: its first element, the distance between elements, and between a matrix's columns.
  public var offset: Int
  public var arrayStride: Int
  public var matrixStride: Int
  /// A sampler's binding (its first element's), nil for a value in the block.
  public var samplerBinding: UInt32?
  public init(name: String, type: GLenum, arraySize: Int = 1, offset: Int = 0, arrayStride: Int = 0, matrixStride: Int = 0,
              samplerBinding: UInt32? = nil) {
    self.name = name
    self.type = type
    self.arraySize = arraySize
    self.offset = offset
    self.arrayStride = arrayStride
    self.matrixStride = matrixStride
    self.samplerBinding = samplerBinding
  }
  public var isSampler: Bool { samplerBinding != nil }
}

/// A linked program: each stage's SPIR-V words and what the program's calls name.
public struct ProgramInterface: Sendable, Equatable {
  public var vertexSPIRV: [UInt32]
  public var fragmentSPIRV: [UInt32]
  public var attributes: [ActiveAttribute]
  public var uniforms: [ActiveUniform]
  public var uniformBlockBytes: Int
  public var log: String
  /// The vertex stage writes GL's clip space, which the library makes the core's (`coreClipSpace`); false where the front
  /// end already did.
  public var glClipSpace: Bool
  public init(vertexSPIRV: [UInt32], fragmentSPIRV: [UInt32], attributes: [ActiveAttribute], uniforms: [ActiveUniform],
              uniformBlockBytes: Int, log: String = "", glClipSpace: Bool = true) {
    self.vertexSPIRV = vertexSPIRV
    self.fragmentSPIRV = fragmentSPIRV
    self.attributes = attributes
    self.uniforms = uniforms
    self.uniformBlockBytes = uniformBlockBytes
    self.log = log
    self.glClipSpace = glClipSpace
  }
}

enum Op {
  static let name: UInt32 = 5, memberName: UInt32 = 6, entryPoint: UInt32 = 15
  static let typeVoid: UInt32 = 19, typeBool: UInt32 = 20, typeInt: UInt32 = 21, typeFloat: UInt32 = 22
  static let typeVector: UInt32 = 23, typeMatrix: UInt32 = 24, typeImage: UInt32 = 25, typeSampledImage: UInt32 = 27
  static let typeArray: UInt32 = 28, typeStruct: UInt32 = 30, typePointer: UInt32 = 32
  static let constant: UInt32 = 43, function: UInt32 = 54, functionEnd: UInt32 = 56, variable: UInt32 = 59
  static let load: UInt32 = 61, store: UInt32 = 62, accessChain: UInt32 = 65
  static let compositeExtract: UInt32 = 81, compositeInsert: UInt32 = 82, fAdd: UInt32 = 129, fMul: UInt32 = 133
  static let decorate: UInt32 = 71, memberDecorate: UInt32 = 72, ret: UInt32 = 253
  // Decorations.
  static let block: UInt32 = 2, arrayStride: UInt32 = 6, matrixStride: UInt32 = 7, builtIn: UInt32 = 11
  static let location: UInt32 = 30, binding: UInt32 = 33, descriptorSet: UInt32 = 34, offset: UInt32 = 35
  // Storage classes.
  static let uniformConstant: UInt32 = 0, input: UInt32 = 1, uniform: UInt32 = 2, output: UInt32 = 3
}

/// A module's instructions, by where each starts in its words.
struct SpirvModule {
  var words: [UInt32]
  /// (start, opcode, word count) of each instruction.
  var instructions: [(at: Int, op: UInt32, count: Int)] = []

  init?(_ words: [UInt32]) {
    guard words.count >= 5, words[0] == 0x0723_0203 else { return nil }
    self.words = words
    var i = 5
    while i < words.count {
      let count = Int(words[i] >> 16), op = words[i] & 0xFFFF
      guard count > 0, i + count <= words.count else { return nil }
      instructions.append((i, op, count))
      i += count
    }
  }

  var bound: UInt32 { words[3] }

  func operands(_ n: Int) -> ArraySlice<UInt32> {
    let ins = instructions[n]
    return words[(ins.at + 1)..<(ins.at + ins.count)]
  }

  /// The literal string starting at word `at` of an instruction's operands.
  static func string(_ w: ArraySlice<UInt32>, from at: Int) -> String {
    var bytes: [UInt8] = []
    var i = w.startIndex + at
    outer: while i < w.endIndex {
      for s in 0..<4 {
        let b = UInt8(truncatingIfNeeded: w[i] >> UInt32(8 * s))
        if b == 0 { break outer }
        bytes.append(b)
      }
      i += 1
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

enum ReflectError: Error, Equatable {
  case malformed(String)
  case unsupported(String)
}

/// A module's types, names and decorations, by id.
struct SpirvInfo {
  enum TypeInfo {
    case bool, int(signed: Bool), float, vector(UInt32, Int), matrix(UInt32, Int), array(UInt32, UInt32), structure([UInt32])
    case pointer(UInt32, UInt32), image(dim: UInt32), sampledImage(UInt32), other
  }
  var types: [UInt32: TypeInfo] = [:]
  var names: [UInt32: String] = [:]
  var memberNames: [UInt32: [UInt32: String]] = [:]
  var decorations: [UInt32: [UInt32: UInt32]] = [:]
  var memberDecorations: [UInt32: [UInt32: [UInt32: UInt32]]] = [:]
  var constants: [UInt32: UInt32] = [:]
  /// (id, pointer type, storage class) of each module-level variable.
  var variables: [(id: UInt32, type: UInt32, storage: UInt32)] = []
  var entryModel: UInt32?

  init(_ m: SpirvModule) {
    for n in m.instructions.indices {
      let ins = m.instructions[n]
      let w = m.operands(n)
      let b = w.startIndex
      switch ins.op {
      case Op.entryPoint where w.count >= 2: if entryModel == nil { entryModel = w[b] }
      case Op.name where w.count >= 1: names[w[b]] = SpirvModule.string(w, from: 1)
      case Op.memberName where w.count >= 2: memberNames[w[b], default: [:]][w[b + 1]] = SpirvModule.string(w, from: 2)
      case Op.decorate where w.count >= 2: decorations[w[b], default: [:]][w[b + 1]] = w.count >= 3 ? w[b + 2] : 0
      case Op.memberDecorate where w.count >= 3:
        memberDecorations[w[b], default: [:]][w[b + 1], default: [:]][w[b + 2]] = w.count >= 4 ? w[b + 3] : 0
      case Op.typeBool where w.count >= 1: types[w[b]] = .bool
      case Op.typeInt where w.count >= 3: types[w[b]] = .int(signed: w[b + 2] != 0)
      case Op.typeFloat where w.count >= 2: types[w[b]] = .float
      case Op.typeVector where w.count >= 3: types[w[b]] = .vector(w[b + 1], Int(w[b + 2]))
      case Op.typeMatrix where w.count >= 3: types[w[b]] = .matrix(w[b + 1], Int(w[b + 2]))
      case Op.typeArray where w.count >= 3: types[w[b]] = .array(w[b + 1], w[b + 2])
      case Op.typeStruct where w.count >= 1: types[w[b]] = .structure(Array(w.dropFirst()))
      case Op.typePointer where w.count >= 3: types[w[b]] = .pointer(w[b + 1], w[b + 2])
      case Op.typeImage where w.count >= 3: types[w[b]] = .image(dim: w[b + 2])
      case Op.typeSampledImage where w.count >= 2: types[w[b]] = .sampledImage(w[b + 1])
      case Op.constant where w.count >= 3: constants[w[b + 1]] = w[b + 2]
      case Op.variable where w.count >= 3: variables.append((w[b + 1], w[b], w[b + 2]))
      default: break
      }
    }
  }

  func decoration(_ id: UInt32, _ d: UInt32) -> UInt32? { decorations[id]?[d] }
  func memberDecoration(_ id: UInt32, _ member: UInt32, _ d: UInt32) -> UInt32? { memberDecorations[id]?[member]?[d] }

  /// The GL type of a value type: a scalar, a vector or a matrix of floats; a scalar or vector of ints; a uint (what a
  /// bool is in a block), or a bool. nil for anything else.
  func glType(_ t: UInt32) -> GLenum? {
    switch types[t] {
    case .float?: return GL_FLOAT
    case .int(let signed)?: return signed ? GL_INT : GL_BOOL
    case .bool?: return GL_BOOL
    case .vector(let e, let n)?:
      switch types[e] {
      case .float?: return [GL_FLOAT_VEC2, GL_FLOAT_VEC3, GL_FLOAT_VEC4][max(0, min(n, 4) - 2)]
      case .int(let signed)?:
        return signed ? [GL_INT_VEC2, GL_INT_VEC3, GL_INT_VEC4][max(0, min(n, 4) - 2)] : [GL_BOOL_VEC2, GL_BOOL_VEC3, GL_BOOL_VEC4][max(0, min(n, 4) - 2)]
      case .bool?: return [GL_BOOL_VEC2, GL_BOOL_VEC3, GL_BOOL_VEC4][max(0, min(n, 4) - 2)]
      default: return nil
      }
    case .matrix(_, let n)?: return [GL_FLOAT_MAT2, GL_FLOAT_MAT3, GL_FLOAT_MAT4][max(0, min(n, 4) - 2)]
    default: return nil
    }
  }
}

/// A vertex and a fragment module's interface, for a program linked from binaries: the uniform block's members (by their
/// names, flattened as GL names them), the samplers (by their variables' names) and the vertex stage's attributes.
func reflect(vertex: [UInt32], fragment: [UInt32]) throws(ReflectError) -> ProgramInterface {
  guard let vm = SpirvModule(vertex), let fm = SpirvModule(fragment) else { throw .malformed("a binary that isn't SPIR-V") }
  let v = SpirvInfo(vm), f = SpirvInfo(fm)
  guard v.entryModel == 0 else { throw .malformed("the vertex shader's binary has no vertex entry point") }
  guard f.entryModel == 4 else { throw .malformed("the fragment shader's binary has no fragment entry point") }
  var uniforms: [ActiveUniform] = []
  var blockBytes = 0
  for info in [v, f] {
    for u in try blockUniforms(info, size: &blockBytes) {
      if let i = uniforms.firstIndex(where: { $0.name == u.name }) {
        guard uniforms[i] == u else { throw .malformed("the uniform \(u.name) differs between the stages") }
      } else {
        uniforms.append(u)
      }
    }
    for u in try samplerUniforms(info) {
      if let i = uniforms.firstIndex(where: { $0.name == u.name }) {
        guard uniforms[i] == u else { throw .malformed("the sampler \(u.name) differs between the stages") }
      } else {
        uniforms.append(u)
      }
    }
  }
  var attributes: [ActiveAttribute] = []
  for variable in v.variables where variable.storage == Op.input {
    guard v.decoration(variable.id, Op.builtIn) == nil, let location = v.decoration(variable.id, Op.location),
      case .pointer(_, let pointee)? = v.types[variable.type]
    else { continue }
    guard let type = v.glType(pointee) else { throw .unsupported("an attribute that isn't a float, a vector or a matrix") }
    attributes.append(ActiveAttribute(name: v.names[variable.id] ?? "", type: type, location: location))
  }
  return ProgramInterface(vertexSPIRV: vertex, fragmentSPIRV: fragment, attributes: attributes, uniforms: uniforms,
                          uniformBlockBytes: blockBytes, log: "", glClipSpace: true)
}

/// The members of the block at set 0, binding 0, flattened; `size` the block's bytes, at least.
private func blockUniforms(_ info: SpirvInfo, size: inout Int) throws(ReflectError) -> [ActiveUniform] {
  var out: [ActiveUniform] = []
  for variable in info.variables where variable.storage == Op.uniform {
    guard info.decoration(variable.id, Op.descriptorSet) ?? 0 == 0, info.decoration(variable.id, Op.binding) == 0,
      case .pointer(_, let block)? = info.types[variable.type], case .structure? = info.types[block]
    else { continue }
    try flatten(info, structure: block, prefix: "", base: 0, into: &out, size: &size)
  }
  return out
}

private func flatten(_ info: SpirvInfo, structure: UInt32, prefix: String, base: Int, into out: inout [ActiveUniform],
                     size: inout Int) throws(ReflectError) {
  guard case .structure(let members)? = info.types[structure] else { return }
  for (m, type) in members.enumerated() {
    let name = prefix + (info.memberNames[structure]?[UInt32(m)] ?? "_\(m)")
    guard let offset = info.memberDecoration(structure, UInt32(m), Op.offset) else {
      throw .malformed("the uniform \(name) has no offset")
    }
    let at = base + Int(offset)
    let matrixStride = Int(info.memberDecoration(structure, UInt32(m), Op.matrixStride) ?? 16)
    var element = type
    var count = 1
    var stride = 0
    if case .array(let e, let length)? = info.types[type] {
      element = e
      count = Int(info.constants[length] ?? 1)
      stride = Int(info.decoration(type, Op.arrayStride) ?? 16)
    }
    if case .structure? = info.types[element] {
      for i in 0..<count {
        let p = stride == 0 && count == 1 && !isArray(info, type) ? name + "." : name + "[\(i)]."
        try flatten(info, structure: element, prefix: p, base: at + i * stride, into: &out, size: &size)
      }
      continue
    }
    guard let glType = info.glType(element) else { throw .unsupported("the uniform \(name)'s type") }
    let isArr = isArray(info, type)
    out.append(ActiveUniform(name: isArr ? name + "[0]" : name, type: glType, arraySize: count, offset: at, arrayStride: stride,
                             matrixStride: matrixStride))
    size = max(size, at + max(count - 1, 0) * stride + valueBytes(glType, matrixStride: matrixStride))
  }
}

private func isArray(_ info: SpirvInfo, _ t: UInt32) -> Bool {
  if case .array? = info.types[t] { return true }
  return false
}

/// The bytes a value of GL type `t` takes in a std140 block (a matrix: its columns, `matrixStride` apart).
func valueBytes(_ t: GLenum, matrixStride: Int) -> Int {
  switch t {
  case GL_FLOAT_MAT2: matrixStride + 8
  case GL_FLOAT_MAT3: 2 * matrixStride + 12
  case GL_FLOAT_MAT4: 3 * matrixStride + 16
  default: 4 * componentCount(t)
  }
}

/// The scalar components of a GL value type (a matrix's: all of them).
func componentCount(_ t: GLenum) -> Int {
  switch t {
  case GL_FLOAT, GL_INT, GL_BOOL, GL_SAMPLER_2D, GL_SAMPLER_CUBE: 1
  case GL_FLOAT_VEC2, GL_INT_VEC2, GL_BOOL_VEC2: 2
  case GL_FLOAT_VEC3, GL_INT_VEC3, GL_BOOL_VEC3: 3
  case GL_FLOAT_VEC4, GL_INT_VEC4, GL_BOOL_VEC4, GL_FLOAT_MAT2: 4
  case GL_FLOAT_MAT3: 9
  case GL_FLOAT_MAT4: 16
  default: 1
  }
}

private func samplerUniforms(_ info: SpirvInfo) throws(ReflectError) -> [ActiveUniform] {
  var out: [ActiveUniform] = []
  for variable in info.variables where variable.storage == Op.uniformConstant {
    guard case .pointer(_, let pointee)? = info.types[variable.type], let binding = info.decoration(variable.id, Op.binding) else {
      continue
    }
    var t = pointee
    var count = 1
    var arrayed = false
    if case .array(let e, let length)? = info.types[t] {
      t = e
      count = Int(info.constants[length] ?? 1)
      arrayed = true
    }
    guard case .sampledImage(let image)? = info.types[t], case .image(let dim)? = info.types[image] else {
      throw .unsupported("a uniform constant that isn't a combined image sampler")
    }
    let type: GLenum
    switch dim {
    case 1: type = GL_SAMPLER_2D
    case 3: type = GL_SAMPLER_CUBE
    default: throw .unsupported("a sampler of image dimension \(dim)")
    }
    let name = info.names[variable.id] ?? "_\(variable.id)"
    out.append(ActiveUniform(name: arrayed ? name + "[0]" : name, type: type, arraySize: count, samplerBinding: binding))
  }
  return out
}

/// `words` (a vertex stage) with GL's clip space made the core's: Position's z, before each return of the entry
/// function, becomes (z + w) / 2. A module that writes no Position comes back as it was.
func coreClipSpace(_ words: [UInt32]) throws(ReflectError) -> [UInt32] {
  guard let m = SpirvModule(words) else { throw .malformed("a vertex shader that isn't SPIR-V") }
  let info = SpirvInfo(m)
  // The entry function.
  var entry: UInt32?
  for n in m.instructions.indices where m.instructions[n].op == Op.entryPoint {
    let w = m.operands(n)
    if w.count >= 2 && w[w.startIndex] == 0 { entry = w[w.startIndex + 1] }
  }
  guard let entry else { throw .malformed("no vertex entry point") }
  // Position: a variable, or a member of an output block.
  var variable: UInt32?
  var member: UInt32?
  for v in info.variables where v.storage == Op.output {
    if info.decoration(v.id, Op.builtIn) == 0 {
      variable = v.id
      break
    }
    if case .pointer(_, let pointee)? = info.types[v.type], case .structure(let members)? = info.types[pointee] {
      for i in members.indices where info.memberDecoration(pointee, UInt32(i), Op.builtIn) == 0 {
        variable = v.id
        member = UInt32(i)
      }
    }
  }
  guard let variable else { return words }
  // The types and constants the rewrite uses: found, or made.
  var next = m.bound
  var globals: [UInt32] = []
  func emit(_ out: inout [UInt32], _ op: UInt32, _ operands: [UInt32]) {
    out.append(UInt32(operands.count + 1) << 16 | op)
    out += operands
  }
  var float: UInt32? = nil
  for (id, t) in info.types {
    if case .float = t { float = id }
  }
  guard let float else { return words }
  var vec4: UInt32? = nil
  for (id, t) in info.types {
    if case .vector(let e, 4) = t, e == float { vec4 = id }
  }
  if vec4 == nil {
    vec4 = next
    emit(&globals, Op.typeVector, [next, float, 4])
    next += 1
  }
  var pointer: UInt32? = nil
  for (id, t) in info.types {
    if case .pointer(Op.output, let p) = t, p == vec4! { pointer = id }
  }
  if pointer == nil {
    pointer = next
    emit(&globals, Op.typePointer, [next, Op.output, vec4!])
    next += 1
  }
  var memberConstant: UInt32? = nil
  if let member {
    var uint: UInt32? = nil
    for (id, t) in info.types {
      if case .int = t { uint = uint ?? id }
    }
    for (id, t) in info.types {
      if case .int(false) = t { uint = id }
    }
    if uint == nil {
      uint = next
      emit(&globals, Op.typeInt, [next, 32, 0])
      next += 1
    }
    memberConstant = next
    emit(&globals, Op.constant, [uint!, next, member])
    next += 1
  }
  let half = next
  emit(&globals, Op.constant, [float, half, 0x3F00_0000])
  next += 1

  var out = Array(words[0..<5])
  var inEntry = false
  var placedGlobals = false
  for n in m.instructions.indices {
    let ins = m.instructions[n]
    if ins.op == Op.function {
      if !placedGlobals {
        out += globals
        placedGlobals = true
      }
      inEntry = words[ins.at + 2] == entry
    }
    if ins.op == Op.functionEnd { inEntry = false }
    if inEntry && ins.op == Op.ret {
      var target = variable
      if let memberConstant {
        target = next
        emit(&out, Op.accessChain, [pointer!, next, variable, memberConstant])
        next += 1
      }
      let value = next, z = next + 1, w = next + 2, sum = next + 3, scaled = next + 4, result = next + 5
      next += 6
      emit(&out, Op.load, [vec4!, value, target])
      emit(&out, Op.compositeExtract, [float, z, value, 2])
      emit(&out, Op.compositeExtract, [float, w, value, 3])
      emit(&out, Op.fAdd, [float, sum, z, w])
      emit(&out, Op.fMul, [float, scaled, sum, half])
      emit(&out, Op.compositeInsert, [vec4!, result, scaled, value, 2])
      emit(&out, Op.store, [target, result])
    }
    out += words[ins.at..<(ins.at + ins.count)]
  }
  out[3] = next
  return out
}
