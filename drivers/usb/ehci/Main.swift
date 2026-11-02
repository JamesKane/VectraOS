// SPDX-License-Identifier: BSD-3-Clause

// bin/ehci (ehci(3)): an EHCI USB host controller's driver host, on PCI or
// as the SpacemiT K1's ChipIdea controller in a devicetree (the vendor's
// `ky,mv-ehci`, D157), whose clock, reset, VBUS supply and PHY it turns
// on through their providers, and whose VBUS drive bit, in the APMU word
// its node gives second, it sets (spacemit-k1 07 §7.4). On PCI it
// takes the controller from firmware first (USBLEGSUP, in configuration
// space). It runs the USB bus on a thread of its own (drivers/usb/bus,
// over Controller.swift): hubs, and HID's boot keyboards and mice, whose
// keys go to /dev/kbin and pointer records to /dev/mousein. Its tree:
// `status`.

import DriverHost
import IPC
import Node
import Sys

@main struct EHCIDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let noncoherent = start.args.contains { $0.utf8.elementsEqual("--noncoherent".utf8) }
    let counts = BusCounts()
    var lines: [String] = []
    let namespace = try? Namespace(start)
    let links = namespace?.readText("/dev/dt/links").map { ProvidedLink.parse($0) }
    do throws(Status) {
      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let regs: Registers
      let interrupt: Handle
      var tdi = false
      if let ns = namespace, let links {
        interrupt = try resources.interrupt()
        lines.append("dt, interrupt \(try resources.interruptNumber())")
        try K1.links(ns, links, &lines)
        if let vbus = try? resources.map(bar: 1) {
          vbus.store32(0, vbus.load32(0) | K1.vbusDrive)
          lines.append("VBUS driven")
        }
        regs = try resources.map(bar: 0)
        tdi = true
      } else {
        let config = try resources.mapConfig()
        // Memory decoding and bus mastering on (a warm boot's devmgr
        // turned bus mastering off, D101).
        config.store16(4, config.load16(4) | 0x6)
        let irq = try PCIInterrupt(resources, config: config)
        interrupt = try irq.handle.duplicate()
        lines.append("pci, \(irq.msix ? "MSI-X" : "INTx")")
        regs = try resources.map(bar: 0)
        lines.append("legacy handoff: " + handoff(regs, config))
      }
      if noncoherent { lines.append("DMA not cache coherent: its memory uncached") }
      let hc = try EHCIHost(regs, memory: PinnedMemory(bti: bti, coherent: !noncoherent),
                            interrupt: try InterruptPort(interrupt), tdi: tdi)
      lines.append(hc.description)

      // Where keys and the pointer's records go: devmgr mounted both.
      var kbin: UInt32 = 0, mousein: UInt32 = 0
      if let h = try? namespace?.connect("/dev/kbin") { kbin = h.release() }
      if let h = try? namespace?.connect("/dev/mousein") { mousein = h.release() }
      if kbin == 0 { lines.append("no /dev/kbin: keys go nowhere") }
      if mousein == 0 { lines.append("no /dev/mousein: the pointer goes nowhere") }
      let bus = Bus(hc, counts: counts, kbin: kbin, mousein: mousein)
      _ = try Thread.spawn { bus.run() }.release()
    } catch {
      lines.append("FAILED: status \(error.rawValue)" + (EHCIHost.failure.isEmpty ? "" : ": " + EHCIHost.failure))
    }
    let head = lines.joined(separator: "\n") + "\n"
    print("ehci: " + lines.joined(separator: "; "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: {
        counts.lock.withLock {
          head + (counts.ready ? "bus ready\n" : "bus starting\n") + counts.devices.map { $0 + "\n" }.joined()
            + "keys to kbdfs \(counts.keys), refused \(counts.keysRefused)\n"
            + "pointer reports to mouse \(counts.reports), refused \(counts.reportsRefused)\n"
            + "transfer errors \(counts.transferErrors), attach failures \(counts.attachFailures)\n"
            + "interrupts \(counts.interrupts)\n"
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

  /// The controller taken from firmware (§5.1, USBLEGSUP at HCCPARAMS'
  /// EECP in configuration space): the OS's semaphore set, the BIOS's
  /// waited for (1 s), and its SMIs off.
  static func handoff(_ regs: borrowing Registers, _ config: borrowing Registers) -> String {
    let eecp = Int((regs.load32(EHCI.hccParams) >> 8) & 0xFF)
    guard eecp >= 0x40, config.load32(eecp) & 0xFF == 1 else { return "no legacy capability" }
    config.store32(eecp, config.load32(eecp) | 1 << 24)
    let released = pollFor(1_000) { config.load32(eecp) & 1 << 16 == 0 }
    config.store32(eecp + 4, 0)
    return released ? "firmware let go" : "firmware didn't let go in 1 s"
  }
}

/// The SpacemiT K1's ChipIdea controller (spacemit-k1 07 §7.5).
enum K1 {
  /// The APMU word's USB_VBUS_DRV.
  static let vbusDrive: UInt32 = 1 << 21

  /// Its clock on and its reset pulsed (2 ms), its VBUS supply on, then its
  /// PHY on, each by the provider its link names.
  static func links(_ ns: Namespace, _ links: [ProvidedLink], _ lines: inout [String]) throws(Status) {
    func say(_ l: ProvidedLink, _ command: String) throws(Status) {
      guard !l.provider.isEmpty else {
        lines.append("no provider runs for its \(l.kind) \(l.name.isEmpty ? "-" : l.name)")
        throw Status.notFound
      }
      guard ns.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") else {
        lines.append("\(l.provider) refused `\(command)`")
        throw Status.io
      }
    }
    let resets = links.filter { $0.isKind("reset") }
    for l in links where l.isKind("clock") { try say(l, l.enabling ?? "") }
    for l in resets { try say(l, "reset \(l.cells.first ?? 0) assert") }
    sleep(until: Clock.monotonic() + 2_000_000)
    for l in resets { try say(l, l.enabling ?? "") }
    for l in links where l.isKind("supply") { try say(l, "on") }
    for l in links where l.isKind("phy") { try say(l, l.enabling ?? "") }
  }
}
