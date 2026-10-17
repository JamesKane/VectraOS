// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-input (M3k, M4a; V2 item 7d): the driver host for a virtio
// input device (Virtual I/O Device 1.2 §5.8): keyboards, mice, tablets. It
// asks the configuration for the device's name, ids and event types, then
// fills the event queue with 8-byte buffers in memory the device reaches
// through its BTI and, woken by its interrupt (MSI-X where the kernel has
// MSIs, else INTx with a 50 ms poll), reads each virtio_input_event (le16
// type, le16 code, le32 value: evdev's codes) and posts the buffer again.
// Each batch, up to the device's SYN_REPORT, goes to the reader's ring at
// once (the input class, drivers/input/lib), stamped with the interrupt's
// time. Its tree: `status`, and `device` (InputDeviceIPC.Device), whose
// `open` gives it a reader's ring.

import DriverHost
import IPC
import InputDevice
import Node
import Sys
import Virtio

/// What the event thread and the tree share.
final class Shared: @unchecked Sendable {
  let lock = Lock()
  var writer: InputWriter?
  var batch: [InputEvent] = []
  var events = 0
  var batches = 0
  var interrupts = 0
  var polls = 0
  var readers = 0
}

struct DeviceSession: InputDeviceIPC.DeviceHandler {
  let deviceInfo: InputDeviceIPC.DeviceInfo
  let shared: Shared

  func info() -> InputDeviceIPC.DeviceInfo { deviceInfo }

  func open(_ events: consuming InputDeviceIPC.Events) throws(InputDeviceIPC.InputError) {
    guard let writer = InputWriter(events) else { throw .invalid }
    shared.lock.withLock {
      shared.writer = writer
      shared.readers += 1
    }
  }
}

@main struct VirtioInput {
  static let buffers = 64

  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    var lines: [String] = []
    let shared = Shared()
    var info = InputDeviceIPC.DeviceInfo(name: "?", kind: 0, vendor: 0, product: 0)
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
      info = InputDeviceIPC.DeviceInfo(name: id.name, kind: kind, vendor: id.vendor, product: id.product)
      lines.append("name \(id.name)")
      lines.append("kind \(["other", "keyboard", "mouse", "tablet"][Int(kind)])")
      lines.append("events \(id.eventTypes.map { "\($0)" }.joined(separator: ","))")

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
      _ = try Thread.spawn {
        let port = Handle(raw: portRaw)
        while true {
          // On INTx, a lost interrupt costs a 50 ms poll, not a stuck
          // device; MSI-X's aren't lost, and an idle desktop takes no
          // wakeups (M6m: the poll was 20 a second for each device).
          let deadline = irq.msix ? infiniteDeadline : Clock.monotonic() + 50_000_000
          var time = Clock.monotonic()
          if let packet = try? Port.wait(port, deadline: deadline) {
            time = Int64(bitPattern: packet.payload.0)
            shared.lock.withLock { shared.interrupts += 1 }
          } else {
            shared.lock.withLock { shared.polls += 1 }
          }
          if !irq.msix { _ = isr.read(0, width: 1) }  // lowers INTx
          try? Interrupt.ack(irq.handle)
          // Each completion's buffer, by its address (SplitQueue.completed).
          var read: [(slot: Int, event: InputEvent)] = []
          for done in queue.completed() {
            let slot = Int((done.address &- eventsBus) / 8)
            guard slot >= 0, slot < size else { continue }
            let at = unsafe UnsafeRawPointer(bitPattern: eventsAddress + UInt(8 * slot))!
            read.append((slot, InputEvent(time: time, type: UInt16(littleEndian: unsafe at.loadUnaligned(as: UInt16.self)),
                                          code: UInt16(littleEndian: unsafe at.loadUnaligned(fromByteOffset: 2, as: UInt16.self)),
                                          value: Int32(littleEndian: unsafe at.loadUnaligned(fromByteOffset: 4, as: Int32.self)))))
          }
          for r in read {
            _ = queue.submit([Buffer(address: eventsBus + UInt64(8 * r.slot), length: 8, deviceWrites: true)])
            shared.lock.withLock {
              shared.events += 1
              shared.batch.append(r.event)
              guard r.event.endsBatch else { return }
              shared.batches += 1
              if let w = shared.writer, !w.post(shared.batch) { shared.writer = nil }  // its ring broke
              shared.batch = []
            }
          }
          if !read.isEmpty { pci.notify(queue: 0, offset: offset) }
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
        shared.lock.withLock {
          status + "events read \(shared.events) in \(shared.batches) batches, dropped \(shared.writer?.dropped ?? 0)\n"
            + "interrupts \(shared.interrupts) polls \(shared.polls)\nreaders \(shared.readers)\n"
        }
      })
      let deviceInfo = info
      _ = tree.service("device") { (channel: consuming Handle) throws(Status) in
        try dispatcher.add(InputDeviceIPC.DeviceServer(channel: channel,
                                                       impl: DeviceSession(deviceInfo: deviceInfo, shared: shared)))
      }
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}
