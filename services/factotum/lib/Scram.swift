// SPDX-License-Identifier: BSD-3-Clause

// SCRAM-SHA-256 (RFC 5802, RFC 7677), both roles, without channel
// binding (gs2 header `n,,`). The app passes the messages between
// factotum and its peer (an IMAP server's AUTHENTICATE, Postgres's SASL);
// the password, the salted password and the keys never leave factotum.
//
//     client-first   n,,n=USER,r=CNONCE
//     server-first   r=CNONCE+SNONCE,s=SALT,i=ITERATIONS
//     client-final   c=biws,r=NONCE,p=PROOF
//     server-final   v=SIGNATURE         (or e=ERROR)
//
// SaltedPassword = Hi(password, salt, i) (PBKDF2), ClientKey = HMAC(it,
// "Client Key"), StoredKey = H(ClientKey), ServerKey = HMAC(it, "Server
// Key"); AuthMessage = client-first-bare,server-first,client-final-
// without-proof; the proof is ClientKey ^ HMAC(StoredKey, AuthMessage),
// the server's signature HMAC(ServerKey, AuthMessage). The client checks
// the signature before it says done: a server that doesn't know the
// password can't finish.
//
// Stubs: SASLprep (RFC 4013) isn't applied to user names or passwords
// (TDUnicode has no NFKC yet), so give them as the server stores them;
// iteration counts are taken from 4096 (RFC 7677's floor) to 1,000,000.

import TDCrypto

/// What an authentication gives the app: whom it authenticated as (or,
/// a server, who the client is), the peer, and a session secret (empty
/// for SCRAM, which makes none; `pass`'s is the password).
public struct AuthResult: Equatable, Sendable {
  public var user: String
  public var peer: String
  public var secret: [UInt8]
  /// A last message for the app to send its peer, if the protocol ends
  /// with one (noise-ik's responder: its reply, sent only if the app
  /// accepts `peer`).
  public var bytes: [UInt8]
  public init(user: String, peer: String, secret: [UInt8], bytes: [UInt8] = []) {
    self.user = user
    self.peer = peer
    self.secret = secret
    self.bytes = bytes
  }
}

public enum AuthFailure: Error, Equatable, Sendable {
  /// No key matches (and none was added while asked for).
  case noKey
  /// The user said no.
  case denied
  /// The pattern asks for what the app's scope doesn't allow.
  case notAllowed
  /// A protocol or role factotum doesn't speak.
  case unsupported
  /// The peer broke the protocol, or failed it (a wrong proof or
  /// signature): what was wrong.
  case peer(String)
  /// Called out of turn (a feed when nothing was asked for).
  case order
}

/// One step of a protocol machine.
enum MachineStep: Equatable {
  /// Send these bytes to the peer.
  case send([UInt8])
  /// Feed the peer's next message.
  case need
  case done(AuthResult)
}

enum Scram {
  static let minIterations = 4096, maxIterations = 1_000_000
  static let gs2 = "n,,"

  /// RFC 5802's saslname: `,` as =2C, `=` as =3D.
  static func saslname(_ s: String) -> String {
    var out: [UInt8] = []
    for c in s.utf8 {
      switch c {
      case UInt8(ascii: ","): out += Array("=2C".utf8)
      case UInt8(ascii: "="): out += Array("=3D".utf8)
      default: out.append(c)
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func unsaslname(_ s: String) throws(AuthFailure) -> String {
    let b = Array(s.utf8)
    var out: [UInt8] = []
    var i = 0
    while i < b.count {
      if b[i] == UInt8(ascii: "=") {
        guard i + 2 < b.count else { throw .peer("a bad user name") }
        let code = String(decoding: b[(i + 1)...(i + 2)], as: UTF8.self)
        if same(code, "2C") { out.append(UInt8(ascii: ",")) } else if same(code, "3D") { out.append(UInt8(ascii: "=")) } else {
          throw .peer("a bad user name")
        }
        i += 3
      } else {
        out.append(b[i])
        i += 1
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// A message's attributes, `x=value` each, in order.
  static func attributes(_ message: [UInt8]) throws(AuthFailure) -> [(UInt8, String)] {
    var out: [(UInt8, String)] = []
    for part in message.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
      guard part.count >= 2, part[part.startIndex + 1] == UInt8(ascii: "=") else { throw .peer("a malformed message") }
      out.append((part[part.startIndex], String(decoding: part.dropFirst(2), as: UTF8.self)))
    }
    return out
  }

  /// A nonce's characters: printable ASCII but `,`.
  static func validNonce(_ s: String) -> Bool {
    !s.utf8.isEmpty && s.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E && $0 != UInt8(ascii: ",") }
  }

  struct Keys {
    var clientKey: [UInt8], storedKey: [UInt8], serverKey: [UInt8]
    init(password: [UInt8], salt: [UInt8], iterations: Int) {
      let salted = PBKDF2.sha256(password: password, salt: salt, iterations: iterations, length: 32)
      clientKey = HMACSHA256.authenticate(Array("Client Key".utf8), key: salted)
      storedKey = SHA256.hash(clientKey)
      serverKey = HMACSHA256.authenticate(Array("Server Key".utf8), key: salted)
    }
  }

  static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { (0..<a.count).map { a[$0] ^ b[$0] } }
}

/// SCRAM-SHA-256's client.
struct ScramClient {
  let user: String
  let password: [UInt8]
  let peerName: String
  let nonce: String
  var bare = ""
  var authMessage = ""
  var expected: [UInt8] = []
  var outgoing: [UInt8]?
  var started = false
  /// 0: waiting for server-first; 1: for server-final; 2: done.
  var stage = 0

  init(user: String, password: [UInt8], peer: String, nonce: String) {
    self.user = user
    self.password = password
    peerName = peer
    self.nonce = nonce
  }

  mutating func next() -> MachineStep {
    if !started {
      started = true
      bare = "n=" + Scram.saslname(user) + ",r=" + nonce
      return .send(Array((Scram.gs2 + bare).utf8))
    }
    if let o = outgoing {
      outgoing = nil
      return .send(o)
    }
    return stage == 2 ? .done(AuthResult(user: user, peer: peerName, secret: [])) : .need
  }

  mutating func feed(_ message: [UInt8]) throws(AuthFailure) {
    guard started, outgoing == nil else { throw .order }
    let attrs = try Scram.attributes(message)
    switch stage {
    case 0:
      guard attrs.count >= 3, attrs[0].0 == UInt8(ascii: "r"), attrs[1].0 == UInt8(ascii: "s"),
        attrs[2].0 == UInt8(ascii: "i")
      else {
        if attrs.first?.0 == UInt8(ascii: "m") { throw .peer("a mandatory extension") }
        throw .peer("a malformed server-first message")
      }
      let combined = attrs[0].1
      guard Scram.validNonce(combined), combined.utf8.count > nonce.utf8.count,
        combined.utf8.starts(with: nonce.utf8)
      else { throw .peer("the server's nonce doesn't extend ours") }
      guard let salt = Base64.decode(attrs[1].1), !salt.isEmpty else { throw .peer("a bad salt") }
      guard let i = Int(attrs[2].1), i >= Scram.minIterations, i <= Scram.maxIterations else {
        throw .peer("an iteration count out of range (\(attrs[2].1))")
      }
      let keys = Scram.Keys(password: password, salt: salt, iterations: i)
      let withoutProof = "c=" + Base64.encode(Array(Scram.gs2.utf8)) + ",r=" + combined
      authMessage = bare + "," + String(decoding: message, as: UTF8.self) + "," + withoutProof
      let signature = HMACSHA256.authenticate(Array(authMessage.utf8), key: keys.storedKey)
      let proof = Scram.xor(keys.clientKey, signature)
      expected = HMACSHA256.authenticate(Array(authMessage.utf8), key: keys.serverKey)
      outgoing = Array((withoutProof + ",p=" + Base64.encode(proof)).utf8)
      stage = 1
    case 1:
      if attrs.first?.0 == UInt8(ascii: "e") { throw .peer("the server refused: " + attrs[0].1) }
      guard attrs.first?.0 == UInt8(ascii: "v"), let v = Base64.decode(attrs[0].1),
        constantTimeEqual(v, expected)
      else { throw .peer("the server's signature is wrong") }
      stage = 2
    default:
      throw .order
    }
  }
}

/// SCRAM-SHA-256's server: `lookup` gives a user's password, salt and
/// iteration count (from factotum's server keys).
struct ScramServer {
  let lookup: (String) -> (password: [UInt8], salt: [UInt8], iterations: Int)?
  let peerName: String
  let nonce: String
  var user = ""
  var combined = ""
  var clientBare = ""
  var serverFirst = ""
  var keys: Scram.Keys?
  var outgoing: [UInt8]?
  /// 0: waiting for client-first; 1: for client-final; 2: done.
  var stage = 0

  init(peer: String, nonce: String, lookup: @escaping (String) -> (password: [UInt8], salt: [UInt8], iterations: Int)?) {
    peerName = peer
    self.nonce = nonce
    self.lookup = lookup
  }

  mutating func next() -> MachineStep {
    if let o = outgoing {
      outgoing = nil
      return .send(o)
    }
    return stage == 2 ? .done(AuthResult(user: user, peer: peerName, secret: [])) : .need
  }

  mutating func feed(_ message: [UInt8]) throws(AuthFailure) {
    guard outgoing == nil else { throw .order }
    switch stage {
    case 0:
      // The gs2 header: no channel binding (`n`, or `y`: the client could
      // but thinks we can't), no authzid.
      guard message.count > 3, message[0] == UInt8(ascii: "n") || message[0] == UInt8(ascii: "y"),
        message[1] == UInt8(ascii: ","), message[2] == UInt8(ascii: ",")
      else { throw .peer("an unsupported gs2 header") }
      let bareBytes = Array(message[3...])
      let attrs = try Scram.attributes(bareBytes)
      guard attrs.count >= 2, attrs[0].0 == UInt8(ascii: "n"), attrs[1].0 == UInt8(ascii: "r"),
        Scram.validNonce(attrs[1].1)
      else { throw .peer("a malformed client-first message") }
      user = try Scram.unsaslname(attrs[0].1)
      guard let creds = lookup(user) else { throw .peer("no such user") }
      clientBare = String(decoding: bareBytes, as: UTF8.self)
      combined = attrs[1].1 + nonce
      serverFirst = "r=" + combined + ",s=" + Base64.encode(creds.salt) + ",i=" + String(creds.iterations)
      keys = Scram.Keys(password: creds.password, salt: creds.salt, iterations: creds.iterations)
      outgoing = Array(serverFirst.utf8)
      stage = 1
    case 1:
      let attrs = try Scram.attributes(message)
      guard attrs.count >= 3, attrs[0].0 == UInt8(ascii: "c"), attrs[1].0 == UInt8(ascii: "r"),
        attrs.last!.0 == UInt8(ascii: "p"), let keys
      else { throw .peer("a malformed client-final message") }
      guard let cb = Base64.decode(attrs[0].1), cb == Array("n,,".utf8) || cb == Array("y,,".utf8) else {
        throw .peer("the channel binding doesn't match")
      }
      guard same(attrs[1].1, combined) else { throw .peer("the nonce doesn't match") }
      guard let proof = Base64.decode(attrs.last!.1), proof.count == 32 else { throw .peer("a bad proof") }
      // Everything before ",p=".
      let text = String(decoding: message, as: UTF8.self)
      let withoutProof = String(decoding: Array(text.utf8).dropLast(attrs.last!.1.utf8.count + 3), as: UTF8.self)
      let authMessage = Array((clientBare + "," + serverFirst + "," + withoutProof).utf8)
      let signature = HMACSHA256.authenticate(authMessage, key: keys.storedKey)
      guard constantTimeEqual(SHA256.hash(Scram.xor(proof, signature)), keys.storedKey) else {
        throw .peer("the proof is wrong")
      }
      outgoing = Array(("v=" + Base64.encode(HMACSHA256.authenticate(authMessage, key: keys.serverKey))).utf8)
      stage = 2
    default:
      throw .order
    }
  }
}
