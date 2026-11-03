// SPDX-License-Identifier: BSD-3-Clause

// A devicetree's CPUs as power(8) scales them (D161): each enabled
// `/cpus/cpu@N`, its hart (`reg`), its clock (`clocks`' first specifier)
// and its supply (`cpu-supply`), each a link whose provider is the device
// holding the node named, as a device's links are found; and its
// operating points, the children of the `operating-points-v2` table it
// names: `opp-hz` and the first cell of `opp-microvolt`, slowest first.
// devmgr gives them in its `cpus` beside ACPI's processors, the drivers
// of their clocks and supplies named, and power moves them through
// their points as it moves CPPC's levels.

import Fdt

/// A rate a CPU can run at, and the supply's voltage it needs.
public struct OperatingPoint: Equatable, Sendable {
  public var hz: UInt64
  public var microvolts: UInt32

  public init(hz: UInt64, microvolts: UInt32) {
    self.hz = hz
    self.microvolts = microvolts
  }
}

/// A CPU the tree describes, as far as its rate goes.
public struct TreeCPU: Equatable, Sendable {
  /// `/cpus/cpu@0`.
  public var path: String
  /// Its hart (its `reg`).
  public var hart: UInt32
  /// Its clock; nil where `clocks` names none.
  public var clock: DeviceLink?
  /// Its supply; nil where it has no `cpu-supply`.
  public var supply: DeviceLink?
  /// Its operating points, slowest first; empty without a table.
  public var points: [OperatingPoint]

  public init(path: String, hart: UInt32, clock: DeviceLink? = nil, supply: DeviceLink? = nil,
              points: [OperatingPoint] = []) {
    self.path = path
    self.hart = hart
    self.clock = clock
    self.supply = supply
    self.points = points
  }
}

extension DeviceTreeBus {
  /// The enabled CPUs under `/cpus`, in document order, their links'
  /// providers found among `devices` (DeviceTreeBus.devices's).
  public static func cpus(_ tree: borrowing Fdt, devices: [TreeDevice]) -> [TreeCPU] {
    guard let root = tree.root else { return [] }
    var cpus: Int? = nil
    var child = tree.firstChild(of: root)
    while let c = child {
      child = tree.nextSibling(of: c)
      if same(string(tree, tree.name(of: c)), "cpus") { cpus = c }
    }
    guard let cpus else { return [] }
    var phandles: [Labelled] = []
    label(tree, root, path: "", depth: 0, &phandles)
    let paths = devices.map { $0.path }
    var out: [TreeCPU] = []
    var node = tree.firstChild(of: cpus)
    while let n = node {
      node = tree.nextSibling(of: n)
      guard tree.isEnabled(n), strings(tree, n, "device_type").contains(where: { same($0, "cpu") }),
        let hart = tree.u32(n, "reg")
      else { continue }
      let path = "/cpus/" + string(tree, tree.name(of: n))
      var scratch = TreeDevice(path: path, name: "", compatibles: [])
      links(tree, n, phandles, paths, &scratch)
      for j in scratch.links.indices where scratch.links[j].provider.isEmpty {
        scratch.links[j].provider = holder(paths, scratch.links[j].target)
      }
      var cpu = TreeCPU(path: path, hart: hart, clock: scratch.links.first { same($0.kind, "clock") },
                        supply: scratch.links.first { same($0.kind, "supply") && same($0.name, "cpu") })
      if let table = tree.property(n, "operating-points-v2"), table.count == 4,
        let t = find(phandles, tree.be32(table.lowerBound)),
        strings(tree, t.node, "compatible").contains(where: { same($0, "operating-points-v2") })
      {
        cpu.points = points(tree, t.node)
      }
      out.append(cpu)
    }
    return out
  }

  /// A table's points: each enabled child with an `opp-hz` (one or two
  /// cells) and an `opp-microvolt` (a target, or a target, its least and
  /// its most), slowest first.
  static func points(_ t: borrowing Fdt, _ table: Int) -> [OperatingPoint] {
    var out: [OperatingPoint] = []
    var child = t.firstChild(of: table)
    while let c = child {
      child = t.nextSibling(of: c)
      guard t.isEnabled(c), let hz = t.property(c, "opp-hz"), hz.count == 4 || hz.count == 8,
        let rate = cells(t, hz.lowerBound, hz.count / 4), let uv = t.property(c, "opp-microvolt"),
        uv.count == 4 || uv.count == 12
      else { continue }
      out.append(OperatingPoint(hz: rate, microvolts: t.be32(uv.lowerBound)))
    }
    for i in out.indices.dropFirst() {
      var j = i
      while j > 0, out[j - 1].hz > out[j].hz {
        out.swapAt(j - 1, j)
        j -= 1
      }
    }
    return out
  }
}
