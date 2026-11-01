// SPDX-License-Identifier: BSD-3-Clause

// bin/regulator-fixed (regulator-fixed(3)): a fixed regulator, a provider
// of a supply (D154). devmgr gives its node's properties and links at
// /dev/dt, starts it after its GPIO's provider and its own supply's, and
// mounts this tree at /dev/provider/SERVICE in each driver whose device's
// `NAME-supply` names it:
//   ctl      `on` or `off`: its own supply on first, then its GPIO set to
//            the level for that, then `startup-delay-us`; a write fails if
//            its GPIO's provider refuses, or for `off` with no GPIO
//   status   its name, voltage and state, its GPIO, the commands done and
//            the last failure
// It is turned on when it starts if its node says it is always on or on
// at boot.

import DriverHost
import IPC
import Node
import Sys

final class Supply: @unchecked Sendable {
  let regulator: FixedRegulator
  let ns: Namespace?
  /// Its GPIO's provider's service and cells; empty where it has none.
  let gpio: ProvidedLink?
  /// Its own supply's provider.
  let input: String?
  let lock = Lock()
  var on = false
  var done = 0, failed = 0
  var last = ""

  init(_ regulator: FixedRegulator, _ ns: Namespace?, links: [ProvidedLink]) {
    self.regulator = regulator
    self.ns = ns
    gpio = links.first { $0.isKind("gpio") }
    input = links.first { $0.isKind("supply") && !$0.provider.isEmpty }?.provider
    on = gpio == nil
  }

  enum Failure: Error { case noGPIO, refused(String) }

  func set(_ want: Bool) throws(Failure) {
    try lock.withLock { () throws(Failure) in
      do throws(Failure) {
        if want, let input, ns?.writeText("/dev/provider/\(input)/ctl", "on\n") != true {
          throw .refused(input)
        }
        if let g = gpio {
          guard !g.provider.isEmpty, let c = regulator.gpioCommand(g.cells, on: want) else { throw .noGPIO }
          guard ns?.writeText("/dev/provider/\(g.provider)/ctl", c + "\n") == true else { throw .refused(g.provider) }
        } else if !want {
          throw .noGPIO
        }
        if want, !on, regulator.startupDelay > 0 {
          sleep(until: Clock.monotonic() + Int64(regulator.startupDelay) * 1000)
        }
        on = want
        done += 1
      } catch {
        failed += 1
        switch error {
        case .noGPIO: last = (want ? "on" : "off") + ": no GPIO"
        case .refused(let p): last = (want ? "on" : "off") + ": \(p) refused"
        }
        throw error
      }
    }
  }

  var status: String {
    lock.withLock {
      var lines = ["\(regulator.name.isEmpty ? "-" : regulator.name) \(regulator.microvolts) uV \(on ? "on" : "off")"]
      if let g = gpio {
        lines.append("gpio \(g.provider.isEmpty ? "-" : g.provider) " + g.cells.map { String($0) }.joined(separator: " ")
          + (regulator.activeHigh ? " active-high" : " active-low"))
      }
      lines.append("commands \(done), failed \(failed)")
      if !last.isEmpty { lines.append("last failure: " + last) }
      return lines.map { $0 + "\n" }.joined()
    }
  }
}

@main struct FixedRegulatorHost {
  static func main() {
    let start = Startup.current
    let ns = try? Namespace(start)
    let regulator = FixedRegulator(node: ns?.readText("/dev/dt/node") ?? "")
    let supply = Supply(regulator, ns, links: ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? ""))
    if regulator.alwaysOn || regulator.bootOn, supply.gpio != nil {
      do throws(Supply.Failure) { try supply.set(true) } catch { print("regulator-fixed: \(regulator.name): not on") }
    }
    print("regulator-fixed: \(regulator.name) \(regulator.microvolts) uV, \(supply.on ? "on" : "off")")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { supply.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A).map({ String(decoding: $0, as: UTF8.self) }) {
          guard line.utf8.elementsEqual("on".utf8) || line.utf8.elementsEqual("off".utf8) else { throw .invalid }
          let want = line.utf8.elementsEqual("on".utf8)
          do throws(Supply.Failure) {
            try supply.set(want)
          } catch {
            print("regulator-fixed: \(regulator.name): \(line) failed")
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
