// SPDX-License-Identifier: BSD-3-Clause

// The process the SDK runs in: its namespace, from its Startup, which the
// SDK reads the first time it needs it (a program built on the SDK never
// reads it itself), and its arguments.

import Node
import Sys

enum NativeProcess {
  nonisolated(unsafe) static var cached: Namespace?
  nonisolated(unsafe) static var looked = false

  /// The process's namespace, or nil if it was started without one.
  static var namespace: Namespace? {
    if !looked {
      looked = true
      cached = try? Namespace(Startup.current)
    }
    return cached
  }
}

/// The process's namespace (libraries find their services through it).
public func processNamespace() -> Namespace? { NativeProcess.namespace }

/// The arguments the process was started with, its name first (its
/// manifest's `program` and `arg`s).
public func processArguments() -> [String] { Startup.current.args }
