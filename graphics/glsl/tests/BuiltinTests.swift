// SPDX-License-Identifier: BSD-3-Clause

// Every built-in function of chapter 8 run on the IR interpreter against a CPU reference, through the whole path
// (GLSL, SPIR-V, the lowering, the compiler); the texture lookups against a model of the texels, and the derivatives
// compiled.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
@testable import GLSL
import Testing

private let a: [Float] = [0.3, -1.25, 2.5, 0.75]
private let bv: [Float] = [1.5, 0.5, -0.75, 2.0]
private let c: [Float] = [0.3, -0.6, 0.9, 0.1]
private let inputs = [Varying(decl: "vec4 a", value: a), Varying(decl: "vec4 b", value: bv), Varying(decl: "vec4 c", value: c)]

private func each(_ f: (Float) -> Float, _ x: [Float]) -> [Float] { x.map(f) }
private func each2(_ f: (Float, Float) -> Float, _ x: [Float], _ y: [Float]) -> [Float] { zip(x, y).map { f($0, $1) } }
private func dot4(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
private func normalized(_ x: [Float]) -> [Float] { let l = dot4(x, x).squareRoot(); return x.map { $0 / l } }
private func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
  let t = min(max((x - e0) / (e1 - e0), 0), 1)
  return t * t * (3 - 2 * t)
}

/// (expression, components, reference, tolerance)
private let cases: [(String, Int, [Float], Float)] = [
  ("radians(a)", 4, each({ $0 * .pi / 180 }, a), 1e-6),
  ("degrees(a)", 4, each({ $0 * 180 / .pi }, a), 1e-6),
  ("sin(a)", 4, each(sinf, a), 2e-4),
  ("cos(a)", 4, each(cosf, a), 2e-4),
  ("tan(c)", 4, each(tanf, c), 2e-4),
  ("asin(c)", 4, each(asinf, c), 2e-4),
  ("acos(c)", 4, each(acosf, c), 2e-4),
  ("atan(a)", 4, each(atanf, a), 2e-4),
  ("atan(a, b)", 4, each2(atan2f, a, bv), 2e-4),
  ("pow(abs(a), b)", 4, each2({ powf(abs($0), $1) }, a, bv), 2e-4),
  ("exp(a)", 4, each(expf, a), 2e-4),
  ("log(abs(a))", 4, each({ logf(abs($0)) }, a), 2e-4),
  ("exp2(a)", 4, each(exp2f, a), 2e-4),
  ("log2(abs(a))", 4, each({ log2f(abs($0)) }, a), 2e-4),
  ("sqrt(abs(a))", 4, each({ abs($0).squareRoot() }, a), 1e-5),
  ("inversesqrt(abs(a))", 4, each({ 1 / abs($0).squareRoot() }, a), 1e-5),
  ("abs(a)", 4, each(abs, a), 0),
  ("sign(a)", 4, each({ $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }, a), 0),
  ("floor(a)", 4, each({ $0.rounded(.down) }, a), 0),
  ("ceil(a)", 4, each({ $0.rounded(.up) }, a), 0),
  ("fract(a)", 4, each({ $0 - $0.rounded(.down) }, a), 1e-6),
  ("mod(a, b)", 4, each2({ $0 - $1 * ($0 / $1).rounded(.down) }, a, bv), 1e-5),
  ("mod(a, 0.7)", 4, each({ $0 - 0.7 * ($0 / 0.7).rounded(.down) }, a), 1e-5),
  ("min(a, b)", 4, each2(min, a, bv), 0),
  ("min(a, 0.5)", 4, each({ min($0, 0.5) }, a), 0),
  ("max(a, b)", 4, each2(max, a, bv), 0),
  ("max(a, 0.5)", 4, each({ max($0, 0.5) }, a), 0),
  ("clamp(a, -0.5, 1.0)", 4, each({ min(max($0, -0.5), 1) }, a), 0),
  ("clamp(a, b, b + 1.0)", 4, each2({ min(max($0, $1), $1 + 1) }, a, bv), 0),
  ("mix(a, b, 0.25)", 4, each2({ $0 * 0.75 + $1 * 0.25 }, a, bv), 1e-6),
  ("mix(a, b, c)", 4, (0..<4).map { a[$0] * (1 - c[$0]) + bv[$0] * c[$0] }, 1e-6),
  ("step(b, a)", 4, each2({ $1 < $0 ? 0 : 1 }, bv, a), 0),
  ("step(0.5, a)", 4, each({ $0 < 0.5 ? 0 : 1 }, a), 0),
  ("smoothstep(-1.0, 2.0, a)", 4, each({ smooth(-1, 2, $0) }, a), 1e-5),
  ("smoothstep(b, b + 2.0, a)", 4, each2({ smooth($1, $1 + 2, $0) }, a, bv), 1e-5),
  ("length(a)", 1, [dot4(a, a).squareRoot()], 1e-6),
  ("length(a.x)", 1, [abs(a[0])], 0),
  ("distance(a, b)", 1, [dot4(each2(-, a, bv), each2(-, a, bv)).squareRoot()], 1e-6),
  ("dot(a, b)", 1, [dot4(a, bv)], 1e-6),
  ("dot(a.y, b.y)", 1, [a[1] * bv[1]], 0),
  ("cross(a.xyz, b.xyz)", 3, [a[1] * bv[2] - a[2] * bv[1], a[2] * bv[0] - a[0] * bv[2], a[0] * bv[1] - a[1] * bv[0]], 1e-6),
  ("normalize(a)", 4, normalized(a), 1e-6),
  ("faceforward(a, b, c)", 4, dot4(c, bv) < 0 ? a : a.map { -$0 }, 0),
  ("faceforward(a, b, -c)", 4, dot4(c.map { -$0 }, bv) < 0 ? a : a.map { -$0 }, 0),
  ("reflect(a, normalize(b))", 4, { let n = normalized(bv); let d = dot4(n, a); return (0..<4).map { a[$0] - 2 * d * n[$0] } }(), 1e-5),
  ("refract(normalize(a), normalize(b), 0.6)", 4, {
    let i = normalized(a)
    let n = normalized(bv)
    let d = dot4(n, i)
    let k = 1 - 0.36 * (1 - d * d)
    return k < 0 ? [0, 0, 0, 0] : (0..<4).map { 0.6 * i[$0] - (0.6 * d + k.squareRoot()) * n[$0] }
  }(), 1e-5),
  ("refract(a, normalize(b), 4.0)", 4, {
    let n = normalized(bv)
    let d = dot4(n, a)
    let k = 1 - 16 * (1 - d * d)
    return k < 0 ? [0, 0, 0, 0] : (0..<4).map { 4 * a[$0] - (4 * d + k.squareRoot()) * n[$0] }
  }(), 1e-5),
  ("vec4(matrixCompMult(mat2(a), mat2(b)))", 4, each2(*, a, bv), 0),
  ("vec4(lessThan(a, b))", 4, each2({ $0 < $1 ? 1 : 0 }, a, bv), 0),
  ("vec4(lessThanEqual(a, a))", 4, [1, 1, 1, 1], 0),
  ("vec4(greaterThan(a, b))", 4, each2({ $0 > $1 ? 1 : 0 }, a, bv), 0),
  ("vec4(greaterThanEqual(a, b))", 4, each2({ $0 >= $1 ? 1 : 0 }, a, bv), 0),
  ("vec4(equal(a, vec4(a.x, b.y, a.z, b.w)))", 4, [1, 0, 1, 0], 0),
  ("vec4(notEqual(a, vec4(a.x, b.y, a.z, b.w)))", 4, [0, 1, 0, 1], 0),
  ("vec4(lessThan(ivec4(a * 4.0), ivec4(b * 4.0)))", 4, each2({ Int($0 * 4) < Int($1 * 4) ? 1 : 0 }, a, bv), 0),
  ("vec4(equal(ivec2(a.xy * 4.0), ivec2(1, -5)), notEqual(ivec2(3), ivec2(a.zw)))", 4, [1, 1, 1, 1], 0),
  ("vec4(equal(bvec2(a.xy), bvec2(true, false)), notEqual(bvec2(true), bvec2(c.xy)))", 4, [1, 0, 0, 0], 0),
  ("float(any(lessThan(a, b)))", 1, [1], 0),
  ("float(all(lessThan(a, b)))", 1, [0], 0),
  ("float(all(lessThan(a, a + 1.0)))", 1, [1], 0),
  ("vec4(not(lessThan(a, b)))", 4, each2({ $0 < $1 ? 0 : 1 }, a, bv), 0),
]

@Suite struct BuiltinTests {
  @Test func everyBuiltinFunction() throws {
    for (expr, n, want, tol) in cases {
      expectAll(try evaluate(expr, components: n, varyings: inputs), want, tolerance: tol, expr)
    }
  }

  /// The texture lookups: the texel at (u, v) of the texture in heap slot t, channel k, is t + u + 10 v + 100 k.
  @Test func textureLookups() throws {
    let texel: (UInt64, [Float], Int) -> Float = { image, uv, k in Float(image) + uv[0] + 10 * uv[1] + 100 * Float(k) }
    let uv = Varying(decl: "vec4 uv", value: [0.25, 0.5, 2, 4])
    let fs = """
      precision mediump float;
      uniform sampler2D s0;
      uniform sampler2D s1;
      varying vec4 uv;
      void main() {
        gl_FragColor = %EXPR%;
      }
      """
    // The active samplers take bindings from 1 in their declaration order: s0 (or s1, alone) binding 1 (slot 11),
    // s1 binding 2 (slot 12) beside s0.
    let lookups: [(String, [Float])] = [
      ("texture2D(s0, uv.xy)", [11.0 + 0.25 + 5, 111.0 + 0.25 + 5, 211.0 + 0.25 + 5, 311.0 + 0.25 + 5]),
      ("texture2D(s1, uv.yx)", [11.0 + 0.5 + 2.5, 111.0 + 0.5 + 2.5, 211.0 + 0.5 + 2.5, 311.0 + 0.5 + 2.5]),
      ("texture2DProj(s0, uv.xyz)", [11.0 + 0.125 + 2.5, 111.0 + 0.125 + 2.5, 211.0 + 0.125 + 2.5, 311.0 + 0.125 + 2.5]),
      ("texture2DProj(s0, uv)", [11.0 + 0.0625 + 1.25, 111.0 + 0.0625 + 1.25, 211.0 + 0.0625 + 1.25, 311.0 + 0.0625 + 1.25]),
      ("texture2D(s0, uv.xy, 1.5) - texture2D(s1, uv.xy, -1.0)", [-1, -1, -1, -1]),
      ("texture2DProj(s1, uv.xyz, 0.5).zw", [0, 0, 0, 0]),
    ]
    for (expr, want) in lookups {
      var src = fs.replacingOccurrences(of: "%EXPR%", with: expr.hasSuffix(".zw") ? "vec4(\(expr) - texture2DProj(s1, uv.xyz).zw, 0.0, 0.0)" : expr)
      if expr.contains("+") { src = src.replacingOccurrences(of: "mediump", with: "highp") }
      expectAll(try runFragment(src, varyings: [uv], texel: texel), want, tolerance: 1e-6, expr)
    }
  }

  @Test func vertexTextureLookupsAndCubesLink() throws {
    // texture2DLod and texture2DProjLod are the vertex shader's; textureCube's image is a cube, which the layer's
    // lowering takes once it lowers cubes: here the SPIR-V is made and checked to be a cube's sample.
    let vs = """
      attribute vec4 p;
      uniform sampler2D height;
      uniform samplerCube env;
      varying vec4 v;
      void main() {
        v = texture2DLod(height, p.xy, 0.0) + texture2DProjLod(height, p.xyz, 1.0) + texture2DProjLod(height, p, 2.0)
          + texture2D(height, p.xy) + textureCubeLod(env, p.xyz, 0.0) + texture2DProj(height, p) + textureCube(env, p.xyz);
        gl_Position = p;
      }
      """
    let fs = """
      precision mediump float;
      uniform samplerCube env;
      varying vec4 v;
      void main() { gl_FragColor = v + textureCube(env, v.xyz) + textureCube(env, v.xyz, 1.0); }
      """
    let p = try linkProgram(vs, fs)
    #expect(p.uniforms.filter { $0.isSampler }.map { $0.name } == ["height", "env"])
    #expect(p.uniforms.first { $0.name == "env" }?.type == 0x8B60)
    // A cube image (Dim 3) is declared in both stages.
    for words in [p.vertexSPIRV, p.fragmentSPIRV] { #expect(instructionOperands(words, op: 25).contains { $0[2] == 3 }) }
  }

  @Test func derivativesNeedTheExtensionAndCompile() throws {
    #expect(compileLog("precision mediump float; varying vec2 t; void main() { gl_FragColor = vec4(dFdx(t), 0.0, 1.0); }", .fragment)?
      .contains("GL_OES_standard_derivatives") == true)
    let fs = """
      #extension GL_OES_standard_derivatives : enable
      precision mediump float;
      varying vec2 t;
      void main() { gl_FragColor = vec4(dFdx(t), dFdy(t.x), fwidth(t.y)); }
      """
    let p = try linkProgram("attribute vec4 p; varying vec2 t; void main() { t = p.xy; gl_Position = p; }", fs)
    _ = try lowerAndCompile(p, .fragment)
    #expect(compileLog("#extension GL_OES_standard_derivatives : enable\nvoid main() { gl_Position = vec4(dFdx(1.0)); }", .vertex)?
      .contains("fragment shader") == true)
  }
}

/// The SPIR-V's instructions of one opcode, each as its operand words.
func instructionOperands(_ words: [UInt32], op: UInt16) -> [[UInt32]] {
  var out: [[UInt32]] = []
  var pos = 5
  while pos < words.count {
    let count = Int(words[pos] >> 16)
    if UInt16(truncatingIfNeeded: words[pos]) == op { out.append(Array(words[(pos + 1)..<(pos + count)])) }
    pos += max(count, 1)
  }
  return out
}

extension String {
  func replacingOccurrences(of a: String, with b: String) -> String {
    var out = ""
    var rest = Substring(self)
    while let r = rest.range(of: a) {
      out += rest[..<r.lowerBound] + b
      rest = rest[r.upperBound...]
    }
    return out + rest
  }
}

extension Substring {
  func range(of s: String) -> Range<Substring.Index>? {
    let n = s.count
    guard n > 0, count >= n else { return nil }
    var i = startIndex
    while i < endIndex {
      if self[i...].hasPrefix(s) { return i..<index(i, offsetBy: n) }
      i = index(after: i)
    }
    return nil
  }
}
