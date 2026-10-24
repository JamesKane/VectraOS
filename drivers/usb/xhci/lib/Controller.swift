// SPDX-License-Identifier: BSD-3-Clause

// An xHCI host controller (eXtensible Host Controller Interface 1.2): its
// registers, the rings it shares with this driver, device contexts, and
// commands. It is taken from firmware (the legacy handoff, §4.22.1),
// halted and reset (§4.2), given a slot table with its scratchpad pages, a
// command ring and one event ring on interrupter 0, and run. Everything it
// reads or writes is in 4 KiB pages through the BTI (`Pages`), mapped
// write-combining when its DMA isn't coherent: a TRB's cycle bit, the
// word that hands it over, is written after the rest of it, a barrier
// between (croi_dma_barrier), and a doorbell after another.
//
// One thread drives it (Bus.swift): a command or a control transfer is
// waited for by reading events until its own arrives, keeping the rest
// (`pending`) for the bus to handle after.

import CroiMMIO
import DriverHost
import Sys

/// A Transfer Request Block (§4.11): a command, a transfer or an event.
struct TRB {
  var parameter: UInt64 = 0
  var status: UInt32 = 0
  var control: UInt32 = 0

  var type: UInt32 { (control >> 10) & 0x3F }
  /// An event's completion code (§6.4.5).
  var completion: UInt32 { status >> 24 }
  var slot: Int { Int(control >> 24) }
  var endpoint: Int { Int((control >> 16) & 0x1F) }
}

enum TRBType {
  static let normal: UInt32 = 1, setup: UInt32 = 2, data: UInt32 = 3, status: UInt32 = 4, link: UInt32 = 6
  static let enableSlot: UInt32 = 9, disableSlot: UInt32 = 10, addressDevice: UInt32 = 11
  static let configureEndpoint: UInt32 = 12, evaluateContext: UInt32 = 13, resetEndpoint: UInt32 = 14
  static let stopEndpoint: UInt32 = 15, setDequeue: UInt32 = 16
  static let transferEvent: UInt32 = 32, commandCompletion: UInt32 = 33, portStatusChange: UInt32 = 34
}

enum CompletionCode {
  static let success: UInt32 = 1, stall: UInt32 = 6, shortPacket: UInt32 = 13
}

/// A page the controller reaches: its address here and the controller's.
struct Page {
  let address: UInt
  let bus: UInt64

  func load32(_ o: Int) -> UInt32 { unsafe UnsafeRawPointer(bitPattern: address + UInt(o))!.load(as: UInt32.self) }
  func load64(_ o: Int) -> UInt64 { unsafe UnsafeRawPointer(bitPattern: address + UInt(o))!.load(as: UInt64.self) }
  func store32(_ o: Int, _ v: UInt32) {
    unsafe UnsafeMutableRawPointer(bitPattern: address + UInt(o))!.storeBytes(of: v, as: UInt32.self)
  }
  func store64(_ o: Int, _ v: UInt64) {
    unsafe UnsafeMutableRawPointer(bitPattern: address + UInt(o))!.storeBytes(of: v, as: UInt64.self)
  }
  func bytes(_ o: Int, _ n: Int) -> [UInt8] {
    let p = unsafe UnsafeRawPointer(bitPattern: address + UInt(o))!
    return (0..<n).map { unsafe p.load(fromByteOffset: $0, as: UInt8.self) }
  }
  func zero() { unsafe UnsafeMutableRawPointer(bitPattern: address)!.initializeMemory(as: UInt8.self, repeating: 0, count: 4096) }
}

/// Pages handed out and taken back, so a device that leaves gives its
/// pages to the next.
final class Pages {
  let memory: DMAMemory
  var free: [Page] = []
  private(set) var count = 0

  init(_ memory: DMAMemory) { self.memory = memory }

  func take() throws(Status) -> Page {
    if let p = free.popLast() {
      p.zero()
      return p
    }
    let a = try unsafe memory.allocate(bytes: 4096)
    count += 1
    return unsafe Page(address: UInt(bitPattern: a.pointer), bus: a.bus)
  }

  func give(_ p: Page) { free.append(p) }
}

/// A ring this driver fills and the controller reads (§4.9.2): a command
/// ring or an endpoint's, one page whose last TRB links back to its first.
struct ProducerRing {
  static let count = 256
  let page: Page
  var enqueue = 0
  var cycle: UInt32 = 1

  init(_ page: Page) {
    self.page = page
    page.store64((Self.count - 1) * 16, page.bus)
    page.store32((Self.count - 1) * 16 + 12, TRBType.link << 10 | 1 << 1)  // toggle cycle; not yet the controller's
  }

  /// Where the controller reads next, with the cycle it expects.
  var dequeuePointer: UInt64 { page.bus + UInt64(enqueue * 16) | UInt64(cycle) }

  /// Writes a TD's TRBs, the first handed over last, so the controller
  /// never sees part of it; their addresses.
  mutating func push(_ trbs: [TRB]) -> [UInt64] {
    var out: [UInt64] = []
    var first = 0
    for (i, t) in trbs.enumerated() {
      let at = enqueue * 16
      if i == 0 { first = at }
      page.store64(at, t.parameter)
      page.store32(at + 8, t.status)
      // The first TRB's cycle bit is wrong until the rest are written.
      page.store32(at + 12, t.control & ~1 | (i == 0 ? cycle ^ 1 : cycle))
      out.append(page.bus + UInt64(at))
      enqueue += 1
      if enqueue == Self.count - 1 {
        page.store32(enqueue * 16 + 12, TRBType.link << 10 | 1 << 1 | cycle)
        enqueue = 0
        cycle ^= 1
      }
    }
    croi_dma_barrier()  // the rest of the TD before its first TRB's cycle bit
    let c = page.load32(first + 12)
    page.store32(first + 12, c ^ 1)
    croi_dma_barrier()  // the TD before the doorbell
    return out
  }
}

/// The event ring (§4.9.4): one segment the controller fills.
struct EventRing {
  static let count = 256
  let page: Page
  var dequeue = 0
  var cycle: UInt32 = 1

  mutating func next() -> TRB? {
    let at = dequeue * 16
    let control = page.load32(at + 12)
    guard control & 1 == cycle else { return nil }
    croi_dma_barrier()  // the event after the cycle bit that says it is new
    let t = TRB(parameter: page.load64(at), status: page.load32(at + 8), control: control)
    dequeue += 1
    if dequeue == Self.count {
      dequeue = 0
      cycle ^= 1
    }
    return t
  }

  var dequeuePointer: UInt64 { page.bus + UInt64(dequeue * 16) }
}

/// The controller.
final class Controller {
  let regs: Registers
  let pages: Pages
  let interrupt: InterruptPort
  /// The operational, runtime and doorbell registers' offsets.
  let op: Int, runtime: Int, doorbells: Int
  let contextSize: Int
  let slots: Int, ports: Int, version: UInt16
  let addresses64: Bool
  /// Each port's protocol's major revision, 2 or 3 (§7.2), by port - 1.
  var portMajor: [UInt8]
  let slotTable: Page
  var commands: ProducerRing
  var events: EventRing
  var pending: [TRB] = []
  var interrupts = 0
  var handoff = "no legacy capability"

  enum Op {
    static let command = 0x00, status = 0x04, pageSize = 0x08, crcr = 0x18, dcbaap = 0x30, config = 0x38
    static let ports = 0x400
  }
  enum Port {
    static let connected: UInt32 = 1 << 0, enabled: UInt32 = 1 << 1, reset: UInt32 = 1 << 4
    static let power: UInt32 = 1 << 9
    /// The bits written as they are (RW, RWS); the rest read-only or
    /// cleared by writing 1, which must be written 0 to keep them.
    static let preserve: UInt32 = 0x0E00_C3E0 & ~(0xF << 5)  // PP, PIC, the wake enables
    static let changes: UInt32 = 0x00FE_0000  // CSC PEC WRC OCC PRC PLC CEC
    static let resetChange: UInt32 = 1 << 21
  }

  init(_ regs: consuming Registers, memory: DMAMemory, interrupt: consuming InterruptPort) throws(Status) {
    // CAPLENGTH and HCIVERSION in one word: some controllers (QEMU's) answer
    // only 32-bit reads of their capability registers, as Linux makes them.
    let first = regs.load32(0), capLength = Int(first & 0xFF)
    let hcs1 = regs.load32(0x04), hcs2 = regs.load32(0x08), hcc1 = regs.load32(0x10)
    let op = capLength, ports = Int(hcs1 >> 24), slots = min(Int(hcs1 & 0xFF), 64)
    let runtime = Int(regs.load32(0x18) & ~0x1F)
    let pages = Pages(memory)
    var portMajor = [UInt8](repeating: 2, count: ports)

    // Its extended capabilities: the legacy handoff and each port's protocol.
    var at = Int(hcc1 >> 16) << 2, hops = 0
    var handoff = "no legacy capability"
    while at != 0, at + 12 <= regs.size, hops < 64 {
      let head = regs.load32(at)
      switch head & 0xFF {
      case 1:  // USB Legacy Support: firmware lets go of it
        regs.store32(at, head | 1 << 24)
        let released = Controller.waitFor(1_000) { regs.load32(at) & 1 << 16 == 0 }
        // Firmware's SMIs off, and their events cleared.
        regs.store32(at + 4, regs.load32(at + 4) & (0x7 << 1 | 0xFF << 5 | 0x7 << 17) | 0x7 << 29)
        handoff = released ? "firmware let go" : "firmware didn't let go in 1 s"
      case 2:  // Supported Protocol: its ports
        let major = UInt8(head >> 24), word = regs.load32(at + 8)
        let first = Int(word & 0xFF), count = Int((word >> 8) & 0xFF)
        for p in first..<(first + count) where p >= 1 && p <= ports { portMajor[p - 1] = major }
      default:
        break
      }
      let next = Int((head >> 8) & 0xFF) << 2
      at = next == 0 ? 0 : at + next
      hops += 1
    }

    // Halted, then reset (§4.22.1: firmware may have left it running).
    if regs.load32(op + Op.status) & 1 == 0 {
      regs.store32(op + Op.command, regs.load32(op + Op.command) & ~1)
      guard Controller.waitFor(1_000, { regs.load32(op + Op.status) & 1 != 0 }) else { throw Status.timedOut }
    }
    regs.store32(op + Op.command, 1 << 1)
    sleep(until: Clock.monotonic() + 1_000_000)  // some controllers want a moment before they're read
    guard Controller.waitFor(1_000, { regs.load32(op + Op.command) & 1 << 1 == 0 }),
          Controller.waitFor(1_000, { regs.load32(op + Op.status) & 1 << 11 == 0 }) else { throw Status.timedOut }
    guard regs.load32(op + Op.pageSize) & 1 != 0 else { throw Status.notSupported }  // 4 KiB pages

    // The slot table, its first entry the scratchpad pages' list.
    let slotTable = try pages.take()
    let scratchpads = Int((hcs2 >> 27) & 0x1F | ((hcs2 >> 21) & 0x1F) << 5)
    if scratchpads > 0 {
      guard scratchpads <= 512 else { throw Status.notSupported }
      let list = try pages.take()
      for i in 0..<scratchpads { list.store64(8 * i, try pages.take().bus) }
      slotTable.store64(0, list.bus)
    }
    regs.store32(op + Op.config, UInt32(slots))
    Controller.store64(regs, op + Op.dcbaap, slotTable.bus)

    let commands = ProducerRing(try pages.take())
    Controller.store64(regs, op + Op.crcr, commands.page.bus | 1)

    // Interrupter 0: one event ring segment, an interrupt at most every
    // 250 µs.
    let events = EventRing(page: try pages.take())
    let table = try pages.take()
    table.store64(0, events.page.bus)
    table.store32(8, UInt32(EventRing.count))
    let ir = runtime + 0x20
    regs.store32(ir + 0x08, 1)  // ERSTSZ
    Controller.store64(regs, ir + 0x18, events.page.bus)  // ERDP
    Controller.store64(regs, ir + 0x10, table.bus)  // ERSTBA, last
    regs.store32(ir + 0x04, 1000)
    regs.store32(ir + 0x00, 3)  // IE, IP cleared

    version = UInt16(first >> 16)
    doorbells = Int(regs.load32(0x14) & ~3)
    contextSize = hcc1 & 4 != 0 ? 64 : 32
    addresses64 = hcc1 & 1 != 0
    (self.op, self.runtime, self.ports, self.slots) = (op, runtime, ports, slots)
    (self.pages, self.portMajor, self.handoff) = (pages, portMajor, handoff)
    (self.slotTable, self.commands, self.events) = (slotTable, commands, events)
    self.interrupt = interrupt
    self.regs = regs

    self.regs.store32(op + Op.command, 1 | 1 << 2)  // run, interrupts on
    guard Controller.waitFor(1_000, { self.regs.load32(op + Op.status) & 1 == 0 }) else { throw Status.timedOut }
    // Every port powered, where the controller switches their power.
    if hcc1 & 1 << 3 != 0 {
      for p in 1...max(ports, 1) where ports > 0 {
        let v = portStatus(p)
        if v & Port.power == 0 { self.regs.store32(portRegister(p), v & Port.preserve | Port.power) }
      }
    }
  }

  /// Polls `done` for up to `ms` milliseconds.
  static func waitFor(_ ms: Int64, _ done: () -> Bool) -> Bool {
    let until = Clock.monotonic() + ms * 1_000_000
    while !done() {
      guard Clock.monotonic() < until else { return done() }
      sleep(until: Clock.monotonic() + 100_000)
    }
    return true
  }

  /// A 64-bit register, written low half first, as Linux writes them.
  static func store64(_ regs: borrowing Registers, _ o: Int, _ v: UInt64) {
    regs.store32(o, UInt32(truncatingIfNeeded: v))
    regs.store32(o + 4, UInt32(truncatingIfNeeded: v >> 32))
  }

  var description: String {
    "xHCI \(version >> 8).\(String(version & 0xFF, radix: 16)), \(ports) ports, \(slots) slots, "
      + "\(contextSize)-byte contexts\(addresses64 ? "" : ", 32-bit DMA")"
  }

  // MARK: Ports

  func portRegister(_ port: Int) -> Int { op + Op.ports + 0x10 * (port - 1) }
  func portStatus(_ port: Int) -> UInt32 { regs.load32(portRegister(port)) }

  /// Clears a root port's change bits; its status after.
  @discardableResult func clearChanges(_ port: Int) -> UInt32 {
    let v = portStatus(port)
    if v & Port.changes != 0 { regs.store32(portRegister(port), v & Port.preserve | v & Port.changes) }
    return portStatus(port)
  }

  /// A root port enabled for its device: a USB 2 port reset (§4.3.1), a
  /// USB 3 port waited for, which enables itself as its link trains. The
  /// device's speed, or nil.
  func enable(port: Int) -> Speed? {
    if portMajor[port - 1] < 3 {
      let v = portStatus(port)
      regs.store32(portRegister(port), v & Port.preserve | Port.reset)
      guard Controller.waitFor(500, { self.portStatus(port) & Port.resetChange != 0 }) else { return nil }
      sleep(until: Clock.monotonic() + 10_000_000)  // TRSTRCY
    } else {
      _ = Controller.waitFor(500) { self.portStatus(port) & Port.enabled != 0 }
    }
    let v = clearChanges(port)
    guard v & Port.connected != 0, v & Port.enabled != 0 else { return nil }
    return Speed(rawValue: UInt8((v >> 10) & 0xF))
  }

  // MARK: Events

  /// The events posted since the last call; the interrupt's source
  /// cleared first, so one posted meanwhile raises it again.
  func drain() -> [TRB] {
    let ir = runtime + 0x20
    regs.store32(op + Op.status, 1 << 3)  // EINT
    regs.store32(ir, 3)  // IP, keeping IE
    var out: [TRB] = []
    while let e = events.next() { out.append(e) }
    Controller.store64(regs, ir + 0x18, events.dequeuePointer | 1 << 3)  // EHB cleared
    return out
  }

  /// Waits for the interrupt, until `deadline`; the events.
  func waitForEvents(until deadline: Int64) -> [TRB] {
    if (try? interrupt.wait(deadline: deadline)) != nil { interrupts += 1 }
    let out = drain()
    try? interrupt.ack()
    return out
  }

  /// The first event `match` takes, others kept in `pending`; nil at
  /// `deadline`.
  func wait(until deadline: Int64, _ match: (TRB) -> Bool) -> TRB? {
    if let i = pending.firstIndex(where: match) { return pending.remove(at: i) }
    while true {
      var found: TRB?
      for e in drain() {
        if found == nil, match(e) { found = e } else { pending.append(e) }
      }
      if let found { return found }
      guard Clock.monotonic() < deadline else { return nil }
      if (try? interrupt.wait(deadline: deadline)) != nil { interrupts += 1 }
      try? interrupt.ack()
    }
  }

  // MARK: Commands

  func ring(_ slot: Int, _ target: Int) { regs.store32(doorbells + 4 * slot, UInt32(target)) }

  /// A command, waited for (5 s): its completion event.
  @discardableResult func command(_ type: UInt32, slot: Int = 0, endpoint: Int = 0, parameter: UInt64 = 0,
                                  flags: UInt32 = 0) throws(Status) -> TRB {
    let at = commands.push([TRB(parameter: parameter,
                                control: type << 10 | UInt32(slot) << 24 | UInt32(endpoint) << 16 | flags)])[0]
    ring(0, 0)
    guard let e = wait(until: Clock.monotonic() + 5_000_000_000, {
      $0.type == TRBType.commandCompletion && $0.parameter == at
    }) else { throw Status.timedOut }
    guard e.completion == CompletionCode.success else { throw Status.io }
    return e
  }

  /// An endpoint a failed or stalled transfer halted, running again with
  /// its ring's next TRB first.
  func recover(slot: Int, endpoint: Int, ring r: ProducerRing, halted: Bool) {
    if halted {
      _ = try? command(TRBType.resetEndpoint, slot: slot, endpoint: endpoint)
    } else {
      _ = try? command(TRBType.stopEndpoint, slot: slot, endpoint: endpoint)
    }
    _ = try? command(TRBType.setDequeue, slot: slot, endpoint: endpoint, parameter: r.dequeuePointer)
  }

  // MARK: Contexts

  /// Slot `slot`'s output context, the controller's (§6.2.1).
  func setDeviceContext(_ slot: Int, _ page: Page?) {
    slotTable.store64(8 * slot, page?.bus ?? 0)
  }
}
