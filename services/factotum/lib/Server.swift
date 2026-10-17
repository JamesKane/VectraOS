// SPDX-License-Identifier: BSD-3-Clause

// factotum served (D75; todhchai's keyring): its own tree's `clients`
// node, which the launcher alone reaches (factotum's manifest: `export
// per-client`), opens a tree for each service that uses it, named for
// that service and scoped by its manifest's `grant factotum` lines:
//
//     grant factotum proto=noise-ik                   a pattern its
//                                                     sessions must stay within
//     grant factotum admin                            `ctl` too: factotum's
//
// A client's tree has `auth` (AuthIPC.Factotum: its sessions, each an
// AuthSession on the dispatcher) and, with `admin`, `ctl` (reading lists
// the keys with secrets hidden; writing `key ...` or `delkey ...`). A
// session that waits on the user puts its question in `questions`, for
// the prompt (`onQuestions` tells it); `answer` takes the user's reply
// from any thread, and the session's `answered` event goes to its app
// on the dispatcher's thread. A key added (by the prompt or `ctl`) ends
// the waits it answers. Tier 0; tested hosted.

import IPC
import Node
import Sys

public final class FactotumState: @unchecked Sendable {
  public let dispatcher: IPCDispatcher
  let lock = Lock()
  let factotum: Factotum
  /// Live sessions, by the dispatcher's id for each.
  var sessions: [(id: UInt64, session: AuthSession)] = []
  /// Called (on any thread) when the questions change: the prompt looks
  /// again.
  public var onQuestions: @Sendable () -> Void = {}

  public init(dispatcher: IPCDispatcher, nonce: @escaping () -> String, random: ((Int) -> [UInt8])? = nil) {
    self.dispatcher = dispatcher
    factotum = Factotum(nonce: nonce, random: random)
  }

  func locked<R>(_ body: () throws(AuthFailure) -> R) throws(AuthFailure) -> R {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// What the user is being asked, each with its session's id.
  public var questions: [(id: UInt64, question: Question)] {
    (try? locked { sessions.compactMap { s in s.session.question.map { (s.id, $0) } } }) ?? []
  }

  /// The user's answer to a `.confirm` question.
  public func answer(_ id: UInt64, confirm: Bool) {
    _ = try? locked {
      sessions.first { $0.id == id }?.session.confirm(confirm)
    }
    dispatcher.wake(id)
    onQuestions()
  }

  /// The user's answer to a `.key` question: the key's user name and
  /// password (added with the pattern's attributes), or nil to decline.
  public func answer(_ id: UInt64, user: String?, password: String?) {
    let woken: [UInt64] = (try? locked { () throws(AuthFailure) -> [UInt64] in
      guard let s = sessions.first(where: { $0.id == id })?.session else { return [] }
      guard let password else {
        s.declineKey()
        return [id]
      }
      var attributes: [KeyAttribute] = []
      for t in s.pattern.terms {
        if let v = t.value { attributes.append(KeyAttribute(t.name, v)) }
      }
      if let user, !user.isEmpty, !attributes.contains(where: { same($0.name, "user") }) {
        attributes.append(KeyAttribute("user", user))
      }
      attributes.append(KeyAttribute("password", password, secret: true))
      factotum.store.add(Key(attributes))
      return answeredByKeys()
    }) ?? []
    for w in woken { dispatcher.wake(w) }
    onQuestions()
  }

  /// Under the lock: sessions asking for a key the store now has. Their
  /// questions end; their apps are told.
  func answeredByKeys() -> [UInt64] {
    var woken: [UInt64] = []
    for s in sessions {
      if case .key? = s.session.question, !factotum.store.matching(s.session.pattern).isEmpty {
        s.session.keyArrived()
        woken.append(s.id)
      }
    }
    return woken
  }

  /// The keys, secrets hidden.
  public var listing: String { (try? locked { factotum.store.listing }) ?? "" }

  /// Factotum's ctl line.
  public func control(_ line: String) throws(KeyError) -> String {
    lock.lock()
    let result: Result<String, KeyError>
    do throws(KeyError) { result = .success(try factotum.store.control(line)) } catch { result = .failure(error) }
    let woken = answeredByKeys()
    lock.unlock()
    for w in woken { dispatcher.wake(w) }
    if !woken.isEmpty { onQuestions() }
    return try result.get()
  }

  /// Serves factotum's own tree's `clients` node on `channel`.
  public func serveClients(_ channel: consuming Handle) throws(Status) {
    try dispatcher.add(LaunchIPC.ClientsServer(channel: channel, impl: ClientsHandler(state: self)))
  }

  /// A client's tree, on `node`.
  func open(client: String, grants: [String], node: consuming Handle) throws(KeyError) {
    var scope: [KeyPattern] = []
    var admin = false
    for g in grants {
      if same(g, "admin") { admin = true } else { scope.append(try KeyPattern(g)) }
    }
    let tree = NodeTree(dispatcher: dispatcher)
    let app = client, frozen = scope
    tree.service("auth") { [self] (channel: consuming Handle) throws(Status) in
      try dispatcher.add(AuthIPC.FactotumServer(channel: channel, impl: FactotumHandler(state: self, app: app, scope: frozen)))
    }
    if admin {
      tree.text("ctl", read: { [self] in listing }, write: { [self] (line: String) throws(NodeError) in
        do throws(KeyError) { _ = try control(line) } catch { throw .invalid }
      })
    }
    do throws(Status) { try tree.serve(node) } catch { throw .syntax("can't serve") }
  }

  /// Starts a session for `app` and serves it on `channel`.
  func start(app: String, scope: [KeyPattern], pattern text: String, role: AuthIPC.Role, channel: consuming Handle)
    throws(AuthIPC.AuthError)
  {
    guard let pattern = try? KeyPattern(text) else { throw .invalid }
    let session: AuthSession
    do throws(AuthFailure) {
      session = try locked { () throws(AuthFailure) -> AuthSession in
        try factotum.start(pattern, role: role == .server ? .server : .client, app: app, scope: scope)
      }
    } catch {
      throw Self.error(error)
    }
    let handler = SessionHandler(state: self, session: session)
    do throws(Status) {
      let id = try dispatcher.add(AuthIPC.AuthSessionServer(channel: channel, impl: handler)) {
        (s: inout AuthIPC.AuthSessionServer<SessionHandler>) throws(IPCError<Never>) in
        try AuthIPC.AuthSessionEventSender.sendAnswered(on: s.connection)
      }
      handler.id = id
      _ = try? locked { sessions.append((id, session)) }
    } catch {
      throw .invalid
    }
  }

  /// A session's channel closed: it's gone, and so is its question.
  func ended(_ id: UInt64) {
    let had = (try? locked { () -> Bool in
      let asked = sessions.contains { $0.id == id && $0.session.question != nil }
      sessions.removeAll { $0.id == id }
      return asked
    }) ?? false
    if had { onQuestions() }
  }

  static func error(_ f: AuthFailure) -> AuthIPC.AuthError {
    switch f {
    case .noKey: .noKey
    case .denied: .denied
    case .notAllowed: .notAllowed
    case .unsupported: .unsupported
    case .peer: .peer
    case .order: .invalid
    }
  }
}

struct ClientsHandler: LaunchIPC.ClientsHandler {
  let state: FactotumState
  func open(client: String, grants: [String], node: consuming Handle) throws(LaunchIPC.ClientsError) {
    do throws(KeyError) { try state.open(client: client, grants: grants, node: node) } catch { throw .refused }
  }
}

struct FactotumHandler: AuthIPC.FactotumHandler {
  let state: FactotumState
  let app: String
  let scope: [KeyPattern]
  func startSession(pattern: String, role: AuthIPC.Role, session: consuming Handle) throws(AuthIPC.AuthError) {
    try state.start(app: app, scope: scope, pattern: pattern, role: role, channel: session)
  }

  func publicKey(pattern: String) throws(AuthIPC.AuthError) -> [UInt8] {
    guard let p = try? KeyPattern(pattern) else { throw .invalid }
    do throws(AuthFailure) {
      return try state.locked { () throws(AuthFailure) -> [UInt8] in
        try state.factotum.publicKey(p, app: app, scope: scope)
      }
    } catch {
      throw FactotumState.error(error)
    }
  }
}

final class SessionHandler: AuthIPC.AuthSessionHandler {
  let state: FactotumState
  let session: AuthSession
  var id: UInt64 = 0
  var failed = ""

  init(state: FactotumState, session: AuthSession) {
    self.state = state
    self.session = session
  }

  deinit { state.ended(id) }

  func next() throws(AuthIPC.AuthError) -> AuthIPC.Step {
    let step: Step
    do throws(AuthFailure) {
      step = try state.locked { () throws(AuthFailure) -> Step in try session.next() }
    } catch {
      if case .peer(let why) = error { failed = why }
      throw FactotumState.error(error)
    }
    func s(_ kind: AuthIPC.StepKind, bytes: [UInt8] = [], text: String = "", result: AuthResult? = nil) -> AuthIPC.Step {
      AuthIPC.Step(kind: kind, bytes: result?.bytes ?? bytes, text: text, user: result?.user ?? "",
                   peer: result?.peer ?? "", secret: result?.secret ?? [])
    }
    switch step {
    case .send(let b): return s(.send, bytes: b)
    case .need: return s(.need)
    case .needKey(let p):
      state.onQuestions()
      return s(.needKey, text: p.text)
    case .needConfirm(let t):
      state.onQuestions()
      return s(.needConfirm, text: t)
    case .done(let r): return s(.done, result: r)
    }
  }

  func feed(_ message: [UInt8]) throws(AuthIPC.AuthError) {
    do throws(AuthFailure) {
      try state.locked { () throws(AuthFailure) in try session.feed(message) }
    } catch {
      if case .peer(let why) = error { failed = why }
      throw FactotumState.error(error)
    }
  }

  func failure() -> String { failed }
}
