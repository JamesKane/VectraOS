// SPDX-License-Identifier: BSD-3-Clause

// bin/nvme: the block class over an NVMe controller (NvmeDisk). It takes
// the controller from firmware, its first active namespace as the disk,
// memory the controller reaches through its BTI, and serves sd(3)'s
// directory (drivers/block/lib) at `sd` in its tree, which devmgr binds
// at /dev/sdN<n>: requests start on the unit's dispatcher's thread, and
// the controller's interrupt (MSI-X, else INTx: then a lost one costs a
// 50 ms poll) ends them on a thread of its own. Its tree: `sd`, and
// `status` (model, serial, size, requests, interrupts).

import DriverHost
import IPC
import Node
import Sd
import Sys

@main struct NvmeDriver {
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
      let config = try resources.mapConfig()
      // Memory decoding and bus mastering on (a warm boot's devmgr turned
      // bus mastering off, D101), and relaxed ordering off, as behind an
      // IOMMU's translation FreeBSD has it on the CIX Sky1.
      config.store16(4, config.load16(4) | 0x6)
      if let pcie = pciCapability(config, 0x10) { config.store16(pcie + 8, config.load16(pcie + 8) & ~UInt16(0x10)) }
      let irq = try PCIInterrupt(resources, config: config)
      let disk = try NvmeDisk(try resources.map(bar: 0), memory: PinnedMemory(bti: bti))
      let mib = (disk.sectors * UInt64(disk.sectorSize)) >> 20
      lines.append("\(disk.model), namespace \(disk.namespace): \(disk.sectors) sectors of \(disk.sectorSize) "
        + "(\(mib) MiB)\(disk.writeCache ? ", a cache to flush" : ""), \(irq.msix ? "MSI-X" : "INTx")")
      let thread = try InterruptThread(irq.handle, msix: irq.msix) { _, ack in
        // Acked (the vector unmasked) before the queue is read, so a
        // completion posted while it is read raises the interrupt again.
        ack()
        disk.serviceInterrupt()
      }
      status = {
        let (i, p) = thread.counts
        return "model \(disk.model)\nserial \(disk.serial)\nnamespace \(disk.namespace)\nsectors \(disk.sectors)\n"
          + "sector \(disk.sectorSize)\nwrite-cache \(disk.writeCache)\ntransfer \(disk.chunk)\n"
          + "interrupt \(irq.msix ? "MSI-X" : "INTx")\nrequests \(disk.requests) failures \(disk.failures)\n"
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
    print("nvme: " + lines.joined(separator: "; "))

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
