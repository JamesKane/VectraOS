// SPDX-License-Identifier: BSD-3-Clause

// gpu-test's hardware probes (BoardProbes in the test kit): each compiles, and the contended atomics and the image stores
// run on the interpreter to what the CPU says they do, so the board's difference from it is the hardware's.

import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

@Suite struct BoardProbeShaderTests {
  @Test func everyProbeCompilesAndValidates() throws {
    var texts: [String] = [BoardProbes.contendedFloatAdd, BoardProbes.contendedHalfAdd, BoardProbes.contendedWordAdd]
    for (format, signed) in [(39, false), (29, true), (38, false), (28, true)] {
      texts.append(BoardProbes.integerImageStore(spirvFormat: format, signed: signed))
    }
    for mode in 0..<3 { texts.append(BoardProbes.imageBounds(mode: mode)) }
    for text in texts {
      let cs = try compileText(text)
      #expect(violations(cs) == [])
    }
  }

  @Test func theContendedCountersCountEveryInvocation() throws {
    // 4 workgroups of 64 on the interpreter (whose atomics are indivisible): the sums are exact.
    let f = try execute(BoardProbes.contendedFloatAdd, inputs: [zeros(1)], grid: (4, 1, 1))
    #expect(Float(bitPattern: UInt32(f.got[0][0]) | UInt32(f.got[0][1]) << 8 | UInt32(f.got[0][2]) << 16 | UInt32(f.got[0][3]) << 24) == 256)
    let h = try execute(BoardProbes.contendedHalfAdd, inputs: [zeros(1)], grid: (4, 1, 1))
    #expect(UInt32(h.got[0][0]) | UInt32(h.got[0][1]) << 8 == 256)
    let w = try execute(BoardProbes.contendedWordAdd, inputs: [zeros(1)], grid: (4, 1, 1))
    #expect(UInt32(w.got[0][0]) | UInt32(w.got[0][1]) << 8 == 256)
  }
}
