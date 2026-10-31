// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-emac (k1-emac(3)): the net class over a SpacemiT K1 Ethernet MAC
// (the Orange Pi RV2's two). devmgr starts it after the APMU's
// k1-syscon(3), whose tree it has at /dev/provider/SERVICE: through its
// ctl it turns the MAC's clock on, releases its reset and sets its
// interface and delay lines, as its node's links say (/dev/dt/links) and
// its properties (/dev/dt/node: `phy-mode`, the delays, the PHY's address
// under `mdio-bus`, the MAC address). Then it sets up the MAC (Mac), the
// PHY through the MAC's MDIO bus, and its rings (Rings) in memory the MAC
// reaches through its BTI, uncached where devmgr says its DMA isn't
// coherent (`--noncoherent`). It serves ether(3)'s directory
// (drivers/net/lib) at `ether`, which devmgr binds at /net/etherN: frames
// written to a conversation's data go out on the dispatcher's thread; a
// thread of its own serves the interrupt, or every 50 ms one lost, and
// reads the PHY's link every second. Its tree: `ether`, and `status`.

import DriverHost
import IPC
import NetClass
import Node
import Sys

/// What the interrupt thread counts and reads, for the status.
final class State: @unchecked Sendable {
  let lock = Lock()
  var link: LinkMode?
  var causes = 0
  var stops = 0
  /// When the PHY's link is read next (the interrupt thread's alone).
  var nextLink: Int64 = 0
}

@main struct K1EmacDriver {
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
      guard let config = NodeConfig(node: ns.readText("/dev/dt/node") ?? "") else {
        lines.append("no phy-mode the MAC has, or a delay past its lines'")
        throw Status.notSupported
      }
      // Its pins set, its clock on, its reset released, its interface and
      // delays set, each by the provider its link names: the pins first,
      // as Linux sets a device's default state before its driver runs.
      let links = ProvidedLink.parse(ns.readText("/dev/dt/links") ?? "")
      let needed = links.filter { $0.isKind("clock") || $0.isKind("reset") || $0.isKind("syscon") }
      guard links.contains(where: { $0.isKind("syscon") }), needed.allSatisfy({ !$0.provider.isEmpty }) else {
        lines.append("no APMU runs: no clock, reset or interface")
        throw Status.notFound
      }
      let pins = links.filter { $0.isKind("pinctrl") && $0.enabling != nil }
      for l in pins where l.provider.isEmpty { lines.append("no pin controller runs: pins as firmware left them") }
      for l in pins.filter({ !$0.provider.isEmpty }) + needed {
        guard let command = l.enabling ?? emacCommand(l, config) else { continue }
        guard ns.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") else {
          lines.append("\(l.provider) refused `\(command)`")
          throw Status.io
        }
      }

      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let regs = try resources.map(bar: 0)
      guard regs.size >= Register.size else { throw Status.outOfRange }
      let mac = Mac(regs)
      mac.stop()
      guard let phy = config.phy.flatMap({ mac.phyID($0) != nil ? $0 : nil }) ?? mac.findPHY(),
        let phyID = mac.phyID(phy)
      else {
        lines.append("no PHY answers on the MDIO bus")
        throw Status.notFound
      }
      guard mac.setUpPHY(phy, id: phyID, config) else {
        lines.append("PHY \(phy) stays in reset")
        throw Status.timedOut
      }
      mac.setUp()
      // The node's address (firmware's, merged by the loader), else the
      // one firmware left in the MAC, else a random local one.
      let left = mac.address
      var address = config.mac ?? left
      var source = config.mac != nil ? "the tree" : "firmware's registers"
      if !address.contains(where: { $0 != 0 }) || address[0] & 1 != 0 {
        address = (try? CPRNG.draw(count: 6)) ?? [0, 0, 0, 0, 0, 1]
        address[0] = address[0] & 0xFE | 0x02
        source = "random"
      }
      mac.setAddress(address)
      mac.setAddress(address, at: Register.flowControlSource)
      let rings = try Rings(mac: mac, memory: PinnedMemory(bti: bti, coherent: !noncoherent))
      mac.start(receive: UInt32(truncatingIfNeeded: rings.receiveRingBus),
                transmit: UInt32(truncatingIfNeeded: rings.transmitRingBus))

      let ether = Ether(tree: tree, at: "ether", nic: EtherNIC(mac: address, mbps: 1000,
        transmit: { rings.transmit($0) },
        ifstats: { "received \(rings.received) transmitted \(rings.transmitted) dropped \(rings.dropped) "
          + "unsent \(rings.unsent)\n" }))
      ether.setLink(false)
      let hex = Ether.hex(address)
      let state = State()
      let id = "0x" + String(phyID, radix: 16)
      lines.append("mac \(hex) (\(source)), PHY \(phy) id \(id), \(noncoherent ? "uncached DMA" : "coherent DMA")")

      let irq = try resources.interrupt()
      let thread = try InterruptThread(irq, msix: false) { _, ack in
        let causes = mac.takeCauses()
        ack()
        if causes & (Bits.transmitStopped | Bits.receiveStopped) != 0 { state.lock.withLock { state.stops += 1 } }
        if causes != 0 { state.lock.withLock { state.causes += 1 } }
        rings.service { ether.receive($0) }
        let now = Clock.monotonic()
        guard now >= state.nextLink else { return }
        state.nextLink = now + 1_000_000_000
        let link = mac.phyLink(phy)
        let was = state.lock.withLock { () -> LinkMode? in
          let was = state.link
          state.link = link
          return was
        }
        guard link != was else { return }
        if let link {
          mac.setLink(link)
          print("k1-emac: \(hex) link up, \(link.mbps) Mb/s \(link.fullDuplex ? "full" : "half") duplex")
        } else {
          print("k1-emac: \(hex) link down")
        }
        ether.setLink(link != nil)
      }
      let summary = lines.joined(separator: "; ")
      status = {
        let (link, causes, stops) = state.lock.withLock { (state.link, state.causes, state.stops) }
        let (i, p) = thread.counts
        return "mac \(hex)\nphy \(phy) \(id)\n"
          + "link \(link.map { "up \($0.mbps) \($0.fullDuplex ? "full" : "half")" } ?? "down")\n"
          + "received \(rings.received) transmitted \(rings.transmitted) dropped \(rings.dropped) unsent \(rings.unsent)\n"
          + "interrupts \(i) polls \(p) causes \(causes) stops \(stops)\n" + summary + "\n"
      }
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
      let failed = lines.joined(separator: "\n") + "\n"
      status = { failed }
    }
    print("k1-emac: " + lines.joined(separator: "; "))

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
