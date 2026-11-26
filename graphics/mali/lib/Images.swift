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
public struct TexelFormat: Equatable, Sendable {
  public var index: UInt32
  public var order: UInt32
  public var srgb: Bool
  /// Bytes of a clump: a texel, or a compression block.
  public var bytesPerTexel: Int
  /// The clump format of a generic plane (03 section 3.9.2): the RAW format of the texel's size (05 section 5.4.1), or the
  /// format's own code (depth, stencil, ETC2, BC).
  public var clump: UInt32
  /// The texels a clump covers: 1 by 1, or a compression block (05 section 5.3.4).
  public var blockWidth: Int
  public var blockHeight: Int
  /// An ASTC format's plane fields (03 section 3.9.4): the plane is of type ASTC 2D, not Generic.
  public var astc: ASTCPlaneFields?

  public init(index: UInt32, order: UInt32, srgb: Bool = false, bytesPerTexel: Int, clump: UInt32? = nil, blockWidth: Int = 1,
              blockHeight: Int = 1, astc: ASTCPlaneFields? = nil) {
    self.index = index
    self.order = order
    self.srgb = srgb
    self.bytesPerTexel = bytesPerTexel
    self.clump = clump ?? TexelFormat.rawClump(bytes: bytesPerTexel)
    self.blockWidth = blockWidth
    self.blockHeight = blockHeight
    self.astc = astc
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
  public static let rgba8 = TexelFormat(index: 187, order: 0, bytesPerTexel: 4)
  public static let rgba8srgb = TexelFormat(index: 187, order: 0, srgb: true, bytesPerTexel: 4)
  /// The same index with order BGRA: bytes B, G, R, A in memory.
  public static let bgra8 = TexelFormat(index: 187, order: 4, bytesPerTexel: 4)
  public static let bgra8srgb = TexelFormat(index: 187, order: 4, srgb: true, bytesPerTexel: 4)
  /// R8 UNORM (index 163, order RGB1: one component reads (R, 0, 0, 1)).
  public static let r8 = TexelFormat(index: 163, order: 16, bytesPerTexel: 1)
  /// The one-channel integer formats (05 section 5.2.2: group UINT 128 or SINT 192, one component, slot 3 for 8 bits and 4 for
  /// 16): R8UI 131, R8I 195, R16UI 132, R16I 196.
  public static let r8ui = TexelFormat(index: 131, order: 16, bytesPerTexel: 1)
  public static let r8i = TexelFormat(index: 195, order: 16, bytesPerTexel: 1)
  public static let r16ui = TexelFormat(index: 132, order: 16, bytesPerTexel: 2)
  public static let r16i = TexelFormat(index: 196, order: 16, bytesPerTexel: 2)
}

/// An ASTC 2D plane's fields (03 section 3.9.4): the block's size in texels, and whether it decodes to 16-bit floats (the linear
/// formats) or to 8 bits (sRGB, always).
public struct ASTCPlaneFields: Equatable, Sendable {
  public var blockWidth: Int
  public var blockHeight: Int
  public var wide: Bool
  public init(blockWidth: Int, blockHeight: Int, wide: Bool) {
    self.blockWidth = blockWidth
    self.blockHeight = blockHeight
    self.wide = wide
  }

  /// The dimension codes of the 2D block (03 section 3.9.4): 4, 5, 6, 8, 10, 12 are 0, 1, 2, 4, 6, 7.
  public static func code(_ texels: Int) -> UInt32? {
    switch texels {
    case 4: 0
    case 5: 1
    case 6: 2
    case 8: 4
    case 10: 6
    case 12: 7
    default: nil
    }
  }
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
  /// 64 KiB tiles of elements in row-major order, 16 by 16-element blocks stored linearly inside a tile and the u-curve inside a
  /// block (05 section 5.7; clump ordering 8): the layout whose tiles a sparse image binds one at a time.
  case interleaved64K
  /// AFBC (05 section 5.11): 16 x 16 superblocks, linear headers, the sparse body; a level is its header area (16 bytes a
  /// superblock), the body at the header area rounded up to 128 bytes, and a slot of the uncompressed superblock's bytes for each.
  /// Written by a pass and read by the texture unit only: no copy kernel, storage image or CPU touches its bytes.
  case afbc

  /// The plane descriptor's clump ordering (03 section 3.9.2); AFBC's plane has none.
  public var clumpOrdering: UInt32 {
    switch self {
    case .linear: 2
    case .uInterleaved: 1
    case .interleaved64K: 8
    case .afbc: 0
    }
  }
  /// The render target's block format (08 section 8.4.3), for the layouts a pass writes.
  public var blockFormat: UInt32 {
    switch self {
    case .interleaved64K: 8
    case .afbc: 12
    default: 2
    }
  }
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
  /// Bytes of one slice of the level (05 section 5.5.4: the surface stride).
  public var surfaceStride: Int
  /// Slices in the level: the image's depth, halved per level (1 for anything but a 3D image).
  public var depth: Int = 1
  /// Sample planes of the level (05 section 5.5.3): a multisampled image's samples, `surface stride` apart.
  public var samples: Int = 1
  /// AFBC (05 section 5.11.6): the header area's bytes, and the body's offset from the level's start; `rowStride` is then the header
  /// row stride and `surfaceStride` the level's bytes, header area through body.
  public var headerBytes = 0
  public var bodyOffset = 0
  /// Bytes of the whole level of one layer: `surface stride * depth * samples`.
  public var levelSize: Int { surfaceStride * depth * samples }
}

/// An image's memory: levels packed in order, all layers sharing one layout (05 section 5.5.3).
public struct ImageLayout: Equatable, Sendable {
  public static let tileTexels = 16
  public static let alignment = 64
  /// The bytes of a 64 KiB tile (05 section 5.7.1).
  public static let tileBytes64K = 65536

  /// A 64 KiB tile's width and height in elements for an element of `bytes` (05 section 5.7.1): 256 x 256 for 1 byte down to 64 x 64
  /// for 16, nil for a size the layout doesn't take.
  public static func tile64K(bytes: Int) -> (width: Int, height: Int)? {
    switch bytes {
    case 1: (256, 256)
    case 2: (256, 128)
    case 4: (128, 128)
    case 8: (128, 64)
    case 16: (64, 64)
    default: nil
    }
  }

  /// The offset of element `(x, y)` from its slice's start in the 64 KiB layout (05 section 5.7.2): its tile's row and column, its
  /// 16 x 16 block in the tile (the blocks in rows of `tile width / 16`), and the u-curve in the block.
  public static func offset64K(x: Int, y: Int, bytes s: Int, rowStride: Int) -> Int {
    let tile = tile64K(bytes: s) ?? (64, 64)
    let ix = x % tile.width, iy = y % tile.height
    let block = (iy / 16) * (tile.width / 16) + ix / 16
    return (y / tile.height) * rowStride + (x / tile.width) * tileBytes64K + block * 256 * s + uCurve(x: ix % 16, y: iy % 16) * s
  }

  public var format: TexelFormat
  public var kind: ImageLayoutKind
  public var width: Int
  public var height: Int
  /// Slices of a 3D image's first level; 1 for any other.
  public var depth: Int
  public var layers: Int
  /// Samples of each texel: a multisampled image has a sample plane each (05 section 5.5.3), never 3D and of one level.
  public var samples: Int
  public private(set) var levels: [LevelLayout]
  /// Bytes from layer k to layer k + 1: `ALIGN(offset after the last level, 64)`.
  public private(set) var arrayStride: Int
  /// The whole plane: `ALIGN(array stride * layers, 4096)`.
  public private(set) var size: Int

  /// Every linear row stride is a multiple of 64 bytes (`alignment`; 05 sections 5.5.4 and 5.5.5, R1.1: the texture unit reads
  /// no other). `rowStride`: level 0's row stride where another process chose it (an import), which must keep the rule.
  public init(format: TexelFormat, kind: ImageLayoutKind, width: Int, height: Int, depth: Int = 1, levels count: Int = 1,
              layers: Int = 1, rowStride: Int? = nil, samples: Int = 1) {
    self.format = format
    self.samples = samples
    self.kind = kind
    self.width = width
    self.height = height
    self.depth = depth
    self.layers = layers
    levels = []
    arrayStride = 0
    size = 0
    var offset = 0
    let s = format.bytesPerTexel
    for l in 0..<count {
      let w = max(1, width >> l)
      let h = max(1, height >> l)
      let d = max(1, depth >> l)
      // The elements of a level: texels, or blocks of the compressed formats (05 section 5.5.2).
      let ew = (w + format.blockWidth - 1) / format.blockWidth
      let eh = (h + format.blockHeight - 1) / format.blockHeight
      let row: Int
      let surface: Int
      switch kind {
      case .linear:
        row = l == 0 && rowStride != nil ? rowStride! : alignUp(ew * s, ImageLayout.alignment)
        surface = alignUp(row * eh, ImageLayout.alignment)
      case .uInterleaved:
        let t = ImageLayout.tileTexels
        let nx = (ew + t - 1) / t
        let ny = (eh + t - 1) / t
        row = alignUp(nx * t * t * s, ImageLayout.alignment)
        surface = alignUp(row * ny, ImageLayout.alignment)
      case .interleaved64K:
        // 05 section 5.7.2: whole tiles, so every level starts on a tile and the layer stride is whole tiles too (5.7.3).
        let tile = ImageLayout.tile64K(bytes: s) ?? (64, 64)
        row = (ew + tile.width - 1) / tile.width * ImageLayout.tileBytes64K
        surface = row * ((eh + tile.height - 1) / tile.height)
      case .afbc:
        // 05 section 5.11.6, linear headers and 16 x 16 superblocks: the extent aligned to the render block, a 16-byte header a
        // superblock, the body at the header area aligned to 128, and a sparse slot of 256 texels a superblock.
        let columns = (w + 15) / 16, rows = (h + 15) / 16
        row = columns * 16
        let headers = columns * rows * 16
        let body = alignUp(headers, 128)
        surface = body + columns * rows * 256 * s
        offset = alignUp(offset, 128)
        var level = LevelLayout(width: w, height: h, offset: offset, rowStride: row, surfaceStride: surface, depth: d, samples: samples)
        level.headerBytes = headers
        level.bodyOffset = body
        levels.append(level)
        offset += surface
        continue
      }
      offset = alignUp(offset, ImageLayout.alignment)
      levels.append(LevelLayout(width: w, height: h, offset: offset, rowStride: row, surfaceStride: surface, depth: d, samples: samples))
      offset += surface * d * samples
    }
    arrayStride = alignUp(offset, kind == .afbc ? 128 : ImageLayout.alignment)
    size = alignUp(arrayStride * layers, 4096)
  }

  /// AFBC's compression mode for a texel of `bytes` (05 section 5.11.8: the component widths, not the order or the type): R8, R8G8
  /// (and 16-bit depth), R8G8B8A8 (and 32-bit depth); nil for a texel AFBC doesn't take here.
  public static func afbcMode(bytes: Int) -> UInt32? {
    switch bytes {
    case 1: 0
    case 2: 3
    case 4: 10
    default: nil
    }
  }

  /// Whether an AFBC image of this format uses the colour transform (05 section 5.11.7: for three and four colour components,
  /// never a depth or a one or two-component mode).
  public var afbcYTR: Bool { kind == .afbc && format.bytesPerTexel == 4 && format != .depth32f }

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
  public func texelOffset(x: Int, y: Int, level: Int = 0, layer: Int = 0, z: Int = 0, sample: Int = 0) -> Int {
    let l = levels[level]
    let base = layer * arrayStride + l.offset + (z + sample) * l.surfaceStride
    let s = format.bytesPerTexel
    switch kind {
    case .linear:
      return base + (y / format.blockHeight) * l.rowStride + (x / format.blockWidth) * s
    case .uInterleaved:
      let t = ImageLayout.tileTexels
      let tileBytes = t * t * s
      return base + (y / t) * l.rowStride + (x / t) * tileBytes + ImageLayout.uCurve(x: x % t, y: y % t) * s
    case .interleaved64K:
      return base + ImageLayout.offset64K(x: x / format.blockWidth, y: y / format.blockHeight, bytes: s, rowStride: l.rowStride)
    case .afbc:
      // An AFBC texel has no address: its superblock is compressed (only the GPU's writes and the texture unit's reads know it).
      return base
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
    planes(base: base, levels: 0..<levels.count, layers: 0..<layers)
  }

  /// The plane descriptors of a view over `levels` and `layers` (03 section 3.8.3: the layer slowest, then the level; the level
  /// and layer are baked into each entry). A 3D image has one layer of entries; each is the first slice of the level, with the
  /// slice stride (03 section 3.9.3).
  public func planes(base: UInt64, levels range: Range<Int>, layers layerRange: Range<Int>) -> [PlaneDescriptor] {
    var out: [PlaneDescriptor] = []
    for layer in layerRange {
      for l in range {
        let lv = levels[l]
        var p = PlaneDescriptor(
          address: base + UInt64(layer * arrayStride + lv.offset), size: UInt64(lv.levelSize), rowStride: lv.rowStride,
          sliceStride: depth > 1 || samples > 1 ? UInt64(lv.surfaceStride) : 0, width: lv.width, height: lv.height, kind: kind, format: format)
        p.headerBytes = lv.headerBytes
        p.ytr = afbcYTR
        out.append(p)
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
  public var format: TexelFormat
  /// AFBC (03 section 3.9.6): the header area's bytes (the header slice size) and the colour transform.
  public var headerBytes = 0
  public var ytr = false

  public init(address: UInt64, size: UInt64, rowStride: Int, sliceStride: UInt64 = 0, width: Int, height: Int,
              kind: ImageLayoutKind, format: TexelFormat) {
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
    var word0 = PlaneDescriptor.typeTag | PlaneDescriptor.genericType << 4 | kind.clumpOrdering << 8 | format.clump << 24
    if let a = format.astc {
      // ASTC 2D (03 section 3.9.4): plane type 4, decode wide `[25]`, block width `[28:26]` and height `[31:29]`.
      guard let w = ASTCPlaneFields.code(a.blockWidth), let h = ASTCPlaneFields.code(a.blockHeight) else { throw .outOfRange }
      word0 = PlaneDescriptor.typeTag | 4 << 4 | kind.clumpOrdering << 8 | (a.wide ? 1 << 25 : 0) | w << 26 | h << 29
    }
    if kind == .afbc {
      // The AFBC plane (03 section 3.9.6): plane type 6, superblock 16 x 16 `[10:8]` 0, YTR `[16]`, prefetch `[20]` (the reference
      // sets it), the compression mode `[31:26]`; the pointer is the header area's, word 4 the header row stride, word 5 the header
      // slice size, word 6 the header slice stride (0 for a 2D view).
      guard let mode = ImageLayout.afbcMode(bytes: format.bytesPerTexel) else { throw .outOfRange }
      return [
        PlaneDescriptor.typeTag | 6 << 4 | (ytr ? 1 << 16 : 0) | 1 << 20 | mode << 26,
        UInt32(truncatingIfNeeded: size),
        UInt32(truncatingIfNeeded: address),
        UInt32(truncatingIfNeeded: address >> 32) & 0xFFFF | UInt32(truncatingIfNeeded: size >> 32) << 16,
        UInt32(rowStride),
        UInt32(headerBytes),
        0,
        UInt32(width - 1) | UInt32(height - 1) << 16,
      ]
    }
    return [
      word0,
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
  public var format: TexelFormat
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
  /// The maximum level of detail in 8.8 fixed point, where it is not the last level's (a one-level texture given a level above
  /// it lets a minifying quad choose its minification filter).
  public var maxLOD: UInt32?

  public init(dimension: Dimension = .d2, format: TexelFormat, width: Int, height: Int, swizzle: UInt32 = TextureSwizzle.identity,
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
      levels: image.levels.count, layers: image.layers, sampleCountLog2: UInt32(log2Floor(UInt64(image.samples))), surfaces: surfaces)
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
      swizzle & 0xFFF | (format.blockWidth > 1 ? 1 : layout.texelInterleave) << 12 | UInt32(levels - 1) << 16,
      sampleCountLog2 << 13 | (maxLOD ?? UInt32((levels - 1) << 8)) << 16,
      UInt32(truncatingIfNeeded: surfaces), UInt32(truncatingIfNeeded: surfaces >> 32),
      UInt32(layers - 1),
      UInt32(depth - 1),
    ]
  }
}

// MARK: Sampler descriptor (03 section 3.7)

public struct SamplerWords: Equatable, Sendable {
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
  /// The compare function's field (03 section 3.7.4's table: 0 never, which is no comparison).
  public var compare: UInt32 = 0
  /// The most samples along the major axis (1: isotropic filtering).
  public var maxAnisotropy: Int = 1

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
  public static let nearest = SamplerWords(minFilter: .nearest, magFilter: .nearest)

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
    guard minLOD < 1 << 13, maxLOD < 1 << 13, border.count == 4, compare < 8, maxAnisotropy >= 1, maxAnisotropy <= 32 else {
      throw .outOfRange
    }
    let bothNearest = minFilter == .nearest && magFilter == .nearest
    let w0 =
      SamplerWords.typeTag | wrapR.rawValue << 8 | wrapT.rawValue << 12 | wrapS.rawValue << 16
      | (bothNearest ? 0 : 1 << 21) | 1 << 23 | (normalizedCoordinates ? 1 << 25 : 0) | 1 << 26
      | (minFilter == .nearest ? 1 << 27 : 0) | (magFilter == .nearest ? 1 << 28 : 0) | mipmap.rawValue << 30
    return [
      w0, minLOD | compare << 13 | maxLOD << 16,
      UInt32(UInt16(bitPattern: lodBias)) | UInt32(maxAnisotropy - 1) << 16 | (maxAnisotropy > 1 ? 3 << 24 : 0), 0,
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
    try resourceTable(textures: (heapAddress, heapBytes), storage: nil)
  }

  /// The table number of the storage images: their descriptors are table 2, apart from the textures' and samplers'
  /// (a shader's handle for element 0 of its storage image binding is `handle(table: 2, index: 0)`).
  public static let storageTableNumber = 2

  /// The resource table for a pass or dispatch: the textures and samplers as table 1 and the storage images as table
  /// 2, each when there is one.
  public static func resourceTable(
    textures: (address: UInt64, bytes: Int)?, storage: (address: UInt64, bytes: Int)?
  ) throws(DescriptorError) -> [UInt8] {
    var entries = [ResourceTableEntry](repeating: .unused, count: tableEntries)
    if let t = textures {
      entries[tableNumber] = ResourceTableEntry(address: t.address, containsDescriptors: true, size: UInt64(t.bytes))
    }
    if let s = storage {
      entries[storageTableNumber] = ResourceTableEntry(address: s.address, containsDescriptors: true, size: UInt64(s.bytes))
    }
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
