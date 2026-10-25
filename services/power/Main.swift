// SPDX-License-Identifier: BSD-3-Clause

// bin/power: the power service (power(8), D130). It asks every CPU with
// ACPI's CPPC for its highest performance level, writing each one's
// desired-performance register (devmgr's `cpus`, the registers' pages
// carved from its manifest's `resource mmio`), and reads the thermal
// zones (devmgr's `thermal`) at their polling period, at most a second
// apart: a step down while one is at or above its passive trip, a step
// back up once every zone is 5 °C below its own, and the machine powered
// off (devmgr's /dev/reboot) when one reaches its critical trip. A
// machine with no CPPC is left at firmware's level; one with no thermal
// zones runs at its highest; one whose zones don't read, at its lowest.
// Its tree: `status`.

import DriverHost
import IPC
import Node
import Sys

func fail(_ what: String) -> Never {
  print("power: \(what)")
  Process.exit(code: 2)
}

/// A page of registers, mapped once for every CPU's register in it.
final class Window {
  let page: UInt64
  let registers: Registers
  init(page: UInt64, registers: consuming Registers) {
    self.page = page
    self.registers = registers
  }
}

/// A CPU whose level is written, and where.
struct Target {
  let control: CPUControl
  let window: Window
  let offset: Int
}

/// What `status` says, kept under its lock.
final class Report: @unchecked Sendable {
  let lock = Lock()
  var cppc = "no CPPC: firmware's levels"
  var level = ""
  var thermal = "no thermal zones"
  var zones: [Zone] = []
  var loop = ""
  var steps = 0

  var text: String {
    lock.withLock {
      var out = cppc + "\n"
      if !level.isEmpty { out += level + "\n" }
      out += thermal + "\n"
      for z in zones {
        let t = z.temperature.map { Zone.celsius($0) + " C" } ?? "unread"
        out += "\(z.path) \(t)" + (z.passive.map { ", passive \(Zone.celsius($0)) C" } ?? "")
          + (z.critical.map { ", critical \(Zone.celsius($0)) C" } ?? "") + "\n"
      }
      if !loop.isEmpty { out += loop + "\n" }
      return out + "steps taken \(steps)\n"
    }
  }
}

/// A dependent chain of multiplies, `n` long: its time is the clock's.
/// Each squares the last (a recurrence with no closed form, from a seed
/// the compiler can't know), so it can't be folded away.
@inline(never) func chain(_ n: Int, _ seed: UInt64) -> UInt64 {
  var x = seed
  for _ in 0..<n { x = x &* x &+ 0x9E37_79B9_7F4A_7C15 }
  return x
}

/// The chain's time in microseconds, the best of three.
func loopMicroseconds() -> Int64 {
  var best = Int64.max
  for _ in 0..<3 {
    let t0 = Clock.monotonic()
    let x = chain(5_000_000, UInt64(truncatingIfNeeded: t0) | 1)
    let t = (Clock.monotonic() - t0) / 1000
    if x == 0 { print("power: the chain came to 0") }
    best = min(best, t)
  }
  return best
}

/// A page of registers carved from the MMIO resource (`raw`, borrowed:
/// the service keeps it) and mapped.
func carve(_ raw: UInt32, page: UInt64) throws(Status) -> Registers {
  let parent = Handle(raw: raw)
  let r: Handle
  do throws(Status) {
    r = try Sys.Resource.create(parent: parent, kind: .mmio, base: page, size: 4096, name: "cppc")
  } catch {
    _ = parent.release()
    throw error
  }
  _ = parent.release()
  return try Registers.map(r)
}

@main struct PowerService {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    let report = Report()

    if let export = start.export(), let dispatcher = try? IPCDispatcher() {
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { report.text })
      if (try? tree.serve(export)) != nil {
        _ = try? Thread.spawn { try? dispatcher.run() }.release()
      }
    }

    // devmgr's processors, once it has loaded ACPI's namespace.
    var cpus = ""
    let until = Clock.monotonic() + 30_000_000_000
    while Clock.monotonic() < until {
      if let t = ns.readText("/svc/devmgr/cpus"), !t.isEmpty {
        cpus = t
        break
      }
      Sys.sleep(until: Clock.monotonic() + 100_000_000)
    }
    let controls = lines(cpus).compactMap { CPUControl.parse($0) }

    // Their registers' pages, each mapped once.
    var found: [Target] = []
    var windows: [Window] = []
    let mmio = start.take(HandleType.info(HandleType.resource(.mmio)))?.release() ?? 0
    for c in controls {
      guard let address = c.address, mmio != 0 else { continue }
      let page = address & ~4095
      if !windows.contains(where: { $0.page == page }) {
        do throws(Status) {
          windows.append(Window(page: page, registers: try carve(mmio, page: page)))
        } catch {
          print("power: can't map CPU \(c.uid)'s register at 0x\(String(address, radix: 16)): \(error.rawValue)")
          continue
        }
      }
      guard let w = windows.first(where: { $0.page == page }) else { continue }
      found.append(Target(control: c, window: w, offset: Int(address - page)))
    }
    let targets = found

    func apply(_ step: Int) {
      for t in targets {
        let level = t.control.level(step, of: Policy.steps)
        switch t.control.bitWidth {
        case 8: t.window.registers.store8(t.offset, UInt8(truncatingIfNeeded: level))
        case 16: t.window.registers.store16(t.offset, UInt16(truncatingIfNeeded: level))
        case 64: t.window.registers.store64(t.offset, UInt64(level))
        default: t.window.registers.store32(t.offset, level)
        }
      }
      describe(step)
    }
    func describe(_ step: Int) {
      guard let first = targets.first else { return }
      let mhz = targets.map { $0.control.megahertz($0.control.level(step, of: Policy.steps)) }
      let range = "\(mhz.min() ?? 0)-\(mhz.max() ?? 0) MHz"
      report.lock.withLock {
        report.level = "step \(step) of \(Policy.steps): CPU \(first.control.uid) at level "
          + "\(first.control.level(step, of: Policy.steps)) of \(first.control.lowest)-\(first.control.highest), "
          + "every CPU \(range)"
      }
    }

    var policy = Policy()
    var seen: [UInt32] = []
    for d in targets.compactMap({ $0.control.domain }) where !seen.contains(d) { seen.append(d) }
    let domains = seen.count
    if !targets.isEmpty {
      let before = loopMicroseconds()
      apply(policy.step)
      Sys.sleep(until: Clock.monotonic() + 50_000_000)
      let after = loopMicroseconds()
      let line = "a chain of 5M multiplies: \(before / 1000).\(before % 1000 / 100) ms at firmware's level, "
        + "\(after / 1000).\(after % 1000 / 100) ms after"
      report.lock.withLock {
        report.cppc = "cppc \(targets.count) of \(controls.count) CPUs, \(domains) domains, \(windows.count) register pages"
        report.loop = line
      }
      print("power: \(targets.count) CPUs asked for their highest level; \(line)")
    } else if !controls.isEmpty {
      report.lock.withLock { report.cppc = "cppc \(controls.count) CPUs, none with a register this service writes" }
    }

    // The zones, at their period, for good.
    while true {
      let zones = lines(ns.readText("/svc/devmgr/thermal") ?? "").compactMap { Zone.parse($0) }
      let action = policy.next(zones)
      report.lock.withLock {
        report.zones = zones
        report.thermal = zones.isEmpty
          ? "no thermal zones" : "\(zones.count) thermal zones, read every \(Policy.period(zones) * 100) ms: \(policy.reason)"
      }
      switch action {
      case .stay: break
      case .step(let s):
        print("power: step \(s) of \(Policy.steps): \(policy.reason)")
        report.lock.withLock { report.steps += 1 }
        apply(s)
      case .powerOff:
        print("power: powering off: \(policy.reason)")
        if var reboot = try? ns.open("/dev/reboot") { _ = try? reboot.writeText("poweroff") }
        fail("still running after asking for power-off")
      }
      Sys.sleep(until: Clock.monotonic() + Int64(Policy.period(zones)) * 100_000_000)
    }
  }
}
