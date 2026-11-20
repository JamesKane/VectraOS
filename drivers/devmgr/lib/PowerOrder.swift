// SPDX-License-Identifier: BSD-3-Clause

// A platform device's power, in its provider graph's order (D170). A
// driver whose record says `power-up graph` is started with its device on:
// devmgr turns on its SCMI power domains, then its clocks, then its ACPI
// power resources, then releases (or pulses) its resets, each through what
// owns it; and `ctl`'s `power DEVICE off` ends the device's supplies, then
// asks each provider to cut in the reverse order: resets asserted,
// resources off, clocks off, domains off. This file is the order and the
// state machine over them, with what acts (the SCMI agent, devmgr's own
// AML, a reset controller's driver, the supplies, the driver host) behind
// protocols, so a host test drives it with a synthetic device.

import DeviceTreeBus

/// One step of a device's power-up, which is run in reverse to cut.
public enum PowerStep: Equatable, Sendable {
  /// An SCMI power domain.
  case domain(UInt32)
  /// An SCMI clock.
  case clock(UInt32)
  /// The device's ACPI power resources (_PR0 and its _DSD power-supply's).
  case resource
  /// A reset line on `service`'s controller.
  case reset(service: String, index: UInt32)

  /// Compared by bytes: a String's `==` pulls Unicode normalization into
  /// the image.
  public static func == (a: PowerStep, b: PowerStep) -> Bool {
    switch (a, b) {
    case (.domain(let x), .domain(let y)): return x == y
    case (.clock(let x), .clock(let y)): return x == y
    case (.resource, .resource): return true
    case (.reset(let s, let x), .reset(let t, let y)): return x == y && same(s, t)
    default: return false
    }
  }
}

/// What a step is asked of, and the line it is sent.
public struct PowerAction: Equatable, Sendable {
  public static func == (a: PowerAction, b: PowerAction) -> Bool {
    a.target == b.target && same(a.line, b.line) && same(a.name, b.name)
  }

  public enum Target: Equatable, Sendable {
    /// The SCMI agent's `ctl`.
    case scmi
    /// devmgr's own ACPI power for the device.
    case resource
    /// A reset controller's driver's `ctl`, by service.
    case provider(String)

    public static func == (a: Target, b: Target) -> Bool {
      switch (a, b) {
      case (.scmi, .scmi), (.resource, .resource): return true
      case (.provider(let x), .provider(let y)): return same(x, y)
      default: return false
      }
    }
  }

  public var target: Target
  /// The `ctl` line; for `.resource`, `on` or `off`.
  public var line: String
  /// What the status says of it.
  public var name: String

  public init(target: Target, line: String, name: String) {
    self.target = target
    self.line = line
    self.name = name
  }
}

public enum PowerOrder {
  /// How long a provider has to confirm a cut (D170 §5), in nanoseconds,
  /// and a device's supplies to end (§4).
  public static let deadline: Int64 = 500_000_000

  /// A device's steps in power-up order, from its `links`. `services[i]` is
  /// the service of `links[i]`'s provider where one runs, `""` where none.
  /// `clocks` names the clocks to turn on (all the device's where empty).
  /// Domains first, then clocks, then the power resources if `powered`,
  /// then resets, each kind in the order its links give.
  public static func steps(links: [DeviceLink], services: [String], clocks: [String], powered: Bool) -> [PowerStep] {
    var domains: [PowerStep] = [], clockSteps: [PowerStep] = [], resets: [PowerStep] = []
    var i = 0
    while i < links.count {
      let l = links[i]
      if same(l.kind, "power-domain"), let id = l.cells.first {
        domains.append(.domain(id))
      } else if same(l.kind, "clock"), let id = l.cells.first, named(l.name, clocks) {
        clockSteps.append(.clock(id))
      } else if same(l.kind, "reset"), let id = l.cells.first, i < services.count, !services[i].isEmpty {
        resets.append(.reset(service: services[i], index: id))
      }
      i += 1
    }
    return domains + clockSteps + (powered ? [.resource] : []) + resets
  }

  /// Whether `name` is one of `wanted`, or `wanted` is empty.
  static func named(_ name: String, _ wanted: [String]) -> Bool {
    if wanted.isEmpty { return true }
    var i = 0
    while i < wanted.count {
      if same(wanted[i], name) { return true }
      i += 1
    }
    return false
  }

  /// A device's reset links that no running provider serves (their
  /// `services` entry is empty): the power-up can't be done as the graph
  /// says.
  public static func unserved(links: [DeviceLink], services: [String]) -> [String] {
    var out: [String] = []
    var i = 0
    while i < links.count {
      if same(links[i].kind, "reset"), i >= services.count || services[i].isEmpty { out.append(links[i].name) }
      i += 1
    }
    return out
  }

  /// The action that turns `step` on; a reset is released, or pulsed for
  /// `pulse` microseconds where that is set (a reset a device needs
  /// asserted and released, not only released).
  public static func on(_ step: PowerStep, pulse: UInt32?) -> PowerAction {
    switch step {
    case .domain(let id): return PowerAction(target: .scmi, line: "power \(id) on", name: "power domain \(id)")
    case .clock(let id): return PowerAction(target: .scmi, line: "clock \(id) on", name: "clock \(id)")
    case .resource: return PowerAction(target: .resource, line: "on", name: "power resource")
    case .reset(let service, let index):
      let line = pulse.map { "reset \(index) pulse \($0)" } ?? "reset \(index) deassert"
      return PowerAction(target: .provider(service), line: line, name: "reset \(index)")
    }
  }

  /// The action that cuts `step`.
  public static func off(_ step: PowerStep) -> PowerAction {
    switch step {
    case .domain(let id): return PowerAction(target: .scmi, line: "power \(id) off", name: "power domain \(id)")
    case .clock(let id): return PowerAction(target: .scmi, line: "clock \(id) off", name: "clock \(id)")
    case .resource: return PowerAction(target: .resource, line: "off", name: "power resource")
    case .reset(let service, let index):
      return PowerAction(target: .provider(service), line: "reset \(index) assert", name: "reset \(index)")
    }
  }

  /// The cuts, in the reverse of the order the steps turned on.
  public static func cuts(_ steps: [PowerStep]) -> [PowerAction] { steps.reversed().map { off($0) } }

  /// The power-up, in order.
  public static func ups(_ steps: [PowerStep], pulse: UInt32?) -> [PowerAction] { steps.map { on($0, pulse: pulse) } }
}

/// What carries an action out. Each returns whether the owner took it.
public protocol PowerActuator {
  func run(_ action: PowerAction) -> Bool
}

/// The supplies devmgr holds for a device (D170 §2), ended before any
/// provider cuts and made again before it powers up. The held supplies
/// are `Supplies.swift`'s; this is what the order asks of them.
public protocol SupplyHolder {
  /// Ends every supply held for `service`, giving the host `deadlineNs`
  /// to release them; whether they all ended.
  func end(_ service: String, deadlineNs: Int64) -> Bool
  /// Makes the supplies for `service`'s next start, after a power-up.
  func renew(_ service: String)
}

/// A holder that holds nothing: a device with no bound windows has nothing
/// to end.
public struct NoSupplies: SupplyHolder {
  public init() {}
  public func end(_ service: String, deadlineNs: Int64) -> Bool { true }
  public func renew(_ service: String) {}
}

/// The driver host a device's driver runs in.
public protocol HostControl {
  /// Ends the host for good, and returns once it has.
  func endHost(_ service: String)
  /// Starts it again, and returns once it runs; whether it does.
  func startHost(_ service: String) -> Bool
}

/// A device devmgr powers, and where it stands (`/svc/devmgr/power`).
public struct PowerDevice: Sendable {
  public var service: String
  /// Its ACPI path, which `ctl` takes too.
  public var path: String
  public var steps: [PowerStep]
  public var pulse: UInt32?
  /// `on`, `off`, `failed` (a step didn't take: the device is down) or
  /// `stuck` (a provider didn't confirm a cut: the device stays down).
  public var state: String
  /// The last transition, `on` or `off` and how long it took, and when
  /// it ended on the monotonic clock, in milliseconds; empty before one.
  public var last = ""
  /// A step that failed or didn't confirm, or empty.
  public var detail = ""

  public init(service: String, path: String, steps: [PowerStep], pulse: UInt32?, state: String = "down") {
    self.service = service
    self.path = path
    self.steps = steps
    self.pulse = pulse
    self.state = state
  }
}

/// The devices devmgr powers by their graphs, and the transitions between
/// their states. Not locked: its caller serializes (one transition at a
/// time, devmgr's `ctl`).
public struct PowerController {
  public var devices: [PowerDevice] = []
  /// The monotonic clock, in nanoseconds.
  public var now: () -> Int64

  public init(now: @escaping () -> Int64) { self.now = now }

  /// The device `name` is, by service or ACPI path.
  public func index(of name: String) -> Int? {
    var i = 0
    while i < devices.count {
      if same(devices[i].service, name) || same(devices[i].path, name) { return i }
      i += 1
    }
    return nil
  }

  /// The device's steps run in order; the first that isn't taken stops it
  /// (the device stays down, `failed`, and the rest are not sent). Returns
  /// whether it is on.
  public mutating func powerUp<A: PowerActuator>(_ i: Int, _ actuator: A) -> Bool {
    let start = now()
    for a in PowerOrder.ups(devices[i].steps, pulse: devices[i].pulse) {
      if !actuator.run(a) {
        devices[i].state = "failed"
        devices[i].detail = "\(a.name) not turned on"
        devices[i].last = "on failed after \(ms(now() - start)) ms at \(ms(now())) ms"
        return false
      }
    }
    devices[i].state = "on"
    devices[i].detail = ""
    devices[i].last = "on \(ms(now() - start)) ms at \(ms(now())) ms"
    return true
  }

  /// Ends the device's supplies and its host, then asks each provider in
  /// reverse order to cut, each given 500 ms to confirm. Every cut is
  /// asked even after one that failed, so a device is left as far down
  /// as it can be; one that wasn't confirmed leaves it `stuck`, the name
  /// of the first in `detail`. Returns whether it is off.
  public mutating func powerDown<A: PowerActuator, S: SupplyHolder, H: HostControl>(
    _ i: Int, _ actuator: A, supplies: S, host: H
  ) -> Bool {
    let start = now()
    var problem = ""
    // A supply the host didn't release is the kernel's to take at the deadline.
    let late = supplies.end(devices[i].service, deadlineNs: PowerOrder.deadline) ? "" : "supplies taken at the deadline"
    host.endHost(devices[i].service)
    for a in PowerOrder.cuts(devices[i].steps) {
      let t = now()
      let taken = actuator.run(a)
      if (!taken || now() - t > PowerOrder.deadline) && problem.isEmpty {
        problem = taken ? "\(a.name) cut after more than 500 ms" : "\(a.name) not cut"
      }
    }
    devices[i].state = problem.isEmpty ? "off" : "stuck"
    devices[i].detail = problem.isEmpty ? late : problem
    devices[i].last = "off \(problem.isEmpty ? "" : "unconfirmed ")\(ms(now() - start)) ms at \(ms(now())) ms"
    return problem.isEmpty
  }

  /// `on` for a device that is down: the supplies made again, the steps
  /// in order, the host started. Returns whether it runs.
  public mutating func restore<A: PowerActuator, S: SupplyHolder, H: HostControl>(
    _ i: Int, _ actuator: A, supplies: S, host: H
  ) -> Bool {
    guard powerUp(i, actuator) else { return false }
    supplies.renew(devices[i].service)
    guard host.startHost(devices[i].service) else {
      devices[i].state = "failed"
      devices[i].detail = "its host did not start"
      return false
    }
    return true
  }

  /// A line for each device: `SERVICE STATE [last TRANSITION] [: DETAIL]`.
  public var text: String {
    var out = ""
    for d in devices {
      out += d.service + " " + d.state
      if !d.last.isEmpty { out += " last " + d.last }
      if !d.detail.isEmpty { out += ": " + d.detail }
      out += "\n"
    }
    return out
  }

  func ms(_ ns: Int64) -> Int64 { ns / 1_000_000 }
}

/// A `ctl` line: `power DEVICE on|off`.
public enum PowerCommand: Equatable, Sendable {
  case on(String)
  case off(String)

  public static func == (a: PowerCommand, b: PowerCommand) -> Bool {
    switch (a, b) {
    case (.on(let x), .on(let y)), (.off(let x), .off(let y)): return same(x, y)
    default: return false
    }
  }

  /// The command in `line`, or nil if it isn't one. DEVICE has no spaces.
  public static func parse(_ line: String) -> PowerCommand? {
    var words: [String] = []
    var word: [UInt8] = []
    for b in line.utf8 {
      if b == 0x20 || b == 0x09 {
        if !word.isEmpty { words.append(String(decoding: word, as: UTF8.self)) }
        word = []
      } else {
        word.append(b)
      }
    }
    if !word.isEmpty { words.append(String(decoding: word, as: UTF8.self)) }
    guard words.count == 3, same(words[0], "power") else { return nil }
    if same(words[2], "on") { return .on(words[1]) }
    if same(words[2], "off") { return .off(words[1]) }
    return nil
  }
}
