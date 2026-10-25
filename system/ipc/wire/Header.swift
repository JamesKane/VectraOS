// SPDX-License-Identifier: BSD-3-Clause

/// The wire format's version, carried in every header.
public let wireVersion: UInt8 = 1

/// What a message is. A reply names its request by transaction id; events
/// and one-way requests carry transaction id 0. Values 4 and 5 are
/// reserved (a cancel and an epitaph, which nothing sent: D137).
public enum MessageKind: UInt8, Equatable, Sendable {
  /// A call, or a one-way request when the transaction id is 0.
  case request = 1
  /// The answer to a request.
  case reply = 2
  /// A message the server sends unasked.
  case event = 3
}

/// Header flags. Bit 0 is reserved (it was `canceled`: D137).
public enum HeaderFlags {
  /// On a reply: the call failed. The body is only the error code (see
  /// `errorInlineSize`).
  public static let error: UInt16 = 1 << 1
  /// Every flag this version defines; the rest must be zero.
  public static let known: UInt16 = error
}

/// An error reply's body: a 4-byte signed code, then 4 bytes of padding.
/// Positive codes are the method's own error type; negative codes are the
/// framework's (the transport's status values, such as "unknown method").
public let errorInlineSize = 8

/// The 16 bytes every message starts with, little-endian:
///
///     0  u32  transaction id
///     4  u8   kind
///     5  u8   wire version
///     6  u16  flags
///     8  u64  method ordinal
public struct MessageHeader: Equatable, Sendable {
  public static let size = 16

  public var txid: UInt32
  public var kind: MessageKind
  public var flags: UInt16
  public var ordinal: UInt64

  public init(txid: UInt32, kind: MessageKind, flags: UInt16 = 0, ordinal: UInt64) {
    self.txid = txid
    self.kind = kind
    self.flags = flags
    self.ordinal = ordinal
  }

  /// Writes the header at the start of `bytes`, which must hold 16 bytes.
  public func store(into bytes: inout MutableRawSpan) {
    bytes.storeBytes(of: txid.littleEndian, toByteOffset: 0, as: UInt32.self)
    bytes.storeBytes(of: kind.rawValue, toByteOffset: 4, as: UInt8.self)
    bytes.storeBytes(of: wireVersion, toByteOffset: 5, as: UInt8.self)
    bytes.storeBytes(of: flags.littleEndian, toByteOffset: 6, as: UInt16.self)
    bytes.storeBytes(of: ordinal.littleEndian, toByteOffset: 8, as: UInt64.self)
  }

  /// Reads and checks the header at the start of `bytes`.
  public init(from bytes: RawSpan) throws(WireError) {
    guard bytes.byteCount >= Self.size else { throw .truncated }
    guard bytes.load(fromByteOffset: 5, as: UInt8.self) == wireVersion else { throw .unsupportedVersion }
    guard let kind = MessageKind(rawValue: bytes.load(fromByteOffset: 4, as: UInt8.self)) else {
      throw .unknownKind
    }
    let flags = bytes.load(fromByteOffset: 6, as: UInt16.self, .littleEndian)
    guard flags & ~HeaderFlags.known == 0 else { throw .reservedFlags }
    self.init(txid: bytes.load(fromByteOffset: 0, as: UInt32.self, .littleEndian), kind: kind,
              flags: flags, ordinal: bytes.load(fromByteOffset: 8, as: UInt64.self, .littleEndian))
  }
}
