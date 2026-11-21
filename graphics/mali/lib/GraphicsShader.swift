// SPDX-License-Identifier: BSD-3-Clause

// What the compiler hands the driver for a vertex or a fragment shader, alongside `ComputeShader`: data only,
// so MaliCore needs no compiler to build a draw. The Valhall backend (graphics/compiler/valhall) fills it.
//
// The graphics ABI the backend uses (valhall 12c and 14; every choice that 14 leaves to the compiler and the
// driver is made here, in this one place, and the backend's header points at it):
//
// Vertex shader (arch 12: one program for both IDVS passes, which tests `shader_output`, 12c.4.2)
//  - Preloaded: r59 the internal vertex id (the vertex's slot in the hardware vertex buffer, always), r60 the
//    API vertex index (bit 12), r61 the instance index (bit 13): `preloadMask` has the bits the code reads.
//  - The shader stores the position in window space, as 14.3.3 says: x, y, z and the reciprocal of w,
//    where the shader does the divide and the viewport transform from FAU words the driver fills
//    (`GraphicsFauLayout.viewportWord`, `ViewportTransform`).
//  - Generic varyings: location n is stored at byte `VaryingLayout.offset(location: n)` of the vertex's generic
//    block (buffer index 1 of table 61), four floats' room each, so the fragment shader needs nothing of the
//    vertex shader to find a varying. The draw's `VARY_SIZE` is `varyingBytes`. A varying the fragment
//    shader declares NoPerspective is stored multiplied by the position's reciprocal w (14.3.6), chosen by
//    `GraphicsFauLayout.nonPerspectiveWord` (a bit a location) when the vertex shader was compiled without
//    knowing the fragment shader's.
//  - Vertex attributes (Location inputs) are read with LD_ATTR_IMM through table 0, index = location (14.8).
//
// Fragment shader
//  - Preloaded: r60 the coverage (always: ATEST and BLEND read it), r59 the pixel position and r58 the primitive
//    flags (facing), r61 the sample and centroid ids (centroid inputs).
//  - A Location input is read with LD_VAR_BUF_IMM at `VaryingLayout.offset`; colour output n is BLEND to render
//    target n, with the special blend descriptor entry n (14.4.7, 12c.6.4).
//  - Register class 64 (valhall 14.1.2: the class 32 statement for r60 is reconciled, but class 64 is the one
//    the board ran).
//
// FAU block (both): a vertex shader's holds the viewport (six words: scale x, offset x, scale y, offset y,
// scale z, offset z: a scale and its offset share a 64-bit slot, so one FMA reads both), then the mask of
// non-perspective varyings when it reads one, then the API's push constants from the next slot; a fragment
// shader's holds the push constants from slot 0. The push constants of both stages are the same bytes.

/// The window transform of a viewport (valhall 14.3.3): `x_window = x_ndc * scaleX + offsetX`, and the same for
/// y and z.
public struct ViewportTransform: Equatable, Sendable {
  public var scale: (x: Float, y: Float, z: Float)
  public var offset: (x: Float, y: Float, z: Float)

  public init(scale: (x: Float, y: Float, z: Float), offset: (x: Float, y: Float, z: Float)) {
    self.scale = scale
    self.offset = offset
  }

  /// The transform of the Vulkan viewport `(x, y, width, height)` and depth range, for a clip volume whose depth
  /// runs from 0 to 1 (14.3.3: `sx = width / 2`, `ox = x + width / 2`, `sz = max - min`, `oz = min`).
  public init(x: Float = 0, y: Float = 0, width: Float, height: Float, minDepth: Float = 0, maxDepth: Float = 1) {
    scale = (width / 2, height / 2, maxDepth - minDepth)
    offset = (x + width / 2, y + height / 2, minDepth)
  }

  public static func == (a: ViewportTransform, b: ViewportTransform) -> Bool {
    a.scale == b.scale && a.offset == b.offset
  }
}

/// Where a graphics shader reads its inputs in the FAU block: data the compiler fills and the driver reads
/// (the order of the block is in this file's header).
public struct GraphicsFauLayout: Equatable, Sendable {
  /// The first of six words: scale x, offset x, scale y, offset y, scale z, offset z; -1 for none (a fragment shader).
  public var viewportWord = -1
  /// The word whose bit n says location n's varying is stored multiplied by w; -1 for none.
  public var nonPerspectiveWord = -1
  /// The word of the API push constants' first word, how many words the shader reads, and the block's size in words
  /// (a whole number of slots).
  public var pushWord = 0
  public var pushWords = 0
  public var words = 0

  public init() {}

  /// The slots of the block.
  public var slots: Int { (words + 1) / 2 }

  /// The block for a draw, as the 64-bit words `fauWords / 2` of the run state's FAU register address.
  public func block(viewport: ViewportTransform? = nil, nonPerspectiveMask: UInt32 = 0, push: [UInt32] = []) -> [UInt64] {
    var w = [UInt32](repeating: 0, count: slots * 2)
    if viewportWord >= 0, let v = viewport {
      w[viewportWord] = v.scale.x.bitPattern
      w[viewportWord + 1] = v.offset.x.bitPattern
      w[viewportWord + 2] = v.scale.y.bitPattern
      w[viewportWord + 3] = v.offset.y.bitPattern
      w[viewportWord + 4] = v.scale.z.bitPattern
      w[viewportWord + 5] = v.offset.z.bitPattern
    }
    if nonPerspectiveWord >= 0 { w[nonPerspectiveWord] = nonPerspectiveMask }
    var i = 0
    while i < pushWords {
      w[pushWord + i] = i < push.count ? push[i] : 0
      i += 1
    }
    var out: [UInt64] = []
    var s = 0
    while s < slots {
      out.append(UInt64(w[s * 2]) | UInt64(w[s * 2 + 1]) << 32)
      s += 1
    }
    return out
  }
}

/// How generic varyings sit in a vertex's generic block: one 16-byte slot a location (valhall 14.3.6 leaves the
/// layout to the two stages' compiler; this one needs no link between them).
public enum VaryingLayout {
  public static let slotBytes = 16
  /// LD_VAR_BUF_IMM reaches byte 2047 (12c.5.3), so locations 0 to 127.
  public static let maxLocations = 128
  public static func offset(location: Int) -> Int { location * slotBytes }
}

/// A compiled vertex shader.
public struct VertexShader: Equatable, Sendable {
  /// The instructions, 64-bit words; the first is the entry. Every path ends in `end`.
  public var code: [UInt64]
  public var registerClass: RegisterClass
  /// Bit n: r(48 + n) is preloaded (valhall 14.3.1).
  public var preloadMask: UInt16
  public var layout: GraphicsFauLayout
  /// The per-vertex bytes of generic varyings: the low 16 bits of `VARY_SIZE`.
  public var varyingBytes: UInt32
  /// The Location outputs, ascending.
  public var outputLocations: [Int]
  /// The Location inputs: the vertex attributes, by table 0 index.
  public var attributeLocations: [Int]
  /// The shader writes PointSize and the code stores it (the position record then has the extended format).
  public var storesPointSize: Bool
  public var stackBytes: UInt32

  /// 32-bit words of the FAU block, as `GraphicsFauLayout.words`.
  public var fauWords: UInt32 { UInt32(layout.words) }

  public init(
    code: [UInt64], registerClass: RegisterClass, preloadMask: UInt16, layout: GraphicsFauLayout, varyingBytes: UInt32,
    outputLocations: [Int], attributeLocations: [Int], storesPointSize: Bool, stackBytes: UInt32 = 0
  ) {
    self.code = code
    self.registerClass = registerClass
    self.preloadMask = preloadMask
    self.layout = layout
    self.varyingBytes = varyingBytes
    self.outputLocations = outputLocations
    self.attributeLocations = attributeLocations
    self.storesPointSize = storesPointSize
    self.stackBytes = stackBytes
  }
}

/// A compiled fragment shader.
public struct FragmentShader: Equatable, Sendable {
  public var code: [UInt64]
  public var registerClass: RegisterClass
  /// Bit n: r(48 + n) is preloaded (valhall 14.4.1).
  public var preloadMask: UInt16
  public var layout: GraphicsFauLayout
  /// The render targets the shader writes (its colour output locations), ascending; one BLEND each.
  public var colourTargets: [Int]
  /// The Location inputs, ascending.
  public var inputLocations: [Int]
  /// Bit n: input location n is declared NoPerspective: a vertex shader compiled for this one stores it times w.
  public var nonPerspectiveMask: UInt32
  /// The shader can discard (OpKill).
  public var discards: Bool
  /// The shader asked for early fragment tests.
  public var earlyFragmentTests: Bool
  public var stackBytes: UInt32

  public var fauWords: UInt32 { UInt32(layout.words) }

  public init(
    code: [UInt64], registerClass: RegisterClass, preloadMask: UInt16, layout: GraphicsFauLayout, colourTargets: [Int],
    inputLocations: [Int], nonPerspectiveMask: UInt32, discards: Bool, earlyFragmentTests: Bool, stackBytes: UInt32 = 0
  ) {
    self.code = code
    self.registerClass = registerClass
    self.preloadMask = preloadMask
    self.layout = layout
    self.colourTargets = colourTargets
    self.inputLocations = inputLocations
    self.nonPerspectiveMask = nonPerspectiveMask
    self.discards = discards
    self.earlyFragmentTests = earlyFragmentTests
    self.stackBytes = stackBytes
  }
}
