// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-net (M3k, N1d): the net class over a virtio network device
// (Virtual I/O Device 1.2 §5.1), modern or transitional. It opens the
// device, takes memory the device reaches through its BTI (croi K9e), and
// serves NetDeviceIPC.Device (drivers/net/lib) over VirtioNetBackend: the
// net service's kicks transmit on the dispatcher's thread, the device's
// interrupt (MSI-X, else INTx: then a lost one costs a 50 ms poll) receives
// on a thread of its own. Its tree: `device`, and `status` (the MAC
// address, link, MTU, frames each way, interrupts).
//
// A device it can't drive (no BTI, no interrupt) is reported through the
// shared scaffold's `status` instead (virtio/host/Host.swift).

import DriverHost
import IPC
import LibSys
import Launch
import NetDevice
import Node
import Sys
import Virtio
import VirtioNet

@main struct VirtioNetDriver {
  static func main() {
    var resources = DeviceResources(take: StartupHandles.take)
    guard let bti = resources.takeBTI(), let pci = try? PCIDevice(resources), let irq = try? pci.interrupt(resources),
      let notify = pci.notify, let isr = pci.isr, let port = try? Port.create(bindToInterrupt: true),
      (try? Interrupt.bind(irq.handle, port: port, key: 1)) != nil
    else {
      probeOnly(resources)
    }
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)), var start = try? Startup(Handle(raw: raw))
    else { exit(2) }

    let backend: VirtioNetBackend<BARWindow>
    do throws(Status) {
      backend = try VirtioNetBackend(device: pci.device, notify: notify, multiplier: pci.notifyMultiplier,
                                     memory: PinnedMemory(bti: bti), vector: irq.vector)
    } catch {
      print("virtio-net: can't start the device: status \(error.rawValue)")
      exit(1)
    }
    let service = NetDeviceService(info: backend.info, dispatcher: dispatcher) { ring in backend.transmit(ring) }
    service.setLink(backend.linkUp)
    let mac = Network.text(backend.mac)
    print("virtio-net: \(mac), mtu \(backend.mtu), link \(backend.linkUp ? "up" : "down"), "
      + "\(irq.msix ? "MSI-X" : "INTx"), serving the net class")

    final class Counts: @unchecked Sendable {
      var interrupts = 0
      var polls = 0
    }
    let counts = Counts()
    let portRaw = port.release()
    do {
      _ = try Thread.spawn {
        let port = Handle(raw: portRaw)
        while true {
          let deadline = irq.msix ? infiniteDeadline : Clock.monotonic() + 50_000_000
          if (try? Port.wait(port, deadline: deadline)) != nil { counts.interrupts += 1 } else { counts.polls += 1 }
          // INTx: reading the ISR lowers the line; bit 1 is a configuration change.
          if !irq.msix { _ = isr.read(0, width: 1) }
          try? Interrupt.ack(irq.handle)
          service.setLink(backend.linkUp)
          backend.serviceInterrupt(service.ring)
        }
      }
    } catch {
      exit(1)
    }

    let tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: {
      "mac \(mac)\nmtu \(backend.mtu)\nlink \(backend.linkUp ? "up" : "down")\n"
        + "features \(String(backend.features, radix: 16))\ninterrupt \(irq.msix ? "MSI-X" : "INTx")\n"
        + "received \(backend.received) transmitted \(backend.transmitted) dropped \(backend.dropped)\n"
        + "interrupts \(counts.interrupts) polls \(counts.polls)\nring \(service.ring == nil ? "closed" : "open")\n"
    })
    service.publish(in: tree)
    do {
      try tree.serve(try start.export())
      try start.ready()
    } catch {
      exit(1)
    }
    _ = try? dispatcher.run()
    _ = consume resources
  }

  /// One dispatcher for the tree and the device's sessions.
  static let dispatcher: IPCDispatcher = {
    guard let d = try? IPCDispatcher() else { exit(1) }
    return d
  }()

  /// A device it can't drive: negotiate, report, and serve the status.
  static func probeOnly(_ resources: consuming DeviceResources) -> Never {
    runDriver("virtio-net", resources) { pci throws(Status) in
      var lines: [String] = []
      let d = pci.device
      _ = try negotiate(d, Network.Feature.mac | Network.Feature.status | Network.Feature.mtu, &lines)
      let c = Network.config(d)
      lines.append("mac \(c.mac.map { Network.text($0) } ?? "none")")
      lines.append("link \(c.status.map { $0 & 1 != 0 ? "up" : "down" } ?? "unknown")")
      lines.append("mtu \(c.mtu.map { "\($0)" } ?? "default"), queue pairs \(c.queuePairs), queues \(d.queueCount)")
      lines.append("not driven: no BTI or no interrupt")
      return lines
    }
  }
}
