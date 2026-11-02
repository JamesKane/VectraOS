// SPDX-License-Identifier: BSD-3-Clause

// An xHCI controller as the USB bus's host (Bus.swift): a device is a
// slot, addressed by Address Device with its slot and endpoint 0
// contexts (§4.3.3), a hub made one in its slot context, and an
// interrupt endpoint a transfer ring in its endpoint context, added by
// Configure Endpoint (§4.6.6). Transfers end as the event ring's
// transfer events.

import Sys

/// A slot: its device's contexts and rings.
final class XHCISlot {
  let slot: Int
  let speed: Speed
  let placement: Placement
  let output: Page, input: Page, buffer: Page
  var ep0: ProducerRing
  var packetSize0: Int
  var hubPorts = 0, thinkTime: UInt32 = 0
  var pipes: [XHCIPipe] = []

  init(slot: Int, speed: Speed, placement: Placement, packetSize0: Int, output: Page, input: Page, buffer: Page,
       ep0: ProducerRing) {
    self.slot = slot
    self.speed = speed
    self.placement = placement
    self.packetSize0 = packetSize0
    self.output = output
    self.input = input
    self.buffer = buffer
    self.ep0 = ep0
  }
}

/// An interrupt IN endpoint: its context index (the pipe's id), ring, and
/// the page its reports land in.
final class XHCIPipe {
  let index: Int
  var ring: ProducerRing
  let buffer: Page
  let length: Int
  var inFlight: UInt64 = 0

  init(index: Int, ring: ProducerRing, buffer: Page, length: Int) {
    self.index = index
    self.ring = ring
    self.buffer = buffer
    self.length = length
  }
}

final class XHCIHost: USBHost {
  let hc: Controller
  var slots: [XHCISlot] = []
  var lastDetail: String?

  init(_ hc: Controller) { self.hc = hc }

  var rootPorts: Int { hc.ports }
  var interrupts: Int { hc.interrupts }

  /// `root port 2: USB 3, connected, link 0`: its protocol, connection
  /// and link state (PORTSC's PLS: 0 U0, 3 U3, 4 disabled, 5 Rx.Detect,
  /// 7 polling, 9 compliance).
  func rootPortLine(_ port: Int) -> String {
    let v = hc.portStatus(port)
    return "root port \(port): USB \(hc.portMajor[port - 1]), "
      + (v & Controller.Port.connected != 0 ? "connected" : "empty") + ", link \((v >> 5) & 0xF)"
  }

  func rootConnected(_ port: Int) -> Bool { hc.clearChanges(port) & Controller.Port.connected != 0 }

  func enable(port: Int) -> Speed? { hc.enable(port: port) }

  func number(_ s: XHCISlot) -> Int { s.slot }

  func events(until deadline: Int64) -> [HostEvent] {
    var trbs = hc.pending
    hc.pending = []
    if trbs.isEmpty { trbs = hc.waitForEvents(until: deadline) }
    var out: [HostEvent] = []
    for e in trbs {
      switch e.type {
      case TRBType.portStatusChange:
        out.append(.port(Int(e.parameter >> 24) & 0xFF))
      case TRBType.transferEvent:
        guard let s = slots.first(where: { $0.slot == e.slot }),
              let p = s.pipes.first(where: { $0.index == e.endpoint }), e.parameter == p.inFlight else { continue }
        if e.completion == CompletionCode.success || e.completion == CompletionCode.shortPacket {
          let report = p.buffer.bytes(0, max(p.length - Int(e.status & 0xFF_FFFF), 0))
          out.append(.transfer(device: s.slot, pipe: p.index, report: report, code: 0))
        } else {
          out.append(.transfer(device: s.slot, pipe: p.index, report: nil, code: e.completion))
        }
      default:
        break
      }
    }
    return out
  }

  // MARK: Devices

  func address(speed: Speed, placement: Placement, packetSize0: Int) throws(Status) -> XHCISlot {
    lastDetail = nil
    var made: XHCISlot?
    do throws(Status) {
      let slot = try hc.command(TRBType.enableSlot).slot
      let s = XHCISlot(slot: slot, speed: speed, placement: placement, packetSize0: packetSize0,
                       output: try hc.pages.take(), input: try hc.pages.take(), buffer: try hc.pages.take(),
                       ep0: ProducerRing(try hc.pages.take()))
      made = s
      hc.setDeviceContext(slot, s.output)
      // Address Device (§4.3.3): the slot's context and endpoint 0's.
      s.input.store32(4, 0b11)
      fillSlot(s, entries: 1)
      fillEndpoint0(s)
      try hc.command(TRBType.addressDevice, slot: slot, parameter: s.input.bus)
      slots.append(s)
      return s
    } catch {
      lastDetail = hc.lastCompletion.map { "completion \($0)" }
      if let s = made { free(s) }
      throw error
    }
  }

  func setPacketSize0(_ s: XHCISlot, _ size: Int) throws(Status) {
    s.packetSize0 = size
    s.input.zero()
    s.input.store32(4, 0b10)
    fillEndpoint0(s)
    try hc.command(TRBType.evaluateContext, slot: s.slot, parameter: s.input.bus)
  }

  func release(_ s: XHCISlot) {
    slots.removeAll { $0 === s }
    free(s)
  }

  func free(_ s: XHCISlot) {
    _ = try? hc.command(TRBType.disableSlot, slot: s.slot)
    hc.setDeviceContext(s.slot, nil)
    for p in [s.output, s.input, s.buffer, s.ep0.page] { hc.pages.give(p) }
    for p in s.pipes {
      hc.pages.give(p.ring.page)
      hc.pages.give(p.buffer)
    }
    s.pipes = []
  }

  // MARK: Contexts

  var cs: Int { hc.contextSize }

  /// The input context's slot context (§6.2.2): where the device is, and
  /// as a hub its ports and translator.
  func fillSlot(_ s: XHCISlot, entries: Int) {
    let p = s.placement, o = cs
    let hub: UInt32 = s.hubPorts > 0 ? 1 << 26 : 0
    s.input.store32(o, p.route | UInt32(s.speed.rawValue) << 20 | hub | UInt32(entries) << 27)
    s.input.store32(o + 4, UInt32(p.rootPort) << 16 | UInt32(s.hubPorts) << 24)
    s.input.store32(o + 8, UInt32(p.ttSlot) | UInt32(p.ttPort) << 8 | s.thinkTime << 16)
  }

  /// An endpoint context (§6.2.3) in the input context.
  func fillEndpoint(_ s: XHCISlot, index: Int, type: UInt32, packet: Int, interval: UInt32 = 0, burst: UInt32 = 0,
                    esit: UInt32 = 0, average: UInt32, ring: ProducerRing) {
    let o = cs * (1 + index)
    s.input.store32(o, interval << 16 | (esit >> 16) << 24)
    s.input.store32(o + 4, 3 << 1 | type << 3 | burst << 8 | UInt32(packet) << 16)
    s.input.store64(o + 8, ring.dequeuePointer)
    s.input.store32(o + 16, average | (esit & 0xFFFF) << 16)
  }

  func fillEndpoint0(_ s: XHCISlot) {
    fillEndpoint(s, index: 1, type: 4, packet: s.packetSize0, average: 8, ring: s.ep0)
  }

  /// Configure Endpoint (§4.6.6): the slot context again, a hub's if it
  /// is one, and each endpoint added with its ring.
  func open(_ s: XHCISlot, _ endpoints: [Endpoint], hub: (ports: Int, thinkTime: UInt32)?) throws(Status) -> [Int] {
    if let hub { (s.hubPorts, s.thinkTime) = (hub.ports, hub.thinkTime) }
    var added: [(Endpoint, XHCIPipe)] = []
    for e in endpoints {
      added.append((e, XHCIPipe(index: e.contextIndex, ring: ProducerRing(try hc.pages.take()),
                                buffer: try hc.pages.take(), length: min(e.maxPacket, 4096))))
    }
    s.pipes += added.map { $0.1 }
    s.input.zero()
    var add: UInt32 = 1
    var entries = 1
    for (_, p) in added {
      add |= 1 << UInt32(p.index)
      entries = max(entries, p.index)
    }
    s.input.store32(4, add)
    fillSlot(s, entries: entries)
    for (e, p) in added {
      let esit = EndpointRules.esitPayload(e)
      fillEndpoint(s, index: p.index, type: EndpointRules.type(e), packet: e.maxPacket,
                   interval: EndpointRules.interval(e, speed: s.speed), burst: UInt32(e.burst), esit: esit,
                   average: esit, ring: p.ring)
    }
    try hc.command(TRBType.configureEndpoint, slot: s.slot, parameter: s.input.bus)
    return added.map { $0.1.index }
  }

  // MARK: Transfers

  /// A control transfer on endpoint 0 (§4.11.2.2), waited for (2 s): what
  /// its data stage read. Requests with data the host sends aren't made.
  func control(_ s: XHCISlot, _ setup: SetupPacket) throws(Status) -> [UInt8] {
    let length = Int(min(setup.length, 4096))
    let reads = length > 0 && setup.deviceToHost
    var trbs = [TRB(parameter: setup.word, status: 8,
                    control: TRBType.setup << 10 | 1 << 6 | (length > 0 ? (reads ? 3 : 2) : 0) << 16)]
    if length > 0 {
      trbs.append(TRB(parameter: s.buffer.bus, status: UInt32(length),
                      control: TRBType.data << 10 | 1 << 2 | (reads ? 1 << 16 : 0)))
    }
    trbs.append(TRB(control: TRBType.status << 10 | 1 << 5 | (reads ? 0 : 1 << 16)))
    let at = s.ep0.push(trbs)
    hc.ring(s.slot, 1)
    var residual = 0
    let deadline = Clock.monotonic() + 2_000_000_000
    while true {
      guard let e = hc.wait(until: deadline, {
        $0.type == TRBType.transferEvent && $0.slot == s.slot && $0.endpoint == 1 && at.contains($0.parameter)
      }) else {
        hc.recover(slot: s.slot, endpoint: 1, ring: s.ep0, halted: false)
        throw Status.timedOut
      }
      if e.completion == CompletionCode.shortPacket, length > 0, e.parameter == at[1] {
        residual = Int(e.status & 0xFF_FFFF)
        continue
      }
      guard e.completion == CompletionCode.success else {
        hc.recover(slot: s.slot, endpoint: 1, ring: s.ep0, halted: true)
        throw Status.io
      }
      guard e.parameter == at[at.count - 1] else { continue }
      return reads ? s.buffer.bytes(0, length - residual) : []
    }
  }

  /// A pipe's next transfer, its buffer whole.
  func queue(_ s: XHCISlot, pipe: Int) {
    guard let p = s.pipes.first(where: { $0.index == pipe }) else { return }
    p.inFlight = p.ring.push([TRB(parameter: p.buffer.bus, status: UInt32(p.length),
                                  control: TRBType.normal << 10 | 1 << 5 | 1 << 2)])[0]
    hc.ring(s.slot, p.index)
  }

  func recover(_ s: XHCISlot, pipe: Int) {
    guard let p = s.pipes.first(where: { $0.index == pipe }) else { return }
    hc.recover(slot: s.slot, endpoint: p.index, ring: p.ring, halted: true)
  }
}
