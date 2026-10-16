// SPDX-License-Identifier: BSD-3-Clause

/// Why a message could not be encoded or decoded. Decoding treats every
/// message as untrusted: any of these means the peer broke the protocol.
public enum WireError: Error, Equatable {
  /// The buffer ends before the data it must hold.
  case truncated
  /// The message is larger than `maxMessageBytes`, or the encoder ran out
  /// of buffer.
  case tooLarge
  /// The header's wire version is not one this code speaks.
  case unsupportedVersion
  /// The header's kind byte is not a `MessageKind`.
  case unknownKind
  /// Reserved header flags are set.
  case reservedFlags
  /// A field lies outside the space reserved or taken so far.
  case outOfBounds
  /// A presence marker is neither "absent" nor "present".
  case badPresence
  /// A padding byte is not zero.
  case nonzeroPadding
  /// More handles than `maxMessageHandles`, or than the handle buffer holds.
  case tooManyHandles
  /// The body marks a handle present, but the side array has no more.
  case missingHandle
  /// Bytes or handles are left over after decoding.
  case unconsumed
  /// A string is not valid UTF-8.
  case invalidUTF8
  /// A field holds a value its type doesn't allow (a Bool that is not 0 or
  /// 1, an absent handle where one is required).
  case invalidValue
  /// A message of the wrong kind arrived (a one-way request with a
  /// transaction id, a reply to no call).
  case unexpectedMessage
}
