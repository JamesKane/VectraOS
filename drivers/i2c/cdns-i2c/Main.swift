// SPDX-License-Identifier: BSD-3-Clause

// bin/cdns-i2c (cdns-i2c(3)): a CIX Sky1 I2C controller (Cadence r1p14,
// ACPI CIXH200B), its bus served to the devices on it (D158). devmgr
// grants its registers and mounts this tree at /dev/provider/SERVICE in
// the driver of each device on the bus:
//   bus     vectraos.i2c's Bus: transfer, one at a time, polled through
//           the controller's FIFOs (CdnsI2C.swift), at the device's
//           `clock-frequency` (/dev/acpi/properties), else 100 kHz
//   status  how it was brought up, the bus's rate and the input clock
//           it was made from, the transfers done and failed, the last
//           failure with the controller's registers
// Bring-up: its power resource on (/dev/acpi/power), its clock on and its
// rate asked for (/dev/scmi, by CLKT's id in /dev/acpi/clocks). Its reset
// is taken as firmware left it. A failed transfer resets the controller.

import DriverHost
import I2CBus
import IPC
import Node
import Sys

final class Controller: I2CBusIPC.BusHandler, @unchecked Sendable {
  let regs: Registers
  let base: UInt32
  let rate: UInt32
  let lock = Lock()
  /// The largest chunk XFER_SIZE holds, less the margin of a re-arm.
  var largest = 0
  /// Whether the registers answered at start.
  var alive = true
  var done = 0, failed = 0
  var last = ""
  /// The registers at the last wait that gave up.
  var seen = ""

  init(_ regs: consuming Registers, dividers: CdnsI2C.Dividers) {
    self.regs = regs
    base = CdnsI2C.base(dividers)
    rate = dividers.rate
  }

  /// Masks every interrupt (the driver polls ISR), flushes the FIFOs and
  /// drops HOLD, and leaves the controller idle in host mode.
  func reset() {
    regs.store32(CdnsI2C.idr, CdnsI2C.Interrupt.all)
    regs.store32(CdnsI2C.cr, base | CdnsI2C.Control.clearFIFO)
    regs.store32(CdnsI2C.transferSize, 0)
    regs.store32(CdnsI2C.isr, regs.load32(CdnsI2C.isr))
    regs.store32(CdnsI2C.sr, regs.load32(CdnsI2C.sr))
    regs.store32(CdnsI2C.cr, base)
    regs.store32(CdnsI2C.timeOut, CdnsI2C.longestHold)
  }

  /// Probes the counter's width, sets the dividers and the hold timeout;
  /// the lines for the status.
  func start() -> [String] {
    var lines: [String] = []
    regs.store32(CdnsI2C.idr, CdnsI2C.Interrupt.all)
    regs.store32(CdnsI2C.cr, CdnsI2C.Control.host | CdnsI2C.Control.receive)
    regs.store32(CdnsI2C.transferSize, 0xFF)
    let readBack = regs.load32(CdnsI2C.transferSize)
    regs.store32(CdnsI2C.transferSize, 0)
    regs.store32(CdnsI2C.cr, 0)
    reset()
    let timeOut = regs.load32(CdnsI2C.timeOut)
    let cr = regs.load32(CdnsI2C.cr)
    largest = CdnsI2C.largestChunk(readBack: readBack)
    lines.append("counter reads back \(readBack), reads in chunks of \(largest)")
    if timeOut != CdnsI2C.longestHold || cr != base || readBack == 0 || readBack == 0xFFFF_FFFF {
      alive = false
      lines.append("NOT RESPONDING: TIME_OUT reads \(hex(timeOut)) (wrote \(hex(CdnsI2C.longestHold))), CR \(hex(cr)) "
        + "(wrote \(hex(base))), XFER_SIZE \(hex(readBack)); its reset taken as firmware left it")
    }
    return lines
  }

  /// Polls ISR for up to `ms` for `bits` or a failure; ISR as it was, its
  /// bits cleared.
  func wait(_ bits: UInt32, ms: Int64 = 100) -> UInt32? {
    let deadline = Clock.monotonic() + ms * 1_000_000
    while true {
      let s = regs.load32(CdnsI2C.isr)
      if s & (bits | CdnsI2C.Interrupt.failures) != 0 {
        regs.store32(CdnsI2C.isr, s)
        return s
      }
      guard Clock.monotonic() < deadline else { return nil }
      sleep(until: Clock.monotonic() + 10_000)
    }
  }

  func gaveUp() -> I2CBusIPC.I2CError {
    seen = "CR \(hex(regs.load32(CdnsI2C.cr))), SR \(hex(regs.load32(CdnsI2C.sr))), ISR \(hex(regs.load32(CdnsI2C.isr))), "
      + "XFER_SIZE \(hex(regs.load32(CdnsI2C.transferSize)))"
    return .timedOut
  }

  func error(_ f: CdnsI2C.Failure, isr: UInt32) -> I2CBusIPC.I2CError {
    seen = "ISR \(hex(isr)), SR \(hex(regs.load32(CdnsI2C.sr))), XFER_SIZE \(hex(regs.load32(CdnsI2C.transferSize)))"
    switch f {
    case .noDevice: return .noDevice
    case .nak: return .nak
    case .busError: return .busError
    case .arbitrationLost: return .arbitrationLost
    }
  }

  /// A message sent: `bytes` from `from`, the address then written.
  func send(address: UInt32, bytes: [UInt8], _ m: CdnsI2C.Message) throws(I2CBusIPC.I2CError) {
    let hold = CdnsI2C.Control.hold
    regs.store32(CdnsI2C.cr, base | CdnsI2C.Control.clearFIFO | (m.holdAtStart ? hold : 0))
    regs.store32(CdnsI2C.isr, regs.load32(CdnsI2C.isr))
    var sent = 0
    func push() {
      let n = CdnsI2C.pushable(remaining: bytes.count - sent, queued: Int(regs.load32(CdnsI2C.transferSize)))
      for _ in 0..<n {
        regs.store32(CdnsI2C.data, UInt32(bytes[sent]))
        sent += 1
      }
      if sent == bytes.count && m.last { regs.store32(CdnsI2C.cr, base) }
    }
    push()
    regs.store32(CdnsI2C.address, address)
    while true {
      guard let s = wait(CdnsI2C.Interrupt.complete) else { throw gaveUp() }
      let moved = max(sent - Int(regs.load32(CdnsI2C.transferSize)), 0)
      if let f = CdnsI2C.failure(isr: s, moved: moved) { throw error(f, isr: s) }
      if sent == bytes.count { return }
      push()
    }
  }

  /// A message received: `m.length` bytes (kept unless dropped).
  func receive(address: UInt32, _ m: CdnsI2C.Message, into out: inout [UInt8]) throws(I2CBusIPC.I2CError) {
    regs.store32(CdnsI2C.cr, base | CdnsI2C.Control.receive | CdnsI2C.Control.clearFIFO
      | (m.holdAtStart ? CdnsI2C.Control.hold : 0))
    regs.store32(CdnsI2C.isr, regs.load32(CdnsI2C.isr))
    var armed = CdnsI2C.firstChunk(length: m.length, largest: largest)
    var held = m.holdAtStart
    regs.store32(CdnsI2C.transferSize, UInt32(armed))
    regs.store32(CdnsI2C.address, address)
    if m.releasesAtStart {
      regs.store32(CdnsI2C.cr, base | CdnsI2C.Control.receive)
      held = false
    }
    var drained = 0
    var complete = false
    while drained < m.length {
      if CdnsI2C.needsRearm(total: m.length, drained: drained, armed: armed) {
        // The FIFO full and the bus held: the counter falls to one, and
        // is written the rest before it can reach zero.
        let want = UInt32(armed - drained - CdnsI2C.fifoDepth)
        let deadline = Clock.monotonic() + 100_000_000
        while regs.load32(CdnsI2C.transferSize) != want {
          let s = regs.load32(CdnsI2C.isr)
          if let f = CdnsI2C.failure(isr: s, moved: drained) { throw error(f, isr: s) }
          guard Clock.monotonic() < deadline else { throw gaveUp() }
          sleep(until: Clock.monotonic() + 10_000)
        }
        let r = CdnsI2C.rearm(total: m.length, drained: drained, largest: largest)
        regs.store32(CdnsI2C.transferSize, UInt32(r.chunk))
        armed = r.armed
        continue
      }
      if regs.load32(CdnsI2C.sr) & CdnsI2C.Status.rxData != 0 {
        let b = UInt8(truncatingIfNeeded: regs.load32(CdnsI2C.data))
        if !m.discard { out.append(b) }
        drained += 1
        if held && CdnsI2C.releasesHold(last: m.last, expected: m.length - drained) {
          regs.store32(CdnsI2C.cr, base | CdnsI2C.Control.receive)
          held = false
        }
        continue
      }
      guard let s = wait(CdnsI2C.Interrupt.data | CdnsI2C.Interrupt.complete) else { throw gaveUp() }
      if let f = CdnsI2C.failure(isr: s, moved: drained) { throw error(f, isr: s) }
      if s & CdnsI2C.Interrupt.complete != 0 {
        complete = true
        // Done with bytes missing: nothing more is coming.
        if regs.load32(CdnsI2C.sr) & CdnsI2C.Status.rxData == 0 && drained < m.length { throw error(.busError, isr: s) }
      }
    }
    if !complete {
      guard let s = wait(CdnsI2C.Interrupt.complete) else { throw gaveUp() }
      if let f = CdnsI2C.failure(isr: s, moved: drained) { throw error(f, isr: s) }
    }
  }

  func transfer(address: UInt16, write: [UInt8], read: UInt32) throws(I2CBusIPC.I2CError) -> [UInt8] {
    guard write.count <= 256, read <= 256 else { throw .tooLong }
    guard CdnsI2C.readFits(length: Int(read), largest: largest) else { throw .tooLong }
    return try lock.withLock { () throws(I2CBusIPC.I2CError) -> [UInt8] in
      var out: [UInt8] = []
      seen = ""
      do throws(I2CBusIPC.I2CError) {
        guard alive else { throw .timedOut }
        // The bus quiet: no START seen without its STOP.
        let deadline = Clock.monotonic() + 500_000_000
        while regs.load32(CdnsI2C.sr) & CdnsI2C.Status.busActive != 0 {
          guard Clock.monotonic() < deadline else {
            seen = "bus active, SR \(hex(regs.load32(CdnsI2C.sr)))"
            throw .busError
          }
          sleep(until: Clock.monotonic() + 100_000)
        }
        for m in CdnsI2C.messages(write: write.count, read: Int(read)) {
          if m.read {
            try receive(address: UInt32(address & 0x7F), m, into: &out)
          } else {
            try send(address: UInt32(address & 0x7F), bytes: write, m)
          }
        }
        done += 1
        return out
      } catch {
        failed += 1
        last = "0x\(String(address, radix: 16)): \(Controller.text(error))" + (seen.isEmpty ? "" : " (\(seen))")
        reset()
        throw error
      }
    }
  }

  static func text(_ e: I2CBusIPC.I2CError) -> String {
    switch e {
    case .noDevice: "no device answered"
    case .nak: "a byte not acknowledged"
    case .busError: "bus error"
    case .arbitrationLost: "arbitration lost"
    case .timedOut: "timed out"
    case .tooLong: "too long"
    }
  }

  func statusText(_ head: [String]) -> String {
    lock.withLock {
      var lines = head + ["\(rate / 1000).\(rate % 1000 / 100) kHz", "transfers \(done), failed \(failed)"]
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }

@main struct CdnsI2CHost {
  /// The input clock's rate assumed where SCMI gives none.
  static let assumedInput: UInt32 = 100_000_000

  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    var head: [String] = []
    // Its power resource, then its clock, and the clock's rate.
    if let ns, !ns.writeText("/dev/acpi/power", "on\n") { head.append("no power resource to turn on") }
    var input = assumedInput
    var clockLine = "input clock \(input) Hz assumed: no SCMI clock"
    if let ns, let id = CdnsI2C.firstNumber(ns.readText("/dev/acpi/clocks") ?? "") {
      if !ns.writeText("/dev/scmi/ctl", "clock \(id) on\n") { head.append("scmi refused `clock \(id) on`") }
      var rate: UInt32?
      if ns.writeText("/dev/scmi/ctl", "clock \(id) rate\n") {
        rate = CdnsI2C.clockRate(status: ns.readText("/dev/scmi/status") ?? "", id: id)
      }
      if let rate {
        input = rate
        clockLine = "input clock \(id) at \(input) Hz"
      } else {
        clockLine = "input clock \(id) rate not read: \(input) Hz assumed"
      }
    }
    head.append(clockLine)
    guard let regs = try? resources.map(bar: 0, extent: CdnsI2C.size) else {
      print("cdns-i2c: no registers")
      Process.exit(code: 1)
    }
    let target = CdnsI2C.busRate(properties: ns?.readText("/dev/acpi/properties") ?? "")
    guard let dividers = CdnsI2C.dividers(input: input, target: target) ?? CdnsI2C.dividers(input: input, target: 100_000)
    else {
      print("cdns-i2c: no divider makes \(target) Hz from \(input) Hz")
      Process.exit(code: 1)
    }
    let controller = Controller(regs, dividers: dividers)
    head += controller.start()
    print("cdns-i2c: " + head.joined(separator: "; "))
    let bringUp = head

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { controller.statusText(bringUp) })
      tree.service("bus") { (channel: consuming Handle) throws(Status) in
        try dispatcher.add(I2CBusIPC.BusServer(channel: channel, impl: controller))
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
