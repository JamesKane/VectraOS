// SPDX-License-Identifier: BSD-3-Clause

// The preprocessor, the parser and the checks: what they accept, and what each refuses with which message, at which
// line and column of GL's info log.

@testable import GLSL
import Testing

/// The preprocessed tokens' texts, joined by spaces, and the log.
private func preprocess(_ src: String, stage: GLSLStage = .vertex) -> (text: String, log: String) {
  var lexer = Lexer(Array(src.utf8), diags: Diagnostics())
  let (tokens, d) = lexer.run()
  var pp = Preprocessor(stage: stage, diags: d)
  let r = pp.run(tokens)
  return (r.tokens.filter { $0.kind != .end }.map { $0.text }.joined(separator: " "), r.diags.log)
}

@Suite struct PreprocessorTests {
  @Test func objectAndFunctionMacros() {
    let src = """
      #define N 4
      #define SQ(x) ((x) * (x))
      #define ADD(a, b) a + b
      #define EMPTY
      #define CALL(f, v) f(v)
      #define SELF SELF + 1
      int a = SQ(N + 1) EMPTY;
      int b = ADD(SQ(2), N);
      int c = CALL(SQ, 3) + SELF;
      int d = ADD((1, 2), 3);
      int e = SQ(
        5);
      #undef N
      int f = N;
      """
    let (t, log) = preprocess(src)
    #expect(log == "")
    #expect(t.contains("int a = ( ( 4 + 1 ) * ( 4 + 1 ) ) ;"))
    #expect(t.contains("int b = ( ( 2 ) * ( 2 ) ) + 4 ;"))
    #expect(t.contains("int c = ( ( 3 ) * ( 3 ) ) + SELF + 1 ;"))
    #expect(t.contains("int d = ( 1 , 2 ) + 3 ;"))
    #expect(t.contains("int e = ( ( 5 ) * ( 5 ) ) ;"))
    #expect(t.contains("int f = N ;"))
  }

  @Test func conditionals() {
    let src = """
      #if defined(GL_ES) && GL_ES == 1 && (2 + 3 * 4 == 14) && !defined UNDEFINED
      yes1
      #else
      no1
      #endif
      #ifdef GL_FRAGMENT_PRECISION_HIGH
      yes2
      #endif
      #ifndef GL_ES
      no2
      #elif 1 ? 0 : 1
      no3
      #elif (7 % 4) == 3 && (1 << 3) == 8 && (-1 < 0) && (~0 == -1) && 0x10 == 16 && 010 == 8
      yes3
      #else
      no4
      #endif
      #if 0
        #if UNDEFINED_IS_FINE_HERE
        no5
        #else
        no6
        #endif
        #error not reached
      #endif
      __VERSION__ __LINE__ __FILE__ GL_OES_standard_derivatives
      """
    let (t, log) = preprocess(src)
    #expect(log == "")
    #expect(t == "yes1 yes2 yes3 100 26 0 1")
  }

  @Test func directivesRefusedOrReported() {
    let cases: [(String, String)] = [
      ("#if UNDEFINED\n#endif\n", "0:1:5: undefined macro UNDEFINED"),
      ("#error this is the message\n", "0:1:2: #error this is the message"),
      ("#define GL_THING 1\n", "macro names beginning with GL_ are reserved"),
      ("#define A 1\n#define A 2\n", "0:2:9: macro A redefined differently"),
      ("#undef GL_ES\n", "#undef of the predefined macro GL_ES"),
      ("#version 300 es\n", "version 300 es is not supported"),
      ("int x;\n#version 100\n", "#version must come before anything else"),
      ("#if 1\n", "unterminated #if"),
      ("#endif\n", "#endif without #if"),
      ("#else\n", "#else without #if"),
      ("#if 1\n#else\n#else\n#endif\n", "#else after #else"),
      ("#foo\n", "unknown directive #foo"),
      ("#define F(a) a\nF(1, 2)\n", "macro F takes 1 argument, given 2"),
      ("#extension GL_EXT_nothing : require\n", "extension GL_EXT_nothing is not supported"),
      ("#extension all : enable\n", "#extension all : enable is not allowed"),
      ("#if 1 / 0\n#endif\n", "division by zero"),
      ("/* never closed\n", "unterminated comment"),
      ("int a = 1 $ 2;\n", "'$' is not a character of the language"),
    ]
    for (src, want) in cases {
      let (_, log) = preprocess(src)
      #expect(log.contains(want), "\(src): \(log)")
    }
    // An unsupported extension to enable is a warning; `#version 100` and a comment before it are fine.
    #expect(preprocess("#extension GL_EXT_nothing : enable\n").log.hasPrefix("WARNING: 0:1:12: extension GL_EXT_nothing is not supported"))
    #expect(preprocess("// a comment\n/* another */ #version 100\nint x;\n").log == "")
  }

  @Test func lineChangesTheReportedLines() {
    let log = compileLog("#line 40 3\nvoid main() {\n  undeclared = 1.0;\n}\n", .vertex) ?? ""
    #expect(log.contains("ERROR: 3:41:3: 'undeclared': undeclared identifier"), "\(log)")
  }

  @Test func commentsAndContinuations() {
    let (t, _) = preprocess("a /* b\n c */ d // e\n#define X 1 \\\n + 2\nX\n")
    #expect(t == "a d 1 + 2")
  }
}

@Suite struct CheckTests {
  @Test func acceptedPrograms() throws {
    let fs = """
      precision mediump float;
      precision highp int;
      struct S { vec3 a; float b[2]; };
      uniform S u;
      uniform sampler2D tex;
      varying vec2 uv;
      invariant varying vec4 col;
      const float PI = 3.14159;
      float g = 2.0;
      vec4 proto(in vec2 a, const in float b);
      vec4 proto(vec2 a, float b) { return vec4(a, b, 1.0); }
      void outs(out float o, inout vec2 io) { o = io.x; io = io.yx; }
      highp float hp(lowp float x) { return x; }
      void main(void) {
        lowp vec4 t = texture2D(tex, uv);
        float o; vec2 io = uv;
        outs(o, io);
        S s = S(vec3(1.0), float[2](1.0, 2.0)[0] == 0.0 ? u.b : u.b);
        gl_FragColor = t + proto(io, o) + vec4(s.a, PI) + col * g + vec4(hp(1.0));
      }
      """
    // GLSL ES 1.00 has no array constructors: the line above must fail; the rest without it passes.
    #expect(compileLog(fs, .fragment) != nil)
    let ok = fs.replacingOccurrences(of: "S s = S(vec3(1.0), float[2](1.0, 2.0)[0] == 0.0 ? u.b : u.b);", with: "S s = u; s.b[1] = 2.0;")
    _ = try compileShader(ok, .fragment)
  }

  @Test func errorsAndWhereTheyAre() {
    let v: GLSLStage = .vertex
    let f: GLSLStage = .fragment
    let cases: [(String, GLSLStage, String)] = [
      ("void main() { float x = 1; }", v, "0:1:25: 'x': cannot initialize a float with a int"),
      ("void main() { vec3 v = vec2(1.0); }", v, "cannot initialize a vec3 with a vec2"),
      ("void main() { float x = y; }", v, "0:1:25: 'y': undeclared identifier"),
      ("void main() { gl_FragColor = vec4(1.0); }", v, "'gl_FragColor': undeclared identifier"),
      ("void main() { float x = 1.0; gl_FragColor = vec4(x); }", f, "0:1:21: no precision specified for float"),
      ("precision mediump float; void main() { gl_Position = vec4(1.0); }", f, "'gl_Position': undeclared identifier"),
      ("void main() { vec4 a; a.xk = vec2(1.0); }", v, "'xk' is not a swizzle of vec4"),
      ("void main() { vec4 a; a.xr = vec2(1.0); }", v, "swizzle 'xr' mixes the component sets"),
      ("void main() { vec2 a; a.z = 1.0; }", v, "swizzle 'z' names a component vec2 does not have"),
      ("void main() { vec4 a; a.xx = vec2(1.0); }", v, "cannot assign to a swizzle that names a component twice"),
      ("void main() { float a; a.x = 1.0; }", v, "only a vector has components"),
      ("uniform float u; void main() { u = 1.0; }", v, "'u': cannot assign to a uniform"),
      ("attribute float a; void main() { a = 1.0; }", v, "'a': cannot assign to an attribute"),
      ("precision mediump float; varying float x; void main() { x = 1.0; }", f, "cannot assign to a varying in a fragment shader"),
      ("const float c = 1.0; void main() { c = 2.0; }", v, "'c': cannot assign to a const variable"),
      ("const float c; void main() {}", v, "a const variable needs an initializer"),
      ("uniform float u; const float c = u; void main() {}", v, "initializer must be a constant expression"),
      ("void main() { float a[0]; }", v, "an array's size must be greater than zero"),
      ("void main() { float a[2]; a[2] = 1.0; }", v, "index 2 is out of range"),
      ("void main() { float a[2]; float b[2]; a = b; }", v, "an array cannot be assigned"),
      ("void main() { int a = 1; float b = 2.0; b = a + b; }", v, "'+' cannot take int and float"),
      ("void main() { vec3 a; vec2 b; a = a + b; }", v, "'+' cannot take vec3 and vec2"),
      ("void main() { mat3 m; vec2 v; v = m * v; }", v, "'*' cannot take mat3 and vec2"),
      ("void main() { int a = 5 % 2; }", v, "'%' is a reserved operator"),
      ("void main() { int a = 5 & 2; }", v, "'&' is a reserved operator"),
      ("void main() { int a = ~2; }", v, "'~' is a reserved operator"),
      ("void main() { if (1) {} }", v, "condition must be a bool"),
      ("void main() { bool b = !1.0; }", v, "'!' cannot take float"),
      ("void main() { break; }", v, "'break' outside a loop"),
      ("void main() { discard; }", v, "discard is only allowed in a fragment shader"),
      ("float f() { return 1; } void main() {}", v, "'f' returns float, not int"),
      ("void f() { return 1.0; } void main() {}", v, "a void function cannot return a value"),
      ("float f() { return; } void main() {}", v, "'f' must return a float"),
      ("void f(float x) {} void main() { f(1); }", v, "no overload of 'f' takes (int)"),
      ("void f(out float x) {} void main() { f(1.0); }", v, "cannot pass as an out or inout argument an expression that is not an l-value"),
      ("void main() { float x = sin(1); }", v, "no overload of built-in 'sin' takes (int)"),
      ("void main() { vec4 x = texture2D(1.0, vec2(0.0)); }", v, "no overload of built-in 'texture2D'"),
      ("uniform sampler2D s; void main() { vec4 x = texture2DLod(s, vec2(0.0), 0.0); }", v, ""),
      ("precision mediump float; uniform sampler2D s; void main() { gl_FragColor = texture2DLod(s, vec2(0.0), 0.0); }", f, "only available in a vertex shader"),
      ("uniform sampler2D s; void main() { gl_Position = texture2D(s, vec2(0.0), 1.0); }", v, "with a bias is only available in a fragment shader"),
      ("float sin(float x) { return x; } void main() {}", v, "is a built-in function and cannot be redeclared"),
      ("void main() { float gl_x; }", v, "names beginning with gl_ are reserved"),
      ("void main() { float x; float x; }", v, "'x' is already declared in this scope"),
      ("void f(float a) { float a; } void main() {}", v, "'a' is already declared in this scope"),
      ("void main() { for (int i = 0; i < 2; i++) { int i; } }", v, "'i' is already declared in this scope"),
      ("void main() { float switch; }", v, "'switch' is a reserved keyword"),
      ("void main() { vec4 v = vec4(1.0, 2.0); }", v, "too few components for a constructor of vec4"),
      ("void main() { vec2 v = vec2(1.0, 2.0, 3.0); }", v, "too many arguments to a constructor of vec2"),
      ("void main() { mat2 m = mat2(mat2(1.0), 1.0); }", v, "a matrix constructed from a matrix takes that one argument"),
      ("struct S { float a; }; void main() { S s = S(1); }", v, "member a of S is float, not int"),
      ("void main() { float f = 1.0f; }", v, "a float constant has no suffix"),
      ("void main() { int i = 4294967296; }", v, "is too large"),
      ("void f(); void main() { f(); }", v, ""),
      ("float f(float x) { return f(x); } void main() {}", v, "is recursive"),
      ("precision mediump float; void main() { gl_FragColor = vec4(0.0); gl_FragData[0] = vec4(1.0); }", f, "both gl_FragColor and gl_FragData"),
      ("attribute vec4 a[2]; void main() {}", v, "an attribute must be a float"),
      ("varying int v; void main() {}", v, "a varying must be a float"),
      ("precision mediump float; attribute vec4 a; void main() {}", f, "attribute declarations are only allowed in a vertex shader"),
      ("void main() { uniform float u; }", v, "'uniform' declarations are only allowed at global scope"),
      ("void main() { float x = 1.0 }", v, "syntax error: expected ';'"),
      ("void main() { float x = (1.0; }", v, "syntax error: expected ')'"),
      ("void main( { }", v, "syntax error"),
      ("float main() { return 1.0; }", v, "main must be declared void main()"),
      ("vec4 x = vec4(1.0); uniform vec4 y = vec4(1.0); void main() {}", v, "a uniform cannot have an initializer"),
      ("void main() { vec2 v = vec2(1.0) == vec2(1.0); }", v, "cannot initialize a vec2 with a bool"),
      ("void main() { float a[2]; float b[2]; bool c = a == b; }", v, "'==' cannot take float[2] and float[2]"),
      ("#extension GL_OES_standard_derivatives : enable\nvoid main() { float x = dFdx(1.0); }", v, "only available in a fragment shader"),
    ]
    for (src, stage, want) in cases {
      let log = compileLog(src, stage)
      if want.isEmpty {
        #expect(log == nil, "\(src) should compile: \(log ?? "")")
      } else {
        #expect(log?.contains(want) == true, "\(src): wanted '\(want)', got: \(log ?? "no error")")
      }
    }
  }

  @Test func theLogReportsEveryErrorOnce() {
    let log = compileLog("void main() {\n  float a = b + c;\n  vec2 v = 1.0;\n}\n", .vertex) ?? ""
    #expect(log.contains("ERROR: 0:2:13: 'b': undeclared identifier"))
    #expect(log.contains("ERROR: 0:2:17: 'c': undeclared identifier"))
    #expect(log.contains("ERROR: 0:3:12: 'v': cannot initialize a vec2 with a float"))
    #expect(log.split(separator: "\n").count == 3, "\(log)")
  }

  @Test func warningsGoToASuccessfulCompilesLog() throws {
    let s = try compileShader("float f(float x) { if (x > 0.0) return x; } void main() { gl_Position = vec4(f(1.0)); }", .vertex)
    #expect(s.log.contains("WARNING: 0:1:7: function 'f' can end without returning a value"))
  }

  @Test func theBuiltinConstantsAndLimits() throws {
    var limits = GLSLLimits()
    limits.maxVertexAttribs = 12
    let src = "const int a = gl_MaxVertexAttribs; float x[gl_MaxDrawBuffers + gl_MaxVaryingVectors]; void main() { gl_Position = vec4(float(a)); }"
    guard case .success(let s) = compile(source: Array(src.utf8), stage: .vertex, limits: limits) else {
      Issue.record("did not compile")
      return
    }
    let a = s.program.variables.first { $0.name == "a" }!
    #expect(a.value == [.i(12)])
    let x = s.program.variables.first { $0.name == "x" }!
    #expect(x.type.arraySize == 1 + 15)
  }
}

@Suite struct LinkTests {
  let vs = "attribute vec4 p; varying vec3 v; void main() { v = p.xyz; gl_Position = p; }"

  @Test func varyingsMustMatch() throws {
    let fsFloat = "precision mediump float; varying float v; void main() { gl_FragColor = vec4(v); }"
    #expect(try linkLog(vs, fsFloat)?.contains("varying 'v' is vec3 in the vertex shader and float in the fragment shader") == true)
    let fsMissing = "precision mediump float; varying vec3 w; void main() { gl_FragColor = vec4(w, 1.0); }"
    #expect(try linkLog(vs, fsMissing)?.contains("varying 'w' is read by the fragment shader but not declared in the vertex shader") == true)
    // A varying the fragment shader declares but never reads needs nothing of the vertex shader.
    #expect(try linkLog(vs, "precision mediump float; varying vec2 unused; void main() { gl_FragColor = vec4(1.0); }") == nil)
    let fsInvariant = "precision mediump float; invariant varying vec3 v; void main() { gl_FragColor = vec4(v, 1.0); }"
    #expect(try linkLog(vs, fsInvariant)?.contains("invariant in one shader and not in the other") == true)
    // Too many: 16 vec4 varyings against 15.
    var many = "attribute vec4 p;\n"
    var reads = "precision mediump float;\n"
    var sum = "vec4(0.0)"
    for i in 0..<16 {
      many += "varying vec4 v\(i);\n"
      reads += "varying vec4 v\(i);\n"
      sum += " + v\(i)"
    }
    many += "void main() { gl_Position = p; }"
    reads += "void main() { gl_FragColor = \(sum); }"
    #expect(try linkLog(many, reads)?.contains("the varyings need 16 vectors; the implementation has 15") == true)
  }

  @Test func eachShaderNeedsMainAndItsFunctions() throws {
    let fs = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"
    #expect(try linkLog("attribute vec4 p;", fs)?.contains("the vertex shader has no main function") == true)
    #expect(try linkLog("void f(); void main() { f(); gl_Position = vec4(0.0); }", fs)?.contains("calls 'f', which it declares but does not define") == true)
    // gl_Position never written: GL allows it.
    #expect(try linkLog("void main() {}", fs) == nil)
  }

  @Test func uniformsShareOneSlot() throws {
    let v = "uniform mat4 m; uniform vec4 onlyV; attribute vec4 p; void main() { gl_Position = m * p + onlyV; }"
    let f = "precision mediump float; uniform highp mat4 m; uniform vec4 onlyF; uniform vec4 unused; void main() { gl_FragColor = m[0] + onlyF; }"
    #expect(try linkLog(v, f)?.contains("uniform 'm' is declared with no precision in the vertex shader and highp in the other") == true)
    let p = try linkProgram(v, f.replacingOccurrences(of: "highp mat4", with: "mat4"))
    #expect(p.uniforms.map { $0.name } == ["m", "onlyV", "onlyF"])
    #expect(p.uniforms.map { $0.offset } == [32, 96, 112])
    #expect(p.uniformBlockBytes == 128)
    let fMismatch = "precision mediump float; uniform mat3 m; void main() { gl_FragColor = vec4(m[0], 1.0); }"
    #expect(try linkLog(v, fMismatch)?.contains("uniform 'm' is mat4 in the vertex shader and mat3 in the other") == true)
    // Both stages read the same words: each stage's block declares m at offset 32.
    for words in [p.vertexSPIRV, p.fragmentSPIRV] {
      #expect(instructionOperands(words, op: 72).contains { $0[1] == 7 && $0[2] == 35 && $0[3] == 32 })
    }
  }

  @Test func samplersAreBindingsFromOne() throws {
    let v = "uniform sampler2D vt; attribute vec4 p; varying vec2 t; void main() { t = p.xy; gl_Position = texture2DLod(vt, p.xy, 0.0); }"
    let f = """
      precision mediump float;
      struct M { sampler2D tex; vec4 tint; };
      uniform M mats[2];
      uniform sampler2D arr[3];
      uniform sampler2D vt;
      varying vec2 t;
      void main() { gl_FragColor = texture2D(mats[1].tex, t) * mats[0].tint + texture2D(arr[2], t) + texture2D(vt, t); }
      """
    let p = try linkProgram(v, f)
    let s = p.uniforms.filter { $0.isSampler }.map { "\($0.name):\($0.binding)x\($0.arraySize)" }
    #expect(s == ["vt:1x1", "mats[0].tex:2x1", "mats[1].tex:3x1", "arr[0]:4x3"])
    #expect(p.samplerBindings == 7)
    #expect(p.uniforms.first { $0.name == "mats[0].tint" }?.offset == 32)
    #expect(p.uniforms.first { $0.name == "mats[1].tint" }?.offset == 48)
    _ = try lowerAndCompile(p, .fragment)
  }

  @Test func attributesKeepTheirBindingsAndTheRestTakeTheLowestFree() throws {
    let v = "attribute vec4 a; attribute mat3 m; attribute vec2 b; attribute float c; attribute vec4 unused; void main() { gl_Position = a + vec4(m * vec3(b, c), 1.0); }"
    let f = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"
    let p = try linkProgram(v, f, bindings: [(name: "b", location: 1), (name: "nothere", location: 5)])
    let locs = Dictionary(uniqueKeysWithValues: p.attributes.map { ($0.name, $0.location) })
    #expect(locs == ["b": 1, "a": 0, "m": 2, "c": 5])
    #expect(p.attributes.first { $0.name == "m" }?.type == 0x8B5B)
    #expect(try linkLog(v, f, bindings: [(name: "a", location: 8)])?.contains("past the implementation's 8") == true)
    _ = try lowerAndCompile(p, .vertex)
  }

  @Test func theStagesMustBeTheRightWayRound() throws {
    let v = try compileShader("void main() {}", .vertex)
    let f = try compileShader("precision mediump float; void main() {}", .fragment)
    #expect(throws: GLSLError.self) { _ = try link(vertex: f, fragment: v, attributeBindings: []) }
  }
}
