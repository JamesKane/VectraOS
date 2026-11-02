// SPDX-License-Identifier: BSD-3-Clause

// bin/xhci (xhci(3)): an xHCI USB host controller's driver host, on PCI,
// as an ACPI platform device (PNP0D10), or as a devicetree's DWC3 (the
// SpacemiT K1's), whose clocks, resets, supply and PHYs it turns on
// through their providers and whose core it makes a host (DWC3.swift)
// before its xHCI is touched. It takes the controller from
// firmware (Controller.swift) in memory its BTI reaches, uncached when
// devmgr says its DMA isn't coherent (`--noncoherent`, from _CCA), on its
// interrupt (MSI-X where it has it, else its INTx or GSI), and runs the
// USB bus on a thread of its own (drivers/usb/bus, over Host.swift): hubs, and HID's boot keyboards
// and mice, whose keys go to the /dev/kbin and pointer records to the
// /dev/mousein devmgr mounted for it (D83). Its tree: `status`.

import DriverHost
import IPC
import Node
import Sys

@main struct XHCIDriver {
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
      if let ns = namespace, let links {
        interrupt = try resources.interrupt()
        lines.append("dt, interrupt \(try resources.interruptNumber())")
        try DWC3Host.links(ns, links, &lines)
        regs = try resources.map(bar: 0)
        try DWC3Host.core(regs, DWC3(node: ns.readText("/dev/dt/node") ?? ""), &lines)
      } else if let config = try? resources.mapConfig() {
        // Memory decoding and bus mastering on (a warm boot's devmgr
        // turned bus mastering off, D101).
        config.store16(4, config.load16(4) | 0x6)
        let irq = try PCIInterrupt(resources, config: config)
        interrupt = try irq.handle.duplicate()
        lines.append("pci, \(irq.msix ? "MSI-X" : "INTx")")
        regs = try resources.map(bar: 0)
      } else {
        interrupt = try resources.interrupt()
        lines.append("acpi, interrupt \(try resources.interruptNumber())")
        regs = try resources.map(bar: 0)
      }
      if noncoherent { lines.append("DMA not cache coherent: its memory uncached") }
      let hc = try Controller(regs, memory: PinnedMemory(bti: bti, coherent: !noncoherent),
                              interrupt: try InterruptPort(interrupt))
      lines.append(hc.description)
      lines.append("legacy handoff: \(hc.handoff)")

      // Where keys and the pointer's records go: devmgr mounted both.
      var kbin: UInt32 = 0, mousein: UInt32 = 0
      if let h = try? namespace?.connect("/dev/kbin") { kbin = h.release() }
      if let h = try? namespace?.connect("/dev/mousein") { mousein = h.release() }
      if kbin == 0 { lines.append("no /dev/kbin: keys go nowhere") }
      if mousein == 0 { lines.append("no /dev/mousein: the pointer goes nowhere") }
      let bus = Bus(XHCIHost(hc), counts: counts, kbin: kbin, mousein: mousein)
      _ = try Thread.spawn { bus.run() }.release()
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
    }
    let head = lines.joined(separator: "\n") + "\n"
    print("xhci: " + lines.joined(separator: "; "))

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
}

/// A devicetree's DWC3, made ready for its xHCI.
enum DWC3Host {
  /// Its clocks on and its resets pulsed (asserted for 2 ms, as a warm
  /// boot may have left it running), its
  /// supply on (the board's VBUS), then its PHYs on, the USB 2 one first,
  /// each by the provider its link names.
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
    let phys = links.filter { $0.isKind("phy") }
    for l in phys.filter({ $0.name.utf8.elementsEqual("usb2-phy".utf8) })
      + phys.filter({ !$0.name.utf8.elementsEqual("usb2-phy".utf8) })
    {
      try say(l, l.enabling ?? "")
    }
    lines.append("\(phys.count) PHYs on")
  }

  /// Its core a host's, its PHY interfaces as its node says.
  static func core(_ regs: borrowing Registers, _ dwc3: DWC3, _ lines: inout [String]) throws(Status) {
    let id = regs.load32(DWC3.gsnpsid)
    guard DWC3.isCore(id) else {
      lines.append("no DWC3 core: GSNPSID 0x\(String(id, radix: 16))")
      throw Status.notSupported
    }
    regs.store32(DWC3.gctl, dwc3.gctl(regs.load32(DWC3.gctl)))
    regs.store32(DWC3.gusb3pipectl, dwc3.usb3(regs.load32(DWC3.gusb3pipectl)))
    regs.store32(DWC3.gusb2phycfg, dwc3.usb2(regs.load32(DWC3.gusb2phycfg)))
    lines.append("DWC3 core 0x\(String(id, radix: 16)), a host")
  }
}
