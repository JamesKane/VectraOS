// SPDX-License-Identifier: BSD-3-Clause

// virtio over PCI (Virtual I/O Device 1.2, OASIS, §4.1): the modern
// transport. The device's vendor capabilities (§4.1.4) say where in its
// BARs the common configuration, notifications, ISR status and the
// device-specific configuration are; the common configuration (§4.1.4.3)
// resets the device, negotiates features (§3.1.1) and sets up queues.
// Registers are reached through a `Window`, so the same code drives the
// device natively (devmgr's mapped BARs) and a model of one in tests.

/// Little-endian registers at offsets: a mapped BAR's range, or a model.
public protocol Window: AnyObject {
  func read(_ offset: Int, width: Int) -> UInt64
  func write(_ offset: Int, width: Int, _ value: UInt64)
}

/// A vendor capability's place (§4.1.4): its type, BAR, offset and length.
public struct Capability: Equatable, Sendable {
  public enum Kind: UInt8, Sendable {
    case common = 1
    case notify = 2
    case isr = 3
    case device = 4
    case pci = 5
  }
  public var kind: Kind
  public var bar: Int
  public var offset: UInt32
  public var length: UInt32
  /// For `notify`: notify_off_multiplier.
  public var multiplier: UInt32

  public init(kind: Kind, bar: Int, offset: UInt32, length: UInt32, multiplier: UInt32 = 0) {
    self.kind = kind
    self.bar = bar
    self.offset = offset
    self.length = length
    self.multiplier = multiplier
  }

  /// The capabilities among a function's capability list (`list`: each
  /// capability's offset in configuration space, read through `read8`).
  /// Of each kind the first is kept, as §4.1.4 says a driver should.
  public static func find(at list: [Int], read8: (Int) -> UInt8) -> [Capability] {
    func le32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(read8(o + $1)) << (8 * UInt32($1)) } }
    var out: [Capability] = []
    for o in list where read8(o) == 0x09 {
      guard let kind = Kind(rawValue: read8(o + 3)), read8(o + 2) >= 16, !out.contains(where: { $0.kind == kind })
      else { continue }
      let bar = Int(read8(o + 4))
      guard bar < 6 else { continue }
      out.append(Capability(kind: kind, bar: bar, offset: le32(o + 8), length: le32(o + 12),
                            multiplier: kind == .notify ? le32(o + 16) : 0))
    }
    return out
  }
}

/// A shared memory region (§4.1.4.7, VIRTIO_PCI_CAP_SHARED_MEMORY_CFG):
/// device memory both sides see, in one of the function's BARs, named by
/// its id (virtio-gpu's host-visible blobs are region 1).
public struct SharedMemoryRegion: Equatable, Sendable {
  public var id: UInt8
  public var bar: Int
  public var offset: UInt64
  public var length: UInt64

  public init(id: UInt8, bar: Int, offset: UInt64, length: UInt64) {
    self.id = id
    self.bar = bar
    self.offset = offset
    self.length = length
  }

  /// The regions among a capability list: type 8, a 64-bit capability
  /// (offset_hi and length_hi after the common fields).
  public static func find(at list: [Int], read8: (Int) -> UInt8) -> [SharedMemoryRegion] {
    func le32(_ o: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(read8(o + $1)) << (8 * UInt64($1)) } }
    var out: [SharedMemoryRegion] = []
    for o in list where read8(o) == 0x09 && read8(o + 3) == 8 && read8(o + 2) >= 24 {
      let bar = Int(read8(o + 4))
      guard bar < 6 else { continue }
      out.append(SharedMemoryRegion(id: read8(o + 5), bar: bar, offset: le32(o + 8) | le32(o + 16) << 32,
                                    length: le32(o + 12) | le32(o + 20) << 32))
    }
    return out
  }
}

/// Device status bits (§2.1).
public enum DeviceStatus {
  public static let acknowledge: UInt8 = 1
  public static let driver: UInt8 = 2
  public static let driverOK: UInt8 = 4
  public static let featuresOK: UInt8 = 8
  public static let needsReset: UInt8 = 64
  public static let failed: UInt8 = 128
}

/// Feature bits every device shares (§6).
public enum Feature {
  /// VIRTIO_F_VERSION_1: the modern interface; a modern driver requires it.
  public static let version1: UInt64 = 1 << 32
  public static let accessPlatform: UInt64 = 1 << 33
  public static let ringPacked: UInt64 = 1 << 34
}

public enum VirtioError: Error, Equatable, Sendable {
  /// A capability the transport needs is missing.
  case missingCapability(Capability.Kind)
  /// The device doesn't offer VERSION_1.
  case notModern
  /// FEATURES_OK didn't stick: the device refused the features.
  case featuresRefused
  case noSuchQueue(Int)
}

/// The common configuration's registers (§4.1.4.3).
enum Common {
  static let deviceFeatureSelect = 0x00
  static let deviceFeature = 0x04
  static let driverFeatureSelect = 0x08
  static let driverFeature = 0x0C
  static let numQueues = 0x12
  static let deviceStatus = 0x14
  static let configGeneration = 0x15
  static let msixConfig = 0x10
  static let queueSelect = 0x16
  static let queueVector = 0x1A
  static let queueSize = 0x18
  static let queueEnable = 0x1C
  static let queueNotifyOff = 0x1E
  static let queueDesc = 0x20
  static let queueDriver = 0x28
  static let queueDevice = 0x30
}

/// A virtio device through its common and device configurations.
public final class Device<W: Window> {
  public let common: W
  public let device: W
  public private(set) var features: UInt64 = 0

  public init(common: W, device: W) {
    self.common = common
    self.device = device
  }

  public var status: UInt8 { UInt8(truncatingIfNeeded: common.read(Common.deviceStatus, width: 1)) }

  public func set(status: UInt8) { common.write(Common.deviceStatus, width: 1, UInt64(status)) }

  /// Writes 0 and waits for the device to read back 0 (§4.1.4.3.2).
  public func reset() {
    set(status: 0)
    var spins = 0
    while status != 0, spins < 1_000_000 { spins += 1 }
  }

  /// The 64 feature bits the device offers.
  public var offered: UInt64 {
    var v: UInt64 = 0
    for half in 0..<2 {
      common.write(Common.deviceFeatureSelect, width: 4, UInt64(half))
      v |= common.read(Common.deviceFeature, width: 4) << (32 * UInt64(half))
    }
    return v
  }

  public var queueCount: Int { Int(common.read(Common.numQueues, width: 2)) }

  /// The initialization sequence's first half (§3.1.1): reset,
  /// ACKNOWLEDGE, DRIVER, the features both sides know (`wanted` and
  /// VERSION_1, which a modern driver requires, and ACCESS_PLATFORM where
  /// offered: a driver's addresses are its BTI's, which the platform's
  /// IOMMU translates, and a device without it would take them as physical
  /// (QEMU's virtio does unless `iommu_platform=on`, V2 7d), FEATURES_OK
  /// checked. The features in use.
  public func negotiate(_ wanted: UInt64) throws(VirtioError) -> UInt64 {
    reset()
    set(status: DeviceStatus.acknowledge)
    set(status: DeviceStatus.acknowledge | DeviceStatus.driver)
    let offer = offered
    guard offer & Feature.version1 != 0 else {
      set(status: status | DeviceStatus.failed)
      throw .notModern
    }
    let accepted = offer & (wanted | Feature.version1 | Feature.accessPlatform)
    for half in 0..<2 {
      common.write(Common.driverFeatureSelect, width: 4, UInt64(half))
      common.write(Common.driverFeature, width: 4, (accepted >> (32 * UInt64(half))) & 0xFFFF_FFFF)
    }
    set(status: status | DeviceStatus.featuresOK)
    guard status & DeviceStatus.featuresOK != 0 else {
      set(status: status | DeviceStatus.failed)
      throw .featuresRefused
    }
    features = accepted
    return accepted
  }

  /// Queue `index`'s largest size (0: there is no such queue).
  public func queueSize(_ index: Int) -> Int {
    common.write(Common.queueSelect, width: 2, UInt64(index))
    return Int(common.read(Common.queueSize, width: 2))
  }

  /// Gives queue `index` its rings' bus addresses and `size`, and enables
  /// it; its notification offset (§4.1.4.4).
  /// No MSI-X vector (§4.1.5.1.2): the configuration change interrupt off,
  /// or a queue on INTx.
  public static var noVector: UInt16 { 0xFFFF }

  /// The configuration change interrupt's MSI-X vector.
  public func setConfigVector(_ vector: UInt16) { common.write(Common.msixConfig, width: 2, UInt64(vector)) }

  public func enable(queue index: Int, size: Int, descriptors: UInt64, driver: UInt64, device: UInt64,
                     vector: UInt16 = noVector) throws(VirtioError) -> Int
  {
    guard index < queueCount, size > 0, size <= queueSize(index) else { throw .noSuchQueue(index) }
    common.write(Common.queueSelect, width: 2, UInt64(index))
    common.write(Common.queueSize, width: 2, UInt64(size))
    if vector != Self.noVector {
      common.write(Common.queueVector, width: 2, UInt64(vector))
      // The device says NO_VECTOR if it can't (§4.1.5.1.2).
      guard common.read(Common.queueVector, width: 2) == UInt64(vector) else { throw .noSuchQueue(index) }
    }
    common.write(Common.queueDesc, width: 8, descriptors)
    common.write(Common.queueDriver, width: 8, driver)
    common.write(Common.queueDevice, width: 8, device)
    common.write(Common.queueEnable, width: 2, 1)
    return Int(common.read(Common.queueNotifyOff, width: 2))
  }

  /// Writes the device configuration (virtio-input's select, §5.8.4).
  public func setConfig(_ offset: Int, width: Int, _ value: UInt64) { device.write(offset, width: width, value) }

  /// The device configuration's bytes `offset..<offset+width`, read so a
  /// change mid-read is seen (§4.1.4.3.1: config_generation before and after).
  public func config(_ offset: Int, width: Int) -> UInt64 {
    while true {
      let before = common.read(Common.configGeneration, width: 1)
      var v: UInt64 = 0
      if width == 8 {
        v = device.read(offset, width: 4) | device.read(offset + 4, width: 4) << 32
      } else {
        v = device.read(offset, width: width)
      }
      if common.read(Common.configGeneration, width: 1) == before { return v }
    }
  }
}
