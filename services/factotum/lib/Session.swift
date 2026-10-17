// SPDX-License-Identifier: BSD-3-Clause

// factotum's core (D75; todhchai's keyring): its keys, and the
// authentication sessions apps run against them. An app starts a session
// with a pattern and a role; factotum finds the key (within the app's
// scope, from its manifest's grants), asks the user first if the key
// says so, and runs the protocol, the app passing bytes between the
// session and its peer:
//
//     loop: next() -> send(bytes)  give them to the peer
//                     need         feed(the peer's next message)
//                     needKey      the user is asked for a key; wait
//                     needConfirm  the user is asked; wait
//                     done(result)
//
// The waits end when the user answers (`confirm`, or a key added): the
// service tells the app with an event. A headless factotum has no one to
// ask: its service answers no (D75). Tier 0, tested hosted; bin/factotum
// serves it.

import Noise
import TDCrypto

/// What a session asks of the app next.
public enum Step: Equatable, Sendable {
  case send([UInt8])
  case need
  /// No key matches this pattern: the user is asked to add one.
  case needKey(KeyPattern)
  /// The user is asked to allow the key's use (the prompt's text).
  case needConfirm(String)
  case done(AuthResult)
}

public enum Role: Sendable { case client, server }

/// A question for the user, while a session waits on it.
public enum Question: Equatable, Sendable {
  /// `app` wants to use a key (shown with its secrets hidden).
  case confirm(app: String, key: String)
  /// `app` needs a key matching the pattern.
  case key(app: String, pattern: String)

  /// What the trusted prompt says.
  public var text: String {
    switch self {
    case .confirm(let app, let key): "\(app) wants to use the key \(key)"
    case .key(let app, let pattern): "\(app) needs a key: \(pattern)"
    }
  }
}

/// factotum: its keys, and what each app has been allowed once.
public final class Factotum {
  public var store = KeyStore()
  /// `confirm=once` keys an app may use without asking again: (app, the
  /// key's public text).
  var allowed: [(String, String)] = []
  /// Nonces for SCRAM: printable, no commas (the service's from croi's
  /// CPRNG; a test's fixed).
  public var nonce: () -> String
  /// N bytes from croi's CPRNG, for keys factotum makes (proto=ed25519,
  /// proto=noise-ik) and noise-ik's ephemerals; nil: it makes none.
  public var random: ((Int) -> [UInt8])?

  public init(nonce: @escaping () -> String, random: ((Int) -> [UInt8])? = nil) {
    self.nonce = nonce
    self.random = random
  }

  /// A session for `app`, whose scope (its manifest's patterns; empty:
  /// anything) must allow `pattern`.
  public func start(_ pattern: KeyPattern, role: Role, app: String, scope: [KeyPattern]) throws(AuthFailure)
    -> AuthSession
  {
    guard scope.isEmpty || scope.contains(where: { pattern.within($0) }) else { throw .notAllowed }
    guard let proto = pattern["proto"], Self.protocols.contains(where: { same(proto, $0) }) else {
      throw .unsupported
    }
    if same(proto, "pass") && role == .server { throw .unsupported }
    if same(proto, "ed25519") && role == .client { throw .unsupported }
    return AuthSession(factotum: self, pattern: pattern, role: role, app: app)
  }

  static let protocols = ["pass", "scram-sha-256", "ed25519", "noise-ik"]

  /// The public half of the key `pattern` names (made if need be, as a
  /// session would): ed25519's and noise-ik's, for an app to give its
  /// peers.
  public func publicKey(_ pattern: KeyPattern, app: String, scope: [KeyPattern]) throws(AuthFailure) -> [UInt8] {
    guard scope.isEmpty || scope.contains(where: { pattern.within($0) }) else { throw .notAllowed }
    if same(pattern["proto"], "noise-ik") { return StaticKey(privateKey: try noiseKey(pattern)).publicKey }
    if same(pattern["proto"], "ed25519") { return Ed25519.publicKey(seed: try signingKey(pattern)) }
    throw .unsupported
  }

  /// Whether using `key` needs the user's yes: its `confirm`, else its
  /// protocol's default (`pass` reveals the secret: always).
  func needsConfirmation(_ key: Key, app: String) -> Bool {
    let confirm = key["confirm"] ?? (same(key.proto, "pass") ? "always" : "never")
    if same(confirm, "never") { return false }
    if same(confirm, "once") { return !allowed.contains { same($0.0, app) && same($0.1, key.shown) } }
    return true
  }
}

public final class AuthSession {
  enum Machine {
    case pass(AuthResult, done: Bool)
    case client(ScramClient)
    case server(ScramServer)
    case signer(Signer)
    case noise(NoiseMachine)
  }
  enum Phase {
    /// Looking for the key (again, once the user has added one).
    case finding
    case confirming(Key)
    case running(Machine)
    case failed(AuthFailure)
  }

  let factotum: Factotum
  public let pattern: KeyPattern
  public let role: Role
  public let app: String
  var phase = Phase.finding
  /// What the user is being asked, while the session waits.
  public private(set) var question: Question?

  init(factotum: Factotum, pattern: KeyPattern, role: Role, app: String) {
    self.factotum = factotum
    self.pattern = pattern
    self.role = role
    self.app = app
  }

  public func next() throws(AuthFailure) -> Step {
    switch phase {
    case .failed(let f): throw f
    case .finding:
      if role == .server { return try run(server()) }
      // noise-ik's key is the node's, made if need be, in either role.
      if same(pattern["proto"], "noise-ik") { return try run(noise()) }
      // (A server's keys aren't a client's.)
      guard let key = factotum.store.matching(pattern).first(where: { !same($0["role"], "server") }) else {
        question = .key(app: app, pattern: pattern.text)
        return .needKey(pattern)
      }
      question = nil
      if factotum.needsConfirmation(key, app: app) {
        phase = .confirming(key)
        question = .confirm(app: app, key: key.shown)
        return .needConfirm(question!.text)
      }
      return try run(machine(key))
    case .confirming:
      return .needConfirm(question?.text ?? "")
    case .running(var m):
      let step: MachineStep
      switch m {
      case .pass(let r, let done):
        if done { throw .order }
        m = .pass(r, done: true)
        step = .done(r)
      case .client(var c):
        step = c.next()
        m = .client(c)
      case .server(var s):
        step = s.next()
        m = .server(s)
      case .signer(var s):
        step = s.next()
        m = .signer(s)
      case .noise(var n):
        step = n.next()
        m = .noise(n)
      }
      phase = .running(m)
      switch step {
      case .send(let b): return .send(b)
      case .need: return .need
      case .done(let r): return .done(r)
      }
    }
  }

  public func feed(_ message: [UInt8]) throws(AuthFailure) {
    guard case .running(var m) = phase else {
      if case .failed(let f) = phase { throw f }
      throw .order
    }
    do throws(AuthFailure) {
      switch m {
      case .pass: throw .order
      case .client(var c):
        try c.feed(message)
        m = .client(c)
      case .server(var s):
        try s.feed(message)
        m = .server(s)
      case .signer(var s):
        try s.feed(message)
        m = .signer(s)
      case .noise(var n):
        try n.feed(message)
        m = .noise(n)
      }
      phase = .running(m)
    } catch {
      phase = .failed(error)
      throw error
    }
  }

  /// The user's answer to `.confirm`.
  public func confirm(_ yes: Bool) {
    guard case .confirming(let key) = phase else { return }
    question = nil
    if !yes {
      phase = .failed(.denied)
      return
    }
    if same(key["confirm"], "once") { factotum.allowed.append((app, key.shown)) }
    phase = .running(machine(key))
  }

  /// A key the session asked for was added: it looks again at `next`.
  public func keyArrived() {
    if case .key? = question { question = nil }
  }

  /// The user won't add the key asked for.
  public func declineKey() {
    guard case .finding = phase, question != nil else { return }
    question = nil
    phase = .failed(.noKey)
  }

  func run(_ m: Machine) throws(AuthFailure) -> Step {
    phase = .running(m)
    return try next()
  }

  func machine(_ key: Key) -> Machine {
    let peer = key["server"] ?? key["service"] ?? key["dom"] ?? ""
    let user = key["user"] ?? ""
    let secret = Array((key["password"] ?? "").utf8)
    if same(key.proto, "pass") { return .pass(AuthResult(user: user, peer: peer, secret: secret), done: false) }
    return .client(ScramClient(user: user, password: secret, peer: peer, nonce: factotum.nonce()))
  }

  /// A server's machine: its keys are found by the client's user name,
  /// each `role=server` with the user's password, `salt` (base64) and
  /// `i` (iterations).
  func server() throws(AuthFailure) -> Machine {
    if same(pattern["proto"], "ed25519") {
      return .signer(Signer(seed: try factotum.signingKey(pattern), peer: pattern["service"] ?? ""))
    }
    if same(pattern["proto"], "noise-ik") { return try noise() }
    let keys = factotum.store.matching(pattern.with("role", "server"))
    guard !keys.isEmpty else { throw .noKey }
    let peer = pattern["server"] ?? ""
    return .server(ScramServer(peer: peer, nonce: factotum.nonce()) { user in
      guard let k = keys.first(where: { same($0["user"], user) }), let p = k["password"],
        let salt = k["salt"].flatMap({ Base64.decode($0) }), let i = k["i"].flatMap({ Int($0) })
      else { return nil }
      return (Array(p.utf8), salt, i)
    })
  }

  /// noise-ik's machine, with the node's key: the responder's for a
  /// server-role session, the initiator's for a client's.
  func noise() throws(AuthFailure) -> Machine {
    guard let random = factotum.random else { throw .noKey }
    return .noise(NoiseMachine(privateKey: try factotum.noiseKey(pattern), initiator: role == .client, random: random))
  }
}
