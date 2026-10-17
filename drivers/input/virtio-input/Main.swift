// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-input (M3k, M4a; V2 item 7d, D83): the driver host for a
// virtio input device (Virtual I/O Device 1.2 §5.8): keyboards, mice,
// tablets. It asks the configuration for the device's name, ids and event
// types, then fills the event queue with 8-byte buffers in memory the
// device reaches through its BTI and, woken by its interrupt (MSI-X where
// the kernel has MSIs, else INTx with a 50 ms poll), reads each
// virtio_input_event (le16 type, le16 code, le32 value: evdev's codes) and
// posts the buffer again. A keyboard's keys go to kbdfs as HID usages
// (D83): each batch, up to the device's SYN_REPORT, one write to the
// /dev/kbin devmgr mounted for it. Mice wait for the mouse service (V5).
// Its tree: `status`.

import DriverHost
import IPC
import InputDevice
import Node
import Sys
import Virtio

/// What the event thread counts, for the status.
final class Counts: @unchecked Sendable {
  let lock = Lock()
  var events = 0
  var keys = 0
  var batches = 0
  var interrupts = 0
  var polls = 0
  var refused = 0
}

@main struct VirtioInput {
  static let buffers = 64

  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    var lines: [String] = []
    let counts = Counts()
    do throws(Status) {
      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let pci = try PCIDevice(resources)
      // MSI-X where devmgr granted it and the kernel can, else INTx.
      let irq = try pci.interrupt(resources)
      lines.append("interrupt \(irq.msix ? "MSI-X" : "INTx")")
      lines.append("capabilities \(pci.summary)")
      let device = pci.device
      let features: UInt64
      do throws(VirtioError) {
        features = try device.negotiate(0)
      } catch {
        throw Status.notSupported
      }
      // Its addresses are the BTI's: a device that takes them as physical
      // would read and write the wrong memory.
      guard features & Feature.accessPlatform != 0 else {
        lines.append("the device bypasses the IOMMU (no ACCESS_PLATFORM)")
        throw Status.notSupported
      }
      let id = Input.identity(device)
      let kind: UInt8 = id.eventTypes.contains(3) ? 3 : id.eventTypes.contains(2) ? 2 : id.eventTypes.contains(1) ? 1 : 0
      lines.append("name \(id.name)")
      lines.append("kind \(["other", "keyboard", "mouse", "tablet"][Int(kind)])")
      lines.append("events \(id.eventTypes.map { "\($0)" }.joined(separator: ","))")

      // Where a keyboard's keys go: kbdfs's kbin, which devmgr mounted.
      var kbinRaw: UInt32 = 0
      do throws(NamespaceError) {
        kbinRaw = try Namespace(start).connect("/dev/kbin").release()
        lines.append("keys to /dev/kbin")
      } catch {
        lines.append("no /dev/kbin: keys go nowhere")
      }

      // The event queue, every buffer posted.
      guard pci.notify != nil, let isr = pci.isr else { throw Status.notSupported }
      let memory = PinnedMemory(bti: bti)
      var size = min(buffers, device.queueSize(0))
      while size & (size - 1) != 0 { size &= size - 1 }
      let layout = QueueLayout(size: size)
      let rings = try unsafe memory.allocate(bytes: layout.bytes)
      let queue = unsafe SplitQueue(layout: layout, unsafe: rings.pointer, busAddress: rings.bus)
      let events = try unsafe memory.allocate(bytes: 8 * size)
      let eventsAddress = unsafe UInt(bitPattern: events.pointer), eventsBus = unsafe events.bus
      let offset: Int
      do throws(VirtioError) {
        offset = try device.enable(queue: 0, size: size, descriptors: queue.descriptorsAddress,
                                   driver: queue.availableAddress, device: queue.usedAddress, vector: irq.vector)
      } catch {
        throw Status.notSupported
      }
      for i in 0..<size {
        guard queue.submit([Buffer(address: eventsBus + UInt64(8 * i), length: 8, deviceWrites: true)]) != nil else {
          throw Status.noResources
        }
      }
      device.set(status: device.status | DeviceStatus.driverOK)
      pci.notify(queue: 0, offset: offset)
      lines.append("event queue \(size) buffers")

      // Its events, on a thread of their own.
      let port = try Port.create(bindToInterrupt: true)
      try Interrupt.bind(irq.handle, port: port, key: 1)
      let portRaw = port.release()
      let kbinChannel = kbinRaw
      _ = try Thread.spawn {
        let port = Handle(raw: portRaw)
        var kbin = NodeIPC.NodeClient(channel: Handle(raw: kbinChannel))
        var batch: [UInt8] = []
        while true {
          // On INTx, a lost interrupt costs a 50 ms poll, not a stuck
          // device; MSI-X's aren't lost, and an idle desktop takes no
          // wakeups (M6m: the poll was 20 a second for each device).
          let deadline = irq.msix ? infiniteDeadline : Clock.monotonic() + 50_000_000
          if (try? Port.wait(port, deadline: deadline)) != nil {
            counts.lock.withLock { counts.interrupts += 1 }
          } else {
            counts.lock.withLock { counts.polls += 1 }
          }
          if !irq.msix { _ = isr.read(0, width: 1) }  // lowers INTx
          try? Interrupt.ack(irq.handle)
          // Each completion's buffer, by its address (SplitQueue.completed).
          var slots: [Int] = []
          for done in queue.completed() {
            let slot = Int((done.address &- eventsBus) / 8)
            guard slot >= 0, slot < size else { continue }
            slots.append(slot)
            let at = unsafe UnsafeRawPointer(bitPattern: eventsAddress + UInt(8 * slot))!
            let type = UInt16(littleEndian: unsafe at.loadUnaligned(as: UInt16.self))
            let code = UInt16(littleEndian: unsafe at.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
            let value = Int32(littleEndian: unsafe at.loadUnaligned(fromByteOffset: 4, as: Int32.self))
            counts.lock.withLock { counts.events += 1 }
            // EV_KEY pressed (1) or released (0); a held key's repeats (2)
            // aren't presses.
            if type == 1, value == 0 || value == 1 {
              let usage = KeyboardUsage.of(evdev: code)
              if usage != 0 { batch += KeyboardUsage.record(usage, down: value == 1) }
            }
            // SYN_REPORT ends the batch: one write.
            if type == 0, code == 0, !batch.isEmpty {
              let n = batch.count / 2
              let wrote = kbinChannel != 0 && (try? kbin.write(offset: 0, batch)) != nil
              counts.lock.withLock {
                counts.batches += 1
                if wrote { counts.keys += n } else { counts.refused += n }
              }
              batch = []
            }
          }
          for slot in slots {
            _ = queue.submit([Buffer(address: eventsBus + UInt64(8 * slot), length: 8, deviceWrites: true)])
          }
          if !slots.isEmpty { pci.notify(queue: 0, offset: offset) }
          // The rings and buffers live as long as the device uses them.
          withExtendedLifetime(memory) {}
        }
      }.release()
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
    }
    let status = lines.joined(separator: "\n") + "\n"
    print("virtio-input: " + lines.joined(separator: "; "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: {
        counts.lock.withLock {
          status + "events read \(counts.events), keys to kbdfs \(counts.keys) in \(counts.batches) batches"
            + ", refused \(counts.refused)\ninterrupts \(counts.interrupts) polls \(counts.polls)\n"
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
