// SPDX-License-Identifier: BSD-3-Clause

import IPCWire
import Testing

/// "todhchai.test.Echo.say", hashed independently (FNV-1a 64, top bit clear).
let sayOrdinal: UInt64 = 0x1458_fe16_9955_bc11

/// A request with a UInt32, a handle and the string "hi": the reference
/// encoding, written out by hand from the format's rules.
let golden: [UInt8] = [
  0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00,  // txid 1, request, version 1, flags 0
  0x11, 0xbc, 0x55, 0x99, 0x16, 0xfe, 0x58, 0x14,  // ordinal
  0x07, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,  // value 7, handle present
  0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // string: count 2
  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,  // string: present
  0x68, 0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // "hi", padded to 8
]

/// Encodes the golden request; returns its bytes and handles.
func encodeSay(handle: UInt32 = 0xabcd) throws(WireError) -> ([UInt8], [UInt32]) {
  var buffer = [UInt8](repeating: 0xee, count: 128)  // nonzero, so padding must be written
  var handles = [UInt32](repeating: 0, count: 4)
  let hi: [UInt8] = [0x68, 0x69]
  var bytes = buffer.mutableSpan
  var e = Encoder(bytes: bytes.mutableBytes, handles: handles.mutableSpan)
  try e.header(MessageHeader(txid: 1, kind: .request, ordinal: sayOrdinal))
  try e.beginBody(inlineSize: 24)
  try e.store(UInt32(7), at: 0)
  try e.storeHandle(handle, at: 4)
  try e.storeBytes(hi.span.bytes, at: 8)
  let (byteCount, handleCount) = e.finish()
  return (Array(buffer[..<byteCount]), Array(handles[..<handleCount]))
}

@Test func ordinalMatchesReferenceHash() {
  let name = Array("todhchai.test.Echo.say".utf8)
  #expect(methodOrdinal(name.span) == sayOrdinal)
}

@Test func encodesGoldenBytes() throws {
  let (bytes, handles) = try encodeSay()
  #expect(bytes == golden)
  #expect(handles == [0xabcd])
}

@Test func decodesGoldenBytes() throws {
  let handles: [UInt32] = [0xabcd]
  var d = try Decoder(bytes: golden.span.bytes, handles: handles.span)
  #expect(d.header == MessageHeader(txid: 1, kind: .request, ordinal: sayOrdinal))
  try d.beginBody(inlineSize: 24)
  #expect(try d.load(UInt32.self, at: 0) == 7)
  #expect(try d.loadHandle(at: 4) == 0xabcd)
  let s = try d.loadBytes(at: 8)
  #expect(s.byteCount == 2)
  #expect(s.load(fromByteOffset: 0, as: UInt8.self) == 0x68)
  #expect(s.load(fromByteOffset: 1, as: UInt8.self) == 0x69)
  try d.finish()
}

/// Decodes `bytes` as the golden request, to its end.
func decodeSay(_ bytes: [UInt8], handles: [UInt32] = [0xabcd]) throws(WireError) {
  var d = try Decoder(bytes: bytes.span.bytes, handles: handles.span)
  try d.beginBody(inlineSize: 24)
  _ = try d.load(UInt32.self, at: 0)
  _ = try d.loadHandle(at: 4)
  _ = try d.loadBytes(at: 8)
  try d.finish()
}

func expectError(_ expected: WireError, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("succeeded; expected \(expected)")
  } catch {
    #expect(error as? WireError == expected)
  }
}

@Test func rejectsHostileMessages() {
  var bytes = golden
  expectError(.truncated) { try decodeSay(Array(golden[..<40])) }
  expectError(.truncated) { try decodeSay(Array(golden[..<12])) }

  bytes = golden; bytes[5] = 2
  expectError(.unsupportedVersion) { try decodeSay(bytes) }
  bytes = golden; bytes[4] = 9
  expectError(.unknownKind) { try decodeSay(bytes) }
  bytes = golden; bytes[7] = 0x80
  expectError(.reservedFlags) { try decodeSay(bytes) }
  bytes = golden; bytes[42] = 1  // padding after "hi"
  expectError(.nonzeroPadding) { try decodeSay(bytes) }
  bytes = golden; bytes[32] = 0x01  // string presence marker
  expectError(.badPresence) { try decodeSay(bytes) }
  bytes = golden; bytes[20] = 0x01  // handle presence marker
  expectError(.badPresence) { try decodeSay(bytes) }
  bytes = golden; bytes[24] = 0x40  // string count beyond the message
  expectError(.truncated) { try decodeSay(bytes) }

  expectError(.missingHandle) { try decodeSay(golden, handles: []) }
  expectError(.unconsumed) { try decodeSay(golden, handles: [1, 2]) }
  expectError(.unconsumed) { try decodeSay(golden + [UInt8](repeating: 0, count: 8)) }
}

@Test func storesOutsideTheInlinePartFail() {
  var buffer = [UInt8](repeating: 0, count: 64)
  var bytes = buffer.mutableSpan
  var e = Encoder(bytes: bytes.mutableBytes, handles: MutableSpan())
  expectError(.outOfBounds) {
    try e.header(MessageHeader(txid: 0, kind: .event, ordinal: 1))
    try e.beginBody(inlineSize: 8)
    try e.store(UInt64(1), at: 4)
  }
}

@Test func encoderStopsAtTheBufferEnd() {
  var buffer = [UInt8](repeating: 0, count: 24)
  var bytes = buffer.mutableSpan
  var e = Encoder(bytes: bytes.mutableBytes, handles: MutableSpan())
  expectError(.tooLarge) {
    try e.header(MessageHeader(txid: 0, kind: .event, ordinal: 1))
    try e.beginBody(inlineSize: 16)
  }
}

@Test func epitaphRoundTrips() throws {
  var buffer = [UInt8](repeating: 0xee, count: 32)
  var bytes = buffer.mutableSpan
  let n = try encodeEpitaph(status: -5, into: bytes.mutableBytes)
  #expect(n == 24)
  #expect(try decodeEpitaph(Array(buffer[..<n]).span.bytes) == -5)
}

@Test func cancelAndCanceledReplyHaveNoBody() throws {
  var buffer = [UInt8](repeating: 0, count: 16)
  var bytes = buffer.mutableSpan
  #expect(try encodeCancel(txid: 3, ordinal: sayOrdinal, into: bytes.mutableBytes) == 16)
  let cancel = try MessageHeader(from: buffer.span.bytes)
  #expect(cancel == MessageHeader(txid: 3, kind: .cancel, ordinal: sayOrdinal))

  bytes = buffer.mutableSpan
  #expect(try encodeCanceledReply(txid: 3, ordinal: sayOrdinal, into: bytes.mutableBytes) == 16)
  let reply = try MessageHeader(from: buffer.span.bytes)
  #expect(reply.kind == .reply && reply.flags == HeaderFlags.canceled)
}
