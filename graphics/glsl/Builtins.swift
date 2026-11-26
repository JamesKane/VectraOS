// SPDX-License-Identifier: BSD-3-Clause

// The built-ins (chapter 7 and 8): each stage's built-in variables, the built-in constants and the uniform
// gl_DepthRange, and the built-in functions' signatures, with each call's result type and precision.

let builtinFunctionNames: Set<String> = [
  "radians", "degrees", "sin", "cos", "tan", "asin", "acos", "atan", "pow", "exp", "log", "exp2", "log2", "sqrt",
  "inversesqrt", "abs", "sign", "floor", "ceil", "fract", "mod", "min", "max", "clamp", "mix", "step", "smoothstep",
  "length", "distance", "dot", "cross", "normalize", "faceforward", "reflect", "refract", "matrixCompMult", "lessThan",
  "lessThanEqual", "greaterThan", "greaterThanEqual", "equal", "notEqual", "any", "all", "not", "texture2D",
  "texture2DProj", "texture2DLod", "texture2DProjLod", "textureCube", "textureCubeLod", "dFdx", "dFdy", "fwidth",
]

extension Parser {
  mutating func declareBuiltins() {
    func variable(_ name: String, _ t: GType, _ p: Precision, _ b: BuiltinVariable) {
      let id = prog.variables.count
      prog.variables.append(Variable(name: name, type: t, precision: p, storage: .builtin, at: SourceLocation(), builtin: b))
      scopes[0][name] = .variable(id)
    }
    func constant(_ name: String, _ v: Int) {
      let id = prog.variables.count
      var x = Variable(name: name, type: .int, precision: .medium, storage: .constant, at: SourceLocation())
      x.value = [.i(Int32(v))]
      prog.variables.append(x)
      scopes[0][name] = .variable(id)
    }
    if prog.stage == .vertex {
      variable("gl_Position", .vec(4), .high, .position)
      variable("gl_PointSize", .float, .medium, .pointSize)
    } else {
      variable("gl_FragCoord", .vec(4), .medium, .fragCoord)
      variable("gl_FrontFacing", .bool, .none, .frontFacing)
      variable("gl_FragColor", .vec(4), .medium, .fragColor)
      variable("gl_FragData", GType.vec(4).array(limits.maxDrawBuffers), .medium, .fragData)
      variable("gl_PointCoord", .vec(2), .medium, .pointCoord)
    }
    constant("gl_MaxVertexAttribs", limits.maxVertexAttribs)
    constant("gl_MaxVertexUniformVectors", limits.maxVertexUniformVectors)
    constant("gl_MaxVaryingVectors", limits.maxVaryingVectors)
    constant("gl_MaxVertexTextureImageUnits", limits.maxVertexTextureImageUnits)
    constant("gl_MaxCombinedTextureImageUnits", limits.maxCombinedTextureImageUnits)
    constant("gl_MaxTextureImageUnits", limits.maxTextureImageUnits)
    constant("gl_MaxFragmentUniformVectors", limits.maxFragmentUniformVectors)
    constant("gl_MaxDrawBuffers", limits.maxDrawBuffers)
    // struct gl_DepthRangeParameters { highp float near; highp float far; highp float diff; }; uniform ... gl_DepthRange;
    let s = prog.structs.count
    prog.structs.append(
      StructDef(
        name: "gl_DepthRangeParameters",
        members: [
          StructMember(name: "near", type: .float, precision: .high), StructMember(name: "far", type: .float, precision: .high),
          StructMember(name: "diff", type: .float, precision: .high),
        ]))
    scopes[0]["gl_DepthRangeParameters"] = .structure(s)
    variable("gl_DepthRange", GType(basic: .structure, structID: s), .high, .depthRange)
  }

  /// A call of a built-in function: the signature that takes these arguments, or an error.
  mutating func builtinCall(_ name: Token, _ args: [Expr]) -> Expr {
    let n = name.text
    let ts = args.map { $0.type }
    func genType(_ t: GType) -> Bool { t.basic == .float && (t.isScalar || t.isVector) }
    func all(_ f: (GType) -> Bool) -> Bool { ts.allSatisfy(f) }
    var p = Precision.none
    for a in args { p = max(p, a.precision) }
    var fn: BuiltinFunction? = nil
    var rt: GType? = nil
    let one: [String: BuiltinFunction] = [
      "radians": .radians, "degrees": .degrees, "sin": .sin, "cos": .cos, "tan": .tan, "asin": .asin, "acos": .acos,
      "exp": .exp, "log": .log, "exp2": .exp2, "log2": .log2, "sqrt": .sqrt, "inversesqrt": .inversesqrt, "abs": .abs,
      "sign": .sign, "floor": .floor, "ceil": .ceil, "fract": .fract, "normalize": .normalize, "dFdx": .dFdx, "dFdy": .dFdy,
      "fwidth": .fwidth,
    ]
    let relational: [String: BuiltinFunction] = [
      "lessThan": .lessThan, "lessThanEqual": .lessThanEqual, "greaterThan": .greaterThan, "greaterThanEqual": .greaterThanEqual,
      "equal": .equal, "notEqual": .notEqual,
    ]
    if let f = one[n] {
      if ts.count == 1 && genType(ts[0]) { (fn, rt) = (f, ts[0]) }
      if f == .dFdx || f == .dFdy || f == .fwidth {
        if !derivatives {
          diags.error(name.at, "'\(n)' needs #extension GL_OES_standard_derivatives : enable")
          return .error(name.at)
        }
        if prog.stage != .fragment {
          diags.error(name.at, "'\(n)' is only available in a fragment shader")
          return .error(name.at)
        }
      }
    } else if let f = relational[n] {
      if ts.count == 2 && ts[0] == ts[1] && ts[0].isVector {
        let numeric = ts[0].isNumeric
        if numeric || ((f == .equal || f == .notEqual) && ts[0].basic == .bool) {
          (fn, rt) = (f, GType.vec(ts[0].rows, .bool))
          p = .none
        }
      }
    } else {
      switch n {
      case "atan":
        if ts.count == 1 && genType(ts[0]) { (fn, rt) = (.atan, ts[0]) }
        if ts.count == 2 && genType(ts[0]) && ts[0] == ts[1] { (fn, rt) = (.atan2, ts[0]) }
      case "pow", "reflect":
        if ts.count == 2 && genType(ts[0]) && ts[0] == ts[1] { (fn, rt) = (n == "pow" ? .pow : .reflect, ts[0]) }
      case "mod", "min", "max":
        if ts.count == 2 && genType(ts[0]) && (ts[1] == ts[0] || ts[1] == .float) {
          (fn, rt) = (n == "mod" ? .mod : n == "min" ? .min : .max, ts[0])
        }
      case "step":
        if ts.count == 2 && genType(ts[1]) && (ts[0] == ts[1] || ts[0] == .float) { (fn, rt) = (.step, ts[1]) }
      case "clamp":
        if ts.count == 3 && genType(ts[0]) && ((ts[1] == ts[0] && ts[2] == ts[0]) || (ts[1] == .float && ts[2] == .float)) {
          (fn, rt) = (.clamp, ts[0])
        }
      case "mix":
        if ts.count == 3 && genType(ts[0]) && ts[1] == ts[0] && (ts[2] == ts[0] || ts[2] == .float) { (fn, rt) = (.mix, ts[0]) }
      case "smoothstep":
        if ts.count == 3 && genType(ts[2]) && ((ts[0] == ts[2] && ts[1] == ts[2]) || (ts[0] == .float && ts[1] == .float)) {
          (fn, rt) = (.smoothstep, ts[2])
        }
      case "length":
        if ts.count == 1 && genType(ts[0]) { (fn, rt) = (.length, .float) }
      case "distance", "dot":
        if ts.count == 2 && genType(ts[0]) && ts[0] == ts[1] { (fn, rt) = (n == "dot" ? .dot : .distance, .float) }
      case "cross":
        if ts.count == 2 && ts[0] == .vec(3) && ts[1] == .vec(3) { (fn, rt) = (.cross, .vec(3)) }
      case "faceforward":
        if ts.count == 3 && genType(ts[0]) && ts[1] == ts[0] && ts[2] == ts[0] { (fn, rt) = (.faceforward, ts[0]) }
      case "refract":
        if ts.count == 3 && genType(ts[0]) && ts[1] == ts[0] && ts[2] == .float { (fn, rt) = (.refract, ts[0]) }
      case "matrixCompMult":
        if ts.count == 2 && ts[0].isMatrix && ts[0] == ts[1] { (fn, rt) = (.matrixCompMult, ts[0]) }
      case "any", "all":
        if ts.count == 1 && ts[0].isVector && ts[0].basic == .bool { (fn, rt) = (n == "any" ? .any : .all, .bool) }
      case "not":
        if ts.count == 1 && ts[0].isVector && ts[0].basic == .bool { (fn, rt) = (.not, ts[0]) }
      case "texture2D", "texture2DProj", "texture2DLod", "texture2DProjLod", "textureCube", "textureCubeLod":
        let cube = n.hasPrefix("textureCube")
        let proj = n.contains("Proj")
        let lod = n.hasSuffix("Lod")
        guard ts.count >= 2, ts[0].basic == (cube ? .samplerCube : .sampler2D), !ts[0].isArray else { break }
        let coordOK = cube ? ts[1] == .vec(3) : proj ? (ts[1] == .vec(3) || ts[1] == .vec(4)) : ts[1] == .vec(2)
        guard coordOK else { break }
        if lod {
          guard ts.count == 3, ts[2] == .float else { break }
          if prog.stage != .vertex {
            diags.error(name.at, "'\(n)' is only available in a vertex shader")
            return .error(name.at)
          }
          fn = cube ? .textureCubeLod : proj ? .texture2DProjLod : .texture2DLod
        } else if ts.count == 3 {
          guard ts[2] == .float else { break }
          if prog.stage != .fragment {
            diags.error(name.at, "'\(n)' with a bias is only available in a fragment shader")
            return .error(name.at)
          }
          fn = cube ? .textureCubeBias : proj ? .texture2DProjBias : .texture2DBias
        } else if ts.count == 2 {
          fn = cube ? .textureCube : proj ? .texture2DProj : .texture2D
        }
        if fn != nil {
          rt = .vec(4)
          p = args[0].precision
        }
      default: break
      }
    }
    guard let f = fn, let r = rt else {
      diags.error(name.at, "no overload of built-in '\(n)' takes (\(ts.map { prog.name($0) }.joined(separator: ", ")))")
      return .error(name.at)
    }
    var e = Expr(type: r, precision: r.basic == .bool ? .none : p, kind: .builtin(f, args), at: name.at)
    e.value = Fold.builtin(f, args, r)
    return e
  }
}
