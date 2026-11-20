// SPDX-License-Identifier: BSD-3-Clause

// Test support: hand-assembling small shaders over the interpreter's
// representation, and running them over one warp.

import Testing

import ValhallInterp

/// `op` with its sources; modifiers go on with `.with(\.field, value)`.
func I(
  _ op: Opcode, _ t: DataType? = nil, d: Int = 0, _ a: Operand? = nil, _ b: Operand? = nil, _ c: Operand? = nil,
  _ e: Operand? = nil
) -> Instr {
  var i = Instr(op, t).sources(a, b, c, e)
  i.dst = UInt8(d)
  return i
}

func r(_ n: Int) -> Operand { .r(n) }

extension Instr {
  func flow(_ f: Flow) -> Instr { with(\.flow, f) }
  func w(_ width: UInt8) -> Instr { with(\.dstWidth, width) }
}

let end = Instr(.nop).with(\.flow, .end)

struct Out {
  var regs: [UInt32]
  var report: RunReport
  /// Register `reg` of lane `lane`.
  subscript(reg: Int, lane: Int) -> UInt32 { regs[lane * 64 + reg] }
  /// Register `reg` of every lane.
  func all(_ reg: Int) -> [UInt32] { (0..<16).map { self[reg, $0] } }
}

/// Runs `code` (an `end` is appended) over one warp of 16 invocations. `inputs[reg]` gives lane `i`'s value
/// of that register as element `i % count`.
func run(
  _ code: [Instr], inputs: [Int: [UInt32]] = [:], fau: [UInt32] = [], ftz: Bool = false, strict: Bool = true,
  memory: GpuMemory = GpuMemory(), helper: UInt16 = 0, tlsBytes: Int = 0, sharedBytes: Int = 0
) throws -> Out {
  var cfg = DispatchConfig(workgroupSize: Dim3(16), grid: Dim3(1), fau: fau)
  cfg.flushDenormals = ftz
  cfg.strictLastUse = strict
  cfg.captureFirstWarp = true
  cfg.helperMask = helper
  cfg.threadLocalBytes = tlsBytes
  cfg.sharedBytes = sharedBytes
  cfg.registerInit = { lane, regs in
    for (reg, vals) in inputs { regs[reg] = vals[lane % vals.count] }
  }
  let report = try runDispatch(Shader(code + [end]), cfg, memory: memory)
  return Out(regs: report.firstWarpRegisters, report: report)
}

func fb(_ x: Float) -> UInt32 { x.bitPattern }
func bf(_ x: UInt32) -> Float { Float(bitPattern: x) }

/// A float result matches: equal bits, or both NaN.
func sameFloat(_ a: UInt32, _ b: UInt32) -> Bool {
  (bf(a).isNaN && bf(b).isNaN) || a == b
}

/// An independent binary16 decoder (formula, not the interpreter's).
func halfToFloat(_ h: UInt16) -> Float {
  let s: Float = h & 0x8000 != 0 ? -1 : 1
  let e = Int((h >> 10) & 0x1F)
  let m = Float(h & 0x3FF)
  if e == 0x1F { return m == 0 ? s * .infinity : .nan }
  if e == 0 { return s * m * Float(sign: .plus, exponent: -24, significand: 1) }
  return s * (1 + m / 1024) * Float(sign: .plus, exponent: e - 15, significand: 1)
}

/// A deterministic stream of 32-bit patterns.
struct Lcg {
  var s: UInt64
  mutating func next() -> UInt32 {
    s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return UInt32(truncatingIfNeeded: s >> 32)
  }
}

/// Interesting binary32 patterns: specials, boundaries, then random.
func floatCorpus(_ n: Int, seed: UInt64 = 1) -> [UInt32] {
  var v: [UInt32] = [
    0, 0x8000_0000, 1, 0x8000_0001, 0x007F_FFFF, 0x0080_0000, 0x3F80_0000, 0xBF80_0000, 0x3F80_0001, 0x7F7F_FFFF,
    0xFF7F_FFFF, 0x7F80_0000, 0xFF80_0000, 0x7FC0_0000, 0x7F80_0001, 0x4B00_0000, 0x3400_0000, 0x3F00_0000,
  ]
  var g = Lcg(s: seed)
  while v.count < n {
    let x = g.next()
    // Bias toward moderate exponents so sums and products stay interesting.
    v.append(g.next() & 1 == 0 ? x : (x & 0x807F_FFFF) | (0x3000_0000 + (x >> 8 & 0x0FFF_FFFF) & 0x7F80_0000))
  }
  return v
}
