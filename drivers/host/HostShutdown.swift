// SPDX-License-Identifier: BSD-3-Clause

// What a driver host does before it ends with its supplies (D170, D173): a
// device that must be stopped while it still has power (an MCU that would
// otherwise lose its power running) adds a step, and the thread that waits
// for SUPPLY_ENDING runs the steps, then exits. A step is bounded by its own
// timeout: the supply's end is not postponed for it (devmgr cuts the power
// when its grace period is over, whatever the host does).

import Sys

public final class HostShutdown: @unchecked Sendable {
  /// The host's one list.
  public static let shared = HostShutdown()

  let lock = Lock()
  var steps: [(name: String, body: @Sendable () -> Void)] = []
  var ran = false

  public init() {}

  /// Adds a step. Steps run last added first (a driver adds the one that
  /// quiesces its device after the ones that depend on it).
  public func add(_ name: String, _ body: @escaping @Sendable () -> Void) {
    lock.withLock { steps.append((name, body)) }
  }

  /// The names of the steps added, in the order they will run.
  public var names: [String] { lock.withLock { steps.reversed().map { $0.name } } }

  /// Runs every step once, the last added first, and returns their names in
  /// the order they ran. A second call runs nothing and returns none: a step
  /// that started the end itself and the thread that waits for it are one
  /// end.
  @discardableResult
  public func run() -> [String] {
    let todo: [(name: String, body: @Sendable () -> Void)] = lock.withLock {
      if ran { return [] }
      ran = true
      return steps.reversed()
    }
    for step in todo { step.body() }
    return todo.map { $0.name }
  }
}
