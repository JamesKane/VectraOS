// SPDX-License-Identifier: BSD-3-Clause

// Arm China's Linlon-D6 display engine, which is Arm's Mali-D71 design
// (Linux's komeda drives it; its d71_regs.h is read as hardware
// reference): a global control unit (GCU) at offset 0, then blocks of
// 0x200 bytes that each say what they are. bin/linlon only flips, so it
// needs little of them: which pipeline firmware left scanning out, that
// pipeline's enabled layer and its buffer, the timing controller's mode,
// and the GCU's configuration-valid latch and its interrupt. And which of
// its two buffers holds what (Buffers).

/// Registers, as offsets in the engine's window or in a block.
public enum D71 {
  public static let blockSize = 0x200
  /// Where the GCU's own blocks end and the engine's window does.
  public static let windowSize = 0x20000

  // The GCU.
  public static let archID = 0x000
  public static let coreID = 0x004
  /// Bits 0-7 the blocks (the GCU and reserved ones among them), 8-10 the pipelines.
  public static let coreInfo = 0x008
  /// Which units have an interrupt pending (Global).
  public static let globalIRQStatus = 0x010
  /// Written 1: the pipeline's shadowed registers latch at its next frame.
  public static let configValid0 = 0x0D4
  public static let configValid1 = 0x0D8

  // Every block.
  public static let blockInfo = 0x000
  public static let irqRawStatus = 0x0A0
  public static let irqClear = 0x0A4
  public static let irqMask = 0x0A8
  public static let irqStatus = 0x0AC
  public static let status = 0x0B0
  public static let control = 0x0D0

  // A layer.
  public static let layerFormat = 0x0D8
  public static let layerInSize = 0x0E0
  public static let p0Low = 0x100
  public static let p0High = 0x104
  public static let p0Stride = 0x108
  public static let layerEnable: UInt32 = 1

  // The timing controller (BS).
  public static let activeSize = 0x0E0
  public static let hIntervals = 0x0E4
  public static let vIntervals = 0x0E8
  public static let sync = 0x0EC

  /// The GCU's interrupts: pipeline 0's and 1's configuration latched.
  public static let cval0: UInt32 = 1 << 0
  public static let cval1: UInt32 = 1 << 1
  /// In globalIRQStatus: the GCU's, and each output unit's.
  public static let globalGCU: UInt32 = 1 << 0
  public static let globalDOU0: UInt32 = 1 << 24
  /// An output unit's: its programmed line reached, once a frame.
  public static let douPL0: UInt32 = 1 << 13

  /// LAYER_FORMAT's id for XRGB8888 (komeda's group 2, format 0): 32-bit
  /// pixels 0x00RRGGBB little endian, the display class's.
  public static let xrgb8888: UInt32 = 2 << 3
  public static let argb8888: UInt32 = 1 << 3

  /// CORE_ID's product (bits 16-31), of the parts with the D71's
  /// registers (komeda's d71_identify): the name it goes by, if one.
  public static func productName(coreID: UInt32) -> String? {
    switch coreID >> 16 {
    case 0x0071: "Mali-D71"
    case 0x0032: "Mali-D32"
    case 0x0060: "Linlon-D6"
    default: nil
    }
  }

  /// What the GCU's status says the engine is doing (bits 0-2).
  public static func modeName(_ status: UInt32) -> String {
    switch status & 7 {
    case 0: "inactive"
    case 1: "TBU connected"
    case 2: "TBU disconnected"
    case 3: "output 0 active"
    case 4: "output 1 active"
    case 5: "outputs 0 and 1 active"
    default: "mode \(status & 7)"
    }
  }

  /// The pipeline the GCU's status says scans out, if any (output 0's
  /// where both do).
  public static func livePipeline(gcuStatus: UInt32) -> Int? {
    switch gcuStatus & 7 {
    case 3, 5: 0
    case 4: 1
    default: nil
    }
  }

  public static func formatName(_ f: UInt32) -> String {
    switch f {
    case xrgb8888: "XRGB8888"
    case argb8888: "ARGB8888"
    case 2 << 3 | 1: "XBGR8888"
    case 1 << 3 | 1: "ABGR8888"
    default: "format \(f)"
    }
  }
}

/// A block's BLOCK_INFO: its type (bits 8-15) and id (bits 4-7).
public struct BlockInfo: Equatable, Sendable {
  public let raw: UInt32
  public init(_ raw: UInt32) { self.raw = raw }
  public var type: UInt32 { raw >> 8 & 0xFF }
  public var id: Int { Int(raw >> 4 & 0xF) }

  public static let layer: UInt32 = 0x10
  public static let outputUnit: UInt32 = 0x03
  public static let timing: UInt32 = 0x31
  public static let reserved: UInt32 = 0xFF
}

/// Where the blocks a flip needs are, by pipeline.
public struct Layout: Equatable, Sendable {
  /// Each layer (not writeback): its pipeline, its index there, and its offset.
  public var layers: [Layer] = []
  /// Each pipeline's output unit and timing controller, by pipeline.
  public var outputUnits: [Int?] = [nil, nil]
  public var timing: [Int?] = [nil, nil]

  public struct Layer: Equatable, Sendable {
    public var pipeline: Int
    public var index: Int
    public var offset: Int
    public init(pipeline: Int, index: Int, offset: Int) {
      self.pipeline = pipeline
      self.index = index
      self.offset = offset
    }
  }

  public init() {}

  /// The blocks after the GCU, `blocks` of them in all (CORE_INFO's count,
  /// the GCU's own included), each read through `read` at its offset;
  /// reserved blocks skipped, as komeda does.
  public static func scan(blocks: Int, read: (Int) -> UInt32) -> Layout {
    var out = Layout()
    var i = 1
    while i < blocks, (i + 1) * D71.blockSize <= D71.windowSize {
      let offset = i * D71.blockSize
      let info = BlockInfo(read(offset))
      switch info.type {
      case BlockInfo.layer:
        // Four layers a pipeline: ids 0-3 pipeline 0's, 4-7 pipeline 1's.
        out.layers.append(Layer(pipeline: info.id / 4, index: info.id % 4, offset: offset))
      case BlockInfo.outputUnit where info.id < 2:
        out.outputUnits[info.id] = offset
      case BlockInfo.timing where info.id < 2:
        out.timing[info.id] = offset
      default:
        break
      }
      i += 1
    }
    return out
  }
}

/// The mode a timing controller runs: its active size and its intervals.
public struct Timing: Equatable, Sendable {
  public var width: UInt32
  public var height: UInt32
  public var hFrontPorch: UInt32, hBackPorch: UInt32, hSync: UInt32
  public var vFrontPorch: UInt32, vBackPorch: UInt32, vSync: UInt32

  /// From BS_ACTIVESIZE, BS_HINTERVALS, BS_VINTERVALS and BS_SYNC.
  public init(activeSize: UInt32, hIntervals: UInt32, vIntervals: UInt32, sync: UInt32) {
    width = activeSize & 0x1FFF
    height = activeSize >> 16 & 0x1FFF
    hFrontPorch = hIntervals & 0xFFF
    hBackPorch = hIntervals >> 16 & 0x3FF
    vFrontPorch = vIntervals & 0x3FFF
    vBackPorch = vIntervals >> 16 & 0xFF
    hSync = sync & 0x3FF
    vSync = sync >> 16 & 0xFF
  }

  public var hTotal: UInt32 { width + hFrontPorch + hSync + hBackPorch }
  public var vTotal: UInt32 { height + vFrontPorch + vSync + vBackPorch }

  public var text: String {
    "\(width)x\(height), total \(hTotal)x\(vTotal) (h \(hFrontPorch)/\(hSync)/\(hBackPorch), "
      + "v \(vFrontPorch)/\(vSync)/\(vBackPorch))"
  }
}

/// A rectangle of an output, in pixels.
public struct Rect: Equatable, Sendable {
  public var x: UInt32, y: UInt32, width: UInt32, height: UInt32
  public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isEmpty: Bool { width == 0 || height == 0 }

  /// Clipped to a `w` × `h` image.
  public func clipped(_ w: UInt32, _ h: UInt32) -> Rect {
    guard x < w, y < h else { return Rect(x: 0, y: 0, width: 0, height: 0) }
    return Rect(x: x, y: y, width: min(width, w - x), height: min(height, h - y))
  }

  /// The smallest rectangle that holds both.
  public func union(_ o: Rect) -> Rect {
    if isEmpty { return o }
    if o.isEmpty { return self }
    let x0 = min(x, o.x), y0 = min(y, o.y)
    let x1 = max(x + width, o.x + o.width), y1 = max(y + height, o.y + o.height)
    return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }
}

/// Two scan-out buffers, one shown and one drawn: what each lacks of the
/// image, so that a flush copies into the drawn one the damage and what
/// the last flushes put only in the other.
public struct Buffers: Equatable, Sendable {
  public let width: UInt32, height: UInt32
  /// The buffer shown (0 or 1), nil until the first flip.
  public private(set) var front: Int?
  /// What each buffer lacks.
  public private(set) var stale: [Rect]

  public init(width: UInt32, height: UInt32) {
    self.width = width
    self.height = height
    stale = [Rect(x: 0, y: 0, width: width, height: height), Rect(x: 0, y: 0, width: width, height: height)]
  }

  /// The buffer the next flip shows.
  public var back: Int { front == 0 ? 1 : 0 }

  /// Both buffers stale: a new image is shown.
  public mutating func invalidate() {
    stale = [Rect(x: 0, y: 0, width: width, height: height), Rect(x: 0, y: 0, width: width, height: height)]
  }

  /// A flush of `damage`: what to copy into `back`, which then lacks
  /// nothing, while the shown one lacks the damage too.
  public mutating func flush(_ damage: Rect) -> Rect {
    let d = damage.clipped(width, height)
    let b = back
    let copy = stale[b].union(d)
    stale[b] = Rect(x: 0, y: 0, width: 0, height: 0)
    stale[1 - b] = stale[1 - b].union(d)
    return copy
  }

  /// The back buffer is shown now.
  public mutating func flipped() { front = back }
}

/// A refresh in millihertz from `frames` frames over `nanoseconds`.
public func refresh(frames: Int, nanoseconds: Int64) -> UInt32 {
  guard frames > 0, nanoseconds > 0 else { return 0 }
  return UInt32(clamping: (Int64(frames) * 1_000_000_000_000 + nanoseconds / 2) / nanoseconds)
}
