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
