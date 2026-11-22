// SPDX-License-Identifier: BSD-3-Clause

// What a blend shader computes (valhall 09 sections 9.9 and 9.10): the API's blend state for one render target of an
// 8-bit unorm or sRGB format (the tile buffer's R8G8B8A8, 9.6.2) as data, so MaliCore and the compiler agree on it without
// either needing the other. The Valhall backend turns a spec into code (graphics/compiler/valhall/backend/lib/BlendShader.swift);
// the device decides when a target needs one (graphics/core/mali PipelineMapping.swift, 9.7.1).

/// The 16 logic operations of the API, on the source `s` and the destination `d` (bitwise, per channel).
public enum LogicOperation: Equatable, Sendable, CaseIterable {
  case clear, and, andReverse, copy, andInverted, noop, xor, or, nor, equivalent, invert, orReverse, copyInverted, orInverted, nand, set

  /// The operation on bits: `s` the source, `d` the destination.
  public func apply(_ s: UInt32, _ d: UInt32) -> UInt32 {
    switch self {
    case .clear: return 0
    case .and: return s & d
    case .andReverse: return s & ~d
    case .copy: return s
    case .andInverted: return ~s & d
    case .noop: return d
    case .xor: return s ^ d
    case .or: return s | d
    case .nor: return ~(s | d)
    case .equivalent: return ~(s ^ d)
    case .invert: return ~d
    case .orReverse: return s | ~d
    case .copyInverted: return ~s
    case .orInverted: return ~s | d
    case .nand: return ~(s & d)
    case .set: return ~0
    }
  }

  /// Whether the result depends on the destination.
  public var readsDestination: Bool {
    switch self {
    case .clear, .copy, .copyInverted, .set: return false
    default: return true
    }
  }
}

/// A render target's blend as a blend shader does it. The shader reads the blend constants from the fragment draw's FAU
/// (09 section 9.9.5), so one shader serves every constant.
public struct BlendShaderSpec: Equatable, Sendable {
  public var renderTarget: Int
  public var isSRGB: Bool
  /// Blending is enabled with `equation`; otherwise the source replaces the destination (under the mask).
  public var blending: Bool
  public var equation: BlendEquation
  public var writeMask: UInt32
  /// A logic operation is enabled: blending is off for the target (09 section 9.12.1), and an sRGB target is not changed by it.
  public var logic: LogicOperation?
  public var alphaToOne: Bool

  public init(
    renderTarget: Int = 0, isSRGB: Bool = false, blending: Bool = false, equation: BlendEquation = .replace, writeMask: UInt32 = 0xF,
    logic: LogicOperation? = nil, alphaToOne: Bool = false
  ) {
    self.renderTarget = renderTarget
    self.isSRGB = isSRGB
    self.blending = blending
    self.equation = equation
    self.writeMask = writeMask & 0xF
    self.logic = logic
    self.alphaToOne = alphaToOne
  }

  /// The logic operation that has an effect: none on an sRGB target (the source is written as it is, 9.12.1).
  public var effectiveLogic: LogicOperation? { isSRGB ? nil : logic }
  /// Whether the equation is evaluated (a logic operation turns blending off).
  public var evaluatesEquation: Bool { blending && logic == nil }

  /// Whether the shader reads the second source colour (r4 to r7).
  public var usesSecondSource: Bool {
    guard evaluatesEquation else { return false }
    let e = equation
    return e.colourSource.usesSecondOutput || e.colourDestination.usesSecondOutput || e.alphaSource.usesSecondOutput
      || e.alphaDestination.usesSecondOutput
  }

  /// Whether the shader reads the blend constants.
  public var usesConstants: Bool {
    guard evaluatesEquation else { return false }
    for f in [equation.colourSource, equation.colourDestination, equation.alphaSource, equation.alphaDestination] {
      switch f {
      case .constantColour, .oneMinusConstantColour, .constantAlpha, .oneMinusConstantAlpha: return true
      default: break
      }
    }
    return false
  }

  /// Whether the result depends on the destination: the descriptor's Load Destination (09 section 9.2.2) and the tile load.
  public var readsDestination: Bool {
    if writeMask & 0xF != 0xF { return true }
    if let l = effectiveLogic { return l.readsDestination }
    if !evaluatesEquation { return false }
    let e = equation
    if e.colourOperation == .min || e.colourOperation == .max || e.alphaOperation == .min || e.alphaOperation == .max { return true }
    func dst(_ f: BlendFactor) -> Bool { f == .dstColour || f == .oneMinusDstColour || f == .dstAlpha || f == .oneMinusDstAlpha }
    return dst(e.colourSource) || dst(e.alphaSource) || e.colourSource == .srcAlphaSaturate
      || e.colourDestination != .zero || e.alphaDestination != .zero
  }

  /// The 64-bit operand of the opaque `BLEND` the shader ends with (09 section 9.10 step 6): word 2 (the mode Opaque, four
  /// components, the target) and word 3 (the memory format of the RGBA8 tile buffer, sRGB adding bit 20).
  public var opaqueOperand: UInt64 { UInt64(1 | 3 << 3 | UInt32(renderTarget & 0xF) << 16) | UInt64(conversionWord) << 32 }
  /// The tile load's conversion operand: the high word of `opaqueOperand` (12c section 12c.7.3).
  public var conversionWord: UInt32 { 237 << 12 | (isSRGB ? 1 << 20 : 0) }
  /// The tile load's pixel-index word: sample 0 in byte 0, the target in byte 1, 255 in byte 3 (12c section 12c.7.3).
  public var pixelIndexWord: UInt32 { 0xFF00_0000 | UInt32(renderTarget & 0xF) << 8 }
}
