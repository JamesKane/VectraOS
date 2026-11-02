// SPDX-License-Identifier: BSD-3-Clause

// A devicetree's thermal zones (D160): each enabled child of
// /thermal-zones, the sensor its `thermal-sensors` names (the node, a
// device whose driver reads it, and the cell, which of its sensors), its
// first passive and first critical trip, and its `polling-delay`. devmgr
// gives them in its `thermal` beside ACPI's zones, each temperature read
// from the sensor's driver, and power(8) acts on them as on ACPI's.

import Fdt

/// A thermal zone the tree describes.
public struct TreeZone: Equatable, Sendable {
  /// `/thermal-zones/NAME`.
  public var path: String
  /// The sensor's node, by path: the device whose driver reads it.
  public var sensor: String
  /// Which of its sensors: the specifier's cell (0 with none).
  public var cell: UInt32
  /// The trips, in millidegrees Celsius as the tree gives them.
  public var passive: Int32?
  public var critical: Int32?
  /// How often to read it, in milliseconds (`polling-delay`); 0 where the
  /// tree leaves it to the sensor's interrupt.
  public var polling: UInt32

  public init(path: String, sensor: String, cell: UInt32 = 0, passive: Int32? = nil, critical: Int32? = nil,
              polling: UInt32 = 0) {
    self.path = path
    self.sensor = sensor
    self.cell = cell
    self.passive = passive
    self.critical = critical
    self.polling = polling
  }
}

extension DeviceTreeBus {
  /// The zones under the root's `thermal-zones`, in document order; one
  /// whose `thermal-sensors` names no node is left out.
  public static func thermalZones(_ tree: borrowing Fdt) -> [TreeZone] {
    guard let root = tree.root else { return [] }
    var zones: Int? = nil
    var child = tree.firstChild(of: root)
    while let c = child {
      child = tree.nextSibling(of: c)
      if same(string(tree, tree.name(of: c)), "thermal-zones") { zones = c }
    }
    guard let zones else { return [] }
    var phandles: [Labelled] = []
    label(tree, root, path: "", depth: 0, &phandles)
    var out: [TreeZone] = []
    var zone = tree.firstChild(of: zones)
    while let z = zone {
      zone = tree.nextSibling(of: z)
      guard tree.isEnabled(z), let sensors = tree.property(z, "thermal-sensors"), sensors.count >= 4,
        let p = find(phandles, tree.be32(sensors.lowerBound))
      else { continue }
      let cells = Int(tree.u32(p.node, "#thermal-sensor-cells") ?? 0)
      var found = TreeZone(path: "/thermal-zones/" + string(tree, tree.name(of: z)), sensor: p.path,
                           cell: cells > 0 && sensors.count >= 8 ? tree.be32(sensors.lowerBound + 4) : 0,
                           polling: tree.u32(z, "polling-delay") ?? 0)
      var trips: Int? = nil
      var under = tree.firstChild(of: z)
      while let u = under {
        under = tree.nextSibling(of: u)
        if same(string(tree, tree.name(of: u)), "trips") { trips = u }
      }
      var trip = trips.flatMap { tree.firstChild(of: $0) }
      while let t = trip {
        trip = tree.nextSibling(of: t)
        guard let kind = strings(tree, t, "type").first, let mC = tree.u32(t, "temperature") else { continue }
        let temperature = Int32(bitPattern: mC)
        if same(kind, "passive"), found.passive == nil { found.passive = temperature }
        if same(kind, "critical"), found.critical == nil { found.critical = temperature }
      }
      out.append(found)
    }
    return out
  }
}
