// SPDX-License-Identifier: BSD-3-Clause

// Environment groups (D81): a process's environment is the tree at its
// /env, a file a variable, as Plan 9's #e. The launcher serves them, on a
// dispatcher and thread of their own (a /svc tree forwards walks to
// /svc/env from the launcher's dispatcher, which can't wait on itself),
// each service's group made from its manifest's `env` lines
// before it starts. A value is stored as Plan 9's rc stores a list: each
// element followed by a NUL. A client creates, writes, cuts (wstat) and
// removes variables as files; `use env` grants /svc/env, whose `new` makes
// an empty group (rc's `rfork e`; `E` copies one into it). A group goes
// when its last channel closes.

import IPC
import Node
import Sys

public final class EnvGroups: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let lock = Lock()
  /// Groups with a channel open.
  var groups: [NodeTree] = []
  /// What `use env` grants: `new`.
  public let tree: NodeTree

  public init() throws(Status) {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    tree.service("new", connect: { [self] (channel: consuming Handle) throws(Status) in
      try make([]).serve(channel)
    })
  }

  /// Serves its groups on a thread of its own, for good.
  public func start() throws(Status) {
    let d = dispatcher
    _ = try Thread.spawn { _ = try? d.run() }.release()
  }

  /// A value as /env holds it: each element followed by a NUL.
  public static func value(_ elements: [String]) -> [UInt8] { elements.flatMap { Array($0.utf8) + [0] } }

  /// A new group holding `variables` (each a name and its elements),
  /// kept while a channel to it is open: serve it at once.
  public func make(_ variables: [(name: String, elements: [String])]) -> NodeTree {
    let group = NodeTree(dispatcher: dispatcher, rootAllowsCreate: true)
    for v in variables where NodeIPC.isValidName(v.name) {
      group.file(v.name, Self.value(v.elements), writable: true)
    }
    // Holding the group: the cycle ends when it does (no weak references
    // in Embedded Swift).
    group.lastClosed = { [self] in
      lock.withLock { groups.removeAll { $0 === group } }
      group.lastClosed = nil
    }
    lock.withLock { groups.append(group) }
    return group
  }

  /// A channel to a new group holding `variables`, for a service's /env.
  public func channel(_ variables: [(name: String, elements: [String])]) throws(Status) -> Handle {
    let ends = try Channel.create()
    try make(variables).serve(ends.b)
    return ends.a
  }

  /// How many groups are open.
  public var count: Int { lock.withLock { groups.count } }

  /// `NAME=value` lines (a manifest's `env`, the boot's parameters) as
  /// variables: the value one element.
  public static func variables(_ lines: [String]) -> [(name: String, elements: [String])] {
    lines.compactMap { line in
      let b = Array(line.utf8)
      guard let eq = b.firstIndex(of: UInt8(ascii: "=")), eq > 0 else { return nil }
      return (String(decoding: b[..<eq], as: UTF8.self), [String(decoding: b[(eq + 1)...], as: UTF8.self)])
    }
  }
}
