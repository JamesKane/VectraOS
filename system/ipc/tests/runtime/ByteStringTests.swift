// SPDX-License-Identifier: BSD-3-Clause

// Byte strings of every length a word's padding can end on, and of a page
// and a message's worth, stored and loaded in one copy each: they read
// back as written, their padding is zero over storage that wasn't, and
// an empty one is present and empty.

import IPC
import IPCWire
import Testing

@Test func byteStringsCopyInOneAndPadWithZeros() throws {
  for count in Array(0...40) + [4096, 32 * 1024] {
    let data = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    var buffer = [UInt8](repeating: 0xee, count: 64 * 1024)  // nonzero, so padding must be written
    var handles = [UInt32](repeating: 0, count: 1)
    var span = buffer.mutableSpan
    var e = Encoder(bytes: span.mutableBytes, handles: handles.mutableSpan)
    try e.header(MessageHeader(txid: 1, kind: .request, ordinal: 1))
    try e.beginBody(inlineSize: 16)
    try e.storeBytes(data.span.bytes, at: 0)
    let (byteCount, _) = e.finish()
    let header = 16, inline = 16
    let padded = (count + 7) & ~7
    #expect(byteCount == header + inline + padded, "\(count) bytes")
    #expect(Array(buffer[(header + inline)..<(header + inline + count)]) == data, "\(count) bytes")
    #expect(buffer[(header + inline + count)..<(header + inline + padded)].allSatisfy { $0 == 0 }, "\(count) bytes")

    let message = Array(buffer[..<byteCount])
    var d = try Decoder(bytes: message.span.bytes, handles: [UInt32]().span)
    try d.beginBody(inlineSize: 16)
    #expect(try d.loadByteArray(at: 0) == data, "\(count) bytes")
  }
}
