// SPDX-License-Identifier: BSD-3-Clause

// What programs compute, run on the IR interpreter: control flow, inlined functions (early returns, out and inout
// parameters), l-value swizzles, matrices and their constructors, structures, arrays, constant expressions, the
// operators' shapes, conversions, uniforms of every kind, and the built-in variables under GL's clip control.

@testable import GLSL
import Testing

private let x = Varying(decl: "vec4 x", value: [0.5, -2, 3, 1.25])

private func fragment(_ body: String, prelude: String = "", varyings: [Varying] = [x], uniforms: (inout UniformBlock) -> Void = { _ in },
  fragCoord: [Float] = [0.5, 0.5, 0.5, 1], flip: Bool = false, height: Float = 0) throws -> [[Float]]
{
  var fs = "precision highp float;\n"
  for v in varyings { fs += "varying \(v.decl);\n" }
  fs += prelude + "\nvoid main() {\n" + body + "\n}\n"
  return try runFragment(fs, varyings: varyings, uniforms: uniforms, fragCoord: fragCoord, flip: flip, height: height)
}

@Suite struct ControlFlowTests {
  @Test func loopsBreakAndContinue() throws {
    let body = """
      float s = 0.0;
      for (int i = 0; i < 10; i++) {
        if (i == 2) continue;
        if (i == 7) break;
        s += float(i);
      }
      float w = 0.0;
      int k = 0;
      while (k < 4) { w += x.y; k++; }
      float d = 0.0;
      do { d += 1.0; } while (d < 3.5);
      float n = 0.0;
      for (int i = 0; i < 3; ++i) for (int j = 0; j < 4; j++) { if (j > i) break; n += 1.0; }
      gl_FragColor = vec4(s, w, d, n);
      """
    expectAll(try fragment(body), [0 + 1 + 3 + 4 + 5 + 6, -8, 4, 1 + 2 + 3], "loops")
  }

  @Test func aConstantCountLoopIsUnrolled() throws {
    let fs = """
      precision highp float;
      varying vec4 x;
      void main() {
        float w[4];
        for (int i = 0; i < 4; i++) w[i] = x[i] * float(i);
        float s = 0.0;
        for (float f = 3.0; f > 0.0; f -= 1.5) s += f;
        for (int i = 0; i < 4; i++) { if (w[i] > 100.0) break; s += w[i]; }
        gl_FragColor = vec4(w[1] + w[3], s, 0.0, 0.0);
      }
      """
    let p = try linkProgram("attribute vec4 p; varying vec4 x; void main() { x = p; gl_Position = p; }", fs)
    // The first two loops are unrolled; the third breaks, so it stays a loop.
    #expect(instructionOperands(p.fragmentSPIRV, op: 246).count == 1)
    let r = try runFragment(fs, varyings: [Varying(decl: "vec4 x", value: [0.5, -2, 3, 1.25])])
    expectAll(r.map { Array($0.prefix(2)) }, [-2 + 3.75, 4.5 + (0 - 2 + 6 + 3.75)], "unrolled")
  }

  @Test func earlyReturnsFromInlinedFunctions() throws {
    let prelude = """
      float classify(float v) {
        if (v < 0.0) return -1.0;
        if (v > 2.0) return 2.0;
        return v;
      }
      float firstAbove(vec4 v, float t) {
        for (int i = 0; i < 4; i++) {
          for (int j = 0; j < 2; j++) {
            if (j == 1 && v[i] > t) return float(i * 10 + j);
          }
        }
        return -5.0;
      }
      float nested(float v) {
        float r = 0.0;
        for (int i = 0; i < 8; i++) {
          r += 1.0;
          if (float(i) >= v) { return r * 100.0; }
        }
        return r;
      }
      void early(inout float v) {
        if (v > 0.0) { v = 1.0; return; }
        v = -1.0;
      }
      """
    let body = """
      float a = x.x; early(a);
      float b = x.y; early(b);
      gl_FragColor = vec4(classify(x.x) + classify(x.y) * 10.0 + classify(x.z) * 100.0, firstAbove(x, 1.0), nested(2.0) + nested(20.0), a * 2.0 + b);
      """
    expectAll(try fragment(body, prelude: prelude), [0.5 - 10 + 200, 21, 300 + 8, 2 - 1], "returns")
  }

  @Test func outAndInoutParametersCopyBack() throws {
    let prelude = """
      void split(vec4 v, out vec2 lo, out vec2 hi) { lo = v.xy; hi = v.zw; }
      void bump(inout float f, float by) { f += by; by = 0.0; }
      float sideEffect(inout float counter) { counter += 1.0; return counter; }
      """
    let body = """
      vec2 a; vec4 c = vec4(0.0);
      split(x, a, c.wz);
      float k = 1.0;
      bump(k, 2.0);
      float n = 0.0;
      bool t = sideEffect(n) > 5.0 && sideEffect(n) > 0.0;
      bool u = sideEffect(n) > 0.0 || sideEffect(n) > 0.0;
      gl_FragColor = vec4(a.x + a.y, c.z * 10.0 + c.w, k, n + (t ? 100.0 : 0.0) + (u ? 10.0 : 0.0));
      """
    expectAll(try fragment(body, prelude: prelude), [-1.5, 12.5 + 3, 3, 2 + 10], "parameters")
  }

  @Test func discardAndTheTernary() throws {
    let fs = """
      precision mediump float;
      varying vec4 x;
      void main() {
        if (x.x > 0.0) discard;
        gl_FragColor = x.y > 0.0 ? vec4(1.0) : vec4(2.0);
      }
      """
    // The interpreter does not run a discard; the program compiles (OpKill).
    let p = try linkProgram("attribute vec4 p; varying vec4 x; void main() { x = p; gl_Position = p; }", fs)
    _ = try lowerAndCompile(p, .fragment)
    #expect(instructionOperands(p.fragmentSPIRV, op: 252).count == 1)
    expectAll(try fragment("gl_FragColor = x.y > 0.0 ? vec4(1.0) : x.x > 0.0 ? vec4(2.0, 3.0, 4.0, 5.0) : vec4(6.0);"), [2, 3, 4, 5], "ternary")
    expectAll(try fragment("mat2 m = x.x > 0.0 ? mat2(1.0) : mat2(2.0); gl_FragColor = vec4(m[0], m[1]);"), [1, 0, 0, 1], "matrix ternary")
  }
}

@Suite struct ValueTests {
  @Test func swizzlesAsLvalues() throws {
    let body = """
      vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
      v.wx = v.xw;
      v.y += 10.0;
      v.zy.x = 7.0;
      vec4 w = x;
      w.xyz = w.zyx;
      gl_FragColor = vec4(v.x + v.w * 10.0, v.y, v.z, w.x + w.z);
      """
    expectAll(try fragment(body), [4 + 10, 12, 7, 3.5], "swizzles")
  }

  @Test func matricesAndTheirConstructors() throws {
    let body = """
      mat2 a = mat2(1.0, 2.0, 3.0, 4.0);
      mat2 b = mat2(vec2(5.0, 6.0), 7.0, 8.0);
      mat2 ab = a * b;
      vec2 av = a * vec2(1.0, 1.0);
      vec2 va = vec2(1.0, 1.0) * a;
      mat3 m3 = mat3(mat4(2.0));
      mat4 m4 = mat4(a);
      mat3 t = mat3(1.0) * 3.0 + mat3(x.xyz, x.yzw, x.zwx) / 2.0;
      ab[1][0] += 0.5;
      gl_FragColor = vec4(ab[0][0] + ab[1][0] * 100.0, av.x + av.y * 10.0, va.x + va.y * 10.0, m3[2][2] + m4[3][3] * 10.0 + m4[1][1] * 100.0 + t[1][1] * 1000.0);
      """
    // a*b: columns a*(5,6) = (23, 34), a*(7,8) = (31, 46); a*(1,1) = (4, 6); (1,1)*a = (3, 7).
    expectAll(try fragment(body), [23 + 31.5 * 100, 4 + 60, 3 + 70, 2 + 10 + 400 + (3 + 1.5) * 1000], "matrices")
    let m4 = """
      mat4 m = mat4(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0);
      mat4 n = m * m;
      gl_FragColor = (m * x) + n[2] * 0.0 + vec4(0.0, 0.0, 0.0, (x * m).y) - vec4(0.0, 0.0, 0.0, n[3][1]);
      """
    let m: [Float] = (1...16).map { Float($0) }
    var mx = [Float](repeating: 0, count: 4)
    for r in 0..<4 { for c in 0..<4 { mx[r] += m[c * 4 + r] * x.value[c] } }
    var xm1: Float = 0
    for k in 0..<4 { xm1 += x.value[k] * m[4 + k] }
    var n31: Float = 0
    for k in 0..<4 { n31 += m[k * 4 + 1] * m[12 + k] }
    expectAll(try fragment(m4), [mx[0], mx[1], mx[2], mx[3] + xm1 - n31], tolerance: 1e-5, "mat4")
  }

  @Test func structuresAndArrays() throws {
    let prelude = """
      struct Light { vec3 color; float power; };
      struct Scene { Light lights[2]; int count; };
      float total(Scene s) {
        float t = 0.0;
        for (int i = 0; i < 2; i++) t += s.lights[i].power * s.lights[i].color.g;
        return t;
      }
      """
    let body = """
      Scene s;
      s.lights[0] = Light(vec3(1.0, 2.0, 3.0), 0.5);
      s.lights[1].color = x.xyz;
      s.lights[1].power = 2.0;
      s.count = 2;
      float arr[3];
      for (int i = 0; i < 3; i++) arr[i] = float(i) * x.w;
      int j = int(x.z) - 2;
      Light l = s.lights[1];
      bool same = s.lights[0] == Light(vec3(1.0, 2.0, 3.0), 0.5);
      gl_FragColor = vec4(total(s), arr[j] + arr[2], l.color.z, same && !(s.lights[0] == l) ? 1.0 : 0.0);
      """
    expectAll(try fragment(body, prelude: prelude), [1 - 4, 1.25 + 2.5, 3, 1], "structures")
  }

  @Test func constantsAndConversions() throws {
    let prelude = """
      const float k = 2.0 * 3.0;
      const vec3 c = vec3(1.0, k, 3.0) * 0.5;
      const int n = 7 / 2;
      const mat2 m = mat2(1.0, 2.0, 3.0, 4.0);
      float g = c.y + float(n);
      """
    let body = """
      int i = int(x.y * 1.5);
      bool b = bool(x.x);
      ivec2 iv = ivec2(x.zw);
      bvec3 bb = bvec3(x.xyz - vec3(0.5, 0.0, 0.0));
      gl_FragColor = vec4(g + m[1][0], float(i) + float(b) * 10.0, float(iv.x * 10 + iv.y) / float(n), float(bb.x) + float(bb.y) * 2.0 + float(bb.z) * 4.0);
      """
    expectAll(try fragment(body, prelude: prelude), [3 + 3 + 3, -3 + 10, 31.0 / 3, 6], "constants")
  }

  @Test func integerArithmeticAndComparisons() throws {
    let body = """
      int a = int(x.z);
      int b = -7;
      ivec3 v = ivec3(a, b, 2) * 2 + ivec3(1);
      gl_FragColor = vec4(float(b / a), float(v.x + v.y + v.z), float(a > b) + float(a <= 3) * 2.0, float(-a));
      """
    expectAll(try fragment(body), [-2, 7 + -13 + 5, 3, -3], "integers")
  }
}

@Suite struct UniformTests {
  @Test func uniformsOfEveryKind() throws {
    let prelude = """
      struct S { vec2 a; bool flag; mat2 m; };
      uniform float f;
      uniform vec3 v3;
      uniform ivec2 i2;
      uniform bool b;
      uniform bvec2 b2;
      uniform mat3 m3;
      uniform float arr[3];
      uniform vec2 varr[2];
      uniform S s;
      uniform S ss[2];
      """
    let body = """
      int idx = int(x.w);
      gl_FragColor = vec4(f + v3.z + float(i2.y), (b ? 1.0 : 0.0) + (b2.y ? 2.0 : 0.0), m3[1][2] + arr[idx + 1] + varr[1].y,
        s.a.y + (s.flag ? 100.0 : 0.0) + s.m[1][0] + ss[idx].m[0][1] * 1000.0);
      """
    let fsrc = "precision highp float;\nvarying vec4 x;\n" + prelude + "\nvoid main() {\n" + body + "\n}\n"
    let lp = try linkProgram("attribute vec4 p; varying vec4 x; void main() { x = p; gl_Position = p; }", fsrc)
    #expect(lp.uniforms.map { $0.name } == ["f", "v3", "i2", "b", "b2", "m3", "arr[0]", "varr[0]", "s.a", "s.flag", "s.m", "ss[0].a", "ss[0].flag", "ss[0].m", "ss[1].a", "ss[1].flag", "ss[1].m"])
    let got = try fragment(body, prelude: prelude) { u in
      u.set("f", [1])
      u.set("v3", [0, 0, 2])
      u.set("i2", ints: [5, 6])
      u.set("b", ints: [1])
      u.set("b2", ints: [0, 1])
      u.set("m3", [0, 0, 0, 0, 0, 7, 0, 0, 0])
      u.set("arr[0]", [1])
      u.set("arr[1]", [2])
      u.set("arr[2]", [3])
      u.set("varr[1]", [0, 4])
      u.set("s.a", [0, 0.25])
      u.set("s.flag", ints: [1])
      u.set("s.m", [0, 0, 3, 0])
      u.set("ss[1].m", [0, 0.5, 0, 0])
    }
    expectAll(got, [1 + 2 + 6, 3, 7 + 3 + 4, 0.25 + 100 + 3 + 500], "uniforms")
  }

  @Test func wholeUniformStructuresAndSamplerParameters() throws {
    let fs = """
      precision highp float;
      struct S { vec2 a; bool flag; mat2 m; };
      struct M { sampler2D tex; vec4 tint; };
      uniform S s;
      uniform M mats[2];
      varying vec4 x;
      vec4 shade(M m, vec2 uv) { return texture2D(m.tex, uv) * m.tint; }
      float pick(S v) { return v.flag ? v.m[1][1] + v.a.x : -1.0; }
      void main() {
        S copy = s;
        copy.a.x += 1.0;
        gl_FragColor = vec4(pick(copy), pick(s), shade(mats[1], x.xy).x, shade(mats[0], x.xy).y);
      }
      """
    let texel: (UInt64, [Float], Int) -> Float = { image, _, k in Float(image) * 10 + Float(k) }
    let got = try runFragment(fs, varyings: [Varying(decl: "vec4 x", value: [0.5, -2, 3, 1.25])], uniforms: { u in
      u.set("s.a", [2, 0])
      u.set("s.flag", ints: [1])
      u.set("s.m", [0, 0, 0, 5])
      u.set("mats[0].tint", [1, 2, 3, 4])
      u.set("mats[1].tint", [0.5, 1, 1, 1])
    }, texel: texel)
    // mats[0].tex is binding 1 (slot 11), mats[1].tex binding 2 (slot 12).
    expectAll(got, [8, 7, 120 * 0.5, 111 * 2], "structures and samplers")
  }

  @Test func theBlockFollowsStd140() throws {
    let fs = """
      precision mediump float;
      struct T { float a; vec3 b; mat2 c; float d[2]; };
      uniform float f;
      uniform vec3 v;
      uniform vec2 w;
      uniform mat3 m;
      uniform T t;
      uniform vec4 last;
      void main() { gl_FragColor = vec4(f) + vec4(v, w.x) + vec4(m[0], t.a) + vec4(t.b, t.c[0].x + t.d[1]) + last; }
      """
    let p = try linkProgram("attribute vec4 p; void main() { gl_Position = p; }", fs)
    func u(_ n: String) -> ActiveUniform { p.uniforms.first { $0.name == n }! }
    #expect(u("f").offset == 32)
    #expect(u("v").offset == 48)
    #expect(u("w").offset == 64)
    #expect(u("m").offset == 80 && u("m").matrixStride == 16)
    #expect(u("t.a").offset == 128 && u("t.b").offset == 144 && u("t.c").offset == 160 && u("t.d[0]").offset == 192)
    #expect(u("t.d[0]").arrayStride == 16 && u("t.d[0]").arraySize == 2)
    #expect(u("last").offset == 224)
    #expect(p.uniformBlockBytes == 240)
    _ = try lowerAndCompile(p, .fragment)
  }
}

@Suite struct BuiltinVariableTests {
  @Test func fragCoordAndPointCoordFollowTheDriverWords() throws {
    let fs = """
      precision mediump float;
      void main() { gl_FragColor = vec4(gl_FragCoord.xy, gl_FrontFacing ? 1.0 : 0.0, 0.0); }
      """
    // Off-screen (no flip): the core's y is GL's. Presented (flipped): GL's y is the height less the core's.
    expectAll(try runFragment(fs, fragCoord: [10.5, 20.5, 0.25, 1]).map { Array($0.prefix(2)) }, [10.5, 20.5], "unflipped")
    expectAll(try runFragment(fs, fragCoord: [10.5, 20.5, 0.25, 1], flip: true, height: 600).map { Array($0.prefix(2)) }, [10.5, 579.5], "flipped")
    var vk = GLSLLinkOptions()
    vk.clipControl = .vulkan
    expectAll(try runFragment(fs, fragCoord: [10.5, 20.5, 0.25, 1], options: vk, flip: true, height: 600).map { Array($0.prefix(2)) }, [10.5, 20.5], "vulkan")
  }

  @Test func theVertexStageWritesPositionVaryingsAndPointSize() throws {
    let vs = """
      attribute vec3 pos;
      attribute mat2 rot;
      uniform mat4 mvp;
      varying vec2 r;
      varying mat2 mv;
      varying float arr[2];
      void main() {
        r = rot * pos.xy;
        mv = rot * 2.0;
        arr[0] = pos.z; arr[1] = -pos.z;
        gl_PointSize = 4.0;
        gl_Position = mvp * vec4(pos, 1.0);
      }
      """
    let fs = """
      precision mediump float;
      varying vec2 r;
      varying mat2 mv;
      varying float arr[2];
      void main() { gl_FragColor = vec4(r, mv[1][1], arr[1]); }
      """
    let results = try runVertex(vs, fs: fs, attributes: ["pos": [1, 2, 0.5], "rot": [0, 1, -1, 0]]) { u in
      u.set("mvp", [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
    }
    for res in results {
      #expect(close(res.position, [1, 2, 0.75, 1]), "position \(res.position)")
      #expect(res.varyings["r"] == [-2, 1])
      #expect(res.varyings["mv"] == [0, 2, -2, 0])
      #expect(res.varyings["arr"] == [0.5, -0.5])
    }
    let p = try linkProgram(vs, fs)
    #expect(p.attributes.first { $0.name == "rot" }.map { $0.type } == 0x8B5A)
    #expect(p.varyings.map { $0.name } == ["r", "mv", "arr"])
    #expect(p.varyings.map { $0.location } == [0, 1, 3])
  }

  @Test func relaxedPrecisionDecoratesMediumpValues() throws {
    let p = try linkProgram(basicVS, basicFS)
    // RelaxedPrecision (decoration 0) on the fragment stage's mediump arithmetic, none in the highp vertex stage's.
    let fsRelaxed = instructionOperands(p.fragmentSPIRV, op: 71).filter { $0[1] == 0 }.count
    let vsRelaxed = instructionOperands(p.vertexSPIRV, op: 71).filter { $0[1] == 0 }.count
    #expect(fsRelaxed > 0)
    #expect(vsRelaxed == 0)
  }
}
