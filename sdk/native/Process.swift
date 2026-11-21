// SPDX-License-Identifier: BSD-3-Clause

// The process the SDK runs in: its namespace, from its Startup, which the
// SDK reads the first time it needs it (a program built on the SDK never
// reads it itself), and its arguments.

import Node
import Sys

enum NativeProcess {
  /// The process's namespace, or nil if it was started without one (Node's, which FDIO and the GPU stack share).
  static var namespace: Namespace? { Namespace.process }
}

/// The process's namespace (libraries find their services through it).
public func processNamespace() -> Namespace? { NativeProcess.namespace }

/// The arguments the process was started with, its name first (its
/// manifest's `program` and `arg`s).
public func processArguments() -> [String] { Startup.current.args }
