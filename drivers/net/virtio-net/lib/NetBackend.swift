// SPDX-License-Identifier: BSD-3-Clause

// The net class over virtio-net (N1d; Virtual I/O Device 1.2 §5.1): the
// receive queue (0) kept full of buffers the device writes, the transmit
// queue (1) fed from the frame ring, each buffer a 2 KiB slot of memory
// the device reaches (a `DMAMemory`, as virtio-blk's backend has it). A
// buffer is the 12-byte virtio_net_hdr (all zero: no offloads were
// negotiated, so none are asked for or reported) and then the frame.
//
// Two threads drive it: the dispatcher's, kicked by the net service
// (`transmit`), and the interrupt's (`serviceInterrupt`: frames received
// go to the ring, transmit buffers done are free again, and what the ring
// still holds goes out). One lock covers the queues; the ring's own is
// taken inside it, never the other way round.

import DriverHost
import FrameRing
import NetDevice
import Sys
import Virtio

@safe public final class VirtioNetBackend<W: Window>: @unchecked Sendable {
  /// virtio_net_hdr with num_buffers: VERSION_1 always has it (§5.1.6).
  public static var headerSize: Int { 12 }
  static var bufferSize: Int { 2048 }
  static var receiveQueue: Int { 0 }
  static var transmitQueue: Int { 1 }

  public let features: UInt64
  public let mac: [UInt8]
  public let mtu: UInt32
  let device: Device<W>
  let notify: W
  let receiveNotify: Int, transmitNotify: Int
  let receive: SplitQueue, transmit: SplitQueue
  /// Kept: the rings and buffers live as long as it does.
  let memory: DMAMemory
  let lock = Lock()
  let receiveAddress: UInt, receiveBus: UInt64
  let transmitAddress: UInt, transmitBus: UInt64
  /// Transmit buffers not with the device, by index.
  var transmitFree: [Int]
  var scratch = [UInt8](repeating: 0, count: FrameRing.maxFrame)

  public private(set) var received = 0
  public private(set) var transmitted = 0
  /// Frames received with no ring open, or too short to hold the header.
  public private(set) var dropped = 0

  /// Negotiates (the MAC address, link status, MTU), sets up both queues
  /// (`queueSize` entries, at most the device's), posts every receive
  /// buffer and sets DRIVER_OK. `vector` is each queue's and the
  /// configuration change's (MSI-X), or none (INTx).
  public init(device: Device<W>, notify: W, multiplier: UInt32, memory: DMAMemory, queueSize: Int = 128,
              vector: UInt16 = Device<W>.noVector) throws(Status)
  {
    self.device = device
    self.notify = notify
    self.memory = memory
    do throws(VirtioError) {
      features = try device.negotiate(Network.Feature.mac | Network.Feature.status | Network.Feature.mtu)
    } catch {
      throw .notSupported
    }
    let config = Network.config(device)
    // No MAC from the device: a locally administered one of our own.
    mac = config.mac ?? [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
    mtu = UInt32(config.mtu ?? 1500)
    guard device.queueCount >= 2 else { throw .notSupported }
    var size = min(queueSize, device.queueSize(Self.receiveQueue), device.queueSize(Self.transmitQueue))
    while size & (size - 1) != 0 { size &= size - 1 }  // a power of two
    guard size >= 2 else { throw .notSupported }
    let layout = QueueLayout(size: size)
    let r = try unsafe memory.allocate(bytes: layout.bytes)
    receive = unsafe SplitQueue(layout: layout, unsafe: r.pointer, busAddress: r.bus)
    let t = try unsafe memory.allocate(bytes: layout.bytes)
    transmit = unsafe SplitQueue(layout: layout, unsafe: t.pointer, busAddress: t.bus)
    let rb = try unsafe memory.allocate(bytes: size * Self.bufferSize)
    receiveAddress = unsafe UInt(bitPattern: rb.pointer)
    receiveBus = unsafe rb.bus
    let tb = try unsafe memory.allocate(bytes: size * Self.bufferSize)
    transmitAddress = unsafe UInt(bitPattern: tb.pointer)
    transmitBus = unsafe tb.bus
    transmitFree = (0..<size).reversed().map { $0 }
    do throws(VirtioError) {
      if vector != Device<W>.noVector { device.setConfigVector(vector) }
      receiveNotify = try device.enable(queue: Self.receiveQueue, size: size, descriptors: receive.descriptorsAddress,
                                        driver: receive.availableAddress, device: receive.usedAddress,
                                        vector: vector) * Int(multiplier)
      transmitNotify = try device.enable(queue: Self.transmitQueue, size: size, descriptors: transmit.descriptorsAddress,
                                         driver: transmit.availableAddress, device: transmit.usedAddress,
                                         vector: vector) * Int(multiplier)
    } catch {
      throw .notSupported
    }
    for i in 0..<size { post(i) }
    device.set(status: device.status | DeviceStatus.driverOK)
    notify.write(receiveNotify, width: 2, UInt64(Self.receiveQueue))
  }

  /// The device's MAC address and MTU, for the protocol.
  public var info: NetDeviceIPC.DeviceInfo {
    NetDeviceIPC.DeviceInfo(mac: mac.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, mtu: mtu)
  }

  /// The link's state: the device's, or up if it doesn't say.
  public var linkUp: Bool { features & Network.Feature.status == 0 || Network.config(device).status.map { $0 & 1 != 0 } ?? true }

  func post(_ i: Int) {
    _ = receive.submit([Buffer(address: receiveBus + UInt64(i * Self.bufferSize), length: UInt32(Self.bufferSize),
                               deviceWrites: true)])
  }

  /// What the device did since the last call: received frames delivered
  /// to `ring` (or dropped without one) and their buffers posted again,
  /// transmit buffers freed, and then `transmit`.
  public func serviceInterrupt(_ ring: NetDeviceRing?) {
    lock.withLock {
      let done = receive.completed()
      if !done.isEmpty {
        var frames: [(slot: Int, count: Int)] = []
        for d in done {
          let slot = Int((d.address &- receiveBus) / UInt64(Self.bufferSize))
          guard slot >= 0, slot < receive.layout.size else { continue }
          let n = Int(d.written) - Self.headerSize
          if n > 0, n <= FrameRing.maxFrame { frames.append((slot, n)) } else { dropped += 1 }
          post(slot)
        }
        if let ring {
          _ = ring.withServer { (s: inout FrameRingServer) throws(FrameRing.Corrupt) in
            for f in frames {
              let at = unsafe UnsafeRawPointer(bitPattern: receiveAddress + UInt(f.slot * Self.bufferSize + Self.headerSize))!
              scratch.withUnsafeMutableBytes { unsafe $0.baseAddress!.copyMemory(from: at, byteCount: f.count) }
              _ = try s.deliver(scratch, count: f.count)
            }
          }
          received += frames.count
        } else {
          dropped += frames.count
        }
        notify.write(receiveNotify, width: 2, UInt64(Self.receiveQueue))
      }
      for d in transmit.completed() {
        let slot = Int((d.address &- transmitBus) / UInt64(Self.bufferSize))
        if slot >= 0, slot < transmit.layout.size { transmitFree.append(slot) }
      }
      if let ring { pump(ring) }
    }
  }

  /// Takes frames from `ring` to the transmit queue (the dispatcher's
  /// thread, when the service kicks).
  public func transmit(_ ring: NetDeviceRing) { lock.withLock { pump(ring) } }

  /// Under the lock: frames out while buffers are free; when the ring is
  /// empty, idle (unless more came). When the buffers run out the driver
  /// stays awake, and the interrupt for the next one done goes on.
  func pump(_ ring: NetDeviceRing) {
    while true {
      var queued = 0
      let more = ring.withServer { (s: inout FrameRingServer) throws(FrameRing.Corrupt) -> Bool in
        while let slot = transmitFree.last {
          guard let n = try s.take(into: &scratch) else { return false }
          transmitFree.removeLast()
          let at = unsafe UnsafeMutableRawPointer(bitPattern: transmitAddress + UInt(slot * Self.bufferSize))!
          unsafe at.initializeMemory(as: UInt8.self, repeating: 0, count: Self.headerSize)
          scratch.withUnsafeBytes { unsafe (at + Self.headerSize).copyMemory(from: $0.baseAddress!, byteCount: n) }
          _ = transmit.submit([Buffer(address: transmitBus + UInt64(slot * Self.bufferSize),
                                      length: UInt32(Self.headerSize + n), deviceWrites: false)])
          queued += 1
        }
        return true
      }
      if queued > 0 {
        transmitted += queued
        notify.write(transmitNotify, width: 2, UInt64(Self.transmitQueue))
      }
      guard let more, !more else { return }  // the session ended, or no buffers
      guard ring.prepareToIdle() else { return }
    }
  }
}
