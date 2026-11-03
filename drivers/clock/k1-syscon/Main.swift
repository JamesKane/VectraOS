// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-syscon (k1-syscon(3)): the SpacemiT K1's APBC or APMU, a provider
// of clocks and resets (D154). devmgr grants the unit's registers and
// gives its node's `compatible` at /dev/dt, which says which unit it is
// (lib/K1Syscon.swift has their tables), and mounts this tree at
// /dev/provider/SERVICE in each driver whose device's `clocks` or
// `resets` name the unit, their cells the ids its ctl takes:
//   ctl      a command a line: `clock ID on|off`, `clock ID rate HZ` (an SDHCI's,
//            an exact rate from PLL1), `reset ID assert|deassert`, `emac OFFSET
//            rgmii|rmii TX RX` (a MAC's interface and delays), `unlock` (the
//            APBC's keys, for one protected AIB access); a write fails
//            if the unit has no such id or MAC, for `off` with no gate, or
//            for a rate no parent and divider make
//   status   the unit, then each clock's and reset's state as its register
//            reads now, each rated clock's rate, each MAC's, the commands
//            done and the last failure
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

  /// The value last written to each of the unit's write-only registers.
  var written: [(register: Int, value: UInt32)] = []

  init(_ unit: SysconUnit, _ regs: consuming Registers) {
    self.unit = unit
    self.regs = regs
  }

  /// A register's value: what reads back, or a write-only one's last
  /// write (0 before any).
  func load(_ register: Int) -> UInt32 {
    guard unit.writeOnly.contains(register) else { return regs.load32(register) }
    return written.first { $0.register == register }?.value ?? 0
  }

  func store(_ register: Int, _ value: UInt32) {
    regs.store32(register, value)
    guard unit.writeOnly.contains(register) else { return }
    if let i = written.firstIndex(where: { $0.register == register }) {
      written[i].value = value
    } else {
      written.append((register, value))
    }
  }

  func run(_ c: Command) throws(SysconError) {
    try lock.withLock { () throws(SysconError) in
      do throws(SysconError) {
        for u in try unit.updates(c, now: { self.load($0) }) {
          // A whole word (a key) is written without reading it first.
          store(u.register, u.mask == ~0 ? u.value : load(u.register) & ~u.mask | u.value)
          guard u.settles != 0 else { continue }
          // A frequency change is given 5 ms to finish.
          let deadline = Clock.monotonic() + 5_000_000
          while regs.load32(u.register) & u.settles != 0 {
            guard Clock.monotonic() < deadline else { throw SysconError.unsettled }
          }
        }
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
      lines += unit.states { self.load($0) }
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
