// SPDX-License-Identifier: BSD-3-Clause

// The checked program a compile keeps (inside GLSLShader) and a link turns into SPIR-V: the language's types (chapter
// 4), its variables, its typed expressions and statements, and the folded values of its constant expressions.

enum Basic: UInt8, Sendable {
  case void, float, int, bool, sampler2D, samplerCube, structure
  /// The type of an expression that failed to check; it matches anything, so one mistake gives one message.
  case error
}

/// A type of the language: a scalar, a vector (`rows` components), a square matrix (`cols` columns of `rows`), a
/// sampler, a structure (`structID` into the shader's structs), or an array of one of these (`arraySize` elements).
struct GType: Hashable, Sendable {
  var basic: Basic
  var rows: Int = 1
  var cols: Int = 1
  var structID: Int = -1
  var arraySize: Int = 0

  static let void = GType(basic: .void)
  static let float = GType(basic: .float)
  static let int = GType(basic: .int)
  static let bool = GType(basic: .bool)
  static let error = GType(basic: .error)
  static func vec(_ n: Int, _ b: Basic = .float) -> GType { GType(basic: b, rows: n) }
  static func mat(_ n: Int) -> GType { GType(basic: .float, rows: n, cols: n) }

  var isArray: Bool { arraySize > 0 }
  var isMatrix: Bool { cols > 1 && !isArray }
  var isVector: Bool { rows > 1 && cols == 1 && !isArray }
  var isScalar: Bool { rows == 1 && cols == 1 && !isArray && (basic == .float || basic == .int || basic == .bool) }
  var isSampler: Bool { basic == .sampler2D || basic == .samplerCube }
  var isStruct: Bool { basic == .structure }
  var isError: Bool { basic == .error }
  var isNumeric: Bool { basic == .float || basic == .int }
  /// A scalar, a vector or a matrix: what arithmetic takes.
  var isBasicValue: Bool { !isArray && (basic == .float || basic == .int || basic == .bool) }
  /// The type of one element of an array.
  var element: GType {
    var t = self
    t.arraySize = 0
    return t
  }
  /// A matrix's column, a vector's component.
  var column: GType {
    if isMatrix { return GType(basic: basic, rows: rows) }
    return GType(basic: basic)
  }
  var scalar: GType { GType(basic: basic) }
  /// The scalar components of one scalar, vector or matrix.
  var components: Int { rows * cols }
  func array(_ n: Int) -> GType {
    var t = self
    t.arraySize = n
    return t
  }
}

/// The precision qualifiers (section 4.5). `none` is a value whose precision the language leaves to its operands (a
/// constant, a bool).
enum Precision: UInt8, Sendable, Comparable {
  case none, low, medium, high
  static func < (a: Precision, b: Precision) -> Bool { a.rawValue < b.rawValue }
  var name: String { ["", "lowp", "mediump", "highp"][Int(rawValue)] }
  /// mediump and lowp values are decorated RelaxedPrecision.
  var relaxed: Bool { self == .low || self == .medium }
}

struct StructMember: Sendable {
  var name: String
  var type: GType
  var precision: Precision
}

struct StructDef: Sendable {
  var name: String
  var members: [StructMember]
}

/// A folded constant: its scalar components in order (a matrix's column by column, a structure's members, an array's
/// elements).
enum Scalar: Sendable, Equatable {
  case f(Float)
  case i(Int32)
  case b(Bool)

  var float: Float {
    switch self {
    case .f(let x): return x
    case .i(let x): return Float(x)
    case .b(let x): return x ? 1 : 0
    }
  }
  var int: Int32 {
    switch self {
    case .f(let x):
      if x.isNaN { return 0 }
      if x >= 2147483648.0 { return Int32.max }
      if x <= -2147483648 { return Int32.min }
      return Int32(x)
    case .i(let x): return x
    case .b(let x): return x ? 1 : 0
    }
  }
  var bool: Bool {
    switch self {
    case .f(let x): return x != 0
    case .i(let x): return x != 0
    case .b(let x): return x
    }
  }
  func converted(to b: Basic) -> Scalar {
    switch b {
    case .float: return .f(float)
    case .int: return .i(int)
    default: return .b(bool)
    }
  }
}

enum Storage: UInt8, Sendable {
  /// A global variable without a storage qualifier.
  case global
  case local
  case param
  /// A `const` variable (its value is folded where it can be).
  case constant
  case uniform
  case attribute
  case varying
  /// A built-in variable: what it is is in `builtin`.
  case builtin
}

enum ParamQualifier: UInt8, Sendable { case `in`, out, `inout` }

enum BuiltinVariable: UInt8, Sendable {
  case none
  case position, pointSize
  case fragCoord, frontFacing, fragColor, fragData, pointCoord
  case depthRange
}

struct Variable: Sendable {
  var name: String
  var type: GType
  var precision: Precision
  var storage: Storage
  var at: SourceLocation
  var qualifier: ParamQualifier = .in
  var invariant = false
  var builtin: BuiltinVariable = .none
  /// A constant's folded value.
  var value: [Scalar]? = nil
  /// The program (any function) stores to it: a written `in` parameter needs a variable of its own.
  var written = false
  /// The program reads it.
  var read = false
}

enum UnaryOp: UInt8, Sendable { case neg, not, plus }

enum BinaryOp: UInt8, Sendable {
  case add, sub, mul, div
  case lt, gt, le, ge, eq, ne
  /// Short-circuiting.
  case and, or
  case xor
}

/// The built-in functions of chapter 8 (and GL_OES_standard_derivatives').
enum BuiltinFunction: UInt8, Sendable {
  case radians, degrees, sin, cos, tan, asin, acos, atan, atan2
  case pow, exp, log, exp2, log2, sqrt, inversesqrt
  case abs, sign, floor, ceil, fract, mod, min, max, clamp, mix, step, smoothstep
  case length, distance, dot, cross, normalize, faceforward, reflect, refract
  case matrixCompMult
  case lessThan, lessThanEqual, greaterThan, greaterThanEqual, equal, notEqual, any, all, not
  case texture2D, texture2DBias, texture2DProj, texture2DProjBias, texture2DLod, texture2DProjLod
  case textureCube, textureCubeBias, textureCubeLod
  case dFdx, dFdy, fwidth
}

struct Expr: Sendable {
  var type: GType
  var precision: Precision
  var kind: Kind
  var at: SourceLocation
  /// Its folded value, when it is a constant expression the compiler can fold.
  var value: [Scalar]? = nil

  indirect enum Kind: Sendable {
    /// A constant (its `value`).
    case constant
    case variable(Int)
    /// Components of a vector, by index (x = 0).
    case swizzle(Expr, [Int])
    case index(Expr, Expr)
    case field(Expr, Int)
    case unary(UnaryOp, Expr)
    case binary(BinaryOp, Expr, Expr)
    /// `=` (op nil) or `op=`; the left is an l-value.
    case assign(BinaryOp?, Expr, Expr)
    case increment(Bool, prefix: Bool, Expr)
    case select(Expr, Expr, Expr)
    case comma(Expr, Expr)
    case call(Int, [Expr])
    case builtin(BuiltinFunction, [Expr])
    /// A constructor of the expression's type.
    case construct([Expr])
    /// A declaration in a condition (`while (bool b = f())`): the variable is set to the initializer, whose value it is.
    case declare(Int, Expr)
  }

  static func error(_ at: SourceLocation) -> Expr { Expr(type: .error, precision: .none, kind: .constant, at: at, value: [.f(0)]) }
}

indirect enum Stmt: Sendable {
  case expr(Expr)
  /// A local variable, with its initializer.
  case declare(Int, Expr?)
  case block([Stmt])
  case ifElse(Expr, Stmt, Stmt?)
  /// `for` (and `while`, with no initializer or step): the initializer is in the enclosing scope's statements.
  case loop(initializer: [Stmt], condition: Expr?, step: Expr?, body: Stmt)
  case doWhile(body: Stmt, condition: Expr)
  case ret(Expr?, SourceLocation)
  case brk
  case cont
  case discard
}

struct FunctionDef: Sendable {
  var name: String
  var returnType: GType
  var returnPrecision: Precision
  /// Variable indices.
  var params: [Int]
  var body: [Stmt]?
  var at: SourceLocation
  /// The user functions its body calls.
  var calls: [Int] = []
  /// The global variables its body uses (uniforms, attributes, varyings, built-ins and the others).
  var uses: [Int] = []
}

/// What a compile keeps: everything checked, ready to be linked.
struct Program: Sendable {
  var stage: GLSLStage
  var structs: [StructDef] = []
  var variables: [Variable] = []
  var functions: [FunctionDef] = []
  /// The global declarations in order: each global variable with its initializer (uniforms, attributes and varyings
  /// have none).
  var globals: [(variable: Int, initializer: Expr?)] = []
  var main = -1
  var invariantAll = false

  func structName(_ t: GType) -> String { t.structID >= 0 && t.structID < structs.count ? structs[t.structID].name : "?" }

  /// The type's name as GLSL spells it (`vec3`, `S[4]`).
  func name(_ t: GType) -> String {
    var s: String
    switch t.basic {
    case .void: s = "void"
    case .error: s = "<error>"
    case .sampler2D: s = "sampler2D"
    case .samplerCube: s = "samplerCube"
    case .structure: s = structName(t)
    case .float, .int, .bool:
      if t.cols > 1 {
        s = "mat\(t.cols)"
      } else if t.rows > 1 {
        s = (t.basic == .float ? "vec" : t.basic == .int ? "ivec" : "bvec") + String(t.rows)
      } else {
        s = t.basic == .float ? "float" : t.basic == .int ? "int" : "bool"
      }
    }
    if t.isArray { s += "[\(t.arraySize)]" }
    return s
  }

  /// Two structure types are the same structure: the same name and the same members (by name and type), recursively.
  /// Used across stages, whose struct tables differ.
  static func sameType(_ a: GType, _ pa: Program, _ b: GType, _ pb: Program) -> Bool {
    guard a.basic == b.basic, a.rows == b.rows, a.cols == b.cols, a.arraySize == b.arraySize else { return false }
    guard a.basic == .structure else { return true }
    let sa = pa.structs[a.structID]
    let sb = pb.structs[b.structID]
    guard sa.name == sb.name, sa.members.count == sb.members.count else { return false }
    for (x, y) in zip(sa.members, sb.members) {
      guard x.name == y.name, sameType(x.type, pa, y.type, pb) else { return false }
    }
    return true
  }

  /// The type contains a sampler (a structure with one, or an array of them).
  func hasSampler(_ t: GType) -> Bool {
    if t.isSampler { return true }
    if t.isStruct { return structs[t.structID].members.contains { hasSampler($0.type) } }
    return false
  }

  func hasArray(_ t: GType) -> Bool {
    if t.isArray { return true }
    if t.isStruct { return structs[t.structID].members.contains { hasArray($0.type) } }
    return false
  }

  /// The scalar components of a value of this type (its folded form's length).
  func flatCount(_ t: GType) -> Int {
    var n = 0
    if t.isStruct {
      for m in structs[t.structID].members { n += flatCount(m.type) }
    } else {
      n = t.components
    }
    return t.isArray ? n * t.arraySize : n
  }
}
