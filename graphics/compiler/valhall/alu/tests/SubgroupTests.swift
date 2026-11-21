// SPDX-License-Identifier: BSD-3-Clause

// Subgroup operations (valhall 13.9: WMASK and CLPER) on the interpreter's warp model, against a CPU reference over the 16 lanes.
// Open question 13.9.4: whether WMASK reports the lanes executing it or every lane launched. The lowering asks the one function
// (the active-lane mask) for the answer, and the tests run under both readings.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

@Suite struct SubgroupTests {
  static func data(_ n: Int) -> [UInt32] {
    var out: [UInt32] = []
    var seed: UInt32 = 7
    for k in 0..<n {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      out.append(k % 16 == 0 ? 0x33 : (seed >> 16) % 120 + (k % 7 == 0 ? 0 : 1))
    }
    return out
  }

  /// The reference for one warp of 16 lanes: 40 words each.
  static func reference(_ v: [UInt32], warp w: Int) -> [[UInt32]] {
    let x = Array(v[(16 * w)..<(16 * w + 16)])
    let s = x.map { Int32(bitPattern: $0) - 50 }
    var mask: UInt32 = 0
    for l in 0..<16 where x[l] & 1 != 0 { mask |= 1 << UInt32(l) }
    var out = [[UInt32]](repeating: [UInt32](repeating: 0, count: 40), count: 16)
    for l in 0..<16 {
      var r = [UInt32](repeating: 0, count: 40)
      r[0] = l == 0 ? 1 : 0
      r[1] = x.allSatisfy { $0 != 0 } ? 1 : 0
      r[2] = x.contains { $0 > 40 } ? 1 : 0
      r[3] = x.allSatisfy { $0 & 0xF0 == x[0] & 0xF0 } ? 1 : 0
      r[4] = x[5]
      r[5] = x[0]
      r[6] = mask
      r[7] = UInt32(mask.nonzeroBitCount)
      r[8] = UInt32((mask & ((2 << UInt32(l)) - 1)).nonzeroBitCount)
      r[9] = UInt32((mask & ((1 << UInt32(l)) - 1)).nonzeroBitCount)
      r[10] = mask == 0 ? UInt32.max : UInt32(mask.trailingZeroBitCount)
      r[11] = mask == 0 ? UInt32.max : UInt32(31 - mask.leadingZeroBitCount)
      r[12] = x[(l * 3) & 15]
      r[13] = x[l ^ 5]
      r[14] = l >= 3 ? x[l - 3] : 0xFFFF_FFFF  // out of range: not compared
      r[15] = l + 2 < 16 ? x[l + 2] : 0xFFFF_FFFF
      let q = l & ~3
      r[16] = x[q | 2]
      r[17] = x[l ^ 1]
      r[18] = x[l ^ 2]
      r[19] = x[l ^ 3]
      r[20] = x.reduce(0, &+)
      r[21] = x.reduce(1) { $0 &* ($1 | 1) }
      r[22] = x.min()!
      r[23] = x.max()!
      r[24] = x.reduce(UInt32.max) { $0 & ($1 | 0xF0F0) }
      r[25] = x.reduce(0) { $0 | ($1 & 0x0F0F) }
      r[26] = x.reduce(0, ^)
      r[27] = x[0...l].reduce(0, &+)
      r[28] = x[0..<l].reduce(0, &+)
      r[29] = x[0...l].reduce(1) { $0 &* ($1 | 1) }
      r[30] = x[(l & ~3)..<((l & ~3) + 4)].reduce(0, &+)
      r[31] = UInt32(bitPattern: s.min()!)
      r[32] = UInt32(bitPattern: s.max()!)
      r[33] = UInt32(bitPattern: s[0...l].min()!)
      r[34] = l == 0 ? UInt32(bitPattern: Int32.min) : UInt32(bitPattern: s[0..<l].max()!)
      r[35] = x.allSatisfy { $0 & 4 != 0 } ? 1 : 0
      r[36] = x.contains { $0 & 128 != 0 } ? 1 : 0
      r[37] = x.reduce(0) { $0 ^ (($1 & 2) != 0 ? 1 : 0) }
      r[38] = x[(l & ~7)..<((l & ~7) + 8)].max()!
      r[39] = x[(l & ~1)..<((l & ~1) + 2)].reduce(0, ^)
      out[l] = r
    }
    return out
  }

  /// A word the operation leaves undefined (shuffle up and down past the ends) is not compared.
  static let undefinedOutOfRange: Set<Int> = [14, 15]

  func runShader(wmaskLaunched: Bool) throws {
    let n = 64
    let input = SubgroupTests.data(n)
    var options = BackendOptions()
    options.ballotWithoutWMASK = wmaskLaunched
    let cs = try compileGLSL("subgroups.comp", options: options)
    #expect(violations(cs) == [])
    let out = try run(
      cs, [pack(input), pack([UInt32](repeating: 0, count: 40 * n)), pack([UInt32](repeating: 0, count: 6 * n)), pack([UInt32](repeating: 0, count: 2 * n))],
      wmaskLaunched: wmaskLaunched)
    let r = unpack(out[1])
    for w in 0..<(n / 16) {
      let want = SubgroupTests.reference(input, warp: w)
      for l in 0..<16 {
        let i = 16 * w + l
        for k in 0..<40 {
          if SubgroupTests.undefinedOutOfRange.contains(k) && want[l][k] == 0xFFFF_FFFF { continue }
          #expect(r[40 * i + k] == want[l][k], "warp \(w) lane \(l) word \(k): got \(r[40 * i + k]) want \(want[l][k])")
        }
      }
    }
    let fr = unpackF(out[2])
    let vr = unpack(out[3])
    for w in 0..<(n / 16) {
      let x = Array(input[(16 * w)..<(16 * w + 16)])
      let f = x.map { Float(Int32(bitPattern: $0) - 50) * 0.25 }
      for l in 0..<16 {
        let i = 16 * w + l
        #expect(fr[6 * i + 0] == f.reduce(0, +))
        #expect(fr[6 * i + 1] == f.min()!)
        #expect(fr[6 * i + 2] == f.max()!)
        #expect(fr[6 * i + 3] == f[0...l].reduce(0, +))
        #expect(fr[6 * i + 4] == f[0..<l].reduce(0, +))
        #expect(fr[6 * i + 5] == f[l ^ 1])
        #expect(vr[2 * i] == x.reduce(0, &+))
        #expect(vr[2 * i + 1] == x.reduce(0) { $0 &+ $1 &* 3 })
      }
    }
  }

  @Test func everyOperationWithAllLanesExecuting() throws { try runShader(wmaskLaunched: false) }
}
