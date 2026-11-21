// SPDX-License-Identifier: BSD-3-Clause

// The fixed state of a graphics pipeline (D174 section 1 and its amendment; gpucore(2)): depth and stencil,
// rasterization, multisampling, blending, and the state a pass's commands set in
// place of the pipeline's. Each type's `init()` is today's behaviour, so a
// pipeline that names none of them is the one the core always had.

public enum CompareOp: Sendable, Equatable {
  case never, less, equal, lessOrEqual, greater, notEqual, greaterOrEqual, always
}

public enum StencilOp: Sendable, Equatable {
  case keep, zero, replace, incrementClamp, decrementClamp, invert, incrementWrap, decrementWrap
}

/// What the stencil test does for one face (front or back).
public struct StencilFaceState: Sendable, Equatable {
  public var failOp: StencilOp
  public var passOp: StencilOp
  public var depthFailOp: StencilOp
  public var compare: CompareOp
  public var compareMask: UInt32
  public var writeMask: UInt32
  public var reference: UInt32
  public init(failOp: StencilOp = .keep, passOp: StencilOp = .keep, depthFailOp: StencilOp = .keep, compare: CompareOp = .always,
              compareMask: UInt32 = 0xFF, writeMask: UInt32 = 0xFF, reference: UInt32 = 0) {
    self.failOp = failOp
    self.passOp = passOp
    self.depthFailOp = depthFailOp
    self.compare = compare
    self.compareMask = compareMask
    self.writeMask = writeMask
    self.reference = reference
  }
}

public struct DepthStencilState: Sendable, Equatable {
  public var depthTest: Bool
  public var depthWrite: Bool
  public var depthCompare: CompareOp
  public var depthBoundsTest: Bool
  public var minDepthBounds: Float
  public var maxDepthBounds: Float
  public var stencilTest: Bool
  public var front: StencilFaceState
  public var back: StencilFaceState
  public init(depthTest: Bool = false, depthWrite: Bool = false, depthCompare: CompareOp = .less, depthBoundsTest: Bool = false,
              minDepthBounds: Float = 0, maxDepthBounds: Float = 1, stencilTest: Bool = false,
              front: StencilFaceState = StencilFaceState(), back: StencilFaceState = StencilFaceState()) {
    self.depthTest = depthTest
    self.depthWrite = depthWrite
    self.depthCompare = depthCompare
    self.depthBoundsTest = depthBoundsTest
    self.minDepthBounds = minDepthBounds
    self.maxDepthBounds = maxDepthBounds
    self.stencilTest = stencilTest
    self.front = front
    self.back = back
  }

  /// Whether the state does anything: the state of a pipeline with no depth or stencil.
  public var isEnabled: Bool { depthTest || depthWrite || depthBoundsTest || stencilTest }
}

public enum CullMode: Sendable, Equatable { case none, front, back, frontAndBack }
public enum FrontFace: Sendable, Equatable { case counterClockwise, clockwise }
public enum PolygonMode: Sendable, Equatable { case fill, line, point }

public struct RasterizationState: Sendable, Equatable {
  public var cull: CullMode
  public var frontFace: FrontFace
  public var polygonMode: PolygonMode
  public var depthBias: Bool
  public var depthBiasConstant: Float
  public var depthBiasClamp: Float
  public var depthBiasSlope: Float
  /// Fragments past the near and far planes are clamped to them, not clipped.
  public var depthClamp: Bool
  public var lineWidth: Float
  /// Nothing is rasterized: a pipeline for its vertex stage's outputs.
  public var rasterizerDiscard: Bool
  public init(cull: CullMode = .none, frontFace: FrontFace = .counterClockwise, polygonMode: PolygonMode = .fill,
              depthBias: Bool = false, depthBiasConstant: Float = 0, depthBiasClamp: Float = 0, depthBiasSlope: Float = 0,
              depthClamp: Bool = false, lineWidth: Float = 1, rasterizerDiscard: Bool = false) {
    self.cull = cull
    self.frontFace = frontFace
    self.polygonMode = polygonMode
    self.depthBias = depthBias
    self.depthBiasConstant = depthBiasConstant
    self.depthBiasClamp = depthBiasClamp
    self.depthBiasSlope = depthBiasSlope
    self.depthClamp = depthClamp
    self.lineWidth = lineWidth
    self.rasterizerDiscard = rasterizerDiscard
  }
}

public struct MultisampleState: Sendable, Equatable {
  /// 1, or a count the format and the device offer.
  public var samples: UInt32
  /// Bit n keeps sample n.
  public var sampleMask: UInt64
  public var alphaToCoverage: Bool
  public var alphaToOne: Bool
  public var sampleShading: Bool
  /// The fraction of samples a fragment shader runs for, with `sampleShading`.
  public var minSampleShading: Float
  public init(samples: UInt32 = 1, sampleMask: UInt64 = ~0, alphaToCoverage: Bool = false, alphaToOne: Bool = false,
              sampleShading: Bool = false, minSampleShading: Float = 0) {
    self.samples = samples
    self.sampleMask = sampleMask
    self.alphaToCoverage = alphaToCoverage
    self.alphaToOne = alphaToOne
    self.sampleShading = sampleShading
    self.minSampleShading = minSampleShading
  }
}

public enum BlendingFactor: Sendable, Equatable {
  case zero, one
  case srcColor, oneMinusSrcColor, dstColor, oneMinusDstColor
  case srcAlpha, oneMinusSrcAlpha, dstAlpha, oneMinusDstAlpha
  case constantColor, oneMinusConstantColor, constantAlpha, oneMinusConstantAlpha
  case srcAlphaSaturate
  /// The second output of the fragment shader (`DeviceFeatures.dualSourceBlend`).
  case src1Color, oneMinusSrc1Color, src1Alpha, oneMinusSrc1Alpha

  public var usesSecondOutput: Bool {
    switch self {
    case .src1Color, .oneMinusSrc1Color, .src1Alpha, .oneMinusSrc1Alpha: true
    default: false
    }
  }
}

public enum BlendOp: Sendable, Equatable { case add, subtract, reverseSubtract, min, max }

/// The channels a pass writes.
public struct ColorMask: Sendable, Equatable {
  public var rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let red = ColorMask(rawValue: 1)
  public static let green = ColorMask(rawValue: 2)
  public static let blue = ColorMask(rawValue: 4)
  public static let alpha = ColorMask(rawValue: 8)
  public static let all = ColorMask(rawValue: 15)
  public static func | (a: ColorMask, b: ColorMask) -> ColorMask { ColorMask(rawValue: a.rawValue | b.rawValue) }
}

/// How a fragment's colour combines with the target's, for one colour attachment.
public struct ColorBlendAttachment: Sendable, Equatable {
  public var enabled: Bool
  public var srcColor: BlendingFactor
  public var dstColor: BlendingFactor
  public var colorOp: BlendOp
  public var srcAlpha: BlendingFactor
  public var dstAlpha: BlendingFactor
  public var alphaOp: BlendOp
  public var writeMask: ColorMask
  public init(enabled: Bool = false, srcColor: BlendingFactor = .one, dstColor: BlendingFactor = .zero, colorOp: BlendOp = .add,
              srcAlpha: BlendingFactor = .one, dstAlpha: BlendingFactor = .zero, alphaOp: BlendOp = .add,
              writeMask: ColorMask = .all) {
    self.enabled = enabled
    self.srcColor = srcColor
    self.dstColor = dstColor
    self.colorOp = colorOp
    self.srcAlpha = srcAlpha
    self.dstAlpha = dstAlpha
    self.alphaOp = alphaOp
    self.writeMask = writeMask
  }

  /// `BlendMode.opaque`: the fragment replaces the target's colour.
  public static var opaque: ColorBlendAttachment { ColorBlendAttachment() }

  /// `BlendMode.alpha`: source alpha over.
  public static var alphaOver: ColorBlendAttachment {
    ColorBlendAttachment(enabled: true, srcColor: .srcAlpha, dstColor: .oneMinusSrcAlpha, colorOp: .add, srcAlpha: .one,
                         dstAlpha: .oneMinusSrcAlpha, alphaOp: .add)
  }

  /// Whether any factor reads the fragment shader's second output.
  public var usesDualSource: Bool {
    enabled && (srcColor.usesSecondOutput || dstColor.usesSecondOutput || srcAlpha.usesSecondOutput || dstAlpha.usesSecondOutput)
  }
}

public enum LogicOp: Sendable, Equatable {
  case clear, and, andReverse, copy, andInverted, noop, xor, or, nor, equivalent, invert, orReverse, copyInverted, orInverted,
    nand, set
}

public struct BlendConstants: Sendable, Equatable {
  public var red: Float
  public var green: Float
  public var blue: Float
  public var alpha: Float
  public init(red: Float = 0, green: Float = 0, blue: Float = 0, alpha: Float = 0) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

/// The state a pass's commands set in place of the pipeline's own (`DeviceFeatures.dynamicState`). The viewport and
/// scissor are always set by commands.
public struct DynamicStates: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32 = 0) { self.rawValue = rawValue }
  public static let blendConstants = DynamicStates(rawValue: 1)
  public static let stencilReference = DynamicStates(rawValue: 2)
  public static let stencilCompareMask = DynamicStates(rawValue: 4)
  public static let stencilWriteMask = DynamicStates(rawValue: 8)
  public static let depthBias = DynamicStates(rawValue: 16)
  public static let depthBounds = DynamicStates(rawValue: 32)
  public static let lineWidth = DynamicStates(rawValue: 64)

  public var isEmpty: Bool { rawValue == 0 }
  public func contains(_ other: DynamicStates) -> Bool { rawValue & other.rawValue == other.rawValue }
  public static func | (a: DynamicStates, b: DynamicStates) -> DynamicStates { DynamicStates(rawValue: a.rawValue | b.rawValue) }
}

/// The faces a stencil command sets.
public struct StencilFaces: Sendable, Equatable {
  public var rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let front = StencilFaces(rawValue: 1)
  public static let back = StencilFaces(rawValue: 2)
  public static let both = StencilFaces(rawValue: 3)
}

/// What a pass must have for a pipeline to draw in it: its attachments' formats, in order, the depth and stencil
/// attachment's, the sample count and the view mask.
public struct PipelineTargets: Sendable, Equatable {
  public var colorFormats: [PixelFormat]
  public var depthStencilFormat: PixelFormat?
  public var samples: UInt32
  public var viewMask: UInt32
  public init(colorFormats: [PixelFormat], depthStencilFormat: PixelFormat? = nil, samples: UInt32 = 1, viewMask: UInt32 = 0) {
    self.colorFormats = colorFormats
    self.depthStencilFormat = depthStencilFormat
    self.samples = samples
    self.viewMask = viewMask
  }
}

/// The value of one specialization constant, as the bits of a 32-bit or 64-bit value.
public struct SpecializationConstant: Sendable, Equatable {
  public var id: UInt32
  public var value: UInt64
  public init(id: UInt32, value: UInt64) {
    self.id = id
    self.value = value
  }
  public init(id: UInt32, bool: Bool) { self.init(id: id, value: bool ? 1 : 0) }
  public init(id: UInt32, int32: Int32) { self.init(id: id, value: UInt64(UInt32(bitPattern: int32))) }
  public init(id: UInt32, uint32: UInt32) { self.init(id: id, value: UInt64(uint32)) }
  public init(id: UInt32, float32: Float) { self.init(id: id, value: UInt64(float32.bitPattern)) }
}
