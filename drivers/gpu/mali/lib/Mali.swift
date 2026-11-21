// SPDX-License-Identifier: BSD-3-Clause

// Arm Mali CSF GPUs (Valhall's 10th architecture on, the 5th generation),
// as their GPU control registers describe them: GPU_ID and the feature
// and present registers, read at a probe (chinese-wall's panthor 02),
// and the CIX Sky1's
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
  /// What a user-side driver sizes its work from (panthor 02 section 2.3; valhall 16 section 16.4).
  public static let threadMaxThreads = 0x0A0
  public static let threadMaxWorkgroupSize = 0x0A4
  public static let threadMaxBarrierSize = 0x0A8
  public static let threadFeatures = 0x0AC
  /// TEXTURE_FEATURES[0]: one bit for each compressed texture format (valhall 05 section 5.4.2).
  public static let textureFeatures0 = 0x0B0
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
  /// THREAD_MAX_THREADS, THREAD_MAX_WORKGROUP_SIZE, THREAD_MAX_BARRIER_SIZE and THREAD_FEATURES.
  public var threadMaxThreads: UInt32
  public var threadMaxWorkgroupSize: UInt32
  public var threadMaxBarrierSize: UInt32
  public var threadFeatures: UInt32
  public var textureFeatures0: UInt32
  public var shaderPresent: UInt64
  public var tilerPresent: UInt64
  public var l2Present: UInt64

  public init(id: GPUID, l2Features: UInt32 = 0, tilerFeatures: UInt32 = 0, memFeatures: UInt32 = 0,
              mmuFeatures: UInt32 = 0, asPresent: UInt32 = 0, csfID: UInt32 = 0, features: UInt64 = 0,
              threadMaxThreads: UInt32 = 0, threadMaxWorkgroupSize: UInt32 = 0, threadMaxBarrierSize: UInt32 = 0,
              threadFeatures: UInt32 = 0, textureFeatures0: UInt32 = 0, shaderPresent: UInt64 = 0, tilerPresent: UInt64 = 0,
              l2Present: UInt64 = 0) {
    self.textureFeatures0 = textureFeatures0
    self.id = id
    self.l2Features = l2Features
    self.tilerFeatures = tilerFeatures
    self.memFeatures = memFeatures
    self.mmuFeatures = mmuFeatures
    self.asPresent = asPresent
    self.csfID = csfID
    self.features = features
    self.threadMaxThreads = threadMaxThreads
    self.threadMaxWorkgroupSize = threadMaxWorkgroupSize
    self.threadMaxBarrierSize = threadMaxBarrierSize
    self.threadFeatures = threadFeatures
    self.shaderPresent = shaderPresent
    self.tilerPresent = tilerPresent
    self.l2Present = l2Present
  }

  public var shaderCores: Int { shaderPresent.nonzeroBitCount }
  /// GPU_FEATURES' ray intersection bit (2).
  public var rayIntersection: Bool { features & 0x4 != 0 }
  /// THREAD_FEATURES[21:0]: 32-bit registers in a core's file (valhall 16 section 16.4.2).
  public var registersPerCore: UInt32 { threadFeatures & 0x3F_FFFF }
  /// THREAD_FEATURES[31:24]: concurrent tasks per core (valhall 16 section 16.5; must not be 0).
  public var tasksPerCore: UInt32 { threadFeatures >> 24 & 0xFF }

  /// The product's name, as Arm's documentation gives it (panthor 02), from
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
      "threads \(threadMaxThreads) a core, workgroup \(threadMaxWorkgroupSize), barrier \(threadMaxBarrierSize);"
        + " THREAD_FEATURES \(hex(threadFeatures)): \(registersPerCore) registers a core, \(tasksPerCore) tasks a core",
      "TEXTURE_FEATURES[0] \(hex(textureFeatures0))",
    ]
  }
}

/// The CIX Sky1's GPU (CIXH5000) after devmgr has powered it up (its record's
/// `power-up graph`: power domain 21, `gpu_clk_core` and `gpu_clk_stacks`,
/// the power resource, `gpu_reset` pulsed); its registers may be read only
/// after that and the driver's own step (a read before raises an SError and
/// the board needs a power cycle). Of its RCSU (BAR 0) only `control` and
/// `harvest` may be read at any time.
public enum Sky1GPU {
  /// The RCSU's power-gating control; bit 0 turns Q-channel clock gating on.
  public static let control = 0x218
  public static let qChannelClockGate: UInt32 = 1 << 0
  /// The RCSU's harvested shader cores.
  public static let harvest = 0x304

  public static let steps = [
    "Q-channel clock gating", "probe", "harvest", "soft reset", "coherency", "system cache", "L2 power", "MCU VM",
    "firmware load", "address space 0", "MCU boot", "interface", "global init", "ping",
  ]
}

func hex(_ v: UInt32) -> String { "0x" + digits(UInt64(v), 8) }
func hex64(_ v: UInt64) -> String { "0x" + digits(v, v >> 32 == 0 ? 8 : 16) }

func digits(_ v: UInt64, _ count: Int) -> String {
  let d = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for i in stride(from: count - 1, through: 0, by: -1) { out.append(d[Int(v >> UInt64(4 * i) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}

