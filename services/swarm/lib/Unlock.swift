// SPDX-License-Identifier: BSD-3-Clause

// A member's half of unlocking another node's volume (D153 §3): on
// tcp!*!17021, unsealed and for any caller, since the node asking has
// no identity until its volume is open, a request is the member's mcr
// key and a blinded point, 64 bytes, and the answer factotum's point, 32
// (McCallum-Relyea: the request says nothing of the volume, and the
// answer opens it only for the node that blinded it). A request for
// another key, or one that isn't a point, is hung up on.

import Factotum
import IPC
import Node
import Sys

public final class UnlockAnswerer: @unchecked Sendable {
  public static let port = 17021
  static let pattern = "proto=mcr"

  let namespace: Namespace
  let path: String
  let log: @Sendable (String) -> Void
  /// factotum's mcr public key, made there if need be.
  public let publicKey: [UInt8]
  let lock = Lock()
  var answered = 0

  /// Answers with the key of the factotum at `path` in `namespace` (its
  /// AuthIPC.Factotum); nil if it has none to give.
  public init?(namespace: Namespace, factotum path: String = "/svc/factotum/auth",
               log: @escaping @Sendable (String) -> Void = { print("swarm: \($0)") }) {
    self.namespace = namespace
    self.path = path
    self.log = log
    guard var f = try? Self.connect(namespace, path), let key = try? f.publicKey(pattern: Self.pattern), key.count == 32
    else { return nil }
    publicKey = key
  }

  public var count: Int { lock.withLock { answered } }

  static func connect(_ namespace: Namespace, _ path: String) throws(NamespaceError) -> AuthIPC.FactotumClient {
    AuthIPC.FactotumClient(channel: try namespace.open(path).takeChannel())
  }

  /// Announces tcp!*!17021 and answers each request on a thread of its
  /// own, until the announcement fails. `ready` is called once it has
  /// said it is answering, or has failed to announce: a process's
  /// threads printing at once mix their lines.
  public func listen(ready: @Sendable () -> Void = {}) -> DialError {
    let a: NetAnnouncement
    do throws(DialError) { a = try namespace.announce("tcp!*!\(Self.port)") } catch {
      ready()
      return error
    }
    log("answering unlocks on tcp!*!\(Self.port)")
    ready()
    while true {
      let call: NetCall
      do throws(DialError) { call = try namespace.listen(a) } catch { return error }
      let c: NetConnection
      do throws(DialError) { c = try namespace.accept(call) } catch { continue }
      // The conversation's files opened anew (as 9gate's streams are), by
      // their channels' numbers into the thread.
      let dir = c.dir
      guard let ctl = try? namespace.open(dir + "/ctl"), let data = try? namespace.open(dir + "/data") else { continue }
      _ = consume c
      let raw = (ctl: ctl.takeChannel().release(), data: data.takeChannel().release())
      do throws(Status) {
        _ = try Thread.spawn { [self] in serve(ctl: Handle(raw: raw.ctl), data: Handle(raw: raw.data)) }.release()
      } catch {
        _ = Handle(raw: raw.ctl)
        _ = Handle(raw: raw.data)
      }
    }
  }

  /// One request: answered, then the conversation closed, so the answer
  /// goes before the end (TCP's `close`; `hangup` would cut it off), or
  /// hung up on.
  func serve(ctl: consuming Handle, data: consuming Handle) {
    var ctl = NodeIPC.NodeClient(channel: ctl), data = NodeIPC.NodeClient(channel: data)
    if let answer = answer(&data), (try? data.write(offset: 0, answer)) != nil {
      lock.withLock { answered += 1 }
      try? ctl.writeText("close")
      // Until the asker hangs up, having read it.
      _ = try? data.read(offset: 0, max: 1)
    }
    try? ctl.writeText("hangup")
  }

  /// The answer to the request read from `data`, or nil.
  func answer(_ data: inout NodeIPC.NodeClient) -> [UInt8]? {
    var request: [UInt8] = []
    while request.count < 64, let b = try? data.read(offset: 0, max: UInt32(64 - request.count)), !b.isEmpty {
      request += b
    }
    guard request.count == 64, Array(request[0..<32]) == publicKey else { return nil }
    return Self.ask(namespace, path, Array(request[32..<64]))
  }

  /// factotum's answer to the point `x`: a server-role mcr session.
  static func ask(_ namespace: Namespace, _ path: String, _ x: [UInt8]) -> [UInt8]? {
    guard var f = try? connect(namespace, path), let ends = try? Channel.create() else { return nil }
    let mine = ends.a, theirs = ends.b
    guard (try? f.startSession(pattern: pattern, role: .server, session: theirs)) != nil else { return nil }
    var s = AuthIPC.AuthSessionClient(channel: mine)
    guard let first = try? s.next(), first.kind == .send, let need = try? s.next(), need.kind == .need,
      (try? s.feed(x)) != nil, let reply = try? s.next(), reply.kind == .send, reply.bytes.count == 32
    else { return nil }
    return reply.bytes
  }
}
