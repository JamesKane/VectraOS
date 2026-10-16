// SPDX-License-Identifier: BSD-3-Clause

/// Reads one message in place, allocating nothing. The message is
/// untrusted: every read is bounds-checked, every padding byte must be
/// zero, and `finish` fails if any byte or handle is left over.
///
/// Byte strings come back as `RawSpan` views into the message, so decoding
/// copies nothing.
public struct Decoder: ~Copyable, ~Escapable {
  let bytes: RawSpan
  let handles: Span<UInt32>
  public let header: MessageHeader
  var nextHandle = 0
  var bodyStart = MessageHeader.size
  var inlineSize = 0
  var next = MessageHeader.size

  /// How many handles have been taken from the side array: on a failed
  /// decode, the rest are still the caller's to close.
  public var handlesTaken: Int { nextHandle }

  @_lifetime(copy bytes, copy handles)
  public init(bytes: RawSpan, handles: Span<UInt32>) throws(WireError) {
    guard bytes.byteCount <= maxMessageBytes, bytes.byteCount % wireAlignment == 0 else {
      throw bytes.byteCount > maxMessageBytes ? .tooLarge : .truncated
    }
    guard handles.count <= maxMessageHandles else { throw .tooManyHandles }
    self.header = try MessageHeader(from: bytes)
    self.bytes = bytes
    self.handles = handles
  }

  /// Takes the body's inline part, which must be there in full.
  @_lifetime(self: copy self)
  public mutating func beginBody(inlineSize: Int) throws(WireError) {
    self.inlineSize = wireAligned(inlineSize)
    guard next + self.inlineSize <= bytes.byteCount else { throw .truncated }
    next += self.inlineSize
  }

  /// An integer at `offset` from the body's start, in the inline part or an
  /// out-of-line object already taken.
  public func load<T: FixedWidthInteger & ConvertibleFromBytes>(_: T.Type, at offset: Int)
    throws(WireError) -> T
  {
    guard offset >= 0, bodyStart + offset + MemoryLayout<T>.size <= next else { throw .outOfBounds }
    return bytes.load(fromByteOffset: bodyStart + offset, as: T.self, .littleEndian)
  }

  /// Checks that the padding in `offset..<offset+count` is zero.
  public func checkPadding(at offset: Int, count: Int) throws(WireError) {
    guard offset >= 0, count >= 0, bodyStart + offset + count <= next else { throw .outOfBounds }
    for i in 0..<count where bytes.load(fromByteOffset: bodyStart + offset + i, as: UInt8.self) != 0 {
      throw .nonzeroPadding
    }
  }

  /// The byte string stored at `offset`, as a view into the message. Out-of-
  /// line data must be taken in the order it was stored.
  @_lifetime(copy self)
  public mutating func loadBytes(at offset: Int) throws(WireError) -> RawSpan {
    guard let bytes = try loadOptionalBytes(at: offset) else { throw .badPresence }
    return bytes
  }

  /// A byte string that may be absent (marker zero, count zero).
  @_lifetime(copy self)
  public mutating func loadOptionalBytes(at offset: Int) throws(WireError) -> RawSpan? {
    guard let (count, base) = try loadVector(at: offset, elementSize: 1) else { return nil }
    return bytes.extracting((bodyStart + base)..<(bodyStart + base + count))
  }

  /// A vector's count, and the offset of its element block, which is taken
  /// now (element `i` starts at `base + i * elementSize`); nil if absent.
  @_lifetime(self: copy self)
  public mutating func loadVector(at offset: Int, elementSize: Int) throws(WireError) -> (count: Int, base: Int)? {
    guard elementSize > 0 else { throw .invalidValue }
    let count = try load(UInt64.self, at: offset)
    switch try load(UInt64.self, at: offset + 8) {
    case 0:
      guard count == 0 else { throw .badPresence }
      return nil
    case presentMarker:
      guard count <= UInt64((bytes.byteCount - next) / elementSize) else { throw .truncated }
      return (Int(count), try claim(Int(count) * elementSize))
    default:
      throw .badPresence
    }
  }

  /// A box's value: the offset of its `size` bytes, taken now; nil if absent.
  @_lifetime(self: copy self)
  public mutating func loadBox(at offset: Int, size: Int) throws(WireError) -> Int? {
    switch try load(UInt64.self, at: offset) {
    case 0: return nil
    case presentMarker: return try claim(size)
    default: throw .badPresence
    }
  }

  /// Takes the next out-of-line object, `size` bytes padded to 8 with zeros:
  /// the offset it starts at.
  @_lifetime(self: copy self)
  mutating func claim(_ size: Int) throws(WireError) -> Int {
    let padded = wireAligned(size)
    guard size >= 0, padded <= bytes.byteCount - next else { throw .truncated }
    for i in (next + size)..<(next + padded) where bytes.load(fromByteOffset: i, as: UInt8.self) != 0 {
      throw .nonzeroPadding
    }
    let base = next - bodyStart
    next += padded
    return base
  }

  /// The handle whose presence marker is at `offset`: the next one in the
  /// side array, or `nil` when the marker says absent.
  @_lifetime(self: copy self)
  public mutating func loadHandle(at offset: Int) throws(WireError) -> UInt32? {
    switch try load(UInt32.self, at: offset) {
    case 0: return nil
    case UInt32.max:
      guard nextHandle < handles.count else { throw .missingHandle }
      defer { nextHandle += 1 }
      return handles[nextHandle]
    default: throw .badPresence
    }
  }

  /// Checks that every byte and every handle was consumed.
  public func finish() throws(WireError) {
    guard next == bytes.byteCount, nextHandle == handles.count else { throw .unconsumed }
  }
}
