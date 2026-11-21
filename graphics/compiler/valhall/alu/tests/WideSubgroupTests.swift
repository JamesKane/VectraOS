// SPDX-License-Identifier: BSD-3-Clause

// Subgroup operations on 8, 16 and 64-bit integers and on binary16 (the lowering moves every value as 32-bit words), against a
// CPU reference over one warp.

import Testing
import ValhallBackend
import ValhallBridge

@Suite struct WideSubgroupTests {
  @Test func narrowAndWideValuesThroughTheSubgroupOperations() throws {
    let cs = try compileGLSL("subgroupwide.comp")
    #expect(violations(cs) == [])
    let input = (0..<16).map { UInt32(($0 * 37 + 11) % 100) }
    let out = try run(
      cs,
      [
        pack(input), [UInt8](repeating: 0, count: 2 * 4 * 16), [UInt8](repeating: 0, count: 2 * 16), [UInt8](repeating: 0, count: 2 * 2 * 16),
        [UInt8](repeating: 0, count: 8 * 2 * 16),
      ])
    let h = unpack16(out[1]).map { Float16(bitPattern: $0) }
    let b = out[2].map { Int8(bitPattern: $0) }
    let s = unpack16(out[3]).map { Int16(bitPattern: $0) }
    let l = unpack64(out[4]).map { Int64(bitPattern: $0) }
    let fh = input.map { Float16(Float($0) * 0.5) }
    let q = input.map { Int8(truncatingIfNeeded: $0) }
    let w = input.map { Int16(truncatingIfNeeded: Int($0) * 311 - 20000) }
    let big = input.map { Int64($0) &* 4_294_967_311 &- 1 }
    for lane in 0..<16 {
      var sum: Float16 = 0
      for x in fh { sum += x }
      #expect(h[4 * lane] == sum, "half add lane \(lane): \(h[4 * lane]) vs \(sum)")
      #expect(h[4 * lane + 1] == fh[lane ^ 3])
      #expect(h[4 * lane + 2] == fh[0...lane].max()!)
      #expect(h[4 * lane + 3] == fh.min()!)
      #expect(b[2 * lane] == q.reduce(0, &+))
      #expect(b[2 * lane + 1] == q[(lane + 1) & 15])
      #expect(s[2 * lane] == w.max()!)
      #expect(s[2 * lane + 1] == w[0..<lane].reduce(0, &+))
      #expect(l[2 * lane] == big.reduce(0, &+))
      #expect(l[2 * lane + 1] == big[7])
    }
  }
}
