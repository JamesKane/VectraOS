// SPDX-License-Identifier: BSD-3-Clause

// The bus below an xHCI controller: its root ports' devices and the hubs'
// below them, each given a slot, addressed and described (USB 2.0 §9.1.2),
// and the ones it has a use for configured: hubs (USB 2.0 ch. 11, USB 3.2
// ch. 10), whose ports it powers, resets and watches through their status
// change endpoints, and HID's boot keyboards and mice, whose reports go to
// kbdfs's kbin and the mouse service's mousein as the input class's
// records (BootKeyboard, BootMouse; D83). One thread runs it: the
// controller's events, each in turn, and a device's enumeration with its
// control transfers waited for in between.

import CroiMMIO
import DriverHost
import IPC
import InputDevice
import Node
import Sys

/// An interrupt IN endpoint this driver reads: its context index, ring,
/// the page its reports land in, and what reads them.
final class InterruptEndpoint {
  enum Role {
    case keyboard(BootKeyboard)
    case mouse(BootMouse)
    case hub
  }

  let index: Int
  var ring: ProducerRing
  let buffer: Page
  let length: Int
  var role: Role
  var inFlight: UInt64 = 0
  var failures = 0

  init(index: Int, ring: ProducerRing, buffer: Page, length: Int, role: Role) {
    self.index = index
    self.ring = ring
    self.buffer = buffer
    self.length = length
    self.role = role
  }
}

/// A device on the bus.
final class USBDevice {
  let slot: Int
  let speed: Speed
  let placement: Placement
  /// The hub it hangs from (its slot; 0 for a root port) and the port.
  let parent: Int, port: Int
  let output: Page, input: Page, buffer: Page
  var ep0: ProducerRing
  var packetSize0: Int
  var descriptor: DeviceDescriptor?
  var endpoints: [InterruptEndpoint] = []
  /// As a hub: its ports and its translator's think time.
  var hubPorts = 0, thinkTime: UInt32 = 0
  var what = "unconfigured"

  init(slot: Int, speed: Speed, placement: Placement, parent: Int, port: Int, output: Page, input: Page,
       buffer: Page, ep0: ProducerRing) {
    self.slot = slot
    self.speed = speed
    self.placement = placement
    self.parent = parent
    self.port = port
    self.output = output
    self.input = input
    self.buffer = buffer
    self.ep0 = ep0
    packetSize0 = speed.defaultPacketSize0
  }

  /// `3.1.2`: its root port, then each hub port below.
  var path: String {
    var parts = ["\(placement.rootPort)"]
    for tier in 0..<placement.depth { parts.append("\((placement.route >> (4 * UInt32(tier))) & 0xF)") }
    return parts.joined(separator: ".")
  }
}

/// What the bus counts, for the status, and the devices' lines.
final class BusCounts: @unchecked Sendable {
  let lock = Lock()
  var devices: [String] = []
  var keys = 0, keysRefused = 0, reports = 0, reportsRefused = 0
  var transferErrors = 0, attachFailures = 0
  var interrupts = 0
  /// Whether the devices there at the start have been looked at.
  var ready = false
}

final class Bus {
  let hc: Controller
  let counts: BusCounts
  var devices: [USBDevice] = []
  var kbin: NodeIPC.NodeClient, mousein: NodeIPC.NodeClient
  let hasKbin: Bool, hasMousein: Bool

  init(_ hc: Controller, counts: BusCounts, kbin: UInt32, mousein: UInt32) {
    self.hc = hc
    self.counts = counts
    self.kbin = NodeIPC.NodeClient(channel: Handle(raw: kbin))
    self.mousein = NodeIPC.NodeClient(channel: Handle(raw: mousein))
    hasKbin = kbin != 0
    hasMousein = mousein != 0
  }

  /// The devices on the root ports now, then the controller's events for good.
  func run() -> Never {
    for p in 1...max(hc.ports, 1) where hc.ports > 0 { rootChanged(p) }
    publish()
    counts.lock.withLock { counts.ready = true }
    while true {
      var events = hc.pending
      hc.pending = []
      if events.isEmpty { events = hc.waitForEvents(until: infiniteDeadline) }
      for e in events { handle(e) }
      counts.lock.withLock { counts.interrupts = hc.interrupts }
    }
  }

  func handle(_ e: TRB) {
    switch e.type {
    case TRBType.portStatusChange:
      rootChanged(Int(e.parameter >> 24) & 0xFF)
    case TRBType.transferEvent:
      guard let d = devices.first(where: { $0.slot == e.slot }),
            let ep = d.endpoints.first(where: { $0.index == e.endpoint }), e.parameter == ep.inFlight else { return }
      completed(d, ep, e)
    default:
      break
    }
  }

  /// The devices' lines, for the status.
  func publish() {
    let lines = devices.map { d -> String in
      let ids = d.descriptor.map { hexText(UInt32($0.vendor), digits: 4) + ":" + hexText(UInt32($0.product), digits: 4) } ?? "-"
      return "port \(d.path): \(ids) \(d.speed.name) speed, slot \(d.slot): \(d.what)"
    }
    counts.lock.withLock { counts.devices = lines }
  }

  // MARK: Ports

  /// A root port's connection changed, or is being looked at for the first
  /// time: its device attached or detached.
  func rootChanged(_ port: Int) {
    guard port >= 1, port <= hc.ports else { return }
    let v = hc.clearChanges(port)
    let present = devices.first { $0.parent == 0 && $0.port == port }
    if v & Controller.Port.connected != 0, present == nil {
      sleep(until: Clock.monotonic() + 100_000_000)  // TATTDB, the connection's debounce
      guard let speed = hc.enable(port: port) else { return }
      attach(Placement(rootPort: port), speed: speed, parent: 0, port: port)
    } else if v & Controller.Port.connected == 0, let present {
      detach(present)
    }
    publish()
  }

  /// A hub's port changed: its device attached or detached.
  func hubChanged(_ hub: USBDevice, _ port: Int) {
    guard let (status, change) = hubPortStatus(hub, port) else { return }
    let changes: [(bit: UInt16, feature: UInt16)] = [
      (0, HubPort.cConnection), (1, HubPort.cEnable), (2, HubPort.cSuspend), (3, HubPort.cOverCurrent),
      (4, HubPort.cReset), (5, HubPort.cBHReset), (6, HubPort.cLinkState), (7, HubPort.cConfigError),
    ]
    for c in changes where change & (1 << c.bit) != 0 {
      _ = try? control(hub, .clearPortFeature(c.feature, port: UInt8(port)))
    }
    let present = devices.first { $0.parent == hub.slot && $0.port == port }
    if status & HubPort.connected != 0, present == nil {
      attachBelow(hub, port)
    } else if status & HubPort.connected == 0, let present {
      detach(present)
    }
    publish()
  }

  func hubPortStatus(_ hub: USBDevice, _ port: Int) -> (status: UInt16, change: UInt16)? {
    guard let b = try? control(hub, .getPortStatus(UInt8(port))), b.count >= 4 else { return nil }
    return (UInt16(b[0]) | UInt16(b[1]) << 8, UInt16(b[2]) | UInt16(b[3]) << 8)
  }

  /// The device on a hub's port, after the port's reset.
  func attachBelow(_ hub: USBDevice, _ port: Int) {
    sleep(until: Clock.monotonic() + 100_000_000)  // TATTDB
    guard (try? control(hub, .setPortFeature(HubPort.reset, port: UInt8(port)))) != nil else { return }
    var status: UInt16 = 0
    let reset = Controller.waitFor(500) {
      guard let s = self.hubPortStatus(hub, port) else { return false }
      status = s.status
      return s.change & 1 << 4 != 0
    }
    _ = try? control(hub, .clearPortFeature(HubPort.cReset, port: UInt8(port)))
    guard reset, status & HubPort.connected != 0, status & HubPort.enabled != 0 else { return }
    let speed: Speed = hub.speed == .superSpeed || hub.speed == .superSpeedPlus ? .superSpeed
      : status & HubPort.lowSpeed != 0 ? .low : status & HubPort.highSpeed != 0 ? .high : .full
    sleep(until: Clock.monotonic() + 10_000_000)  // TRSTRCY
    attach(hub.placement.below(port: port, hubSlot: hub.slot, hubSpeed: hub.speed, speed: speed), speed: speed,
           parent: hub.slot, port: port)
  }

  // MARK: Devices

  /// A new device: a slot, its address, its descriptors, and what it is
  /// configured as. A failure leaves it out, its slot given back.
  func attach(_ placement: Placement, speed: Speed, parent: Int, port: Int) {
    // Made but not yet on the bus, or on it and being configured.
    var made: USBDevice?, listed: USBDevice?
    do throws(Status) {
      let slot = try hc.command(TRBType.enableSlot).slot
      let output = try hc.pages.take(), input = try hc.pages.take(), buffer = try hc.pages.take()
      let d = USBDevice(slot: slot, speed: speed, placement: placement, parent: parent, port: port, output: output,
                        input: input, buffer: buffer, ep0: ProducerRing(try hc.pages.take()))
      made = d
      hc.setDeviceContext(slot, output)
      // Address Device (§4.3.3): the slot's context and endpoint 0's.
      input.store32(4, 0b11)
      fillSlot(d, entries: 1)
      fillEndpoint0(d)
      try hc.command(TRBType.addressDevice, slot: slot, parameter: input.bus)
      // Endpoint 0's packet size from the descriptor's first 8 bytes.
      guard let head = DeviceDescriptor(try control(d, .getDescriptor(1, length: 8))) else { throw Status.io }
      if head.packetSize0 != d.packetSize0, head.packetSize0 >= 8 {
        d.packetSize0 = head.packetSize0
        input.zero()
        input.store32(4, 0b10)
        fillEndpoint0(d)
        try hc.command(TRBType.evaluateContext, slot: slot, parameter: input.bus)
      }
      d.descriptor = DeviceDescriptor(try control(d, .getDescriptor(1, length: 18)))
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
      if let d = made { release(d) }
      listed?.what = "failed: status \(error.rawValue)"
    }
    publish()
  }

  /// A device gone, with whatever hangs below it.
  func detach(_ d: USBDevice) {
    for child in devices where child.parent == d.slot { detach(child) }
    devices.removeAll { $0 === d }
    release(d)
  }

  func release(_ d: USBDevice) {
    _ = try? hc.command(TRBType.disableSlot, slot: d.slot)
    hc.setDeviceContext(d.slot, nil)
    for p in [d.output, d.input, d.buffer, d.ep0.page] { hc.pages.give(p) }
    for e in d.endpoints {
      hc.pages.give(e.ring.page)
      hc.pages.give(e.buffer)
    }
    d.endpoints = []
  }

  // MARK: Contexts

  var cs: Int { hc.contextSize }

  /// The input context's slot context (§6.2.2): where the device is, and
  /// as a hub its ports and translator.
  func fillSlot(_ d: USBDevice, entries: Int) {
    let p = d.placement, o = cs
    let hub: UInt32 = d.hubPorts > 0 ? 1 << 26 : 0
    d.input.store32(o, p.route | UInt32(d.speed.rawValue) << 20 | hub | UInt32(entries) << 27)
    d.input.store32(o + 4, UInt32(p.rootPort) << 16 | UInt32(d.hubPorts) << 24)
    d.input.store32(o + 8, UInt32(p.ttSlot) | UInt32(p.ttPort) << 8 | d.thinkTime << 16)
  }

  /// An endpoint context (§6.2.3) in the input context.
  func fillEndpoint(_ d: USBDevice, index: Int, type: UInt32, packet: Int, interval: UInt32 = 0, burst: UInt32 = 0,
                    esit: UInt32 = 0, average: UInt32, ring: ProducerRing) {
    let o = cs * (1 + index)
    d.input.store32(o, interval << 16 | (esit >> 16) << 24)
    d.input.store32(o + 4, 3 << 1 | type << 3 | burst << 8 | UInt32(packet) << 16)
    d.input.store64(o + 8, ring.dequeuePointer)
    d.input.store32(o + 16, average | (esit & 0xFFFF) << 16)
  }

  func fillEndpoint0(_ d: USBDevice) {
    fillEndpoint(d, index: 1, type: 4, packet: d.packetSize0, average: 8, ring: d.ep0)
  }

  /// Configure Endpoint (§4.6.6): the slot context again, and `endpoints`
  /// added, each with its ring.
  func configure(_ d: USBDevice, _ endpoints: [(Endpoint, InterruptEndpoint)]) throws(Status) {
    d.input.zero()
    var add: UInt32 = 1
    var entries = 1
    for (_, ep) in endpoints {
      add |= 1 << UInt32(ep.index)
      entries = max(entries, ep.index)
    }
    d.input.store32(4, add)
    fillSlot(d, entries: entries)
    for (e, ep) in endpoints {
      let esit = EndpointRules.esitPayload(e)
      fillEndpoint(d, index: ep.index, type: EndpointRules.type(e), packet: e.maxPacket,
                   interval: EndpointRules.interval(e, speed: d.speed), burst: UInt32(e.burst), esit: esit,
                   average: esit, ring: ep.ring)
    }
    try hc.command(TRBType.configureEndpoint, slot: d.slot, parameter: d.input.bus)
  }

  // MARK: Transfers

  /// A control transfer on endpoint 0 (§4.11.2.2), waited for (2 s): what
  /// its data stage read. Requests with data the host sends aren't made.
  func control(_ d: USBDevice, _ setup: SetupPacket) throws(Status) -> [UInt8] {
    let length = Int(min(setup.length, 4096))
    let reads = length > 0 && setup.deviceToHost
    var trbs = [TRB(parameter: setup.word, status: 8,
                    control: TRBType.setup << 10 | 1 << 6 | (length > 0 ? (reads ? 3 : 2) : 0) << 16)]
    if length > 0 {
      trbs.append(TRB(parameter: d.buffer.bus, status: UInt32(length),
                      control: TRBType.data << 10 | 1 << 2 | (reads ? 1 << 16 : 0)))
    }
    trbs.append(TRB(control: TRBType.status << 10 | 1 << 5 | (reads ? 0 : 1 << 16)))
    let at = d.ep0.push(trbs)
    hc.ring(d.slot, 1)
    var residual = 0
    let deadline = Clock.monotonic() + 2_000_000_000
    while true {
      guard let e = hc.wait(until: deadline, {
        $0.type == TRBType.transferEvent && $0.slot == d.slot && $0.endpoint == 1 && at.contains($0.parameter)
      }) else {
        hc.recover(slot: d.slot, endpoint: 1, ring: d.ep0, halted: false)
        throw Status.timedOut
      }
      if e.completion == CompletionCode.shortPacket, length > 0, e.parameter == at[1] {
        residual = Int(e.status & 0xFF_FFFF)
        continue
      }
      guard e.completion == CompletionCode.success else {
        counts.lock.withLock { counts.transferErrors += 1 }
        hc.recover(slot: d.slot, endpoint: 1, ring: d.ep0, halted: true)
        throw Status.io
      }
      guard e.parameter == at[at.count - 1] else { continue }
      return reads ? d.buffer.bytes(0, length - residual) : []
    }
  }

  /// An interrupt endpoint's next transfer, its buffer whole.
  func queue(_ d: USBDevice, _ ep: InterruptEndpoint) {
    ep.inFlight = ep.ring.push([TRB(parameter: ep.buffer.bus, status: UInt32(ep.length),
                                    control: TRBType.normal << 10 | 1 << 5 | 1 << 2)])[0]
    hc.ring(d.slot, ep.index)
  }

  /// An interrupt endpoint's transfer ended: its report read, the next queued.
  func completed(_ d: USBDevice, _ ep: InterruptEndpoint, _ e: TRB) {
    guard e.completion == CompletionCode.success || e.completion == CompletionCode.shortPacket else {
      counts.lock.withLock { counts.transferErrors += 1 }
      ep.failures += 1
      // A device that keeps failing is let be until its port says it left.
      guard ep.failures < 8 else { return }
      hc.recover(slot: d.slot, endpoint: ep.index, ring: ep.ring, halted: true)
      queue(d, ep)
      return
    }
    ep.failures = 0
    let report = ep.buffer.bytes(0, max(ep.length - Int(e.status & 0xFF_FFFF), 0))
    switch ep.role {
    case .keyboard(var k):
      let records = k.take(report)
      ep.role = .keyboard(k)
      if !records.isEmpty {
        let wrote = hasKbin && (try? kbin.write(offset: 0, records)) != nil
        counts.lock.withLock { if wrote { counts.keys += records.count / 2 } else { counts.keysRefused += records.count / 2 } }
      }
    case .mouse(var m):
      let records = m.take(report)
      ep.role = .mouse(m)
      if !records.isEmpty {
        let wrote = hasMousein && (try? mousein.write(offset: 0, records)) != nil
        counts.lock.withLock { if wrote { counts.reports += 1 } else { counts.reportsRefused += 1 } }
      }
    case .hub:
      queue(d, ep)
      // Bit n: port n changed (bit 0, the hub itself, isn't watched).
      for port in 1...max(d.hubPorts, 1) where d.hubPorts > 0 {
        let byte = port / 8
        if byte < report.count, report[byte] & (1 << UInt8(port % 8)) != 0 { hubChanged(d, port) }
      }
      return
    }
    queue(d, ep)
  }

  /// A new interrupt endpoint for `e`: its ring and report page.
  func interruptEndpoint(_ e: Endpoint, role: InterruptEndpoint.Role) throws(Status) -> InterruptEndpoint {
    InterruptEndpoint(index: e.contextIndex, ring: ProducerRing(try hc.pages.take()), buffer: try hc.pages.take(),
                      length: min(e.maxPacket, 4096), role: role)
  }

  // MARK: Classes

  /// A hub: configured, its descriptor read, the slot made a hub's, its
  /// ports powered and their devices attached, and its status change
  /// endpoint watched.
  func setUpHub(_ d: USBDevice, _ config: Configuration) throws(Status) {
    guard let status = config.interfaces.first?.interruptIn else { throw Status.notSupported }
    _ = try control(d, .setConfiguration(config.value))
    let superSpeed = d.speed == .superSpeed || d.speed == .superSpeedPlus
    if superSpeed { _ = try control(d, .setHubDepth(UInt16(d.placement.depth))) }
    guard let hub = HubDescriptor(try control(d, .getHubDescriptor(superSpeed: superSpeed))) else { throw Status.io }
    d.hubPorts = hub.ports
    d.thinkTime = d.speed == .high ? hub.thinkTime : 0
    let ep = try interruptEndpoint(status, role: .hub)
    d.endpoints = [ep]
    try configure(d, [(status, ep)])
    d.what = "hub, \(hub.ports) ports"
    for p in 1...max(hub.ports, 1) where hub.ports > 0 {
      _ = try? control(d, .setPortFeature(HubPort.power, port: UInt8(p)))
    }
    sleep(until: Clock.monotonic() + Int64(max(hub.powerOnToGood, 100)) * 1_000_000)
    publish()
    for p in 1...max(hub.ports, 1) where hub.ports > 0 { hubChanged(d, p) }
    queue(d, ep)
  }

  /// HID's boot keyboards and mice: configured, each such interface put
  /// in the boot protocol and its interrupt endpoint read.
  func setUpHID(_ d: USBDevice, _ config: Configuration) throws(Status) {
    let hids = config.interfaces.filter { ($0.isBootKeyboard || $0.isBootMouse) && $0.interruptIn != nil }
    guard !hids.isEmpty else {
      let classes = config.interfaces.map { hexText(UInt32($0.interfaceClass), digits: 2) }.joined(separator: ",")
      d.what = "no driver (class \(hexText(UInt32(d.descriptor?.deviceClass ?? 0), digits: 2)), interfaces \(classes))"
      return
    }
    _ = try control(d, .setConfiguration(config.value))
    var added: [(Endpoint, InterruptEndpoint)] = []
    var names: [String] = []
    for i in hids {
      guard let e = i.interruptIn else { continue }
      // Not every device takes these; a stall is no failure.
      _ = try? control(d, .setProtocol(0, interface: i.number))
      if i.isBootKeyboard { _ = try? control(d, .setIdle(interface: i.number)) }
      added.append((e, try interruptEndpoint(e, role: i.isBootKeyboard ? .keyboard(BootKeyboard()) : .mouse(BootMouse()))))
      names.append(i.isBootKeyboard ? "keyboard" : "mouse")
    }
    d.endpoints = added.map { $0.1 }
    try configure(d, added)
    d.what = names.joined(separator: ", ")
    for (_, ep) in added { queue(d, ep) }
  }
}

/// `value` as `digits` hex digits, zero-padded.
func hexText(_ value: UInt32, digits: Int) -> String {
  let s = String(value, radix: 16)
  return String(repeating: "0", count: max(digits - s.utf8.count, 0)) + s
}
