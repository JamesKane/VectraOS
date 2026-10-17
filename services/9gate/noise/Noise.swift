// SPDX-License-Identifier: BSD-3-Clause

// Noise IK, `Noise_IK_25519_ChaChaPoly_SHA256`, after the Noise Protocol
// Framework (revision 34): 9gate's transport (D77). The initiator knows
// the responder's static key beforehand; its own travels encrypted in
// the first message.
//
//     <- s
//     ...
//     -> e, es, s, ss
//     <- e, ee, se
//
// Every operation on a static key is one Diffie-Hellman with a peer's
// public key, so the key is a `NoiseKey`: factotum's holds the private
// half and runs the exchange itself (D75), and `StaticKey` holds it in
// memory. Ephemeral keys come from the caller, so a handshake is a
// function of its inputs and the test vectors replay it.

// The crypto is its own module but in the target's test program, which
// compiles both into one (GateSuite).
#if canImport(TDCrypto)
  import TDCrypto
#endif

/// A static key: its public half, and Diffie-Hellman against a peer's
/// public key (nil if the result is all zeros).
public protocol NoiseKey {
  var publicKey: [UInt8] { get }
  func dh(_ peer: [UInt8]) -> [UInt8]?
}

/// A key pair held in memory.
public struct StaticKey: NoiseKey {
  let privateKey: [UInt8]
  public let publicKey: [UInt8]

  public init(privateKey: [UInt8]) {
    self.privateKey = privateKey
    publicKey = X25519.publicKey(privateKey)
  }

  public func dh(_ peer: [UInt8]) -> [UInt8]? { X25519.sharedSecret(privateKey, peer) }
}

public enum Noise {
  public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
  /// DHLEN and HASHLEN.
  public static let keySize = 32
  public static let tagSize = 16
  /// A Noise message's largest size, its tag included.
  public static let maxMessage = 65535
  /// The plaintext one transport message carries at most.
  public static let maxPayload = maxMessage - tagSize
}

/// A key and its nonce (§5.1). The nonce is 32 bits of zeros then the
/// counter, 64-bit little-endian; the last value is reserved, so a
/// cipher that reaches it refuses.
public struct CipherState: Sendable {
  var key: [UInt8]?
  var n: UInt64 = 0

  init(key: [UInt8]? = nil) { self.key = key }

  var nonce: [UInt8] {
    var b = [UInt8](repeating: 0, count: 12)
    for i in 0..<8 { b[4 + i] = UInt8(truncatingIfNeeded: n >> (8 * UInt64(i))) }
    return b
  }

  /// The plaintext sealed with `ad`, or as it is with no key yet; nil once
  /// the nonces are spent.
  mutating func encrypt(_ ad: [UInt8], _ plaintext: [UInt8]) -> [UInt8]? {
    guard let key else { return plaintext }
    guard n < .max else { return nil }
    defer { n += 1 }
    return ChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, aad: ad)
  }

  /// The plaintext, or nil if the tag is wrong or the nonces are spent. A
  /// failed decryption doesn't use up a nonce.
  mutating func decrypt(_ ad: [UInt8], _ ciphertext: [UInt8]) -> [UInt8]? {
    guard let key else { return ciphertext }
    guard n < .max, let plain = ChaCha20Poly1305.open(ciphertext, key: key, nonce: nonce, aad: ad) else { return nil }
    n += 1
    return plain
  }
}

/// The chaining key, the handshake hash and the cipher (§5.2).
struct SymmetricState {
  var ck: [UInt8]
  var h: [UInt8]
  var cipher = CipherState()

  init() {
    // The name is HASHLEN bytes exactly, so it is h itself.
    let name = Array(Noise.protocolName.utf8)
    h = name.count <= Noise.keySize ? name + [UInt8](repeating: 0, count: Noise.keySize - name.count)
      : SHA256.hash(name)
    ck = h
  }

  mutating func mixHash(_ data: [UInt8]) { h = SHA256.hash(h + data) }

  mutating func mixKey(_ input: [UInt8]) {
    let out = hkdf(ck, input)
    ck = out.0
    cipher = CipherState(key: out.1)
  }

  mutating func encryptAndHash(_ plaintext: [UInt8]) -> [UInt8]? {
    guard let c = cipher.encrypt(h, plaintext) else { return nil }
    mixHash(c)
    return c
  }

  mutating func decryptAndHash(_ ciphertext: [UInt8]) -> [UInt8]? {
    guard let p = cipher.decrypt(h, ciphertext) else { return nil }
    mixHash(ciphertext)
    return p
  }

  /// The two transport ciphers: the initiator's sending one first.
  func split() -> (CipherState, CipherState) {
    let out = hkdf(ck, [])
    return (CipherState(key: out.0), CipherState(key: out.1))
  }
}

/// HKDF with HMAC-SHA-256, two outputs (§4.3).
func hkdf(_ chainingKey: [UInt8], _ input: [UInt8]) -> ([UInt8], [UInt8]) {
  let temp = HMACSHA256.authenticate(input, key: chainingKey)
  let first = HMACSHA256.authenticate([1], key: temp)
  let second = HMACSHA256.authenticate(first + [2], key: temp)
  return (first, second)
}

/// One side of an IK handshake (§5.3). The initiator writes the first
/// message and reads the second; the responder reads, checks
/// `remoteStatic` (who it is talking to), and writes. Then `split` gives
/// the session that carries the traffic. Any failure ends the handshake:
/// every later call returns nil.
public struct Handshake<Key: NoiseKey> {
  public let initiator: Bool
  let key: Key
  let ephemeral: StaticKey
  var state = SymmetricState()
  /// The peer's static public key, once known, and its ephemeral one.
  public private(set) var remoteStatic: [UInt8]?
  var remoteEphemeral: [UInt8]?
  /// Messages done: two finish it.
  var step = 0
  var failed = false
  var spent = false

  /// The initiator's side, to the responder whose static key is
  /// `remote`. `ephemeral` is 32 random bytes.
  public init(initiator key: Key, remote: [UInt8], ephemeral: [UInt8], prologue: [UInt8] = []) {
    initiator = true
    self.key = key
    self.ephemeral = StaticKey(privateKey: ephemeral)
    remoteStatic = remote
    state.mixHash(prologue)
    state.mixHash(remote)
  }

  /// The responder's side.
  public init(responder key: Key, ephemeral: [UInt8], prologue: [UInt8] = []) {
    initiator = false
    self.key = key
    self.ephemeral = StaticKey(privateKey: ephemeral)
    state.mixHash(prologue)
    state.mixHash(key.publicKey)
  }

  /// Whether both messages are done.
  public var complete: Bool { step == 2 && !failed }

  /// The handshake hash, which names the session (channel binding).
  public var hash: [UInt8] { state.h }

  /// This side's next message, carrying `payload`; nil if it isn't this
  /// side's turn, or the handshake failed.
  public mutating func write(_ payload: [UInt8] = []) -> [UInt8]? {
    guard !failed, step < 2, initiator == (step == 0) else { return fail() }
    var out = ephemeral.publicKey
    state.mixHash(ephemeral.publicKey)
    if step == 0 {
      // -> e, es, s, ss
      guard let rs = remoteStatic, let es = ephemeral.dh(rs) else { return fail() }
      state.mixKey(es)
      guard let s = state.encryptAndHash(key.publicKey) else { return fail() }
      out += s
      guard let ss = key.dh(rs) else { return fail() }
      state.mixKey(ss)
    } else {
      // <- e, ee, se
      guard let re = remoteEphemeral, let rs = remoteStatic, let ee = ephemeral.dh(re), let se = ephemeral.dh(rs)
      else { return fail() }
      state.mixKey(ee)
      state.mixKey(se)
    }
    guard let p = state.encryptAndHash(payload), out.count + p.count <= Noise.maxMessage else { return fail() }
    step += 1
    return out + p
  }

  /// The payload of the peer's next message; nil if it isn't the peer's
  /// turn, or the message is wrong, which ends the handshake.
  public mutating func read(_ message: [UInt8]) -> [UInt8]? {
    guard !failed, step < 2, initiator == (step == 1), message.count <= Noise.maxMessage else { return fail() }
    var r = message[...]
    func take(_ n: Int) -> [UInt8]? {
      guard r.count >= n else { return nil }
      defer { r = r.dropFirst(n) }
      return Array(r.prefix(n))
    }
    guard let re = take(Noise.keySize) else { return fail() }
    remoteEphemeral = re
    state.mixHash(re)
    if step == 0 {
      // -> e, es, s, ss, as the responder
      guard let es = key.dh(re) else { return fail() }
      state.mixKey(es)
      guard let sealed = take(Noise.keySize + Noise.tagSize), let rs = state.decryptAndHash(sealed) else { return fail() }
      remoteStatic = rs
      guard let ss = key.dh(rs) else { return fail() }
      state.mixKey(ss)
    } else {
      // <- e, ee, se, as the initiator
      guard let ee = ephemeral.dh(re), let se = key.dh(re) else { return fail() }
      state.mixKey(ee)
      state.mixKey(se)
    }
    guard let payload = state.decryptAndHash(Array(r)) else { return fail() }
    step += 1
    return payload
  }

  /// The transport, once the handshake is complete: given once, so no two
  /// sessions use the same keys and nonces. Later calls return nil.
  public mutating func split() -> Session? {
    guard complete, !spent else { return nil }
    spent = true
    let (a, b) = state.split()
    return initiator ? Session(send: a, receive: b, hash: state.h) : Session(send: b, receive: a, hash: state.h)
  }

  mutating func fail<T>() -> T? {
    failed = true
    return nil
  }
}

/// The transport after a handshake: a cipher each way.
public struct Session: Sendable {
  var send: CipherState
  var receive: CipherState
  /// The handshake hash.
  public let hash: [UInt8]

  /// One transport message carrying `plaintext` (at most
  /// `Noise.maxPayload` bytes), or nil if it's too long or the nonces
  /// are spent.
  public mutating func seal(_ plaintext: [UInt8]) -> [UInt8]? {
    guard plaintext.count <= Noise.maxPayload else { return nil }
    return send.encrypt([], plaintext)
  }

  /// A transport message's plaintext, or nil if it wasn't sealed by the
  /// peer's next message.
  public mutating func open(_ message: [UInt8]) -> [UInt8]? {
    guard message.count <= Noise.maxMessage else { return nil }
    return receive.decrypt([], message)
  }
}
