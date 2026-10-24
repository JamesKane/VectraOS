// SPDX-License-Identifier: BSD-3-Clause

// Arm Mali CSF GPUs (Valhall's 10th architecture on, the 5th generation),
// as their GPU control registers describe them: GPU_ID and the feature
// and present registers, read at a probe (offsets from Linux's
// panthor_gpu_regs.h, read as hardware reference), and the CIX Sky1's
// order for powering its Mali-G720 up, which must hold before the first
// register read (docs/boards/orangepi-6-plus/).

/// The GPU control block's registers a probe reads.
public enum GPURegister {
  public static let id = 0x00
  public static let l2Features = 0x04
  public static let coreFeatures = 0x08
  public static let tilerFeatures = 0x0C
  public static let memFeatures = 0x10
  public static let mmuFeatures = 0x14
  public static let asPresent = 0x18
  public static let csfID = 0x1C
  /// 64 bits.
  public static let features = 0x60
  /// Each 64 bits, a bit a core or unit.
  public static let shaderPresent = 0x100
  public static let tilerPresent = 0x110
  public static let l2Present = 0x120
}

/// GPU_ID's fields.
public struct GPUID: Equatable, Sendable {
  public let raw: UInt32
  public init(_ raw: UInt32) { self.raw = raw }

  public var archMajor: UInt32 { raw >> 28 }
  public var archMinor: UInt32 { raw >> 24 & 0xF }
  public var archRevision: UInt32 { raw >> 20 & 0xF }
  public var productMajor: UInt32 { raw >> 16 & 0xF }
  public var versionMajor: UInt32 { raw >> 12 & 0xF }
  public var versionMinor: UInt32 { raw >> 4 & 0xFF }
  public var versionStatus: UInt32 { raw & 0xF }

  /// What a powered-off or absent block reads as.
  public var isPlausible: Bool { raw != 0 && raw != UInt32.max && archMajor >= 10 }
}

/// What a probe read.
public struct Probe: Equatable, Sendable {
  public var id: GPUID
  public var l2Features: UInt32
  public var tilerFeatures: UInt32
  public var memFeatures: UInt32
  public var mmuFeatures: UInt32
  public var asPresent: UInt32
  public var csfID: UInt32
  public var features: UInt64
  public var shaderPresent: UInt64
  public var tilerPresent: UInt64
  public var l2Present: UInt64

  public init(id: GPUID, l2Features: UInt32 = 0, tilerFeatures: UInt32 = 0, memFeatures: UInt32 = 0,
              mmuFeatures: UInt32 = 0, asPresent: UInt32 = 0, csfID: UInt32 = 0, features: UInt64 = 0,
              shaderPresent: UInt64 = 0, tilerPresent: UInt64 = 0, l2Present: UInt64 = 0) {
    self.id = id
    self.l2Features = l2Features
    self.tilerFeatures = tilerFeatures
    self.memFeatures = memFeatures
    self.mmuFeatures = mmuFeatures
    self.asPresent = asPresent
    self.csfID = csfID
    self.features = features
    self.shaderPresent = shaderPresent
    self.tilerPresent = tilerPresent
    self.l2Present = l2Present
  }

  public var shaderCores: Int { shaderPresent.nonzeroBitCount }
  /// GPU_FEATURES' ray intersection bit (2).
  public var rayIntersection: Bool { features & 0x4 != 0 }

  /// The product's name, as Arm's documentation and Linux give it, from
  /// the architecture, the product and how many cores it has.
  public var name: String {
    let cores = shaderCores
    switch (id.archMajor, id.productMajor) {
    case (10, 2): return "Mali-G710"
    case (10, 3): return "Mali-G510"
    case (10, 4): return "Mali-G310"
    case (10, 7): return "Mali-G610"
    case (11, 2) where cores >= 10 && rayIntersection: return "Mali-G715-Immortalis"
    case (11, 2) where cores >= 7: return "Mali-G715"
    case (11, 2), (11, 3): return "Mali-G615"
    case (12, 0) where cores >= 10 && rayIntersection: return "Mali-G720-Immortalis"
    case (12, 0) where cores >= 6: return "Mali-G720"
    case (12, 0), (12, 1): return "Mali-G620"
    case (13, 0) where cores >= 10 && rayIntersection: return "Mali-G925-Immortalis"
    case (13, 0) where cores >= 6: return "Mali-G725"
    case (13, 0), (13, 1): return "Mali-G625"
    default: return "an unknown Mali"
    }
  }

  /// The status's lines.
  public var lines: [String] {
    let id = self.id
    return [
      "\(name), GPU_ID \(hex(id.raw)): architecture \(id.archMajor).\(id.archMinor).\(id.archRevision),"
        + " r\(id.versionMajor)p\(id.versionMinor) status \(id.versionStatus)",
      "shader cores \(shaderCores) (\(hex64(shaderPresent))), tiler \(hex64(tilerPresent)), L2 \(hex64(l2Present))",
      "L2 \(hex(l2Features)) tiler \(hex(tilerFeatures)) mem \(hex(memFeatures)) MMU \(hex(mmuFeatures))"
        + " AS \(hex(asPresent)) CSF \(hex(csfID)) features \(hex64(features))",
    ]
  }
}

/// The CIX Sky1's power-up for its GPU (CIXH5000), in order; the GPU's
/// registers may be read only after the last (a read before raises an
/// SError and the board needs a power cycle). Of its RCSU (BAR 0) only
/// `control` and `harvest` may be read at any time.
public enum Sky1GPU {
  /// SCMI power domain 21 (Linux's SKY1_PD_GPU), TF-A's.
  public static let powerDomain: UInt32 = 21
  /// The clocks to turn on, by their names in the GPU's CLKT.
  public static let clocks = ["gpu_clk_core", "gpu_clk_stacks"]
  /// The reset controller's (RST0's) register and bit for the GPU's
  /// reset, RSTL's `gpu_reset` (index 9), active low.
  public static let resetIndex: UInt32 = 9
  public static let resetRegister = 0x400
  public static let resetBit: UInt32 = 1 << 6
  /// The RCSU's power-gating control; bit 0 turns Q-channel clock gating on.
  public static let control = 0x218
  public static let qChannelClockGate: UInt32 = 1 << 0
  /// The RCSU's harvested shader cores.
  public static let harvest = 0x304

  /// The steps' names, as the status lists them.
  public static let steps = ["power domain", "clocks", "power resource", "reset", "Q-channel clock gating"]
}

func hex(_ v: UInt32) -> String { "0x" + digits(UInt64(v), 8) }
func hex64(_ v: UInt64) -> String { "0x" + digits(v, v >> 32 == 0 ? 8 : 16) }

func digits(_ v: UInt64, _ count: Int) -> String {
  let d = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for i in stride(from: count - 1, through: 0, by: -1) { out.append(d[Int(v >> UInt64(4 * i) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}
