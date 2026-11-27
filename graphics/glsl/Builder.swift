// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V 1.0 out: a module's sections, its ids, and its types and constants made once each.

enum SpvOp {
  static let undef: UInt16 = 1
  static let name: UInt16 = 5
  static let memberName: UInt16 = 6
  static let extInstImport: UInt16 = 11
  static let extInst: UInt16 = 12
  static let memoryModel: UInt16 = 14
  static let entryPoint: UInt16 = 15
  static let executionMode: UInt16 = 16
  static let capability: UInt16 = 17
  static let typeVoid: UInt16 = 19
  static let typeBool: UInt16 = 20
  static let typeInt: UInt16 = 21
  static let typeFloat: UInt16 = 22
  static let typeVector: UInt16 = 23
  static let typeImage: UInt16 = 25
  static let typeSampledImage: UInt16 = 27
  static let typeArray: UInt16 = 28
  static let typeStruct: UInt16 = 30
  static let typePointer: UInt16 = 32
  static let typeFunction: UInt16 = 33
  static let constantTrue: UInt16 = 41
  static let constantFalse: UInt16 = 42
  static let constant: UInt16 = 43
  static let constantComposite: UInt16 = 44
  static let function: UInt16 = 54
  static let functionEnd: UInt16 = 56
  static let variable: UInt16 = 59
  static let load: UInt16 = 61
  static let store: UInt16 = 62
  static let accessChain: UInt16 = 65
  static let decorate: UInt16 = 71
  static let memberDecorate: UInt16 = 72
  static let vectorExtractDynamic: UInt16 = 77
  static let vectorInsertDynamic: UInt16 = 78
  static let vectorShuffle: UInt16 = 79
  static let compositeConstruct: UInt16 = 80
  static let compositeExtract: UInt16 = 81
  static let compositeInsert: UInt16 = 82
  static let convertFToS: UInt16 = 110
  static let convertSToF: UInt16 = 111
  static let sNegate: UInt16 = 126
  static let fNegate: UInt16 = 127
  static let iAdd: UInt16 = 128
  static let fAdd: UInt16 = 129
  static let iSub: UInt16 = 130
  static let fSub: UInt16 = 131
  static let iMul: UInt16 = 132
  static let fMul: UInt16 = 133
  static let sDiv: UInt16 = 135
  static let fDiv: UInt16 = 136
  static let vectorTimesScalar: UInt16 = 142
  static let dot: UInt16 = 148
  static let any: UInt16 = 154
  static let all: UInt16 = 155
  static let logicalEqual: UInt16 = 164
  static let logicalNotEqual: UInt16 = 165
  static let logicalOr: UInt16 = 166
  static let logicalAnd: UInt16 = 167
  static let logicalNot: UInt16 = 168
  static let select: UInt16 = 169
  static let iEqual: UInt16 = 170
  static let iNotEqual: UInt16 = 171
  static let sGreaterThan: UInt16 = 173
  static let sGreaterThanEqual: UInt16 = 175
  static let sLessThan: UInt16 = 177
  static let sLessThanEqual: UInt16 = 179
  static let fOrdEqual: UInt16 = 180
  static let fUnordNotEqual: UInt16 = 183
  static let fOrdLessThan: UInt16 = 184
  static let fOrdGreaterThan: UInt16 = 186
  static let fOrdLessThanEqual: UInt16 = 188
  static let fOrdGreaterThanEqual: UInt16 = 190
  static let dPdx: UInt16 = 207
  static let dPdy: UInt16 = 208
  static let fwidth: UInt16 = 209
  static let phi: UInt16 = 245
  static let loopMerge: UInt16 = 246
  static let selectionMerge: UInt16 = 247
  static let label: UInt16 = 248
  static let branch: UInt16 = 249
  static let branchConditional: UInt16 = 250
  static let kill: UInt16 = 252
  static let return_: UInt16 = 253
  static let unreachable: UInt16 = 255
  static let imageSampleImplicitLod: UInt16 = 87
  static let imageSampleExplicitLod: UInt16 = 88
  static let imageSampleProjImplicitLod: UInt16 = 91
  static let imageSampleProjExplicitLod: UInt16 = 92
}

enum Decoration {
  static let relaxedPrecision: UInt32 = 0
  static let block: UInt32 = 2
  static let arrayStride: UInt32 = 6
  static let builtIn: UInt32 = 11
  static let invariant: UInt32 = 18
  static let location: UInt32 = 30
  static let binding: UInt32 = 33
  static let descriptorSet: UInt32 = 34
  static let offset: UInt32 = 35
}

enum StorageClass {
  static let uniformConstant: UInt32 = 0
  static let input: UInt32 = 1
  static let uniform: UInt32 = 2
  static let output: UInt32 = 3
  static let function: UInt32 = 7
}

struct Builder {
  var bound: UInt32 = 1
  var header: [UInt32] = []
  var debug: [UInt32] = []
  var annotations: [UInt32] = []
  var globals: [UInt32] = []
  var cache: [String: UInt32] = [:]
  let glsl: UInt32

  init() {
    glsl = 1
    bound = 2
  }

  mutating func id() -> UInt32 {
    defer { bound += 1 }
    return bound
  }

  static func instruction(_ op: UInt16, _ operands: [UInt32]) -> [UInt32] {
    [UInt32(operands.count + 1) << 16 | UInt32(op)] + operands
  }

  static func string(_ s: String) -> [UInt32] {
    var w: [UInt32] = []
    var cur: UInt32 = 0
    var n = 0
    for b in s.utf8 {
      cur |= UInt32(b) << UInt32(8 * n)
      n += 1
      if n == 4 {
        w.append(cur)
        cur = 0
        n = 0
      }
    }
    w.append(cur)
    return w
  }

  mutating func decorate(_ target: UInt32, _ d: UInt32, _ extra: [UInt32] = []) {
    annotations += Builder.instruction(SpvOp.decorate, [target, d] + extra)
  }

  mutating func memberDecorate(_ target: UInt32, _ member: Int, _ d: UInt32, _ extra: [UInt32] = []) {
    annotations += Builder.instruction(SpvOp.memberDecorate, [target, UInt32(member), d] + extra)
  }

  mutating func name(_ target: UInt32, _ s: String) {
    debug += Builder.instruction(SpvOp.name, [target] + Builder.string(s))
  }

  mutating func memberName(_ target: UInt32, _ member: Int, _ s: String) {
    debug += Builder.instruction(SpvOp.memberName, [target, UInt32(member)] + Builder.string(s))
  }

  /// A type or constant by its key, made by `make` the first time.
  mutating func cached(_ key: String, _ op: UInt16, _ operands: [UInt32], typed: UInt32? = nil) -> UInt32 {
    if let x = cache[key] { return x }
    let r = id()
    if let t = typed {
      globals += Builder.instruction(op, [t, r] + operands)
    } else {
      globals += Builder.instruction(op, [r] + operands)
    }
    cache[key] = r
    return r
  }

  // MARK: types

  var void: UInt32 { mutating get { cached("void", SpvOp.typeVoid, []) } }
  var bool: UInt32 { mutating get { cached("bool", SpvOp.typeBool, []) } }
  var float: UInt32 { mutating get { cached("f32", SpvOp.typeFloat, [32]) } }
  var int: UInt32 { mutating get { cached("i32", SpvOp.typeInt, [32, 1]) } }
  var uint: UInt32 { mutating get { cached("u32", SpvOp.typeInt, [32, 0]) } }

  mutating func vector(_ element: UInt32, _ n: Int) -> UInt32 {
    if n == 1 { return element }
    return cached("v\(n)_\(element)", SpvOp.typeVector, [element, UInt32(n)])
  }

  mutating func array(_ element: UInt32, _ n: Int, stride: Int = 0) -> UInt32 {
    let len = constant(int: Int32(n))
    if stride == 0 { return cached("a\(element)x\(n)", SpvOp.typeArray, [element, len]) }
    let key = "a\(element)x\(n)s\(stride)"
    if let x = cache[key] { return x }
    let r = cached(key, SpvOp.typeArray, [element, len])
    decorate(r, Decoration.arrayStride, [UInt32(stride)])
    return r
  }

  /// A new structure type (each call makes one: a laid-out block's members are decorated).
  mutating func structure(_ members: [UInt32], key: String? = nil) -> UInt32 {
    if let k = key, let x = cache[k] { return x }
    let r = id()
    globals += Builder.instruction(SpvOp.typeStruct, [r] + members)
    if let k = key { cache[k] = r }
    return r
  }

  mutating func pointer(_ storage: UInt32, _ pointee: UInt32) -> UInt32 {
    cached("p\(storage)_\(pointee)", SpvOp.typePointer, [storage, pointee])
  }

  mutating func functionType(_ ret: UInt32, _ params: [UInt32] = []) -> UInt32 {
    cached("fn\(ret)(\(params))", SpvOp.typeFunction, [ret] + params)
  }

  /// A sampled image of a float 2D or cube image.
  mutating func sampledImage(cube: Bool) -> UInt32 {
    let f = float
    let image = cached(cube ? "imgCube" : "img2D", SpvOp.typeImage, [f, cube ? 3 : 1, 0, 0, 0, 1, 0])
    return cached(cube ? "simgCube" : "simg2D", SpvOp.typeSampledImage, [image])
  }

  // MARK: constants

  mutating func constant(float f: Float) -> UInt32 {
    let t = float
    return cached("cf\(f.bitPattern)", SpvOp.constant, [f.bitPattern], typed: t)
  }

  mutating func constant(int i: Int32) -> UInt32 {
    let t = int
    return cached("ci\(i)", SpvOp.constant, [UInt32(bitPattern: i)], typed: t)
  }

  mutating func constant(uint u: UInt32) -> UInt32 {
    let t = uint
    return cached("cu\(u)", SpvOp.constant, [u], typed: t)
  }

  mutating func constant(bool b: Bool) -> UInt32 {
    let t = bool
    return cached(b ? "ctrue" : "cfalse", b ? SpvOp.constantTrue : SpvOp.constantFalse, [], typed: t)
  }

  mutating func composite(_ type: UInt32, _ parts: [UInt32]) -> UInt32 {
    cached("cc\(type):\(parts)", SpvOp.constantComposite, parts, typed: type)
  }

  mutating func undef(_ type: UInt32) -> UInt32 { cached("undef\(type)", SpvOp.undef, [], typed: type) }

  mutating func variable(_ pointerType: UInt32, _ storage: UInt32) -> UInt32 {
    let r = id()
    globals += Builder.instruction(SpvOp.variable, [pointerType, r, storage])
    return r
  }

  /// The module's words: the header, then the sections in the order SPIR-V lays them out.
  func module(capabilities: [UInt32], entry: [UInt32], modes: [UInt32], function: [UInt32]) -> [UInt32] {
    var w: [UInt32] = [0x0723_0203, 0x0001_0000, 0, bound, 0]
    for c in capabilities { w += Builder.instruction(SpvOp.capability, [c]) }
    w += Builder.instruction(SpvOp.extInstImport, [glsl] + Builder.string("GLSL.std.450"))
    w += Builder.instruction(SpvOp.memoryModel, [0, 1])
    w += entry
    w += modes
    w += debug
    w += annotations
    w += globals
    w += function
    return w
  }
}
