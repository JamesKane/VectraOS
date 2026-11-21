// SPDX-License-Identifier: BSD-3-Clause

// The precision of the float functions on binary16: each run on the interpreter over the binary16 values of its domain (every
// value with VX_SLOW_TESTS, an even sample otherwise) and compared, in units in the last place of binary16, with the correctly
// rounded result computed in double precision. The functions are computed in binary32 and rounded once, so the error is the final
// rounding and what binary32's own error adds.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

@Suite struct HalfPrecisionTests {
  struct Fn {
    var name: String
    var op: String
    var binary = false
    var accept: (Double, Double) -> Bool
    var reference: (Double, Double) -> Double
    var bound = 1.5
  }

  static var functions: [Fn] {
    let any: (Double, Double) -> Bool = { _, _ in true }
    return [
      Fn(name: "fdiv", op: "OpFDiv %T", binary: true, accept: { _, y in y != 0 }, reference: { $0 / $1 }),
      Fn(name: "sqrt", op: "OpExtInst %T %glsl 31", accept: { x, _ in x > 0 }, reference: { x, _ in sqrt(x) }),
      Fn(name: "inversesqrt", op: "OpExtInst %T %glsl 32", accept: { x, _ in x > 0 }, reference: { x, _ in 1 / sqrt(x) }),
      Fn(name: "exp", op: "OpExtInst %T %glsl 27", accept: { x, _ in x > -9 && x < 11 }, reference: { x, _ in exp(x) }),
      Fn(name: "exp2", op: "OpExtInst %T %glsl 29", accept: { x, _ in x > -13 && x < 16 }, reference: { x, _ in exp2(x) }),
      Fn(name: "log", op: "OpExtInst %T %glsl 28", accept: { x, _ in x > 0 }, reference: { x, _ in log(x) }),
      Fn(name: "log2", op: "OpExtInst %T %glsl 30", accept: { x, _ in x > 0 }, reference: { x, _ in log2(x) }),
      Fn(
        name: "pow", op: "OpExtInst %T %glsl 26", binary: true, accept: { x, y in x > 0 && abs(y) < 16 }, reference: { pow($0, $1) },
        bound: 2),
      Fn(name: "sin", op: "OpExtInst %T %glsl 13", accept: { x, _ in abs(x) < 100 }, reference: { x, _ in sin(x) }),
      Fn(name: "cos", op: "OpExtInst %T %glsl 14", accept: { x, _ in abs(x) < 100 }, reference: { x, _ in cos(x) }),
      Fn(name: "tan", op: "OpExtInst %T %glsl 15", accept: { x, _ in abs(x) < 1.5 }, reference: { x, _ in tan(x) }, bound: 2),
      Fn(name: "asin", op: "OpExtInst %T %glsl 16", accept: { x, _ in abs(x) <= 1 }, reference: { x, _ in asin(x) }),
      Fn(name: "acos", op: "OpExtInst %T %glsl 17", accept: { x, _ in abs(x) <= 1 }, reference: { x, _ in acos(x) }),
      Fn(name: "atan", op: "OpExtInst %T %glsl 18", accept: any, reference: { x, _ in atan(x) }),
      Fn(name: "atan2", op: "OpExtInst %T %glsl 25", binary: true, accept: { x, y in x != 0 || y != 0 }, reference: { atan2($0, $1) }),
      Fn(name: "sinh", op: "OpExtInst %T %glsl 19", accept: { x, _ in abs(x) < 11 }, reference: { x, _ in sinh(x) }, bound: 2),
      Fn(name: "cosh", op: "OpExtInst %T %glsl 20", accept: { x, _ in abs(x) < 11 }, reference: { x, _ in cosh(x) }, bound: 2),
      Fn(name: "tanh", op: "OpExtInst %T %glsl 21", accept: any, reference: { x, _ in tanh(x) }, bound: 2),
      Fn(name: "asinh", op: "OpExtInst %T %glsl 22", accept: any, reference: { x, _ in asinh(x) }, bound: 2),
      Fn(name: "acosh", op: "OpExtInst %T %glsl 23", accept: { x, _ in x >= 1 }, reference: { x, _ in acosh(x) }, bound: 2),
      Fn(name: "atanh", op: "OpExtInst %T %glsl 24", accept: { x, _ in abs(x) < 1 }, reference: { x, _ in atanh(x) }, bound: 2),
    ]
  }

  @Test func float16FunctionsAreWithinTheirBounds() throws {
    let take = slowTests ? 1 : 24
    var table = ""
    for fn in HalfPrecisionTests.functions {
      let probe = Sweep(name: fn.name, op: fn.op, binary: fn.binary, inputs: { _, _ in (0, 0) }, reference: { _, _ in 0 }, bound: { _, _, _ in 1 })
      let cs = try compileText(PrecisionTests.shader(probe, half: true))
      var xs: [Float16] = []
      var ys: [Float16] = []
      var domain: [Float16] = []
      for p in 0..<65536 {
        let h = Float16(bitPattern: UInt16(p))
        if h.isFinite { domain.append(h) }
      }
      var k = 0
      for (n, h) in domain.enumerated() where n % take == 0 {
        let partner = domain[(n * 7919 + 13) % domain.count]
        if fn.accept(Double(h), fn.binary ? Double(partner) : 0) {
          xs.append(h)
          ys.append(fn.binary ? partner : 0)
          k += 1
        }
      }
      while xs.count % 64 != 0 {
        xs.append(xs[0])
        ys.append(ys[0])
      }
      var got: [Float16] = []
      let slice = 64 * 16
      var base = 0
      while base < xs.count {
        let m = min(slice, xs.count - base)
        let out = try run(
          cs,
          [pack16(xs[base..<(base + m)].map { $0.bitPattern }), pack16(ys[base..<(base + m)].map { $0.bitPattern }), pack16([UInt16](repeating: 0, count: m))],
          groups: m / 64)
        got += unpack16(out[2]).map { Float16(bitPattern: $0) }
        base += m
      }
      var worst = 0.0
      var at = (0.0, 0.0)
      var compared = 0
      for i in 0..<xs.count {
        let x = Double(xs[i])
        let y = Double(ys[i])
        let exact = fn.reference(x, y)
        guard exact.isFinite, abs(exact) >= 6.2e-5, abs(exact) < 65000 else { continue }
        let want = Float16(exact)
        let g = got[i]
        if !g.isFinite {
          worst = .infinity
          at = (x, y)
          continue
        }
        let err = abs(Double(g) - exact) / Double(want.ulp)
        compared += 1
        if err > worst {
          worst = err
          at = (x, y)
        }
      }
      table += "\(fn.name) f16 max \(worst) ulp at \(at), \(compared) values\n"
      #expect(worst <= fn.bound, "\(fn.name): \(worst) ulp at \(at)")
      #expect(compared > 0, "\(fn.name) compared nothing")
    }
    if getenv("VX_PRECISION_TABLE") != nil { print(table) }
  }
}
