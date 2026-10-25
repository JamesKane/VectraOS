// SPDX-License-Identifier: BSD-3-Clause

// What the other virtio devices' configurations say (Virtual I/O Device
// 1.2): network (§5.1) and input (§5.8); GPU's (§5.7) is
// drivers/display/virtio-gpu's. Each reads only the configuration; their
// queues carry the rest.

public enum Network {
  public enum Feature {
    public static let mtu: UInt64 = 1 << 3
    public static let mac: UInt64 = 1 << 5
    public static let status: UInt64 = 1 << 16
    public static let multiqueue: UInt64 = 1 << 22
  }

  public struct Config: Equatable, Sendable {
    public var mac: [UInt8]?
    /// Bit 0: the link is up.
    public var status: UInt16?
    public var mtu: UInt16?
    public var queuePairs: UInt16

    public init(mac: [UInt8]?, status: UInt16?, mtu: UInt16?, queuePairs: UInt16) {
      self.mac = mac
      self.status = status
      self.mtu = mtu
      self.queuePairs = queuePairs
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    let f = d.features
    return Config(
      mac: f & Feature.mac != 0 ? (0..<6).map { UInt8(truncatingIfNeeded: d.config($0, width: 1)) } : nil,
      status: f & Feature.status != 0 ? UInt16(truncatingIfNeeded: d.config(6, width: 2)) : nil,
      mtu: f & Feature.mtu != 0 ? UInt16(truncatingIfNeeded: d.config(10, width: 2)) : nil,
      queuePairs: f & Feature.multiqueue != 0 ? UInt16(truncatingIfNeeded: d.config(8, width: 2)) : 1)
  }

  /// `52:54:00:12:34:56`.
  public static func text(_ mac: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for (i, b) in mac.enumerated() {
      if i > 0 { out.append(UInt8(ascii: ":")) }
      out += [digits[Int(b >> 4)], digits[Int(b & 15)]]
    }
    return String(decoding: out, as: UTF8.self)
  }
}

public enum Input {
  /// virtio_input_config's select values (§5.8.4).
  public static let idName: UInt8 = 0x01
  public static let idSerial: UInt8 = 0x02
  public static let idDevids: UInt8 = 0x03
  public static let propBits: UInt8 = 0x10
  public static let eventBits: UInt8 = 0x11
  public static let absInfo: UInt8 = 0x12

  /// Asks the configuration (select, subsel) and reads the answer: `size`
  /// bytes of data at 8.
  public static func query<W: Window>(_ d: Device<W>, _ select: UInt8, _ subsel: UInt8 = 0) -> [UInt8] {
    d.setConfig(0, width: 1, UInt64(select))
    d.setConfig(1, width: 1, UInt64(subsel))
    let size = min(Int(d.config(2, width: 1)), 128)
    return (0..<size).map { UInt8(truncatingIfNeeded: d.config(8 + $0, width: 1)) }
  }

  public struct Identity: Equatable, Sendable {
    public var name: String
    public var bus: UInt16
    public var vendor: UInt16
    public var product: UInt16
    public var version: UInt16
    /// The event types it reports (EV_KEY 1, EV_REL 2, EV_ABS 3...).
    public var eventTypes: [UInt8]

    public init(name: String, bus: UInt16, vendor: UInt16, product: UInt16, version: UInt16, eventTypes: [UInt8]) {
      self.name = name
      self.bus = bus
      self.vendor = vendor
      self.product = product
      self.version = version
      self.eventTypes = eventTypes
    }
  }

  public static func identity<W: Window>(_ d: Device<W>) -> Identity {
    var nameBytes = query(d, idName)
    while nameBytes.last == 0 { nameBytes.removeLast() }  // QEMU counts the terminator
    let name = String(decoding: nameBytes, as: UTF8.self)
    let ids = query(d, idDevids)
    func le16(_ i: Int) -> UInt16 { i + 1 < ids.count ? UInt16(ids[i]) | UInt16(ids[i + 1]) << 8 : 0 }
    var types: [UInt8] = []
    for t in UInt8(1)..<0x20 where !query(d, eventBits, t).isEmpty { types.append(t) }
    return Identity(name: name, bus: le16(0), vendor: le16(2), product: le16(4), version: le16(6), eventTypes: types)
  }

  /// An absolute axis's range (virtio_input_absinfo's le32 min and max),
  /// nil if the device has none for it.
  public static func absRange<W: Window>(_ d: Device<W>, axis: UInt8) -> ClosedRange<Int32>? {
    let info = query(d, absInfo, axis)
    guard info.count >= 8 else { return nil }
    func le32(_ i: Int) -> Int32 {
      Int32(bitPattern: UInt32(info[i]) | UInt32(info[i + 1]) << 8 | UInt32(info[i + 2]) << 16 | UInt32(info[i + 3]) << 24)
    }
    let (low, high) = (le32(0), le32(4))
    return low <= high ? low...high : nil
  }
}
