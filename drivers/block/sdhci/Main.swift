// SPDX-License-Identifier: BSD-3-Clause

// bin/sdhci (sdhci(3)): the block class over an SD host controller and
// the SD card in its slot (lib/Host.swift). A PCI SD host (QEMU's
// sdhci-pci) gives its registers in BAR 0 and its base clock in its
// capabilities; a SpacemiT K1's SDHCI (the Orange Pi RV2's microSD slot
// and eMMC) is a devicetree device, whose pins, clocks and resets its
// providers turn on as its node's links say (/dev/dt/links), and whose
// `io` clock k1-syscon(3) sets to 204.8 MHz, its base clock, since its
// capabilities don't give one. Then the card is brought up, polled, and
// served as sd(3)'s directory (drivers/block/lib) at `sd`, which devmgr
// binds at /dev/sdMn: requests start on the unit's dispatcher's thread,
// each a piece of one bounce buffer by ADMA2, and the controller's
// interrupt ends each on a thread of its own, or a 50 ms poll if one is
// lost. Its tree: `sd`, and `status`.

import DriverHost
import IPC
import Node
import Sd
import Sys

@main struct SdhciDriver {
  /// The K1's SDHCI clock's rate: PLL1's 409.6 MHz halved.
  static let k1Base: UInt32 = 204_800_000

  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let noncoherent = start.args.contains { $0.utf8.elementsEqual("--noncoherent".utf8) }
    let dispatcher: IPCDispatcher
    do throws(Status) {
      dispatcher = try IPCDispatcher()
    } catch {
      Process.exit(code: 1)
    }
    let tree = NodeTree(dispatcher: dispatcher)
    var lines: [String] = []
    var status: () -> String = { "" }
    do throws(Status) {
      guard let ns = try? Namespace(start) else { throw Status.notFound }
      let links = ns.readText("/dev/dt/links").map { ProvidedLink.parse($0) }
      let irq: Handle, msix: Bool
      var base: UInt64 = 0
      if let links {
        // Its pins set, its clocks on and its resets released, then its
        // `io` clock's rate, each by the provider its link names.
        let needed = links.filter { $0.isKind("clock") || $0.isKind("reset") }
        guard !needed.isEmpty, needed.allSatisfy({ !$0.provider.isEmpty }) else {
          lines.append("no clock and reset unit runs")
          throw Status.notFound
        }
        let pins = links.filter { $0.isKind("pinctrl") && $0.enabling != nil }
        for l in pins where l.provider.isEmpty { lines.append("no pin controller runs: pins as firmware left them") }
        for l in pins.filter({ !$0.provider.isEmpty }) + needed {
          guard let command = l.enabling else { continue }
          guard ns.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") else {
            lines.append("\(l.provider) refused `\(command)`")
            throw Status.io
          }
        }
        guard let io = links.first(where: { $0.isKind("clock") && $0.name.utf8.elementsEqual("io".utf8) }),
          let id = io.cells.first,
          ns.writeText("/dev/provider/\(io.provider)/ctl", "clock \(id) rate \(k1Base)\n")
        else {
          lines.append("no `io` clock at \(k1Base) Hz")
          throw Status.notSupported
        }
        base = UInt64(k1Base)
        irq = try resources.interrupt()
        msix = false
      } else {
        // Memory decoding and bus mastering on (a warm boot's devmgr
        // turned bus mastering off, D101).
        let config = try resources.mapConfig()
        config.store16(4, config.load16(4) | 0x6)
        let pci = try PCIInterrupt(resources, config: config)
        irq = try pci.handle.duplicate()
        msix = pci.msix
      }

      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let regs = try resources.map(bar: 0)
      guard regs.size >= Register.size else { throw Status.outOfRange }
      let host = Host(regs, k1: links != nil, base: base)
      let card: Host.Card
      do throws(HostError) {
        try host.setUp()
        card = try host.identify()
      } catch {
        lines.append("version \(host.version + 1), base \(host.base / 1_000_000) MHz: \(error.what)")
        throw Status.notFound
      }
      let disk = try SdhciDisk(host, card: card, memory: PinnedMemory(bti: bti, coherent: !noncoherent))
      let mib = (disk.sectors * UInt64(disk.sectorSize)) >> 20
      lines.append("\(card.name.isEmpty ? "card" : card.name): \(disk.sectors) sectors (\(mib) MiB), "
        + "\(card.highCapacity ? "high capacity" : "standard capacity"), 4-bit at \(host.clock / 1_000_000) MHz"
        + "\(card.highSpeed ? " (high speed)" : ""), \(noncoherent ? "uncached DMA" : "coherent DMA")")
      host.enableInterrupts()
      let thread = try InterruptThread(irq, msix: msix) { _, ack in
        disk.serviceInterrupt()
        ack()
      }
      status = {
        let (i, p) = thread.counts
        return "card \(card.name)\nsectors \(disk.sectors)\ncapacity \(card.highCapacity ? "high" : "standard")\n"
          + "clock \(host.clock)\nversion \(host.version + 1)\nrequests \(disk.requests) failures \(disk.failures)"
          + "\(disk.failures > 0 ? " last error 0x\(String(disk.lastError, radix: 16))" : "")\n"
          + "interrupts \(i) polls \(p)\n"
      }

      // The unit on a dispatcher of its own: the tree waits on its thread
      // for a mount's answers, and the unit's partitions are read first,
      // through the interrupt thread.
      let disks = try IPCDispatcher()
      let unit = SdUnit(disk, dispatcher: disks)
      _ = try Thread.spawn { try? disks.run() }.release()
      _ = tree.mount("sd", try unit.channel())
      lines.append("\(unit.partitions.count - 1) partition(s)")
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
      let failed = lines.joined(separator: "\n") + "\n"
      status = { failed }
    }
    print("sdhci: " + lines.joined(separator: "; "))

    do throws(Status) {
      let report = status
      tree.text("status", read: { report() })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}
