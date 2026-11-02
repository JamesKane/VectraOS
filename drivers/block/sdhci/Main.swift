// SPDX-License-Identifier: BSD-3-Clause

// bin/sdhci (sdhci(3)): the block class over an SD host controller and
// the SD card in its slot (lib/Host.swift). A PCI SD host (QEMU's
// sdhci-pci) gives its registers in BAR 0 and its base clock in its
// capabilities; a SpacemiT K1's SDHCI (the Orange Pi RV2's microSD slot
// and eMMC) is a devicetree device, whose pins, clocks and resets its
// providers turn on as its node's links say (/dev/dt/links), and whose
// `io` clock k1-syscon(3) sets to 204.8 MHz, its base clock, since its
// capabilities don't give one. Its signalling could go to 1.8 V for UHS,
// where its node allows, through its `vqmmc` supply's provider (p1(3))
// and its `uhs` pin state (k1-pinctrl(3)), but that is off (`uhs`).
// Then the card is brought up, polled, and served as sd(3)'s directory
// (drivers/block/lib) at `sd`, which devmgr binds at /dev/sdMn: requests
// start on the unit's dispatcher's thread, each a piece of one bounce
// buffer by ADMA2, and the controller's interrupt ends each on a thread
// of its own, or a 50 ms poll if one is lost. Its tree: `sd`, and
// `status`.

import DriverHost
import IPC
import Node
import Sd
import Sys

@main struct SdhciDriver {
  /// The K1's SDHCI clock's rate: PLL1's 409.6 MHz halved.
  static let k1Base: UInt32 = 204_800_000

  /// Whether a slot that can go to 1.8 V does: not yet. On the Orange Pi
  /// RV2 the card takes CMD11 and never lets its lines go, and a card
  /// left so answers nothing until the board loses power (sdhci(3)'s
  /// BUGS).
  static let uhs = false

  /// The slot's way to 1.8 V, from its node: its `vqmmc` supply's
  /// provider and the regulator it names (`aldo1`, through p1(3)'s
  /// `voltage`), its `uhs` and `default` pin states (k1-pinctrl(3)), and
  /// the UHS modes its `sd-uhs-sdr104` and `sd-uhs-sdr50` allow; nil
  /// where any is missing.
  static func signalling(_ ns: Namespace, _ links: [ProvidedLink]) -> Signalling? {
    func named(_ kind: String, _ name: String) -> ProvidedLink? {
      links.first { $0.isKind(kind) && $0.name.utf8.elementsEqual(name.utf8) && !$0.provider.isEmpty }
    }
    func last(_ path: String) -> String {
      path.utf8.split(separator: UInt8(ascii: "/")).last.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    guard let supply = named("supply", "vqmmc"), let uhs = named("pinctrl", "uhs"), let normal = named("pinctrl", "default")
    else { return nil }
    var speeds: [BusSpeed] = []
    for line in (ns.readText("/dev/dt/node") ?? "").utf8.split(separator: 0x0A) {
      if line.elementsEqual("sd-uhs-sdr104".utf8) { speeds.append(.sdr104) }
      if line.elementsEqual("sd-uhs-sdr50".utf8) { speeds.append(.sdr50) }
    }
    guard !speeds.isEmpty else { return nil }
    let regulator = last(supply.node), at18 = last(uhs.node), at33 = last(normal.node)
    return Signalling(
      supply: { ns.writeText("/dev/provider/\(supply.provider)/ctl", "voltage \(regulator) \($0)\n") },
      pads: { ns.writeText("/dev/provider/\(uhs.provider)/ctl", "state \($0 ? at18 : at33)\n") },
      speeds: speeds)
  }

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
      if uhs, let links { host.signalling = SdhciDriver.signalling(ns, links) }
      let card: Host.Card
      do throws(HostError) {
        try host.setUp()
        card = try host.identify()
      } catch {
        lines.append("version \(host.version + 1), base \(host.base / 1_000_000) MHz: \(error.what)")
        lines += host.notes
        throw Status.notFound
      }
      let disk = try SdhciDisk(host, card: card, memory: PinnedMemory(bti: bti, coherent: !noncoherent))
      let mib = (disk.sectors * UInt64(disk.sectorSize)) >> 20
      lines.append("\(card.mmc ? "eMMC" : "SD card") \(card.name): \(disk.sectors) sectors (\(mib) MiB), "
        + "\(card.highCapacity ? "high capacity" : "standard capacity"), \(card.width)-bit at \(host.clock / 1_000_000) MHz"
        + " (\(card.mode)\(host.at18 ? ", 1.8 V" : ""))"
        + (host.receiveDelay.map { ", receive delay \($0.code) of \($0.window.lowerBound)-\($0.window.upperBound - 1)" } ?? "")
        + ", \(noncoherent ? "uncached DMA" : "coherent DMA")")
      lines += host.notes
      host.enableInterrupts()
      let thread = try InterruptThread(irq, msix: msix) { _, ack in
        disk.serviceInterrupt()
        ack()
      }
      status = {
        let (i, p) = thread.counts
        return "kind \(card.mmc ? "emmc" : "sd")\ncard \(card.name)\nwidth \(card.width)\nsectors \(disk.sectors)\ncapacity \(card.highCapacity ? "high" : "standard")\n"
          + "clock \(host.clock)\nmode \(card.mode)\nsignalling \(host.at18 ? "1.8" : "3.3") V\n"
          + (host.receiveDelay.map { "receive-delay \($0.code) window \($0.window.lowerBound)-\($0.window.upperBound - 1)\n" } ?? "")
          + "version \(host.version + 1)\nrequests \(disk.requests) failures \(disk.failures)"
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
