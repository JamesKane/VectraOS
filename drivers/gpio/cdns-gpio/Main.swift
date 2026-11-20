// SPDX-License-Identifier: BSD-3-Clause

// bin/cdns-gpio (cdns-gpio(3)): one of the CIX Sky1's Cadence GPIO
// controllers (CIXH1002, CIXH1003), a provider of GPIOs (D163). devmgr
// grants its registers and its interrupt, and mounts this tree at
// /dev/provider/SERVICE in each driver whose device has a GpioIo or
// GpioInt connection on it, the connection's pin and flags the cells its
// ctl takes:
//   ctl      a command a line, `gpio PIN FLAGS on|off|input|watch
//            [TRIGGER]`: the pin driven to its active level (flags bit 0,
//            active low) or the other, made an input, or watched; a write
//            fails for a pin it hasn't
//   events   each watched line, `gpio PIN FLAGS active|inactive edges N`;
//            a read waits until a line has had an interrupt since the
//            channel's last read
//   status   the controller's lines, each line a command named, the
//            commands done and the last failure, the interrupts
// A line no command names is left as firmware set it. The controller's
// clock is turned on through the SCMI agent; its reset is firmware's.

import DriverHost
import IPC
import Node
import Sys

/// The registers, changed a command at a time.
final class Gpios: @unchecked Sendable {
  let regs: Registers
  let lines: Int
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""
  var watches = Watches()
  /// The lines a command has named.
  var touched: UInt32 = 0
  /// Whether the interrupt is served: a line can't be watched otherwise.
  var interrupt = false
  /// Whether the registers answered at start.
  var responds = true
  var counts: () -> (interrupts: Int, polls: Int) = { (0, 0) }

  /// Where the line count came from, for `status`.
  let source: String

  init(_ regs: consuming Registers, lines: Int, byAddress: Bool) {
    source = byAddress ? "by address" : "ngpios"
    self.lines = lines
    self.regs = regs
    // Every line masked, and what was pending cleared, before the
    // interrupt is let through; nothing else is written.
    let pending = self.regs.load32(CdnsRegister.status)
    for w in Watches.reset(lines: lines, pending: pending) { self.regs.store32(w.offset, w.value) }
    let all = CdnsGpios.all(lines)
    responds = self.regs.load32(CdnsRegister.mask) & all == all
  }

  var now: LineRegisters {
    LineRegisters(
      bypass: regs.load32(CdnsRegister.bypass), direction: regs.load32(CdnsRegister.direction),
      outputEnable: regs.load32(CdnsRegister.outputEnable), outputValue: regs.load32(CdnsRegister.outputValue),
      type: regs.load32(CdnsRegister.type), value: regs.load32(CdnsRegister.value),
      anyEdge: regs.load32(CdnsRegister.anyEdge))
  }

  func run(_ c: GpioCommand) throws(GpioError) {
    try lock.withLock { () throws(GpioError) in
      do throws(GpioError) {
        if c.action == .watch, !interrupt { throw .noInterrupt }
        for w in try c.writes(lines: lines, now: now) { regs.store32(w.offset, w.value) }
        touched |= UInt32(1) << UInt32(c.pin)
        if c.action == .watch { watches.watch(c) }
        done += 1
      } catch {
        failed += 1
        last = c.description + ": " + error.description
        throw error
      }
    }
  }

  /// The interrupt: the status read once; whether a watched line had one.
  func serve() -> Bool {
    lock.withLock {
      let (writes, changed) = watches.take(
        status: regs.load32(CdnsRegister.status), mask: regs.load32(CdnsRegister.mask))
      for w in writes { regs.store32(w.offset, w.value) }
      return changed
    }
  }

  var events: String { lock.withLock { watches.text(level: regs.load32(CdnsRegister.inputValue)) } }

  var status: String {
    lock.withLock {
      var out = ["gpios \(lines) (\(source))"]
      if !responds { out.append("no response: the registers don't read as a controller's, its reset may be held") }
      let direction = regs.load32(CdnsRegister.direction), level = regs.load32(CdnsRegister.inputValue)
      let bypass = regs.load32(CdnsRegister.bypass), mask = regs.load32(CdnsRegister.mask)
      for p in 0..<lines where touched & (UInt32(1) << UInt32(p)) != 0 {
        out.append(pinStatus(pin: p, direction: direction, level: level, bypass: bypass, mask: mask,
                             watch: watches.lines.first(where: { $0.pin == p })))
      }
      out.append("commands \(done), failed \(failed)")
      if !last.isEmpty { out.append("last failure: " + last) }
      let (i, p) = counts()
      out.append(interrupt ? "interrupts \(i) polls \(p)" : "no interrupt: no line can be watched")
      return out.map { $0 + "\n" }.joined()
    }
  }
}

/// Writes `line` to `path`.
func command(_ ns: Namespace, _ path: String, _ line: String) -> Bool {
  guard var f = try? ns.open(path) else { return false }
  let bytes = Array((line + "\n").utf8)
  return (try? f.write(offset: 0, bytes)) == UInt32(bytes.count)
}

@main struct CdnsGpioHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    // Its clock, by CLKT's ids: turned on, never off (the FCH's four
    // share one).
    var clocks = 0
    for l in (ns?.readText("/dev/acpi/clocks") ?? "").utf8.split(separator: 0x0A) {
      let w = l.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
      if let ns, w.count == 2, let id = UInt32(w[0]), command(ns, "/dev/scmi/ctl", "clock \(id) on") { clocks += 1 }
    }
    guard let regs = try? resources.map(bar: 0, extent: CdnsGpios.size) else {
      print("cdns-gpio: no registers")
      Process.exit(code: 1)
    }
    let (count, byAddress) = CdnsGpios.count(
      properties: ns?.readText("/dev/acpi/properties") ?? "", base: regs.physical)
    let gpios = Gpios(regs, lines: count, byAddress: byAddress)

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      let events = tree.changing("events", { gpios.events })
      if gpios.responds, let irq = try? resources.interrupt(),
        let thread = try? InterruptThread(irq, msix: false, serve: { _, ack in
          let changed = gpios.serve()
          ack()
          if changed { tree.ready(events) }
        })
      {
        gpios.lock.withLock {
          gpios.interrupt = true
          gpios.counts = { thread.counts }
        }
      }
      print("cdns-gpio: \(count) GPIOs (\(byAddress ? "by address" : "ngpios")),\(clocks) clocks on"
        + (gpios.responds ? "" : "; no response") + (gpios.interrupt ? "" : "; no interrupt: no line can be watched"))
      tree.text("status", read: { gpios.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A).map({ String(decoding: $0, as: UTF8.self) }) {
          guard let c = GpioCommand(line) else { throw .invalid }
          do throws(GpioError) {
            try gpios.run(c)
          } catch {
            print("cdns-gpio: \(c.description): \(error.description)")
            throw .invalid
          }
          // A line watched now is read at once.
          if c.action == .watch { tree.ready(events) }
        }
      })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}
