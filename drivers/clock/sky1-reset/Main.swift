// SPDX-License-Identifier: BSD-3-Clause

// bin/sky1-reset (sky1-reset(3)): one of the CIX Sky1's two reset
// controllers, RST0 (CIXHA020) or RST1 (CIXHA021), the one owner of its
// page (D167). devmgr grants the controller's own registers, and mounts
// this tree at /dev/provider/SERVICE in the driver of each device whose
// RSTL names it (D163); the device reads its link's index from
// /dev/acpi/links:
//   ctl      a command a line: `reset N assert`, `reset N deassert`, or
//            `reset N pulse US`; a write fails if the controller has no
//            line N. Each change reads the line's word and writes it
//            back with that bit alone changed, so no other block's reset
//            is touched, and a command that finds the bit as asked writes
//            nothing
//   status   the controller, each line a command named and its state as
//            its bit reads now, the commands done and the last failure
// Written with no Linux or BSD source: lib/Sky1Reset.swift has the tables.

import DriverHost
import IPC
import Node
import Sys

/// The controller's registers, changed a command at a time.
final class Unit: @unchecked Sendable {
  let controller: Controller
  let regs: Registers
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""
  /// The indices a command has named, in order.
  var touched: [UInt32] = []

  init(_ controller: Controller, _ regs: consuming Registers) {
    self.controller = controller
    self.regs = regs
  }

  /// `line` held or released, its word's other bits as they read.
  func set(_ line: Line, asserted: Bool) {
    let word = regs.load32(line.register)
    let next = changed(word, line, asserted: asserted)
    if next != word { regs.store32(line.register, next) }
  }

  func run(_ c: Command) throws(ResetError) {
    try lock.withLock { () throws(ResetError) in
      guard let line = controller.line(c.index) else {
        failed += 1
        last = c.description + ": " + ResetError.noSuchLine.description
        throw ResetError.noSuchLine
      }
      if !touched.contains(c.index) { touched.append(c.index) }
      switch c {
      case .assert: set(line, asserted: true)
      case .deassert: set(line, asserted: false)
      case .pulse(_, let us):
        // Held, released, and given as long again to come out of reset.
        set(line, asserted: true)
        sleep(until: Clock.monotonic() + Int64(us) * 1000)
        set(line, asserted: false)
        sleep(until: Clock.monotonic() + Int64(us) * 1000)
      }
      done += 1
    }
  }

  var status: String {
    lock.withLock {
      var lines = ["\(controller.name): \(controller.hid), \(controller.count) resets"]
      for n in touched {
        guard let line = controller.line(n) else { continue }
        lines.append("reset \(n) " + (isAsserted(regs.load32(line.register), line) ? "asserted" : "deasserted"))
      }
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct Sky1ResetHost {
  static func main() {
    let start = Startup.current
    let resources = DeviceResources(take: { start.take($0)?.release() })
    guard let regs = try? resources.map(bar: 0) else {
      print("sky1-reset: no registers")
      Process.exit(code: 1)
    }
    guard let which = Controller(base: regs.physical) else {
      print("sky1-reset: not RST0 or RST1: registers at \(regs.physical)")
      Process.exit(code: 1)
    }
    guard regs.size >= which.size else {
      print("sky1-reset: \(which.name): registers too small: \(regs.size)")
      Process.exit(code: 1)
    }
    let unit = Unit(which, regs)
    print("sky1-reset: \(which.name): \(which.hid), \(which.count) resets")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { unit.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A).map({ String(decoding: $0, as: UTF8.self) }) {
          guard let c = Command(line) else { throw .invalid }
          do throws(ResetError) {
            try unit.run(c)
          } catch {
            print("sky1-reset: \(which.name): \(c.description): \(error.description)")
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
