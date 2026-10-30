// SPDX-License-Identifier: BSD-3-Clause

// cpu's terminal on a node (D75): `cpu -h NODE` runs rc on another node,
// as vx cpu does from the dev machine. It dials that node's cpu server,
// runs Noise IK as this node through factotum (prologue `cpu`), sends
// the command record (CpuProtocol), and then serves this namespace in
// 9P2000 over the same connection (gate(2)'s Export), which the other
// node mounts at /mnt/term: rc's text is this namespace's /dev/cons, the
// window's, so neither side has a pty. The notes this program takes, its
// window's interrupt, are read there from dev/cpunote, a stream added
// after this namespace's /dev, and posted to rc.

import CpuProtocol
import Gate
import IPC
import Node
import Sys

/// The notes for the other node's rc: dev/cpunote's stream, which gives
/// one note a read, waits while there are none, and ends with the
/// session.
public final class CpuNotes: @unchecked Sendable {
  let tree: NodeTree
  let lock = Lock()
  var waiting: [String] = []
  var ended = false
  var node: TreeNode?

  /// Its tree is served on `dispatcher`.
  public init(dispatcher: IPCDispatcher) {
    tree = NodeTree(dispatcher: dispatcher)
    node = tree.stream("cpunote", NodeStream(take: { [self] max in
      lock.withLock { () -> [UInt8]? in
        guard !waiting.isEmpty else { return ended ? [] : nil }
        return Array(waiting.removeFirst().utf8.prefix(max))
      }
    }))
  }

  /// Sends `note` to the other node's rc.
  public func post(_ note: String) {
    lock.withLock { waiting.append(note) }
    if let node { tree.ready(node) }
  }

  func end() {
    lock.withLock { ended = true }
    if let node { tree.ready(node) }
  }

  /// A channel to the directory holding cpunote.
  func channel() throws(Status) -> Handle {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return ends.a
  }
}

public enum CpuClient {
  /// The dial string for `host`: itself if it has a `!`, else its cpu
  /// server's, `tcp!HOST!17019`.
  public static func address(_ host: String) -> String {
    host.utf8.contains(0x21) ? host : "tcp!\(host)!\(CpuProtocol.port)"
  }

  /// Runs `command` on the node at `host`, whose key is `key`, rc -i if
  /// it is empty, serving `ns` as /mnt/term until the session ends: nil
  /// then, or why it couldn't start.
  public static func run(_ ns: Namespace, identity: Identity, host: String, key: [UInt8], command: String,
                         notes: CpuNotes) -> String? {
    let c: NetConnection
    do throws(DialError) { c = try ns.dial(address(host)) } catch { return error.reason }
    guard let stream = GateService.stream(ns, c) else { return "no data channel" }
    return session(stream, ns, identity: identity, key: key, command: command, notes: notes)
  }

  /// `run`'s session on `stream`, a connection to the node's cpu server.
  public static func session(_ stream: ByteStream, _ ns: Namespace, identity: Identity, key: [UInt8],
                             command: String, notes: CpuNotes) -> String? {
    guard let record = CpuProtocol.record(Array(command.utf8)) else {
      stream.close()
      return "command too long"
    }
    let sealed: ByteStream
    do throws(GateError) {
      sealed = try identity.initiate(stream, key, CpuProtocol.prologue)
      try sealed.write(record)
    } catch {
      stream.close()
      return GateService.text(error)
    }
    let exported: Namespace
    do throws(NamespaceError) {
      exported = try ns.clone()
      let dir: Handle
      do throws(Status) { dir = try notes.channel() } catch { throw .transport(error) }
      try exported.mount(dir, at: "/dev", .after)
    } catch {
      sealed.close()
      return "namespace: \(error.text)"
    }
    _ = Export.serve(sealed, namespace: exported, root: "/")
    notes.end()
    return nil
  }
}
