// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-pcie-phy (k1-pcie-phy(3)): the SpacemiT K1's PCIe PHYs, providers
// of PHYs (D154), one driver for each. devmgr grants the PHY's
// registers, gives its node at /dev/dt, starts it after its providers
// (the APMU, the pin controller, and for a port's PHY the combo PHY,
// whose calibration it takes), and mounts this tree at
// /dev/provider/SERVICE in each driver whose device links to it:
//   calibration  the combo PHY's: `rx N tx N`, the termination its
//                calibration found, or empty if it failed
//   ctl          a port's PHY: `on`, its lanes set up from the combo
//                PHY's calibration and its PLL locked; a write fails
//                without a calibration or if the PLL doesn't lock. The
//                combo PHY's: `on 4` (PHY_TYPE_USB3), given to USB 3
//                through the APMU and its PLL locked
//   status       which PHY, its lanes, PLL and termination, the commands
//                done and the last failure
// The combo PHY calibrates when it starts, unless firmware has: with
// PCIe 0's clocks on and its resets released through the APMU, it waits
// up to 500 ms for the hardware to finish, then puts them back.

import DriverHost
import IPC
import Node
import Sys

final class Phy: @unchecked Sendable {
  let regs: Registers
  let ns: Namespace?
  let combo: Bool
  let lanes: Int
  /// The combo PHY's service, for a port's PHY.
  let calibrator: String?
  /// The APMU's service, for the combo PHY.
  var apmu: String?
  let lock = Lock()
  var termination: Termination?
  var locked = false
  /// The combo PHY's: given to USB 3.
  var usb3 = false
  var done = 0, failed = 0
  var last = ""

  init(_ regs: consuming Registers, _ ns: Namespace?, combo: Bool, lanes: Int, calibrator: String?) {
    self.regs = regs
    self.ns = ns
    self.combo = combo
    self.lanes = lanes
    self.calibrator = calibrator
  }

  /// Waits up to 500 ms for `bits` of `register`, as Linux does.
  func poll(_ register: Int, _ bits: UInt32) -> Bool {
    let deadline = Clock.monotonic() + 500_000_000
    while regs.load32(register) & bits == 0 {
      guard Clock.monotonic() < deadline else { return false }
      sleep(until: Clock.monotonic() + 500_000)
    }
    return true
  }

  /// The combo PHY's calibration, through the APMU at `apmu`, with PCIe
  /// 0's clocks and resets `links` (dbi, mstr, slv).
  func calibrate(apmu: String, links: [ProvidedLink]) -> String {
    let say = { (c: String) in self.ns?.writeText("/dev/provider/\(apmu)/ctl", c + "\n") == true }
    _ = say("pcie 0x3cc hold-phy off")
    if let t = Termination(result: regs.load32(PhyRegister.calibrationResult)) {
      termination = t
      return "by firmware"
    }
    _ = say("combo pcie")
    let app = links.filter { l in ["dbi", "mstr", "slv"].contains { l.name.utf8.elementsEqual($0.utf8) } }
    for l in app where l.isKind("clock") { _ = say("clock \(l.cells.first ?? 0) on") }
    for l in app where l.isKind("reset") { _ = say("reset \(l.cells.first ?? 0) deassert") }
    let finished = poll(PhyRegister.calibrationResult, Termination.done)
    for l in app where l.isKind("reset") { _ = say("reset \(l.cells.first ?? 0) assert") }
    for l in app where l.isKind("clock") { _ = say("clock \(l.cells.first ?? 0) off") }
    guard finished, let t = Termination(result: regs.load32(PhyRegister.calibrationResult)) else {
      return "failed: not done in 500 ms"
    }
    termination = t
    return "done"
  }

  enum Failure: Error { case noCalibration, unlocked, noAPMU }

  /// The combo PHY as USB 3's, through the APMU at `apmu`.
  func onUSB3(apmu: String?) throws(Failure) {
    try lock.withLock { () throws(Failure) in
      do throws(Failure) {
        guard let apmu, ns?.writeText("/dev/provider/\(apmu)/ctl", "combo usb\n") == true else { throw .noAPMU }
        for u in K1PciePhy.usb3 { regs.store32(u.register, u.apply(regs.load32(u.register))) }
        locked = poll(PhyRegister.clockConfig, PhyRegister.pllReady)
        guard locked else { throw .unlocked }
        let u = K1PciePhy.usb3LFPS
        regs.store32(u.register, u.apply(regs.load32(u.register)))
        usb3 = true
        done += 1
      } catch {
        failed += 1
        last = error == .noAPMU ? "on 4: the APMU refused combo usb" : "on 4: the PLL didn't lock in 500 ms"
        throw error
      }
    }
  }

  /// A port's PHY on.
  func on() throws(Failure) {
    try lock.withLock { () throws(Failure) in
      do throws(Failure) {
        guard let c = calibrator, let t = ns?.readText("/dev/provider/\(c)/calibration").flatMap({ Termination($0) }) else {
          throw .noCalibration
        }
        termination = t
        for u in K1PciePhy.setup(lanes: lanes, t) { regs.store32(u.register, u.apply(regs.load32(u.register))) }
        locked = poll(PhyRegister.clockConfig, PhyRegister.pllReady)
        guard locked else { throw .unlocked }
        done += 1
      } catch {
        failed += 1
        last = error == .noCalibration ? "on: no calibration" : "on: the PLL didn't lock in 500 ms"
        throw error
      }
    }
  }

  var status: String {
    lock.withLock {
      let pll = "PLL \(regs.load32(PhyRegister.clockConfig) & PhyRegister.pllReady != 0 ? "locked" : "unlocked")"
      var lines = [combo ? (usb3 ? "combo, USB 3, " + pll : "combo") : "port, \(lanes) lanes, " + pll]
      lines.append("termination " + (termination?.description ?? "-"))
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct K1PciePhyHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    let combo = (ns?.readText("/dev/dt/compatible") ?? "").utf8.split(separator: 0x0A)
      .contains { $0.elementsEqual("spacemit,k1-combo-phy".utf8) }
    let links = ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "")
    // Its pins, and its own (global) reset released and left so.
    for l in links where !l.provider.isEmpty && (l.isKind("pinctrl") || l.isKind("reset") && l.name.utf8.elementsEqual("phy".utf8)) {
      guard let command = l.enabling else { continue }
      if ns?.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") != true {
        print("k1-pcie-phy: \(l.provider) refused `\(command)`")
      }
    }
    guard let regs = try? resources.map(bar: 0, extent: combo ? 0x1000 : PhyRegister.size) else {
      print("k1-pcie-phy: no registers")
      Process.exit(code: 1)
    }
    let calibrator = links.first { $0.isKind("phy") && $0.name.utf8.elementsEqual("calibration".utf8) }?.provider
    let phy = Phy(regs, ns, combo: combo, lanes: combo ? 1 : K1PciePhy.lanes(node: ns?.readText("/dev/dt/node") ?? ""),
                  calibrator: calibrator.flatMap { $0.isEmpty ? nil : $0 })
    if combo {
      let apmu = links.first { $0.isKind("syscon") && !$0.provider.isEmpty }?.provider
      let how = apmu.map { phy.calibrate(apmu: $0, links: links) } ?? "failed: no APMU"
      phy.apmu = apmu
      print("k1-pcie-phy: combo: calibration \(how)" + (phy.termination.map { ", " + $0.description } ?? ""))
    } else {
      print("k1-pcie-phy: port, \(phy.lanes) lanes" + (phy.calibrator == nil ? ", no combo PHY to calibrate it" : ""))
    }

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { phy.status })
      if combo {
        tree.text("calibration", read: { phy.termination.map { $0.description + "\n" } ?? "" })
      }
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A) {
          let usb3 = line.elementsEqual("on \(phyTypeUSB3)".utf8)
          guard combo ? usb3 : line.elementsEqual("on".utf8) else { throw .invalid }
          do throws(Phy.Failure) {
            if usb3 { try phy.onUSB3(apmu: phy.apmu) } else { try phy.on() }
          } catch {
            print("k1-pcie-phy: \(phy.last)")
            throw .invalid
          }
        }
      })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}
