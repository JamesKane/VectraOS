// SPDX-License-Identifier: BSD-3-Clause

// bin/p1 (p1(3)): the SpacemiT P1 PMIC, on an I2C bus (D158). devmgr gives
// its node at /dev/dt, starts it after its bus's controller, and mounts
// the controller's tree at /dev/provider/SERVICE, whose `bus` it calls
// for each register read or written (P1.swift). Its tree, mounted in the
// drivers of the devices its regulators supply:
//   status  the chip's version, the RTC's date, and each regulator its
//           node names: on or off, and its voltage
//   ctl     `on NAME` or `off NAME`, a regulator its node names (not
//           `off` for one always on); `voltage NAME MICROVOLTS`, its
//           voltage, in the range its node gives (the SD card's
//           signalling supply to 1.8 V, sdhci(3)); `poweroff`, the board
//           off
//   rtc     the RTC's date, `2026-11-01T18:04:05Z`; written, the RTC
//           set to it (stopped, its counts written and read back, and
//           started again)
// It starts the RTC if it isn't counting (spacemit-k1 05 §5.3).
// devmgr mounts its tree at dev/rtc0 too, for the time service. The
// RTC's alarm isn't used, and the PMIC's interrupt isn't taken.

import DriverHost
import I2CBus
import IPC
import Node
import Sys

/// The PMIC through its bus.
final class Chip: @unchecked Sendable {
  var bus: I2CBusIPC.BusClient
  let address: UInt16
  let named: [(name: String, alwaysOn: Bool)]
  /// The node's properties: each regulator's voltage range.
  let node: String
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""

  init(bus raw: UInt32, address: UInt16, node: String) {
    bus = I2CBusIPC.BusClient(channel: Handle(raw: raw))
    self.address = address
    self.node = node
    named = P1.named(node: node)
  }

  /// `count` registers from `register`.
  func read(_ register: Int, _ count: Int) -> [UInt8]? {
    try? bus.transfer(address: address, write: [UInt8(register)], read: UInt32(count))
  }

  func write(_ register: Int, _ value: UInt8) -> Bool {
    (try? bus.transfer(address: address, write: [UInt8(register), value], read: 0)) != nil
  }

  /// The RTC's date, read twice alike so no count rolls over between.
  func date() -> P1.Date? {
    var previous = read(P1.rtc, 6)
    for _ in 0..<4 {
      let now = read(P1.rtc, 6)
      if let now, now == previous { return P1.Date(counts: now) }
      previous = now
    }
    return nil
  }

  enum Failure: Error { case unknown, alwaysOn, bus, range, unsettled }

  static func text(_ e: Failure) -> String {
    switch e {
    case .unknown: "not this PMIC's, or not in its node"
    case .alwaysOn: "always on"
    case .bus: "the bus failed"
    case .range: "no code for it, or outside its node's range"
    case .unsettled: "its code didn't read back"
    }
  }

  func set(_ name: String, on: Bool) throws(Failure) {
    try lock.withLock { () throws(Failure) in
      do throws(Failure) {
        guard let r = P1.regulator(name), let n = named.first(where: { $0.name.utf8.elementsEqual(name.utf8) }) else {
          throw .unknown
        }
        if !on, n.alwaysOn { throw .alwaysOn }
        guard let c = read(r.control, 1)?.first, write(r.control, on ? c | 1 : c & ~1) else { throw .bus }
        done += 1
      } catch {
        failed += 1
        last = (on ? "on " : "off ") + name + ": "
          + Chip.text(error)
        throw error
      }
    }
  }

  /// Regulator `name` at `uv`: its code written, waited 1 ms for (an
  /// LDO settles well within it), and read back.
  func setVoltage(_ name: String, _ uv: UInt32) throws(Failure) {
    try lock.withLock { () throws(Failure) in
      do throws(Failure) {
        guard let r = P1.regulator(name), named.contains(where: { $0.name.utf8.elementsEqual(name.utf8) }) else {
          throw .unknown
        }
        guard let code = r.code(uv), P1.range(node: node, name)?.contains(uv) ?? false else { throw .range }
        guard write(r.voltage, code) else { throw .bus }
        sleep(until: Clock.monotonic() + 1_000_000)
        guard let back = read(r.voltage, 1)?.first else { throw .bus }
        guard r.microvolts(back) == uv else { throw .unsettled }
        done += 1
      } catch {
        failed += 1
        last = "voltage \(name) \(uv): " + Chip.text(error)
        throw error
      }
    }
  }

  /// The RTC started if it isn't counting; whether it is.
  func startClock() -> Bool {
    lock.withLock {
      guard let c = read(P1.rtcControl, 1)?.first else { return false }
      guard c & P1.rtcRunning == 0 else { return true }
      return write(P1.rtcControl, c | P1.rtcStart)
    }
  }

  /// The RTC set to `d`: stopped, each count written and all read back,
  /// then started again.
  func setClock(_ d: P1.Date) -> Bool {
    lock.withLock {
      defer { _ = write(P1.rtcControl, (read(P1.rtcControl, 1)?.first ?? 0) | P1.rtcStart) }
      guard let c = read(P1.rtcControl, 1)?.first, write(P1.rtcControl, c & ~P1.rtcRunning) else { return false }
      for (i, v) in d.counts.enumerated() where !write(P1.rtc + i, v) { return false }
      guard let back = read(P1.rtc, 6), P1.Date(counts: back) == d else {
        failed += 1
        last = "rtc " + d.text + ": the counts didn't read back"
        return false
      }
      done += 1
      return true
    }
  }

  func powerOff() -> Bool {
    lock.withLock {
      guard let c = read(P1.powerControl, 1)?.first else { return false }
      return write(P1.powerControl, c | P1.shutdown)
    }
  }

  var status: String {
    lock.withLock {
      var lines = ["version " + (read(P1.version, 1)?.first.map { "0x" + String($0, radix: 16) } ?? "unread")]
      lines.append("rtc " + (date()?.text ?? "unread"))
      for n in named {
        guard let r = P1.regulator(n.name) else { continue }
        guard let c = read(r.control, 2), c.count == 2 else {
          lines.append("\(n.name) unread")
          continue
        }
        lines.append("\(n.name) \(c[0] & 1 != 0 ? "on" : "off") \(r.microvolts(c[1])) uV" + (n.alwaysOn ? " always-on" : ""))
      }
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct P1Host {
  static func main() {
    let start = Startup.current
    let ns = try? Namespace(start)
    let links = ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "")
    guard let i2c = links.first(where: { $0.isKind("i2c") }), !i2c.provider.isEmpty, let address = i2c.cells.first else {
      print("p1: no I2C controller runs for it")
      Process.exit(code: 1)
    }
    guard let channel = try? ns?.connect("/dev/provider/\(i2c.provider)/bus") else {
      print("p1: \(i2c.provider) has no bus")
      Process.exit(code: 1)
    }
    let chip = Chip(bus: channel.release(), address: UInt16(address), node: ns?.readText("/dev/dt/node") ?? "")
    let running = chip.startClock()
    let version = chip.read(P1.version, 1)?.first
    print("p1: at 0x\(String(address, radix: 16)), version " + (version.map { "0x" + String($0, radix: 16) } ?? "unread")
      + ", rtc " + (chip.date()?.text ?? "unread") + (running ? "" : " (not counting)")
      + ", \(chip.named.count) regulators named")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { chip.status })
      tree.text("rtc", read: { chip.lock.withLock { chip.date().map { $0.text + "\n" } ?? "" } },
                write: { (text: String) throws(NodeError) in
        guard let d = P1.Date(text: text), chip.setClock(d) else { throw .invalid }
        print("p1: rtc set to \(d.text)")
      })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A) {
          let words = line.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
          if words.count == 1, words[0].utf8.elementsEqual("poweroff".utf8) {
            print("p1: powering off")
            guard chip.powerOff() else { throw .invalid }
            continue
          }
          if words.count == 3, words[0].utf8.elementsEqual("voltage".utf8), let uv = UInt32(words[2]) {
            do throws(Chip.Failure) {
              try chip.setVoltage(words[1], uv)
              print("p1: \(words[1]) at \(uv) uV")
            } catch {
              print("p1: \(chip.last)")
              throw .invalid
            }
            continue
          }
          guard words.count == 2, words[0].utf8.elementsEqual("on".utf8) || words[0].utf8.elementsEqual("off".utf8)
          else { throw .invalid }
          do throws(Chip.Failure) {
            try chip.set(words[1], on: words[0].utf8.elementsEqual("on".utf8))
          } catch {
            print("p1: \(chip.last)")
            throw .invalid
          }
        }
      })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
  }
}
