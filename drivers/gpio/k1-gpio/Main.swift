// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-gpio (k1-gpio(3)): the SpacemiT K1's GPIO controller, a provider
// of GPIOs (D154). devmgr grants its registers, starts it after the APBC
// whose clocks it names, and mounts this tree at /dev/provider/SERVICE in
// each driver whose device's `gpios` or `NAME-gpios` name it, the
// specifier's cells the bank, pin and flags its ctl takes:
//   ctl      a command a line, `gpio BANK PIN FLAGS on|off|input`: the pin
//            driven to its active level (flags bit 0, active low) or the
//            other, or made an input; a write fails for a pin it hasn't
//   status   each bank's outputs and levels as its registers read now,
//            the commands done and the last failure

import DriverHost
import IPC
import Node
import Sys

/// The registers, changed a command at a time.
final class Gpios: @unchecked Sendable {
  let regs: Registers
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""

  init(_ regs: consuming Registers) { self.regs = regs }

  func run(_ c: GpioCommand) throws(GpioError) {
    try lock.withLock { () throws(GpioError) in
      do throws(GpioError) {
        for w in try c.writes() { regs.store32(w.offset, w.value) }
        done += 1
      } catch {
        failed += 1
        last = c.description + ": " + error.description
        throw error
      }
    }
  }

  var status: String {
    lock.withLock {
      var lines = ["gpios \(K1Gpios.count), banks \(K1Gpios.banks)"]
      for b in 0..<K1Gpios.banks {
        let base = K1Gpios.bank(b)
        lines.append("bank \(b) outputs 0x\(hex(regs.load32(base + GpioRegister.direction))) "
          + "levels 0x\(hex(regs.load32(base + GpioRegister.level)))")
      }
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

func hex(_ v: UInt32) -> String {
  let s = String(v, radix: 16)
  return String(repeating: "0", count: max(0, 8 - s.utf8.count)) + s
}

@main struct K1GpioHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    // Its own clocks, the APBC's, on.
    for l in ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "") where !l.provider.isEmpty {
      guard let command = l.enabling else { continue }
      if ns?.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") != true {
        print("k1-gpio: \(l.provider) refused `\(command)`")
      }
    }
    guard let regs = try? resources.map(bar: 0, extent: K1Gpios.size) else {
      print("k1-gpio: no registers")
      Process.exit(code: 1)
    }
    let gpios = Gpios(regs)
    print("k1-gpio: \(K1Gpios.count) GPIOs in \(K1Gpios.banks) banks")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { gpios.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A).map({ String(decoding: $0, as: UTF8.self) }) {
          guard let c = GpioCommand(line) else { throw .invalid }
          do throws(GpioError) {
            try gpios.run(c)
          } catch {
            print("k1-gpio: \(c.description): \(error.description)")
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
    _ = consume resources
  }
}
