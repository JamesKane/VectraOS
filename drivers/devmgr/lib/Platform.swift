// SPDX-License-Identifier: BSD-3-Clause

// What a platform device's driver gets past its own _CRS (D74). Firmware
// links devices by name in _DSD and in tables of its own, and a driver
// needs what they name:
// - the ranges of the devices its _DSD names as its SCMI shared memory and
//   mailboxes ("shmem" and "mboxes", the arm,scmi binding's names) or
//   its DisplayPort PHY ("dp_phy", CIX's: a child of the PHY's device),
//   granted after its own ranges and named to it by `--bar=INDEX:ROLE`
//   arguments (the reset controllers its RSTL names are not: a reset
//   controller's driver owns its page, and serves its resets, D167);
// - CIX's tables of its clocks (CLKT: SCMI clock id, name, device) and
//   resets (RSTL: controller, index, device, name), shown in its
//   /dev/acpi;
// - its power resources (_PR0, its own or its _DSD power-supply's), which
//   its driver asks devmgr to turn on through /dev/acpi/power, since only
//   devmgr runs AML.
// A board rule adds what firmware's tables don't describe at all
// (`firmwareCall`), as the kernel's do (D126).

import DeviceTreeBus
import TDACPI

/// What a property or table names, read from evaluated AML.
public enum PlatformTables {
  /// CLKT's clocks: packages of the SCMI id, the name and the device; as
  /// links, the SCMI agent's, whose cell is the id.
  public static func clocks(_ table: Datum) -> [DeviceLink] {
    guard case .package(let p) = table else { return [] }
    var out: [DeviceLink] = []
    for e in p.elements {
      guard case .package(let c) = e, c.elements.count >= 2, let id = c.elements[0].integer,
        let name = c.elements[1].string
      else { continue }
      out.append(DeviceLink(kind: "clock", name: String(decoding: name, as: UTF8.self), provider: "",
                            cells: [UInt32(truncatingIfNeeded: id)]))
    }
    return out
  }

  /// RSTL's resets: packages of the controller, the index, the device and
  /// the name; the controller as its node, for the caller to name.
  public static func resets(_ table: Datum) -> [(controller: Int, index: UInt32, name: String)] {
    guard case .package(let p) = table else { return [] }
    var out: [(controller: Int, index: UInt32, name: String)] = []
    for e in p.elements {
      guard case .package(let r) = e, r.elements.count >= 4, let controller = Namespace.referencedNodes(r.elements[0]).first,
        let index = r.elements[1].integer, let name = r.elements[3].string
      else { continue }
      out.append((controller, UInt32(truncatingIfNeeded: index), String(decoding: name, as: UTF8.self)))
    }
    return out
  }

  /// The links a device's _CRS makes: each I2cSerialBus connection an
  /// `i2c` link to the controller its resource source names, the slave
  /// address its cell; each GpioInt or GpioIo an `int` or `io` `gpio`
  /// link to the controller it names, its cells the connection's pins and
  /// then its flags word (the interrupt flags of a GpioInt: bit 0 edge,
  /// bits 1-2 polarity (0 high, 1 low, 2 both), bit 3 shared, bit 4
  /// wake; the I/O flags of a GpioIo: bits 0-1 restriction, bit 3
  /// shared). The provider is the controller's namespace path, found by
  /// name from `scope` (the device), or empty where no node has it.
  public static func connections(_ crs: [Resource], in ns: Namespace, from scope: Int) -> [DeviceLink] {
    var out: [DeviceLink] = []
    for r in crs {
      switch r {
      case .serialBus(let s) where s.type == 1 && s.typeData.count >= 6:
        // The connection speed (4 bytes), then the slave address (2).
        let address = UInt32(s.typeData[4]) | UInt32(s.typeData[5]) << 8
        out.append(DeviceLink(kind: "i2c", provider: provider(s.source, ns, scope), cells: [address]))
      case .gpio(let g) where g.type <= 1:
        out.append(DeviceLink(kind: "gpio", name: g.type == 0 ? "int" : "io", provider: provider(g.source, ns, scope),
                              cells: g.pins.map { UInt32($0) } + [UInt32(g.flags)]))
      default: break
      }
    }
    return out
  }

  /// The namespace path of the node a resource source names, from
  /// `scope`; empty where none has it. A static function, not a closure
  /// over `ns`: on arm64 a short String made in a closure that captures a
  /// struct came out corrupt (CLAUDE.md), and an ACPI path is short.
  static func provider(_ source: [UInt8], _ ns: borrowing Namespace, _ scope: Int) -> String {
    guard !source.isEmpty, let n = ns.lookup(source, from: scope) else { return "" }
    let path = ns.path(n)
    return String(decoding: path, as: UTF8.self)
  }

  /// A device's _DSD properties as a `properties` file: a line `NAME
  /// VALUE`, an integer in decimal, a string as it is, a reference as
  /// its namespace path, a package of those as its elements, space apart.
  /// A property of any other kind (a buffer, a package within one) is
  /// left out.
  public static func properties(_ list: [(name: [UInt8], value: Datum)], in ns: Namespace) -> String {
    var out = ""
    for p in list {
      var words: [String] = []
      if case .package(let e) = p.value {
        for x in e.elements {
          guard let w = scalar(x, ns) else {
            words = []
            break
          }
          words.append(w)
        }
        if words.isEmpty { continue }
      } else if let w = scalar(p.value, ns) {
        words = [w]
      } else {
        continue
      }
      out += String(decoding: p.name, as: UTF8.self) + " " + words.joined(separator: " ") + "\n"
    }
    return out
  }

  /// One property value as a word (static, not nested: see `provider`).
  static func scalar(_ d: Datum, _ ns: borrowing Namespace) -> String? {
    switch d {
    case .integer(let v): return String(v)
    case .string(let s):
      var b: [UInt8] = []
      for c in s { b.append(c == 0x0A || c == 0x0D ? 0x20 : c) }
      return String(decoding: b, as: UTF8.self)
    case .reference(.node(let n)), .object(let n):
      let path = ns.path(n)
      return String(decoding: path, as: UTF8.self)
    default: return nil
    }
  }

  /// The `--bar=INDEX:ROLE` arguments for a device's linked ranges and a
  /// firmware call's memory: each after the device's own MMIO and I/O
  /// ranges, as `platformGrants` grants them, while there are BARs left.
  public static func barRoles(_ d: Device.ACPIDevice, firmwareCall: Bool) -> [(index: Int, role: String)] {
    var index = d.resources.filter {
      switch $0 {
      case .mmio, .ioport: true
      case .interrupt: false
      }
    }.count
    var out: [(index: Int, role: String)] = []
    for l in d.linked where index < 6 {
      out.append((index, l.role))
      index += 1
    }
    if firmwareCall, index < 6 { out.append((index, "firmware")) }
    return out
  }

  /// Display engines and their transmitters (D146), each by its first
  /// register range's base: the n-th transmitter goes with the n-th
  /// engine, as the CIX Sky1 lays out its five of each (engine n at
  /// 0x14010000 + n * 0x70000, its transmitter's core 0x54000 above).
  /// Pairs of indices into `engines` and `links`; extra ones of either
  /// go unpaired.
  public static func pairs(engines: [UInt64], links: [UInt64]) -> [(engine: Int, link: Int)] {
    let e = engines.indices.sorted { engines[$0] < engines[$1] }
    let l = links.indices.sorted { links[$0] < links[$1] }
    return zip(e, l).map { (engine: $0, link: $1) }
  }

  /// A device's first MMIO range's base.
  public static func firstBase(_ d: Device.ACPIDevice) -> UInt64? {
    for r in d.resources { if case .mmio(let base, _) = r { return base } }
    return nil
  }
}

/// Firmware a driver calls through SMC where the tables don't describe
/// it: the function's id and the memory its messages pass through.
public struct FirmwareCall: Equatable, Sendable {
  public var function: UInt32
  public var memory: UInt64
  public var size: UInt64

  public init(function: UInt32, memory: UInt64, size: UInt64) {
    self.function = function
    self.memory = memory
    self.size = size
  }

  /// The board rule for device `hid` on the firmware that names itself
  /// `oemID` and `oemTableID` in its FADT. The CIX Sky1's (`CIXTEK` /
  /// `SKY1EDK2`): its SCMI agent (CIXHA006) also has TF-A's, for power
  /// domains, through SiP function 0xC2000001 and shared memory at
  /// 0x84380000 (Linux's sky1.dtsi, arm,scmi-smc), which ACPI leaves out.
  public static func rule(oemID: [UInt8], oemTableID: [UInt8], hid: String?) -> FirmwareCall? {
    guard oemID == Array("CIXTEK".utf8), oemTableID == Array("SKY1EDK2".utf8),
      hid.map({ $0.utf8.elementsEqual("CIXHA006".utf8) }) == true
    else { return nil }
    return FirmwareCall(function: 0xC200_0001, memory: 0x8438_0000, size: 0x80)
  }
}
