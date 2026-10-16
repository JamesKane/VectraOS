// SPDX-License-Identifier: BSD-3-Clause

/// A message as it travels: its bytes, and the raw handles it carries.
public struct IPCMessage {
  public var bytes: [UInt8]
  public var handles: [UInt32]

  public init(bytes: [UInt8], handles: [UInt32]) {
    self.bytes = bytes
    self.handles = handles
  }

  /// The message's header, checked.
  public func header() throws(WireError) -> MessageHeader {
    try MessageHeader(from: bytes.span.bytes)
  }

  /// Closes every handle the message carries: for a message that is
  /// dropped, so its handles don't leak.
  public func closeHandles() {
    for h in handles { Sys.close(raw: h) }
  }
}

/// Encoding and decoding for generated code.
public enum IPCCodec {
  /// Encodes a message: the header, then (with `inlineSize`) a body that
  /// `body` fills. Handles move into the message as they are stored; if
  /// encoding fails, those are closed (and any not yet stored close as
  /// their owners drop them).
  public static func encode<E: IPCErrorCode>(
    _ header: MessageHeader, inlineSize: Int?, _: E.Type,
    _ body: (inout Encoder) throws(WireError) -> Void = { _ in }
  ) throws(IPCError<E>) -> IPCMessage {
    var bytes = [UInt8](repeating: 0, count: maxMessageBytes)
    var handles = [UInt32](repeating: 0, count: maxMessageHandles)
    let sizes: (byteCount: Int, handleCount: Int)
    do throws(WireError) {
      var span = bytes.mutableSpan
      var e = Encoder(bytes: span.mutableBytes, handles: handles.mutableSpan)
      try e.header(header)
      if let inlineSize {
        try e.beginBody(inlineSize: inlineSize)
        try body(&e)
      }
      sizes = e.finish()
    } catch {
      // Handle 0 is never valid, and the buffer starts zeroed.
      for h in handles where h != 0 { Sys.close(raw: h) }
      throw .wire(error)
    }
    return IPCMessage(bytes: Array(bytes[..<sizes.byteCount]), handles: Array(handles[..<sizes.handleCount]))
  }

  /// Decodes a message's body, which must be consumed exactly. On failure
  /// the handles not yet decoded are closed; those decoded close with the
  /// values that own them.
  public static func decode<E: IPCErrorCode, R: ~Copyable>(
    _ message: IPCMessage, inlineSize: Int, _: E.Type, _ body: (inout Decoder) throws(WireError) -> R
  ) throws(IPCError<E>) -> R {
    var d: Decoder
    do throws(WireError) {
      d = try Decoder(bytes: message.bytes.span.bytes, handles: message.handles.span)
    } catch {
      message.closeHandles()
      throw .wire(error)
    }
    do throws(WireError) {
      try d.beginBody(inlineSize: inlineSize)
      let result = try body(&d)
      try d.finish()
      return result
    } catch {
      for h in message.handles[d.handlesTaken...] { Sys.close(raw: h) }
      throw .wire(error)
    }
  }
}

extension Encoder {
  /// Stores a string's UTF-8 bytes (docs/wire-format.md: byte strings).
  @_lifetime(self: copy self)
  public mutating func storeString(_ string: String, at offset: Int) throws(WireError) {
    let utf8 = Array(string.utf8)
    try storeBytes(utf8.span.bytes, at: offset)
  }

  /// Stores a byte array (docs/wire-format.md: byte strings).
  @_lifetime(self: copy self)
  public mutating func storeByteArray(_ bytes: [UInt8], at offset: Int) throws(WireError) {
    try storeBytes(bytes.span.bytes, at: offset)
  }

  /// Stores a Bool as one byte, 0 or 1.
  @_lifetime(self: copy self)
  public mutating func storeBool(_ value: Bool, at offset: Int) throws(WireError) {
    try store(UInt8(value ? 1 : 0), at: offset)
  }
}

extension Decoder {
  /// A string, which must be valid UTF-8.
  @_lifetime(self: copy self)
  public mutating func loadString(at offset: Int) throws(WireError) -> String {
    guard let string = try loadOptionalString(at: offset) else { throw .badPresence }
    return string
  }

  /// A string that may be absent.
  @_lifetime(self: copy self)
  public mutating func loadOptionalString(at offset: Int) throws(WireError) -> String? {
    guard let utf8 = try loadOptionalByteArray(at: offset) else { return nil }
    guard let string = String(validating: utf8, as: UTF8.self) else { throw .invalidUTF8 }
    return string
  }

  /// A byte string, copied out of the message.
  @_lifetime(self: copy self)
  public mutating func loadByteArray(at offset: Int) throws(WireError) -> [UInt8] {
    guard let bytes = try loadOptionalByteArray(at: offset) else { throw .badPresence }
    return bytes
  }

  /// A byte string that may be absent.
  @_lifetime(self: copy self)
  public mutating func loadOptionalByteArray(at offset: Int) throws(WireError) -> [UInt8]? {
    guard let bytes = try loadOptionalBytes(at: offset) else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.byteCount)
    for i in 0..<bytes.byteCount { out.append(bytes.load(fromByteOffset: i, as: UInt8.self)) }
    return out
  }

  /// A Bool, which must be 0 or 1.
  public func loadBool(at offset: Int) throws(WireError) -> Bool {
    switch try load(UInt8.self, at: offset) {
    case 0: return false
    case 1: return true
    default: throw .invalidValue
    }
  }

  /// A handle that must be present.
  @_lifetime(self: copy self)
  public mutating func loadRequiredHandle(at offset: Int) throws(WireError) -> UInt32 {
    guard let handle = try loadHandle(at: offset) else { throw .invalidValue }
    return handle
  }
}
