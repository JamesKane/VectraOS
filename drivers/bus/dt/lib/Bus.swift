// SPDX-License-Identifier: BSD-3-Clause

// The devicetree as a bus (D154): the devices a flattened tree describes,
// which devmgr binds beside ACPI's and PCI's. A device is an enabled node
// with a `compatible` on the root or on a `simple-bus`; any other node's
// children are its driver's to read (an I2C controller's, an Ethernet
// MAC's PHY), as Linux's platform bus leaves them. Its `reg` ranges are
// translated to CPU addresses through each bus's `ranges`. Its interrupts
// (`interrupts` through `interrupt-parent`, or `interrupts-extended`) are
// followed through each nexus's `interrupt-map` to the controller the
// kernel owns, a PLIC, an APLIC or a GIC, and given as that controller's
// GSI, the numbering lib/dtacpi gave the kernel's tables (PLIC and APLIC
// sources from 0, a GIC's INTIDs); one that ends at another controller (a
// GPIO block's) is a provider's: a link, not a grant. Its DMA reaches
// as far as each bus's `dma-ranges` maps addresses unchanged. Its
// `iommus` name their units. Nodes the kernel owns, its interrupt
// controllers and timers, are not devices.
//
// Its links are what its phandles name (D154): `clocks`, `resets`,
// `power-domains` and `phys`, each with its specifier's cells and its
// name from the matching `-names` list; `pinctrl-N`, the state named by
// `pinctrl-names`; each `NAME-supply`, and each `NAME-gpios` with its
// cells; an interrupt on a provider's controller; and a vendor's
// reference into a system controller's registers, such as the K1's
// `spacemit,apmu` (a `syscon` link, its cells the offset). A link's
// provider is the device whose node is the one named, or holds it (a pin
// controller holds its states).
//
// Its properties, and those of the nodes under it (an Ethernet MAC's
// MDIO bus and PHY), are text for its driver: a line each, `NAME VALUE`,
// the value as dtc writes one, strings quoted, cells in angle brackets,
// other bytes in square ones; a property of a node under it is named by
// that node's path below the device's (`mdio-bus/phy@1/reg <0x1>`).

import Fdt

/// A link from a device to what provides one of its clocks, resets,
/// power domains, PHYs, pin states, supplies, GPIOs, interrupts or system
/// controllers' registers: devmgr's
/// one record of them, which a tree's phandles fill and ACPI's tables
/// too (CIX's CLKT and RSTL).
public struct DeviceLink: Equatable, Sendable {
  /// `clock`, `reset`, `power-domain`, `phy`, `pinctrl`, `supply`,
  /// `gpio`, `interrupt` or `syscon`.
  public var kind: String
  /// Its name for the consumer (`core`, `vmmc`, `default`), or empty.
  public var name: String
  /// The providing device: its node's path or ACPI path; empty where no
  /// device holds the node named, or where the tables don't say (CLKT's
  /// clocks, the SCMI agent's).
  public var provider: String
  /// The node named, the provider's own or one it holds (a pin state).
  public var target: String
  /// The specifier's cells: which of the provider's clocks or resets.
  public var cells: [UInt32]

  public init(kind: String, name: String = "", provider: String, target: String? = nil, cells: [UInt32] = []) {
    self.kind = kind
    self.name = name
    self.provider = provider
    self.target = target ?? provider
    self.cells = cells
  }
}

/// A device the tree describes, as devmgr binds it.
public struct TreeDevice: Equatable, Sendable {
  public struct Range: Equatable, Sendable {
    public var base: UInt64
    public var size: UInt64
    public init(base: UInt64, size: UInt64) {
      self.base = base
      self.size = size
    }
  }

  /// A specifier's trigger, its flags cell's IRQ_TYPE (level-high where
  /// it has none, as a PLIC's).
  public enum Trigger: Equatable, Sendable {
    case levelHigh, levelLow, edgeRising, edgeFalling

    public var description: String {
      switch self {
      case .levelHigh: "level-high"
      case .levelLow: "level-low"
      case .edgeRising: "edge-rising"
      case .edgeFalling: "edge-falling"
      }
    }
  }

  /// An interrupt on the controller the kernel owns.
  public struct Interrupt: Equatable, Sendable {
    public var gsi: UInt32
    public var trigger: Trigger
    public init(gsi: UInt32, trigger: Trigger) {
      self.gsi = gsi
      self.trigger = trigger
    }
  }

  /// An IOMMU unit `iommus` names (its node's path) and the specifier's
  /// cells, its stream or device id.
  public struct IOMMU: Equatable, Sendable {
    public var unit: String
    public var id: [UInt32]
    public init(unit: String, id: [UInt32]) {
      self.unit = unit
      self.id = id
    }
  }

  /// Its node's path (`/soc/network-bus/ethernet@cac80000`).
  public var path: String
  /// A name for devmgr: the node's (`ethernet@cac80000`), or where two
  /// devices' nodes share one, the path's components joined by dots.
  public var name: String
  /// `compatible`, most specific first.
  public var compatibles: [String]
  /// `reg`'s ranges, in order, at the addresses the CPU reaches them by.
  public var ranges: [Range]
  public var interrupts: [Interrupt]
  /// Whether its DMA is cache coherent: the nearest `dma-coherent` or
  /// `dma-noncoherent` on it or a bus above it, else the arch's default.
  public var coherent: Bool
  /// The address bits its DMA reaches memory by: for each bus above it
  /// whose `dma-ranges` has a range from bus address 0 to CPU address 0,
  /// that range's size rounded down to a power of two, the least of them
  /// (the SpacemiT K1's storage bus's 2 GiB: 31); 64 where none says.
  public var dmaBits: UInt32 = 64
  public var iommus: [IOMMU]
  /// Its links, in its properties' order.
  public var links: [DeviceLink]
  /// What couldn't be resolved: a range no bus translates, an interrupt
  /// no controller takes, a phandle to no node.
  public var notes: [String]
  /// Its node's properties and those of the nodes under it, as text: a
  /// line each (above).
  public var properties: String

  public init(path: String, name: String, compatibles: [String], ranges: [Range] = [], interrupts: [Interrupt] = [],
              coherent: Bool = true, iommus: [IOMMU] = [], links: [DeviceLink] = [], notes: [String] = [], properties: String = "") {
    self.path = path
    self.name = name
    self.compatibles = compatibles
    self.ranges = ranges
    self.interrupts = interrupts
    self.coherent = coherent
    self.iommus = iommus
    self.links = links
    self.notes = notes
    self.properties = properties
  }
}

public enum DeviceTreeBus {
  /// The devices `tree` describes, in document order. `coherentByDefault`
  /// is the arch's DMA default where the tree says nothing: coherent on
  /// RISC-V, not on arm64.
  public static func devices(_ tree: borrowing Fdt, coherentByDefault: Bool) -> [TreeDevice] {
    guard let root = tree.root else { return [] }
    var phandles: [Labelled] = []
    label(tree, root, path: "", depth: 0, &phandles)
    var out: [TreeDevice] = [], nodes: [Int] = []
    var ancestors = [root]
    walk(tree, root, path: "", &ancestors, interruptParent: tree.u32(root, "interrupt-parent"),
         coherent: coherence(tree, root) ?? coherentByDefault, dmaBits: 64, phandles, &out, &nodes)
    // Links once every device is known: a provider may come later.
    let paths = out.map { $0.path }
    for i in out.indices {
      links(tree, nodes[i], phandles, paths, &out[i])
      // A PCI host's root ports' links are the host's: their PHYs and
      // their slots' supplies, which Linux's hosts read from the port.
      if strings(tree, nodes[i], "device_type").contains(where: { same($0, "pci") }) {
        var child = tree.firstChild(of: nodes[i])
        while let c = child {
          child = tree.nextSibling(of: c)
          guard tree.isEnabled(c), strings(tree, c, "device_type").contains(where: { same($0, "pci") }) else { continue }
          links(tree, c, phandles, paths, &out[i])
        }
      }
      for l in implied where out[i].compatibles.contains(where: { same($0, l.consumer) }) {
        guard let p = out.first(where: { d in d.compatibles.contains { same($0, l.provider) } }) else { continue }
        out[i].links.append(DeviceLink(kind: l.kind, name: l.name, provider: p.path))
      }
      for j in out[i].links.indices where out[i].links[j].provider.isEmpty {
        out[i].links[j].provider = holder(paths, out[i].links[j].target)
      }
    }
    // A node's name for devmgr, unless another device's node has it too.
    let leaves = out.map { last($0.path) }
    var names = leaves
    for i in leaves.indices where leaves.indices.contains(where: { $0 != i && same(leaves[$0], leaves[i]) }) {
      names[i] = String(decoding: out[i].path.utf8.dropFirst().map { $0 == UInt8(ascii: "/") ? UInt8(ascii: ".") : $0 },
                        as: UTF8.self)
    }
    for i in out.indices { out[i].name = names[i] }
    return out
  }

  /// Links a binding implies and no phandle names: a device needs
  /// another's, by its `compatible`. The K1's PCIe PHYs for ports B and C
  /// take their receiver and transmitter termination from the combo
  /// PHY's calibration (Linux's phy-k1-pcie.c).
  static let implied: [(consumer: String, provider: String, kind: String, name: String)] = [
    ("spacemit,k1-pcie-phy", "spacemit,k1-combo-phy", "phy", "calibration"),
  ]

  /// A node with a phandle: the phandle, the node and its path.
  struct Labelled {
    var phandle: UInt32
    var node: Int
    var path: String
  }

  static func label(_ t: borrowing Fdt, _ node: Int, path: String, depth: Int, _ out: inout [Labelled]) {
    if let p = t.u32(node, "phandle") ?? t.u32(node, "linux,phandle") {
      out.append(Labelled(phandle: p, node: node, path: path.isEmpty ? "/" : path))
    }
    guard depth < 32 else { return }
    var child = t.firstChild(of: node)
    while let c = child {
      label(t, c, path: path + "/" + string(t, t.name(of: c)), depth: depth + 1, &out)
      child = t.nextSibling(of: c)
    }
  }

  /// Each device among `bus`'s children, and its buses' devices.
  static func walk(_ t: borrowing Fdt, _ bus: Int, path: String, _ ancestors: inout [Int], interruptParent: UInt32?,
                   coherent: Bool, dmaBits: UInt32, _ phandles: [Labelled], _ out: inout [TreeDevice],
                   _ nodes: inout [Int]) {
    var child = t.firstChild(of: bus)
    while let c = child {
      child = t.nextSibling(of: c)
      let compatibles = strings(t, c, "compatible")
      guard t.isEnabled(c), !compatibles.isEmpty else { continue }
      let here = path + "/" + string(t, t.name(of: c))
      let parent = t.u32(c, "interrupt-parent") ?? interruptParent
      let dma = coherence(t, c) ?? coherent
      if compatibles.contains(where: { same($0, "simple-bus") }) {
        guard ancestors.count < 16 else { continue }
        let reach = min(dmaBits, identityBits(t, c, bus) ?? 64)
        ancestors.append(c)
        walk(t, c, path: here, &ancestors, interruptParent: parent, coherent: dma, dmaBits: reach, phandles, &out,
             &nodes)
        ancestors.removeLast()
        continue
      }
      guard !compatibles.contains(where: { k in kernels.contains { same($0, k) } }) else { continue }
      var device = TreeDevice(path: here, name: "", compatibles: compatibles, coherent: dma)
      device.dmaBits = dmaBits
      ranges(t, c, ancestors, &device)
      interrupts(t, c, interruptParent: parent, phandles, &device)
      iommus(t, c, phandles, &device)
      device.properties = properties(t, c, under: "", depth: 0)
      out.append(device)
      nodes.append(c)
    }
  }

  /// What the kernel owns, and so isn't a device: the interrupt
  /// controllers it drives and the timers it reads.
  static let kernels: [String] = [
    "riscv,plic0", "sifive,plic-1.0.0", "riscv,aplic", "riscv,imsics", "sifive,clint0", "riscv,clint0",
    "riscv,aclint-mtimer", "riscv,aclint-mswi", "riscv,aclint-sswi",
    "arm,gic-v3", "arm,gic-400", "arm,cortex-a15-gic", "arm,gic-v3-its", "arm,armv8-timer",
  ]

  // MARK: Ranges

  /// `node`'s `reg`, each range translated up through its buses' `ranges`.
  static func ranges(_ t: borrowing Fdt, _ node: Int, _ ancestors: [Int], _ device: inout TreeDevice) {
    guard let reg = t.property(node, "reg"), let bus = ancestors.last else { return }
    let ac = cellCount(t, bus, "#address-cells", 2), sc = cellCount(t, bus, "#size-cells", 1)
    guard ac >= 1 else { return }
    var at = reg.lowerBound, index = 0
    while at + 4 * (ac + sc) <= reg.upperBound {
      if let address = cells(t, at, ac), let size = cells(t, at + 4 * ac, sc),
        let base = translate(t, address, ancestors)
      {
        device.ranges.append(TreeDevice.Range(base: base, size: size))
      } else {
        device.notes.append("reg \(index) not translated")
      }
      at += 4 * (ac + sc)
      index += 1
    }
  }

  /// `address`, on the last of `ancestors`, as the CPU reaches it: each
  /// bus's `ranges` from there up to the root's children (empty is the
  /// same addresses); nil where a bus has none or no entry covers it.
  static func translate(_ t: borrowing Fdt, _ address: UInt64, _ ancestors: [Int]) -> UInt64? {
    var a = address
    var i = ancestors.count - 1
    while i > 0 {
      let bus = ancestors[i], parent = ancestors[i - 1]
      guard let r = t.property(bus, "ranges") else { return nil }
      if !r.isEmpty {
        let cac = cellCount(t, bus, "#address-cells", 2), pac = cellCount(t, parent, "#address-cells", 2)
        let sc = cellCount(t, bus, "#size-cells", 1), stride = 4 * (cac + pac + sc)
        guard stride > 0 else { return nil }
        var at = r.lowerBound
        var found = false
        while at + stride <= r.upperBound {
          if let child = cells(t, at, cac), let to = cells(t, at + 4 * cac, pac), let size = cells(t, at + 4 * (cac + pac), sc),
            a >= child, a - child < size
          {
            a = to + (a - child)
            found = true
            break
          }
          at += stride
        }
        guard found else { return nil }
      }
      i -= 1
    }
    return a
  }

  // MARK: Interrupts

  /// `node`'s interrupts: `interrupts-extended`'s, each on the controller
  /// it names, or `interrupts`', on its interrupt parent.
  static func interrupts(_ t: borrowing Fdt, _ node: Int, interruptParent: UInt32?, _ phandles: [Labelled],
                         _ device: inout TreeDevice) {
    let unit = unitAddress(t, node)
    if let list = t.property(node, "interrupts-extended") {
      var at = list.lowerBound
      while at + 4 <= list.upperBound {
        guard let controller = find(phandles, t.be32(at)), let n = interruptCells(t, controller.node),
          at + 4 + 4 * n <= list.upperBound
        else {
          device.notes.append("interrupts-extended unreadable")
          return
        }
        resolve(t, controller.node, words(t, at + 4, n), unit: unit, phandles, &device)
        at += 4 + 4 * n
      }
      return
    }
    guard let list = t.property(node, "interrupts") else { return }
    guard let p = interruptParent, let controller = find(phandles, p), let n = interruptCells(t, controller.node), n > 0
    else {
      device.notes.append("interrupts without an interrupt parent")
      return
    }
    var at = list.lowerBound
    while at + 4 * n <= list.upperBound {
      resolve(t, controller.node, words(t, at, n), unit: unit, phandles, &device)
      at += 4 * n
    }
  }

  /// Follows `specifier` on `start` through each nexus's `interrupt-map`
  /// to a controller: the kernel's gives the device an interrupt; any
  /// other, a note.
  static func resolve(_ t: borrowing Fdt, _ start: Int, _ specifier: [UInt32], unit: [UInt32], _ phandles: [Labelled],
                      _ device: inout TreeDevice) {
    var current = start, spec = specifier, unit = unit
    for _ in 0..<8 {
      if t.has(current, "interrupt-controller") {
        if let i = kernelInterrupt(t, current, spec) {
          device.interrupts.append(i)
        } else {
          device.links.append(DeviceLink(kind: "interrupt", provider: "", target: path(phandles, current), cells: spec))
        }
        return
      }
      guard let map = t.property(current, "interrupt-map") else { break }
      let ac = cellCount(t, current, "#address-cells", 0), ic = cellCount(t, current, "#interrupt-cells", 0)
      var key = (0..<ac).map { $0 < unit.count ? unit[$0] : 0 } + (0..<ic).map { $0 < spec.count ? spec[$0] : 0 }
      if let m = t.property(current, "interrupt-map-mask"), m.count == 4 * (ac + ic) {
        for i in key.indices { key[i] &= t.be32(m.lowerBound + 4 * i) }
      }
      var at = map.lowerBound
      var next: (node: Int, unit: [UInt32], spec: [UInt32])?
      while next == nil, at + 4 * (ac + ic + 1) <= map.upperBound {
        let entry = words(t, at, ac + ic)
        guard let parent = find(phandles, t.be32(at + 4 * (ac + ic))), let pic = interruptCells(t, parent.node) else { break }
        let pac = cellCount(t, parent.node, "#address-cells", 0)
        guard at + 4 * (ac + ic + 1 + pac + pic) <= map.upperBound else { break }
        if entry == key {
          let p = at + 4 * (ac + ic + 1)
          next = (parent.node, words(t, p, pac), words(t, p + 4 * pac, pic))
        }
        at += 4 * (ac + ic + 1 + pac + pic)
      }
      guard let next else { break }
      (current, unit, spec) = next
    }
    device.notes.append("interrupt \(specifier.first ?? 0) unresolved")
  }

  /// `spec` on `controller` as its GSI, if the kernel owns `controller`:
  /// a PLIC's or APLIC's source (and its IRQ_TYPE cell, where it has
  /// one), or a GIC's SPI (32 up) or PPI (16 up).
  static func kernelInterrupt(_ t: borrowing Fdt, _ controller: Int, _ spec: [UInt32]) -> TreeDevice.Interrupt? {
    if t.contains(controller, "compatible", "riscv,plic0") || t.contains(controller, "compatible", "sifive,plic-1.0.0")
      || t.contains(controller, "compatible", "riscv,aplic")
    {
      guard let source = spec.first else { return nil }
      return TreeDevice.Interrupt(gsi: source, trigger: spec.count >= 2 ? trigger(spec[1]) : .levelHigh)
    }
    if t.contains(controller, "compatible", "arm,gic-v3") || t.contains(controller, "compatible", "arm,gic-400")
      || t.contains(controller, "compatible", "arm,cortex-a15-gic")
    {
      guard spec.count >= 3, spec[0] <= 1 else { return nil }
      return TreeDevice.Interrupt(gsi: spec[1] + (spec[0] == 0 ? 32 : 16), trigger: trigger(spec[2]))
    }
    return nil
  }

  /// IRQ_TYPE's low bits (dt-bindings/interrupt-controller/irq.h).
  static func trigger(_ flags: UInt32) -> TreeDevice.Trigger {
    switch flags & 0xF {
    case 1, 3: .edgeRising
    case 2: .edgeFalling
    case 8: .levelLow
    default: .levelHigh
    }
  }

  /// `node`'s unit address for an `interrupt-map`: its `reg`'s cells.
  static func unitAddress(_ t: borrowing Fdt, _ node: Int) -> [UInt32] {
    guard let reg = t.property(node, "reg") else { return [] }
    return words(t, reg.lowerBound, min(reg.count / 4, 4))
  }

  static func interruptCells(_ t: borrowing Fdt, _ node: Int) -> Int? {
    t.u32(node, "#interrupt-cells").map { Int($0) }
  }

  // MARK: IOMMUs

  static func iommus(_ t: borrowing Fdt, _ node: Int, _ phandles: [Labelled], _ device: inout TreeDevice) {
    guard let list = t.property(node, "iommus") else { return }
    var at = list.lowerBound
    while at + 4 <= list.upperBound {
      guard let unit = find(phandles, t.be32(at)) else { break }
      let n = cellCount(t, unit.node, "#iommu-cells", 0)
      guard at + 4 + 4 * n <= list.upperBound else { break }
      device.iommus.append(TreeDevice.IOMMU(unit: unit.path, id: words(t, at + 4, n)))
      at += 4 + 4 * n
    }
  }

  // MARK: Links

  /// `node`'s links, in its properties' order (each provider still to be
  /// found: `holder`).
  static func links(_ t: borrowing Fdt, _ node: Int, _ phandles: [Labelled], _ paths: [String],
                    _ device: inout TreeDevice) {
    var property = t.firstProperty(of: node)
    while let p = property {
      property = t.nextProperty(after: p)
      guard let (n, value) = t.property(at: p) else { continue }
      let name = bytes(t, n)
      if equal(name, "clocks") {
        specifiers(t, node, value, kind: "clock", cells: "#clock-cells", names: t.property(node, "clock-names"), phandles,
                   &device)
      } else if equal(name, "resets") {
        specifiers(t, node, value, kind: "reset", cells: "#reset-cells", names: t.property(node, "reset-names"), phandles,
                   &device)
      } else if equal(name, "power-domains") {
        specifiers(t, node, value, kind: "power-domain", cells: "#power-domain-cells",
                   names: t.property(node, "power-domain-names"), phandles, &device)
      } else if equal(name, "phys") {
        specifiers(t, node, value, kind: "phy", cells: "#phy-cells", names: t.property(node, "phy-names"), phandles,
                   &device)
      } else if name.starts(with: Array("pinctrl-".utf8)), name.count > 8,
        let state = Int(String(decoding: name[8...], as: UTF8.self))
      {
        // A state's phandles, each a node its pin controller holds.
        let label = nth(t, t.property(node, "pinctrl-names"), state) ?? String(state)
        var at = value.lowerBound
        while at + 4 <= value.upperBound {
          if let s = find(phandles, t.be32(at)) {
            device.links.append(DeviceLink(kind: "pinctrl", name: label, provider: "", target: s.path))
          } else {
            device.notes.append("pinctrl-\(state): phandle \(t.be32(at)) names no node")
          }
          at += 4
        }
      } else if let prefix = suffixed(name, "-supply") {
        if value.count == 4, let s = find(phandles, t.be32(value.lowerBound)) {
          device.links.append(DeviceLink(kind: "supply", name: prefix, provider: "", target: s.path))
        } else {
          device.notes.append("\(prefix)-supply names no node")
        }
      } else if equal(name, "gpios") || suffixed(name, "-gpios") != nil {
        specifiers(t, node, value, kind: "gpio", cells: "#gpio-cells", label: suffixed(name, "-gpios") ?? "", phandles,
                   &device)
      } else if syscons.contains(where: { equal(name, $0) }) {
        // A phandle and the cells its binding gives (an offset).
        if value.count >= 4, value.count % 4 == 0, let s = find(phandles, t.be32(value.lowerBound)) {
          device.links.append(DeviceLink(kind: "syscon", name: String(decoding: name, as: UTF8.self), provider: "",
                                         target: s.path, cells: words(t, value.lowerBound + 4, value.count / 4 - 1)))
        } else {
          device.notes.append("\(String(decoding: name, as: UTF8.self)) names no node")
        }
      }
    }
  }

  /// The vendor properties that name a system controller and an offset
  /// into its registers (Linux's syscon_regmap_lookup_by_phandle_args):
  /// each is a binding's own, with no cell count to find it by.
  static let syscons = ["spacemit,apmu"]

  // MARK: Properties

  /// `node`'s properties and those of the nodes under it, a line each,
  /// those of a node under it named by its path below `node` (`under`).
  static func properties(_ t: borrowing Fdt, _ node: Int, under: String, depth: Int) -> String {
    var out = ""
    var property = t.firstProperty(of: node)
    while let p = property {
      property = t.nextProperty(after: p)
      guard let (n, value) = t.property(at: p) else { continue }
      let v = render(t, value)
      out += under + string(t, n) + (v.isEmpty ? "" : " " + v) + "\n"
    }
    guard depth < 8 else { return out }
    var child = t.firstChild(of: node)
    while let c = child {
      out += properties(t, c, under: under + string(t, t.name(of: c)) + "/", depth: depth + 1)
      child = t.nextSibling(of: c)
    }
    return out
  }

  /// A value as dtc writes one: `"a", "b"` for printable strings, each
  /// ended by a NUL; `<0x1 0x2>` for a whole number of cells; else
  /// `[00 1a]`; empty for none.
  static func render(_ t: borrowing Fdt, _ value: Range<Int>) -> String {
    guard !value.isEmpty else { return "" }
    var printable = t.byte(value.upperBound - 1) == 0
    var previous: UInt8 = 0
    for i in value where printable {
      let b = t.byte(i)
      // No empty string, and nothing but printable ASCII in one.
      printable = b == 0 ? previous != 0 : b >= 0x20 && b < 0x7F && b != UInt8(ascii: "\"")
      previous = b
    }
    if printable {
      var parts: [String] = []
      var start = value.lowerBound
      for i in value where t.byte(i) == 0 {
        parts.append("\"" + string(t, start..<i) + "\"")
        start = i + 1
      }
      return parts.joined(separator: ", ")
    }
    if value.count % 4 == 0 {
      return "<" + words(t, value.lowerBound, value.count / 4).map { "0x" + String($0, radix: 16) }
        .joined(separator: " ") + ">"
    }
    return "[" + value.map { i in
      let b = t.byte(i)
      return (b < 16 ? "0" : "") + String(b, radix: 16)
    }.joined(separator: " ") + "]"
  }

  /// A list of specifiers, each a phandle and the cells its node's
  /// `cells` property counts, named in order by `names` or all `label`.
  static func specifiers(_ t: borrowing Fdt, _ node: Int, _ list: Range<Int>, kind: String, cells: StaticString,
                         names: Range<Int>? = nil, label: String = "", _ phandles: [Labelled],
                         _ device: inout TreeDevice) {
    var at = list.lowerBound, index = 0
    while at + 4 <= list.upperBound {
      guard let p = find(phandles, t.be32(at)) else {
        device.notes.append("\(kind) \(index): phandle \(t.be32(at)) names no node")
        return
      }
      let n = Int(t.u32(p.node, cells) ?? 0)
      guard n <= 8, at + 4 + 4 * n <= list.upperBound else {
        device.notes.append("\(kind) \(index) unreadable")
        return
      }
      let name = names.map { nth(t, $0, index) ?? "" } ?? label
      device.links.append(DeviceLink(kind: kind, name: name, provider: "", target: p.path, cells: words(t, at + 4, n)))
      at += 4 + 4 * n
      index += 1
    }
  }

  /// The device whose node is `target` or holds it: the longest of
  /// `paths` that is `target` or a path above it; empty for none.
  static func holder(_ paths: [String], _ target: String) -> String {
    let t = Array(target.utf8)
    var best = ""
    for p in paths {
      let b = Array(p.utf8)
      guard b.count > best.utf8.count, t.starts(with: b), t.count == b.count || t[b.count] == UInt8(ascii: "/") else {
        continue
      }
      best = p
    }
    return best
  }

  /// The `index`th string of a string list.
  static func nth(_ t: borrowing Fdt, _ list: Range<Int>?, _ index: Int) -> String? {
    guard let list else { return nil }
    var start = list.lowerBound, i = 0
    while start < list.upperBound {
      var end = start
      while end < list.upperBound, t.byte(end) != 0 { end += 1 }
      if i == index { return string(t, start..<end) }
      i += 1
      start = end + 1
    }
    return nil
  }

  /// What comes before `suffix` in a property's name, if it ends so and
  /// something does.
  static func suffixed(_ name: [UInt8], _ suffix: String) -> String? {
    let s = Array(suffix.utf8)
    guard name.count > s.count, name[(name.count - s.count)...].elementsEqual(s) else { return nil }
    return String(decoding: name[..<(name.count - s.count)], as: UTF8.self)
  }

  static func equal(_ name: [UInt8], _ value: String) -> Bool { name.elementsEqual(value.utf8) }

  static func bytes(_ t: borrowing Fdt, _ range: Range<Int>) -> [UInt8] {
    var out: [UInt8] = []
    for i in range { out.append(t.byte(i)) }
    return out
  }

  // MARK: Cells and strings

  /// Whether `node` says its DMA is coherent (`dma-coherent`) or isn't
  /// (`dma-noncoherent`).
  static func coherence(_ t: borrowing Fdt, _ node: Int) -> Bool? {
    if t.has(node, "dma-coherent") { return true }
    if t.has(node, "dma-noncoherent") { return false }
    return nil
  }

  /// The bits `bus`'s `dma-ranges` give its devices' DMA, `parent` the
  /// bus above it: its range from bus address 0 to CPU address 0, its
  /// size rounded down to a power of two; nil where it has none, or no
  /// such range.
  static func identityBits(_ t: borrowing Fdt, _ bus: Int, _ parent: Int) -> UInt32? {
    guard let r = t.property(bus, "dma-ranges"), !r.isEmpty else { return nil }
    let cac = cellCount(t, bus, "#address-cells", 2), pac = cellCount(t, parent, "#address-cells", 2)
    let sc = cellCount(t, bus, "#size-cells", 1), stride = 4 * (cac + pac + sc)
    guard stride > 0 else { return nil }
    var at = r.lowerBound
    while at + stride <= r.upperBound {
      if cells(t, at, cac) == 0, cells(t, at + 4 * cac, pac) == 0, let size = cells(t, at + 4 * (cac + pac), sc),
        size > 0
      {
        return UInt32(63 - size.leadingZeroBitCount)
      }
      at += stride
    }
    return nil
  }

  /// A cell-count property (`#address-cells`), or `otherwise`; at most 4.
  static func cellCount(_ t: borrowing Fdt, _ node: Int, _ name: StaticString, _ otherwise: Int) -> Int {
    min(Int(t.u32(node, name) ?? UInt32(otherwise)), 4)
  }

  /// `count` cells at `at` as one number: 0 for none, nil for more than
  /// 64 bits' worth that aren't zero above them.
  static func cells(_ t: borrowing Fdt, _ at: Int, _ count: Int) -> UInt64? {
    var v: UInt64 = 0
    for i in 0..<count {
      guard v >> 32 == 0 else { return nil }
      v = v << 32 | UInt64(t.be32(at + 4 * i))
    }
    return v
  }

  static func words(_ t: borrowing Fdt, _ at: Int, _ count: Int) -> [UInt32] {
    var out: [UInt32] = []
    for i in 0..<count { out.append(t.be32(at + 4 * i)) }
    return out
  }

  static func find(_ phandles: [Labelled], _ phandle: UInt32) -> Labelled? {
    phandles.first { $0.phandle == phandle }
  }

  static func path(_ phandles: [Labelled], _ node: Int) -> String {
    phandles.first { $0.node == node }?.path ?? "?"
  }

  /// A string-list property's strings (`compatible`).
  static func strings(_ t: borrowing Fdt, _ node: Int, _ name: StaticString) -> [String] {
    guard let p = t.property(node, name) else { return [] }
    var out: [String] = []
    var start = p.lowerBound
    while start < p.upperBound {
      var end = start
      while end < p.upperBound, t.byte(end) != 0 { end += 1 }
      if end > start { out.append(string(t, start..<end)) }
      start = end + 1
    }
    return out
  }

  static func string(_ t: borrowing Fdt, _ range: Range<Int>) -> String {
    var bytes: [UInt8] = []
    for i in range { bytes.append(t.byte(i)) }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// A path's last component.
  static func last(_ path: String) -> String {
    String(decoding: Array(path.utf8.split(separator: UInt8(ascii: "/")).last ?? []), as: UTF8.self)
  }
}

/// Whether two strings have the same bytes (String's == needs Unicode
/// tables tier 0 doesn't link).
func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
