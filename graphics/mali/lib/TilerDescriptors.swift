// SPDX-License-Identifier: BSD-3-Clause

// What a driver gives the tiler (chinese-wall's valhall 07): the tiler context,
// the heap descriptor it points at, the hierarchy mask and its bin-pointer
// memory arithmetic (7.6, with the worked examples of 7.6.4), and the sample
// position table (7.9). Each descriptor is a value that encodes itself into
// little-endian words; where it lives is the render pass recipe's.

// MARK: Tiler context (07 section 7.2)

/// The 128-byte tiler context of a render pass (one per group of up to 8 layers on arch 10 to 13). The driver
/// initialises it (the polygon list pointer, the completed pointers and the private state at zero); the hardware
/// updates it. The two completed words at byte offsets 40 and 48 are what FINISH_FRAGMENT hands back (7.10).
public struct TilerContext: Equatable, Sendable {
  public static let size = 128
  public static let alignment = 64
  /// Byte offsets of the completed top and completed bottom (7.10), loaded together for FINISH_FRAGMENT.
  public static let completedOffset = 40
  /// The geometry buffer's default size in 4 KiB units (7.5): 64 KiB.
  public static let defaultGeometryUnits = 16

  /// Which bin levels are enabled (13 bits); 0 lets the hardware choose on arch 12 and later (7.6).
  public var hierarchyMask: UInt32
  /// 7.9.1; equals the framebuffer descriptor's.
  public var samplePattern: UInt32
  /// 1: the first vertex of a primitive provokes flat shading; equals the framebuffer descriptor's.
  public var firstProvokingVertex: Bool
  /// log2 of the tile's pixel count (arch 12 to 14), 4 to 12; equals the framebuffer descriptor's.
  public var effectiveTileLog2: UInt32
  /// The framebuffer's size in pixels (stored minus one).
  public var width: Int
  public var height: Int
  /// Layers this context handles (stored minus one), and the signed layer offset (arch 10 to 13).
  public var layerCount: Int
  public var layerOffset: Int
  /// The address of the heap descriptor (7.4): 32-byte aligned.
  public var heap: UInt64
  /// The geometry buffer's address (4 KiB aligned) and size in 4 KiB units (at most 4095).
  public var geometryBuffer: UInt64
  public var geometryUnits: Int

  public init(
    hierarchyMask: UInt32 = 0, samplePattern: UInt32 = 0, firstProvokingVertex: Bool = true, effectiveTileLog2: UInt32,
    width: Int, height: Int, layerCount: Int = 1, layerOffset: Int = 0, heap: UInt64, geometryBuffer: UInt64,
    geometryUnits: Int = TilerContext.defaultGeometryUnits
  ) {
    self.hierarchyMask = hierarchyMask
    self.samplePattern = samplePattern
    self.firstProvokingVertex = firstProvokingVertex
    self.effectiveTileLog2 = effectiveTileLog2
    self.width = width
    self.height = height
    self.layerCount = layerCount
    self.layerOffset = layerOffset
    self.heap = heap
    self.geometryBuffer = geometryBuffer
    self.geometryUnits = geometryUnits
  }

  /// The 32 words. Word 2: hierarchy mask `[12:0]`, sample pattern `[15:13]`, first provoking vertex `[18]`,
  /// effective tile size `[23:20]`. Word 3: width minus one `[15:0]`, height minus one `[31:16]`. Word 4: layer
  /// count minus one `[7:0]`, layer offset `[16:8]` (9-bit signed). Words 6 and 7: the heap. Words 8 and 9:
  /// the geometry buffer's address bits `[63:12]` with its size in 4 KiB units in `[11:0]`. Every other word is
  /// zero (the polygon list, the completed pointers, the reserved words and the private state).
  public func words() throws(DescriptorError) -> [UInt32] {
    guard width >= 1, height >= 1, width <= 65536, height <= 65536 else { throw .outOfRange }
    guard layerCount >= 1, layerCount <= 8, layerOffset >= -256, layerOffset <= 255 else { throw .outOfRange }
    guard hierarchyMask < 1 << 13, samplePattern < 8, effectiveTileLog2 >= 4, effectiveTileLog2 <= 12 else {
      throw .outOfRange
    }
    guard geometryUnits >= 1, geometryUnits <= 4095 else { throw .outOfRange }
    guard heap & 31 == 0, geometryBuffer & 4095 == 0 else { throw .misaligned }
    var w = [UInt32](repeating: 0, count: 32)
    w[2] = hierarchyMask | samplePattern << 13 | (firstProvokingVertex ? 1 << 18 : 0) | effectiveTileLog2 << 20
    w[3] = UInt32(width - 1) | UInt32(height - 1) << 16
    w[4] = UInt32(layerCount - 1) | (UInt32(bitPattern: Int32(layerOffset)) & 0x1FF) << 8
    w[6] = UInt32(truncatingIfNeeded: heap)
    w[7] = UInt32(truncatingIfNeeded: heap >> 32)
    let geometry = geometryBuffer | UInt64(geometryUnits)
    w[8] = UInt32(truncatingIfNeeded: geometry)
    w[9] = UInt32(truncatingIfNeeded: geometry >> 32)
    return w
  }
}

// MARK: Tiler heap descriptor (07 section 7.4)

/// The 32-byte heap descriptor (a buffer descriptor of type 9, buffer type 2) the tiler context points at. The
/// driver sets size, base, bottom and top once; after that the hardware owns the three pointers.
public struct TilerHeapDescriptor: Equatable, Sendable {
  public static let size = 32
  public static let alignment = 32
  /// The chunk's header: its first 64 bytes (NEXT, then reserved zero; panthor 08 section 8.3.3).
  public static let chunkHeaderBytes: UInt64 = 64

  /// A chunk's size in bytes: a multiple of 4 KiB (the kernel's heaps hold 128 KiB to 8 MiB).
  public var chunkBytes: UInt64
  /// The address of the first chunk the heap starts with: 4 KiB aligned.
  public var firstChunk: UInt64

  public init(chunkBytes: UInt64, firstChunk: UInt64) {
    self.chunkBytes = chunkBytes
    self.firstChunk = firstChunk
  }

  /// Word 0: type 9 in `[3:0]`, buffer type 2 in `[7:4]`. Word 1: the chunk size. Words 2 and 3: the base.
  /// Words 4 and 5: bottom, the base plus 64. Words 6 and 7: top, the base plus the size.
  public func words() throws(DescriptorError) -> [UInt32] {
    guard chunkBytes >= 4096, chunkBytes & 4095 == 0, chunkBytes < 1 << 32 else { throw .outOfRange }
    guard firstChunk & 4095 == 0, firstChunk != 0 else { throw .misaligned }
    let bottom = firstChunk + TilerHeapDescriptor.chunkHeaderBytes
    let top = firstChunk + chunkBytes
    return [
      BufferDescriptor.typeTag | BufferDescriptor.Kind.tilerHeap.rawValue << 4, UInt32(truncatingIfNeeded: chunkBytes),
      UInt32(truncatingIfNeeded: firstChunk), UInt32(truncatingIfNeeded: firstChunk >> 32),
      UInt32(truncatingIfNeeded: bottom), UInt32(truncatingIfNeeded: bottom >> 32),
      UInt32(truncatingIfNeeded: top), UInt32(truncatingIfNeeded: top >> 32),
    ]
  }

  /// A chunk reference as the kernel's heap and the firmware encode it (panthor 08 section 8.3.3): the address'
  /// bits `[63:12]` and the size in 4 KiB units in `[11:0]`.
  public static func chunkReference(address: UInt64, chunkBytes: UInt64) -> UInt64 {
    address & ~UInt64(0xFFF) | chunkBytes >> 12
  }
}

// MARK: Hierarchy mask (07 section 7.6)

public enum HierarchyMask {
  /// Bins at level `level` (edge `16 << level` pixels): the product of the two counts (7.6.2).
  public static func bins(level: Int, width: Int, height: Int) -> Int {
    let edge = 16 << level
    return ((width + edge - 1) / edge) * ((height + edge - 1) / edge)
  }

  /// The mask the byte estimate uses (7.6.2): on arch 12 and later, a mask of 0 or of more than 4 bits is the
  /// automatic one (0xAC for a tile of more than 1024 pixels, else 0xAA); otherwise the mask itself.
  public static func estimateMask(_ mask: UInt32, tilePixels: Int, arch: Int) -> UInt32 {
    guard arch >= 12 else { return mask }
    if mask == 0 || mask.nonzeroBitCount > 4 { return tilePixels > 1024 ? 0xAC : 0xAA }
    return mask
  }

  /// The bytes of bin pointers the framebuffer needs at the enabled levels (7.6.2): `ceil(total / 8) * 8 *
  /// pointer size`, the pointer 8 bytes before arch 12 and 16 after.
  public static func estimateBytes(mask: UInt32, width: Int, height: Int, tilePixels: Int, arch: Int) -> Int {
    let m = estimateMask(mask, tilePixels: tilePixels, arch: arch)
    var total = 0
    for level in 0..<13 where m >> UInt32(level) & 1 == 1 { total += bins(level: level, width: width, height: height) }
    return (total + 7) / 8 * 8 * (arch >= 12 ? 16 : 8)
  }

  /// The selection procedure of 7.6.3 (arch 12 and later; with `arch` below 12, 7.6.3's last note: no step 1 and
  /// the 8-byte pointer). `maxLevels` is TILER_FEATURES' `[11:8]`. `chunkBytes` gives the budget, the chunk less
  /// its 64-byte header. nil when no mask fits.
  public static func select(width: Int, height: Int, tilePixels: Int, maxLevels: Int, chunkBytes: Int, arch: Int = 12)
    -> UInt32?
  {
    let budget = chunkBytes - Int(TilerHeapDescriptor.chunkHeaderBytes)
    if arch >= 12, estimateBytes(mask: 0, width: width, height: height, tilePixels: tilePixels, arch: arch) <= budget {
      return 0
    }
    // Step 2: the significant bits of ceil(max(W, H) / 16).
    let units = (max(width, height) + 15) / 16
    let top = Int.bitWidth - units.leadingZeroBitCount
    // Step 3: the start mask.
    let starts: [UInt32] = [0x00, 0x80, 0x82, 0xA2, 0xAA, 0xEA, 0xEE, 0xFE]
    var m = maxLevels
    var mask: UInt32
    if m < 8 {
      mask = starts[max(m, 0)]
      m = 8
    } else {
      mask = m >= 32 ? ~0 : (1 << UInt32(m)) - 1
    }
    // Step 4: a level covering the whole framebuffer.
    if top > m { mask <<= UInt32(top - m) }
    // Step 5: n, the smallest with T <= 256 << (2n); clear bins smaller than a tile.
    var n = 0
    while tilePixels > 256 << (2 * n) { n += 1 }
    func cleared(_ mask: UInt32, _ n: Int) -> UInt32 { n >= 13 ? 0 : mask & ~((1 << UInt32(n)) - 1) }
    mask = cleared(mask, n)
    // Step 6: drop the finest levels while the estimate is not below the budget.
    while estimateBytes(mask: mask, width: width, height: height, tilePixels: tilePixels, arch: arch) >= budget && n < 12 {
      n += 1
      mask = cleared(mask, n)
    }
    // Step 7: the result must fit.
    return estimateBytes(mask: mask, width: width, height: height, tilePixels: tilePixels, arch: arch) <= budget
      ? mask : nil
  }
}

// MARK: Heap sizing

public enum TilerHeapSizing {
  /// The chunk a single small render pass is given, so that its tiler never runs out of memory and no TILER_OOM
  /// is raised (the kernel driver need not grow the heap): 1 MiB. What a pass uses is the 64-byte header, the bin
  /// pointer tables (7.6.2: 128 bytes for a 64 x 64 target at the automatic levels, 35 072 bytes for 1920 x 1080)
  /// and the polygon list entries of the primitives, tens of bytes for each tile a primitive touches. One
  /// triangle on one 64 x 64 tile is a few hundred bytes: 1 MiB is thousands of times that, and a power of two
  /// above the kernel's 128 KiB chunk floor (panthor 08 section 8.3.1).
  public static let smallPassChunkBytes: UInt64 = 1 << 20

  /// The least a chunk must hold for a framebuffer's bin pointers (7.6.2), the 64-byte header included, at the
  /// levels the hardware picks. Anything beyond is for the primitives.
  public static func binTableBytes(width: Int, height: Int, tilePixels: Int, arch: Int = 12) -> Int {
    HierarchyMask.estimateBytes(mask: 0, width: width, height: height, tilePixels: tilePixels, arch: arch)
      + Int(TilerHeapDescriptor.chunkHeaderBytes)
  }
}

// MARK: Sample positions (07 section 7.9)

/// The sample pattern values (7.9.1) and the position table the framebuffer descriptor points into (7.9.2).
public enum SamplePatterns {
  public static let single: UInt32 = 0
  public static let ordered4x: UInt32 = 1
  public static let rotated4x: UInt32 = 2
  public static let d3d8x: UInt32 = 3
  public static let d3d16x: UInt32 = 4
  public static let rotated2x: UInt32 = 5
  public static let patternCount = 6
  public static let blockBytes = 256
  public static let tableBytes = 6 * 256

  /// The sample pattern for a sample count (7.9.1); nil for a count the hardware has none for.
  public static func pattern(samples: Int) -> UInt32? {
    switch samples {
    case 1: return single
    case 2: return rotated2x
    case 4: return rotated4x
    case 8: return d3d8x
    case 16: return d3d16x
    default: return nil
    }
  }

  /// The positions of a pattern as offsets from the pixel centre in 1/16 pixel (7.9.2's table).
  public static func offsets(pattern: UInt32) -> [(x: Int, y: Int)] {
    switch pattern {
    case single: return [(0, 0)]
    case rotated2x: return [(4, 4), (-4, -4)]
    case ordered4x: return [(-4, -4), (4, -4), (-4, 4), (4, 4)]
    case rotated4x: return [(-2, -6), (6, -2), (-6, 2), (2, 6)]
    case d3d8x: return [(1, -3), (-1, 3), (5, 1), (-3, -5), (-5, 5), (-7, -1), (3, 7), (7, -7)]
    case d3d16x:
      return [
        (1, 1), (-1, -3), (-3, 2), (4, -1), (-5, -2), (2, 5), (5, 3), (3, -5), (-2, 6), (0, -7), (-4, -6), (-6, 4),
        (-8, 0), (7, -4), (6, 7), (-7, -8),
      ]
    default: return []
    }
  }

  /// The table of all six patterns, 256 bytes each at `256 * pattern`: 32 positions of two little-endian 16-bit
  /// numbers (x then y) in 1/256 pixel from the pixel's top-left corner (128 + 16 * offset), the pattern's own
  /// first and the rest zero; then at byte 128 of the block the origin (128, 128). Bytes 132 to 255 are zero.
  public static func table() -> [UInt8] {
    var image = MemoryImage(size: tableBytes)
    for p in 0..<patternCount {
      let base = p * blockBytes
      for (i, o) in offsets(pattern: UInt32(p)).enumerated() {
        image.store(UInt32(128 + 16 * o.x) | UInt32(128 + 16 * o.y) << 16, at: base + 4 * i)
      }
      image.store(UInt32(128) | UInt32(128) << 16, at: base + 128)
    }
    return image.bytes
  }
}
