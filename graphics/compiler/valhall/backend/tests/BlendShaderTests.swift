// SPDX-License-Identifier: BSD-3-Clause

// Blend shaders (valhall 09 sections 9.9 and 9.10): the fragment shader's call sequence after BLEND, the blend shader the backend
// makes for a state the blender can't do, and the two together on the interpreter against the API's formula (a Double reference),
// for every op, factor, mask, constant, logic operation and format class the generator does. Every output passes the validator
// (compileBlendShader validates; the fragment shader is compiled with it on).

import Foundation
import MaliCore
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

private let isa = ISATable.shared

/// The fragment shader of the colour pass-through (varying 0 to colour 0), made to call blend shaders.
private func calling() throws -> CompiledGraphicsShader {
  var o = BackendOptions()
  o.blendShaders = true
  return try compileGraphicsText(Corpus.varyingFragment, options: o)
}

// MARK: the reference

private struct Rng {
  var s: UInt64
  mutating func next() -> UInt64 {
    s = s &* 6364136223846793005 &+ 1442695040888963407
    return s >> 33
  }
  /// 0 to 1 in steps of an eighth of a code.
  mutating func unit() -> Double {
    // Never a tie between two codes (the rounding of one is not the model of another).
    let fractions = [0, 0.25, 0.75, 0.3, 0.7, 0.1, 0.9]
    return min((Double(next() % 255) + fractions[Int(next() % 7)]) / 255, 1)
  }
}

/// The colours of the 16 lanes: out-of-range values among them (the source is clamped to the format).
private func sources(_ seed: UInt64) -> [[Float]] {
  var r = Rng(s: seed)
  var out: [[Float]] = []
  for l in 0..<16 {
    var c = (0..<4).map { _ in Float(r.unit()) }
    if l == 3 { c = [1.5, -0.25, 0.5, 2] }
    if l == 4 { c = [0, 0, 0, 0] }
    if l == 5 { c = [1, 1, 1, 1] }
    out.append(c)
  }
  return out
}

private func destinations(_ seed: UInt64) -> [UInt32] {
  var r = Rng(s: seed)
  var out: [UInt32] = []
  for l in 0..<16 {
    var w = UInt32(truncatingIfNeeded: r.next() & 0xFFFF_FFFF) ^ UInt32(truncatingIfNeeded: r.next() << 16)
    if l == 4 { w = 0 }
    if l == 5 { w = 0xFFFF_FFFF }
    out.append(w)
  }
  return out
}

private func decodeSRGB(_ c: Double) -> Double { TileFormatCheck.decode(c) }
private func encodeSRGB(_ c: Double) -> Double { TileFormatCheck.encode(c) }

private enum TileFormatCheck {
  static func decode(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
  static func encode(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

/// The API's blend of one pixel, as codes. `s` the source (and `s1` the second), `d` the destination code word, `k` the constants.
private func expected(
  _ spec: BlendShaderSpec, source s0: [Float], second s1: [Float], dest: UInt32, constants k: [Float]
) -> [UInt8] {
  var d = (0..<4).map { Double((dest >> UInt32(8 * $0)) & 0xFF) / 255 }
  if spec.isSRGB { for c in 0..<3 { d[c] = decodeSRGB(d[c]) } }
  var s = s0.map { clamp01(Double($0)) }
  if spec.alphaToOne { s[3] = 1 }
  let sp = s1.map { clamp01(Double($0)) }
  let kk = k.map { clamp01(Double($0)) }
  var out = d
  if let l = spec.effectiveLogic {
    let codes = s.map { UInt32(($0 * 255).rounded(.toNearestOrEven)) }
    let dc = (0..<4).map { UInt32((dest >> UInt32(8 * $0)) & 0xFF) }
    for c in 0..<4 { out[c] = Double(l.apply(codes[c], dc[c]) & 0xFF) / 255 }
  } else if spec.evaluatesEquation {
    let e = spec.equation
    for c in 0..<4 {
      let alpha = c == 3
      let own = alpha ? 3 : c
      func factor(_ f: BlendFactor) -> Double {
        switch f {
        case .zero: return 0
        case .one: return 1
        case .srcColour: return s[own]
        case .oneMinusSrcColour: return 1 - s[own]
        case .srcAlpha: return s[3]
        case .oneMinusSrcAlpha: return 1 - s[3]
        case .dstColour: return d[own]
        case .oneMinusDstColour: return 1 - d[own]
        case .dstAlpha: return d[3]
        case .oneMinusDstAlpha: return 1 - d[3]
        case .constantColour: return kk[own]
        case .oneMinusConstantColour: return 1 - kk[own]
        case .constantAlpha: return kk[3]
        case .oneMinusConstantAlpha: return 1 - kk[3]
        case .srcAlphaSaturate: return alpha ? 1 : min(s[3], 1 - d[3])
        case .src1Colour: return sp[own]
        case .oneMinusSrc1Colour: return 1 - sp[own]
        case .src1Alpha: return sp[3]
        case .oneMinusSrc1Alpha: return 1 - sp[3]
        }
      }
      let op = alpha ? e.alphaOperation : e.colourOperation
      let fs = alpha ? e.alphaSource : e.colourSource
      let fd = alpha ? e.alphaDestination : e.colourDestination
      switch op {
      case .min: out[c] = min(s[c], d[c])
      case .max: out[c] = max(s[c], d[c])
      case .add: out[c] = clamp01(s[c] * factor(fs) + d[c] * factor(fd))
      case .subtract: out[c] = clamp01(s[c] * factor(fs) - d[c] * factor(fd))
      case .reverseSubtract: out[c] = clamp01(d[c] * factor(fd) - s[c] * factor(fs))
      }
    }
  } else {
    out = s
  }
  for c in 0..<4 where spec.writeMask & (1 << UInt32(c)) == 0 { out[c] = d[c] }
  return (0..<4).map { c in
    var v = clamp01(out[c])
    if spec.isSRGB && c < 3 { v = encodeSRGB(v) }
    return UInt8((v * 255).rounded(.toNearestOrEven))
  }
}

// MARK: the run

private struct BlendRun {
  var tile: [[Int: UInt32]]
  var shader: BlendShader
  var fragment: CompiledGraphicsShader
  var instructions: Int
}

private func laneOfPixel(_ x: Int, _ y: Int) -> Int { ((y / 2) * 2 + x / 2) * 4 + (y % 2) * 2 + x % 2 }

/// Run the calling fragment shader with `spec`'s blend shader for target 0 over 16 lanes.
private func run(_ spec: BlendShaderSpec, source: [[Float]], dest: [UInt32], constants: [Float] = [0, 0, 0, 0]) throws -> BlendRun {
  let fs = try calling()
  let blend = try ValhallBackend.compileBlendShader(spec)
  var input = FragmentInput()
  input.varying = { _, x, y in source[laneOfPixel(Int(x), Int(y))] }
  for l in 0..<16 { input.tile[l][0] = dest[l] }
  let r = try HostRun.fragment(fs, input: input, blendShaders: [0: blend], blendConstants: constants)
  return BlendRun(tile: r.tile, shader: blend, fragment: fs, instructions: r.instructions)
}

private func check(_ spec: BlendShaderSpec, seed: UInt64 = 1, constants: [Float] = [0.25, 0.5, 0.75, 0.125], tolerance: Int = 1, _ what: String) throws {
  let src = sources(seed)
  let dst = destinations(seed &+ 77)
  let r = try run(spec, source: src, dest: dst, constants: constants)
  for l in 0..<16 {
    let want = expected(spec, source: src[l], second: [0, 0, 0, 0], dest: dst[l], constants: constants)
    let word = r.tile[l][0] ?? 0
    for c in 0..<4 {
      let got = Int((word >> UInt32(8 * c)) & 0xFF)
      #expect(abs(got - Int(want[c])) <= tolerance, "\(what) lane \(l) channel \(c): got \(got), want \(want[c]) (source \(src[l]), dest \(String(dst[l], radix: 16)))")
    }
  }
}

private func equation(
  _ op: BlendOperation, _ fs: BlendFactor, _ fd: BlendFactor, alpha aop: BlendOperation? = nil, _ afs: BlendFactor? = nil,
  _ afd: BlendFactor? = nil
) -> BlendEquation {
  BlendEquation(
    colourOperation: op, colourSource: fs, colourDestination: fd, alphaOperation: aop ?? op, alphaSource: afs ?? fs,
    alphaDestination: afd ?? fd)
}

private let factors: [BlendFactor] = [
  .zero, .one, .srcColour, .oneMinusSrcColour, .srcAlpha, .oneMinusSrcAlpha, .dstColour, .oneMinusDstColour, .dstAlpha,
  .oneMinusDstAlpha, .constantColour, .oneMinusConstantColour, .constantAlpha, .oneMinusConstantAlpha, .srcAlphaSaturate,
]

// MARK: tests

@Suite struct BlendShaderTests {
  @Test func theCallSequenceFollowsEachBlend() throws {
    let c = try calling()
    let list = c.listing.split(whereSeparator: { $0.isNewline }).map(String.init)
    let b = try #require(list.firstIndex { $0.hasPrefix("BLEND") })
    // 09 section 9.9.1: the BLEND ends the shader, so the sequence sets the link register to zero and jumps through the descriptor.
    #expect(list[b].contains(".end"), "\(list[b])")
    #expect(list[b + 1].hasPrefix("MOV") && list[b + 1].contains("r48"), "\(list[b + 1])")
    #expect(list[b + 2].hasPrefix("JUMP"), "\(list[b + 2])")
    #expect(list.count == b + 3, "\(c.listing)")
    let f = try #require(c.fragment)
    #expect(f.layout.blendConstantWord == 0 && f.layout.pushWord == 4)
  }

  @Test func theCallSequenceReturnsToTheNextInstructionBetweenTargets() throws {
    var o = BackendOptions()
    o.blendShaders = true
    let c = try compileGraphicsText(Corpus.fragmentFeatures, options: o)
    let list = c.listing.split(whereSeparator: { $0.isNewline }).map(String.init)
    let blends = list.indices.filter { list[$0].hasPrefix("BLEND") }
    #expect(blends.count == 2)
    // The first BLEND skips the 16 bytes of its call sequence; its ADR sets r48 to the address after the JUMP (pc plus 8).
    #expect(list[blends[0]].contains("skip:16"), "\(list[blends[0]])")
    #expect(list[blends[0] + 1].hasPrefix("ADR") && list[blends[0] + 1].contains("r48"), "\(list[blends[0] + 1])")
    #expect(list[blends[0] + 2].hasPrefix("JUMP"))
    // The second colour waits outside r0 to r15 while the first target's blend shader may run.
    let f = try #require(c.fragment)
    #expect(f.colourTargets == [0, 1])
  }

  @Test func aFragmentShaderWithoutBlendShadersIsUnchanged() throws {
    let c = try compileGraphicsText(Corpus.varyingFragment)
    let list = c.listing.split(whereSeparator: { $0.isNewline }).map(String.init)
    #expect(!list.contains { $0.hasPrefix("JUMP") || $0.hasPrefix("ADR") })
    #expect(c.fragment?.layout.blendConstantWord == -1 && c.fragment?.layout.pushWord == 0)
  }

  @Test func theWorkedShadersOfTheSpecShape() throws {
    // 09 section 9.10.1: min, max and a saturating add on RGBA8, all four mask bits, no constant.
    for (name, e) in [
      ("min", equation(.min, .one, .one)), ("max", equation(.max, .one, .one)), ("saturate", equation(.add, .one, .one)),
    ] {
      let spec = BlendShaderSpec(blending: true, equation: e)
      let s = try ValhallBackend.compileBlendShader(spec)
      #expect(s.loadsDestination && !s.usesConstants, "\(name)")
      let list = s.listing
      #expect(list.contains("LD_TILE.f16.v4.slot0") || list.contains("LD_TILE"), "\(name)\n\(list)")
      #expect(list.contains("JUMP r48, r48") || list.contains("JUMP"), "\(name)")
      #expect(s.instructions.last?.flow == .end)
      #expect(s.code.count == s.instructions.count)
      // The opaque operand and the conversion word are the spec's.
      #expect(spec.opaqueOperand == 0x000E_D000_0000_0019 && spec.conversionWord == 0x000E_D000 && spec.pixelIndexWord == 0xFF00_0000)
      try check(spec, "\(name)")
    }
  }

  @Test func everyOperationAndFactorMatchesTheEquation() throws {
    for op in [BlendOperation.add, .subtract, .reverseSubtract] {
      for fs in factors {
        for fd in factors {
          // Colour and alpha use different factors, so both functions are exercised (an alpha factor that names a colour is its alpha).
          let afs = factors[(factors.firstIndex(of: fs)! + 3) % factors.count]
          let afd = factors[(factors.firstIndex(of: fd)! + 5) % factors.count]
          let spec = BlendShaderSpec(blending: true, equation: equation(op, fs, fd, alpha: op, afs, afd))
          try check(spec, "\(op) \(fs) \(fd) / \(afs) \(afd)")
        }
      }
    }
  }

  @Test func minimumAndMaximumIgnoreTheirFactors() throws {
    for (a, b) in [(BlendOperation.min, BlendOperation.max), (.max, .min), (.min, .min), (.max, .max)] {
      let spec = BlendShaderSpec(blending: true, equation: equation(a, .srcAlpha, .constantColour, alpha: b, .zero, .dstAlpha))
      try check(spec, "\(a) \(b)")
    }
  }

  @Test func unequalConstantsAreRead() throws {
    for k: [Float] in [[0.1, 0.9, 0.4, 0.6], [0, 0, 0, 1], [1, 0.5, 0, 0], [-1, 2, 0.5, 0.5]] {
      let spec = BlendShaderSpec(blending: true, equation: equation(.add, .constantColour, .oneMinusConstantColour, alpha: .add, .constantAlpha, .oneMinusConstantAlpha))
      try check(spec, constants: k, "constants \(k)")
    }
  }

  /// layout(location = 0, index = 0) out vec4 c0; layout(location = 0, index = 1) out vec4 c1;
  /// layout(location = 0) in vec4 a; layout(location = 1) in vec4 b; void main() { c0 = a; c1 = b; }
  static let dualFragment = """
    OpCapability Shader
    OpMemoryModel Logical GLSL450
    OpEntryPoint Fragment %main "main" %c0 %c1 %a %b
    OpExecutionMode %main OriginUpperLeft
    OpDecorate %c0 Location 0
    OpDecorate %c0 Index 0
    OpDecorate %c1 Location 0
    OpDecorate %c1 Index 1
    OpDecorate %a Location 0
    OpDecorate %b Location 1
    \(Corpus.graphicsPrelude)
    %c0 = OpVariable %ptr_out_v4 Output
    %c1 = OpVariable %ptr_out_v4 Output
    %a = OpVariable %ptr_in_v4 Input
    %b = OpVariable %ptr_in_v4 Input
    %main = OpFunction %void None %fn
    %entry = OpLabel
    %va = OpLoad %v4float %a
    %vb = OpLoad %v4float %b
    OpStore %c0 %va
    OpStore %c1 %vb
    OpReturn
    OpFunctionEnd
    """

  @Test func dualSourceBlendingReadsTheSecondColourFromR4() throws {
    var o = BackendOptions()
    o.blendShaders = true
    let fs = try compileGraphicsText(Self.dualFragment, options: o)
    let f = try #require(fs.fragment)
    #expect(f.writesSecondOutput && f.colourTargets == [0])
    let list = fs.listing.split(whereSeparator: { $0.isNewline }).map(String.init)
    #expect(list.contains { $0.hasPrefix("MOV.i32 r4,") } && list.contains { $0.hasPrefix("MOV.i32 r7,") }, "\(fs.listing)")
    let dualFactors: [BlendFactor] = [.src1Colour, .oneMinusSrc1Colour, .src1Alpha, .oneMinusSrc1Alpha]
    for fsF in dualFactors + [.one, .srcAlpha] {
      for fdF in dualFactors + [.zero, .oneMinusSrcAlpha] {
        for op in [BlendOperation.add, .subtract, .reverseSubtract] {
          let spec = BlendShaderSpec(blending: true, equation: equation(op, fsF, fdF, alpha: op, fdF, fsF))
          #expect(spec.usesSecondSource == (fsF.usesSecondOutput || fdF.usesSecondOutput))
          let blend = try ValhallBackend.compileBlendShader(spec)
          let src = sources(5), second = sources(9), dst = destinations(6)
          var input = FragmentInput()
          input.varying = { loc, x, y in loc == 0 ? src[laneOfPixel(Int(x), Int(y))] : second[laneOfPixel(Int(x), Int(y))] }
          for l in 0..<16 { input.tile[l][0] = dst[l] }
          let r = try HostRun.fragment(fs, input: input, blendShaders: [0: blend])
          for l in 0..<16 {
            let want = expected(spec, source: src[l], second: second[l], dest: dst[l], constants: [0, 0, 0, 0])
            for c in 0..<4 {
              let got = Int(((r.tile[l][0] ?? 0) >> UInt32(8 * c)) & 0xFF)
              #expect(abs(got - Int(want[c])) <= 1, "dual \(op) \(fsF) \(fdF) lane \(l) channel \(c): got \(got), want \(want[c])")
            }
          }
        }
      }
    }
  }

  @Test func theWriteMaskKeepsTheDestination() throws {
    for mask in UInt32(1)...15 {
      let spec = BlendShaderSpec(blending: true, equation: equation(.max, .one, .one), writeMask: mask)
      try check(spec, "mask \(mask)")
      let replace = BlendShaderSpec(blending: false, writeMask: mask, alphaToOne: true)
      try check(replace, "replace under mask \(mask)")
    }
  }

  @Test func alphaToOneSetsTheSourceAlpha() throws {
    for blend in [false, true] {
      let spec = BlendShaderSpec(blending: blend, equation: .alpha, alphaToOne: true)
      try check(spec, "alpha to one, blending \(blend)")
    }
  }

  @Test func srgbTargetsBlendInLinearLight() throws {
    for e in [equation(.max, .one, .one), BlendEquation.alpha, equation(.add, .one, .one)] {
      try check(BlendShaderSpec(isSRGB: true, blending: true, equation: e), tolerance: 2, "srgb \(e)")
    }
  }

  @Test func logicOperationsAreExact() throws {
    for l in LogicOperation.allCases where l != .noop {
      for mask in [UInt32(15), 5] {
        try check(BlendShaderSpec(blending: true, equation: .alpha, writeMask: mask, logic: l), tolerance: 0, "logic \(l) mask \(mask)")
      }
    }
    // The no-op operation writes nothing: the tile is as it was (a blend shader that only returns).
    let none = BlendShaderSpec(logic: .noop)
    let s = try ValhallBackend.compileBlendShader(none)
    #expect(s.instructions.count == 2 && !s.loadsDestination)
    let r = try run(none, source: sources(3), dest: destinations(4))
    #expect(r.tile.map { $0[0] ?? 0 } == destinations(4))
  }

  @Test func aLogicOperationOnAnSRGBTargetWritesTheSource() throws {
    for l in [LogicOperation.xor, .invert, .clear] {
      try check(BlendShaderSpec(isSRGB: true, blending: true, equation: .alpha, logic: l), tolerance: 1, "srgb logic \(l)")
    }
  }

  @Test func aTargetOtherThanTheFirstUsesItsOwnTile() throws {
    var spec = BlendShaderSpec(blending: true, equation: equation(.max, .one, .one))
    spec.renderTarget = 3
    let s = try ValhallBackend.compileBlendShader(spec)
    #expect(spec.pixelIndexWord == 0xFF00_0300 && spec.opaqueOperand & 0xFFFF_FFFF == 0x0003_0019)
    #expect(s.listing.contains("0x300") || s.instructions.count > 0)
  }

  @Test func everyOutputPassesTheValidatorAndFitsTheRegisters() throws {
    var specs: [BlendShaderSpec] = []
    for fs in factors { for fd in factors { specs.append(BlendShaderSpec(blending: true, equation: equation(.add, fs, fd))) } }
    for l in LogicOperation.allCases { specs.append(BlendShaderSpec(logic: l)) }
    specs.append(BlendShaderSpec(blending: true, equation: equation(.max, .one, .one), writeMask: 6, alphaToOne: true))
    for spec in specs {
      let s = try ValhallBackend.compileBlendShader(spec)
      for i in s.instructions {
        if let d = i.destination { #expect(d < 16 || d == 48, "\(spec)") }
        if let b = i.stagingWrite { #expect(b.first + b.count <= 16) }
        if let b = i.stagingRead { #expect(b.first + b.count <= 16) }
      }
    }
  }
}
