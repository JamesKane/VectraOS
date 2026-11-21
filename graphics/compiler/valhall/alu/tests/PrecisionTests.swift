// SPDX-License-Identifier: BSD-3-Clause

// The precision of the float functions: each run on the interpreter over a dense sweep and compared, in units in the last place,
// with the correctly rounded result computed in double precision, against Vulkan's table ("Precision and Operation of SPIR-V
// Instructions"). A function whose measured error exceeds its bound fails; the measured maxima are printed (VX_PRECISION_TABLE) for
// valhallbackend(2). The default sweep is a few thousand points a function; VX_SLOW_TESTS makes it dense.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge

struct Sweep {
  var name: String
  /// The assembler text of the operation: `OpFDiv %T` or `OpExtInst %T %glsl 31`, over the operands %x (and %y).
  var op: String
  var binary = false
  /// The inputs of sample k of n.
  var inputs: (Int, Int) -> (Double, Double)
  var reference: (Double, Double) -> Double
  /// The error allowed at an input, in units in the last place of the result, and an absolute error that is allowed instead.
  var bound: (Double, Double, Double) -> Double
  var absolute: ((Double, Double) -> Double)? = nil
}

func logUniform(_ lo: Double, _ hi: Double, _ k: Int, _ n: Int) -> Double {
  let u = (Double(k) + 0.5) / Double(n)
  return lo * pow(hi / lo, u)
}

func linear(_ lo: Double, _ hi: Double, _ k: Int, _ n: Int) -> Double { lo + (hi - lo) * (Double(k) + 0.5) / Double(n) }

/// Even samples linear over [lo, hi], odd ones log-uniform in magnitude over [tiny, hi] with the sign of the range's ends.
func mixed(_ lo: Double, _ hi: Double, tiny: Double, _ k: Int, _ n: Int) -> Double {
  if k % 2 == 0 { return linear(lo, hi, k / 2, (n + 1) / 2) }
  let m = logUniform(tiny, max(abs(lo), abs(hi)), k / 2, n / 2)
  let signed = (k / 2) % 2 == 0 || lo >= 0 ? m : -m
  return min(max(signed, lo), hi)
}

@Suite struct PrecisionTests {
  static func shader(_ s: Sweep, half: Bool) -> String {
    let ty = half ? "%half" : "%float"
    let stride = half ? 2 : 4
    return """
      OpCapability Shader
      \(half ? "OpCapability Float16\n      OpCapability StorageBuffer16BitAccess" : "")
      %glsl = OpExtInstImport "GLSL.std.450"
      OpMemoryModel Logical GLSL450
      OpEntryPoint GLCompute %main "main" %gid
      OpExecutionMode %main LocalSize 64 1 1
      OpDecorate %gid BuiltIn GlobalInvocationId
      OpDecorate %arr ArrayStride \(stride)
      OpMemberDecorate %A 0 Offset 0
      OpDecorate %A Block
      OpDecorate %xv DescriptorSet 0
      OpDecorate %xv Binding 0
      OpDecorate %yv DescriptorSet 0
      OpDecorate %yv Binding 1
      OpDecorate %rv DescriptorSet 0
      OpDecorate %rv Binding 2
      \(Corpus.prelude)
      %gid = OpVariable %ptr_in_v3uint Input
      \(half ? "%half = OpTypeFloat 16" : "")
      %arr = OpTypeRuntimeArray \(ty)
      %A = OpTypeStruct %arr
      %ptr_A = OpTypePointer StorageBuffer %A
      %ptr_el = OpTypePointer StorageBuffer \(ty)
      %xv = OpVariable %ptr_A StorageBuffer
      %yv = OpVariable %ptr_A StorageBuffer
      %rv = OpVariable %ptr_A StorageBuffer
      %main = OpFunction %void None %fn
      %entry = OpLabel
      %gp = OpAccessChain %ptr_in_uint %gid %u0
      %i = OpLoad %uint %gp
      %px = OpAccessChain %ptr_el %xv %u0 %i
      %py = OpAccessChain %ptr_el %yv %u0 %i
      %pr = OpAccessChain %ptr_el %rv %u0 %i
      %x = OpLoad \(ty) %px
      %y = OpLoad \(ty) %py
      %r = \(s.op.replacingOccurrences(of: "%T", with: ty)) %x\(s.binary ? " %y" : "")
      OpStore %pr %r
      OpReturn
      OpFunctionEnd
      """
  }

  struct Result {
    var maxUlp = 0.0
    var at = (0.0, 0.0)
    var maxAbs = 0.0
    var worstRatio = 0.0
    var count = 0
  }

  static func measure(_ s: Sweep, points n: Int) throws -> Result {
    let cs = try compileText(shader(s, half: false))
    let groups = (n + 63) / 64
    let total = groups * 64
    var xs: [Float] = []
    var ys: [Float] = []
    for k in 0..<total {
      let (x, y) = s.inputs(k, total)
      xs.append(Float(x))
      ys.append(Float(y))
    }
    var res = Result()
    var got: [Float] = []
    // Dispatch in slices so a grid stays small.
    let slice = 64 * 16
    var base = 0
    while base < total {
      let m = min(slice, total - base)
      let out = try run(cs, [packF(Array(xs[base..<(base + m)])), packF(Array(ys[base..<(base + m)])), packF([Float](repeating: 0, count: m))], groups: m / 64)
      got += unpackF(out[2])
      base += m
    }
    for k in 0..<total {
      let x = Double(xs[k])
      let y = Double(ys[k])
      let exact = s.reference(x, y)
      let want = Float(exact)
      guard exact.isFinite, abs(exact) >= 1.2e-38 || exact == 0, abs(exact) < 3.0e38 else { continue }
      let g = got[k]
      if g.isNaN || g.isInfinite {
        if res.worstRatio < 1e9 { res.worstRatio = 1e9; res.at = (x, y); res.maxUlp = .infinity }
        continue
      }
      let err = abs(Double(g) - exact)
      let ulp = Double(want.ulp)
      let inUlps = ulp > 0 ? err / ulp : err
      let allowed = s.bound(x, y, exact)
      var ratio = inUlps / allowed
      if let a = s.absolute, err <= a(x, y) { ratio = min(ratio, 0) }
      res.count += 1
      if err > res.maxAbs { res.maxAbs = err }
      if inUlps > res.maxUlp && ratio > 0 { res.maxUlp = inUlps }
      if ratio > res.worstRatio {
        res.worstRatio = ratio
        res.at = (x, y)
      }
    }
    return res
  }

  static let pi = Double.pi

  static var sweeps: [Sweep] {
    let u4 = 1.0 / 16777216
    func bound(_ k: Double) -> (Double, Double, Double) -> Double { { _, _, _ in k } }
    let big = 1e19
    var s: [Sweep] = []
    s.append(
      Sweep(
        name: "fdiv", op: "OpFDiv %T", binary: true,
        inputs: { k, n in (mixed(-1000, 1000, tiny: 1e-20, k, n), logUniform(1e-30, 1e30, (k * 7919) % n, n)) },
        reference: { $0 / $1 }, bound: bound(2.5)))
    s.append(
      Sweep(
        name: "sqrt", op: "OpExtInst %T %glsl 31", inputs: { k, n in (logUniform(1e-30, 1e30, k, n), 0) },
        reference: { x, _ in sqrt(x) }, bound: bound(4.5)))
    s.append(
      Sweep(
        name: "inversesqrt", op: "OpExtInst %T %glsl 32", inputs: { k, n in (logUniform(1e-30, 1e30, k, n), 0) },
        reference: { x, _ in 1 / sqrt(x) }, bound: bound(2)))
    s.append(
      Sweep(
        name: "exp", op: "OpExtInst %T %glsl 27", inputs: { k, n in (mixed(-87, 88, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in exp(x) }, bound: { x, _, _ in 3 + 2 * abs(x).rounded(.down) }))
    s.append(
      Sweep(
        name: "exp2", op: "OpExtInst %T %glsl 29", inputs: { k, n in (mixed(-125, 127, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in exp2(x) }, bound: { x, _, _ in 3 + 2 * abs(x).rounded(.down) }))
    s.append(
      Sweep(
        name: "log", op: "OpExtInst %T %glsl 28", inputs: { k, n in (k % 2 == 0 ? logUniform(1e-30, 1e30, k, n) : linear(0.5, 2, k, n), 0) },
        reference: { x, _ in log(x) }, bound: bound(3), absolute: { x, _ in x >= 0.5 && x <= 2 ? pow(2, -21) : 0 }))
    s.append(
      Sweep(
        name: "log2", op: "OpExtInst %T %glsl 30", inputs: { k, n in (k % 2 == 0 ? logUniform(1e-30, 1e30, k, n) : linear(0.5, 2, k, n), 0) },
        reference: { x, _ in log2(x) }, bound: bound(3), absolute: { x, _ in x >= 0.5 && x <= 2 ? pow(2, -21) : 0 }))
    s.append(
      Sweep(
        name: "pow", op: "OpExtInst %T %glsl 26", binary: true,
        inputs: { k, n in (logUniform(0.01, 100, k, n), linear(-8, 8, (k * 7919) % n, n)) },
        reference: { pow($0, $1) },
        bound: { x, y, _ in
          // exp2(y log2 x): the exponential's 3 + 2|z| plus the logarithm's error carried through the product.
          let l = log2(x)
          let z = y * l
          let delta = max(pow(2, -21), 3 * abs(l) * u4)
          return 3 + 2 * abs(z).rounded(.down) + log(2) * abs(y) * delta / u4 + 1
        }))
    s.append(
      Sweep(
        name: "sin", op: "OpExtInst %T %glsl 13", inputs: { k, n in (mixed(-pi, pi, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in sin(x) }, bound: bound(.infinity), absolute: nil))
    s.append(
      Sweep(
        name: "cos", op: "OpExtInst %T %glsl 14", inputs: { k, n in (mixed(-pi, pi, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in cos(x) }, bound: bound(.infinity), absolute: nil))
    s.append(
      Sweep(
        name: "tan", op: "OpExtInst %T %glsl 15", inputs: { k, n in (mixed(-1.5, 1.5, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in tan(x) },
        bound: { x, _, _ in 2.5 + pow(2, -11) / abs(sin(x)) / u4 + pow(2, -11) / abs(cos(x)) / u4 }))
    s.append(
      Sweep(
        name: "asin", op: "OpExtInst %T %glsl 16", inputs: { k, n in (mixed(-1, 1, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in asin(x) }, bound: bound(4096)))
    s.append(
      Sweep(
        name: "acos", op: "OpExtInst %T %glsl 17", inputs: { k, n in (mixed(-1, 1, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in acos(x) }, bound: bound(4096)))
    s.append(
      Sweep(
        name: "atan", op: "OpExtInst %T %glsl 18", inputs: { k, n in (mixed(-big, big, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in atan(x) }, bound: bound(4096)))
    s.append(
      Sweep(
        name: "atan2", op: "OpExtInst %T %glsl 25", binary: true,
        inputs: { k, n in (mixed(-100, 100, tiny: 1e-6, k, n), mixed(-100, 100, tiny: 1e-6, (k * 7919) % n, n)) },
        reference: { atan2($0, $1) }, bound: bound(4096 + 2.5)))
    s.append(
      Sweep(
        name: "sinh", op: "OpExtInst %T %glsl 19", inputs: { k, n in (mixed(-88, 88, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in sinh(x) }, bound: { x, _, _ in (3 + 2 * abs(x)) * cosh(abs(x)) / sinh(abs(x)) + 2 }))
    s.append(
      Sweep(
        name: "cosh", op: "OpExtInst %T %glsl 20", inputs: { k, n in (mixed(-88, 88, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in cosh(x) }, bound: { x, _, _ in 3 + 2 * abs(x) + 2 }))
    s.append(
      Sweep(
        name: "tanh", op: "OpExtInst %T %glsl 21", inputs: { k, n in (mixed(-20, 20, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in tanh(x) },
        bound: { x, _, _ in (3 + 2 * abs(x)) * cosh(abs(x)) / sinh(abs(x)) + 2 + 3 + 2 * abs(x) + 2 + 2.5 }))
    s.append(
      Sweep(
        name: "asinh", op: "OpExtInst %T %glsl 22", inputs: { k, n in (mixed(-1000, 1000, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in asinh(x) }, bound: { _, _, r in max(3, 4 / abs(r)) + 6 }))
    s.append(
      Sweep(
        name: "acosh", op: "OpExtInst %T %glsl 23", inputs: { k, n in (1 + mixed(0, 1000, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in acosh(x) }, bound: { _, _, r in max(3, 4 / abs(r)) + 6 }))
    s.append(
      Sweep(
        name: "atanh", op: "OpExtInst %T %glsl 24", inputs: { k, n in (mixed(-0.999, 0.999, tiny: 1e-6, k, n), 0) },
        reference: { x, _ in atanh(x) }, bound: { _, _, r in max(3, 4 / abs(r)) + 6 }))
    return s
  }

  @Test func float32FunctionsMeetVulkansTable() throws {
    let n = slowTests ? 262_144 : 1024
    var table = ""
    for s in PrecisionTests.sweeps {
      let r = try PrecisionTests.measure(s, points: n)
      table += "\(s.name) max \(r.maxUlp) ulp, max abs \(r.maxAbs), worst at \(r.at), ratio \(r.worstRatio), samples \(r.count)\n"
      #expect(r.worstRatio <= 1.0, "\(s.name): \(r.maxUlp) ulp at \(r.at) (ratio \(r.worstRatio) of the bound)")
    }
    if getenv("VX_PRECISION_TABLE") != nil { print(table) }
  }

  /// sin and cos: Vulkan asks for an absolute error of 2^-11 on -pi to pi; the sequence of 11c.13.11, with pi/2 in two parts, is good to 2^-14 up to about
  /// 411000 radians.
  @Test func sineAndCosineAbsoluteError() throws {
    let n = slowTests ? 262_144 : 1024
    for (name, op, f) in [("sin", 13, { sin($0) }), ("cos", 14, { cos($0) })] as [(String, Int, (Double) -> Double)] {
      for (range, limit) in [(Double.pi, 0.00048828125), (400_000.0, 0.00006103515625)] as [(Double, Double)] {
        let s = Sweep(
          name: name, op: "OpExtInst %T %glsl \(op)", inputs: { k, n in (mixed(-range, range, tiny: 1e-6, k, n), 0) },
          reference: { x, _ in f(x) }, bound: { _, _, _ in .infinity })
        let r = try PrecisionTests.measure(s, points: n)
        #expect(r.maxAbs <= limit, "\(name) over \(range): \(r.maxAbs)")
        if getenv("VX_PRECISION_TABLE") != nil { print("\(name) |x| < \(range): max abs \(r.maxAbs)") }
      }
    }
  }
}
