// SPDX-License-Identifier: BSD-3-Clause

// Subgroup operations in divergent code (valhall 13.9.4, 13.5), on the interpreter's warp model with lanes inactive in branches, in
// a loop whose lanes leave at different iterations, in a switch and in nested branches; under both readings of WMASK.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

@Suite struct DivergentSubgroupTests {
  /// 10 words for each lane of one warp.
  static func reference(_ x: [UInt32]) -> [[UInt32]] {
    var out = [[UInt32]](repeating: [UInt32](repeating: 0, count: 10), count: 16)
    let n = (0..<16).map { $0 % 5 }
    let breakAt: [Int] = x.map { v in
      var k = 0
      while !((Int(v) + k) % 7 == 3 || k > 9) { k += 1 }
      return k
    }
    for l in 0..<16 {
      var r = [UInt32](repeating: 0, count: 10)
      let odd = l & 1 == 1
      let arm = (0..<16).filter { ($0 & 1 == 1) == odd }
      r[0] = odd ? arm.reduce(0) { $0 &+ x[$1] } : arm.map { x[$0] }.max()!
      r[1] = odd ? 0xAAAA : 0x5555
      r[2] = l == arm[0] ? 1 : 0
      var acc: UInt32 = 0
      for k in 0..<n[l] { acc += 2 * UInt32((0..<16).filter { n[$0] > k }.count) }
      r[3] = acc
      r[4] = 0xFFFF
      if l < 8 {
        if l & 2 != 0 {
          r[5] = [2, 3, 6, 7].reduce(0) { $0 &+ x[$1] } &+ 4000
        } else {
          r[5] = [0, 1, 4, 5].map { x[$0] }.min()! + 1
        }
      }
      switch l & 3 {
      case 0: r[6] = 0x1111
      case 1: r[6] = [1, 5, 9, 13].reduce(0) { $0 &+ x[$1] }
      case 2: r[6] = x[2]
      default: r[6] = UInt32((l - 3) / 4)
      }
      r[7] = x.reduce(0, &+)
      var seen: UInt32 = 0
      for k in 0..<breakAt[l] {
        var m: UInt32 = 0
        for j in 0..<16 where breakAt[j] > k { m |= 1 << UInt32(j) }
        seen += m & 0xFF
      }
      r[8] = seen + 100_000 * UInt32(breakAt[l])
      r[9] = 0xFFFF
      out[l] = r
    }
    return out
  }

  func check(wmaskLaunched: Bool, interpreterLaunched: Bool) throws {
    var options = BackendOptions()
    options.ballotWithoutWMASK = wmaskLaunched
    let cs = try compileGLSL("divergent.comp", options: options)
    let n = 32
    let input = SubgroupTests.data(n)
    let out = try run(cs, [pack(input), pack([UInt32](repeating: 0, count: 10 * n))], wmaskLaunched: interpreterLaunched)
    let r = unpack(out[1])
    for w in 0..<(n / 16) {
      let want = DivergentSubgroupTests.reference(Array(input[(16 * w)..<(16 * w + 16)]))
      for l in 0..<16 {
        for k in 0..<10 {
          #expect(r[10 * (16 * w + l) + k] == want[l][k], "warp \(w) lane \(l) word \(k): got \(r[10 * (16 * w + l) + k]) want \(want[l][k])")
        }
      }
    }
  }

  @Test func onlyTheLanesExecutingTheCallTakePartWhenWMASKReportsThem() throws {
    try check(wmaskLaunched: false, interpreterLaunched: false)
  }

  /// The software scheme of 13.9.4 is right on hardware that reports every launched lane, and on hardware that reports the lanes
  /// executing it: the same code under both readings.
  @Test func theSoftwareSchemeIsRightUnderEitherReading() throws {
    try check(wmaskLaunched: true, interpreterLaunched: true)
    try check(wmaskLaunched: true, interpreterLaunched: false)
  }

  /// Without the scheme, a ballot on hardware that reports every launched lane sees the lanes that are not in the branch: the choice
  /// matters, which is why it is isolated and why the board has to settle it.
  @Test func trustingWMASKIsWrongIfItReportsEveryLaunchedLane() throws {
    var failed = 0
    var options = BackendOptions()
    options.ballotWithoutWMASK = false
    let cs = try compileGLSL("divergent.comp", options: options)
    let n = 32
    let input = SubgroupTests.data(n)
    let out = try run(cs, [pack(input), pack([UInt32](repeating: 0, count: 10 * n))], wmaskLaunched: true)
    let r = unpack(out[1])
    for w in 0..<(n / 16) {
      let want = DivergentSubgroupTests.reference(Array(input[(16 * w)..<(16 * w + 16)]))
      for l in 0..<16 { for k in 0..<10 where r[10 * (16 * w + l) + k] != want[l][k] { failed += 1 } }
    }
    #expect(failed > 0)
  }

  @Test func uniformOperationsUnderTheSoftwareScheme() throws {
    let input = SubgroupTests.data(64)
    var options = BackendOptions()
    options.ballotWithoutWMASK = true
    let cs = try compileGLSL("subgroups.comp", options: options)
    let out = try run(
      cs, [pack(input), pack([UInt32](repeating: 0, count: 40 * 64)), pack([UInt32](repeating: 0, count: 6 * 64)), pack([UInt32](repeating: 0, count: 2 * 64))],
      wmaskLaunched: true)
    let r = unpack(out[1])
    for w in 0..<4 {
      let want = SubgroupTests.reference(input, warp: w)
      for l in 0..<16 {
        for k in 0..<40 where !(SubgroupTests.undefinedOutOfRange.contains(k) && want[l][k] == 0xFFFF_FFFF) {
          #expect(r[40 * (16 * w + l) + k] == want[l][k], "warp \(w) lane \(l) word \(k)")
        }
      }
    }
  }
}
