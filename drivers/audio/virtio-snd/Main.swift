// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-snd (D179, D180): the audio class over a virtio sound device
// (Virtual I/O Device 1.2 §5.14). It opens the device, takes memory the
// device reaches through its BTI for its queues and for each stream's
// cyclic buffer, asks the device for its streams, and serves audio(3)'s
// directory (drivers/audio/lib) at `audio` in its tree, which devmgr
// binds at /dev/audio/<n>, over VirtioSound: periods are handed to the
// device from the unit's threads, and the device's interrupt (MSI-X,
// else INTx: then a lost one costs a 50 ms poll) ends them on a thread
// of its own. Its tree: `audio`, and `status` (the device's streams,
// periods, events and control requests).

import AudioDevice
import DriverHost
import IPC
import Node
import Sys
import Virtio

@main struct VirtioSoundDriver {
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
      let sound = try VirtioSound(device: pci.device, notify: notify, multiplier: pci.notifyMultiplier,
                                  memory: PinnedMemory(bti: bti), vector: irq.vector)
      // Its addresses are the BTI's: a device that takes them as physical
      // would read and write the wrong memory.
      guard sound.features & Feature.accessPlatform != 0 else {
        lines.append("the device bypasses the IOMMU (no ACCESS_PLATFORM)")
        throw Status.notSupported
      }
      guard sound.streams.output != nil || sound.streams.input != nil else {
        lines.append("no stream the class can use")
        throw Status.notSupported
      }
      let msix = irq.msix
      lines.append("\(sound.config.streams) streams, \(msix ? "MSI-X" : "INTx")")

      // The unit's directory and its data file each on a dispatcher of
      // their own: the tree waits on its thread for a mount's answers,
      // and a write waiting for room mustn't hold up ctl or stat.
      let control = try IPCDispatcher()
      let data = try IPCDispatcher()
      let unit = AudioUnit(sound, control: control, data: data)
      sound.finished = { unit.finished($0) }
      _ = try Thread.spawn { try? control.run() }.release()
      _ = try Thread.spawn { try? data.run() }.release()
      let thread = try InterruptThread(irq.handle, msix: msix) { _, ack in
        if !msix { _ = isr.read(0, width: 1) }  // INTx: the line goes down
        ack()
        sound.serviceInterrupt()
      }
      _ = tree.mount("audio", try unit.channel())
      for d in [AudioDirection.output, .input] {
        if let c = sound.capabilities(d) { lines.append(c.line(d)) }
      }
      let f = unit.format
      lines.append("format \(f.sample.name) \(f.channels) speed \(f.rate)")
      status = {
        let (i, p) = thread.counts
        return "streams \(sound.config.streams)\ninterrupt \(msix ? "MSI-X" : "INTx")\n" + sound.report
          + "interrupts \(i) polls \(p)\n"
      }
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
      let failed = lines.joined(separator: "\n") + "\n"
      status = { failed }
    }
    print("virtio-snd: " + lines.joined(separator: "; "))

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
