// SPDX-License-Identifier: BSD-3-Clause

// An encrypted volume's keybag (S2, D153 §3): up to four slots in the
// superblock, each the volume key wrapped under a key-encryption key:
// its first 32 bytes encrypt the volume key with ChaCha20, its last 32
// key the BLAKE3 tag over the rest of the slot. A slot is added or
// removed by a commit, which rewrites only the superblock. Two kinds:
//
//   passphrase  the key-encryption key is PBKDF2-HMAC-SHA256 of the
//               passphrase and the slot's salt
//   swarm       it is derived from the secret a swarm member's key
//               gives back (McCallum-Relyea, crypto/lib): the slot holds
//               the member's public key, the point the secret is bound
//               at, and the member's address, and the node asks with a
//               blinded request that tells the member nothing

import TDCrypto

public struct Keybag: Equatable, Sendable {
  public static let count = 4
  static let slotSize = 256
  /// Bytes in the superblock.
  static let size = count * slotSize

  /// One way to the volume key.
  public struct Slot: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
      case passphrase = 1
      case swarm
    }

    public var kind: Kind
    /// PBKDF2's iterations (passphrase).
    public var iterations: UInt32
    public var salt: [UInt8]  // 32 bytes (passphrase)
    /// The volume key, encrypted.
    public var wrapped: [UInt8]  // 32 bytes
    public var tag: [UInt8]  // 32 bytes
    /// The member's public key (swarm).
    public var member: [UInt8]  // 32 bytes
    /// The point the member's secret is bound at, C (swarm).
    public var point: [UInt8]  // 32 bytes
    /// Where the member answers, a dial string (swarm).
    public var address: String

    /// PBKDF2's iterations for a new passphrase slot: about a second on
    /// the board's cores, under KVM a little less.
    public static let iterations: UInt32 = 200_000
    /// The longest address a swarm slot holds, in bytes.
    public static let addressSize = 56
    static let swarmContext = Array("Taisce 2026-10-30 swarm slot, McCallum-Relyea".utf8)
    static let zeros = [UInt8](repeating: 0, count: 32)

    init(kind: Kind, iterations: UInt32 = 0, salt: [UInt8] = zeros, member: [UInt8] = zeros,
         point: [UInt8] = zeros, address: String = "", kek: [UInt8], key: VolumeKey) {
      self.kind = kind
      self.iterations = iterations
      self.salt = salt
      self.member = member
      self.point = point
      self.address = address
      wrapped = Self.wrap(key.bytes, kek)
      tag = []
      tag = tag(kek)
    }

    init(kind: Kind, iterations: UInt32, salt: [UInt8], wrapped: [UInt8], tag: [UInt8], member: [UInt8],
         point: [UInt8], address: String) {
      self.kind = kind
      self.iterations = iterations
      self.salt = salt
      self.wrapped = wrapped
      self.tag = tag
      self.member = member
      self.point = point
      self.address = address
    }

    /// A slot opened by `passphrase`, its salt 32 random bytes.
    public static func passphrase(_ passphrase: [UInt8], key: VolumeKey, salt: [UInt8],
                                  iterations: UInt32 = Slot.iterations) -> Slot {
      precondition(salt.count == 32, "a salt is 32 bytes")
      let kek = PBKDF2.sha256(password: passphrase, salt: salt, iterations: Int(iterations), length: 64)
      return Slot(kind: .passphrase, iterations: iterations, salt: salt, kek: kek, key: key)
    }

    /// A slot opened by the swarm member whose mcr key is `member`, at
    /// `address`, bound from 64 random bytes; nil if the key isn't a point
    /// or the address is too long.
    public static func swarm(member: [UInt8], address: String, key: VolumeKey, random: [UInt8]) -> Slot? {
      guard address.utf8.count <= addressSize, !address.isEmpty, !address.utf8.contains(0),
        let (point, secret) = McCallumRelyea.provision(member, random: random)
      else { return nil }
      return Slot(kind: .swarm, member: member, point: point, address: address, kek: swarmKEK(secret), key: key)
    }

    /// Byte for byte: String's == needs Unicode's tables, which tier 0
    /// links without.
    public static func == (a: Slot, b: Slot) -> Bool {
      a.kind == b.kind && a.iterations == b.iterations && a.salt == b.salt && a.wrapped == b.wrapped && a.tag == b.tag
        && a.member == b.member && a.point == b.point && a.address.utf8.elementsEqual(b.address.utf8)
    }

    static func swarmKEK(_ secret: [UInt8]) -> [UInt8] {
      var h = BLAKE3(deriveKeyContext: swarmContext)
      h.update(secret)
      return h.finalize(count: 64)
    }

    static func wrap(_ bytes: [UInt8], _ kek: [UInt8]) -> [UInt8] {
      ChaCha20.xor(bytes, key: Array(kek[0..<32]), nonce: [UInt8](repeating: 0, count: 12), counter: 0)
    }

    /// The tag of everything else in the slot.
    func tag(_ kek: [UInt8]) -> [UInt8] {
      let b = encode()
      var h = BLAKE3(key: Array(kek[32..<64]))
      h.update(Array(b[0..<104]))
      h.update(Array(b[136..<Keybag.slotSize]))
      return h.finalize(count: 32)
    }

    /// The volume key, if the tag says `kek` is this slot's.
    func open(kek: [UInt8]) -> VolumeKey? {
      guard constantTimeEqual(tag(kek), tag) else { return nil }
      return VolumeKey(Self.wrap(wrapped, kek))
    }

    /// The volume key, if `passphrase` is this slot's.
    public func open(_ passphrase: [UInt8]) -> VolumeKey? {
      guard kind == .passphrase else { return nil }
      return open(kek: PBKDF2.sha256(password: passphrase, salt: salt, iterations: Int(iterations), length: 64))
    }

    /// What a swarm slot sends its member, from 64 random bytes: its key,
    /// then the blinded request (64 bytes); and the blinding, to open the
    /// slot with the answer.
    public func request(random: [UInt8]) -> (message: [UInt8], blinding: [UInt8])? {
      guard kind == .swarm, let (x, e) = McCallumRelyea.ask(point, random: random) else { return nil }
      return (member + x, e)
    }

    /// The volume key, from the member's answer to the request made with
    /// `blinding`.
    public func open(answer: [UInt8], blinding: [UInt8]) -> VolumeKey? {
      guard kind == .swarm, let secret = McCallumRelyea.recover(answer, blinding: blinding, publicKey: member) else {
        return nil
      }
      return open(kek: Self.swarmKEK(secret))
    }

    /// kind u8, 3 bytes zero, iterations u32, salt, wrapped, 32 bytes
    /// zero, tag; then the member's key, the point and the address (NUL
    /// padded), to the slot's size.
    func encode() -> [UInt8] {
      var b = [UInt8](repeating: 0, count: Keybag.slotSize)
      b[0] = kind.rawValue
      b.put(iterations, at: 4)
      b.put(bytes: salt, at: 8)
      b.put(bytes: wrapped, at: 40)
      b.put(bytes: tag, at: 104)
      b.put(bytes: member, at: 136)
      b.put(bytes: point, at: 168)
      b.put(bytes: Array(address.utf8), at: 200)
      return b
    }

    static func decode(_ b: ArraySlice<UInt8>) -> Slot? {
      let b = Array(b)
      guard let kind = Kind(rawValue: b[0]) else { return nil }
      let address = b[200..<Keybag.slotSize].prefix { $0 != 0 }
      return Slot(kind: kind, iterations: b.get(UInt32.self, at: 4), salt: b.get(bytes: 32, at: 8),
                  wrapped: b.get(bytes: 32, at: 40), tag: b.get(bytes: 32, at: 104), member: b.get(bytes: 32, at: 136),
                  point: b.get(bytes: 32, at: 168), address: String(decoding: address, as: UTF8.self))
    }
  }

  public var slots: [Slot?]

  public init(_ slots: [Slot?] = []) {
    self.slots = Array(slots.prefix(Self.count)) + [Slot?](repeating: nil, count: Swift.max(0, Self.count - slots.count))
  }

  /// The volume key, from the first slot `passphrase` opens.
  public func unlock(_ passphrase: [UInt8]) -> VolumeKey? {
    for case let slot? in slots {
      if let key = slot.open(passphrase) { return key }
    }
    return nil
  }

  /// The swarm slots, each asked of its member at boot.
  public var swarmSlots: [Slot] { slots.compactMap { $0 }.filter { $0.kind == .swarm } }

  func encode() -> [UInt8] {
    var b: [UInt8] = []
    for s in slots { b += s?.encode() ?? [UInt8](repeating: 0, count: Self.slotSize) }
    return b
  }

  static func decode(_ b: [UInt8], at offset: Int) -> Keybag {
    Keybag((0..<count).map { i in Slot.decode(b[(offset + i * slotSize)..<(offset + (i + 1) * slotSize)]) })
  }
}
