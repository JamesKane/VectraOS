// SPDX-License-Identifier: BSD-3-Clause

// float16 in registers and in storage (valhall 11a, 11c.6), on the interpreter against a CPU reference.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

@Suite struct NarrowFloatTests {
  @Test func f16ArithmeticAndConversions() throws {
    let cs = try compileGLSL("f16ops.comp")
    #expect(violations(cs) == [])
    let n = 64
    var xs: [Float16] = []
    var ys: [Float16] = []
    var seed: UInt32 = 12345
    func rnd() -> UInt32 {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return seed >> 8
    }
    for k in 0..<n {
      let sx = Float(Int(rnd() % 20001) - 10000) / 100
      let sy = Float(Int(rnd() % 20001) - 10000) / 100
      xs.append(Float16(k == 0 ? 0.5 : sx))
      ys.append(Float16(k == 0 ? 0.5 : (k == 1 ? Float(xs[1]) : sy)))
    }
    let out = try run(cs, [pack16(xs.map { $0.bitPattern }), pack16(ys.map { $0.bitPattern }), pack16([UInt16](repeating: 0, count: 8 * n)), packF([Float](repeating: 0, count: 4 * n))])
    let r = unpack16(out[2]).map { Float16(bitPattern: $0) }
    let s = unpackF(out[3])
    for i in 0..<n {
      let x = xs[i]
      let y = ys[i]
      let want: [Float16] = [
        x + y, x - y, x * y, x.addingProduct(x, y).isNaN ? 0 : Float16(Float(x) * Float(y) + Float(x)), -x, abs(x), x < y ? min(x, y) : max(x, y), x == y ? 1 : 2,
      ]
      for k in 0..<8 {
        if k == 3 { continue }
        #expect(r[8 * i + k].bitPattern == want[k].bitPattern, "elem \(i) op \(k): \(x) \(y) got \(r[8 * i + k]) want \(want[k])")
      }
      // fma: one rounding, computed exactly through Double.
      let fm = Float16(Double(x) * Double(y) + Double(x))
      #expect(r[8 * i + 3].bitPattern == fm.bitPattern, "fma \(x) \(y)")
      #expect(s[4 * i] == Float(x))
      #expect(s[4 * i + 1] == Float(x) + Float(y))
      #expect(s[4 * i + 2] == Float(Float16(Float(x) * 1.5)))
      #expect(s[4 * i + 3] == Float(Int(x)))
    }
  }
}
