// SPDX-License-Identifier: BSD-3-Clause

// Images (valhall 03 sections 3.7 to 3.9, 05): the pixel format word, the linear and u-interleaved layouts with
// their address arithmetic, the texture, plane and sampler descriptors, the descriptor heap (one resource-table
// table of 32-byte descriptors, D174 section 1) and the handles shaders name them by (12b section 12b.2).
// Pure: the descriptors encode themselves into words, the layouts compute offsets, and `ImageLayout.upload` and
// `download` copy texels between a packed row-major array and the layout's memory. Compressed layouts (AFBC, AFRC,
// 64 KiB interleaved), block-compressed and YUV formats are not here.

// MARK: Pixel formats (05 section 5.2)

/// A texel format: the 22-bit pixel format word (05 section 5.2.1: component order `[7:0]`, format index
/// `[19:12]`, sRGB `[20]`) and the plane's clump format.
public struct PixelFormat: Equatable, Sendable {
  public var index: UInt32
  public var order: UInt32
  public var srgb: Bool
  public var bytesPerTexel: Int
  /// The clump format of a generic plane (03 section 3.9.2): the RAW format of the texel's size (05 section 5.4.1).
  public var clump: UInt32

  public init(index: UInt32, order: UInt32, srgb: Bool = false, bytesPerTexel: Int) {
    self.index = index
    self.order = order
    self.srgb = srgb
    self.bytesPerTexel = bytesPerTexel
    clump = PixelFormat.rawClump(bytes: bytesPerTexel)
  }

  /// The word as a texture descriptor's `[31:10]` field takes it (before the shift).
  public var word: UInt32 { order | index << 12 | (srgb ? 1 << 20 : 0) }

  /// RAW8, RAW16, RAW24, RAW32, RAW48, RAW64, RAW96, RAW128 by texel size (05 section 5.4.1).
  public static func rawClump(bytes: Int) -> UInt32 {
    switch bytes {
    case 1: return 0
    case 2: return 1
    case 3: return 8
    case 4: return 2
    case 6: return 9
    case 8: return 3
    case 12: return 10
    default: return 4
    }
  }

  /// RGBA8 UNORM, bytes R, G, B, A (index 187, order RGBA, 05 section 5.3.1).
  public static let rgba8 = PixelFormat(index: 187, order: 0, bytesPerTexel: 4)
  public static let rgba8srgb = PixelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 4)
  /// The same index with order BGRA: bytes B, G, R, A in memory.
  public static let bgra8 = PixelFormat(index: 187, order: 4, bytesPerTexel: 4)
  public static let bgra8srgb = PixelFormat(index: 187, order: 4, srgb: true, bytesPerTexel: 4)
  /// R8 UNORM (index 163, order RGB1: one component reads (R, 0, 0, 1)).
  public static let r8 = PixelFormat(index: 163, order: 16, bytesPerTexel: 1)
}

/// The 12-bit channel swizzle (05 section 5.2.4): four 3-bit selectors, R, G, B, A in `[2:0]` to `[11:9]`; 0 to 3
/// name the texel's channels, 4 constant zero, 5 constant one.
public enum TextureSwizzle {
  public static let identity: UInt32 = 0 | 1 << 3 | 2 << 6 | 3 << 9
  public static func make(r: UInt32, g: UInt32, b: UInt32, a: UInt32) -> UInt32 { r | g << 3 | b << 6 | a << 9 }
}

// MARK: Layouts (05 sections 5.5 to 5.6)

public enum ImageLayoutKind: Equatable, Sendable {
  /// Row-major (clump ordering 2).
  case linear
  /// 16 by 16 texel tiles in row-major order, the u-curve inside a tile (clump ordering 1).
  case uInterleaved

  /// The plane descriptor's clump ordering (03 section 3.9.2).
  public var clumpOrdering: UInt32 { self == .linear ? 2 : 1 }
  /// Texel interleave (03 section 3.8.2): 1 for every layout but plain linear.
  public var texelInterleave: UInt32 { self == .linear ? 0 : 1 }
}

/// One mip level of an image: where it starts in a layer, and its strides.
public struct LevelLayout: Equatable, Sendable {
  public var width: Int
  public var height: Int
  /// Byte offset from the layer's start.
  public var offset: Int
  /// Bytes from one row of texels (linear) or of tiles (u-interleaved) to the next.
  public var rowStride: Int
  /// Bytes of the whole level of one layer (05 section 5.5.4: `surface stride * depth`, depth 1).
  public var surfaceStride: Int
}

/// An image's memory: levels packed in order, all layers sharing one layout (05 section 5.5.3).
public struct ImageLayout: Equatable, Sendable {
  public static let tileTexels = 16
  public static let alignment = 64

  public var format: PixelFormat
  public var kind: ImageLayoutKind
  public var width: Int
  public var height: Int
  public var layers: Int
  public private(set) var levels: [LevelLayout]
  /// Bytes from layer k to layer k + 1: `ALIGN(offset after the last level, 64)`.
  public private(set) var arrayStride: Int
  /// The whole plane: `ALIGN(array stride * layers, 4096)`.
  public private(set) var size: Int

  public init(format: PixelFormat, kind: ImageLayoutKind, width: Int, height: Int, levels count: Int = 1, layers: Int = 1) {
    self.format = format
    self.kind = kind
    self.width = width
    self.height = height
    self.layers = layers
    levels = []
    arrayStride = 0
    size = 0
    var offset = 0
    let s = format.bytesPerTexel
    for l in 0..<count {
      let w = max(1, width >> l)
      let h = max(1, height >> l)
      let row: Int
      let surface: Int
      switch kind {
      case .linear:
        row = alignUp(w * s, ImageLayout.alignment)
        surface = alignUp(row * h, ImageLayout.alignment)
      case .uInterleaved:
        let t = ImageLayout.tileTexels
        let nx = (w + t - 1) / t
        let ny = (h + t - 1) / t
        row = alignUp(nx * t * t * s, ImageLayout.alignment)
        surface = alignUp(row * ny, ImageLayout.alignment)
      }
      offset = alignUp(offset, ImageLayout.alignment)
      levels.append(LevelLayout(width: w, height: h, offset: offset, rowStride: row, surfaceStride: surface))
      offset += surface
    }
    arrayStride = alignUp(offset, ImageLayout.alignment)
    size = alignUp(arrayStride * layers, 4096)
  }

  /// The u-curve (05 section 5.6.2): the index of the element `(x, y)` of a 16 by 16 tile, the bits from the most
  /// significant `y3, x3 ^ y3, y2, x2 ^ y2, y1, x1 ^ y1, y0, x0 ^ y0`.
  public static func uCurve(x: Int, y: Int) -> Int {
    var index = 0
    var bit = 3
    while bit >= 0 {
      let yb = (y >> bit) & 1
      let xb = (x >> bit) & 1
      index = index << 2 | yb << 1 | (xb ^ yb)
      bit -= 1
    }
    return index
  }

  /// The byte offset of texel `(x, y)` of a level of a layer from the image's base (05 sections 5.5.4 and 5.6.3).
  public func texelOffset(x: Int, y: Int, level: Int = 0, layer: Int = 0) -> Int {
    let l = levels[level]
    let base = layer * arrayStride + l.offset
    let s = format.bytesPerTexel
    switch kind {
    case .linear:
      return base + y * l.rowStride + x * s
    case .uInterleaved:
      let t = ImageLayout.tileTexels
      let tileBytes = t * t * s
      return base + (y / t) * l.rowStride + (x / t) * tileBytes + ImageLayout.uCurve(x: x % t, y: y % t) * s
    }
  }

  /// Copy a tightly packed, row-major array of texels (width times height times bytes per texel of the level) into
  /// the image's memory.
  public func upload(_ texels: [UInt8], level: Int = 0, layer: Int = 0, into memory: inout [UInt8], at base: Int = 0) {
    let l = levels[level]
    let s = format.bytesPerTexel
    for y in 0..<l.height {
      for x in 0..<l.width {
        let from = (y * l.width + x) * s
        let to = base + texelOffset(x: x, y: y, level: level, layer: layer)
        for b in 0..<s { memory[to + b] = texels[from + b] }
      }
    }
  }

  /// The inverse of `upload`: the level's texels, tightly packed.
  public func download(level: Int = 0, layer: Int = 0, from memory: [UInt8], at base: Int = 0) -> [UInt8] {
    let l = levels[level]
    let s = format.bytesPerTexel
    var out = [UInt8](repeating: 0, count: l.width * l.height * s)
    for y in 0..<l.height {
      for x in 0..<l.width {
        let from = base + texelOffset(x: x, y: y, level: level, layer: layer)
        let to = (y * l.width + x) * s
        for b in 0..<s { out[to + b] = memory[from + b] }
      }
    }
    return out
  }

  /// The plane descriptors of the image's views, in the order a texture descriptor's `Surfaces` array takes them:
  /// the layer slowest, then the level (03 section 3.8.3), one plane each.
  public func planes(base: UInt64) -> [PlaneDescriptor] {
    var out: [PlaneDescriptor] = []
    for layer in 0..<layers {
      for l in 0..<levels.count {
        let lv = levels[l]
        out.append(
          PlaneDescriptor(
            address: base + UInt64(layer * arrayStride + lv.offset), size: UInt64(lv.surfaceStride), rowStride: lv.rowStride,
            sliceStride: 0, width: lv.width, height: lv.height, kind: kind, format: format))
      }
    }
    return out
  }
}

// MARK: Plane descriptor (03 section 3.9)

/// A generic plane (03 section 3.9.2): one mip level of one layer.
public struct PlaneDescriptor: Equatable, Sendable {
  public static let size = 32
  public static let typeTag: UInt32 = 10
  public static let genericType: UInt32 = 1

  public var address: UInt64
  public var size: UInt64
  public var rowStride: Int
  public var sliceStride: UInt64
  public var width: Int
  public var height: Int
  public var kind: ImageLayoutKind
  public var format: PixelFormat

  public init(address: UInt64, size: UInt64, rowStride: Int, sliceStride: UInt64 = 0, width: Int, height: Int,
              kind: ImageLayoutKind, format: PixelFormat) {
    self.address = address
    self.size = size
    self.rowStride = rowStride
    self.sliceStride = sliceStride
    self.width = width
    self.height = height
    self.kind = kind
    self.format = format
  }

  /// Word 0: type 10 `[3:0]`, plane type Generic `[7:4]`, clump ordering `[11:8]`, clump format `[31:24]`. Word 1:
  /// the size's low half; words 2 and 3: the 48-bit pointer, with the size's bits 47:32 in word 3 `[31:16]`. Word
  /// 4: the row stride `[26:0]` and the slice stride's bits 36:32 `[31:27]`. Word 5: zero. Word 6: the slice
  /// stride's low half. Word 7: width minus one `[15:0]`, height minus one `[31:16]`.
  public func words() throws(DescriptorError) -> [UInt32] {
    guard address < 1 << 48, size < 1 << 48, rowStride >= 0, rowStride < 1 << 27, sliceStride < 1 << 37,
      width >= 1, height >= 1, width <= 65536, height <= 65536
    else { throw .outOfRange }
    return [
      PlaneDescriptor.typeTag | PlaneDescriptor.genericType << 4 | kind.clumpOrdering << 8 | format.clump << 24,
      UInt32(truncatingIfNeeded: size),
      UInt32(truncatingIfNeeded: address),
      UInt32(truncatingIfNeeded: address >> 32) & 0xFFFF | UInt32(truncatingIfNeeded: size >> 32) << 16,
      UInt32(rowStride) | UInt32(truncatingIfNeeded: sliceStride >> 32) << 27,
      0,
      UInt32(truncatingIfNeeded: sliceStride),
      UInt32(width - 1) | UInt32(height - 1) << 16,
    ]
  }

  /// A null plane: valid padding (03 section 3.9).
  public static let null: [UInt32] = [typeTag, 0, 0, 0, 0, 0, 0, 0]
}

// MARK: Texture descriptor (03 section 3.8)

public struct TextureDescriptor: Equatable, Sendable {
  public static let size = 32
  public static let typeTag: UInt32 = 2

  public enum Dimension: UInt32, Sendable {
    case cube = 0
    case d1 = 1
    case d2 = 2
    case d3 = 3
  }

  public var dimension: Dimension
  public var format: PixelFormat
  public var width: Int
  public var height: Int
  public var swizzle: UInt32
  public var layout: ImageLayoutKind
  /// Levels in the view (with plane descriptors).
  public var levels: Int
  /// The array's size in layers, and a 3D view's depth.
  public var layers: Int
  public var depth: Int
  public var sampleCountLog2: UInt32
  /// The GPU address of the plane-descriptor array (32-byte aligned).
  public var surfaces: UInt64

  public init(dimension: Dimension = .d2, format: PixelFormat, width: Int, height: Int, swizzle: UInt32 = TextureSwizzle.identity,
              layout: ImageLayoutKind, levels: Int = 1, layers: Int = 1, depth: Int = 1, sampleCountLog2: UInt32 = 0,
              surfaces: UInt64) {
    self.dimension = dimension
    self.format = format
    self.width = width
    self.height = height
    self.swizzle = swizzle
    self.layout = layout
    self.levels = levels
    self.layers = layers
    self.depth = depth
    self.sampleCountLog2 = sampleCountLog2
    self.surfaces = surfaces
  }

  /// The view of a whole image whose plane array is at `surfaces`.
  public init(image: ImageLayout, surfaces: UInt64, swizzle: UInt32 = TextureSwizzle.identity) {
    self.init(
      format: image.format, width: image.width, height: image.height, swizzle: swizzle, layout: image.kind,
      levels: image.levels.count, layers: image.layers, surfaces: surfaces)
  }

  /// Eight words. Word 0: type 2, dimension `[6:4]`, format `[31:10]`. Word 1: width minus one `[15:0]`, height
  /// minus one `[31:16]`. Word 2: swizzle `[11:0]`, texel interleave `[12]`, levels minus one `[20:16]`. Word 3: minimum
  /// LOD `[12:0]` (zero), sample count log2 `[15:13]`, maximum LOD `[28:16]` (the last level, 8 fractional bits).
  /// Words 4 and 5: the plane array. Word 6: array size minus one. Word 7: depth minus one.
  public func words() throws(DescriptorError) -> [UInt32] {
    guard width >= 1, height >= 1, width <= 65536, height <= 65536, levels >= 1, levels <= 32, layers >= 1, layers <= 65536,
      depth >= 1, depth <= 65536, sampleCountLog2 <= 7
    else { throw .outOfRange }
    guard surfaces & 31 == 0 else { throw .misaligned }
    return [
      TextureDescriptor.typeTag | dimension.rawValue << 4 | format.word << 10,
      UInt32(width - 1) | UInt32(height - 1) << 16,
      swizzle & 0xFFF | layout.texelInterleave << 12 | UInt32(levels - 1) << 16,
      sampleCountLog2 << 13 | UInt32((levels - 1) << 8) << 16,
      UInt32(truncatingIfNeeded: surfaces), UInt32(truncatingIfNeeded: surfaces >> 32),
      UInt32(layers - 1),
      UInt32(depth - 1),
    ]
  }
}

// MARK: Sampler descriptor (03 section 3.7)

public struct SamplerDescriptor: Equatable, Sendable {
  public static let size = 32
  public static let typeTag: UInt32 = 1

  /// The wrap modes (03 section 3.7).
  public enum Wrap: UInt32, Sendable {
    case `repeat` = 8
    case clampToEdge = 9
    case clampToBorder = 11
    case mirroredRepeat = 12
    case mirroredClampToEdge = 13
    case mirroredClampToBorder = 15
  }
  public enum Filter: Sendable { case nearest, linear }
  /// Mipmap mode `[31:30]`: 0 Nearest (the nearest level), 1 None (the base level), 2 performance trilinear, 3 trilinear.
  public enum MipmapMode: UInt32, Sendable {
    case nearest = 0
    case none = 1
    case performanceTrilinear = 2
    case trilinear = 3
  }

  public var wrapS: Wrap
  public var wrapT: Wrap
  public var wrapR: Wrap
  public var minFilter: Filter
  public var magFilter: Filter
  public var mipmap: MipmapMode
  public var normalizedCoordinates: Bool
  /// Levels of detail in 8.8 fixed point (a Float of levels is `lod * 256`), and the bias.
  public var minLOD: UInt32
  public var maxLOD: UInt32
  public var lodBias: Int16
  /// The border colour in the register form the shader receives (32-bit floats for float and normalised formats).
  public var border: [UInt32]

  public init(
    wrapS: Wrap = .clampToEdge, wrapT: Wrap = .clampToEdge, wrapR: Wrap = .clampToEdge, minFilter: Filter = .linear,
    magFilter: Filter = .linear, mipmap: MipmapMode = .none, normalizedCoordinates: Bool = true, minLOD: UInt32 = 0,
    maxLOD: UInt32 = 0x1FFF, lodBias: Int16 = 0, border: [UInt32] = [0, 0, 0, 0]
  ) {
    self.wrapS = wrapS
    self.wrapT = wrapT
    self.wrapR = wrapR
    self.minFilter = minFilter
    self.magFilter = magFilter
    self.mipmap = mipmap
    self.normalizedCoordinates = normalizedCoordinates
    self.minLOD = minLOD
    self.maxLOD = maxLOD
    self.lodBias = lodBias
    self.border = border
  }

  /// Nearest filtering and clamp to edge, no mipmaps: what an exact comparison needs.
  public static let nearest = SamplerDescriptor(minFilter: .nearest, magFilter: .nearest)

  /// The border colour of four floats (the normalised and float formats' form).
  public static func borderWords(r: Float, g: Float, b: Float, a: Float) -> [UInt32] {
    [r.bitPattern, g.bitPattern, b.bitPattern, a.bitPattern]
  }

  /// Eight words. Word 0: type 1, wrap R `[11:8]`, T `[15:12]`, S `[19:16]`, round to nearest even `[21]`
  /// (cleared when both filters are nearest: 03 section 3.7.1), seamless cube map `[23]`, normalised coordinates
  /// `[25]`, clamp integer array indices `[26]`, minify nearest `[27]`, magnify nearest `[28]`, mipmap mode
  /// `[31:30]`. Word 1: minimum LOD `[12:0]`, compare function (never, 0) `[15:13]`, maximum LOD `[28:16]`. Word 2:
  /// the LOD bias `[15:0]`, maximum anisotropy minus one (0) `[20:16]`, the LOD algorithm (isotropic, 0) `[25:24]`.
  /// Word 3 is zero; words 4 to 7 are the border colour.
  public func words() throws(DescriptorError) -> [UInt32] {
    guard minLOD < 1 << 13, maxLOD < 1 << 13, border.count == 4 else { throw .outOfRange }
    let bothNearest = minFilter == .nearest && magFilter == .nearest
    let w0 =
      SamplerDescriptor.typeTag | wrapR.rawValue << 8 | wrapT.rawValue << 12 | wrapS.rawValue << 16
      | (bothNearest ? 0 : 1 << 21) | 1 << 23 | (normalizedCoordinates ? 1 << 25 : 0) | 1 << 26
      | (minFilter == .nearest ? 1 << 27 : 0) | (magFilter == .nearest ? 1 << 28 : 0) | mipmap.rawValue << 30
    return [
      w0, minLOD | maxLOD << 16, UInt32(UInt16(bitPattern: lodBias)), 0,
      border[0], border[1], border[2], border[3],
    ]
  }
}

// MARK: The descriptor heap (03 section 3.2, D174 section 1)

/// The one bindless heap of a device: a resource-table table of 32-byte descriptors, textures and samplers by
/// index. A shader names an entry by a handle: `table << 24 | index` (03 section 3.2.2).
public struct DescriptorHeap: Equatable, Sendable {
  /// The table number the heap has in the resource table; table 0 is the driver's (03 section 3.2.4).
  public static let tableNumber = 1
  public static let descriptorBytes = 32
  /// The resource table the pass is given: the entries of tables 0 to 3 (the count is a multiple of 4).
  public static let tableEntries = 4

  public private(set) var words: [UInt32] = []

  public init() {}

  public var count: Int { words.count / 8 }
  public var byteSize: Int { words.count * 4 }

  /// Add a descriptor (eight words): its index in the heap.
  @discardableResult
  public mutating func add(_ descriptor: [UInt32]) -> Int {
    precondition(descriptor.count == 8, "a descriptor is 32 bytes")
    words.append(contentsOf: descriptor)
    return count - 1
  }

  /// The heap's bytes, little-endian.
  public var bytes: [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(words.count * 4)
    for w in words {
      for b in 0..<4 { out.append(UInt8(truncatingIfNeeded: w >> UInt32(8 * b))) }
    }
    return out
  }

  /// The handle of entry `index` of the heap's table.
  public static func handle(index: Int) -> UInt32 { ResourceTable.handle(table: tableNumber, index: index) }

  /// The resource table for a pass: the heap as table 1, the rest unused. The entry is 16 bytes at the table's
  /// 64-byte aligned address.
  public static func resourceTable(heapAddress: UInt64, heapBytes: Int) throws(DescriptorError) -> [UInt8] {
    var entries = [ResourceTableEntry](repeating: .unused, count: tableEntries)
    entries[tableNumber] = ResourceTableEntry(address: heapAddress, containsDescriptors: true, size: UInt64(heapBytes))
    return try ResourceTable.encode(entries)
  }
}

// MARK: Texture and sampler handles (12b section 12b.2)

public enum TextureHandle {
  /// The wide form of `H` (12b.2.1): word 0 the sampler's handle, word 1 the texture's.
  public static func wide(sampler: UInt32, texture: UInt32) -> UInt64 { UInt64(sampler) | UInt64(texture) << 32 }

  /// The packed form of `H`, word 0: texture table `[31:27]`, texture index `[26:16]`, sampler table `[15:11]`,
  /// sampler index `[10:0]`. Only for tables 0 to 11 and indices below 1024 (12b.2.1); nil otherwise. The narrow
  /// word, word 1 of `H`, is zero.
  public static func packed(textureTable: Int, textureIndex: Int, samplerTable: Int, samplerIndex: Int) -> UInt64? {
    guard textureTable >= 0, textureTable <= 11, samplerTable >= 0, samplerTable <= 11, textureIndex >= 0, textureIndex < 1024,
      samplerIndex >= 0, samplerIndex < 1024
    else { return nil }
    let w0 = UInt32(textureTable) << 27 | UInt32(textureIndex) << 16 | UInt32(samplerTable) << 11 | UInt32(samplerIndex)
    return UInt64(w0)
  }
}
