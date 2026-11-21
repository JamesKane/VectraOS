// SPDX-License-Identifier: BSD-3-Clause

// 8 and 16-bit integers in registers and storage (LegalizeNarrow, valhall 11c.3, 12a.3), on the interpreter against Swift's
// own fixed-width integers.

import Testing
import ValhallBackend
import ValhallBridge

func floorMod(_ x: Int16, _ y: Int16) -> Int16 {
  if y == -1 { return 0 }
  let r = x % y
  return r != 0 && ((r < 0) != (y < 0)) ? r + y : r
}

@Suite struct NarrowIntTests {
  @Test func int16AndInt8Operations() throws {
    let cs = try compileGLSL("int16ops.comp")
    let n = 64
    var xs: [Int16] = [0, 1, -1, 32767, -32768, 100, -100, 255, -256, 127, -128, 128, 12345, -12345, 7, -7]
    var ys: [Int16] = [0, 1, -1, -1, -1, 3, -3, 2, 5, -128, 127, 2, 7, 9, -4, 4]
    var seed: UInt32 = 99
    while xs.count < n {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      xs.append(Int16(truncatingIfNeeded: seed >> 8))
      seed = seed &* 1_664_525 &+ 1_013_904_223
      ys.append(Int16(truncatingIfNeeded: seed >> 8))
    }
    let out = try run(
      cs,
      [
        pack16(xs.map { UInt16(bitPattern: $0) }), pack16(ys.map { UInt16(bitPattern: $0) }), [UInt8](repeating: 0, count: 2 * 12 * n),
        [UInt8](repeating: 0, count: 8 * n), [UInt8](repeating: 0, count: 4 * 6 * n),
      ])
    let r = unpack16(out[2]).map { Int16(bitPattern: $0) }
    let c = out[3].map { Int8(bitPattern: $0) }
    let s = unpack(out[4]).map { Int32(bitPattern: $0) }
    for i in 0..<n {
      let x = xs[i]
      let y = ys[i]
      let ux = UInt16(bitPattern: x)
      let uy = UInt16(bitPattern: y)
      let want: [Int16] = [
        x &+ y, x &- y, x &* y, y == 0 ? 0 : (x == .min && y == -1 ? .min : x / y), y == 0 ? 0 : floorMod(x, y),
        x >> 3, Int16(bitPattern: ux >> 3), x << 2, x < y ? 1 : 0, ux < uy ? 1 : 0, max(x, y), Int16(bitPattern: min(ux, uy)),
      ]
      for k in 0..<12 { #expect(r[12 * i + k] == want[k], "elem \(i) op \(k): \(x) \(y) got \(r[12 * i + k]) want \(want[k])") }
      let p = Int8(truncatingIfNeeded: x)
      let q = Int8(truncatingIfNeeded: y)
      let wc: [Int8] = [
        p &+ q, p &* q, p >> 1, Int8(bitPattern: UInt8(bitPattern: p) >> 1), p < q ? 1 : 0,
        q == 0 ? 0 : (p == .min && q == -1 ? .min : p / q), 0 &- p, ~q,
      ]
      for k in 0..<8 { #expect(c[8 * i + k] == wc[k], "elem \(i) int8 op \(k): \(p) \(q) got \(c[8 * i + k]) want \(wc[k])") }
      let ws: [Int32] = [
        Int32(x), Int32(ux), Int32(p), Int32(UInt8(bitPattern: p)), Int32(Int64(x) >> 1), Int32(Float(x)),
      ]
      for k in 0..<6 { #expect(s[6 * i + k] == ws[k], "elem \(i) conv \(k): \(x) got \(s[6 * i + k]) want \(ws[k])") }
    }
  }
}
