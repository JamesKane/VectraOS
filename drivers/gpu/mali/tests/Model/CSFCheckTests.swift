// SPDX-License-Identifier: BSD-3-Clause

// The CSF request/acknowledge protocol on the model checker (D173, D166's
// world shape; panthor 06 §6.3): the host's code (CSF.swift's and
// CSFHost.swift's, the same files the driver builds), the model firmware
// (ModelFirmware.swift) and the JOB interrupt's handler as interleaved
// actors over one checked region. Every access the host makes (the code
// under check) is a point where the checker may switch threads; the
// firmware, which is the model, switches at its stores, its loads running
// with the store after them. The locks' bodies and the interrupt status
// register's operations are atomic, as on the hardware. Every interleaving
// of those is explored. The states multiply with each request and event, so
// there are two small machines (theProtocolHolds, about 30 s); the broken
// variants are caught in about a minute.
//
// The machine: one CSG slot with two CS slots. The requester asks the
// firmware, ENDPOINT_CONFIG and then STATUS_UPDATE, waiting for each
// acknowledge by sleeping until the firmware's wake (an interrupt and a wait
// queue: a counter) and re-reading. The firmware serves doorbells and, at
// points of its own, raises events: SYNC_UPDATE on the CSG, then FAULT on
// CS 0, each setting the JOB status and waking the handler. The handler is
// the interrupt handler: it sleeps, clears the status, and handles what it
// finds.
//
// What must hold, in every interleaving: every request is served (each
// toggle seen by the firmware once: no request is lost, none counted twice),
// each event is handled once (none lost, none double-counted), the words end
// matched, and every thread finishes. The broken variants are each a
// deliberate wrong order or a missing lock, and the checker finds each.

import Mali
import ModelCheck
import Testing

/// The model's world: statics, because a model's threads are plain code.
enum CSFModel {
  static let config = ModelConfig(version: CSFVersion(4, 1, 0), groups: 1, streams: 2, streamStride: 0x10,
                                  workRegisters: 16, scoreboards: 4, suspendSize: 0x100, protmSuspendSize: 0x100)
  nonisolated(unsafe) static let plan = ModelFirmware(memory: ModelMemory(), config: config)
  static var layout: CSFLayout { plan.layout }
  /// The JOB interrupt's status register: a word after the interface.
  static var status: Int { (plan.interfaceEnd + 7) & ~7 }
  static var regionSize: Int { status + 8 }

  /// Counters: the doorbell, the interrupt's wake, the acknowledge's wake.
  static let doorbell = 0, wakeIrq = 1, wakeAck = 2

  nonisolated(unsafe) static var mem: UnsafeMutablePointer<UInt32>! = nil
  nonisolated(unsafe) static var locked = false
  /// A variant: no lock held (the locks are no-ops).
  nonisolated(unsafe) static var useLocks = true

  // The run's tallies.
  nonisolated(unsafe) static var requests = 2
  nonisolated(unsafe) static var events = 2
  nonisolated(unsafe) static var issued = 0
  nonisolated(unsafe) static var acked = 0
  nonisolated(unsafe) static var performed = 0
  nonisolated(unsafe) static var handled = [0, 0, 0]
  nonisolated(unsafe) static var spurious = 0
  nonisolated(unsafe) static var handledTotal = 0

  /// A shared-memory access: where threads may switch, unless a lock's
  /// body is running.
  static func gate(_ what: String) {
    if locked { return }
    Checker.step(what)
  }

  static func hardware(_ what: String, _ body: () -> Void) {
    Checker.step(what)
    body()
  }

  static func reset() {
    for i in 0..<regionSize / 4 { mem[i] = 0 }
    locked = false
    issued = 0
    acked = 0
    performed = 0
    handled = [0, 0, 0]
    spurious = 0
    handledTotal = 0
    // The firmware has booted, and the host has enabled every acknowledge's interrupt.
    let fw = ModelFirmware(memory: ModelMemory(), config: config)
    fw.boot()
    let gl = fw.layout.groups[0]
    mem[(gl.input + CSF.GroupInput.ackIrqMask) / 4] = 0xFFFF_FFFF
    for cs in gl.streams { mem[(cs.input + CSF.StreamInput.ackIrqMask) / 4] = 0xFFFF_FFFF }
  }
}

struct ModelMemory: SharedMemory {
  init() {}
  var size: Int { CSFModel.regionSize }
  func load32(_ offset: Int) -> UInt32 {
    CSFModel.gate("load")
    let v = CSFModel.mem[offset / 4]
    Checker.observe(UInt64(v))
    return v
  }
  func store32(_ offset: Int, _ value: UInt32) {
    CSFModel.gate("store")
    CSFModel.mem[offset / 4] = value
  }
  func lock(_ id: Int) {
    CSFModel.gate("lock")
    if CSFModel.useLocks { CSFModel.locked = true }
  }
  func unlock(_ id: Int) { CSFModel.locked = false }
}

/// The firmware's view: its stores are where threads may switch, its loads run
/// together with the store that follows them (the firmware is the model, and
/// the host's accesses, which are the code under check, stay one by one).
struct FirmwareMemory: SharedMemory {
  init() {}
  var size: Int { CSFModel.regionSize }
  func load32(_ offset: Int) -> UInt32 {
    let v = CSFModel.mem[offset / 4]
    Checker.observe(UInt64(v))
    return v
  }
  func store32(_ offset: Int, _ value: UInt32) {
    CSFModel.gate("firmware store")
    CSFModel.mem[offset / 4] = value
  }
}

struct ModelBell: CSFDoorbell {
  func ring(_ id: Int) { Checker.kernelAdd(CSFModel.doorbell) }
}

enum Variant: String, CaseIterable {
  case correct
  /// The handler reads the JOB status, handles it, and only then clears it: an
  /// event raised in between sets a bit already set, and the clear loses it
  /// (06 §6.3.7: clear first).
  case inspectBeforeClear = "inspects before it clears the interrupt"
  /// The handler acknowledges CSG_CS_IRQ after looking at the CS words, with
  /// the value as it then is: a CS event raised in between is acknowledged
  /// unseen (06 §6.3.7 step 2: before any CS word, with the value read).
  case lateCsIrqAck = "acknowledges CS_IRQ after looking at the CS words"
  /// The handler never copies the CSG events' ACK into REQ: the event stays
  /// pending and is handled twice (06 §6.3.2, kind 4).
  case noEventAck = "never acknowledges the CSG events"
  /// The requester's and the handler's updates of CSG_REQ are not under the
  /// lock: one's read-modify-write overwrites the other's (06 §6.3.3).
  case noLocks = "updates CSG_REQ without the lock"
  /// The requester rings the doorbell, then writes the request: the
  /// firmware looks, finds nothing, and isn't rung again (06 §6.3.6).
  case ringBeforeRequest = "rings before it writes the request"
}

/// Waits for `wait` as a driver does: read the counter, check, sleep until it
/// moves, check again.
func waitForAck(_ host: CSFHost<ModelMemory>, _ wait: AckWait) {
  while true {
    let seen = Checker.kernelLoad(CSFModel.wakeAck)
    if host.isDone(wait) { return }
    Checker.kernelWaitAbove(CSFModel.wakeAck, seen)
  }
}

func requester(_ variant: Variant) {
  let host = CSFHost(memory: ModelMemory(), layout: CSFModel.layout)
  let door = ModelBell()
  for k in 0..<CSFModel.requests {
    CSFModel.issued += 1
    let wait: AckWait
    if variant == .ringBeforeRequest {
      // The wrong order: the input, the kick, then the request word.
      if k == 0 {
        host.writeEndpoint(0, EndpointRequest(priority: 5))
        host.kickGroup(0, door)
        wait = host.csgRequest(0, toggle: CSF.GroupReq.endpointConfig)
      } else {
        host.kickGroup(0, door)
        wait = host.csgRequest(0, toggle: CSF.GroupReq.statusUpdate)
      }
    } else if k == 0 {
      wait = host.csgEndpointConfig(0, EndpointRequest(priority: 5), door)
    } else {
      wait = host.csgStatusUpdate(0, door)
    }
    waitForAck(host, wait)
    CSFModel.acked += 1
  }
}

func raise(_ fw: inout ModelFirmware<FirmwareMemory>, _ i: Int) {
  switch i {
  case 0: fw.raiseGroupEvent(0, CSF.GroupReq.syncUpdate)
  case 1: fw.raiseStreamFault(0, 0, type: 0x55, data: 7, info: 9)
  default: fw.raiseStreamFault(0, 0, type: 0x55, data: 7, info: 9)
  }
}

/// The JOB interrupt: bits the firmware raised set the status and wake the handler.
func publish(_ fw: inout ModelFirmware<FirmwareMemory>) {
  let bits = fw.takeInterrupts()
  guard bits != 0 else { return }
  CSFModel.hardware("irq raise") { CSFModel.mem[CSFModel.status / 4] |= bits }
  Checker.kernelAdd(CSFModel.wakeIrq)
}

func firmware() {
  var fw = ModelFirmware(memory: FirmwareMemory(), config: CSFModel.config)
  var next = 0
  while true {
    let seen = Checker.kernelLoad(CSFModel.doorbell)
    if next < CSFModel.events {
      raise(&fw, next)
      next += 1
      publish(&fw)
    }
    let before = fw.performed
    fw.step(scanGlobal: false)
    publish(&fw)
    if fw.performed != before { Checker.kernelAdd(CSFModel.wakeAck) }
    if fw.performed == CSFModel.requests {
      // The host asks no more: the rest of the events.
      while next < CSFModel.events {
        raise(&fw, next)
        next += 1
        publish(&fw)
      }
      CSFModel.performed = fw.performed
      return
    }
    Checker.kernelWaitAbove(CSFModel.doorbell, seen)
  }
}

func tally(slot: Int, events: UInt32) {
  if slot == 0 && events == CSF.StreamReq.fault {
    CSFModel.handled[1] += 1
  } else if slot == 1 && events == CSF.StreamReq.fatal {
    CSFModel.handled[2] += 1
  } else {
    CSFModel.spurious += 1
  }
  CSFModel.handledTotal += 1
}

func tallySync(_ events: UInt32) {
  if events == CSF.GroupReq.syncUpdate {
    CSFModel.handled[0] += 1
    CSFModel.handledTotal += 1
  } else if events != 0 {
    CSFModel.spurious += 1
  }
}

/// The handler of variants that write the interrupt's steps by hand: the
/// library's csgInterrupt with one step moved or missing.
func manualInterrupt(_ host: CSFHost<ModelMemory>, _ door: ModelBell, lateCsIrqAck: Bool, noEventAck: Bool) {
  let m = host.memory
  let gl = host.layout.groups[0]
  let req = m.load32(gl.input + CSF.GroupInput.req)
  let ack = m.load32(gl.output + CSF.GroupOutput.ack)
  let irqReq = m.load32(gl.output + CSF.GroupOutput.csIrqReq)
  let irqAck = m.load32(gl.input + CSF.GroupInput.csIrqAck)
  let events = ReqAck.pending(req: req, ack: ack, mask: CSF.GroupReq.events)
  let streams = ReqAck.pending(req: irqReq, ack: irqAck, mask: 0b11)
  if events == 0 && streams == 0 { return }
  if !lateCsIrqAck { m.store32(gl.input + CSF.GroupInput.csIrqAck, irqReq) }
  if events != 0 {
    tallySync(events)
    if !noEventAck { host.csgAcknowledge(0) }
  }
  for s in 0..<2 where streams & 1 << UInt32(s) != 0 {
    let cs = host.csEvents(0, s)
    guard cs != 0 else { continue }
    tally(slot: s, events: cs)
    host.csAcknowledge(0, s, cs)
  }
  if lateCsIrqAck { m.store32(gl.input + CSF.GroupInput.csIrqAck, m.load32(gl.output + CSF.GroupOutput.csIrqReq)) }
  host.kickGroup(0, door)
}

func handler(_ variant: Variant) {
  let host = CSFHost(memory: ModelMemory(), layout: CSFModel.layout)
  let door = ModelBell()
  var seen: Int64 = 0
  while CSFModel.handledTotal < CSFModel.events {
    Checker.kernelWaitAbove(CSFModel.wakeIrq, seen)
    // The counter first, then the status: a raise after the read wakes us again.
    seen = Checker.kernelLoad(CSFModel.wakeIrq)
    var status: UInt32 = 0
    CSFModel.hardware("irq read") { status = CSFModel.mem[CSFModel.status / 4] }
    Checker.observe(UInt64(status))
    if variant != .inspectBeforeClear {
      CSFModel.hardware("irq clear") { CSFModel.mem[CSFModel.status / 4] &= ~status }
    }
    if status & 1 != 0 {
      switch variant {
      case .lateCsIrqAck: manualInterrupt(host, door, lateCsIrqAck: true, noEventAck: false)
      case .noEventAck: manualInterrupt(host, door, lateCsIrqAck: false, noEventAck: true)
      default:
        let r = host.csgInterrupt(0, door) { slot, events in
          tally(slot: slot, events: events)
          return events
        }
        tallySync(r.events)
      }
    }
    if variant == .inspectBeforeClear {
      CSFModel.hardware("irq clear") { CSFModel.mem[CSFModel.status / 4] &= ~status }
    }
  }
}

func finalCheck(_ done: [Bool]) -> String? {
  if !done.allSatisfy({ $0 }) { return "a thread didn't finish (a request or an event was lost)" }
  if CSFModel.acked != CSFModel.requests { return "\(CSFModel.acked) of \(CSFModel.requests) requests were acknowledged" }
  if CSFModel.performed != CSFModel.issued {
    return "the firmware did \(CSFModel.performed) requests, the host made \(CSFModel.issued)"
  }
  if CSFModel.handled != [CSFModel.events >= 1 ? 1 : 0, CSFModel.events >= 2 ? 1 : 0, 0] { return "events handled \(CSFModel.handled), each should be once" }
  if CSFModel.spurious != 0 { return "\(CSFModel.spurious) events the model never raised" }
  let m = ModelMemory()
  let gl = CSFModel.layout.groups[0]
  let host = CSFHost(memory: m, layout: CSFModel.layout)
  let hostBits = CSF.GroupReq.hostBits | CSF.GroupReq.events
  if ReqAck.pending(req: host.csgReq(0), ack: host.csgAck(0), mask: hostBits) != 0 { return "CSG_REQ and CSG_ACK end apart" }
  for s in 0..<2 where host.csEvents(0, s) != 0 { return "CS \(s) ends with an event unacknowledged" }
  if m.load32(gl.input + CSF.GroupInput.csIrqAck) != m.load32(gl.output + CSF.GroupOutput.csIrqReq) {
    return "CSG_CS_IRQ_ACK ends behind CSG_CS_IRQ_REQ"
  }
  return nil
}

@Suite(.serialized)
struct CSFCheckTests {
  static func check(_ variant: Variant, requests: Int = 1, events: Int = 2) -> Checker.Result {
    CSFModel.requests = requests
    CSFModel.events = events
    let region = UnsafeMutableRawBufferPointer.allocate(byteCount: CSFModel.regionSize, alignment: 8)
    defer { region.deallocate() }
    CSFModel.mem = region.baseAddress!.assumingMemoryBound(to: UInt32.self)
    CSFModel.useLocks = variant != .noLocks
    defer { CSFModel.useLocks = true }
    var model = Checker.Model(
      name: "CSF request/acknowledge, " + variant.rawValue, regions: [region], counters: 3,
      reset: { CSFModel.reset() },
      threads: [{ requester(variant) }, { firmware() }, { handler(variant) }],
      final: { done, _ in finalCheck(done) })
    model.maxDepth = 4000
    return Checker.check(model)
  }

  /// The protocol as the library writes it: no request lost, no event lost
  /// or counted twice, in every interleaving. The machine is kept small (the
  /// states multiply with each request and event): one request against two
  /// events, where the handler and the requester both write CSG_REQ; and
  /// two requests one after the other, where the toggles must invert again.
  @Test(arguments: [(1, 2), (2, 0)])
  func theProtocolHolds(_ requests: Int, _ events: Int) {
    let result = Self.check(.correct, requests: requests, events: events)
    #expect(result.ok, "\(result.failure ?? "")")
    #expect(result.finals > 0)
    print("csf check: \(requests) requests, \(events) events: \(result.states) states, \(result.executions) runs, "
          + "\(result.finals) ends")
  }

  /// Each wrong order or missing lock: the checker finds it.
  @Test(arguments: Variant.allCases.filter { $0 != .correct })
  func brokenVariantsAreCaught(_ variant: Variant) {
    let result = Self.check(variant)
    #expect(!result.ok, "a requester or a handler that \(variant.rawValue) should fail")
    if let failure = result.failure { print("csf check: \(variant.rawValue), as expected: \(failure.prefix(160))") }
  }
}
