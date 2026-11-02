// SPDX-License-Identifier: BSD-3-Clause

// An EHCI host controller (Enhanced Host Controller Interface 1.0) as the
// USB bus's host (drivers/usb/bus). It is halted and reset (§2.3.1),
// given a periodic frame list and an asynchronous schedule's one queue
// head (§4.8, §4.10), and run, its ports routed to it (CONFIGFLAG) and
// powered.
//
// A control transfer runs on the asynchronous schedule: its one queue
// head, the reclamation list's head, is set up for the device and
// endpoint 0 with the asynchronous schedule stopped, given the setup,
// data and status stages as three transfer descriptors (qTDs), and the
// schedule started; the status stage's descriptor is waited for (2 s),
// and the schedule stopped. One thread runs the bus, so one transfer at
// a time.
//
// An interrupt IN endpoint is a queue head of its own on the periodic
// schedule, which every frame's entry reaches (each endpoint polled
// every frame, more often than its interval asks), its two descriptors
// used in turn: the one the queue head will fetch next is filled and
// made active, the other left as the inactive one it points on to.
//
// A ChipIdea (TDI) controller, the SpacemiT K1's, is put in host mode
// (USBMODE), and its root ports have a transaction translator of their
// own: a full- or low-speed device on one is reached by split
// transactions through hub address 0, its root port the translator's
// port, and its speed read from PORTSC. Elsewhere such a device belongs
// to a companion controller, which this driver doesn't drive.
//
// Everything the controller reads or writes is in pages below 4 GiB (the
// driver's record narrows its DMA to 32 bits), each structure's 64-bit
// form's upper words left zero.

import CroiMMIO
import DriverHost
import Sys

enum EHCI {
  // Capability registers.
  static let hcsParams = 0x04, hccParams = 0x08
  // Operational registers, from CAPLENGTH.
  static let command = 0x00, status = 0x04, interruptEnable = 0x08, frameIndex = 0x0C, segment = 0x10
  static let periodicBase = 0x14, asyncAddress = 0x18, configFlag = 0x40, ports = 0x44
  /// A ChipIdea controller's USBMODE: CM 3 is a host.
  static let usbMode = 0x68

  enum Command {
    static let run: UInt32 = 1 << 0, reset: UInt32 = 1 << 1, periodic: UInt32 = 1 << 4, async: UInt32 = 1 << 5
  }
  enum Status {
    static let interrupt: UInt32 = 1 << 0, error: UInt32 = 1 << 1, portChange: UInt32 = 1 << 2
    static let systemError: UInt32 = 1 << 4, halted: UInt32 = 1 << 12
    static let periodicRunning: UInt32 = 1 << 14, asyncRunning: UInt32 = 1 << 15
    static let acknowledged: UInt32 = 0x3F
  }
  enum Port {
    static let connected: UInt32 = 1 << 0, connectChange: UInt32 = 1 << 1, enabled: UInt32 = 1 << 2
    static let enableChange: UInt32 = 1 << 3, overCurrentChange: UInt32 = 1 << 5, reset: UInt32 = 1 << 8
    static let power: UInt32 = 1 << 12
    /// Written 1 to clear.
    static let changes: UInt32 = connectChange | enableChange | overCurrentChange
  }
  /// A queue head's and a qTD's words (§3.5, §3.6).
  enum Token {
    static let active: UInt32 = 1 << 7, halted: UInt32 = 1 << 6
    /// Data buffer, babble, transaction and missed microframe errors.
    static let errors: UInt32 = 0x3C
    static let out: UInt32 = 0 << 8, in_: UInt32 = 1 << 8, setup: UInt32 = 2 << 8
    static let threeErrors: UInt32 = 3 << 10, ioc: UInt32 = 1 << 15, toggle: UInt32 = 1 << 31
  }
  /// A link pointer's: terminate, and a queue head's type.
  static let terminate: UInt32 = 1, queueHead: UInt32 = 1 << 1
}

/// A device: its address and how its packets reach it.
final class EHCISlot {
  let address: Int
  let speed: Speed
  let placement: Placement
  var packetSize0: Int
  var pipes: [EHCIPipe] = []

  init(address: Int, speed: Speed, placement: Placement, packetSize0: Int) {
    self.address = address
    self.speed = speed
    self.placement = placement
    self.packetSize0 = packetSize0
  }

  /// The speed as a queue head's EPS: 0 full, 1 low, 2 high.
  var eps: UInt32 { speed == .low ? 1 : speed == .high ? 2 : 0 }

  /// The transaction translator a full- or low-speed device's split
  /// transactions go through: its hub's address and port, address 0 and
  /// the root port for a ChipIdea root port's own.
  var translator: (hub: UInt32, port: UInt32) {
    guard speed == .low || speed == .full else { return (0, 0) }
    return placement.ttSlot != 0 ? (UInt32(placement.ttSlot), UInt32(placement.ttPort)) : (0, UInt32(placement.rootPort))
  }
}

/// An interrupt IN endpoint: a page with its queue head (at 0) and its two
/// descriptors (at 0x100 and 0x200), and the page its reports land in.
final class EHCIPipe {
  /// Its endpoint's number: the pipe's id.
  let number: Int
  let page: Page, buffer: Page
  let length: Int
  /// The descriptor to fill next, and the one in flight.
  var next = 0x100
  var inFlight: Int?

  init(number: Int, page: Page, buffer: Page, length: Int) {
    self.number = number
    self.page = page
    self.buffer = buffer
    self.length = length
  }
}

final class EHCIHost: USBHost {
  let regs: Registers
  let op: Int
  let pages: Pages
  let interrupt: InterruptPort
  let ports: Int, version: UInt16
  /// A ChipIdea controller: host mode set, root ports with a translator.
  let tdi: Bool
  /// The frame list, and the control transfers' page: the asynchronous
  /// queue head at 0, the descriptors at 0x100, 0x140 and 0x180, the setup
  /// packet at 0x200; and their data.
  let frames: Page, control: Page, data: Page
  var slots: [EHCISlot] = []
  /// The periodic schedule's queue heads, first first.
  var periodic: [EHCIPipe] = []
  var interrupts = 0
  var lastDetail: String?

  init(_ regs: consuming Registers, memory: DMAMemory, interrupt: consuming InterruptPort, tdi: Bool) throws(Status) {
    let first = regs.load32(0)
    let op = Int(first & 0xFF)
    let hcs = regs.load32(EHCI.hcsParams), hcc = regs.load32(EHCI.hccParams)
    let pages = Pages(memory)

    // Halted, then reset (§2.3.1). A ChipIdea controller not in host mode
    // (idle, or a device) never says it is halted: it is only reset.
    let host = !tdi || regs.load32(op + EHCI.usbMode) & 3 == 3
    if host, regs.load32(op + EHCI.status) & EHCI.Status.halted == 0 {
      regs.store32(op + EHCI.command, regs.load32(op + EHCI.command) & ~EHCI.Command.run)
      guard pollFor(100, { regs.load32(op + EHCI.status) & EHCI.Status.halted != 0 }) else {
        throw EHCIHost.fail("halt", regs.load32(op + EHCI.command), regs.load32(op + EHCI.status))
      }
    }
    regs.store32(op + EHCI.command, EHCI.Command.reset)
    guard pollFor(250, { regs.load32(op + EHCI.command) & EHCI.Command.reset == 0 }) else {
      throw EHCIHost.fail("reset", regs.load32(op + EHCI.command), regs.load32(op + EHCI.status))
    }
    if tdi { regs.store32(op + EHCI.usbMode, regs.load32(op + EHCI.usbMode) & ~3 | 3) }

    let frames = try pages.take(), control = try pages.take(), data = try pages.take()
    for i in 0..<1024 { frames.store32(4 * i, EHCI.terminate) }
    // The asynchronous schedule's head, linked to itself, idle.
    control.store32(0, UInt32(control.bus) | EHCI.queueHead)
    control.store32(4, 1 << 15)
    control.store32(0x10, EHCI.terminate)
    control.store32(0x14, EHCI.terminate)
    croi_dma_barrier()
    if hcc & 1 != 0 { regs.store32(op + EHCI.segment, 0) }
    regs.store32(op + EHCI.periodicBase, UInt32(frames.bus))
    regs.store32(op + EHCI.asyncAddress, UInt32(control.bus))
    regs.store32(op + EHCI.interruptEnable, EHCI.Status.interrupt | EHCI.Status.error | EHCI.Status.portChange
      | EHCI.Status.systemError)
    // Run, the periodic schedule on, an interrupt at most every 1 ms.
    regs.store32(op + EHCI.command, EHCI.Command.run | EHCI.Command.periodic | 8 << 16)
    guard pollFor(100, { regs.load32(op + EHCI.status) & EHCI.Status.halted == 0 }) else {
      throw EHCIHost.fail("run", regs.load32(op + EHCI.command), regs.load32(op + EHCI.status))
    }
    regs.store32(op + EHCI.configFlag, 1)

    (self.op, self.pages, self.tdi) = (op, pages, tdi)
    (self.frames, self.control, self.data) = (frames, control, data)
    ports = Int(hcs & 0xF)
    version = UInt16(first >> 16)
    self.interrupt = interrupt
    self.regs = regs
    // Every port powered, where the controller switches their power.
    if hcs & 1 << 4 != 0 {
      for p in 1...max(ports, 1) where ports > 0 {
        let v = portStatus(p)
        self.regs.store32(portRegister(p), v & ~(EHCI.Port.changes | EHCI.Port.enabled) | EHCI.Port.power)
      }
      sleep(until: Clock.monotonic() + 20_000_000)
    }
  }

  /// Why setting it up failed: the step, USBCMD and USBSTS.
  nonisolated(unsafe) static var failure = ""

  static func fail(_ step: String, _ command: UInt32, _ status: UInt32) -> Status {
    failure = "\(step) timed out (USBCMD 0x\(String(command, radix: 16)), USBSTS 0x\(String(status, radix: 16)))"
    return Status.timedOut
  }

  var description: String {
    "EHCI \(version >> 8).\(String(version & 0xFF, radix: 16)), \(ports) ports" + (tdi ? ", ChipIdea host" : "")
  }

  // MARK: Ports

  var rootPorts: Int { ports }

  func portRegister(_ port: Int) -> Int { op + EHCI.ports + 4 * (port - 1) }
  func portStatus(_ port: Int) -> UInt32 { regs.load32(portRegister(port)) }

  /// `root port 1: USB 2, connected, enabled`.
  func rootPortLine(_ port: Int) -> String {
    let v = portStatus(port)
    return "root port \(port): USB 2, " + (v & EHCI.Port.connected != 0 ? "connected" : "empty") + ", "
      + (v & EHCI.Port.enabled != 0 ? "enabled" : "disabled")
  }

  func rootConnected(_ port: Int) -> Bool {
    let v = portStatus(port)
    // PE written as read: a 0 would disable the port.
    if v & EHCI.Port.changes != 0 { regs.store32(portRegister(port), v & ~EHCI.Port.reset) }
    return portStatus(port) & EHCI.Port.connected != 0
  }

  /// A root port reset (50 ms, §4.2.2) and enabled: its device's speed.
  /// Elsewhere than a ChipIdea's, a low-speed device (the K state) or one
  /// left disabled after the reset (full speed) is a companion's: nil.
  func enable(port: Int) -> Speed? {
    var v = portStatus(port)
    guard v & EHCI.Port.connected != 0 else { return nil }
    if !tdi, (v >> 10) & 3 == 1 { return nil }
    regs.store32(portRegister(port), v & ~(EHCI.Port.changes | EHCI.Port.enabled) | EHCI.Port.reset)
    sleep(until: Clock.monotonic() + 50_000_000)
    regs.store32(portRegister(port), portStatus(port) & ~(EHCI.Port.changes | EHCI.Port.reset))
    _ = pollFor(2) { self.portStatus(port) & EHCI.Port.reset == 0 }
    v = portStatus(port)
    guard v & EHCI.Port.enabled != 0 else { return nil }
    sleep(until: Clock.monotonic() + 10_000_000)  // TRSTRCY
    guard tdi else { return .high }
    switch (v >> 26) & 3 {
    case 1: return .low
    case 2: return .high
    default: return .full
    }
  }

  // MARK: Events

  /// What the interrupt said: each root port whose connection changed,
  /// and each interrupt endpoint's descriptor the controller retired.
  func events(until deadline: Int64) -> [HostEvent] {
    if (try? interrupt.wait(deadline: deadline)) != nil { interrupts += 1 }
    let s = regs.load32(op + EHCI.status)
    regs.store32(op + EHCI.status, s & EHCI.Status.acknowledged)
    try? interrupt.ack()
    if s & EHCI.Status.systemError != 0 { print("ehci: host system error (USBSTS 0x\(String(s, radix: 16)))") }
    var out: [HostEvent] = []
    for p in 1...max(ports, 1) where ports > 0 && portStatus(p) & EHCI.Port.connectChange != 0 { out.append(.port(p)) }
    for slot in slots {
      for pipe in slot.pipes {
        guard let at = pipe.inFlight else { continue }
        let token = pipe.page.load32(at + 8)
        guard token & EHCI.Token.active == 0 else { continue }
        pipe.inFlight = nil
        if token & (EHCI.Token.halted | EHCI.Token.errors) != 0 {
          out.append(.transfer(device: slot.address, pipe: pipe.number, report: nil, code: token & 0xFF))
        } else {
          let read = max(pipe.length - Int((token >> 16) & 0x7FFF), 0)
          out.append(.transfer(device: slot.address, pipe: pipe.number, report: pipe.buffer.bytes(0, read), code: 0))
        }
      }
    }
    return out
  }

  // MARK: Devices

  /// An address of its own (1 to 127), given by SET_ADDRESS to address 0.
  func address(speed: Speed, placement: Placement, packetSize0: Int) throws(Status) -> EHCISlot {
    lastDetail = nil
    guard let address = (1...127).first(where: { a in !slots.contains { $0.address == a } }) else {
      throw Status.noResources
    }
    let fresh = EHCISlot(address: 0, speed: speed, placement: placement, packetSize0: packetSize0)
    _ = try control(fresh, SetupPacket(requestType: 0, request: 5, value: UInt16(address)))
    sleep(until: Clock.monotonic() + 2_000_000)  // SET_ADDRESS's recovery
    let s = EHCISlot(address: address, speed: speed, placement: placement, packetSize0: packetSize0)
    slots.append(s)
    return s
  }

  func number(_ s: EHCISlot) -> Int { s.address }

  func setPacketSize0(_ s: EHCISlot, _ size: Int) throws(Status) { s.packetSize0 = size }

  func release(_ s: EHCISlot) {
    slots.removeAll { $0 === s }
    guard !s.pipes.isEmpty else { return }
    for p in s.pipes {
      guard let i = periodic.firstIndex(where: { $0 === p }) else { continue }
      let after = p.page.load32(0)
      if i == 0 {
        for f in 0..<1024 { frames.store32(4 * f, after) }
      } else {
        periodic[i - 1].page.store32(0, after)
      }
      periodic.remove(at: i)
    }
    croi_dma_barrier()
    // The controller may be on them for a frame yet.
    sleep(until: Clock.monotonic() + 3_000_000)
    for p in s.pipes {
      pages.give(p.page)
      pages.give(p.buffer)
    }
    s.pipes = []
  }

  // MARK: Transfers

  /// A qTD at `at` in `page`: its next, the stage's PID and toggle, its
  /// length, its buffer.
  func descriptor(_ page: Page, _ at: Int, next: UInt32, pid: UInt32, toggle: Bool, length: Int, buffer: UInt64,
                  ioc: Bool = false) {
    page.store32(at, next)
    page.store32(at + 4, EHCI.terminate)
    page.store32(at + 12, UInt32(truncatingIfNeeded: buffer))
    page.store32(at + 16, UInt32(truncatingIfNeeded: buffer &+ 4096) & ~0xFFF)
    croi_dma_barrier()
    page.store32(at + 8, (toggle ? EHCI.Token.toggle : 0) | UInt32(length) << 16 | (ioc ? EHCI.Token.ioc : 0)
      | EHCI.Token.threeErrors | pid | EHCI.Token.active)
  }

  func asynchronous(_ on: Bool) {
    let c = regs.load32(op + EHCI.command)
    regs.store32(op + EHCI.command, on ? c | EHCI.Command.async : c & ~EHCI.Command.async)
    _ = pollFor(10) { (self.regs.load32(self.op + EHCI.status) & EHCI.Status.asyncRunning != 0) == on }
  }

  /// A control transfer on endpoint 0, waited for (2 s): what its data
  /// stage read. Requests with data the host sends aren't made.
  func control(_ s: EHCISlot, _ setup: SetupPacket) throws(Status) -> [UInt8] {
    let length = Int(min(setup.length, 4096))
    let reads = length > 0 && setup.deviceToHost
    let base = UInt32(control.bus)
    asynchronous(false)
    let tt = s.translator
    let lowOrFull = s.speed != .high
    control.store32(4, UInt32(s.address) | s.eps << 12 | 1 << 14 | 1 << 15 | UInt32(s.packetSize0) << 16
      | (lowOrFull ? 1 << 27 : 0))
    control.store32(8, 1 << 30 | tt.port << 23 | tt.hub << 16)
    control.store32(0x0C, 0)
    control.store32(0x10, base + 0x100)
    control.store32(0x14, EHCI.terminate)
    control.store32(0x18, 0)
    control.store64(0x200, setup.word)
    descriptor(control, 0x180, next: EHCI.terminate, pid: reads ? EHCI.Token.out : EHCI.Token.in_, toggle: true,
               length: 0, buffer: 0)
    if length > 0 {
      descriptor(control, 0x140, next: base + 0x180, pid: reads ? EHCI.Token.in_ : EHCI.Token.out, toggle: true,
                 length: length, buffer: data.bus)
    }
    descriptor(control, 0x100, next: base + (length > 0 ? 0x140 : 0x180), pid: EHCI.Token.setup, toggle: false,
               length: 8, buffer: control.bus + 0x200)
    asynchronous(true)
    let stages = length > 0 ? [0x100, 0x140, 0x180] : [0x100, 0x180]
    let done = pollFor(2_000) {
      let tokens = stages.map { self.control.load32($0 + 8) }
      return tokens.last.map { $0 & EHCI.Token.active == 0 } == true
        || tokens.contains { $0 & EHCI.Token.halted != 0 }
    }
    asynchronous(false)
    let tokens = stages.map { control.load32($0 + 8) }
    guard done else {
      lastDetail = "token 0x\(String(tokens.last ?? 0, radix: 16))"
      throw Status.timedOut
    }
    if let bad = tokens.first(where: { $0 & (EHCI.Token.halted | EHCI.Token.errors) != 0 }) {
      lastDetail = "token 0x\(String(bad, radix: 16))"
      throw Status.io
    }
    guard reads else { return [] }
    return data.bytes(0, max(length - Int((tokens[1] >> 16) & 0x7FFF), 0))
  }

  /// Each endpoint a queue head on the periodic schedule, first in it:
  /// for a full- or low-speed device a split transaction's start in
  /// microframe 0 and its completes in 2 to 4, else microframe 0.
  func open(_ s: EHCISlot, _ endpoints: [Endpoint], hub: (ports: Int, thinkTime: UInt32)?) throws(Status) -> [Int] {
    let tt = s.translator
    var ids: [Int] = []
    for e in endpoints {
      let p = EHCIPipe(number: e.number, page: try pages.take(), buffer: try pages.take(),
                       length: min(e.maxPacket, 4096))
      let split: UInt32 = s.speed == .high ? 0x01 : 0x1C << 8 | 0x01
      p.page.store32(0, periodic.first.map { UInt32($0.page.bus) | EHCI.queueHead } ?? EHCI.terminate)
      p.page.store32(4, UInt32(s.address) | UInt32(e.number) << 8 | s.eps << 12 | UInt32(e.maxPacket) << 16)
      p.page.store32(8, 1 << 30 | tt.port << 23 | tt.hub << 16 | split)
      p.page.store32(0x10, UInt32(p.page.bus) + 0x100)
      p.page.store32(0x14, EHCI.terminate)
      p.page.store32(0x18, 0)
      croi_dma_barrier()
      let link = UInt32(p.page.bus) | EHCI.queueHead
      for f in 0..<1024 { frames.store32(4 * f, link) }
      periodic.insert(p, at: 0)
      s.pipes.append(p)
      ids.append(p.number)
    }
    return ids
  }

  /// The pipe's next descriptor filled and made active, pointing on to the
  /// other, inactive.
  func queue(_ s: EHCISlot, pipe: Int) {
    guard let p = s.pipes.first(where: { $0.number == pipe }) else { return }
    let at = p.next, other = at == 0x100 ? 0x200 : 0x100
    p.page.store32(other + 8, 0)
    p.page.store32(other, EHCI.terminate)
    p.page.store32(other + 4, EHCI.terminate)
    descriptor(p.page, at, next: UInt32(p.page.bus) + UInt32(other), pid: EHCI.Token.in_, toggle: false,
               length: p.length, buffer: p.buffer.bus, ioc: true)
    p.next = other
    p.inFlight = at
  }

  /// A halted queue head going again: its overlay cleared, pointing at
  /// the descriptor to fill next.
  func recover(_ s: EHCISlot, pipe: Int) {
    guard let p = s.pipes.first(where: { $0.number == pipe }) else { return }
    p.page.store32(0x0C, 0)
    p.page.store32(0x10, UInt32(p.page.bus) + UInt32(p.next))
    croi_dma_barrier()
    p.page.store32(0x18, 0)
  }
}
