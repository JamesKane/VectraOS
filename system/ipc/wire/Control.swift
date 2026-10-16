// SPDX-License-Identifier: BSD-3-Clause

// The messages the protocol layer sends for itself: epitaphs, cancels and
// canceled replies. Their encoding is part of the wire format.

/// An epitaph's body: the status the channel closed with (a 4-byte signed
/// integer, then 4 bytes of padding).
public let epitaphInlineSize = 8

/// Encodes an epitaph: the last message before a channel closes.
public func encodeEpitaph(status: Int32, into bytes: consuming MutableRawSpan) throws(WireError) -> Int {
  var e = Encoder(bytes: bytes, handles: MutableSpan())
  try e.header(MessageHeader(txid: 0, kind: .epitaph, ordinal: 0))
  try e.beginBody(inlineSize: epitaphInlineSize)
  try e.store(status, at: 0)
  return e.finish().byteCount
}

/// The status an epitaph carries.
public func decodeEpitaph(_ bytes: RawSpan) throws(WireError) -> Int32 {
  var d = try Decoder(bytes: bytes, handles: Span())
  guard d.header.kind == .epitaph else { throw .unknownKind }
  try d.beginBody(inlineSize: epitaphInlineSize)
  let status = try d.load(Int32.self, at: 0)
  try d.checkPadding(at: 4, count: 4)
  try d.finish()
  return status
}

/// Encodes a cancel of the request with transaction id `txid`. It has no
/// body; the ordinal is the cancelled method's.
public func encodeCancel(txid: UInt32, ordinal: UInt64, into bytes: consuming MutableRawSpan)
  throws(WireError) -> Int
{
  var e = Encoder(bytes: bytes, handles: MutableSpan())
  try e.header(MessageHeader(txid: txid, kind: .cancel, ordinal: ordinal))
  return e.finish().byteCount
}

/// Encodes the reply that says a request was cancelled: no body.
public func encodeCanceledReply(txid: UInt32, ordinal: UInt64, into bytes: consuming MutableRawSpan)
  throws(WireError) -> Int
{
  var e = Encoder(bytes: bytes, handles: MutableSpan())
  try e.header(MessageHeader(txid: txid, kind: .reply, flags: HeaderFlags.canceled, ordinal: ordinal))
  return e.finish().byteCount
}
