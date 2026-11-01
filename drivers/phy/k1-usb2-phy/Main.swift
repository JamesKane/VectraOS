// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-usb2-phy (k1-usb2-phy(3)): the SpacemiT K1's USB 2 PHY, a
// provider of a PHY (D154). devmgr grants the PHY's registers, gives its
// node at /dev/dt, starts it after its clock's provider (the APMU), and
// mounts this tree at /dev/provider/SERVICE in each driver whose device
// links to it:
//   ctl     `on`: its clock on, then once its PLL locks (500 ms at most),
//           its setup written (K1Usb2Phy.swift); a write fails if the
//           clock's provider refuses or the PLL doesn't lock
//   status  its PLL, the commands done and the last failure
// Its user, the DWC3, turns it on after releasing its own resets, as the
// vendor's driver does.

import DriverHost
import IPC
import Node
import Sys

final class Phy: @unchecked Sendable {
  let regs: Registers
  let ns: Namespace?
  let clocks: [ProvidedLink]
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""

  init(_ regs: consuming Registers, _ ns: Namespace?, clocks: [ProvidedLink]) {
    self.regs = regs
    self.ns = ns
    self.clocks = clocks
  }

  enum Failure: Error { case refused(String), unlocked }

  func on() throws(Failure) {
    try lock.withLock { () throws(Failure) in
      do throws(Failure) {
        for l in clocks {
          guard let c = l.enabling, !l.provider.isEmpty, ns?.writeText("/dev/provider/\(l.provider)/ctl", c + "\n") == true
          else { throw .refused(l.provider.isEmpty ? "-" : l.provider) }
        }
        let deadline = Clock.monotonic() + 500_000_000
        while regs.load32(K1Usb2Phy.pll) & K1Usb2Phy.pllReady == 0 {
          guard Clock.monotonic() < deadline else { throw .unlocked }
          sleep(until: Clock.monotonic() + 50_000)
        }
        for u in K1Usb2Phy.setup { regs.store32(u.register, u.apply(regs.load32(u.register))) }
        done += 1
      } catch {
        failed += 1
        switch error {
        case .refused(let p): last = "on: \(p) refused its clock"
        case .unlocked: last = "on: the PLL didn't lock in 500 ms"
        }
        throw error
      }
    }
  }

  var status: String {
    lock.withLock {
      var lines = ["PLL \(regs.load32(K1Usb2Phy.pll) & K1Usb2Phy.pllReady != 0 ? "locked" : "unlocked")"]
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct K1Usb2PhyHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    let links = ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "")
    guard let regs = try? resources.map(bar: 0, extent: K1Usb2Phy.size) else {
      print("k1-usb2-phy: no registers")
      Process.exit(code: 1)
    }
    let phy = Phy(regs, ns, clocks: links.filter { $0.isKind("clock") })
    print("k1-usb2-phy: \(phy.clocks.count) clocks")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { phy.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A) {
          guard line.elementsEqual("on".utf8) else { throw .invalid }
          do throws(Phy.Failure) {
            try phy.on()
          } catch {
            print("k1-usb2-phy: \(phy.last)")
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
