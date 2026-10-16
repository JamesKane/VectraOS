// SPDX-License-Identifier: BSD-3-Clause

// Devices (ACPI 6.5 §6): what a device is (_HID, _CID, _UID, _ADR), whether
// it's there (_STA), their initialization (_INI), its resources (_CRS),
// PCI interrupt routing (_PRT) and capability handshakes (_OSC).

/// _STA's bits (§6.3.7).
public struct DeviceStatus: Equatable, Sendable {
  public var raw: UInt64
  public init(raw: UInt64) { self.raw = raw }
  /// No _STA: present, enabled, shown and functioning.
  public static let assumed = DeviceStatus(raw: 0x0F)
  public var present: Bool { raw & 1 != 0 }
  public var enabled: Bool { raw & 2 != 0 }
  public var functioning: Bool { raw & 8 != 0 }
}

/// One _PRT entry (§6.2.13): a slot's interrupt pin, routed either to a
/// global system interrupt or through a link device.
public struct PCIRoute: Equatable, Sendable {
  /// The slot (device number); the function part of _PRT's address is
  /// always 0xFFFF, any function.
  public var device: UInt16
  /// 0-3: INTA-INTD.
  public var pin: UInt8
  /// The link device, or nil: then `index` is the GSI.
  public var link: Int?
  public var index: UInt32
}

extension Namespace {
  /// A compressed EISA ID as text (§6.1.5): three letters, five bits each,
  /// then four hex digits ("PNP0A08").
  public static func eisaID(_ v: UInt64) -> [UInt8] {
    let b0 = UInt8(truncatingIfNeeded: v), b1 = UInt8(truncatingIfNeeded: v >> 8)
    let b2 = UInt8(truncatingIfNeeded: v >> 16), b3 = UInt8(truncatingIfNeeded: v >> 24)
    let digits: [UInt8] = Array("0123456789ABCDEF".utf8)
    return [0x40 + ((b0 >> 2) & 0x1F), 0x40 + ((b0 & 3) << 3 | b1 >> 5), 0x40 + (b1 & 0x1F),
            digits[Int(b2 >> 4)], digits[Int(b2 & 0xF)], digits[Int(b3 >> 4)], digits[Int(b3 & 0xF)]]
  }

  /// The nodes enumeration visits: devices, processors, power resources
  /// and thermal zones, in tree order.
  public func deviceNodes() -> [Int] {
    var out: [Int] = []
    var stack = [Self.root]
    while let n = stack.popLast() {
      switch nodes[n].object {
      case .device, .processor, .powerResource, .thermalZone: out.append(n)
      default: break
      }
      stack += children(n).reversed()
    }
    return out
  }

  /// A method or object under `device`, evaluated; nil if it isn't there.
  public mutating func childValue<H: ACPIHost>(_ device: Int, _ name: StaticString, host: H) throws(ACPIError) -> Datum? {
    guard let c = child(device, NameSeg.make(name)) else { return nil }
    return try evaluate(c, host: host)
  }

  /// _STA, or present-and-functioning when there's none (§6.3.7).
  public mutating func status<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError) -> DeviceStatus {
    guard let v = try childValue(device, "_STA", host: host) else { return .assumed }
    guard let raw = v.integer else { throw ACPIError.typeMismatch }
    return DeviceStatus(raw: raw)
  }

  /// An ID as text: an integer is an EISA ID; a string is itself.
  func identifier(_ d: Datum) throws(ACPIError) -> [UInt8] {
    switch d {
    case .integer(let v): return Self.eisaID(v)
    case .string(let s): return s
    default: throw ACPIError.typeMismatch
    }
  }

  /// _HID (§6.1.5).
  public mutating func hardwareID<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError) -> [UInt8]? {
    guard let v = try childValue(device, "_HID", host: host) else { return nil }
    return try identifier(v)
  }

  /// _CID (§6.1.2): one ID or a package of them.
  public mutating func compatibleIDs<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError) -> [[UInt8]] {
    guard let v = try childValue(device, "_CID", host: host) else { return [] }
    if case .package(let p) = v {
      var out: [[UInt8]] = []
      for e in p.elements { out.append(try identifier(e)) }
      return out
    }
    return [try identifier(v)]
  }

  /// _UID (§6.1.12): an integer in decimal, or the string.
  public mutating func uniqueID<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError) -> [UInt8]? {
    guard let v = try childValue(device, "_UID", host: host) else { return nil }
    switch v {
    case .integer(let i):
      var digits: [UInt8] = []
      var x = i
      repeat {
        digits.append(UInt8(x % 10) + 0x30)
        x /= 10
      } while x != 0
      return digits.reversed()
    case .string(let s): return s
    default: throw ACPIError.typeMismatch
    }
  }

  /// _ADR (§6.1.1).
  public mutating func address<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError) -> UInt64? {
    guard let v = try childValue(device, "_ADR", host: host) else { return nil }
    guard let a = v.integer else { throw ACPIError.typeMismatch }
    return a
  }

  /// _CRS (§6.2.2), decoded.
  public mutating func currentResources<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError) -> [Resource]? {
    guard let v = try childValue(device, "_CRS", host: host) else { return nil }
    guard let bytes = v.bytes else { throw ACPIError.typeMismatch }
    return try Resources.decode(bytes)
  }

  /// _PRT (§6.2.13): a package of {address, pin, source, source index}.
  public mutating func routing<H: ACPIHost>(_ bridge: Int, host: H) throws(ACPIError) -> [PCIRoute]? {
    guard let v = try childValue(bridge, "_PRT", host: host) else { return nil }
    guard let entries = v.elements else { throw ACPIError.typeMismatch }
    var out: [PCIRoute] = []
    for e in entries {
      guard let f = e.elements, f.count == 4, let address = f[0].integer, let pin = f[1].integer,
        let index = f[3].integer
      else { throw ACPIError.typeMismatch }
      var link: Int? = nil
      switch f[2] {
      case .integer: break  // 0: a GSI
      case .reference(.node(let n)): link = n
      case .object(let n): link = n
      case .string(let s): link = lookup(s)
      default: throw ACPIError.typeMismatch
      }
      out.append(PCIRoute(device: UInt16(truncatingIfNeeded: address >> 16), pin: UInt8(truncatingIfNeeded: pin),
                          link: link, index: UInt32(truncatingIfNeeded: index)))
    }
    return out
  }

  /// A UUID's 16 bytes as ToUUID gives them (§19.6.142): the first three
  /// groups little-endian, the rest in order. "33DB4D5B-1FF7-401C-9657-7441C03DD766".
  public static func uuid(_ text: StaticString) -> [UInt8] {
    let t = unsafe text.withUTF8Buffer { unsafe Array($0) }.filter { $0 != 0x2D }
    func hex(_ c: UInt8) -> UInt8 { c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x57 }
    var b: [UInt8] = []
    for i in stride(from: 0, to: t.count - 1, by: 2) { b.append(hex(t[i]) << 4 | hex(t[i + 1])) }
    guard b.count == 16 else { return b }
    return [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + Array(b[8...])
  }

  /// _OSC (§6.2.11): the capabilities the OS asks for (the first dword is
  /// the query/status dword), and the dwords the firmware grants back.
  public mutating func operatingSystemCapabilities<H: ACPIHost>(_ device: Int, uuid: [UInt8], revision: UInt64,
                                                               _ capabilities: [UInt32], host: H) throws(ACPIError) -> [UInt32]? {
    guard let osc = child(device, NameSeg.make("_OSC")) else { return nil }
    var buffer: [UInt8] = []
    for c in capabilities { for i in 0..<4 { buffer.append(UInt8(truncatingIfNeeded: c >> (8 * UInt32(i)))) } }
    let result = try evaluate(osc, [.buffer(BufferObject(uuid)), .integer(revision),
                                    .integer(UInt64(capabilities.count)), .buffer(BufferObject(buffer))], host: host)
    guard let bytes = result.bytes else { throw ACPIError.typeMismatch }
    return stride(from: 0, to: bytes.count - 3, by: 4).map { bytes.le32($0) }
  }

  /// Device initialization (§6.5.1): \_SB._INI, then each device's _INI,
  /// parents before children, where _STA says present. A device neither
  /// present nor functioning has its children skipped. Returns the
  /// devices whose _STA or _INI failed, with the error, and goes on.
  public mutating func initializeDevices<H: ACPIHost>(host: H) -> [(device: Int, error: ACPIError)] {
    var failed: [(device: Int, error: ACPIError)] = []
    if let sb = lookup("\\_SB"), let ini = child(sb, NameSeg.make("_INI")) {
      do { _ = try evaluate(ini, host: host) } catch { failed.append((sb, error)) }
    }
    var stack = children(Self.root).reversed().map { $0 }
    while let n = stack.popLast() {
      var descend = true
      switch nodes[n].object {
      case .device, .processor, .thermalZone:
        let s: DeviceStatus
        do { s = try status(n, host: host) } catch {
          failed.append((n, error))
          continue
        }
        if s.present, let ini = child(n, NameSeg.make("_INI")) {
          do { _ = try evaluate(ini, host: host) } catch { failed.append((n, error)) }
        }
        descend = s.present || s.functioning
      default: break
      }
      if descend { stack += children(n).reversed() }
    }
    return failed
  }
}
