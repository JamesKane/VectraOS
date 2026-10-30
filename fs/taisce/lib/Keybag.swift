// SPDX-License-Identifier: BSD-3-Clause

// An encrypted volume's keybag (S2, D153 §3): up to four slots in the
// superblock, each the volume key wrapped under a key-encryption key. A
// passphrase slot's comes from PBKDF2-HMAC-SHA256 of the passphrase and
// the slot's salt: its first 32 bytes encrypt the volume key with
// ChaCha20, its last 32 key the BLAKE3 tag over the slot. A slot is added
// or removed by a commit, which rewrites only the superblock.

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
    }

    public var kind: Kind
    /// PBKDF2's iterations.
    public var iterations: UInt32
    public var salt: [UInt8]  // 32 bytes
    /// The volume key, encrypted.
    public var wrapped: [UInt8]  // 32 bytes
    public var tag: [UInt8]  // 32 bytes

    /// PBKDF2's iterations for a new passphrase slot: about a second on
    /// the board's cores, under KVM a little less.
    public static let iterations: UInt32 = 200_000

    /// A slot opened by `passphrase`, its salt 32 random bytes.
    public static func passphrase(_ passphrase: [UInt8], key: VolumeKey, salt: [UInt8],
                                  iterations: UInt32 = Slot.iterations) -> Slot {
      precondition(salt.count == 32, "a salt is 32 bytes")
      let kek = PBKDF2.sha256(password: passphrase, salt: salt, iterations: Int(iterations), length: 64)
      let wrapped = ChaCha20.xor(key.bytes, key: Array(kek[0..<32]), nonce: [UInt8](repeating: 0, count: 12), counter: 0)
      var s = Slot(kind: .passphrase, iterations: iterations, salt: salt, wrapped: wrapped, tag: [])
      s.tag = s.tag(Array(kek[32..<64]))
      return s
    }

    /// The tag of everything else in the slot.
    func tag(_ key: [UInt8]) -> [UInt8] {
      var h = BLAKE3(key: key)
      h.update(Array(encode()[0..<104]))
      return h.finalize(count: 32)
    }

    /// The volume key, if `passphrase` is this slot's.
    public func open(_ passphrase: [UInt8]) -> VolumeKey? {
      guard kind == .passphrase else { return nil }
      let kek = PBKDF2.sha256(password: passphrase, salt: salt, iterations: Int(iterations), length: 64)
      guard constantTimeEqual(tag(Array(kek[32..<64])), tag) else { return nil }
      return VolumeKey(ChaCha20.xor(wrapped, key: Array(kek[0..<32]), nonce: [UInt8](repeating: 0, count: 12), counter: 0))
    }

    /// kind u8, 3 bytes zero, iterations u32, salt, wrapped, tag; zeros
    /// to the slot's size.
    func encode() -> [UInt8] {
      var b = [UInt8](repeating: 0, count: Keybag.slotSize)
      b[0] = kind.rawValue
      b.put(iterations, at: 4)
      b.put(bytes: salt, at: 8)
      b.put(bytes: wrapped, at: 40)
      b.put(bytes: tag, at: 104)
      return b
    }

    static func decode(_ b: ArraySlice<UInt8>) -> Slot? {
      let b = Array(b)
      guard let kind = Kind(rawValue: b[0]) else { return nil }
      return Slot(kind: kind, iterations: b.get(UInt32.self, at: 4), salt: b.get(bytes: 32, at: 8),
                  wrapped: b.get(bytes: 32, at: 40), tag: b.get(bytes: 32, at: 104))
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

  func encode() -> [UInt8] {
    var b: [UInt8] = []
    for s in slots { b += s?.encode() ?? [UInt8](repeating: 0, count: Self.slotSize) }
    return b
  }

  static func decode(_ b: [UInt8], at offset: Int) -> Keybag {
    Keybag((0..<count).map { i in Slot.decode(b[(offset + i * slotSize)..<(offset + (i + 1) * slotSize)]) })
  }
}
