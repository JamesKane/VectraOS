// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-pinctrl (k1-pinctrl(3)): the SpacemiT K1's pin controller, a
// provider of pin states (D154). devmgr grants its registers, gives its
// node's properties at /dev/dt (its states are the nodes under it:
// lib/K1Pinctrl.swift), starts it after the APBC whose clocks it names,
// and mounts this tree at /dev/provider/SERVICE in each driver whose
// device's `pinctrl-N` names one of its states:
//   ctl      a command a line, `state NAME`: each of the state's pins set to
//            its function and settings; a write fails for a state it hasn't
//   status   its states, each `set` if its pins' registers read so now,
//            the commands done and the last failure

import DriverHost
import IPC
import Node
import Sys

/// The registers, changed a command at a time.
final class Pins: @unchecked Sendable {
  let regs: Registers
  let states: [PinState]
  let lock = Lock()
  var done = 0, failed = 0
  var last = ""

  init(_ regs: consuming Registers, _ states: [PinState]) {
    self.regs = regs
    self.states = states
  }

  func set(_ name: String) throws(PinError) {
    try lock.withLock { () throws(PinError) in
      do throws(PinError) {
        guard let s = states.first(where: { $0.name.utf8.elementsEqual(name.utf8) }) else { throw .noSuchState }
        for w in try s.writes() { regs.store32(w.offset, w.value) }
        done += 1
      } catch {
        failed += 1
        last = "state \(name): " + error.description
        throw error
      }
    }
  }

  var status: String {
    lock.withLock {
      var lines = ["pins \(K1Pins.count), states \(states.count)"]
      for s in states {
        let count = s.groups.reduce(0) { $0 + $1.pins.count }
        let set = (try? s.writes())?.allSatisfy { regs.load32($0.offset) & Pad.settings == $0.value & Pad.settings }
        lines.append("state \(s.name) \(count) pins \(set == true ? "set" : "not set")")
      }
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct K1PinctrlHost {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    let states = PinState.states(node: ns?.readText("/dev/dt/node") ?? "")
    // Its own clocks, the APBC's, on.
    for l in ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "") where !l.provider.isEmpty {
      guard let command = l.enabling else { continue }
      if ns?.writeText("/dev/provider/\(l.provider)/ctl", command + "\n") != true {
        print("k1-pinctrl: \(l.provider) refused `\(command)`")
      }
    }
    guard let regs = try? resources.map(bar: 0), regs.size >= K1Pins.size else {
      print("k1-pinctrl: no registers")
      Process.exit(code: 1)
    }
    let pins = Pins(regs, states)
    print("k1-pinctrl: \(K1Pins.count) pins, \(states.count) states")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { pins.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A).map({ String(decoding: $0, as: UTF8.self) }) {
          guard let name = stateCommand(line) else { throw .invalid }
          do throws(PinError) {
            try pins.set(name)
          } catch {
            print("k1-pinctrl: state \(name): \(error.description)")
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
