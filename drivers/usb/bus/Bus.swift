// SPDX-License-Identifier: BSD-3-Clause

// The bus below a USB host controller, whatever its kind (xhci's xHCI,
// ehci's EHCI): its root ports' devices and the hubs' below them, each
// addressed and described (USB 2.0 §9.1.2), and the ones it has a use for
// configured: hubs (USB 2.0 ch. 11, USB 3.2 ch. 10), whose ports it
// powers, resets and watches through their status change endpoints, and
// HID's boot keyboards and its mice (read as their report descriptors
// lay their reports out), whose reports go to kbdfs's kbin and the mouse
// service's mousein as the input class's records (BootKeyboard,
// HIDMouse; D83). The controller is a USBHost: it addresses a device,
// runs its control transfers, opens its interrupt endpoints and reports
// what ended. One thread runs it: the controller's events, each in turn,
// and a device's enumeration with its control transfers waited for in
// between.

import IPC
import InputDevice
import Node
import Sys

/// What a bus asks of its host controller.
protocol USBHost: AnyObject {
  /// A device as the controller keeps it.
  associatedtype Slot: AnyObject

  var rootPorts: Int { get }
  /// Root port `port`'s line for the status.
  func rootPortLine(_ port: Int) -> String
  /// Root port `port`'s changes acknowledged: whether something is
  /// connected.
  func rootConnected(_ port: Int) -> Bool
  /// Root port `port` reset and enabled for its device: its speed, or nil.
  func enable(port: Int) -> Speed?
  /// The events since the last call, waited for until `deadline` if none.
  func events(until deadline: Int64) -> [HostEvent]
  var interrupts: Int { get }

  /// A new device at `placement`, given an address, its endpoint 0's
  /// packet size `packetSize0`.
  func address(speed: Speed, placement: Placement, packetSize0: Int) throws(Status) -> Slot
  /// The number the controller knows it by, in events and as a hub to
  /// the devices below it (xHCI's slot, EHCI's address).
  func number(_ s: Slot) -> Int
  func setPacketSize0(_ s: Slot, _ size: Int) throws(Status)
  /// A control transfer on endpoint 0, waited for: what its data stage
  /// read. `io` for a transfer error.
  func control(_ s: Slot, _ setup: SetupPacket) throws(Status) -> [UInt8]
  /// Its interrupt IN endpoints `endpoints` opened, as a hub of `hub`'s
  /// ports and think time if it is one: each one's pipe.
  func open(_ s: Slot, _ endpoints: [Endpoint], hub: (ports: Int, thinkTime: UInt32)?) throws(Status) -> [Int]
  /// Pipe `pipe`'s next transfer.
  func queue(_ s: Slot, pipe: Int)
  /// Pipe `pipe` after a failed transfer, ready to be queued again.
  func recover(_ s: Slot, pipe: Int)
  /// Everything the controller keeps for it given back.
  func release(_ s: Slot)
  /// What the controller said of the last failure, if more than its
  /// status (`completion 4`).
  var lastDetail: String? { get }
}

/// What the controller reports.
enum HostEvent {
  /// A root port changed.
  case port(Int)
  /// A pipe's transfer ended: the report it read, or nil and the
  /// controller's code for a failure.
  case transfer(device: Int, pipe: Int, report: [UInt8]?, code: UInt32)
}

/// An interrupt IN endpoint the bus reads, and what reads it.
final class Pipe {
  enum Role {
    case keyboard(BootKeyboard)
    case mouse(HIDMouse)
    case hub
  }

  let id: Int
  var role: Role
  var failures = 0

  init(id: Int, role: Role) {
    self.id = id
    self.role = role
  }
}

/// A device on the bus.
final class USBDevice<Slot: AnyObject> {
  let slot: Slot
  /// The controller's number for it.
  let number: Int
  let speed: Speed
  let placement: Placement
  /// The hub it hangs from (its number; 0 for a root port) and the port.
  let parent: Int, port: Int
  var descriptor: DeviceDescriptor?
  var pipes: [Pipe] = []
  /// As a hub: its ports.
  var hubPorts = 0
  var what = "unconfigured"

  init(slot: Slot, number: Int, speed: Speed, placement: Placement, parent: Int, port: Int) {
    self.slot = slot
    self.number = number
    self.speed = speed
    self.placement = placement
    self.parent = parent
    self.port = port
  }
}

extension Placement {
  /// `3.1.2`: its root port, then each hub port below.
  var path: String {
    var parts = ["\(rootPort)"]
    for tier in 0..<depth { parts.append("\((route >> (4 * UInt32(tier))) & 0xF)") }
    return parts.joined(separator: ".")
  }
}

/// What the bus counts, for the status, and the devices' lines.
final class BusCounts: @unchecked Sendable {
  let lock = Lock()
  var devices: [String] = []
  var keys = 0, keysRefused = 0, reports = 0, reportsRefused = 0
  var transferErrors = 0, attachFailures = 0
  /// The last few devices that failed before they were addressed and
  /// read: a line each.
  var failed: [String] = []
  var interrupts = 0
  /// Whether the devices there at the start have been looked at.
  var ready = false
}

/// Polls `done` for up to `ms` milliseconds.
func pollFor(_ ms: Int64, _ done: () -> Bool) -> Bool {
  let until = Clock.monotonic() + ms * 1_000_000
  while !done() {
    guard Clock.monotonic() < until else { return done() }
    sleep(until: Clock.monotonic() + 100_000)
  }
  return true
}

final class Bus<Host: USBHost> {
  typealias Device = USBDevice<Host.Slot>

  let host: Host
  let counts: BusCounts
  var devices: [Device] = []
  var kbin: NodeIPC.NodeClient, mousein: NodeIPC.NodeClient
  let hasKbin: Bool, hasMousein: Bool

  init(_ host: Host, counts: BusCounts, kbin: UInt32, mousein: UInt32) {
    self.host = host
    self.counts = counts
    self.kbin = NodeIPC.NodeClient(channel: Handle(raw: kbin))
    self.mousein = NodeIPC.NodeClient(channel: Handle(raw: mousein))
    hasKbin = kbin != 0
    hasMousein = mousein != 0
  }

  /// The devices on the root ports now, then the controller's events for good.
  func run() -> Never {
    for p in 1...max(host.rootPorts, 1) where host.rootPorts > 0 { rootChanged(p) }
    publish()
    counts.lock.withLock { counts.ready = true }
    while true {
      for e in host.events(until: infiniteDeadline) { handle(e) }
      counts.lock.withLock { counts.interrupts = host.interrupts }
    }
  }

  func handle(_ e: HostEvent) {
    switch e {
    case .port(let p):
      rootChanged(p)
    case .transfer(let number, let id, let report, let code):
      guard let d = devices.first(where: { $0.number == number }), let pipe = d.pipes.first(where: { $0.id == id })
      else { return }
      completed(d, pipe, report, code: code)
    }
  }

  /// The root ports' and devices' lines, for the status.
  func publish() {
    let ports = (1...max(host.rootPorts, 1)).filter { _ in host.rootPorts > 0 }.map { host.rootPortLine($0) }
    let lines = devices.map { d -> String in
      let ids = d.descriptor.map { hexText(UInt32($0.vendor), digits: 4) + ":" + hexText(UInt32($0.product), digits: 4) } ?? "-"
      return "port \(d.placement.path): \(ids) \(d.speed.name) speed, slot \(d.number): \(d.what)"
    }
    counts.lock.withLock { counts.devices = ports + lines + counts.failed }
  }

  func noteFailure(_ line: String) {
    counts.lock.withLock { counts.failed = Array(counts.failed.suffix(7)) + [line] }
  }

  // MARK: Ports

  /// A root port's connection changed, or is being looked at for the first
  /// time: its device attached or detached.
  func rootChanged(_ port: Int) {
    guard port >= 1, port <= host.rootPorts else { return }
    let connected = host.rootConnected(port)
    let present = devices.first { $0.parent == 0 && $0.port == port }
    if connected, present == nil {
      sleep(until: Clock.monotonic() + 100_000_000)  // TATTDB, the connection's debounce
      guard let speed = host.enable(port: port) else {
        noteFailure("port \(port): failed at its reset: not enabled")
        publish()
        return
      }
      attach(Placement(rootPort: port), speed: speed, parent: 0, port: port)
    } else if !connected, let present {
      detach(present)
    }
    publish()
  }

  /// A hub's port changed: its device attached or detached.
  func hubChanged(_ hub: Device, _ port: Int) {
    guard let (status, change) = hubPortStatus(hub, port) else { return }
    let changes: [(bit: UInt16, feature: UInt16)] = [
      (0, HubPort.cConnection), (1, HubPort.cEnable), (2, HubPort.cSuspend), (3, HubPort.cOverCurrent),
      (4, HubPort.cReset), (5, HubPort.cBHReset), (6, HubPort.cLinkState), (7, HubPort.cConfigError),
    ]
    for c in changes where change & (1 << c.bit) != 0 {
      _ = try? control(hub, .clearPortFeature(c.feature, port: UInt8(port)))
    }
    let present = devices.first { $0.parent == hub.number && $0.port == port }
    if status & HubPort.connected != 0, present == nil {
      attachBelow(hub, port)
    } else if status & HubPort.connected == 0, let present {
      detach(present)
    }
    publish()
  }

  func hubPortStatus(_ hub: Device, _ port: Int) -> (status: UInt16, change: UInt16)? {
    guard let b = try? control(hub, .getPortStatus(UInt8(port))), b.count >= 4 else { return nil }
    return (UInt16(b[0]) | UInt16(b[1]) << 8, UInt16(b[2]) | UInt16(b[3]) << 8)
  }

  /// The device on a hub's port, after the port's reset.
  func attachBelow(_ hub: Device, _ port: Int) {
    sleep(until: Clock.monotonic() + 100_000_000)  // TATTDB
    guard (try? control(hub, .setPortFeature(HubPort.reset, port: UInt8(port)))) != nil else { return }
    var status: UInt16 = 0
    let reset = pollFor(500) {
      guard let s = self.hubPortStatus(hub, port) else { return false }
      status = s.status
      return s.change & 1 << 4 != 0
    }
    _ = try? control(hub, .clearPortFeature(HubPort.cReset, port: UInt8(port)))
    guard reset, status & HubPort.connected != 0, status & HubPort.enabled != 0 else { return }
    let speed: Speed = hub.speed == .superSpeed || hub.speed == .superSpeedPlus ? .superSpeed
      : status & HubPort.lowSpeed != 0 ? .low : status & HubPort.highSpeed != 0 ? .high : .full
    sleep(until: Clock.monotonic() + 10_000_000)  // TRSTRCY
    attach(hub.placement.below(port: port, hubSlot: hub.number, hubSpeed: hub.speed, speed: speed), speed: speed,
           parent: hub.number, port: port)
  }

  // MARK: Devices

  /// A new device: an address, its descriptors, and what it is configured
  /// as. A failure leaves it out, what the controller kept for it given
  /// back.
  func attach(_ placement: Placement, speed: Speed, parent: Int, port: Int) {
    // Made but not yet on the bus, or on it and being configured.
    var made: Host.Slot?, listed: Device?
    var step = "address device"
    do throws(Status) {
      let slot = try host.address(speed: speed, placement: placement, packetSize0: speed.defaultPacketSize0)
      made = slot
      let d = Device(slot: slot, number: host.number(slot), speed: speed, placement: placement, parent: parent,
                     port: port)
      step = "device descriptor"
      // Endpoint 0's packet size from the descriptor's first 8 bytes.
      guard let head = DeviceDescriptor(try control(d, .getDescriptor(1, length: 8))) else { throw Status.io }
      if head.packetSize0 != speed.defaultPacketSize0, head.packetSize0 >= 8 {
        try host.setPacketSize0(slot, head.packetSize0)
      }
      d.descriptor = DeviceDescriptor(try control(d, .getDescriptor(1, length: 18)))
      step = "configuration descriptor"
      guard let first = Configuration(try control(d, .getDescriptor(2, length: 9))) else { throw Status.io }
      guard let config = Configuration(try control(d, .getDescriptor(2, length: UInt16(min(first.totalLength, 4096)))))
      else { throw Status.io }
      devices.append(d)
      (made, listed) = (nil, d)
      if d.descriptor?.deviceClass == 9 {
        try setUpHub(d, config)
      } else {
        try setUpHID(d, config)
      }
    } catch {
      counts.lock.withLock { counts.attachFailures += 1 }
      if listed == nil {
        noteFailure("port \(placement.path): \(speed.name) speed: failed at \(step): status \(error.rawValue)"
          + (host.lastDetail.map { ", " + $0 } ?? ""))
      }
      if let s = made { host.release(s) }
      listed?.what = "failed: status \(error.rawValue)"
    }
    publish()
  }

  /// A device gone, with whatever hangs below it.
  func detach(_ d: Device) {
    for child in devices where child.parent == d.number { detach(child) }
    devices.removeAll { $0 === d }
    host.release(d.slot)
    d.pipes = []
  }

  // MARK: Transfers

  /// A control transfer on endpoint 0 (2 s), its transfer errors counted.
  func control(_ d: Device, _ setup: SetupPacket) throws(Status) -> [UInt8] {
    do {
      return try host.control(d.slot, setup)
    } catch {
      if error == .io { counts.lock.withLock { counts.transferErrors += 1 } }
      throw error
    }
  }

  /// A pipe's transfer ended: its report read, the next queued.
  func completed(_ d: Device, _ pipe: Pipe, _ report: [UInt8]?, code: UInt32) {
    guard let report else {
      counts.lock.withLock { counts.transferErrors += 1 }
      pipe.failures += 1
      // A device that keeps failing is let be until its port says it left.
      guard pipe.failures < 8 else {
        print("usb: slot \(d.number) pipe \(pipe.id) failed 8 times (code \(code)): let be")
        return
      }
      host.recover(d.slot, pipe: pipe.id)
      host.queue(d.slot, pipe: pipe.id)
      return
    }
    pipe.failures = 0
    switch pipe.role {
    case .keyboard(var k):
      let records = k.take(report)
      pipe.role = .keyboard(k)
      if !records.isEmpty {
        let wrote = hasKbin && (try? kbin.write(offset: 0, records)) != nil
        counts.lock.withLock { if wrote { counts.keys += records.count / 2 } else { counts.keysRefused += records.count / 2 } }
      }
    case .mouse(var m):
      let records = m.take(report)
      pipe.role = .mouse(m)
      if !records.isEmpty {
        let wrote = hasMousein && (try? mousein.write(offset: 0, records)) != nil
        counts.lock.withLock { if wrote { counts.reports += 1 } else { counts.reportsRefused += 1 } }
      }
    case .hub:
      host.queue(d.slot, pipe: pipe.id)
      // Bit n: port n changed (bit 0, the hub itself, isn't watched).
      for port in 1...max(d.hubPorts, 1) where d.hubPorts > 0 {
        let byte = port / 8
        if byte < report.count, report[byte] & (1 << UInt8(port % 8)) != 0 { hubChanged(d, port) }
      }
      return
    }
    host.queue(d.slot, pipe: pipe.id)
  }

  // MARK: Classes

  /// A hub: configured, its descriptor read, the device made a hub's, its
  /// ports powered and their devices attached, and its status change
  /// endpoint watched.
  func setUpHub(_ d: Device, _ config: Configuration) throws(Status) {
    guard let status = config.interfaces.first?.interruptIn else { throw Status.notSupported }
    _ = try control(d, .setConfiguration(config.value))
    let superSpeed = d.speed == .superSpeed || d.speed == .superSpeedPlus
    if superSpeed { _ = try control(d, .setHubDepth(UInt16(d.placement.depth))) }
    guard let hub = HubDescriptor(try control(d, .getHubDescriptor(superSpeed: superSpeed))) else { throw Status.io }
    d.hubPorts = hub.ports
    let ids = try host.open(d.slot, [status], hub: (hub.ports, d.speed == .high ? hub.thinkTime : 0))
    let pipe = Pipe(id: ids[0], role: .hub)
    d.pipes = [pipe]
    d.what = "hub, \(hub.ports) ports"
    for p in 1...max(hub.ports, 1) where hub.ports > 0 {
      _ = try? control(d, .setPortFeature(HubPort.power, port: UInt8(p)))
    }
    sleep(until: Clock.monotonic() + Int64(max(hub.powerOnToGood, 100)) * 1_000_000)
    publish()
    for p in 1...max(hub.ports, 1) where hub.ports > 0 { hubChanged(d, p) }
    host.queue(d.slot, pipe: pipe.id)
  }

  /// HID's boot keyboards and mice: configured, each such interface put
  /// in the boot protocol (a mouse whose report descriptor lays out a
  /// pointer, in the report protocol) and its interrupt endpoint read.
  func setUpHID(_ d: Device, _ config: Configuration) throws(Status) {
    let hids = config.interfaces.filter { ($0.isBootKeyboard || $0.isBootMouse) && $0.interruptIn != nil }
    guard !hids.isEmpty else {
      let classes = config.interfaces.map { hexText(UInt32($0.interfaceClass), digits: 2) }.joined(separator: ",")
      d.what = "no driver (class \(hexText(UInt32(d.descriptor?.deviceClass ?? 0), digits: 2)), interfaces \(classes))"
      return
    }
    _ = try control(d, .setConfiguration(config.value))
    var endpoints: [Endpoint] = []
    var roles: [Pipe.Role] = []
    var names: [String] = []
    for i in hids {
      guard let e = i.interruptIn else { continue }
      // A mouse's reports as its descriptor lays them out, in the report
      // protocol: not every mouse honours the boot protocol. Else, and for
      // keyboards, the boot protocol. Not every device takes these
      // requests; a stall is no failure.
      let layout = i.isBootKeyboard
        ? nil : (try? control(d, .getReportDescriptor(interface: i.number, length: 1024))).flatMap { MouseLayout.parse($0) }
      _ = try? control(d, .setProtocol(layout == nil ? 0 : 1, interface: i.number))
      if i.isBootKeyboard { _ = try? control(d, .setIdle(interface: i.number)) }
      endpoints.append(e)
      roles.append(i.isBootKeyboard ? .keyboard(BootKeyboard()) : .mouse(HIDMouse(layout: layout ?? .boot)))
      names.append(i.isBootKeyboard ? "keyboard" : layout == nil ? "mouse" : "mouse (its report descriptor's)")
    }
    let ids = try host.open(d.slot, endpoints, hub: nil)
    d.pipes = zip(ids, roles).map { Pipe(id: $0.0, role: $0.1) }
    d.what = names.joined(separator: ", ")
    for p in d.pipes { host.queue(d.slot, pipe: p.id) }
  }
}

/// `value` as `digits` hex digits, zero-padded.
func hexText(_ value: UInt32, digits: Int) -> String {
  let s = String(value, radix: 16)
  return String(repeating: "0", count: max(digits - s.utf8.count, 0)) + s
}
