// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-syscon (k1-syscon(3)): the SpacemiT K1's APBC or APMU, a provider
// of clocks and resets (D154). devmgr grants the unit's registers and
// gives its node's `compatible` at /dev/dt, which says which unit it is
// (lib/K1Syscon.swift has their tables), and mounts this tree at
// /dev/provider/SERVICE in each driver whose device's `clocks` or
// `resets` name the unit, their cells the ids its ctl takes:
//   ctl      a command a line: `clock ID on|off`, `reset ID assert|deassert`;
//            a write fails if the unit has no such id, or for `off`, no gate
//   status   the unit, then each clock's and reset's state as its register
//            reads now, the commands done and the last failure
// A clock or reset two devices share (the K1's SDHCIs' AXI) is one gate
// or one reset: the last command wins.

import DriverHost
import IPC
import Node
import Sys

/// The unit's registers, changed a command at a time.
final class Unit: @unchecked Sendable {
  let unit: SysconUnit
  let regs: Registers
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""

  init(_ unit: SysconUnit, _ regs: consuming Registers) {
    self.unit = unit
    self.regs = regs
  }

  func run(_ c: Command) throws(SysconError) {
    try lock.withLock { () throws(SysconError) in
      do throws(SysconError) {
        let u = try unit.update(c)
        if u.mask != 0 { regs.store32(u.register, regs.load32(u.register) & ~u.mask | u.value) }
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
      var lines = ["\(unit.name): \(unit.clocks.count) clocks, \(unit.resets.count) resets"]
      lines += unit.states { regs.load32($0) }
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct K1SysconHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let compatible = (try? Namespace(start))?.readText("/dev/dt/compatible") ?? ""
    guard let which = SysconUnit(compatibles: compatible.utf8.split(separator: 0x0A).map { Array($0) }) else {
      print("k1-syscon: not an APBC or APMU: \(compatible)")
      Process.exit(code: 1)
    }
    guard let regs = try? resources.map(bar: 0), regs.size >= which.size else {
      print("k1-syscon: \(which.name): no registers")
      Process.exit(code: 1)
    }
    let unit = Unit(which, regs)
    print("k1-syscon: \(which.name): \(which.clocks.count) clocks, \(which.resets.count) resets")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { unit.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A).map({ String(decoding: $0, as: UTF8.self) }) {
          guard let c = Command(line) else { throw .invalid }
          do throws(SysconError) {
            try unit.run(c)
          } catch {
            print("k1-syscon: \(which.name): \(c.description): \(error.description)")
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
