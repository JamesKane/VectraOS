// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-i2c (k1-i2c(3)): a SpacemiT K1 I2C controller, its bus served to
// the devices on it (D158). devmgr grants its registers, gives its node at
// /dev/dt, starts it after its providers (its pins, clocks and reset),
// and mounts this tree at /dev/provider/SERVICE in the driver of each
// device on the bus:
//   bus     vectraos.i2c's Bus: transfer, one at a time, polled
//           (K1I2C.swift), its bytes at the node's `clock-frequency`
//   status  the bus's speed, the transfers done and failed, the last
//           failure
// A failed transfer resets the controller, so the next starts clean.

import DriverHost
import I2CBus
import IPC
import Node
import Sys

final class Controller: I2CBusIPC.BusHandler, @unchecked Sendable {
  let regs: Registers
  let base: UInt32
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""

  init(_ regs: consuming Registers, frequency: UInt32) {
    self.regs = regs
    base = K1I2C.base(frequency: frequency)
  }

  /// The unit reset and enabled, its status cleared.
  func reset() {
    regs.store32(K1I2C.cr, K1I2C.Control.unitReset)
    sleep(until: Clock.monotonic() + 5_000)
    regs.store32(K1I2C.cr, 0)
    regs.store32(K1I2C.cr, base)
    regs.store32(K1I2C.sr, K1I2C.Status.clear)
  }

  /// Waits up to 20 ms for `bits` of SR, or an error; SR as it was, its
  /// bits cleared.
  func wait(_ bits: UInt32) -> UInt32? {
    let deadline = Clock.monotonic() + 20_000_000
    while true {
      let s = regs.load32(K1I2C.sr)
      if s & (bits | K1I2C.Status.busError | K1I2C.Status.arbitrationLost) != 0 {
        regs.store32(K1I2C.sr, s & K1I2C.Status.clear)
        return s
      }
      guard Clock.monotonic() < deadline else { return nil }
      sleep(until: Clock.monotonic() + 10_000)
    }
  }

  func transfer(address: UInt16, write: [UInt8], read: UInt32) throws(I2CBusIPC.I2CError) -> [UInt8] {
    guard write.count <= 256, read <= 256 else { throw .tooLong }
    return try lock.withLock { () throws(I2CBusIPC.I2CError) -> [UInt8] in
      reset()
      var out: [UInt8] = []
      var seen = ""
      do throws(I2CBusIPC.I2CError) {
        for step in K1I2C.steps(address: UInt8(address & 0x7F), write: write, read: Int(read)) {
          if let b = step.byte { regs.store32(K1I2C.dbr, UInt32(b)) }
          regs.store32(K1I2C.cr, step.control(base))
          guard let s = wait(step.done) else {
            seen = "SR 0x\(String(regs.load32(K1I2C.sr), radix: 16)), CR 0x\(String(regs.load32(K1I2C.cr), radix: 16)), "
              + "BMR 0x\(String(regs.load32(K1I2C.bmr), radix: 16))"
            throw .timedOut
          }
          if s & K1I2C.Status.arbitrationLost != 0 { throw .arbitrationLost }
          if s & K1I2C.Status.busError != 0 {
            if case .address = step { throw .noDevice }
            throw s & K1I2C.Status.nakReceived != 0 ? .nak : .busError
          }
          if case .receive = step { out.append(UInt8(truncatingIfNeeded: regs.load32(K1I2C.dbr))) }
        }
        // The STOP sent and the unit idle again.
        _ = Controller.poll(5) { self.regs.load32(K1I2C.sr) & K1I2C.Status.unitBusy == 0 }
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

  static func poll(_ ms: Int64, _ ok: () -> Bool) -> Bool {
    let deadline = Clock.monotonic() + ms * 1_000_000
    while !ok() {
      guard Clock.monotonic() < deadline else { return false }
      sleep(until: Clock.monotonic() + 10_000)
    }
    return true
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

  var status: String {
    lock.withLock {
      var lines = ["\(base & K1I2C.Control.fast != 0 ? 400 : 100) kHz", "transfers \(done), failed \(failed)"]
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct K1I2CHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    let links = ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "")
    // Its pins set, its clocks on and its reset released.
    for l in links where !l.provider.isEmpty && (l.isKind("pinctrl") || l.isKind("clock") || l.isKind("reset")) {
      guard let command = l.enabling else { continue }
      if ns?.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") != true {
        print("k1-i2c: \(l.provider) refused `\(command)`")
      }
    }
    guard let regs = try? resources.map(bar: 0, extent: K1I2C.size) else {
      print("k1-i2c: no registers")
      Process.exit(code: 1)
    }
    let frequency = I2CNode.frequency(ns?.readText("/dev/dt/node") ?? "")
    let controller = Controller(regs, frequency: frequency)
    controller.reset()
    print("k1-i2c: \(frequency / 1000) kHz")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { controller.status })
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

enum I2CNode {
  /// The node's `clock-frequency`, else I2C's standard 100 kHz.
  static func frequency(_ node: String) -> UInt32 {
    for line in node.utf8.split(separator: 0x0A) where line.starts(with: "clock-frequency ".utf8) {
      let digits = line.dropFirst(16).filter { $0 != UInt8(ascii: "<") && $0 != UInt8(ascii: ">") }
      let s = String(decoding: digits, as: UTF8.self)
      let v = s.utf8.starts(with: "0x".utf8) ? UInt32(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16)
        : UInt32(s)
      if let v, v > 0 { return v }
    }
    return 100_000
  }
}
