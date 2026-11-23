// SPDX-License-Identifier: BSD-3-Clause

// A graphics pipeline's fixed-function state on Mali (D174's amendment, step 3; gpucore(2)): what the core's
// `GraphicsPipelineDescriptor` says, mapped to MaliCore's draw state (graphics/mali PipelineState.swift and Blend.swift) at
// the pipeline's making, and resolved against the state a pass's commands have set when a draw is planned. The
// hardware's decisions are the specs' (valhall 06, 08, 09); a state the hardware or this driver doesn't do is refused at the
// pipeline's making, in words, with `.unsupported`.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

/// What a graphics pipeline fixes, kept in its record.
struct GraphicsState {
  var topology: PrimitiveTopology
  var restart: Bool
  var raster: RasterizationState
  var depthStencil: DepthStencilState
  var depthStencilFormat: PixelFormat?
  var blend: ColorBlendAttachment
  /// Every colour target's format and blend, in order (the first is `blend`).
  var formats: [PixelFormat]
  var blends: [ColorBlendAttachment]
  var constants: BlendConstants
  var dynamic: DynamicStates
  var srgb: Bool
  /// The pipeline's logic operation (it turns blending off on every target).
  var logicOp: LogicOperation?
  /// The fragment shader was compiled to call blend shaders (09 section 9.9): some target may need one.
  var fragmentCalls: Bool
  /// The samples, the sample mask, alpha to coverage and one, and sample shading.
  var multisample = MultisampleState()
}

/// The state a pass's commands set, as the draws after them see it.
struct DynamicValues {
  var viewport: DrawViewport?
  var scissor: ScissorBox?
  var constants = BlendConstants()
  var frontReference: UInt32 = 0
  var backReference: UInt32 = 0
  var frontCompareMask: UInt32 = 0xFF
  var backCompareMask: UInt32 = 0xFF
  var frontWriteMask: UInt32 = 0xFF
  var backWriteMask: UInt32 = 0xFF
  var biasConstant: Float = 0
  var biasClamp: Float = 0
  var biasSlope: Float = 0
  var lineWidth: Float = 1
}

enum PipelineMapping {
  /// The widest line the hardware draws (valhall 06 section 6.5.1: 8 minus 1/128).
  static let maxLineWidth: Float = 7.9921875

  static func compare(_ c: CompareOp) -> UInt32 {
    switch c {
    case .never: 0
    case .less: 1
    case .equal: 2
    case .lessOrEqual: 3
    case .greater: 4
    case .notEqual: 5
    case .greaterOrEqual: 6
    case .always: 7
    }
  }

  static func stencilOperation(_ o: StencilOp) -> UInt32 {
    switch o {
    case .keep: 0
    case .replace: 1
    case .zero: 2
    case .invert: 3
    case .incrementWrap: 4
    case .decrementWrap: 5
    case .incrementClamp: 6
    case .decrementClamp: 7
    }
  }

  static func factor(_ f: BlendingFactor) -> BlendFactor {
    switch f {
    case .zero: .zero
    case .one: .one
    case .srcColor: .srcColour
    case .oneMinusSrcColor: .oneMinusSrcColour
    case .dstColor: .dstColour
    case .oneMinusDstColor: .oneMinusDstColour
    case .srcAlpha: .srcAlpha
    case .oneMinusSrcAlpha: .oneMinusSrcAlpha
    case .dstAlpha: .dstAlpha
    case .oneMinusDstAlpha: .oneMinusDstAlpha
    case .constantColor: .constantColour
    case .oneMinusConstantColor: .oneMinusConstantColour
    case .constantAlpha: .constantAlpha
    case .oneMinusConstantAlpha: .oneMinusConstantAlpha
    case .srcAlphaSaturate: .srcAlphaSaturate
    case .src1Color: .src1Colour
    case .oneMinusSrc1Color: .oneMinusSrc1Colour
    case .src1Alpha: .src1Alpha
    case .oneMinusSrc1Alpha: .oneMinusSrc1Alpha
    }
  }

  static func logic(_ o: LogicOp) -> LogicOperation {
    switch o {
    case .clear: .clear
    case .and: .and
    case .andReverse: .andReverse
    case .copy: .copy
    case .andInverted: .andInverted
    case .noop: .noop
    case .xor: .xor
    case .or: .or
    case .nor: .nor
    case .equivalent: .equivalent
    case .invert: .invert
    case .orReverse: .orReverse
    case .copyInverted: .copyInverted
    case .orInverted: .orInverted
    case .nand: .nand
    case .set: .set
    }
  }

  static func operation(_ o: BlendOp) -> BlendOperation {
    switch o {
    case .add: .add
    case .subtract: .subtract
    case .reverseSubtract: .reverseSubtract
    case .min: .min
    case .max: .max
    }
  }

  /// Whether the equation names the blend constant.
  static func usesConstant(_ b: ColorBlendAttachment) -> Bool {
    guard b.enabled else { return false }
    for f in [b.srcColor, b.dstColor, b.srcAlpha, b.dstAlpha] {
      switch f {
      case .constantColor, .oneMinusConstantColor, .constantAlpha, .oneMinusConstantAlpha: return true
      default: break
      }
    }
    return false
  }

  /// A render target's blend and the blend shader it needs, if any (09 section 9.7.1).
  struct TargetBlend {
    var descriptor: BlendDescriptor
    var shader: BlendShaderSpec?
  }

  /// The blend of every colour target of a pipeline by 09 section 9.7.1 (the array's position is the target, 9.2.3), with the one
  /// constant the hardware reads (the first fixed-function target's that names one) in all the fixed-function descriptors: a target
  /// whose constant differs from an earlier one's, or that names constants that are not the same in the channels it uses, or whose
  /// equation the blender can't do, gets a blend shader.
  static func blendTargets(_ state: GraphicsState, constants k: BlendConstants) -> [TargetBlend] {
    var out: [TargetBlend] = []
    var first: UInt32?
    for (i, b) in state.blends.enumerated() {
      let t = BlendDescriptor.planned(
        blendState(b, constants: k, logic: state.logicOp, alphaToOne: state.multisample.alphaToOne), renderTarget: i, isSRGB: state.formats[i] == .bgra8srgb, firstConstant: first)
      if t.descriptor.mode == .fixedFunction && usesConstant(b) && first == nil { first = t.descriptor.blend.constant }
      out.append(TargetBlend(descriptor: t.descriptor, shader: t.shader))
    }
    if let c = first { for i in 0..<out.count where out[i].descriptor.mode == .fixedFunction { out[i].descriptor.blend.constant = c } }
    return out
  }

  /// Whether a draw of the pipeline may need a blend shader: now with its own constants, or when the constants are dynamic and
  /// some equation names one (a draw's constants decide whether the blender can do it).
  static func mayNeedBlendShader(_ state: GraphicsState) -> Bool {
    if blendTargets(state, constants: state.constants).contains(where: { $0.shader != nil }) { return true }
    if state.dynamic.contains(.blendConstants) && state.logicOp == nil {
      for (i, b) in state.blends.enumerated() where usesConstant(b) && i < state.formats.count { return true }
    }
    return false
  }

  /// The blend state of a colour attachment with the constants in force.
  static func blendState(_ b: ColorBlendAttachment, constants k: BlendConstants, logic: LogicOperation?, alphaToOne: Bool = false) -> BlendState {
    let equation = BlendEquation(
      colourOperation: operation(b.colorOp), colourSource: factor(b.srcColor), colourDestination: factor(b.dstColor),
      alphaOperation: operation(b.alphaOp), alphaSource: factor(b.srcAlpha), alphaDestination: factor(b.dstAlpha))
    // Alpha to one is a blend shader's (09 section 9.2.2: the reference replaces the source alphas by 1.0 in one).
    return BlendState(enabled: b.enabled, equation: equation, writeMask: UInt32(b.writeMask.rawValue),
                      constant: [k.red, k.green, k.blue, k.alpha], alphaToOne: alphaToOne, logicOp: logic)
  }

  /// The primitive mode of a topology, or the refusal.
  static func mode(_ t: PrimitiveTopology) throws(GPUError) -> DrawMode {
    switch t {
    case .triangleList: return .triangles
    case .triangleStrip: return .triangleStrip
    case .triangleFan: return .triangleFan
    case .lineList: return .lines
    case .lineStrip: return .lineStrip
    case .pointList: return .points
    case .patchList: throw .unsupported("patch lists")
    }
  }

  /// The scissor box of a command (06 section 6.7.1): the origin and the far corner minus one, clamped to the target, a
  /// zero extent keeping one pixel.
  static func scissorBox(x: Int, y: Int, width: Int, height: Int, targetWidth: Int, targetHeight: Int) -> ScissorBox {
    let x0 = min(max(x, 0), targetWidth - 1)
    let y0 = min(max(y, 0), targetHeight - 1)
    let x1 = max(min(x + width - 1, targetWidth - 1), x0)
    let y1 = max(min(y + height - 1, targetHeight - 1), y0)
    return ScissorBox(minX: x0, minY: y0, maxX: x1, maxY: y1)
  }

  static func isTriangles(_ t: PrimitiveTopology) -> Bool { t == .triangleList || t == .triangleStrip || t == .triangleFan }

  /// The state of a draw of `state`'s pipeline with `dyn` in force, on a target of `width` by `height`. `hasDepth` and
  /// `hasStencil` say what the pass has; a test the pass can't hold was refused when the list was judged.
  static func drawState(_ state: GraphicsState, _ dyn: DynamicValues, width: Int, height: Int) -> DrawPipelineState {
    var s = DrawPipelineState()
    s.mode = (try? mode(state.topology)) ?? .triangles
    s.primitiveRestart = state.restart
    let r = state.raster
    if isTriangles(state.topology) {
      s.cullFront = r.cull == .front || r.cull == .frontAndBack
      s.cullBack = r.cull == .back || r.cull == .frontAndBack
      s.frontFaceCCW = r.frontFace == .counterClockwise
    }
    if state.topology == .pointList {
      s.primitiveSize = 1
    } else if state.topology == .lineList || state.topology == .lineStrip {
      let w = state.dynamic.contains(.lineWidth) ? dyn.lineWidth : r.lineWidth
      s.primitiveSize = min(max(w, 0), maxLineWidth)
    }
    s.viewport = dyn.viewport
    s.scissor = dyn.scissor
    // The sample mask (flags 1, 6.9.2), sample shading (binary on this hardware: any fraction above 0 shades every sample, 6.9.4)
    // and alpha to coverage (the hardware's own mapping, 6.9.4).
    let ms = state.multisample
    s.sampleMask = UInt32(truncatingIfNeeded: ms.sampleMask) & 0xFFFF
    s.perSample = ms.sampleShading && ms.minSampleShading > 0
    s.alphaToCoverage = ms.alphaToCoverage
    let d = state.depthStencil
    let hasDepth = state.depthStencilFormat?.hasDepth ?? false
    let hasStencil = state.depthStencilFormat?.hasStencil ?? false
    if (hasDepth && (d.depthTest || d.depthWrite)) || (hasStencil && d.stencilTest) || r.depthBias || r.depthClamp {
      var z = ZSDescriptorState()
      if hasDepth && d.depthTest {
        z.depthFunction = compare(d.depthCompare)
        z.depthWrite = d.depthWrite
      }
      if hasStencil && d.stencilTest {
        z.stencilTest = true
        func face(_ f: StencilFaceState, reference: UInt32, compareMask: UInt32, writeMask: UInt32) -> StencilFaceWords {
          var w = StencilFaceWords()
          w.function = compare(f.compare)
          w.failOperation = stencilOperation(f.failOp)
          w.passOperation = stencilOperation(f.passOp)
          w.depthFailOperation = stencilOperation(f.depthFailOp)
          w.reference = reference
          w.compareMask = compareMask
          w.writeMask = writeMask
          return w
        }
        let dynamic = state.dynamic
        z.front = face(
          d.front, reference: dynamic.contains(.stencilReference) ? dyn.frontReference : d.front.reference,
          compareMask: dynamic.contains(.stencilCompareMask) ? dyn.frontCompareMask : d.front.compareMask,
          writeMask: dynamic.contains(.stencilWriteMask) ? dyn.frontWriteMask : d.front.writeMask)
        z.back = face(
          d.back, reference: dynamic.contains(.stencilReference) ? dyn.backReference : d.back.reference,
          compareMask: dynamic.contains(.stencilCompareMask) ? dyn.backCompareMask : d.back.compareMask,
          writeMask: dynamic.contains(.stencilWriteMask) ? dyn.backWriteMask : d.back.writeMask)
      }
      if r.depthBias {
        z.depthBias = true
        if state.dynamic.contains(.depthBias) {
          z.biasConstant = dyn.biasConstant
          z.biasSlope = dyn.biasSlope
          z.biasClamp = dyn.biasClamp
        } else {
          z.biasConstant = r.depthBiasConstant
          z.biasSlope = r.depthBiasSlope
          z.biasClamp = r.depthBiasClamp
        }
      }
      if r.depthClamp {
        z.depthClip = false
        z.clampToViewport = true
      }
      s.depthStencil = z
    }
    return s
  }
}
