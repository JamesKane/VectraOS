// SPDX-License-Identifier: BSD-3-Clause

// USB's standard requests and descriptors (USB 2.0 ch. 9, USB 3.2 ch. 9,
// HID 1.11 §7, the hub class: USB 2.0 ch. 11 and USB 3.2 ch. 10), parsed
// from the bytes a device returns, and the rules xhci(3) sets endpoints
// up by (xHCI 1.2 §6.2.3, §4.14.2). Compiled into bin/xhci, and tested on
// the host (drivers/usb/tests).

/// A control transfer's setup packet (USB 2.0 §9.3).
public struct SetupPacket: Equatable, Sendable {
  public var requestType: UInt8
  public var request: UInt8
  public var value: UInt16
  public var index: UInt16
  public var length: UInt16

  public init(requestType: UInt8, request: UInt8, value: UInt16 = 0, index: UInt16 = 0, length: UInt16 = 0) {
    self.requestType = requestType
    self.request = request
    self.value = value
    self.index = index
    self.length = length
  }

  /// Whether its data stage, if any, is the device's to the host.
  public var deviceToHost: Bool { requestType & 0x80 != 0 }

  /// Its eight bytes as xHCI's setup stage takes them, one little-endian word.
  public var word: UInt64 {
    UInt64(requestType) | UInt64(request) << 8 | UInt64(value) << 16 | UInt64(index) << 32 | UInt64(length) << 48
  }

  public static func getDescriptor(_ type: UInt8, index: UInt8 = 0, length: UInt16) -> SetupPacket {
    SetupPacket(requestType: 0x80, request: 6, value: UInt16(type) << 8 | UInt16(index), length: length)
  }
  public static func setConfiguration(_ value: UInt8) -> SetupPacket {
    SetupPacket(requestType: 0x00, request: 9, value: UInt16(value))
  }
  /// HID's SET_PROTOCOL: 0 boot, 1 report.
  public static func setProtocol(_ value: UInt16, interface: UInt8) -> SetupPacket {
    SetupPacket(requestType: 0x21, request: 0x0B, value: value, index: UInt16(interface))
  }
  /// HID's SET_IDLE: a report only on a change.
  public static func setIdle(interface: UInt8) -> SetupPacket {
    SetupPacket(requestType: 0x21, request: 0x0A, index: UInt16(interface))
  }
  /// The hub's descriptor: USB 2's (0x29) or a SuperSpeed hub's (0x2A).
  public static func getHubDescriptor(superSpeed: Bool) -> SetupPacket {
    SetupPacket(requestType: 0xA0, request: 6, value: UInt16(superSpeed ? 0x2A : 0x29) << 8, length: 12)
  }
  /// A SuperSpeed hub's depth below the root (USB 3.2 §10.16.2.9).
  public static func setHubDepth(_ depth: UInt16) -> SetupPacket {
    SetupPacket(requestType: 0x20, request: 12, value: depth)
  }
  public static func getPortStatus(_ port: UInt8) -> SetupPacket {
    SetupPacket(requestType: 0xA3, request: 0, index: UInt16(port), length: 4)
  }
  public static func setPortFeature(_ feature: UInt16, port: UInt8) -> SetupPacket {
    SetupPacket(requestType: 0x23, request: 3, value: feature, index: UInt16(port))
  }
  public static func clearPortFeature(_ feature: UInt16, port: UInt8) -> SetupPacket {
    SetupPacket(requestType: 0x23, request: 1, value: feature, index: UInt16(port))
  }
}

/// Hub port features and status bits (USB 2.0 Tables 11-17, 11-21, 11-22;
/// USB 3.2 Table 10-9).
public enum HubPort {
  public static let reset: UInt16 = 4, power: UInt16 = 8
  public static let cConnection: UInt16 = 16, cEnable: UInt16 = 17, cSuspend: UInt16 = 18
  public static let cOverCurrent: UInt16 = 19, cReset: UInt16 = 20
  public static let cBHReset: UInt16 = 29, cLinkState: UInt16 = 25, cConfigError: UInt16 = 26

  /// wPortStatus: connected, enabled, in reset; USB 2's low- and
  /// high-speed bits (USB 3's hub has none: its devices are SuperSpeed).
  public static let connected: UInt16 = 1 << 0, enabled: UInt16 = 1 << 1, resetting: UInt16 = 1 << 4
  public static let lowSpeed: UInt16 = 1 << 9, highSpeed: UInt16 = 1 << 10
}

/// The device descriptor (USB 2.0 §9.6.1), its first 8 bytes enough for
/// endpoint 0's packet size.
public struct DeviceDescriptor: Equatable, Sendable {
  public var usb: UInt16
  public var deviceClass: UInt8, subclass: UInt8, deviceProtocol: UInt8
  public var maxPacket0: UInt8
  public var vendor: UInt16 = 0, product: UInt16 = 0
  public var configurations: UInt8 = 0

  public init?(_ b: [UInt8]) {
    guard b.count >= 8, b[1] == 1 else { return nil }
    usb = le16(b, 2)
    deviceClass = b[4]
    subclass = b[5]
    deviceProtocol = b[6]
    maxPacket0 = b[7]
    guard b.count >= 18 else { return }
    vendor = le16(b, 8)
    product = le16(b, 10)
    configurations = b[17]
  }

  /// Endpoint 0's packet size: bMaxPacketSize0, which USB 3 gives as a
  /// power of two.
  public var packetSize0: Int { usb >= 0x0300 ? 1 << Int(min(maxPacket0, 15)) : Int(maxPacket0) }
}

public struct Endpoint: Equatable, Sendable {
  /// bEndpointAddress: the number, and bit 7 for IN.
  public var address: UInt8
  /// bmAttributes' transfer type: 0 control, 1 isochronous, 2 bulk, 3 interrupt.
  public var type: UInt8
  public var maxPacket: Int
  /// Transactions a microframe beyond the first (USB 2's high bandwidth).
  public var extra: Int
  public var interval: UInt8
  /// A SuperSpeed endpoint's companion: bMaxBurst.
  public var burst: UInt8 = 0

  public var number: Int { Int(address & 0x0F) }
  public var isIn: Bool { address & 0x80 != 0 }
  /// Its Device Context Index (xHCI 1.2 §4.5.1): 2 × number, plus 1 for IN.
  public var contextIndex: Int { 2 * number + (isIn ? 1 : 0) }
}

public struct Interface: Equatable, Sendable {
  public var number: UInt8
  public var alternate: UInt8
  public var interfaceClass: UInt8, subclass: UInt8, interfaceProtocol: UInt8
  public var endpoints: [Endpoint] = []

  /// HID's boot keyboard (class 3, subclass 1, protocol 1) or mouse (2).
  public var isBootKeyboard: Bool { interfaceClass == 3 && subclass == 1 && interfaceProtocol == 1 }
  public var isBootMouse: Bool { interfaceClass == 3 && subclass == 1 && interfaceProtocol == 2 }
  /// Its first interrupt IN endpoint.
  public var interruptIn: Endpoint? { endpoints.first { $0.type == 3 && $0.isIn } }
}

/// A configuration descriptor with its interfaces (alternate setting 0
/// only) and their endpoints (USB 2.0 §9.6.3-9.6.6).
public struct Configuration: Equatable, Sendable {
  public var value: UInt8
  public var totalLength: Int
  public var interfaces: [Interface] = []

  /// The first 9 bytes are enough for wTotalLength; the whole of it for
  /// the interfaces.
  public init?(_ b: [UInt8]) {
    guard b.count >= 9, b[1] == 2 else { return nil }
    totalLength = Int(le16(b, 2))
    value = b[5]
    var at = Int(b[0])
    var skipping = false
    while at + 2 <= b.count {
      let length = Int(b[at]), type = b[at + 1]
      guard length >= 2, at + length <= b.count else { break }
      switch type {
      case 4 where length >= 9:
        skipping = b[at + 3] != 0
        if !skipping {
          interfaces.append(Interface(number: b[at + 2], alternate: b[at + 3], interfaceClass: b[at + 5],
                                      subclass: b[at + 6], interfaceProtocol: b[at + 7]))
        }
      case 5 where length >= 7 && !skipping && !interfaces.isEmpty:
        let size = le16(b, at + 4)
        interfaces[interfaces.count - 1].endpoints.append(
          Endpoint(address: b[at + 2], type: b[at + 3] & 3, maxPacket: Int(size & 0x7FF),
                   extra: Int(size >> 11) & 3, interval: b[at + 6]))
      case 0x30 where length >= 6 && !skipping && !interfaces.isEmpty:
        let i = interfaces.count - 1
        if !interfaces[i].endpoints.isEmpty { interfaces[i].endpoints[interfaces[i].endpoints.count - 1].burst = b[at + 2] }
      default:
        break
      }
      at += length
    }
  }
}

/// A hub's descriptor: its ports, wHubCharacteristics (the TT's think
/// time in bits 5-6) and how long its ports' power takes, in ms.
public struct HubDescriptor: Equatable, Sendable {
  public var ports: Int
  public var characteristics: UInt16
  public var powerOnToGood: Int

  public init?(_ b: [UInt8]) {
    guard b.count >= 7, b[1] == 0x29 || b[1] == 0x2A else { return nil }
    ports = Int(b[2])
    characteristics = le16(b, 3)
    powerOnToGood = 2 * Int(b[5])
  }

  public var thinkTime: UInt32 { UInt32(characteristics >> 5) & 3 }
}

/// xHCI's port speeds (the default Protocol Speed IDs, xHCI 1.2 §7.2.2.1.1).
public enum Speed: UInt8, Sendable {
  case full = 1, low = 2, high = 3, superSpeed = 4, superSpeedPlus = 5

  /// Endpoint 0's packet size until the device descriptor says (§4.3).
  public var defaultPacketSize0: Int {
    switch self {
    case .low, .full: 8
    case .high: 64
    case .superSpeed, .superSpeedPlus: 512
    }
  }

  public var name: String {
    switch self {
    case .low: "low"
    case .full: "full"
    case .high: "high"
    case .superSpeed: "super"
    case .superSpeedPlus: "super+"
    }
  }
}

public enum EndpointRules {
  /// The Endpoint Context's Interval, a period of 2^n × 125 µs (xHCI 1.2
  /// §6.2.3.6): a full- or low-speed interrupt endpoint's bInterval is in
  /// frames (1 ms), rounded down to a power of two; a high- or SuperSpeed
  /// one's is already an exponent, 2^(bInterval-1) microframes.
  public static func interval(_ e: Endpoint, speed: Speed) -> UInt32 {
    switch speed {
    case .low, .full:
      guard e.type == 3 else { return 0 }  // isochronous FS: unsupported here
      var frames = max(Int(e.interval), 1), n = 3
      while frames > 1 {
        frames >>= 1
        n += 1
      }
      return UInt32(min(n, 10))
    case .high, .superSpeed, .superSpeedPlus:
      guard e.type == 3 || e.type == 1 else { return 0 }
      return UInt32(min(max(Int(e.interval), 1), 16) - 1)
    }
  }

  /// xHCI's endpoint type (§6.2.3): 4 control, else the transfer type,
  /// plus 4 for IN.
  public static func type(_ e: Endpoint) -> UInt32 {
    e.type == 0 ? 4 : UInt32(e.type) + (e.isIn ? 4 : 0)
  }

  /// The most bytes it moves in one service interval (Max ESIT Payload).
  public static func esitPayload(_ e: Endpoint) -> UInt32 {
    UInt32(e.maxPacket * (e.extra + 1) * (Int(e.burst) + 1))
  }
}

/// Where a device is: its root port, and the route string of hub ports
/// below it (xHCI 1.2 §8.9, a nibble a tier); a full- or low-speed
/// device's transaction translator is the nearest high-speed hub's port.
public struct Placement: Equatable, Sendable {
  public var rootPort: Int
  public var route: UInt32 = 0
  public var depth = 0
  public var ttSlot = 0, ttPort = 0

  public init(rootPort: Int) { self.rootPort = rootPort }

  /// A device on `port` of the hub at this placement, whose slot is
  /// `hubSlot` and speed `hubSpeed`, the device's own speed `speed`.
  public func below(port: Int, hubSlot: Int, hubSpeed: Speed, speed: Speed) -> Placement {
    var p = Placement(rootPort: rootPort)
    p.depth = depth + 1
    p.route = route | UInt32(min(port, 15)) << (4 * UInt32(depth))
    if speed == .low || speed == .full {
      if hubSpeed == .high {
        (p.ttSlot, p.ttPort) = (hubSlot, port)
      } else {
        (p.ttSlot, p.ttPort) = (ttSlot, ttPort)
      }
    }
    return p
  }
}

func le16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
