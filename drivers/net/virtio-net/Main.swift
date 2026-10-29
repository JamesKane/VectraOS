// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-net (M3k, N1d; D82): the net class over a virtio network
// device (Virtual I/O Device 1.2 §5.1). It opens the device, takes memory
// the device reaches through its BTI, and serves ether(3)'s directory
// (drivers/net/lib) at `ether` in its tree, which devmgr binds at
// /net/etherN, over VirtioNetBackend: frames written to a conversation's
// data go out on the dispatcher's thread, and the device's interrupt
// (MSI-X, else INTx: then a lost one costs a 50 ms poll) receives on a
// thread of its own. Its tree: `ether`, and `status` (the MAC address,
// link, MTU, frames each way, interrupts).

import DriverHost
import IPC
import NetClass
import Node
import Sys
import Virtio

/// The link's watch, which only the interrupt thread reads and changes.
final class Watch: @unchecked Sendable {
  var link = LinkWatch()
}

@main struct VirtioNetDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
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
      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let pci = try PCIDevice(resources)
      let irq = try pci.interrupt(resources)
      guard let notify = pci.notify, let isr = pci.isr else { throw Status.notSupported }
      let backend = try VirtioNetBackend(device: pci.device, notify: notify, multiplier: pci.notifyMultiplier,
                                         memory: PinnedMemory(bti: bti), vector: irq.vector)
      // Its addresses are the BTI's: a device that takes them as physical
      // would read and write the wrong memory.
      guard backend.features & Feature.accessPlatform != 0 else {
        lines.append("the device bypasses the IOMMU (no ACCESS_PLATFORM)")
        throw Status.notSupported
      }
      let ether = Ether(tree: tree, at: "ether", nic: EtherNIC(mac: backend.mac, mbps: 1000,
        transmit: { backend.transmit($0) },
        ifstats: { "received \(backend.received) transmitted \(backend.transmitted) dropped \(backend.dropped) "
          + "unsent \(backend.unsent)\n" }))
      ether.setLink(backend.linkUp)
      let mac = Network.text(backend.mac)
      lines.append("mac \(mac), mtu \(backend.mtu), link \(backend.linkUp ? "up" : "down"), "
        + "\(irq.msix ? "MSI-X" : "INTx")")
      // The link's state is the device's config space, an exit a read
      // under a hypervisor: read when it may have changed, not at each
      // interrupt (LinkWatch).
      let watch = Watch(), msix = irq.msix
      let thread = try InterruptThread(irq.handle, msix: msix, next: { watch.link.deadline }) { interrupted, ack in
        // INTx: reading the ISR lowers the line; bit 1 is a configuration
        // change, so it says when to read the link. MSI-X: one vector for
        // the queues and the configuration says nothing.
        let changed: Bool
        if msix {
          let now = Clock.monotonic()
          changed = interrupted ? watch.link.interrupt(now: now) : watch.link.due(now: now)
        } else {
          changed = isr.read(0, width: 1) & 2 != 0
        }
        ack()
        if changed { ether.setLink(backend.linkUp) }
        backend.serviceInterrupt { ether.receive($0) }
      }
      status = {
        let (i, p) = thread.counts
        return "mac \(mac)\nmtu \(backend.mtu)\nlink \(backend.linkUp ? "up" : "down")\n"
          + "features \(String(backend.features, radix: 16))\ninterrupt \(msix ? "MSI-X" : "INTx")\n"
          + "received \(backend.received) transmitted \(backend.transmitted) dropped \(backend.dropped)"
          + " unsent \(backend.unsent) unkicked \(backend.unkicked)\ninterrupts \(i) polls \(p)\n"
      }
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
      let failed = lines.joined(separator: "\n") + "\n"
      status = { failed }
    }
    print("virtio-net: " + lines.joined(separator: "; "))

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
