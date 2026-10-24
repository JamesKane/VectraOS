// SPDX-License-Identifier: BSD-3-Clause

// bin/xhci (xhci(3)): an xHCI USB host controller's driver host, on PCI
// or as an ACPI platform device (PNP0D10). It takes the controller from
// firmware (Controller.swift) in memory its BTI reaches, uncached when
// devmgr says its DMA isn't coherent (`--noncoherent`, from _CCA), on its
// interrupt (MSI-X where it has it, else its INTx or GSI), and runs the
// bus on a thread of its own (Bus.swift): hubs, and HID's boot keyboards
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
    do throws(Status) {
      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let regs: Registers
      let interrupt: Handle
      if let config = try? resources.mapConfig() {
        // Memory decoding and bus mastering on (a warm boot's devmgr
        // turned bus mastering off, D101).
        config.store16(4, config.load16(4) | 0x6)
        let irq = try PCIInterrupt(resources, config: config)
        interrupt = try irq.handle.duplicate()
        lines.append("pci, \(irq.msix ? "MSI-X" : "INTx")")
      } else {
        interrupt = try resources.interrupt()
        lines.append("acpi, interrupt \(try resources.interruptNumber())")
      }
      regs = try resources.map(bar: 0)
      if noncoherent { lines.append("DMA not cache coherent: its memory uncached") }
      let hc = try Controller(regs, memory: PinnedMemory(bti: bti, coherent: !noncoherent),
                              interrupt: try InterruptPort(interrupt))
      lines.append(hc.description)
      lines.append("legacy handoff: \(hc.handoff)")

      // Where keys and the pointer's records go: devmgr mounted both.
      let namespace = try? Namespace(start)
      var kbin: UInt32 = 0, mousein: UInt32 = 0
      if let h = try? namespace?.connect("/dev/kbin") { kbin = h.release() }
      if let h = try? namespace?.connect("/dev/mousein") { mousein = h.release() }
      if kbin == 0 { lines.append("no /dev/kbin: keys go nowhere") }
      if mousein == 0 { lines.append("no /dev/mousein: the pointer goes nowhere") }
      let bus = Bus(hc, counts: counts, kbin: kbin, mousein: mousein)
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
