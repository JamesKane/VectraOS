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
// GPIO block's) is a provider's, and is noted, not granted. Its `iommus`
// name their units. Nodes the kernel owns, its interrupt controllers and
// timers, are not devices.

import Fdt

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
  public var iommus: [IOMMU]
  /// What couldn't be resolved: a range no bus translates, an interrupt
  /// on a controller the kernel doesn't own.
  public var notes: [String]

  public init(path: String, name: String, compatibles: [String], ranges: [Range] = [], interrupts: [Interrupt] = [],
              coherent: Bool = true, iommus: [IOMMU] = [], notes: [String] = []) {
    self.path = path
    self.name = name
    self.compatibles = compatibles
    self.ranges = ranges
    self.interrupts = interrupts
    self.coherent = coherent
    self.iommus = iommus
    self.notes = notes
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
    var out: [TreeDevice] = []
    var ancestors = [root]
    walk(tree, root, path: "", &ancestors, interruptParent: tree.u32(root, "interrupt-parent"),
         coherent: coherence(tree, root) ?? coherentByDefault, phandles, &out)
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
                   coherent: Bool, _ phandles: [Labelled], _ out: inout [TreeDevice]) {
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
        ancestors.append(c)
        walk(t, c, path: here, &ancestors, interruptParent: parent, coherent: dma, phandles, &out)
        ancestors.removeLast()
        continue
      }
      guard !compatibles.contains(where: { k in kernels.contains { same($0, k) } }) else { continue }
      var device = TreeDevice(path: here, name: "", compatibles: compatibles, coherent: dma)
      ranges(t, c, ancestors, &device)
      interrupts(t, c, interruptParent: parent, phandles, &device)
      iommus(t, c, phandles, &device)
      out.append(device)
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
          device.notes.append("interrupt \(spec.first ?? 0) on \(path(phandles, current)): a provider's")
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

  // MARK: Cells and strings

  /// Whether `node` says its DMA is coherent (`dma-coherent`) or isn't
  /// (`dma-noncoherent`).
  static func coherence(_ t: borrowing Fdt, _ node: Int) -> Bool? {
    if t.has(node, "dma-coherent") { return true }
    if t.has(node, "dma-noncoherent") { return false }
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
