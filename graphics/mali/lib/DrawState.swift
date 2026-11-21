// SPDX-License-Identifier: BSD-3-Clause

// The per-draw state a vertex/tiler run consumes (chinese-wall's valhall 06 and
// 09): the primitive flags, the three draw flag words, scissor and viewport, the
// depth/stencil descriptor with the test off, the opaque blend descriptor, and
// the staging registers of RUN_IDVS2 (01 section 1.9.3) that carry them (arch
// 12). Each is a value that encodes itself; a zero word is not a neutral
// default (06 section 6.1), so every word is built from its table.

// MARK: Primitive flags (06 section 6.2)

public enum DrawMode: UInt32, Sendable {
  case points = 1
  case lines = 2
  case lineStrip = 4
  case triangles = 8
  case triangleStrip = 10
  case triangleFan = 12
}

/// The `TILER_FLAGS` word (register 56). The depth-cull bits are set by default, as an ordinary draw has them.
public struct PrimitiveFlags: Equatable, Sendable {
  public var mode: DrawMode
  /// 0 none, 1 u8, 2 u16, 3 u32.
  public var indexType: UInt32
  public var lowDepthCull: Bool
  public var highDepthCull: Bool
  public var primitiveRestart: Bool
  /// 1 basic: the vertex shader writes none of point size, layer and primitive id; 2 extended.
  public var positionFIFOFormat: UInt32
  /// Bit i selects layer i of the tiler context (arch 10 to 13). 0 for a draw that is neither layered nor multiview
  /// (06 section 6.12 gives only those two uses).
  public var viewMask: UInt32

  public init(mode: DrawMode = .triangles, indexType: UInt32 = 0, lowDepthCull: Bool = true, highDepthCull: Bool = true,
              primitiveRestart: Bool = false, positionFIFOFormat: UInt32 = 1, viewMask: UInt32 = 0) {
    self.mode = mode
    self.indexType = indexType
    self.lowDepthCull = lowDepthCull
    self.highDepthCull = highDepthCull
    self.primitiveRestart = primitiveRestart
    self.positionFIFOFormat = positionFIFOFormat
    self.viewMask = viewMask
  }

  /// Draw mode `[3:0]`, index type `[10:8]`, low depth cull `[16]`, high depth cull `[17]`, primitive restart
  /// `[19]`, position FIFO format `[23:22]`, view mask `[31:24]`; the rest is zero.
  public var word: UInt32 {
    mode.rawValue | (indexType & 7) << 8 | (lowDepthCull ? 1 << 16 : 0) | (highDepthCull ? 1 << 17 : 0)
      | (primitiveRestart ? 1 << 19 : 0) | (positionFIFOFormat & 3) << 22 | (viewMask & 0xFF) << 24
  }
}

// MARK: Draw flag words (06 section 6.9)

/// The kill and update operations of 6.10.1.
public enum PixelOperation: UInt32, Sendable {
  case forceEarly = 0
  case strongEarly = 1
  case weakEarly = 2
  case forceLate = 3
}

/// Draw flags 0 (register 57), for a draw whose fragment shader writes colour only. The derivation of the kill
/// and update operations is 6.10.2's: with no depth attachment, no occlusion query and a plain shader (SW = WZO =
/// AC = LC = SE = EFT = 0, PASS = 1) the update is Force early and the kill Weak early (its third worked example).
public struct DrawFlags0: Equatable, Sendable {
  public var allowForwardPixelToKill: Bool
  public var allowForwardPixelToBeKilled: Bool
  public var pixelKill: PixelOperation
  public var zsUpdate: PixelOperation
  public var primitiveBarrier: Bool
  public var frontFaceCCW: Bool
  public var cullFront: Bool
  public var cullBack: Bool
  public var multisample: Bool
  public var shaderModifiesCoverage: Bool
  public var scissorToBoundingBox: Bool
  public var cullZeroArea: Bool

  /// A colour-only opaque draw with nothing culled (6.9.1's POLICY rows: scissor to bounding box and cull zero
  /// area are always set on arch 12; the forward-pixel bits follow 6.10.3).
  public static let colourOnly = DrawFlags0(
    allowForwardPixelToKill: true, allowForwardPixelToBeKilled: true, pixelKill: .weakEarly, zsUpdate: .forceEarly,
    primitiveBarrier: false, frontFaceCCW: false, cullFront: false, cullBack: false, multisample: false,
    shaderModifiesCoverage: false, scissorToBoundingBox: true, cullZeroArea: true)

  /// Allow kill `[0]`, allow be killed `[1]`, pixel kill `[3:2]`, ZS update `[5:4]`, primitive barrier `[10]`,
  /// front face CCW `[16]`, cull front `[17]`, cull back `[18]`, multisample `[19]`, shader modifies coverage
  /// `[20]`, scissor to bounding box `[23]`, cull zero area `[26]`.
  public var word: UInt32 {
    (allowForwardPixelToKill ? 1 : 0) | (allowForwardPixelToBeKilled ? 1 << 1 : 0) | pixelKill.rawValue << 2
      | zsUpdate.rawValue << 4 | (primitiveBarrier ? 1 << 10 : 0) | (frontFaceCCW ? 1 << 16 : 0)
      | (cullFront ? 1 << 17 : 0) | (cullBack ? 1 << 18 : 0) | (multisample ? 1 << 19 : 0)
      | (shaderModifiesCoverage ? 1 << 20 : 0) | (scissorToBoundingBox ? 1 << 23 : 0) | (cullZeroArea ? 1 << 26 : 0)
  }
}

public enum DrawFlags1 {
  /// Sample mask `[15:0]` (all ones when unused) and render target mask `[27:16]` on arch 12 (6.9.2).
  public static func word(sampleMask: UInt32 = 0xFFFF, renderTargetMask: UInt32) -> UInt32 {
    sampleMask & 0xFFFF | (renderTargetMask & 0xFFF) << 16
  }
}

public enum DrawFlags2 {
  /// Read mask `[11:0]`, write mask `[23:12]`, no shader stencil read `[24]` and no shader depth read `[25]`
  /// (6.9.3, arch 11 to 14). A colour-only shader reads neither plane.
  public static func word(readMask: UInt32 = 0, writeMask: UInt32, noShaderStencilRead: Bool = true,
                          noShaderDepthRead: Bool = true) -> UInt32 {
    readMask & 0xFFF | (writeMask & 0xFFF) << 12 | (noShaderStencilRead ? 1 << 24 : 0)
      | (noShaderDepthRead ? 1 << 25 : 0)
  }
}

// MARK: Scissor and viewport (06 section 6.7)

/// The scissor box (registers 42 and 43): unsigned 16-bit pixel positions, the maximum inclusive.
public struct ScissorBox: Equatable, Sendable {
  public var minX: Int
  public var minY: Int
  public var maxX: Int
  public var maxY: Int
  public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }
  /// A box over `width` x `height` pixels from the origin.
  public init(width: Int, height: Int) { self.init(minX: 0, minY: 0, maxX: width - 1, maxY: height - 1) }
  /// Word 0: min x `[15:0]`, min y `[31:16]`; word 1: max x and max y likewise.
  public var words: [UInt32] {
    [UInt32(truncatingIfNeeded: minX) & 0xFFFF | UInt32(truncatingIfNeeded: minY) << 16,
     UInt32(truncatingIfNeeded: maxX) & 0xFFFF | UInt32(truncatingIfNeeded: maxY) << 16]
  }
}

/// The viewport of an arch 12 draw (registers 44 to 47, laid out as the 16-byte descriptor): the rectangle
/// as the scissor's (6.7.2) and the depth range as 32-bit floats.
public struct Viewport: Equatable, Sendable {
  public var rectangle: ScissorBox
  public var minDepth: Float
  public var maxDepth: Float
  public init(rectangle: ScissorBox, minDepth: Float = 0, maxDepth: Float = 1) {
    self.rectangle = rectangle
    self.minDepth = minDepth
    self.maxDepth = maxDepth
  }
  public var words: [UInt32] { rectangle.words + [minDepth.bitPattern, maxDepth.bitPattern] }
}

// MARK: Depth/stencil descriptor (06 section 6.8)

/// The 32-byte descriptor with depth and stencil testing off (6.8.3): every compare Always on the depth side,
/// the stencil test off with its function and operation fields zero, no depth write, no bias.
public struct DepthStencilDescriptor: Equatable, Sendable {
  public static let size = 32
  public static let alignment = 32
  public static let typeTag: UInt32 = 7

  /// 8 words. Word 0 is the type 7 alone (stencil fields zero with the test off). Word 4: depth cull enable `[22]`
  /// (default 1, the depth-clip enable), depth clamp mode `[24:23]` 1 (clamp to [0, 1], the default), depth source
  /// `[26:25]` 2 (fixed function, the default), depth function `[31:29]` Always (7). Words 1 to 3 and 5 to 7 are
  /// zero: no mask, reference, depth write or bias.
  public static var disabled: [UInt32] {
    [typeTag, 0, 0, 0, 1 << 22 | 1 << 23 | 2 << 25 | 7 << 29, 0, 0, 0]
  }
}

// MARK: Blend descriptor (09 section 9.2, 9.5)

/// A blend descriptor in Opaque mode for a blendable 8-bit target (09 example 1): 16 bytes. The array holds one per
/// render target and the position must equal the target's index (9.2.3).
public struct BlendDescriptor: Equatable, Sendable {
  public static let size = 16
  public static let alignment = 16

  public var renderTarget: Int
  public var isSRGB: Bool

  public init(renderTarget: Int = 0, isSRGB: Bool = false) {
    self.renderTarget = renderTarget
    self.isSRGB = isSRGB
  }

  /// Word 0: enable `[9]`, sRGB `[10]`, round to framebuffer precision `[11]`; no destination load, constant 0.
  /// Word 1: the replace equation for both functions (A Src, B Src, C Zero: `0x122`) and the full colour mask
  /// `[31:28]`. Word 2: mode Opaque (1) `[1:0]`, components minus one (3) `[4:3]`, render target `[19:16]`.
  /// Word 3: the memory format RGBA8 tile buffer (237) at `[19:12]` with order RGBA (0); sRGB adds bit 20.
  public var words: [UInt32] {
    [
      1 << 9 | (isSRGB ? 1 << 10 : 0) | 1 << 11,
      0xF000_0000 | 0x122 << 12 | 0x122,
      1 | 3 << 3 | UInt32(renderTarget & 0xF) << 16,
      237 << 12 | (isSRGB ? 1 << 20 : 0),
    ]
  }

  /// The BLEND_DESC register (arch 12, register 54): the array's address (16-byte aligned) ORed with the count.
  public static func register(address: UInt64, count: Int) throws(DescriptorError) -> UInt64 {
    guard address & 15 == 0, address < 1 << 56 else { throw .misaligned }
    guard count >= 1, count <= 8 else { throw .outOfRange }
    return address | UInt64(count)
  }
}

// MARK: The staging registers of RUN_IDVS2 (01 section 1.9.3, arch 12)

/// The values of the 66 staging registers a vertex/tiler run reads, as the recipe sets them. A 64-bit register
/// pair is named by its even register.
public struct IDVSState: Equatable, Sendable {
  public var vertexSRT: UInt64 = 0
  public var fragmentSRT: UInt64 = 0
  public var vertexFAU: UInt64 = 0
  public var fragmentFAU: UInt64 = 0
  public var vertexSPD: UInt64 = 0
  public var fragmentSPD: UInt64 = 0
  public var vertexTSD: UInt64 = 0
  public var fragmentTSD: UInt64 = 0
  public var globalAttributeOffset: UInt32 = 0
  /// The index (or, non-indexed, vertex) count, and the instance count (at least 1).
  public var indexCount: UInt32 = 0
  public var instanceCount: UInt32 = 1
  public var indexOffset: UInt32 = 0
  public var vertexOffset: UInt32 = 0
  public var instanceOffset: UInt32 = 0
  public var tilerContext: UInt64 = 0
  public var scissor = ScissorBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
  public var viewport = Viewport(rectangle: ScissorBox(minX: 0, minY: 0, maxX: 0, maxY: 0))
  public var indexBuffer: UInt64 = 0
  public var indexBufferSize: UInt32 = 0
  /// Bytes of generic varying storage a vertex needs, in `[15:0]`.
  public var varySize: UInt32 = 0
  public var depthStencil: UInt64 = 0
  public var blend: UInt64 = 0
  public var tilerFlags: UInt32 = 0
  public var flags0: UInt32 = 0
  public var flags1: UInt32 = 0
  public var flags2: UInt32 = 0
  public var primitiveSize: UInt32 = 0
  public var tilerFlags2: UInt32 = 0
  public var occlusionQuery: UInt64 = 0

  public init() {}

  /// The register numbers of 01 section 1.9.3's table.
  public enum Register {
    public static let vertexSRT = 0
    public static let fragmentSRT = 2
    public static let vertexFAU = 8
    public static let fragmentFAU = 10
    public static let vertexSPD = 16
    public static let fragmentSPD = 18
    public static let vertexTSD = 24
    public static let fragmentTSD = 26
    public static let globalAttributeOffset = 32
    public static let indexCount = 33
    public static let instanceCount = 34
    public static let indexOffset = 35
    public static let vertexOffset = 36
    public static let instanceOffset = 37
    public static let tilerContext = 40
    public static let scissor = 42
    public static let viewportHigh = 44
    public static let viewportLow = 46
    public static let indexBuffer = 48
    public static let indexBufferSize = 50
    public static let varySize = 51
    public static let depthStencil = 52
    public static let blend = 54
    public static let tilerFlags = 56
    public static let flags0 = 57
    public static let flags1 = 58
    public static let flags2 = 59
    public static let primitiveSize = 60
    public static let tilerFlags2 = 61
    public static let occlusionQuery = 64
    public static let count = 66
  }

  /// Write every register the run reads into `builder` (a run samples them when it issues; the stream sets all
  /// of them, since the ones a previous job left are not the recipe's to rely on, 02 section 2.1.3).
  public func load(into b: inout CSBuilder) {
    typealias R = Register
    b.move64(R.vertexSRT, vertexSRT)
    b.move64(R.fragmentSRT, fragmentSRT)
    b.move64(R.vertexFAU, vertexFAU)
    b.move64(R.fragmentFAU, fragmentFAU)
    b.move64(R.vertexSPD, vertexSPD)
    b.move64(R.fragmentSPD, fragmentSPD)
    b.move64(R.vertexTSD, vertexTSD)
    b.move64(R.fragmentTSD, fragmentTSD)
    b.move32(R.globalAttributeOffset, globalAttributeOffset)
    b.move32(R.indexCount, indexCount)
    b.move32(R.instanceCount, instanceCount)
    b.move32(R.indexOffset, indexOffset)
    b.move32(R.vertexOffset, vertexOffset)
    b.move32(R.instanceOffset, instanceOffset)
    b.move64(R.tilerContext, tilerContext)
    let s = scissor.words
    b.move32(R.scissor, s[0])
    b.move32(R.scissor + 1, s[1])
    let v = viewport.words
    for i in 0..<4 { b.move32(R.viewportHigh + i, v[i]) }
    b.move64(R.indexBuffer, indexBuffer)
    b.move32(R.indexBufferSize, indexBufferSize)
    b.move32(R.varySize, varySize)
    b.move64(R.depthStencil, depthStencil)
    b.move64(R.blend, blend)
    b.move32(R.tilerFlags, tilerFlags)
    b.move32(R.flags0, flags0)
    b.move32(R.flags1, flags1)
    b.move32(R.flags2, flags2)
    b.move32(R.primitiveSize, primitiveSize)
    b.move32(R.tilerFlags2, tilerFlags2)
    b.move64(R.occlusionQuery, occlusionQuery)
  }
}
