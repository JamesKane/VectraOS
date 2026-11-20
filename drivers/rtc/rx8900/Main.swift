// SPDX-License-Identifier: BSD-3-Clause

// bin/rx8900 (rx8900(3)): the Epson RX8900 real-time clock, on an I2C bus
// (D163). devmgr gives the device's links at /dev/acpi/links, starts the
// bus's controller first and mounts its tree at /dev/provider/SERVICE,
// whose `bus` it calls for each register read or written (RX8900.swift).
// Its tree:
//   status  the date or why there is none, the flag register decoded,
//           the transfers done and failed, and the last failure
//   rtc     the date, `2026-11-01T18:04:05Z` (UTC), empty if there is
//           none; written such a date, the clock set to it
// devmgr mounts its tree at dev/rtc<n> too, for the time service. The
// alarm and the timer aren't used, and no interrupt is enabled.

import DriverHost
import I2CBus
import IPC
import Node
import Sys

/// The clock through its bus.
final class Chip: @unchecked Sendable {
  var bus: I2CBusIPC.BusClient
  let address: UInt16
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""

  init(bus raw: UInt32, address: UInt16) {
    bus = I2CBusIPC.BusClient(channel: Handle(raw: raw))
    self.address = address
  }

  /// `count` registers from `register`, counted; the lock held.
  func read(_ register: Int, _ count: Int) -> [UInt8]? {
    if let r = try? bus.transfer(address: address, write: [UInt8(register)], read: UInt32(count)), r.count == count {
      done += 1
      return r
    }
    fail("read \(count) at 0x" + String(register, radix: 16))
    return nil
  }

  func write(_ register: Int, _ bytes: [UInt8]) -> Bool {
    if (try? bus.transfer(address: address, write: [UInt8(register)] + bytes, read: 0)) != nil {
      done += 1
      return true
    }
    fail("write \(bytes.count) at 0x" + String(register, radix: 16))
    return false
  }

  func fail(_ what: String) {
    failed += 1
    last = what + ": the transfer failed"
  }

  /// The flag register and the time, read twice alike so no count rolls
  /// over between; the lock held.
  func registers() -> (flags: RX8900.Flags, time: [UInt8])? {
    guard let f = read(RX8900.flag, 1)?.first else { return nil }
    var previous = read(RX8900.time, 7)
    for _ in 0..<4 {
      let now = read(RX8900.time, 7)
      if let now, now == previous { return (RX8900.Flags(f), now) }
      previous = now
    }
    return nil
  }

  func date() -> RX8900.Date? {
    lock.withLock {
      guard let r = registers() else { return nil }
      return RX8900.Date(registers: r.time, flags: r.flags)
    }
  }

  /// The clock set to `d`: RESET set, the seven registers written in one
  /// transfer, RESET cleared, then VLF cleared and read back clear.
  func set(_ d: RX8900.Date) -> Bool {
    lock.withLock {
      guard let c = read(RX8900.control, 1)?.first, write(RX8900.control, [c | RX8900.reset]) else { return false }
      let wrote = write(RX8900.time, d.registers)
      guard write(RX8900.control, [c & ~RX8900.reset]), wrote else { return false }
      guard let f = read(RX8900.flag, 1)?.first, write(RX8900.flag, [f & ~RX8900.vlf]),
        let back = read(RX8900.flag, 1)?.first, back & RX8900.vlf == 0
      else {
        last = "rtc " + d.text + ": VLF didn't clear"
        failed += 1
        return false
      }
      return true
    }
  }

  var status: String {
    lock.withLock {
      var lines: [String] = []
      if let r = registers() {
        lines.append("rtc " + (RX8900.Date(registers: r.time, flags: r.flags)?.text
          ?? RX8900.why(registers: r.time, flags: r.flags) ?? "unread"))
        lines.append("flags " + r.flags.text)
      } else {
        lines.append("rtc unread")
        if let f = read(RX8900.flag, 1)?.first { lines.append("flags " + RX8900.Flags(f).text) }
      }
      lines.append("transfers \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct RX8900Host {
  static func main() {
    let start = Startup.current
    let ns = try? Namespace(start)
    let links = ProvidedLink.parse(ns?.readText("/dev/acpi/links") ?? "")
    guard let i2c = links.first(where: { $0.isKind("i2c") }), !i2c.provider.isEmpty, let address = i2c.cells.first else {
      print("rx8900: no I2C controller runs for it")
      Process.exit(code: 1)
    }
    guard let channel = try? ns?.connect("/dev/provider/\(i2c.provider)/bus") else {
      print("rx8900: \(i2c.provider) has no bus")
      Process.exit(code: 1)
    }
    let chip = Chip(bus: channel.release(), address: UInt16(address))
    print("rx8900: at 0x\(String(address, radix: 16)), " + chip.status.utf8.split(separator: 0x0A).prefix(2)
      .map { String(decoding: $0, as: UTF8.self) }.joined(separator: ", "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { chip.status })
      tree.text("rtc", read: { chip.date().map { $0.text + "\n" } ?? "" },
                write: { (text: String) throws(NodeError) in
        guard let d = RX8900.Date(text: text), chip.set(d) else { throw .invalid }
        print("rx8900: rtc set to \(d.text)")
      })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
  }
}
