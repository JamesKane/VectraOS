// SPDX-License-Identifier: BSD-3-Clause

// gpu-test's probes (gpu-test(8)): when the compiled saxpy is wrong, which instruction is. Variants of
// saxpy's listing, assembled and validated on the host (generated/ProbeShaders.swift: the ISA's assembler
// reads Characters, which this program can't link), are dispatched through the same path as the compiled
// shaders over the same buffers and FAU block. Each stores one value into y and prints its first two
// words with the ones the CPU computes. The last variant is the whole listing; the compiler's own words
// are printed beside the listing's, line by line.

import GPUClient
import GPUDevice
import Sys

extension GPUTest {
  static func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }
  static func hex64(_ v: UInt64) -> String {
    var s = String(v, radix: 16)
    while s.utf8.count < 16 { s = "0" + s }
    return "0x" + s
  }

  /// The compiled saxpy's code words beside the listing's, each with the listing's line (the disassembler
  /// reads Characters, so the lines were made on the host).
  static func listCompiledSaxpy(_ saxpy: CompiledShader) {
    let text = ProbeShaders.listing
    print("gpu-test: probe: compiled saxpy code, \(saxpy.shader.code.count) words, the listing's \(text.count)")
    var differ = 0
    var k = 0
    while k < text.count || k < saxpy.shader.code.count {
      let mine = k < text.count ? text[k] : 0
      let theirs = k < saxpy.shader.code.count ? saxpy.shader.code[k] : 0
      let line = k < ProbeShaders.listingLines.count ? ProbeShaders.listingLines[k] : ""
      let same = mine == theirs
      if !same { differ += 1 }
      print("gpu-test: probe: word \(k): compiler \(hex64(theirs)) listing \(hex64(mine))\(same ? "" : " DIFFERENT")  \(line)")
      k += 1
    }
    print("gpu-test: probe: the compiler's words and the listing's differ in \(differ) of \(k)")
  }

  /// FRCP.f32 against the correctly rounded reciprocal (reported, not judged): 131072 divisors, positive, from 2^-27 to
  /// 2^27, of every mantissa the generator reaches. Says how many results are the correctly rounded one, how many are above
  /// it and how many below, and the largest distance in ulps and where.
  static func probeFRCP(_ shader: CompiledShader) {
    let n = 131_072
    var x: [UInt32] = []
    var state: UInt32 = 0x1234_5678
    for i in 0..<n {
      state ^= state << 13
      state ^= state >> 17
      state ^= state << 5
      // The first 4096 are mantissas of 1.0 and the rest random ones; exponents spread over 2^-27 to 2^27.
      let mantissa = i < 4096 ? UInt32(i) << 11 : state & 0x7F_FFFF
      let exponent = UInt32(100 + (i * 7) % 55)
      x.append(exponent << 23 | mantissa)
    }
    let workgroup = UInt32(max(shader.shader.workgroupSize.x, 1))
    let out = dispatch("probe s1-frcp-x", shader, grid: Dim3(UInt32(n) / workgroup), inputs: [x, [UInt32](repeating: 0, count: n)],
                       push: [0, UInt32(n)])
    let got = out[1]
    var equal = 0, above = 0, below = 0, worst: UInt32 = 0, worstAt = 0
    for i in 0..<n {
      let divisor = Double(Float(bitPattern: x[i]))
      let exact = Float(1.0 / divisor)
      let g = Float(bitPattern: got[i])
      if g.bitPattern == exact.bitPattern {
        equal += 1
        continue
      }
      if g > exact { above += 1 } else { below += 1 }
      let distance = g.bitPattern > exact.bitPattern ? g.bitPattern - exact.bitPattern : exact.bitPattern - g.bitPattern
      if distance > worst {
        worst = distance
        worstAt = i
      }
    }
    print("gpu-test: probe FRCP.f32 over \(n) divisors: \(equal) the correctly rounded reciprocal, \(above) above it, \(below) below it;"
      + " the worst is \(worst) ulp at x = \(hex(x[worstAt])) (got \(hex(got[worstAt])), exact \(hex(Float(1.0 / Double(Float(bitPattern: x[worstAt]))).bitPattern)))")
  }

  /// WMASK in divergent code (reported, not judged): a warp of 16 lanes of which the first eight run the shader's WMASK of a
  /// nonzero constant and store it, the others skipping (s2: to a reconverge) or ending (s3). The stored mask is 0x00ff if
  /// WMASK reports the lanes active now, 0xffff if it reports the lanes launched.
  static func probeWMASK(_ shader: CompiledShader, name: String) {
    var y = [UInt32](repeating: 0xDEAD_BEEF, count: 64)
    let x = [UInt32](repeating: 0, count: 64)
    let out = dispatch("probe \(name)", shader, grid: Dim3(1), inputs: [x, y], push: [0, 8])
    y = out[1]
    var line = ""
    for i in 0..<16 { line += " " + hex(y[i]) }
    print("gpu-test: probe \(name): lanes 0 to 15 stored:\(line)")
    var masks: [UInt32] = []
    for i in 0..<8 where !masks.contains(y[i]) { masks.append(y[i]) }
    if masks.count == 1 && masks[0] == 0xFF {
      print("gpu-test: probe \(name): WMASK reports the lanes active now (0x00ff)")
    } else if masks.count == 1 && masks[0] == 0xFFFF {
      print("gpu-test: probe \(name): WMASK reports the lanes launched (0xffff)")
    } else {
      print("gpu-test: probe \(name): WMASK reported neither 0x00ff nor 0xffff for the active lanes")
    }
  }

  /// Run the variants; returns how many printed a first word other than the expected one.
  static func probeSaxpy(_ saxpy: CompiledShader) -> Int {
    listCompiledSaxpy(saxpy)
    let a: Float = 2.5
    let n: UInt32 = 100
    var x: [UInt32] = []
    var y: [UInt32] = []
    var xf: [Float] = []
    var yf: [Float] = []
    for i in 0..<128 {
      let xv = Float(i) * 0.37 + 0.1
      let yv = 1000 - Float(i) * 1.5
      xf.append(xv)
      yf.append(yv)
      x.append(xv.bitPattern)
      y.append(yv.bitPattern)
    }
    let abits = a.bitPattern
    let mul: [UInt32] = [(a * xf[0]).bitPattern, (a * xf[1]).bitPattern]
    let sum: [UInt32] = [(xf[0] + yf[0]).bitPattern, (xf[1] + yf[1]).bitPattern]
    let full: [UInt32] = [(a * xf[0] + yf[0]).bitPattern, (a * xf[1] + yf[1]).bitPattern]
    // What each variant should store at y[0] and y[1], in the order of ProbeShaders.variants.
    let wants: [[UInt32]] = [
      [x[0], x[1]],  // a: x stored unchanged
      [abits, abits],  // b: a + 0
      [abits, abits],  // b2: IADD_IMM of a
      mul, mul, mul, mul, mul, mul,  // c, c2, d, d2, d3, e: a * x
      sum,  // f: x + y
      full,  // g: the listing
      full, full,  // h, i: the listing with the FMA's destination or wait changed
      full, full,  // j, k: the listing without its compare and branch, and without the branch
      [0xFFFF_FFFF, 0xFFFF_FFFF],  // m: the compare's result for a lane below n (all ones)
      [y[0], y[1]],  // n: y stored through the listing
      mul,  // o: a * x through the listing
      [x[0], x[1]],  // p: x through the listing
      [x[0], x[1]], [x[0], x[1]], [x[0], x[1]], [x[0], x[1]],  // q1-q4: x after each kind of wait
      [x[0], x[1]],  // q5: x after a load carrying its own wait
      full,  // r-old-listing: the old compiled saxpy, expected to fail (garbage)
    ]
    var wrong = 0
    var v = 0
    while v < ProbeShaders.variants.count {
      let variant = ProbeShaders.variants[v]
      // The hardware measurements (s1 on) are reported, not judged.
      if variant.name.utf8.starts(with: "s".utf8) {
        var probe = saxpy
        probe.shader.code = variant.words
        if variant.name.utf8.starts(with: "s1".utf8) {
          probeFRCP(probe)
        } else if variant.name.utf8.starts(with: "s2".utf8) || variant.name.utf8.starts(with: "s3".utf8) {
          probeWMASK(probe, name: variant.name)
        } else {
          probeHandAssembled(probe, name: variant.name)
        }
        v += 1
        continue
      }
      let want = wants[v]
      var probe = saxpy
      probe.shader.code = variant.words
      let out = dispatch("probe \(variant.name)", probe, grid: Dim3(2), inputs: [x, y], push: [abits, n])
      let got = out[1]
      print("gpu-test: probe \(variant.name): word0 \(hex(got[0])) word1 \(hex(got[1])) (expected \(hex(want[0])) \(hex(want[1])))")
      let differs = got[0] != want[0] || got[1] != want[1]
      if variant.expectsFailure {
        print("gpu-test: probe \(variant.name): \(differs ? "expected failure" : "unexpectedly right")")
      } else if differs {
        wrong += 1
      }
      v += 1
    }
    return wrong
  }
}
