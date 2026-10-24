// SPDX-License-Identifier: BSD-3-Clause

// devmgr's model (architecture §9): the devices enumeration found, PCI
// functions and ACPI's present devices. Drivers are bound to them by the
// match records each driver carries (Index.swift).

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
    /// Its clocks and resets, as CIX's tables name them (CLKT, RSTL).
    public var clocks: [Clock]
    public var resets: [Reset]
    /// Whether its driver may ask devmgr to power it (_PR0, its own or its
    /// _DSD power-supply's).
    public var powered: Bool
    /// Whether its driver talks to the SCMI agent: it has clocks or SCMI
    /// power domains.
    public var usesSCMI: Bool

    public init(path: String, hid: String?, cids: [String], status: UInt64, resources: [PlatformResource] = [],
                coherent: Bool = true, linked: [LinkedRange] = [], clocks: [Clock] = [], resets: [Reset] = [],
                powered: Bool = false, usesSCMI: Bool = false) {
      self.path = path
      self.hid = hid
      self.cids = cids
      self.status = status
      self.resources = resources
      self.coherent = coherent
      self.linked = linked
      self.clocks = clocks
      self.resets = resets
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

  /// A clock: its SCMI id and name.
  public struct Clock: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public init(id: UInt32, name: String) {
      self.id = id
      self.name = name
    }
  }

  /// A reset: its controller's path, its index there, and its name.
  public struct Reset: Equatable, Sendable {
    public var controller: String
    public var index: UInt32
    public var name: String
    public init(controller: String, index: UInt32, name: String) {
      self.controller = controller
      self.index = index
      self.name = name
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
  }

  public var bus: Bus

  public init(pci: Function) { bus = .pci(pci) }
  public init(acpi: ACPIDevice) { bus = .acpi(acpi) }

  /// The PCI function, if it is one.
  public var pci: Function? {
    switch bus {
    case .pci(let f): f
    case .acpi: nil
    }
  }

  /// The ACPI device, if it is one.
  public var acpi: ACPIDevice? {
    switch bus {
    case .pci: nil
    case .acpi(let d): d
    }
  }

  /// A name for the device's node and its driver host's service:
  /// `pci-bb:dd.f`, or `acpi-` and the path without its root
  /// (`acpi-_SB_.PCI0.SF8_.RTC_`).
  public var name: String {
    switch bus {
    case .pci(let f): "pci-" + f.address.description
    case .acpi(let d): "acpi-" + String(decoding: d.path.utf8.drop { $0 == UInt8(ascii: "\\") }, as: UTF8.self)
    }
  }

  /// Its ids for devmgr's status: `vvvv:dddd` or the HID.
  public var ids: String {
    switch bus {
    case .pci(let f): hex(UInt32(f.vendor), digits: 4) + ":" + hex(UInt32(f.device), digits: 4)
    case .acpi(let d): d.hid ?? "-"
    }
  }

  public var description: String {
    switch bus {
    case .pci(let f): "pci " + f.description
    case .acpi(let d): "acpi " + d.path + " " + (d.hid ?? "-")
    }
  }
}
