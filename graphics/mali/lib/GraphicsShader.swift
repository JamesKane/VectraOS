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
// Textures and samplers (valhall 03 and 12b; D174 section 1): there is one bindless heap, resource-table table
// `DescriptorHeap.tableNumber` (1), whose 32-byte descriptors are textures and samplers by index. A SPIR-V image or
// sampler is an element of a binding (set, binding), an array of one for a binding that is not an array. The
// driver picks, for each binding the shader names, the heap index of its element 0 and puts the handle
// (`table << 24 | index`) in the FAU word `ImageBinding.word` (`GraphicsFauLayout.imageBindings`, one word each,
// from word 0 of a fragment shader's block: `pushWord` follows them). A sample or a fetch computes both handles as
// the word plus the array index, and names them in the wide form of the handle source `H` (12b.2.1: word 0 the
// sampler, word 1 the texture), so the heap may be any size. A fetch of an image with no sampler names the
// driver's dummy sampler: `dummySamplerWord` holds its handle (12b.2.1: a valid sampler in every stage). Vertex
// shaders do not sample. Implicit levels run with helper lanes alive: the shaders have no `discard` flow, and a
// demote is a DISCARD that flags the lane.
//
// FAU block (both): a vertex shader's holds the viewport (six words: scale x, offset x, scale y, offset y,
// scale z, offset z: a scale and its offset share a 64-bit slot, so one FMA reads both), then the mask of
// non-perspective varyings when it reads one, then the API's push constants from the next slot; a fragment
// shader's holds the push constants from slot 0, or from slot 2 when it may call a blend shader (the first four words are the blend
// constants, valhall 09.9.5: `GraphicsFauLayout.blendConstantWord`). The push constants of both stages are the same bytes.

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

/// A (set, binding) of an image or a sampler and the FAU word its element 0's heap handle is in.
public struct ImageBinding: Equatable, Sendable {
  public var set: Int
  public var binding: Int
  public var word: Int
  public init(set: Int, binding: Int, word: Int) {
    self.set = set
    self.binding = binding
    self.word = word
  }
}

/// Where a graphics shader reads its inputs in the FAU block: data the compiler fills and the driver reads
/// (the order of the block is in this file's header).
public struct GraphicsFauLayout: Equatable, Sendable {
  /// The first of six words: scale x, offset x, scale y, offset y, scale z, offset z; -1 for none (a fragment shader).
  public var viewportWord = -1
  /// The word whose bit n says location n's varying is stored multiplied by w; -1 for none.
  public var nonPerspectiveWord = -1
  /// The words holding the draw's first vertex and base instance (signed; 14.7.4), for the BaseVertex and BaseInstance
  /// built-ins and InstanceIndex (r61 counts from zero); -1 for none.
  public var baseVertexWord = -1
  public var baseInstanceWord = -1
  /// The first of four words, the blend constants (red, green, blue, alpha, as floats) a blend shader reads (09 section 9.9.5: the
  /// fragment FAU's slots 0 and 1); -1 for none. A fragment shader that may call a blend shader reserves them.
  public var blendConstantWord = -1
  /// The FAU words holding the heap handle of each image or sampler binding the shader names, in ascending (set,
  /// binding) order, and the word of the dummy sampler a fetch of a plain image names (-1: none).
  public var imageBindings: [ImageBinding] = []
  public var dummySamplerWord = -1
  /// The word of the API push constants' first word, how many words the shader reads, and the block's size in words
  /// (a whole number of slots).
  public var pushWord = 0
  public var pushWords = 0
  public var words = 0

  public init() {}

  /// The slots of the block.
  public var slots: Int { (words + 1) / 2 }

  /// The block for a draw, as the 64-bit words `fauWords / 2` of the run state's FAU register address.
  /// `images` gives the heap handle of each binding's element 0 (a binding not listed has handle 0), `dummySampler` the
  /// handle of the sampler a fetch of a plain image names.
  public func block(
    viewport: ViewportTransform? = nil, nonPerspectiveMask: UInt32 = 0, push: [UInt32] = [],
    images: [(set: Int, binding: Int, handle: UInt32)] = [], dummySampler: UInt32 = 0, baseVertex: Int32 = 0,
    baseInstance: Int32 = 0, blendConstants: [Float] = []
  ) -> [UInt64] {
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
    if baseVertexWord >= 0 { w[baseVertexWord] = UInt32(bitPattern: baseVertex) }
    if baseInstanceWord >= 0 { w[baseInstanceWord] = UInt32(bitPattern: baseInstance) }
    if blendConstantWord >= 0 {
      for i in 0..<4 { w[blendConstantWord + i] = i < blendConstants.count ? blendConstants[i].bitPattern : 0 }
    }
    for b in imageBindings {
      for g in images where g.set == b.set && g.binding == b.binding { w[b.word] = g.handle }
    }
    if dummySamplerWord >= 0 { w[dummySamplerWord] = dummySampler }
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
  /// The shader reads DrawIndex: the draw enables its draw-id register (r62 holds a value only then, 14.3.1).
  public var readsDrawIndex = false
  /// The shader stores a layer or a viewport index (the attribute section, 12c.4.1): the position FIFO's format is the
  /// extended one (06 6.6.1), and the viewport index is in the same u8 field as the layer, `storesViewportIndex` says which.
  public var extendedRecord = false
  public var storesViewportIndex = false

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
  /// The shader writes FragDepth (ZS_EMIT, so a late depth test, 12c.6.2) or a sample mask.
  public var writesDepth = false
  public var writesSampleMask = false
  /// The shader writes a second colour output (Index 1 of location 0: dual-source blending), which a blend shader reads (09 section 9.9.2).
  public var writesSecondOutput = false
  /// The shader reads the sample id or position: the draw runs per sample.
  public var perSampleShading = false
  /// The shader reads SamplePosition: the `sample` special FAU entry must name the position table (14.7.2).
  public var readsSamplePositions = false

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
