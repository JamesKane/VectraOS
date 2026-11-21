// SPDX-License-Identifier: BSD-3-Clause

// gpu-test's probes of the G720's behaviour where the spec leaves a question open (gpu-test(8), valhallbackend(2) BUGS):
// each prints a line that says what was measured, and none of them judges it. Hand-assembled ones are variants of saxpy's
// listing (generated/ProbeShaders.swift), the others are SPIR-V the backend compiles on the device
// (generated/CompilerShaders.swift from BoardProbes in the compiler's test kit).
//
//   f  WMASK of a constant in a branch the odd lanes take (s4)
//   h  narrow loads zero extend? neighbouring lanes' narrow stores exact? (s5, s6)
//   i  binary16 subnormals under flush mode 0 (s7)
//   j  a contended compare-exchange loop: every lane adds 1 to one counter
//   c  an integer too wide for an 8 or 16-bit integer storage image: saturate or wrap
//   e  `auto32` on the signed 8 and 16-bit formats
//   d  out of bounds image loads, stores and atomics

import GPUClient
import GPUDevice
import Sys

/// A storage image the dispatch gives its shader: the backing memory's bytes at the start (the first 64 hold the plane
/// descriptor), the texels from `texelOffset`.
struct ProbeImage {
  var format: TexelFormat
  var width: Int
  var height: Int
  var initial: [UInt8]
  var texelOffset: Int
}

extension GPUTest {
  static func hex8(_ v: UInt32) -> String {
    var s = String(v, radix: 16)
    while s.utf8.count < 8 { s = "0" + s }
    return "0x" + s
  }

  // MARK: Hand-assembled variants (s4 to s7)

  static func probeHandAssembled(_ shader: CompiledShader, name: String) {
    var x = [UInt32](repeating: 0, count: 128)
    var y = [UInt32](repeating: poison, count: 128)
    let push: [UInt32] = [0, 128]
    if name.utf8.starts(with: "s4".utf8) {
      for i in 0..<128 { x[i] = UInt32(i & 1) }
      let out = dispatch("probe \(name)", shader, grid: Dim3(2), inputs: [x, y], push: push)
      var line = ""
      for i in 0..<16 { line += " " + hex(out[1][i]) }
      var odd: [UInt32] = []
      for i in 0..<128 where i & 1 == 1 && !odd.contains(out[1][i]) { odd.append(out[1][i]) }
      var even = true
      for i in 0..<128 where i & 1 == 0 && out[1][i] != poison { even = false }
      print("gpu-test: probe \(name): lanes 0 to 15 stored:\(line)")
      let verdict: String
      if odd == [0xAAAA] {
        verdict = "WMASK(1) in a branch the odd lanes take is 0xaaaa: the lanes active now"
      } else if odd == [0xFFFF] {
        verdict = "WMASK(1) in a branch the odd lanes take is 0xffff: the lanes launched"
      } else {
        var s = ""
        for v in odd { s += " " + hex(v) }
        verdict = "WMASK(1) in a branch the odd lanes take is neither 0xaaaa nor 0xffff:" + s
      }
      print("gpu-test: probe \(name): \(verdict) (the even lanes \(even ? "stored nothing" : "stored something"))")
    } else if name.utf8.starts(with: "s5".utf8) {
      for i in 0..<128 { x[i] = 0xF1F2_F383 }
      let out = dispatch("probe \(name)", shader, grid: Dim3(2), inputs: [x, y], push: push)
      let wantZero: UInt32
      let wantSign: UInt32
      // Not `switch name`: comparing Strings pulls in the Unicode tables, which this program doesn't link.
      if name.utf8.starts(with: "s5a".utf8) {
        (wantZero, wantSign) = (0x83, 0xFFFF_FF83)
      } else if name.utf8.starts(with: "s5b".utf8) {
        (wantZero, wantSign) = (0xF1, 0xFFFF_FFF1)
      } else if name.utf8.starts(with: "s5c".utf8) {
        (wantZero, wantSign) = (0xF383, 0xFFFF_F383)
      } else {
        (wantZero, wantSign) = (0xF1F2, 0xFFFF_F1F2)
      }
      var zero = 0, sign = 0, other = 0
      var firstOther: UInt32 = 0
      for i in 0..<128 {
        if out[1][i] == wantZero { zero += 1 } else if out[1][i] == wantSign { sign += 1 } else {
          if other == 0 { firstOther = out[1][i] }
          other += 1
        }
      }
      let verdict = other == 0 && sign == 0 ? "zero extends" : (other == 0 && zero == 0 ? "sign extends" : "mixed: \(zero) zero extended, \(sign) sign extended, \(other) other (the first \(hex8(firstOther)))")
      print("gpu-test: probe \(name): the register after the load is \(hex8(out[1][0])) (zero extended \(hex8(wantZero))): the load \(verdict)")
    } else if name.utf8.starts(with: "s6".utf8) {
      y = [UInt32](repeating: 0, count: 128)
      let out = dispatch("probe \(name)", shader, grid: Dim3(2), inputs: [x, y], push: push)
      var wrong = 0
      var first = ""
      let bits = name.utf8.starts(with: "s6a".utf8) ? 8 : 16
      let count = 128
      for i in 0..<count {
        let got: UInt32
        let want: UInt32
        if bits == 8 {
          got = out[1][i / 4] >> UInt32(8 * (i % 4)) & 0xFF
          want = UInt32(0x41 + i) & 0xFF
        } else {
          got = out[1][i / 2] >> UInt32(16 * (i % 2)) & 0xFFFF
          want = UInt32(0x4041 + i) & 0xFFFF
        }
        if got != want {
          wrong += 1
          if first.isEmpty { first = "element \(i) is \(hex(got)), not \(hex(want))" }
        }
      }
      print("gpu-test: probe \(name): words 0 to 3 \(hex8(out[1][0])) \(hex8(out[1][1])) \(hex8(out[1][2])) \(hex8(out[1][3])):"
        + " \(wrong == 0 ? "all \(count) \(bits)-bit stores of neighbouring lanes are exact" : "\(wrong) of \(count) \(bits)-bit stores are wrong, the first: \(first)")")
    } else {
      // s7: binary16 pairs. a: x + y. b: x * y + 0.
      let add = name.utf8.starts(with: "s7a".utf8)
      let xs: [UInt32] = add ? [0x0200_0001, 0x0400_0400] : [0x0100_0001, 0x0400_0400]
      let ys: [UInt32] = add ? [0x0100_0001, 0x8200_8200] : [0x4000_4000, 0x3800_3800]
      let wants: [UInt32] = add ? [0x0300_0002, 0x0200_0200] : [0x0200_0002, 0x0200_0200]
      for i in 0..<128 {
        x[i] = xs[i & 1]
        y[i] = ys[i & 1]
      }
      let out = dispatch("probe \(name)", shader, grid: Dim3(2), inputs: [x, y], push: push)
      var verdicts = ""
      for k in 0..<2 {
        let got = out[1][k]
        let kind = got == wants[k] ? "kept" : (got == 0 ? "flushed to zero" : "other")
        verdicts += " \(hex8(xs[k])) \(add ? "+" : "*") \(hex8(ys[k])) = \(hex8(got)) (subnormal result \(hex8(wants[k]))): \(kind);"
      }
      print("gpu-test: probe \(name):" + verdicts)
    }
  }

  // MARK: j: a contended compare-exchange loop

  static func probeContended() {
    let words = CompilerShaders.contendedWordAdd
    let halves = CompilerShaders.contendedHalfAdd
    let floats = CompilerShaders.contendedFloatAdd
    let wordShader = compile("contendedWordAdd", words).shader
    let halfShader = compile("contendedHalfAdd", halves).shader
    let floatShader = compile("contendedFloatAdd", floats).shader
    var workgroups: UInt32 = 64
    while workgroups <= 256 {
      let lanes = workgroups * 64
      var slow = false
      for (what, shader) in [("a hardware atomic add", wordShader), ("a 16-bit add (loop on the word)", halfShader),
                             ("a float add (loop on the word)", floatShader)] {
        let start = Clock.monotonic()
        let out = dispatch("contended \(what)", shader, grid: Dim3(workgroups), inputs: [[0]], push: [])
        let took = micros(Clock.monotonic() - start)
        let word = out[0][0]
        let value: String
        let exact: Bool
        if what.utf8.starts(with: "a float".utf8) {
          let f = Float(bitPattern: word)
          value = "\(Int(f))"
          exact = f == Float(lanes)
        } else if what.utf8.starts(with: "a 16".utf8) {
          value = "\(word & 0xFFFF) (the neighbouring half \(word >> 16))"
          exact = word & 0xFFFF == lanes && word >> 16 == 0
        } else {
          value = "\(word)"
          exact = word == lanes
        }
        print("gpu-test: probe contended: \(lanes) lanes of \(workgroups) workgroups each add 1 to one counter, \(what): finished,"
          + " the counter is \(value), \(exact ? "exact" : "NOT exact (\(lanes) expected)"), \(took) us for the whole dispatch (its context included)")
        if took > 1_000_000 { slow = true }
      }
      if slow { break }
      workgroups *= 4
    }
  }

  // MARK: c and e: integer storage images

  /// What an 8 or 16-bit integer storage image keeps of 32-bit values: in range ones exactly (`auto32` on the signed
  /// formats too), and out of range ones by saturating or wrapping.
  static func probeIntegerImages() {
    struct Case {
      var name: String
      var shader: [UInt32]
      var format: TexelFormat
      var bits: Int
      var signed: Bool
      var values: [UInt32]
    }
    func s(_ v: Int32) -> UInt32 { UInt32(bitPattern: v) }
    let cases = [
      Case(name: "r8ui", shader: CompilerShaders.imageStoreR8ui, format: .r8ui, bits: 8, signed: false,
           values: [0, 1, 127, 128, 255, 256, 257, 511, 0x1234, 0xFFFF, 0x1_0000, 0xFFFF_FFFF, 3, 4, 5, 6]),
      Case(name: "r8i", shader: CompilerShaders.imageStoreR8i, format: .r8i, bits: 8, signed: true,
           values: [0, 1, s(-1), 127, s(-128), 5, s(-100), 128, 255, 256, s(-129), s(-256), 1000, 0x7FFF_FFFF, s(Int32.min), s(-32768)]),
      Case(name: "r16ui", shader: CompilerShaders.imageStoreR16ui, format: .r16ui, bits: 16, signed: false,
           values: [0, 1, 255, 256, 32767, 32768, 65535, 65536, 65537, 0x1_2345, 0xFF_FFFF, 0xFFFF_FFFF, 3, 4, 5, 6]),
      Case(name: "r16i", shader: CompilerShaders.imageStoreR16i, format: .r16i, bits: 16, signed: true,
           values: [0, 1, s(-1), 32767, s(-32768), 255, s(-100), 32768, 65535, 65536, s(-32769), s(-65536), 100000, 0x7FFF_FFFF, s(Int32.min), 300]),
    ]
    for c in cases {
      let compiled = compile("imageStore \(c.name)", c.shader).shader
      var initial = [UInt8](repeating: 0xAB, count: 8192)
      for i in 0..<64 { initial[i] = 0 }
      let image = ProbeImage(format: c.format, width: 16, height: 1, initial: initial, texelOffset: 4096)
      _ = dispatch("integer image store \(c.name)", compiled, grid: Dim3(1), inputs: [c.values], push: [], image: image)
      let bytesPer = c.bits / 8
      let bytes = lastImageBytes
      var line = ""
      var inRange = 0, inRangeExact = 0, outRange = 0, saturated = 0, wrapped = 0, neither = 0
      let low: Int64 = c.signed ? -(1 << Int64(c.bits - 1)) : 0
      let high: Int64 = c.signed ? (1 << Int64(c.bits - 1)) - 1 : (1 << Int64(c.bits)) - 1
      for (k, v) in c.values.enumerated() {
        var raw: UInt32 = 0
        for b in 0..<bytesPer { raw |= UInt32(bytes[4096 + k * bytesPer + b]) << UInt32(8 * b) }
        let stored: Int64 = c.signed
          ? (c.bits == 8 ? Int64(Int8(truncatingIfNeeded: raw)) : Int64(Int16(truncatingIfNeeded: raw))) : Int64(raw)
        let value: Int64 = c.signed ? Int64(Int32(bitPattern: v)) : Int64(v)
        line += " \(value)->\(stored)"
        if value >= low && value <= high {
          inRange += 1
          if stored == value { inRangeExact += 1 }
        } else {
          outRange += 1
          let sat = value < low ? low : high
          let wrap: Int64 = c.signed
            ? (c.bits == 8 ? Int64(Int8(truncatingIfNeeded: value)) : Int64(Int16(truncatingIfNeeded: value)))
            : value & ((1 << Int64(c.bits)) - 1)
          if stored == sat && stored != wrap { saturated += 1 } else if stored == wrap && stored != sat { wrapped += 1 } else if stored == sat { saturated += 1 } else { neither += 1 }
        }
      }
      print("gpu-test: probe image store \(c.name):\(line)")
      let kind = outRange == 0 ? "" : (saturated == outRange ? "saturates" : (wrapped == outRange ? "wraps" : "mixed (\(saturated) saturated, \(wrapped) wrapped, \(neither) neither)"))
      print("gpu-test: probe image store \(c.name): \(inRangeExact) of \(inRange) values in range stored exactly"
        + (c.signed ? " (auto32 on the signed \(c.bits)-bit format)" : "") + "; the \(outRange) too wide: ST_CVT \(kind)")
    }
  }

  // MARK: d: out of bounds image accesses

  static func probeImageBounds() {
    let layout = ImageLayout(format: TexelFormat(index: 133, order: 16, bytesPerTexel: 4), kind: .linear, width: 8, height: 8)
    // R32UI: 128 + 5 (32 bits) = 133, one component.
    let rowStride = layout.levels[0].rowStride
    let texelOffset = 4096
    let pairs: [(Int32, Int32)] = [
      (3, 2), (-1, 0), (8, 0), (0, -1), (0, 8), (-100, 5), (7, 7), (9, 9), (1000, 1000), (65536, 0), (65537, 1), (0, 65536),
      (32768, 0), (0, 32768), (65535, 0), (0, 65535),
    ]
    var coords: [UInt32] = []
    for p in pairs {
      coords.append(UInt32(bitPattern: p.0))
      coords.append(UInt32(bitPattern: p.1))
    }
    var initial = [UInt8](repeating: 0xAB, count: 16384)
    for i in 0..<64 { initial[i] = 0 }
    for y in 0..<8 {
      for x in 0..<8 {
        let v = UInt32(0x100 + y * 8 + x)
        for b in 0..<4 { initial[texelOffset + y * rowStride + x * 4 + b] = UInt8(truncatingIfNeeded: v >> UInt32(8 * b)) }
      }
    }
    let image = ProbeImage(format: TexelFormat(index: 133, order: 16, bytesPerTexel: 4), width: 8, height: 8, initial: initial,
                           texelOffset: texelOffset)
    let load = compile("imageBoundsLoad", CompilerShaders.imageBoundsLoad).shader
    let store = compile("imageBoundsStore", CompilerShaders.imageBoundsStore).shader
    let atomic = compile("imageBoundsAtomic", CompilerShaders.imageBoundsAtomic).shader
    let out = [UInt32](repeating: 0x5555_5555, count: 64)
    let loaded = dispatch("image bounds load", load, grid: Dim3(1), inputs: [coords, out], push: [], image: image)
    for (k, p) in pairs.enumerated() {
      let r = loaded[1]
      print("gpu-test: probe image bounds: load (\(p.0), \(p.1)) reads \(hex8(r[4 * k])) \(hex8(r[4 * k + 1])) \(hex8(r[4 * k + 2])) \(hex8(r[4 * k + 3]))"
        + (k == 0 ? " (in bounds: texel \(hex8(0x100 + 2 * 8 + 3)))" : ""))
    }
    for (what, shader, isAtomic) in [("store", store, false), ("atomic add", atomic, true)] {
      let result = dispatch("image bounds \(what)", shader, grid: Dim3(1), inputs: [coords, out], push: [], image: image)
      let after = lastImageBytes
      var changed: [Int] = []
      for i in 64..<after.count where after[i] != initial[i] { changed.append(i - texelOffset) }
      // The one in-bounds access (3, 2) changes its texel: 4 bytes at 2 * rowStride + 12.
      let legit = 2 * rowStride + 3 * 4
      var others: [Int] = []
      for c in changed where c < legit || c >= legit + 4 { others.append(c) }
      var list = ""
      for c in others.prefix(12) { list += " \(c)" }
      var olds = ""
      if isAtomic { for k in 0..<pairs.count { olds += " \(hex8(result[1][4 * k]))" } }
      print("gpu-test: probe image bounds: \(what): \(changed.count) bytes changed in all, \(others.count) outside the in-bounds texel"
        + (others.isEmpty ? ": out of bounds accesses changed no memory" : " at (bytes from the first texel):\(list)")
        + (isAtomic ? "; the old values returned:\(olds)" : ""))
    }
  }

  /// All the probes that need no GPU state of their own, after the compiled checks.
  static func hardwareProbes() {
    probeContended()
    probeIntegerImages()
    probeImageBounds()
  }
}
