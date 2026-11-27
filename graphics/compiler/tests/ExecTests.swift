// SPDX-License-Identifier: BSD-3-Clause

// The corpus run on the IR interpreter against CPU references: as lowered,
// after the passes with vectors kept, and after the passes with vectors
// scalarised. A wrong lowering or a pass that changes meaning fails here.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderCompiler
import ShaderTestKit
import Testing

@Suite struct ExecTests {
  @Test func fill() throws {
    for (name, ir) in try variants(Corpus.fill) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 128 * 4))
      try mc.dispatch(groups: (2, 1, 1))
      let out = words(mc.storage[0]!)
      #expect(out == (0..<128).map { UInt32($0) * 3 + 1 }, "\(name)")
    }
  }

  @Test func saxpy() throws {
    for (name, ir) in try variants(Corpus.saxpy) {
      let mc = Machine(ir)
      mc.push = bytes([Float(2.5).bitPattern, 100])
      let x = (0..<128).map { Float($0) * 0.25 }
      let y = (0..<128).map { Float(1000 - $0) }
      mc.setBuffer(0, 0, bytes(x))
      mc.setBuffer(0, 1, bytes(y))
      try mc.dispatch(groups: (2, 1, 1))
      let got = floats(mc.storage[1]!)
      let want = (0..<128).map { $0 < 100 ? 2.5 * x[$0] + y[$0] : y[$0] }
      #expect(got == want, "\(name)")
    }
  }

  @Test func reduceWithSharedMemoryAndBarriers() throws {
    for (name, ir) in try variants(Corpus.reduce) {
      let mc = Machine(ir)
      let input = (0..<256).map { UInt32($0 % 7 + 1) }
      mc.setBuffer(0, 0, bytes(input))
      mc.setBuffer(0, 1, [UInt8](repeating: 0, count: 16))
      try mc.dispatch(groups: (4, 1, 1))
      let want = (0..<4).map { g in input[(g * 64)..<(g * 64 + 64)].reduce(0, +) }
      #expect(words(mc.storage[1]!) == want, "\(name)")
    }
  }

  @Test func loopWithABranch() throws {
    func ref(_ g: UInt32) -> UInt32 {
      var acc: UInt32 = 0
      var i: UInt32 = 0
      while i < g {
        if i & 1 == 0 { acc = acc &+ i } else { acc ^= i &* 3 }
        i += 1
      }
      return acc
    }
    for (name, ir) in try variants(Corpus.loopsum) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 128 * 4))
      try mc.dispatch(groups: (2, 1, 1))
      #expect(words(mc.storage[0]!) == (0..<128).map { ref(UInt32($0)) }, "\(name)")
    }
  }

  @Test func vectorsAndExtendedInstructions() throws {
    let input: [Float] = (0..<128 * 4).map { Float(($0 * 37) % 23) * 0.25 - 2.0 }
    func ref(_ i: Int) -> [Float] {
      let a = Array(input[(i * 4)..<(i * 4 + 4)])
      var d = a[0] * a[0]
      for k in 1..<4 { d = d.addingProduct(a[k], a[k]) }
      return [d.squareRoot(), Swift.min(a[0], a[1]), abs(a[2]), Swift.min(Swift.max(a[3], 0), 1)]
    }
    for (name, ir) in try variants(Corpus.vec) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, bytes(input))
      mc.setBuffer(0, 1, [UInt8](repeating: 0, count: 128 * 16))
      try mc.dispatch(groups: (2, 1, 1))
      let got = floats(mc.storage[1]!)
      var want: [Float] = []
      for i in 0..<128 { want += ref(i) }
      #expect(got == want, "\(name)")
    }
  }

  @Test func matricesAreTheirColumns() throws {
    // Small whole numbers, so that every product and sum is exact however it is fused.
    let n = 16
    let mcols: [[Float]] = (0..<4).map { c in (0..<4).map { r in Float((c * 4 + r) % 5) - 2 } }
    let input: [[Float]] = (0..<n).map { i in (0..<4).map { Float(($0 * 3 + i) % 7) - 3 } }
    func mulMV(_ cs: [[Float]], _ v: [Float]) -> [Float] { (0..<4).map { r in (0..<4).reduce(Float(0)) { $0 + cs[$1][r] * v[$1] } } }
    let mm: [[Float]] = mcols.map { mulMV(mcols, $0) }
    let mt: [[Float]] = (0..<4).map { r in (0..<4).map { c in mcols[c][r] } }
    for (name, ir) in try variants(Corpus.matrix) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, bytes([Float](repeating: 9, count: 4) + mcols.flatMap { $0 }))
      mc.setBuffer(0, 1, bytes(input.flatMap { $0 }))
      mc.setBuffer(0, 2, [UInt8](repeating: 0, count: n * 7 * 16))
      try mc.dispatch(groups: (1, 1, 1))
      let got = floats(mc.storage[2]!)
      var want: [Float] = []
      for i in 0..<n {
        let a = input[i]
        want += mulMV(mcols, a)
        want += (0..<4).map { c in (0..<4).reduce(Float(0)) { $0 + a[$1] * mcols[c][$1] } }
        want += mulMV(mm, a)
        want += mulMV(mt, a)
        want += mcols[i % 4].map { $0 * 2 }
        want += a.map { $0 * a[1] }
        want += mulMV(mm, a)
      }
      #expect(got == want, "\(name)")
    }
  }

  @Test func everyExtendedInstructionTheLoweringKnows() throws {
    let n = 64
    let x = (0..<n).map { Float($0 + 1) / 6 }
    let ln2 = Float(0.6931471805599453)
    let log2e = Float(1.4426950408889634)
    // The lowering's exp and pow carry the exponent product's rounding through (LowerMath.swift), step by step in binary32 with
    // fused multiply-adds: hi = a * b, lo = fma(a, b, -hi), e = exp2(hi), e + e * lo * ln2 (the correction only below |hi| 127).
    func expRef(_ x: Float) -> Float {
      let hi = x * log2e
      let lo = (-hi).addingProduct(x, log2e)
      let c = lo.addingProduct(x, Float(1.4426950408889634 - Double(log2e)))
      let e = exp2(hi)
      return abs(hi) < 127 ? e.addingProduct(e, c * ln2) : e
    }
    func powRef(_ x: Float, _ y: Float) -> Float {
      let l = log2(x)
      let hi = y * l
      let lo = (-hi).addingProduct(y, l)
      let e = exp2(hi)
      return abs(hi) < 127 ? e.addingProduct(e, lo * ln2) : e
    }
    func ref(_ x: Float) -> [Float] {
      let x3 = x * 3
      let t = (Float(1) - 0.25)
      _ = t
      let q = (x - 0.5) / (1.5 - 0.5)
      let st = Swift.min(Swift.max(q, 0), 1)
      return [
        x, Swift.min(x, 1), Swift.max(x, 1), Swift.min(Swift.max(x, 0.75), 1.25), x3.rounded(.down),
        x3 - x3.rounded(.down), x.squareRoot(), 1 / x.squareRoot(), exp2(x), log2(x), powRef(x, 2.5), sin(x),
        cos(x), Float(1).addingProduct(x, x), (x * (1 - 0.25)).addingProduct(2, 0.25), x < 1 ? 0 : 1,
        expRef(x), log2(x) * ln2, (st * st) * (3 - 2 * st), x3.rounded(.up), (-x3).rounded(.towardZero),
        x3.rounded(.toNearestOrEven),
      ]
    }
    for (name, ir) in try variants(Corpus.math) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, bytes(x))
      mc.setBuffer(0, 1, [UInt8](repeating: 0, count: n * 22 * 4))
      mc.setBuffer(0, 2, [UInt8](repeating: 0, count: n * 5 * 4))
      try mc.dispatch(groups: (1, 1, 1))
      let f = floats(mc.storage[1]!)
      let u = words(mc.storage[2]!)
      for i in 0..<n {
        let want = ref(x[i])
        for k in 0..<22 {
          #expect(f[i * 22 + k] == want[k], "\(name) \(Corpus.mathFloat[k].name)(\(x[i])): \(f[i * 22 + k]) != \(want[k])")
        }
        let si = Int32(i) - 5
        let wantU: [UInt32] = [
          UInt32(bitPattern: abs(si)), UInt32(bitPattern: Swift.min(si, 2)), UInt32(Swift.max(i, 7)),
          UInt32(Swift.min(Swift.max(i, 3), 9)), UInt32(bitPattern: si > 0 ? 1 : si < 0 ? -1 : 0),
        ]
        #expect(Array(u[(i * 5)..<(i * 5 + 5)]) == wantU, "\(name) \(i)")
      }
    }
  }

  @Test func atomicsAndASwitch() throws {
    for (name, ir) in try variants(Corpus.atomics) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 4 + 128 * 4))
      mc.setBuffer(0, 1, [UInt8](repeating: 0, count: 128 * 4))
      try mc.dispatch(groups: (2, 1, 1))
      let c = words(mc.storage[0]!)
      #expect(c[0] == 128, "\(name)")
      #expect(Array(c[1...]).sorted() == (0..<128).map { UInt32($0) }, "\(name)")
      #expect(words(mc.storage[1]!) == (0..<128).map { [10, 20, 30, 30][$0 & 3] }, "\(name)")
    }
  }

  @Test func specializationConstantsAndSixtyFourBitIntegers() throws {
    for (name, ir) in try variants(Corpus.spec64) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 64 * 4))
      try mc.dispatch(groups: (1, 1, 1))
      #expect(words(mc.storage[0]!) == (0..<64).map { UInt32($0) * 6 }, "\(name)")
      #expect(ir.specializations.map { $0.id }.sorted() == [0, 1], "\(name)")
    }
    // K = 9 and ZERO = true.
    let k9 = try variants(Corpus.spec64, spec: [(id: 0, bits: 9)])
    for (name, ir) in k9 {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 64 * 4))
      try mc.dispatch(groups: (1, 1, 1))
      #expect(words(mc.storage[0]!) == (0..<64).map { UInt32($0) * 10 }, "\(name)")
    }
    for (name, ir) in try variants(Corpus.spec64, spec: [(id: 1, bits: 1)]) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 7, count: 64 * 4))
      try mc.dispatch(groups: (1, 1, 1))
      #expect(words(mc.storage[0]!) == [UInt32](repeating: 0, count: 64), "\(name)")
    }
  }

  @Test func calls() throws {
    func h(_ a: UInt32, _ b: UInt32) -> UInt32 { a &* b &+ 1 }
    for (name, ir) in try variants(Corpus.calls) {
      #expect(ir.functions.count == 2, "\(name)")
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 64 * 4))
      try mc.dispatch(groups: (1, 1, 1))
      #expect(words(mc.storage[0]!) == (0..<64).map { h(h(UInt32($0), 3), UInt32($0)) }, "\(name)")
    }
  }

  @Test func localArraysAndStructs() throws {
    func ref(_ i: UInt32) -> UInt32 {
      let arr: [UInt32] = [i, i + 1, i &* 2, 7]
      return arr[Int(i & 3)] &+ arr[Int((i + 1) & 3)] &+ i &+ UInt32(Float(i) * 0.5)
    }
    for (name, ir) in try variants(Corpus.locals) {
      let mc = Machine(ir)
      mc.setBuffer(0, 0, [UInt8](repeating: 0, count: 64 * 4))
      try mc.dispatch(groups: (1, 1, 1))
      #expect(words(mc.storage[0]!) == (0..<64).map { ref(UInt32($0)) }, "\(name)")
    }
  }
}
