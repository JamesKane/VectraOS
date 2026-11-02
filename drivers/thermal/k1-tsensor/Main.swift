// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-tsensor (k1-tsensor(3)): the SpacemiT K1's thermal sensor, its
// five sensing points read. devmgr grants its registers, starts it after
// the APBC whose clocks and reset it names, and reads its `temperatures`
// for each devicetree thermal zone whose `thermal-sensors` names it
// (devmgr's `thermal`, which power(8) acts on):
//   temperatures  a line a sensor, `<n> <C|-> <name>`, read from its
//                 data registers when the file is read; `-` for one not
//                 yet converted
//   status        the sensors, what firmware left in the control
//                 registers, and how long the first readings took
// The block converts continuously once enabled (K1Tsensor.swift); its
// threshold and emergency interrupts stay masked.

import DriverHost
import IPC
import Node
import Sys

final class Sensor: @unchecked Sendable {
  let regs: Registers
  let lock = Lock()
  var found = ""
  var firstReading = ""
  var reads = 0

  init(_ regs: consuming Registers) { self.regs = regs }

  func rmw(_ offset: Int, _ change: (UInt32) -> UInt32) { regs.store32(offset, change(regs.load32(offset))) }

  /// The enable sequence (§13.8), its clocks already on and its reset
  /// released; every interrupt masked.
  func enable() {
    found = "found pctrl 0x\(hex(regs.load32(Tsensor.pctrl))) enable 0x\(hex(regs.load32(Tsensor.enable))) "
      + "time 0x\(hex(regs.load32(Tsensor.timeControl)))"
    regs.store32(Tsensor.interruptMask, Tsensor.everyInterruptMasked)
    rmw(Tsensor.timeControl, Tsensor.timing)
    rmw(Tsensor.pctrl, Tsensor.powered)
    rmw(Tsensor.pctrl2, Tsensor.modulatorAt24MHz)
    rmw(Tsensor.enable, Tsensor.allEnabled)
  }

  var readings: [Int?] {
    (0..<Tsensor.sensors).map { Tsensor.celsius($0, word: regs.load32(Tsensor.data($0).offset)) }
  }

  var temperatures: String {
    lock.withLock {
      reads += 1
      return Tsensor.text(readings)
    }
  }

  var status: String {
    lock.withLock {
      let live = readings.filter { $0 != nil }.count
      return "sensors \(Tsensor.sensors), \(live) reading\n" + found + "\n"
        + "now pctrl 0x\(hex(regs.load32(Tsensor.pctrl))) enable 0x\(hex(regs.load32(Tsensor.enable))) "
        + "interrupts masked 0x\(hex(regs.load32(Tsensor.interruptMask)))\n" + firstReading + "\n"
        + "reads \(reads)\n"
    }
  }
}

func hex(_ v: UInt32) -> String {
  let s = String(v, radix: 16)
  return String(repeating: "0", count: max(0, 8 - s.utf8.count)) + s
}

@main struct K1TsensorHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    // Its clocks on and its reset released.
    for l in ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "")
    where !l.provider.isEmpty && (l.isKind("clock") || l.isKind("reset")) {
      guard let command = l.enabling else { continue }
      if ns?.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") != true {
        print("k1-tsensor: \(l.provider) refused `\(command)`")
      }
    }
    guard let regs = try? resources.map(bar: 0, extent: Tsensor.size) else {
      print("k1-tsensor: no registers")
      Process.exit(code: 1)
    }
    let sensor = Sensor(regs)
    sensor.enable()
    // The first conversions: every sensor reading, or 100 ms.
    let t0 = Clock.monotonic()
    var first = sensor.readings
    while first.contains(where: { $0 == nil }), Clock.monotonic() - t0 < 100_000_000 {
      sleep(until: Clock.monotonic() + 1_000_000)
      first = sensor.readings
    }
    let us = (Clock.monotonic() - t0) / 1000
    let line = first.contains(where: { $0 == nil })
      ? "not every sensor read after \(us) us" : "every sensor read within \(us) us"
    sensor.firstReading = line
    print("k1-tsensor: \(line): " + Tsensor.text(first).utf8.split(separator: 0x0A)
      .map { String(decoding: $0, as: UTF8.self) }.joined(separator: ", "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("temperatures", read: { sensor.temperatures })
      tree.text("status", read: { sensor.status })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}
