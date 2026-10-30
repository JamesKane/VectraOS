// SPDX-License-Identifier: BSD-3-Clause

// The net class over virtio-net (N1d, D82; Virtual I/O Device 1.2 §5.1):
// the receive queue (0) kept full of buffers the device writes, the
// transmit queue (1) fed a frame a write, each buffer a 2 KiB slot of memory
// the device reaches (a `DMAMemory`, as virtio-blk's backend has it). A
// buffer is the 12-byte virtio_net_hdr (all zero: no offloads were
// negotiated, so none are asked for or reported) and then the frame.
//
// Two threads drive it: the dispatcher's, a frame written to a
// conversation's data (`transmit`), and the interrupt's
// (`serviceInterrupt`: frames received go to the class, and transmit
// buffers done are free again). Each queue has its own lock, so a send
// doesn't wait for the frames received to be handled; frames are given
// to the class after the lock drops. A send takes back the buffers done
// itself, so the transmit queue interrupts only while few are free: an
// interrupt a frame sent had woken the interrupt thread for nothing.

import DriverHost
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
  let receiveLock = Lock(), transmitLock = Lock()
  let receiveAddress: UInt, receiveBus: UInt64
  let transmitAddress: UInt, transmitBus: UInt64
  /// Transmit buffers not with the device, by index.
  var transmitFree: [Int]
  /// The largest frame, its header included (no FCS).
  public static var maxFrame: Int { 1514 }

  public private(set) var received = 0
  public private(set) var transmitted = 0
  /// Frames too short to hold the header, or too long; and frames not
  /// sent for want of a free buffer.
  public private(set) var dropped = 0
  public private(set) var unsent = 0
  /// Frames sent without a notify: the device was already sending.
  public private(set) var unkicked = 0

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
    let size = device.queueSize(most: queueSize, [Self.receiveQueue, Self.transmitQueue])
    guard size >= 2 else { throw .notSupported }
    if vector != Device<W>.noVector { device.setConfigVector(vector) }
    let r = try device.makeQueue(Self.receiveQueue, size: size, memory: memory, vector: vector)
    let t = try device.makeQueue(Self.transmitQueue, size: size, memory: memory, vector: vector)
    (receive, receiveNotify) = (r.queue, r.notify * Int(multiplier))
    (transmit, transmitNotify) = (t.queue, t.notify * Int(multiplier))
    let rb = try unsafe memory.allocate(bytes: size * Self.bufferSize)
    receiveAddress = unsafe UInt(bitPattern: rb.pointer)
    receiveBus = unsafe rb.bus
    let tb = try unsafe memory.allocate(bytes: size * Self.bufferSize)
    transmitAddress = unsafe UInt(bitPattern: tb.pointer)
    transmitBus = unsafe tb.bus
    transmitFree = (0..<size).reversed().map { $0 }
    for i in 0..<size { post(i) }
    transmit.interrupts(false)
    device.set(status: device.status | DeviceStatus.driverOK)
    notify.write(receiveNotify, width: 2, UInt64(Self.receiveQueue))
  }

  /// The link's state: the device's, or up if it doesn't say.
  public var linkUp: Bool { features & Network.Feature.status == 0 || Network.config(device).status.map { $0 & 1 != 0 } ?? true }

  func post(_ i: Int) {
    _ = receive.submit([Buffer(address: receiveBus + UInt64(i * Self.bufferSize), length: UInt32(Self.bufferSize),
                               deviceWrites: true)])
  }

  /// What the device did since the last call: the frames received given
  /// to `deliver` together (after the lock drops), their buffers posted
  /// again, and transmit buffers freed.
  public func serviceInterrupt(_ deliver: ([[UInt8]]) -> Void) {
    let frames = receiveLock.withLock { () -> [[UInt8]] in
      var frames: [[UInt8]] = []
      let done = receive.completed()
      frames.reserveCapacity(done.count)
      for d in done {
        let slot = Int((d.address &- receiveBus) / UInt64(Self.bufferSize))
        guard slot >= 0, slot < receive.layout.size else { continue }
        let n = Int(d.written) - Self.headerSize
        if n > 0, n <= Self.maxFrame {
          let at = unsafe UnsafeRawPointer(bitPattern: receiveAddress + UInt(slot * Self.bufferSize + Self.headerSize))!
          frames.append(unsafe Array(UnsafeRawBufferPointer(start: at, count: n)))
        } else {
          dropped += 1
        }
        post(slot)
      }
      if !done.isEmpty, receive.needsNotify { notify.write(receiveNotify, width: 2, UInt64(Self.receiveQueue)) }
      received += frames.count
      return frames
    }
    transmitLock.withLock { reapTransmitted() }
    deliver(frames)
  }

  /// Transmit buffers the device is done with, free again; interrupts
  /// asked for only while a quarter or fewer are free. Under
  /// `transmitLock`.
  func reapTransmitted() {
    for d in transmit.completed() {
      let slot = Int((d.address &- transmitBus) / UInt64(Self.bufferSize))
      if slot >= 0, slot < transmit.layout.size { transmitFree.append(slot) }
    }
    transmit.interrupts(transmitFree.count <= transmit.layout.size / 4)
  }

  /// Sends `frame` (the dispatcher's thread, a write to a conversation's
  /// data); false if every transmit buffer is with the device. A busy
  /// device's buffers come back with its next interrupt.
  public func transmit(_ frame: [UInt8]) -> Bool {
    guard frame.count <= Self.maxFrame else { return false }
    return transmitLock.withLock {
      // Done buffers first: an interrupt may not have come yet.
      reapTransmitted()
      guard let slot = transmitFree.popLast() else {
        unsent += 1
        return false
      }
      let at = unsafe UnsafeMutableRawPointer(bitPattern: transmitAddress + UInt(slot * Self.bufferSize))!
      unsafe at.initializeMemory(as: UInt8.self, repeating: 0, count: Self.headerSize)
      frame.withUnsafeBytes { unsafe (at + Self.headerSize).copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
      _ = transmit.submit([Buffer(address: transmitBus + UInt64(slot * Self.bufferSize),
                                  length: UInt32(Self.headerSize + frame.count), deviceWrites: false)])
      transmitted += 1
      if transmit.needsNotify {
        notify.write(transmitNotify, width: 2, UInt64(Self.transmitQueue))
      } else {
        unkicked += 1
      }
      return true
    }
  }
}
