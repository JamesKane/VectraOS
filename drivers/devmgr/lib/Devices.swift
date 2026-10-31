// SPDX-License-Identifier: BSD-3-Clause

// devmgr's model (architecture §9): the devices enumeration found, PCI
// functions, ACPI's present devices and a devicetree's devices (D154).
// Drivers are bound to them by the match records each driver carries
// (Index.swift).

import DeviceTreeBus
import PCI
import Sys

public struct Device: Sendable {
  /// An ACPI device: its namespace path (`\\_SB_.PCI0.SF8_.RTC_`), its
  /// hardware id and compatible ids (`PNP0B00`, `ACPI0007`), and _STA.
  public struct ACPIDevice: Equatable, Sendable {
    public var path: String
    public var hid: String?
    public var cids: [String]
    public var status: UInt64
    /// What its _CRS names (D74: a platform device's driver is given them).
    public var resources: [PlatformResource]
    /// Whether its DMA is cache coherent: _CCA, coherent when there's none.
    public var coherent: Bool
    /// Other devices' ranges it is granted after its own (Platform.swift).
    public var linked: [LinkedRange]
    /// Its clocks and resets, as CIX's tables name them (CLKT, RSTL):
    /// links, a clock's cell its SCMI id, a reset's its index on the
    /// controller that provides it.
    public var links: [DeviceLink]
    /// Whether its driver may ask devmgr to power it (_PR0, its own or its
    /// _DSD power-supply's).
    public var powered: Bool
    /// Whether its driver talks to the SCMI agent: it has clocks or SCMI
    /// power domains.
    public var usesSCMI: Bool

    public init(path: String, hid: String?, cids: [String], status: UInt64, resources: [PlatformResource] = [],
                coherent: Bool = true, linked: [LinkedRange] = [], links: [DeviceLink] = [],
                powered: Bool = false, usesSCMI: Bool = false) {
      self.path = path
      self.hid = hid
      self.cids = cids
      self.status = status
      self.resources = resources
      self.coherent = coherent
      self.linked = linked
      self.links = links
      self.powered = powered
      self.usesSCMI = usesSCMI
    }
  }

  /// A range of another device's _CRS a platform device is granted, and
  /// why: `shmem`, `mboxes` or `reset`.
  public struct LinkedRange: Equatable, Sendable {
    public var role: String
    public var base: UInt64
    public var size: UInt64
    public init(role: String, base: UInt64, size: UInt64) {
      self.role = role
      self.base = base
      self.size = size
    }
  }

  /// A range or interrupt a platform device's _CRS names, as devmgr
  /// grants it.
  public enum PlatformResource: Equatable, Sendable {
    case mmio(base: UInt64, size: UInt64)
    case ioport(base: UInt16, count: UInt16)
    case interrupt(UInt32, Interrupt.Mode)
  }

  public enum Bus: Sendable {
    case pci(Function)
    case acpi(ACPIDevice)
    case dt(TreeDevice)
  }

  public var bus: Bus

  public init(pci: Function) { bus = .pci(pci) }
  public init(acpi: ACPIDevice) { bus = .acpi(acpi) }
  public init(dt: TreeDevice) { bus = .dt(dt) }

  /// The PCI function, if it is one.
  public var pci: Function? {
    switch bus {
    case .pci(let f): f
    case .acpi, .dt: nil
    }
  }

  /// The ACPI device, if it is one.
  public var acpi: ACPIDevice? {
    switch bus {
    case .pci, .dt: nil
    case .acpi(let d): d
    }
  }

  /// The devicetree device, if it is one.
  public var dt: TreeDevice? {
    switch bus {
    case .pci, .acpi: nil
    case .dt(let d): d
    }
  }

  /// A name for the device's node and its driver host's service:
  /// `pci-bb:dd.f`, `acpi-` and the path without its root
  /// (`acpi-_SB_.PCI0.SF8_.RTC_`), or `dt-` and its node's name
  /// (`dt-ethernet@cac80000`; TreeDevice.name).
  public var name: String {
    switch bus {
    case .pci(let f): "pci-" + f.address.description
    case .acpi(let d): "acpi-" + String(decoding: d.path.utf8.drop { $0 == UInt8(ascii: "\\") }, as: UTF8.self)
    case .dt(let d): "dt-" + d.name
    }
  }

  /// Its ids for devmgr's status: `vvvv:dddd`, the HID, or the first compatible.
  public var ids: String {
    switch bus {
    case .pci(let f): hex(UInt32(f.vendor), digits: 4) + ":" + hex(UInt32(f.device), digits: 4)
    case .acpi(let d): d.hid ?? "-"
    case .dt(let d): d.compatibles.first ?? "-"
    }
  }

  public var description: String {
    switch bus {
    case .pci(let f): "pci " + f.description
    case .acpi(let d): "acpi " + d.path + " " + (d.hid ?? "-")
    case .dt(let d): "dt " + d.path + " " + (d.compatibles.first ?? "-")
    }
  }
}

extension TreeDevice {
  /// Its line in devmgr's `devicetree`: `/soc/network-bus/ethernet@cac80000
  /// spacemit,k1-emac mmio 0xcac80000+0x420 irq 131 level-high
  /// noncoherent`, then a line for each link, `clock core
  /// /soc/system-controller@d4282800 10` (`-` for no name or no device), and
  /// for each note, indented.
  public var summary: String {
    path + " " + compatibles.joined(separator: ",")
      + ranges.map { " mmio 0x\(String($0.base, radix: 16))+0x\(String($0.size, radix: 16))" }.joined()
      + interrupts.map { " irq \($0.gsi) \($0.trigger.description)" }.joined()
      + (coherent ? "" : " noncoherent")
      + iommus.map { " iommu \($0.unit)" + $0.id.map { " 0x\(String($0, radix: 16))" }.joined() }.joined()
      + "\n" + links.map { "  " + $0.summary + "\n" }.joined() + notes.map { "  \($0)\n" }.joined()
  }
}

extension DeviceLink {
  /// `KIND NAME PROVIDER [NODE] CELLS...`: `-` for no name or no
  /// provider, and the node named where it isn't the provider's own (a pin
  /// state).
  public var summary: String {
    kind + " " + (name.isEmpty ? "-" : name) + " " + (provider.isEmpty ? "-" : provider)
      + (same(target, provider) ? "" : " " + target) + cells.map { " \($0)" }.joined()
  }
}
