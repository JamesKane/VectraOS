// SPDX-License-Identifier: BSD-3-Clause

// Noise messages over a byte stream (TCP): each one after its length,
// 16-bit big-endian, as the framework suggests (§3). 9P's own messages
// are a byte stream inside them, so an msize past one Noise message is
// carried in several.

public enum Frame {
  /// A message, its length first.
  public static func wrap(_ message: [UInt8]) -> [UInt8] {
    precondition(message.count <= Noise.maxMessage)
    return [UInt8(message.count >> 8), UInt8(message.count & 0xff)] + message
  }
}

/// Whole messages out of a stream's bytes as they come.
public struct Deframer: Sendable {
  var pending: [UInt8] = []
  var start = 0

  public init() {}

  public mutating func push(_ bytes: [UInt8]) {
    if start > 0, start == pending.count {
      pending.removeAll(keepingCapacity: true)
      start = 0
    }
    pending += bytes
  }

  /// The next whole message, or nil until one has come.
  public mutating func next() -> [UInt8]? {
    guard pending.count - start >= 2 else { return nil }
    let n = Int(pending[start]) << 8 | Int(pending[start + 1])
    guard pending.count - start - 2 >= n else { return nil }
    let message = Array(pending[start + 2..<start + 2 + n])
    start += 2 + n
    if start > 4096, start * 2 > pending.count {
      pending.removeFirst(start)
      start = 0
    }
    return message
  }
}
