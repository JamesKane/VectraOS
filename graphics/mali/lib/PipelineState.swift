// SPDX-License-Identifier: BSD-3-Clause

// The fixed-function state of a draw that a pass's recipe takes beyond the colour-only opaque draw (chinese-wall's
// valhall 06 sections 6.4 to 6.10, 08 sections 8.2 and 8.5, 09): the depth/stencil descriptor with its test on, the depth and
// stencil target of the framebuffer (its parameters and the 64-byte extension), the primitive mode and restart, culling
// and winding, the line width, a viewport and scissor, and the early/late decision. Values are raw hardware numbers:
// the core's names for them are the backend's to map (graphics/core/mali).

// MARK: The depth/stencil descriptor with the test on (06 section 6.8)

/// One face of the stencil test, in the hardware's numbers: compare functions are Vulkan's (never 0 ... always 7);
/// operations are keep 0, replace 1, zero 2, invert 3, increment-wrap 4, decrement-wrap 5, increment-clamp 6,
/// decrement-clamp 7 (6.8.2).
public struct StencilFaceWords: Equatable, Sendable {
  public var function: UInt32 = 7
  public var failOperation: UInt32 = 0
  public var depthFailOperation: UInt32 = 0
  public var passOperation: UInt32 = 0
  public var writeMask: UInt32 = 0xFF
  public var compareMask: UInt32 = 0xFF
  public var reference: UInt32 = 0
  public init() {}
}

/// The state a depth/stencil descriptor holds (06 section 6.8), built afresh for a draw.
public struct ZSDescriptorState: Equatable, Sendable {
  /// The depth function (6.8.1); Always when the depth test is off (6.8.3).
  public var depthFunction: UInt32 = 7
  public var depthWrite = false
  public var stencilTest = false
  public var front = StencilFaceWords()
  public var back = StencilFaceWords()
  public var depthBias = false
  /// The constant factor, the slope factor and the clamp (words 5 to 7), as the API gives them (6.8.4).
  public var biasConstant: Float = 0
  public var biasSlope: Float = 0
  public var biasClamp: Float = 0
  /// Depth cull enable (word 4 `[22]`, the API's depth clip); depth clamp mode 2 (to the viewport's range) when the API
  /// clamps instead of clipping, else 1 (to 0 .. 1) (6.8.3).
  public var depthClip = true
  public var clampToViewport = false
  /// The fragment shader writes the depth: depth source 3, not the fixed function's 2 (6.8.3).
  public var depthFromShader = false

  public init() {}

  /// Whether the depth test can never reject a fragment.
  public var depthAlwaysPasses: Bool { depthFunction == 7 }
  /// Whether the stencil test can never reject (off, or Always on both faces).
  public var stencilAlwaysPasses: Bool { !stencilTest || (front.function == 7 && back.function == 7) }
  /// Whether the draw can change depth or stencil (6.10.2's WZO, without the occlusion query).
  public var writes: Bool { depthWrite || stencilTest }

  /// The 8 words (6.8): word 0 the type and the stencil functions and operations, word 1 the write and compare masks,
  /// word 2 the references, word 3 reserved, word 4 the depth fields, words 5 to 7 the bias.
  public var words: [UInt32] {
    var w0: UInt32 = DepthStencilDescriptor.typeTag
    if stencilTest {
      w0 |= (front.function & 7) << 4 | (front.failOperation & 7) << 7 | (front.depthFailOperation & 7) << 10
        | (front.passOperation & 7) << 13 | (back.function & 7) << 16 | (back.failOperation & 7) << 19
        | (back.depthFailOperation & 7) << 22 | (back.passOperation & 7) << 25 | 1 << 31
    }
    let w1: UInt32 = stencilTest
      ? (front.writeMask & 0xFF) | (back.writeMask & 0xFF) << 8 | (front.compareMask & 0xFF) << 16 | (back.compareMask & 0xFF) << 24 : 0
    let w2: UInt32 = stencilTest ? (front.reference & 0xFF) | (back.reference & 0xFF) << 8 : 0
    var w4: UInt32 = (depthFromShader ? 3 : 2) << 25 | (depthClip ? 1 << 22 : 0) | (clampToViewport ? 2 : 1) << 23
    if depthWrite { w4 |= 1 << 27 }
    if depthBias { w4 |= 1 << 28 }
    w4 |= (depthFunction & 7) << 29
    return [w0, w1, w2, 0, w4, depthBias ? biasConstant.bitPattern : 0, depthBias ? biasSlope.bitPattern : 0,
            depthBias ? biasClamp.bitPattern : 0]
  }
}

// MARK: The depth and stencil target (08 sections 8.2.1 and 8.5)

/// The depth format of a target: its memory format (8.5.1: D16 1, D32 14) and the tile's internal format (8.2.2: D16 0,
/// D32 2).
public enum DepthFormat: Equatable, Sendable {
  case d16
  case d32f
  public var writeFormat: UInt32 { self == .d16 ? 1 : 14 }
  public var internalFormat: UInt32 { self == .d16 ? 0 : 2 }
  public var bytesPerPixel: Int { self == .d16 ? 2 : 4 }
}

/// A pass's depth and stencil target: the planes it writes back (a linear plane each), and the clear values the tile starts
/// from. A plane the pass doesn't store has no address (its record says "no write"). Loading from an image is a frame
/// shader's (08 section 8.10), not this record's.
public struct ZSTarget: Equatable, Sendable {
  public static let size = 64
  public var depthFormat: DepthFormat?
  /// The depth plane's surface (nil: not stored) and its strides.
  public var depthAddress: UInt64?
  public var depthRowStride = 0
  public var depthSurfaceStride = 0
  /// The stencil plane's surface (nil: not stored); the S8 plane's strides.
  public var stencilAddress: UInt64?
  public var stencilRowStride = 0
  public var stencilSurfaceStride = 0
  public var clearDepth: Float = 1
  public var clearStencil: UInt32 = 0
  /// Whether the pass has a stencil aspect (a stencil-only target has no depth format).
  public var hasStencil = false

  public init(depthFormat: DepthFormat?, hasStencil: Bool) {
    self.depthFormat = depthFormat
    self.hasStencil = hasStencil
  }

  /// The parameters block's word 12 (08 section 8.2.1) for this target: stencil clear `[7:0]`, stencil write `[8]`, Z internal
  /// format `[17:16]`, Z write `[18]`, has-extension `[21]`. D24 for a stencil-only target.
  public var word12: UInt32 {
    var w: UInt32 = (clearStencil & 0xFF) | (depthFormat?.internalFormat ?? 1) << 16 | 1 << 21
    if stencilAddress != nil { w |= 1 << 8 }
    if depthAddress != nil { w |= 1 << 18 }
    return w
  }

  /// The extension (08 section 8.5): the depth record (write format `[3:0]`, linear block format `[7:4]`) and the stencil
  /// record (S8 write format 1 at `[19:16]`, block format `[23:20]`), clean tile write `[31]` (a tile no primitive touched
  /// still holds the clear value the pass stores), and the planes' bases and strides at words 8 to 15.
  public func words() throws(DescriptorError) -> [UInt32] {
    var w = [UInt32](repeating: 0, count: 16)
    if let a = depthAddress, let f = depthFormat {
      guard a & 63 == 0 else { throw .misaligned }
      guard depthRowStride > 0, depthRowStride < 1 << 27, depthSurfaceStride >= 0, UInt64(depthSurfaceStride) < 1 << 37 else {
        throw .outOfRange
      }
      w[0] |= f.writeFormat | 2 << 4
      w[8] = UInt32(truncatingIfNeeded: a)
      w[9] = UInt32(truncatingIfNeeded: a >> 32)
      w[10] = UInt32(depthRowStride) | UInt32(truncatingIfNeeded: UInt64(depthSurfaceStride) >> 32) << 27
      w[11] = UInt32(truncatingIfNeeded: depthSurfaceStride)
    }
    if let a = stencilAddress {
      guard a & 63 == 0 else { throw .misaligned }
      guard stencilRowStride > 0, stencilRowStride < 1 << 27, stencilSurfaceStride >= 0, UInt64(stencilSurfaceStride) < 1 << 37
      else { throw .outOfRange }
      w[0] |= 1 << 16 | 2 << 20
      w[12] = UInt32(truncatingIfNeeded: a)
      w[13] = UInt32(truncatingIfNeeded: a >> 32)
      w[14] = UInt32(stencilRowStride) | UInt32(truncatingIfNeeded: UInt64(stencilSurfaceStride) >> 32) << 27
      w[15] = UInt32(truncatingIfNeeded: stencilSurfaceStride)
    }
    if depthAddress != nil || stencilAddress != nil { w[0] |= 1 << 31 }
    return w
  }
}

// MARK: Early and late (06 section 6.10.2)

public enum PixelOperations {
  /// The kill and update operations of arch 12 for a draw: the procedure of 6.10.2 with its inputs `sw` (the shader writes
  /// depth or stencil), `wzo` (the API state writes depth or stencil, or an occlusion query is active), `ac` (alpha to
  /// coverage), `lc` (coverage may depend on the shader), `se` (memory side effects), `eft` (forced early tests) and `pass`
  /// (the depth and stencil tests always pass).
  public static func derive(sw: Bool, wzo: Bool, ac: Bool, lc: Bool, se: Bool, eft: Bool, pass: Bool)
    -> (kill: PixelOperation, update: PixelOperation)
  {
    var lateUpdate = sw || ac
    var lateKill = sw
    // Arch 11 and later force the update early (6.10.1: it cannot be weak).
    let forceEarlyUpdate = true
    let forceEarlyKill = eft
    if lc && wzo { lateUpdate = true }
    if se { lateKill = true }
    if eft {
      lateUpdate = false
      lateKill = false
    }
    let update: PixelOperation = lateUpdate ? .forceLate : (pass && !forceEarlyUpdate ? .weakEarly : .forceEarly)
    let kill: PixelOperation = lateKill ? .forceLate : (pass && !forceEarlyKill ? .weakEarly : .forceEarly)
    return (kill, update)
  }
}

// MARK: One draw's state

/// A viewport as a command gives it, in pixels, and its depth range.
public struct DrawViewport: Equatable, Sendable {
  public var x: Float
  public var y: Float
  public var width: Float
  public var height: Float
  public var minDepth: Float
  public var maxDepth: Float
  public init(x: Float, y: Float, width: Float, height: Float, minDepth: Float = 0, maxDepth: Float = 1) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.minDepth = minDepth
    self.maxDepth = maxDepth
  }

  /// The rectangle of the viewport as the hardware has it (6.7.2): the origin truncated, the far corner minus one, a negative
  /// height swapping the bounds, clamped to the target, a zero extent keeping the minimum.
  public func box(width target: Int, height targetHeight: Int) -> ScissorBox {
    func clamp(_ v: Float, _ hi: Int) -> Int {
      if !(v > 0) { return 0 }
      if v >= Float(hi) { return hi }
      return Int(v)
    }
    let x0 = clamp(x, target - 1)
    var x1 = clamp(x + width - 1, target - 1)
    let y0 = clamp(min(y, y + height), targetHeight - 1)
    var y1 = clamp(max(y, y + height) - 1, targetHeight - 1)
    if x1 < x0 { x1 = x0 }
    if y1 < y0 { y1 = y0 }
    return ScissorBox(minX: x0, minY: y0, maxX: x1, maxY: y1)
  }
}

/// What a draw adds to the colour-only opaque triangle list. Its default is that draw.
public struct DrawPipelineState: Equatable, Sendable {
  public var mode: DrawMode = .triangles
  public var primitiveRestart = false
  /// Culling and winding, for a triangle mode (6.9.1: never for points and lines).
  public var cullFront = false
  public var cullBack = false
  public var frontFaceCCW = false
  /// The line width or point size written to `PRIMITIVE_SIZE` (arch 12, 6.5); 0 leaves the register zero.
  public var primitiveSize: Float = 0
  /// The depth/stencil descriptor; nil leaves the test off.
  public var depthStencil: ZSDescriptorState?
  /// The viewport (nil: the whole target) and the scissor (nil: the whole target).
  public var viewport: DrawViewport?
  public var scissor: ScissorBox?
  /// The sample mask word of flags 1 (all ones: every sample).
  public var sampleMask: UInt32 = 0xFFFF
  public init() {}

  /// The smallest vertex count that makes one primitive of the mode.
  public var minimumVertices: Int {
    switch mode {
    case .points: return 1
    case .lines, .lineStrip: return 2
    default: return 3
    }
  }
}
