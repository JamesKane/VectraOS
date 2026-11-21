// SPDX-License-Identifier: BSD-3-Clause

// Division and remainder of whole vectors (scalarised, then the sequences of valhall 11b.8 and 11c.13.4), run on the interpreter
// against Swift's own integer division and the float division's 2.5 ulp bound.

import Testing
import ValhallBackend
import ValhallBridge

@Suite struct VectorDivisionTests {
  @Test func vectorDivisionAndRemainder() throws {
    let cs = try compileGLSL("vecdiv.comp")
    #expect(violations(cs) == [])
    let n = 16
    var seed: UInt32 = 4242
    func rnd() -> UInt32 {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return seed
    }
    var ua: [UInt32] = []
    var ub: [UInt32] = []
    var ia: [Int32] = []
    var ib: [Int32] = []
    var fa: [Float] = []
    var fb: [Float] = []
    for k in 0..<(4 * n) {
      ua.append(k % 5 == 0 ? UInt32.max - UInt32(k) : rnd())
      ub.append(k % 7 == 0 ? 0 : (k % 3 == 0 ? rnd() >> 20 : rnd() >> UInt32(k % 17)))
      ia.append(k % 11 == 0 ? Int32.max - Int32(k) : Int32(bitPattern: rnd()) / (k % 4 == 0 ? 1 : 3))
      ib.append(k % 13 == 0 ? 0 : (k % 2 == 0 ? Int32(bitPattern: rnd()) >> 12 : -Int32(rnd() >> 20)))
      fa.append(Float(Int32(bitPattern: rnd()) >> 8) * 0.37)
      fb.append(Float(Int32(bitPattern: rnd()) >> 10) * 0.11 + 0.5)
    }
    let out = try run(
      cs,
      [
        pack(ua), pack(ub), pack(ia.map { UInt32(bitPattern: $0) }), pack(ib.map { UInt32(bitPattern: $0) }), packF(fa), packF(fb),
        pack([UInt32](repeating: 0, count: 4 * 8 * n)),
      ])
    let r = unpack(out[6])
    for i in 0..<n {
      for c in 0..<4 {
        let k = 4 * i + c
        let d = max(ub[k], 1)
        var e = ib[k]
        if e == 0 { e = 1 }
        func word(_ s: Int) -> UInt32 { r[4 * (8 * i + s) + c] }
        #expect(word(0) == ua[k] / d, "udiv \(ua[k]) / \(d)")
        #expect(word(1) == ua[k] % d, "urem \(ua[k]) % \(d)")
        let q = ia[k].dividedReportingOverflow(by: e)
        let floorMod: Int32 = {
          if e == -1 { return 0 }
          let m = ia[k] % e
          return m != 0 && (m < 0) != (e < 0) ? m + e : m
        }()
        if !q.overflow {
          #expect(Int32(bitPattern: word(2)) == q.partialValue, "sdiv \(ia[k]) / \(e)")
          #expect(Int32(bitPattern: word(3)) == floorMod, "smod \(ia[k]) % \(e)")
        }
        let fd = Float(bitPattern: word(4))
        let fwant = fa[k] / fb[k]
        #expect(ulpDistance(fd, fwant) <= 3, "fdiv \(fa[k]) / \(fb[k]): \(fd) vs \(fwant)")
        #expect(word(5) == ua[k] / (ub[4 * i].self | 1), "vector by scalar")
        var ey = ib[4 * i + 1]
        if ey == 0 { ey = 1 }
        let qs = ia[k].dividedReportingOverflow(by: ey)
        if !qs.overflow { #expect(Int32(bitPattern: word(6)) == qs.partialValue, "signed vector by scalar") }
        #expect(ulpDistance(Float(bitPattern: word(7)), fa[k] / fb[4 * i + 3]) <= 3, "float vector by scalar")
      }
    }
  }
}
