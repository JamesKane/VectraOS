// SPDX-License-Identifier: BSD-3-Clause

// The keyring's core (M6k part k4b): factotum's keys and patterns, base64
// (RFC 4648's vectors), SCRAM-SHA-256 against RFC 7677's example exchange
// byte for byte in both roles, a client keyring against a server one, a
// wrong password, a forged signature and malformed peers refused, and
// the sessions' scope, confirmation and missing keys.

@testable import Keyring
import TDCrypto
import Testing

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

// MARK: Keys and patterns

@Test func keysHideTheirSecrets() throws {
  var store = KeyStore()
  #expect(try store.control("key proto=pass service=imap user=jk 'note=two words' !password='it''s'") == "added")
  let k = try #require(store.keys.first)
  #expect(k["password"] == "it's" && k["note"] == "two words")
  #expect(store.listing == "key proto=pass service=imap user=jk note='two words' !password?\n")
  // The same public attributes replace the key.
  _ = try store.control("key proto=pass service=imap user=jk 'note=two words' !password=new")
  #expect(store.keys.count == 1 && store.keys[0]["password"] == "new")
  _ = try store.control("key proto=pass service=smtp user=jk !password=x")
  #expect(try store.control("delkey service=imap") == "deleted 1" && store.keys.count == 1)
  #expect(throws: KeyError.self) { try store.control("key user=jk") }  // no proto
  #expect(throws: KeyError.self) { try store.control("key proto=pass 'unfinished") }
}

@Test func patternsMatchAndScope() throws {
  let k = try Key(parsing: "proto=pass service=imap server=mail.example user=jk !password=secret")
  #expect(try KeyPattern("proto=pass server=mail.example user?").matches(k))
  #expect(try !KeyPattern("proto=pass user=other").matches(k))
  #expect(try KeyPattern("password?").matches(k))
  // A secret's value can't be tested.
  #expect(try !KeyPattern("password=secret").matches(k))
  let scope = try KeyPattern("proto=pass server=mail.example")
  #expect(try KeyPattern("proto=pass server=mail.example user?").within(scope))
  #expect(try !KeyPattern("proto=pass user?").within(scope))
  #expect(try !KeyPattern("proto=pass server=other.example").within(scope))
}

@Test func base64IsRFC4648s() {
  for (plain, coded) in [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="),
                         ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy")] {
    #expect(Base64.encode(bytes(plain)) == coded)
    #expect(Base64.decode(coded) == bytes(plain))
  }
  for bad in ["Zg=", "Zh==", "Z===", "Zm9v!A==", "=Zm9"] { #expect(Base64.decode(bad) == nil, "\(bad)") }
}

// MARK: SCRAM-SHA-256

/// RFC 7677 §3's exchange: user "user", password "pencil".
enum RFC7677 {
  static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
  static let serverNonce = "%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
  static let clientFirst = "n,,n=user,r=rOprNGfwEbeRWgbNEkqO"
  static let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
  static let clientFinal =
    "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
  static let serverFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
}

func keyring(_ keys: [String], nonce: String) throws -> Keyring {
  let k = Keyring(nonce: { nonce })
  for key in keys { k.store.add(try Key(parsing: key)) }
  return k
}

@Test func scramsClientIsRFC7677s() throws {
  let k = try keyring(["proto=scram-sha-256 server=example user=user !password=pencil"], nonce: RFC7677.clientNonce)
  let s = try k.start(KeyPattern("proto=scram-sha-256 server=example"), role: .client, app: "mail", scope: [])
  #expect(try s.next() == .send(bytes(RFC7677.clientFirst)))
  #expect(try s.next() == .need)
  try s.feed(bytes(RFC7677.serverFirst))
  #expect(try s.next() == .send(bytes(RFC7677.clientFinal)))
  try s.feed(bytes(RFC7677.serverFinal))
  #expect(try s.next() == .done(AuthResult(user: "user", peer: "example", secret: [])))
}

@Test func scramsServerIsRFC7677s() throws {
  let k = try keyring(["proto=scram-sha-256 role=server server=example user=user !password=pencil salt=W22ZaJ0SNY7soEsUEjb6gQ== i=4096"],
                      nonce: RFC7677.serverNonce)
  let s = try k.start(KeyPattern("proto=scram-sha-256 server=example"), role: .server, app: "imapd", scope: [])
  #expect(try s.next() == .need)
  try s.feed(bytes(RFC7677.clientFirst))
  #expect(try s.next() == .send(bytes(RFC7677.serverFirst)))
  try s.feed(bytes(RFC7677.clientFinal))
  #expect(try s.next() == .send(bytes(RFC7677.serverFinal)))
  #expect(try s.next() == .done(AuthResult(user: "user", peer: "example", secret: [])))
}

/// Runs a client session against a server session; the client's result,
/// or the first failure and which side had it.
func exchange(_ c: AuthSession, _ s: AuthSession) -> Result<AuthResult, AuthFailure> {
  var toServer: [[UInt8]] = [], toClient: [[UInt8]] = []
  for _ in 0..<10 {
    do throws(AuthFailure) {
      switch try c.next() {
      case .send(let b): toServer.append(b)
      case .done(let r): return .success(r)
      case .need: if !toClient.isEmpty { try c.feed(toClient.removeFirst()) }
      default: return .failure(.order)
      }
      switch try s.next() {
      case .send(let b): toClient.append(b)
      case .need: if !toServer.isEmpty { try s.feed(toServer.removeFirst()) }
      case .done: break
      default: return .failure(.order)
      }
    } catch {
      return .failure(error)
    }
  }
  return .failure(.order)
}

@Test func aClientKeyringAuthenticatesToAServerKeyring() throws {
  var n = 0
  let nonces = { () -> String in
    n += 1
    return "nonce\(n)xyz"
  }
  let server = Keyring(nonce: nonces), client = Keyring(nonce: nonces)
  server.store.add(try Key(parsing: "proto=scram-sha-256 role=server server=db user='a,b=c' !password=hunter2 salt=c2FsdHNhbHQ= i=4096"))
  client.store.add(try Key(parsing: "proto=scram-sha-256 server=db user='a,b=c' !password=hunter2"))
  let pattern = try KeyPattern("proto=scram-sha-256 server=db")
  let ok = exchange(try client.start(pattern, role: .client, app: "psql", scope: []),
                    try server.start(pattern, role: .server, app: "db", scope: []))
  #expect(ok == .success(AuthResult(user: "a,b=c", peer: "db", secret: [])))
  // A wrong password: the server refuses the proof.
  client.store.add(try Key(parsing: "proto=scram-sha-256 server=db user='a,b=c' !password=hunter3"))
  let wrong = exchange(try client.start(pattern, role: .client, app: "psql", scope: []),
                       try server.start(pattern, role: .server, app: "db", scope: []))
  #expect(wrong == .failure(.peer("the proof is wrong")))
}

@Test func aClientRefusesABadServer() throws {
  func client() throws -> AuthSession {
    let k = try keyring(["proto=scram-sha-256 server=example user=user !password=pencil"], nonce: RFC7677.clientNonce)
    let s = try k.start(KeyPattern("proto=scram-sha-256"), role: .client, app: "mail", scope: [])
    _ = try s.next()
    return s
  }
  // A forged signature: the server didn't know the password.
  let forged = try client()
  try forged.feed(bytes(RFC7677.serverFirst))
  _ = try forged.next()
  #expect(throws: AuthFailure.peer("the server's signature is wrong")) {
    try forged.feed(bytes("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
  }
  #expect(throws: AuthFailure.peer("the server's signature is wrong")) { try forged.next() }
  // A nonce that isn't ours extended, too few iterations, an extension it
  // must understand, an error.
  for (bad, why) in [("r=someoneelse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "the server's nonce doesn't extend ours"),
                     ("r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000", "an iteration count out of range (1000)"),
                     ("m=ext,r=rOprNGfwEbeRWgbNEkqOx,s=c2FsdA==,i=4096", "a mandatory extension"),
                     ("r=rOprNGfwEbeRWgbNEkqOx,s=!!,i=4096", "a bad salt")] {
    let s = try client()
    #expect(throws: AuthFailure.peer(why)) { try s.feed(bytes(bad)) }
  }
  let refused = try client()
  try refused.feed(bytes(RFC7677.serverFirst))
  _ = try refused.next()
  #expect(throws: AuthFailure.peer("the server refused: invalid-proof")) { try refused.feed(bytes("e=invalid-proof")) }
}

// MARK: Sessions

@Test func passAsksEveryTimeAndRevealsOnlyOnYes() throws {
  let k = try keyring(["proto=pass server=mail.example user=jk !password=secret"], nonce: "n")
  let pattern = try KeyPattern("proto=pass server=mail.example")
  let s = try k.start(pattern, role: .client, app: "mail", scope: [])
  #expect(try s.next() == .needConfirm("mail wants to use the key proto=pass server=mail.example user=jk !password?"))
  #expect(s.question == .confirm(app: "mail", key: "proto=pass server=mail.example user=jk !password?"))
  #expect(try s.next() == .needConfirm(s.question!.text))  // still waiting
  s.confirm(true)
  #expect(try s.next() == .done(AuthResult(user: "jk", peer: "mail.example", secret: bytes("secret"))))
  // Again: asked again (`always`), and no this time.
  let again = try k.start(pattern, role: .client, app: "mail", scope: [])
  guard case .needConfirm = try again.next() else { Issue.record("not asked"); return }
  again.confirm(false)
  #expect(throws: AuthFailure.denied) { try again.next() }
  #expect(throws: AuthFailure.unsupported) { try k.start(pattern, role: .server, app: "mail", scope: []) }
}

@Test func onceIsOncePerApp() throws {
  let k = try keyring(["proto=scram-sha-256 server=db user=u !password=p confirm=once"], nonce: "abc")
  let pattern = try KeyPattern("proto=scram-sha-256 server=db")
  let first = try k.start(pattern, role: .client, app: "psql", scope: [])
  guard case .needConfirm = try first.next() else { Issue.record("not asked"); return }
  first.confirm(true)
  guard case .send = try first.next() else { Issue.record("didn't start"); return }
  // The same app isn't asked again; another is.
  guard case .send = try k.start(pattern, role: .client, app: "psql", scope: []).next() else {
    Issue.record("asked again")
    return
  }
  guard case .needConfirm = try k.start(pattern, role: .client, app: "other", scope: []).next() else {
    Issue.record("another app wasn't asked")
    return
  }
}

@Test func scopeAndMissingKeys() throws {
  let k = try keyring([], nonce: "abc")
  let scope = [try KeyPattern("proto=scram-sha-256 server=db")]
  #expect(throws: AuthFailure.notAllowed) {
    try k.start(KeyPattern("proto=scram-sha-256 server=other"), role: .client, app: "psql", scope: scope)
  }
  #expect(throws: AuthFailure.unsupported) { try k.start(KeyPattern("proto=p9sk1"), role: .client, app: "a", scope: []) }
  let pattern = try KeyPattern("proto=scram-sha-256 server=db user?")
  let s = try k.start(pattern, role: .client, app: "psql", scope: scope)
  #expect(try s.next() == .needKey(pattern) && s.question == .key(app: "psql", pattern: pattern.text))
  // The user adds one: the session goes on.
  k.store.add(try Key(parsing: "proto=scram-sha-256 server=db user=u !password=p"))
  guard case .send = try s.next() else { Issue.record("didn't find the key added"); return }
  // Or doesn't.
  let none = try k.start(KeyPattern("proto=scram-sha-256 server=db user=nobody"), role: .client, app: "psql", scope: scope)
  _ = try none.next()
  none.declineKey()
  #expect(throws: AuthFailure.noKey) { try none.next() }
}

// MARK: proto=ed25519 (N1c)

func hex(_ s: String) -> [UInt8] {
  var out: [UInt8] = []
  var i = s.startIndex
  while i < s.endIndex {
    let j = s.index(i, offsetBy: 2)
    out.append(UInt8(s[i..<j], radix: 16)!)
    i = j
  }
  return out
}

/// One signature through a session: the public key, then the signature.
func sign(_ k: Keyring, _ pattern: String, _ data: [UInt8]) throws -> (key: [UInt8], signature: [UInt8]) {
  let s = try k.start(KeyPattern(pattern), role: .server, app: "sshd", scope: [KeyPattern("proto=ed25519 service=sshd")])
  guard case .send(let key) = try s.next() else { throw AuthFailure.order }
  #expect(try s.next() == .need)
  try s.feed(data)
  guard case .send(let signature) = try s.next() else { throw AuthFailure.order }
  #expect(try s.next() == .done(AuthResult(user: "", peer: "sshd", secret: [])))
  return (key, signature)
}

@Test func ed25519SignsWithAKeyNoAppHolds() throws {
  // RFC 8032 §7.1's first test: its key, the empty message.
  let seed = Base64.encode(hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
  let k = try keyring(["proto=ed25519 service=sshd !seed=\(seed)"], nonce: "")
  let (key, signature) = try sign(k, "proto=ed25519 service=sshd", [])
  #expect(key == hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
  #expect(signature == hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"))
  #expect(!k.store.listing.contains(seed))
  // Out of turn, and as a client: refused.
  let s = try k.start(KeyPattern("proto=ed25519 service=sshd"), role: .server, app: "sshd", scope: [])
  #expect(throws: AuthFailure.order) { try s.feed([1]) }
  #expect(throws: AuthFailure.unsupported) {
    try k.start(KeyPattern("proto=ed25519 service=sshd"), role: .client, app: "sshd", scope: [])
  }
  #expect(throws: AuthFailure.notAllowed) {
    try k.start(KeyPattern("proto=ed25519 service=other"), role: .server, app: "sshd",
                scope: [KeyPattern("proto=ed25519 service=sshd")])
  }
}

@Test func ed25519MakesItsKeyOnFirstUse() throws {
  var counter: UInt8 = 0
  let k = Keyring(nonce: { "" }) { n in
    counter &+= 1
    return [UInt8](repeating: counter, count: n)
  }
  let first = try sign(k, "proto=ed25519 service=sshd", Array("exchange hash".utf8))
  #expect(Ed25519.verify(first.signature, of: Array("exchange hash".utf8), publicKey: first.key))
  #expect(k.store.listing == "key proto=ed25519 service=sshd !seed?\n")
  // The same key after: made once.
  let second = try sign(k, "proto=ed25519 service=sshd", [])
  #expect(second.key == first.key && counter == 1)
  // Without randomness, no key is made.
  let none = Keyring(nonce: { "" })
  #expect(throws: AuthFailure.noKey) { try sign(none, "proto=ed25519 service=sshd", []) }
}
