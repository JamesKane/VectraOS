// SPDX-License-Identifier: BSD-3-Clause

// What a process's Startup (D65) says of Node: its namespace, as PA_NS_DIR
// handles each naming its path in the names table; its export, the server
// end of its own tree; and the session board. A launcher adds them, the
// process reads them back first thing:
//
//     let start = Startup.current
//     let ns = try Namespace(start)
//     if let export = start.export() { try tree.serve(export) }

import IPC

extension Startup {
  /// A namespace entry's info word: `index` into the names table, the
  /// union placement and whether it is marked for creating.
  static func nsInfo(_ index: Int, _ placement: Namespace.Placement, _ create: Bool) -> UInt32 {
    let p: UInt32 = switch placement {
    case .replace: 0
    case .before: 1
    case .after: 2
    }
    return HandleType.info(HandleType.nsDir, UInt32(index) | p << 12 | (create ? 1 << 14 : 0))
  }

  /// Adds `channel` (a Node channel) to the namespace at `path`.
  public func mount(_ channel: consuming Handle, at path: String, _ placement: Namespace.Placement = .replace,
                    create: Bool = false) {
    names.append(path)
    add(channel, info: Self.nsInfo(names.count - 1, placement, create))
  }

  /// The channel to serve this process's own Node tree on, once.
  public func export() -> Handle? { take(HandleType.info(HandleType.export)) }

  /// The session's board, to post to /srv, once.
  public func board() -> SrvIPC.BoardClient? {
    guard let channel = take(HandleType.info(HandleType.srvBoard)) else { return nil }
    return SrvIPC.BoardClient(channel: channel)
  }
}

extension Namespace {
  /// The namespace `startup` gives: each PA_NS_DIR handle mounted at its
  /// name, in the order given (a union's members in theirs).
  public convenience init(_ startup: Startup) throws(NamespaceError) {
    self.init()
    let names = startup.names
    for info in startup.infos where info & 0xFF == HandleType.nsDir {
      let argument = info >> 16, index = Int(argument & 0xFFF)
      guard index < names.count, let channel = startup.take(info) else { throw .badPath }
      let placement: Placement = switch (argument >> 12) & 3 {
      case 1: .before
      case 2: .after
      default: .replace
      }
      try mount(channel, at: names[index], placement, create: argument & (1 << 14) != 0)
    }
  }
}
