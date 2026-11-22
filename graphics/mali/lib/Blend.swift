// SPDX-License-Identifier: BSD-3-Clause

// Blend (valhall 09): the API's equation to a fixed-function blend descriptor, and the decision of 9.7.1 for one
// render target of an 8-bit unorm or sRGB format (the tile buffer's R8G8B8A8, 9.6.2). The hardware has one
// multiplier, so an equation is `A + B * C` (9.4.1); `BlendEquationEncoder` finds the rearrangement (9.4.2).
// Blend shaders are not implemented: what needs one (a logic operation, alpha-to-one, minimum and maximum, the
// saturated source alpha, a constant that is not the same in the channels it names, a target whose constant
// differs from the first fixed-function target's) is refused with `BlendRefusal.needsBlendShader`, which says why.
// The descriptor array position must equal the render target (9.2.3).

public enum BlendOperation: Equatable, Sendable {
  case add, subtract, reverseSubtract, min, max
}

public enum BlendFactor: Equatable, Sendable {
  case zero, one
  case srcColour, oneMinusSrcColour, srcAlpha, oneMinusSrcAlpha
  case dstColour, oneMinusDstColour, dstAlpha, oneMinusDstAlpha
  case constantColour, oneMinusConstantColour, constantAlpha, oneMinusConstantAlpha
  case srcAlphaSaturate
  /// The fragment shader's second output (dual-source blending): a blend shader reads it from r4 to r7 (09 section 9.9.2).
  case src1Colour, oneMinusSrc1Colour, src1Alpha, oneMinusSrc1Alpha

  public var usesSecondOutput: Bool {
    self == .src1Colour || self == .oneMinusSrc1Colour || self == .src1Alpha || self == .oneMinusSrc1Alpha
  }
}

/// An API blend equation: an operation and the two factors, for the colour channels and for alpha.
public struct BlendEquation: Equatable, Sendable {
  public var colourOperation: BlendOperation
  public var colourSource: BlendFactor
  public var colourDestination: BlendFactor
  public var alphaOperation: BlendOperation
  public var alphaSource: BlendFactor
  public var alphaDestination: BlendFactor

  public init(
    colourOperation: BlendOperation = .add, colourSource: BlendFactor, colourDestination: BlendFactor,
    alphaOperation: BlendOperation = .add, alphaSource: BlendFactor, alphaDestination: BlendFactor
  ) {
    self.colourOperation = colourOperation
    self.colourSource = colourSource
    self.colourDestination = colourDestination
    self.alphaOperation = alphaOperation
    self.alphaSource = alphaSource
    self.alphaDestination = alphaDestination
  }

  /// Straight alpha: colour `S * Sa + D * (1 - Sa)`, alpha `S + D * (1 - Sa)` (09 example 2).
  public static let alpha = BlendEquation(
    colourSource: .srcAlpha, colourDestination: .oneMinusSrcAlpha, alphaSource: .one, alphaDestination: .oneMinusSrcAlpha)
  /// Premultiplied alpha: `S + D * (1 - Sa)` in every channel.
  public static let premultiplied = BlendEquation(
    colourSource: .one, colourDestination: .oneMinusSrcAlpha, alphaSource: .one, alphaDestination: .oneMinusSrcAlpha)
  /// No blending: the source replaces the destination.
  public static let replace = BlendEquation(
    colourSource: .one, colourDestination: .zero, alphaSource: .one, alphaDestination: .zero)
}

/// A render target's blend state, as an API gives it.
public struct BlendState: Equatable, Sendable {
  public var enabled: Bool
  public var equation: BlendEquation
  /// The channels written, bit 0 red to bit 3 alpha.
  public var writeMask: UInt32
  /// The constant (red, green, blue, alpha), for the factors that name it.
  public var constant: [Float]
  /// A logic operation is enabled, or alpha-to-one: the blender has neither, so a blend shader does them (09 section 9.7.1).
  public var logicOp: LogicOperation?
  public var alphaToOne: Bool
  public var logicOperation: Bool { logicOp != nil }

  public init(
    enabled: Bool, equation: BlendEquation = .alpha, writeMask: UInt32 = 0xF, constant: [Float] = [0, 0, 0, 0],
    logicOperation: Bool = false, alphaToOne: Bool = false, logicOp: LogicOperation? = nil
  ) {
    self.enabled = enabled
    self.equation = equation
    self.writeMask = writeMask
    self.constant = constant
    self.logicOp = logicOp ?? (logicOperation ? .copy : nil)
    self.alphaToOne = alphaToOne
  }

  public static let disabled = BlendState(enabled: false)
}

public enum BlendRefusal: Error, Equatable, Sendable {
  /// The state needs a blend shader (09 section 9.7.1), which this driver does not make; the text says which row.
  case needsBlendShader(String)
}

/// What a render target's descriptor does (09 section 9.1).
public enum BlendMode: Equatable, Sendable {
  case off
  case opaque
  case fixedFunction
  /// A blend shader does the blend (09 section 9.9): `BlendShaderSpec` says what it computes.
  case shader
}

/// The equation word's two functions, the constant and whether the destination is read (09 sections 9.2.2, 9.4).
public struct FixedFunctionBlend: Equatable, Sendable {
  /// The 12-bit colour function (word 1 `[11:0]`) and alpha function (`[23:12]`).
  public var colourFunction: UInt32
  public var alphaFunction: UInt32
  public var writeMask: UInt32
  /// The 16-bit blend constant (word 0 `[31:16]`).
  public var constant: UInt32
  public var loadDestination: Bool

  /// The replace equation (A Src, B Src, C Zero), 09 section 9.4.4.
  public static let replaceFunction: UInt32 = 2 | 2 << 4 | 1 << 8
}

public enum BlendEquationEncoder {
  // The function's fields (09 section 9.4.1).
  static let aZero: UInt32 = 1, aSrc: UInt32 = 2, aDest: UInt32 = 3
  static let bSrcMinusDest: UInt32 = 0, bSrcPlusDest: UInt32 = 1, bSrc: UInt32 = 2, bDest: UInt32 = 3
  static let cZero: UInt32 = 1, cSrc: UInt32 = 2, cDest: UInt32 = 3, cSrcTimes2: UInt32 = 4, cSrcAlpha: UInt32 = 5
  static let cDestAlpha: UInt32 = 6, cConstant: UInt32 = 7

  static func function(a: UInt32, negateA: Bool, b: UInt32, negateB: Bool, c: UInt32, invertC: Bool) -> UInt32 {
    a | (negateA ? 1 << 3 : 0) | b << 4 | (negateB ? 1 << 7 : 0) | c << 8 | (invertC ? 1 << 11 : 0)
  }

  /// A factor as a C operand (09 section 9.4.2): the operand and whether it is inverted; nil for the saturated
  /// source alpha. In the alpha function a colour factor is its alpha variant first.
  static func operand(_ f: BlendFactor, alpha: Bool) -> (c: UInt32, invert: Bool)? {
    var f = f
    if alpha {
      switch f {
      case .srcColour: f = .srcAlpha
      case .oneMinusSrcColour: f = .oneMinusSrcAlpha
      case .dstColour: f = .dstAlpha
      case .oneMinusDstColour: f = .oneMinusDstAlpha
      case .constantColour: f = .constantAlpha
      case .oneMinusConstantColour: f = .oneMinusConstantAlpha
      default: break
      }
    }
    switch f {
    case .zero: return (cZero, false)
    case .one: return (cZero, true)
    case .srcColour: return (cSrc, false)
    case .oneMinusSrcColour: return (cSrc, true)
    case .srcAlpha: return (cSrcAlpha, false)
    case .oneMinusSrcAlpha: return (cSrcAlpha, true)
    case .dstColour: return (cDest, false)
    case .oneMinusDstColour: return (cDest, true)
    case .dstAlpha: return (cDestAlpha, false)
    case .oneMinusDstAlpha: return (cDestAlpha, true)
    case .constantColour, .constantAlpha: return (cConstant, false)
    case .oneMinusConstantColour, .oneMinusConstantAlpha: return (cConstant, true)
    case .srcAlphaSaturate, .src1Colour, .oneMinusSrc1Colour, .src1Alpha, .oneMinusSrc1Alpha: return nil
    }
  }

  /// The 12-bit function of one equation (09 section 9.4.2's seven rearrangements, in its order), or nil when the
  /// hardware's single multiplier cannot do it: a minimum, a maximum or the saturated source alpha.
  public static func encode(
    operation op: BlendOperation, source fs: BlendFactor, destination fd: BlendFactor, alpha: Bool
  ) -> UInt32? {
    guard op == .add || op == .subtract || op == .reverseSubtract else { return nil }
    guard let s = operand(fs, alpha: alpha), let d = operand(fd, alpha: alpha) else { return nil }
    let sub = op == .subtract
    let rsub = op == .reverseSubtract
    let zero = (c: cZero, invert: false)
    let one = (c: cZero, invert: true)
    func same(_ x: (c: UInt32, invert: Bool), _ y: (c: UInt32, invert: Bool)) -> Bool { x.c == y.c && x.invert == y.invert }

    // 1: fs = ZERO.
    if same(s, zero) {
      return function(a: aZero, negateA: false, b: bDest, negateB: sub, c: d.c, invertC: d.invert)
    }
    // 2: fs = ONE.
    if same(s, one) {
      return function(a: aSrc, negateA: rsub, b: bDest, negateB: sub, c: d.c, invertC: d.invert)
    }
    // 3: fd = ZERO.
    if same(d, zero) {
      return function(a: aZero, negateA: false, b: bSrc, negateB: rsub, c: s.c, invertC: s.invert)
    }
    // 4: fd = ONE.
    if same(d, one) {
      return function(a: aDest, negateA: sub, b: bSrc, negateB: rsub, c: s.c, invertC: s.invert)
    }
    // 5: the same factor, the same inversion.
    if same(s, d) {
      return function(
        a: aZero, negateA: false, b: op == .add ? bSrcPlusDest : bSrcMinusDest, negateB: rsub, c: s.c, invertC: s.invert)
    }
    // 6: add, fs the destination (alpha: its alpha), fd the source (alpha): twice source times destination.
    if op == .add {
      let fsDest = alpha ? fs == .dstAlpha || fs == .dstColour : fs == .dstColour
      let fdSrc = alpha ? fd == .srcAlpha || fd == .srcColour : fd == .srcColour
      if fsDest && fdSrc {
        return function(a: aZero, negateA: false, b: bDest, negateB: false, c: cSrcTimes2, invertC: false)
      }
    }
    // 7: the same base factor, one inverted and one not.
    if s.c == d.c && s.invert != d.invert {
      if op == .add {
        return function(a: aDest, negateA: false, b: bSrcMinusDest, negateB: false, c: s.c, invertC: s.invert)
      }
      if rsub {
        return function(a: aDest, negateA: false, b: bSrcPlusDest, negateB: true, c: s.c, invertC: s.invert)
      }
      return function(a: aDest, negateA: true, b: bSrcPlusDest, negateB: false, c: s.c, invertC: s.invert)
    }
    return nil
  }

  static func usesConstantColour(_ f: BlendFactor) -> Bool { f == .constantColour || f == .oneMinusConstantColour }
  static func usesConstantAlpha(_ f: BlendFactor) -> Bool { f == .constantAlpha || f == .oneMinusConstantAlpha }
  static func readsDestination(_ f: BlendFactor) -> Bool {
    f == .dstColour || f == .oneMinusDstColour || f == .dstAlpha || f == .oneMinusDstAlpha
  }

  /// The 16-bit constant of a value in `[0, 1]` for an 8-bit target: `trunc(k * 65280)` (09 section 9.4.5).
  public static func constantWord(_ k: Float) -> UInt32 {
    let c = min(max(k, 0), 1)
    return UInt32(c * 65280)
  }

  /// The decision of 09 section 9.7.1 for one 8-bit unorm or sRGB target. `firstConstant` is the constant an earlier
  /// fixed-function target of the draw used (the hardware reads one), or nil.
  public static func plan(_ state: BlendState, firstConstant: UInt32? = nil) throws(BlendRefusal)
    -> (mode: BlendMode, blend: FixedFunctionBlend)
  {
    let off = FixedFunctionBlend(colourFunction: 0, alphaFunction: 0, writeMask: 0, constant: 0, loadDestination: false)
    // Row 1: nothing to write.
    if state.writeMask & 0xF == 0 { return (.off, off) }
    // Rows 2 and 3.
    if state.logicOperation { throw .needsBlendShader("a logic operation (09 section 9.7.1 row 2)") }
    if state.alphaToOne { throw .needsBlendShader("alpha to one (09 section 9.7.1 row 3)") }
    let mask = state.writeMask & 0xF
    let e = state.equation
    // Row 4: the equation is opaque when blending is off or source ONE and destination ZERO in both functions (9.4.4).
    let opaqueEquation =
      !state.enabled
      || ((e.colourOperation == .add || e.colourOperation == .subtract) && e.colourSource == .one && e.colourDestination == .zero
        && (e.alphaOperation == .add || e.alphaOperation == .subtract) && e.alphaSource == .one && e.alphaDestination == .zero)
    if opaqueEquation {
      if mask == 0xF { return (.opaque, FixedFunctionBlend(
        colourFunction: FixedFunctionBlend.replaceFunction, alphaFunction: FixedFunctionBlend.replaceFunction, writeMask: 0xF,
        constant: 0, loadDestination: false)) }
      // A partial mask: fixed function with the replace equation, reading the destination for the channels kept.
      return (.fixedFunction, FixedFunctionBlend(
        colourFunction: FixedFunctionBlend.replaceFunction, alphaFunction: FixedFunctionBlend.replaceFunction, writeMask: mask,
        constant: 0, loadDestination: true))
    }
    // Rows 5 and 6: the equation must be expressible.
    guard let colour = encode(operation: e.colourOperation, source: e.colourSource, destination: e.colourDestination, alpha: false)
    else { throw .needsBlendShader("the colour equation has no A + B * C form (09 section 9.7.2)") }
    guard let alphaFn = encode(operation: e.alphaOperation, source: e.alphaSource, destination: e.alphaDestination, alpha: true)
    else { throw .needsBlendShader("the alpha equation has no A + B * C form (09 section 9.7.2)") }
    // Row 7: the constant. One 16-bit scalar serves every channel an equation names (9.4.5).
    var usesColour = false
    var usesAlpha = false
    for f in [e.colourSource, e.colourDestination] {
      if usesConstantColour(f) { usesColour = true }
      if usesConstantAlpha(f) { usesAlpha = true }
    }
    for f in [e.alphaSource, e.alphaDestination] {
      if usesConstantColour(f) || usesConstantAlpha(f) { usesAlpha = true }
    }
    var constant: UInt32 = 0
    if usesColour || usesAlpha {
      guard state.constant.count == 4 else { throw .needsBlendShader("the blend constant is not four values") }
      let c = state.constant
      if usesColour && !(c[0] == c[1] && c[1] == c[2]) {
        throw .needsBlendShader("the constant colour's channels differ (09 section 9.4.5)")
      }
      if usesColour && usesAlpha && c[0] != c[3] {
        throw .needsBlendShader("the constant colour and alpha differ (09 section 9.4.5)")
      }
      constant = constantWord(usesColour ? c[0] : c[3])
      if let first = firstConstant, first != constant {
        throw .needsBlendShader("the constant differs from the first fixed-function target's (09 section 9.7.1 row 7)")
      }
    }
    // Load Destination (9.4.3): a partial mask, a destination source factor, or any destination factor but ZERO.
    let reads =
      mask != 0xF || readsDestination(e.colourSource) || readsDestination(e.alphaSource)
      || e.colourDestination != .zero || e.alphaDestination != .zero
      || e.colourSource == .srcAlphaSaturate
    return (.fixedFunction, FixedFunctionBlend(
      colourFunction: colour, alphaFunction: alphaFn, writeMask: mask, constant: constant, loadDestination: reads))
  }
}
