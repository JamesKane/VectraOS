// SPDX-License-Identifier: BSD-3-Clause

// What the fragment stage reads to render a frame (chinese-wall's valhall 08
// and 05 section 5.5): the framebuffer parameters block and the render-target
// descriptor (RGB variant, linear block format), the tile-buffer budgeting that
// picks the effective tile size and the colour allocation (8.8, with its
// worked examples), the clear value's packing (8.7.2), the tagged pointer
// RUN_FRAGMENT reads (8.1.3) and the linear image layout (5.5.4). Arch 10 to
// 13's parameters block; arch 14 has none.

// MARK: Tile-buffer budgeting (08 section 8.8)

/// The tile buffer's two parts for a GPU model (16 section 16.2.2): totals in bytes. The budgets the formulas use
/// are the halves, so that two tiles fit and the next can load while one is shaded.
public struct TileBuffer: Equatable, Sendable {
  public var colourBytes: Int
  public var depthBytes: Int
  /// The most pixels a tile holds on the arch: 256, 1024 or 4096 (8.8.2).
  public var maxTilePixels: Int

  public init(colourBytes: Int, depthBytes: Int, maxTilePixels: Int) {
    self.colourBytes = colourBytes
    self.depthBytes = depthBytes
    self.maxTilePixels = maxTilePixels
  }

  /// The G720 and G720-Immortalis (arch 12): 64 KiB of colour, 32 KiB of depth, tiles up to 64 x 64.
  public static let g720 = TileBuffer(colourBytes: 65536, depthBytes: 32768, maxTilePixels: 4096)
  /// A G310 v1, the spec's second worked example (arch 10).
  public static let g310 = TileBuffer(colourBytes: 16384, depthBytes: 8192, maxTilePixels: 1024)
}

/// The effective tile size and the colour area of a pass (8.8.4 and 8.8.6).
public struct TilePlan: Equatable, Sendable {
  public var tilePixels: Int
  public var tileLog2: UInt32
  /// The colour tile-buffer allocation in bytes (a multiple of 1024) and the field's value, in KiB.
  public var allocationBytes: Int
  public var allocationField: UInt32
  /// Each present target's internal buffer offset in bytes, in target order.
  public var offsets: [Int]
  public var tileWidth: Int { 1 << ((tileLog2 + 1) / 2) }
  public var tileHeight: Int { 1 << (tileLog2 / 2) }

  /// Plan a pass: `bytesPerSample` are the tile-buffer bytes of each present target (8.8.3: 4 for a blendable
  /// unorm or sRGB format), `localStorage` the pixel local storage per pixel. An absent target is not listed
  /// (the spec's open question about a pass of none: this counts it as 4 bytes per sample, as it advises).
  public static func make(_ buffer: TileBuffer, bytesPerSample: [Int], samples: Int, localStorage: Int = 0) -> TilePlan? {
    guard samples >= 1, samples <= 16, isPowerOfTwo(UInt64(samples)) else { return nil }
    let budgetColour = buffer.colourBytes / 2
    let budgetDepth = buffer.depthBytes / 2
    var sum = 0
    for b in bytesPerSample { sum += b }
    if bytesPerSample.isEmpty { sum = 4 }
    let perSample = max(sum, localStorage)
    let perPixel = perSample * samples
    let depthPerPixel = 4 * samples
    var t = min(budgetColour >> log2Ceil(UInt64(perPixel)), budgetDepth >> log2Ceil(UInt64(depthPerPixel)))
    if t < 16 { t *= 2 }
    t = min(t, buffer.maxTilePixels)
    guard t >= 16, isPowerOfTwo(UInt64(t)) else { return nil }
    let alloc = alignUp(perPixel * t, 1024)
    guard alloc <= 2 * budgetColour, alloc / 1024 <= 255 else { return nil }
    var offsets: [Int] = []
    var at = 0
    for b in bytesPerSample {
      offsets.append(at)
      at += b * t * samples
    }
    return TilePlan(tilePixels: t, tileLog2: UInt32(log2Floor(UInt64(t))), allocationBytes: alloc,
                    allocationField: UInt32(alloc / 1024), offsets: offsets)
  }
}

// MARK: Linear layout (05 section 5.5.4)

/// A linear image's row and surface strides for level 0 of one layer: the row stride is the row's bytes aligned
/// to 64, the surface stride that times the rows aligned to 64.
public struct LinearLayout: Equatable, Sendable {
  public var rowStride: Int
  public var surfaceStride: Int
  public init(width: Int, height: Int, bytesPerPixel: Int) {
    rowStride = alignUp(width * bytesPerPixel, 64)
    surfaceStride = alignUp(rowStride * height, 64)
  }
}

// MARK: Render target (08 section 8.4)

/// A colour target's memory format for the blendable 8-bit formats (8.4.2, 9.6.2): both are R8G8B8A8 in the tile
/// buffer and in the writeback format enumeration; the order of the channels in memory is the swizzle.
public enum ColourFormat: Equatable, Sendable {
  case rgba8
  case bgra8

  /// Internal Format R8G8B8A8 (8.4.2, value 1) and Writeback Format R8G8B8A8 (value 19).
  public static let internalFormat: UInt32 = 1
  public static let writebackFormat: UInt32 = 19
  public static let bytesPerPixel = 4

  /// The 12-bit render-target swizzle (8.4.5, 5.2.4): the inverse permutation of the format's channel order.
  /// RGBA is the identity 0x688; BGRA swaps R and B (its own inverse): `2 | 1 << 3 | 0 << 6 | 3 << 9`.
  public var swizzle: UInt32 {
    switch self {
    case .rgba8: return 0 | 1 << 3 | 2 << 6 | 3 << 9
    case .bgra8: return 2 | 1 << 3 | 0 << 6 | 3 << 9
    }
  }

  /// A 32-bit clear word in the tile-buffer representation (8.7.2, rules 1 to 5): each channel clamped to [0, 1]
  /// and rounded to nearest even at 8 bits, R in the low byte. The format's memory order is not in it. Without an
  /// sRGB target no conversion applies. `Float` rounding by hand: no libm in the tier 0 code.
  public static func packedClear(red: Float, green: Float, blue: Float, alpha: Float) -> UInt32 {
    func channel(_ v: Float) -> UInt32 {
      let c = min(max(v, 0), 1) * 255
      var n = UInt32(c)  // truncation toward zero; c is in [0, 255]
      let fraction = c - Float(n)
      if fraction > 0.5 || (fraction == 0.5 && n & 1 == 1) { n += 1 }
      return n
    }
    return channel(red) | channel(green) << 8 | channel(blue) << 16 | channel(alpha) << 24
  }
}

/// The render-target descriptor, RGB variant (8.4.1, 8.4.4): 64 bytes, 64-byte aligned.
public struct RenderTargetDescriptor: Equatable, Sendable {
  public static let size = 64
  public static let alignment = 64

  public var format: ColourFormat
  /// The target's byte offset within the tile colour area (a multiple of 16, at most 65520).
  public var internalBufferOffset: Int
  /// Where the surface starts, and its strides in bytes (the row stride's 27 bits, the surface stride's 37).
  public var address: UInt64
  public var rowStride: Int
  public var surfaceStride: Int
  /// The four clear words in the tile-buffer representation (8.7.2: all four equal for a blendable format).
  public var clear: [UInt32]
  /// Write the tile back even if no primitive touched it: a pass that clears sets it (8.7.1, 8.9.1).
  public var cleanTileWrite: Bool
  public var dithering: Bool

  public init(format: ColourFormat, internalBufferOffset: Int = 0, address: UInt64, rowStride: Int, surfaceStride: Int,
              clearWord: UInt32, cleanTileWrite: Bool = true, dithering: Bool = true) {
    self.format = format
    self.internalBufferOffset = internalBufferOffset
    self.address = address
    self.rowStride = rowStride
    self.surfaceStride = surfaceStride
    clear = [clearWord, clearWord, clearWord, clearWord]
    self.cleanTileWrite = cleanTileWrite
    self.dithering = dithering
  }

  /// 16 words. Word 0: writeback mode 0 (compatibility) `[3:0]`, internal buffer offset shr 4 `[15:4]`, internal
  /// format `[31:26]`. Word 1: write enable `[0]`, writeback format `[7:3]`, block format Linear (2) `[11:8]`,
  /// MSAA single (0) `[13:12]`, dithering `[15]`, swizzle `[27:16]`, clean tile write `[31]`. Words 8 and 9: the
  /// base. Word 10: row stride `[26:0]` and the high five bits of the surface stride `[31:27]`. Word 11: the
  /// surface stride's low 32 bits. Words 12 to 15: the clear words. The rest is zero.
  public func words() throws(DescriptorError) -> [UInt32] {
    guard internalBufferOffset >= 0, internalBufferOffset <= 65520, internalBufferOffset & 15 == 0 else {
      throw .outOfRange
    }
    guard rowStride > 0, rowStride < 1 << 27, surfaceStride >= 0, UInt64(surfaceStride) < 1 << 37 else {
      throw .outOfRange
    }
    guard address & 63 == 0 else { throw .misaligned }
    var w = [UInt32](repeating: 0, count: 16)
    w[0] = UInt32(internalBufferOffset >> 4) << 4 | ColourFormat.internalFormat << 26
    w[1] = 1 | ColourFormat.writebackFormat << 3 | 2 << 8 | (dithering ? 1 << 15 : 0) | format.swizzle << 16
      | (cleanTileWrite ? 1 << 31 : 0)
    w[8] = UInt32(truncatingIfNeeded: address)
    w[9] = UInt32(truncatingIfNeeded: address >> 32)
    w[10] = UInt32(rowStride) | UInt32(truncatingIfNeeded: UInt64(surfaceStride) >> 32) << 27
    w[11] = UInt32(truncatingIfNeeded: surfaceStride)
    for i in 0..<4 { w[12 + i] = clear[i] }
    return w
  }
}

// MARK: Framebuffer parameters (08 section 8.2)

/// The 128-byte framebuffer parameters block (arch 10 to 13, 8.2.1) for a pass with no depth or stencil
/// attachment and no frame shaders.
public struct FramebufferParameters: Equatable, Sendable {
  public static let size = 128
  public static let alignment = 64

  public var width: Int
  public var height: Int
  /// The inclusive pixel bounding box of the pass (8.11); the whole frame is (0, 0) to (width - 1, height - 1).
  public var boundMinX: Int
  public var boundMinY: Int
  public var boundMaxX: Int
  public var boundMaxY: Int
  public var sampleCountLog2: UInt32
  public var samplePattern: UInt32
  /// The sample-position table's address for the pattern (07 section 7.9.2): `table + 256 * pattern`.
  public var sampleLocations: UInt64
  public var effectiveTileLog2: UInt32
  public var firstProvokingVertex: Bool
  public var renderTargetCount: Int
  /// The tile-buffer colour area in KiB (8.8.4).
  public var colourAllocationKiB: UInt32
  /// The address of the tiler context of this layer (words 14 and 15).
  public var tiler: UInt64

  public init(
    width: Int, height: Int, sampleCountLog2: UInt32 = 0, samplePattern: UInt32 = 0, sampleLocations: UInt64,
    effectiveTileLog2: UInt32, firstProvokingVertex: Bool = true, renderTargetCount: Int = 1,
    colourAllocationKiB: UInt32, tiler: UInt64
  ) {
    self.width = width
    self.height = height
    boundMinX = 0
    boundMinY = 0
    boundMaxX = width - 1
    boundMaxY = height - 1
    self.sampleCountLog2 = sampleCountLog2
    self.samplePattern = samplePattern
    self.sampleLocations = sampleLocations
    self.effectiveTileLog2 = effectiveTileLog2
    self.firstProvokingVertex = firstProvokingVertex
    self.renderTargetCount = renderTargetCount
    self.colourAllocationKiB = colourAllocationKiB
    self.tiler = tiler
  }

  /// The tie-break rule the reference driver writes (8.3.3): 2 for every sample count but 16.
  public var tieBreak: UInt32 { sampleCountLog2 == 4 ? 3 : 2 }

  /// 32 words. Word 0: the three frame-shader modes (Never, 0) and the internal layer index (0). Words 4 and 5:
  /// the sample locations. Words 6 and 7: the frame shaders' draw descriptors (zero: none). Word 8: width minus
  /// one `[15:0]`, height minus one `[31:16]`. Words 9 and 10: the bounding box, min and max, x in `[15:0]` and y
  /// in `[31:16]`. Word 11: sample count `[2:0]`, pattern `[5:3]`, tie-break `[8:6]`, effective tile size
  /// `[12:9]`, first provoking vertex `[14]`, point sprite origin max Y `[15]` (default 1), render target count
  /// minus one `[22:19]`, colour buffer allocation `[31:24]`. Word 12: Z internal format D24 `[17:16]` (the spec's
  /// value for a pass with no depth attachment) and no stencil, depth or CRC. Word 13 (Z clear), the tiler's
  /// address in words 14 and 15, and the padding are zero or as named.
  public func words() throws(DescriptorError) -> [UInt32] {
    guard width >= 1, height >= 1, width <= 65536, height <= 65536 else { throw .outOfRange }
    guard boundMinX >= 0, boundMinY >= 0, boundMaxX < width, boundMaxY < height, boundMinX <= boundMaxX,
      boundMinY <= boundMaxY
    else { throw .outOfRange }
    guard effectiveTileLog2 >= 4, effectiveTileLog2 <= 12, sampleCountLog2 <= 4, samplePattern < 8,
      renderTargetCount >= 1, renderTargetCount <= 8, colourAllocationKiB <= 255
    else { throw .outOfRange }
    guard sampleLocations & 3 == 0, tiler & 63 == 0 else { throw .misaligned }
    var w = [UInt32](repeating: 0, count: 32)
    w[4] = UInt32(truncatingIfNeeded: sampleLocations)
    w[5] = UInt32(truncatingIfNeeded: sampleLocations >> 32)
    w[8] = UInt32(width - 1) | UInt32(height - 1) << 16
    w[9] = UInt32(boundMinX) | UInt32(boundMinY) << 16
    w[10] = UInt32(boundMaxX) | UInt32(boundMaxY) << 16
    w[11] = sampleCountLog2 | samplePattern << 3 | tieBreak << 6 | effectiveTileLog2 << 9
      | (firstProvokingVertex ? 1 << 14 : 0) | 1 << 15 | UInt32(renderTargetCount - 1) << 19
      | colourAllocationKiB << 24
    w[12] = 1 << 16
    w[14] = UInt32(truncatingIfNeeded: tiler)
    w[15] = UInt32(truncatingIfNeeded: tiler >> 32)
    return w
  }

  /// RUN_FRAGMENT's FBD_POINTER (8.1.3) for the group at `address` (64-byte aligned): the type bit `[0]`, the
  /// extension flag `[1]`, the render-target count minus one `[5:2]` and the address in `[63:6]`, which with the
  /// low six bits the tag takes is the address plus the tag.
  public static func taggedPointer(address: UInt64, extensionPresent: Bool, renderTargetCount: Int) -> UInt64 {
    address | 1 | (extensionPresent ? 2 : 0) | UInt64(renderTargetCount - 1) << 2
  }

  /// The group's size (8.1.2): the parameters, the extension if present and a descriptor per target.
  public static func groupBytes(extensionPresent: Bool, renderTargetCount: Int) -> Int {
    128 + (extensionPresent ? 64 : 0) + 64 * renderTargetCount
  }

  /// RUN_FRAGMENT's BBOX_MIN and BBOX_MAX registers (8.11): x in `[15:0]`, y in `[31:16]`, both inclusive.
  public var boundingBoxRegisters: (min: UInt32, max: UInt32) {
    (UInt32(boundMinX) | UInt32(boundMinY) << 16, UInt32(boundMaxX) | UInt32(boundMaxY) << 16)
  }
}
