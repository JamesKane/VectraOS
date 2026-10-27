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
  /// union placement, whether it is marked for creating, and whether the
  /// namespace is sealed (any entry says so for all).
  static func nsInfo(_ index: Int, _ placement: Namespace.Placement, _ create: Bool, _ sealed: Bool) -> UInt32 {
    let p: UInt32 = switch placement {
    case .replace: 0
    case .before: 1
    case .after: 2
    }
    return HandleType.info(HandleType.nsDir, UInt32(index) | p << 12 | (create ? 1 << 14 : 0) | (sealed ? 1 << 15 : 0))
  }

  /// Adds `channel` (a Node channel) to the namespace at `path`; `sealed`:
  /// the namespace is (Namespace.seal: Plan 9's RFNOMNT, inherited).
  /// `reconnect`, the launcher's forwarder for a service's mount, goes
  /// with it as PA_NS_RECONNECT.
  public func mount(_ channel: consuming Handle, at path: String, _ placement: Namespace.Placement = .replace,
                    create: Bool = false, sealed: Bool = false, reconnect: consuming Handle? = nil) {
    names.append(path)
    let info = Self.nsInfo(names.count - 1, placement, create, sealed)
    add(channel, info: info)
    if let reconnect { add(reconnect, info: HandleType.info(HandleType.nsReconnect, info >> 16)) }
  }

  /// Adds `namespace` whole, for a child: each mount point, and each
  /// member of a union in its order, a new channel to the same node (and
  /// a forwarder of its own, where one reconnects), sealed if `namespace`
  /// is. Each is a clone, sent without waiting for its server.
  public func mount(_ namespace: Namespace) throws(NamespaceError) {
    let sealed = namespace.sealed
    for m in namespace.locked({ namespace.mounts }) {
      for (i, member) in m.members.enumerated() {
        let channel: Handle
        var forwarder: Handle? = nil
        do throws(NodeIPC.NodeClient.Failure) {
          forwarder = try member.forwarder()
          channel = try member.clone()
        } catch {
          throw NamespaceError(error)
        }
        mount(channel, at: "/" + m.path.joined(separator: "/"), i == 0 ? .replace : .after,
              create: member.create, sealed: sealed, reconnect: forwarder)
      }
    }
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
  /// name, in the order given (a union's members in theirs), with the
  /// PA_NS_RECONNECT of the same argument if there is one, sealed if one
  /// says so.
  public convenience init(_ startup: Startup) throws(NamespaceError) {
    self.init()
    let names = startup.names
    let sealed = startup.infos.contains { $0 & 0xFF == HandleType.nsDir && ($0 >> 16) & (1 << 15) != 0 }
    for info in startup.infos where info & 0xFF == HandleType.nsDir {
      let argument = info >> 16, index = Int(argument & 0xFFF)
      guard index < names.count, let channel = startup.take(info) else { throw .badPath }
      let placement: Placement = switch (argument >> 12) & 3 {
      case 1: .before
      case 2: .after
      default: .replace
      }
      try mount(channel, at: names[index], placement, create: argument & (1 << 14) != 0,
                reconnect: startup.take(HandleType.info(HandleType.nsReconnect, argument)))
    }
    if sealed { seal() }
  }
}
