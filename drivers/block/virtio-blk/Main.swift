// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-blk (D106): the block class over a virtio block device
// (Virtual I/O Device 1.2 §5.2). It opens the device, takes memory the
// device reaches through its BTI, and serves sd(3)'s directory
// (drivers/block/lib) at `sd` in its tree, which devmgr binds at
// /dev/sdF<n>, over VirtioDisk: requests start on the unit's dispatcher's
// thread, and the device's interrupt (MSI-X, else INTx: then a lost one
// costs a 50 ms poll) ends them on a thread of its own. Its tree: `sd`,
// and `status` (capacity, features, requests, interrupts).

import DriverHost
import IPC
import Node
import Sd
import Sys
import Virtio

@main struct VirtioBlockDriver {
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
      let disk = try VirtioDisk(device: pci.device, notify: notify, multiplier: pci.notifyMultiplier,
                                memory: PinnedMemory(bti: bti), vector: irq.vector)
      // Its addresses are the BTI's: a device that takes them as physical
      // would read and write the wrong memory.
      guard disk.features & Feature.accessPlatform != 0 else {
        lines.append("the device bypasses the IOMMU (no ACCESS_PLATFORM)")
        throw Status.notSupported
      }
      let mib = (disk.sectors * UInt64(disk.sectorSize)) >> 20
      let flushes = disk.features & Block.Feature.flush != 0
      lines.append("\(disk.sectors) sectors (\(mib) MiB)\(disk.readOnly ? ", read-only" : "")"
        + "\(flushes ? ", a cache to flush" : ""), \(irq.msix ? "MSI-X" : "INTx")")
      let msix = irq.msix
      let thread = try InterruptThread(irq.handle, msix: msix) { _, ack in
        if !msix { _ = isr.read(0, width: 1) }  // INTx: the line goes down
        ack()
        disk.serviceInterrupt()
      }
      status = {
        let (i, p) = thread.counts
        return "sectors \(disk.sectors)\nsector \(disk.sectorSize)\nread-only \(disk.readOnly)\n"
          + "features \(String(disk.features, radix: 16))\ninterrupt \(msix ? "MSI-X" : "INTx")\n"
          + "requests \(disk.requests) failures \(disk.failures)\ninterrupts \(i) polls \(p)\n"
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
    print("virtio-blk: " + lines.joined(separator: "; "))

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
