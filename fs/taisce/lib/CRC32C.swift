// SPDX-License-Identifier: BSD-3-Clause

/// CRC-32C (Castagnoli), as iSCSI uses it (RFC 3720 §B.4): the reflected
/// polynomial 0x82F63B78, initial value and final XOR 0xFFFFFFFF. It
/// guards the superblock and the log's records in S0. S1 puts a stronger
/// checksum on every block, in the parent pointer (filesystem.md §4).
public enum CRC32C {
  static let table: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x82F6_3B78 : c >> 1 }
    return c
  }

  /// The checksum of `bytes[range]`.
  public static func checksum(_ bytes: [UInt8], _ range: Range<Int>? = nil) -> UInt32 {
    update(0xFFFF_FFFF, bytes, range ?? bytes.indices) ^ 0xFFFF_FFFF
  }

  static func update(_ crc: UInt32, _ bytes: [UInt8], _ range: Range<Int>) -> UInt32 {
    var c = crc
    let t = table
    for i in range { c = t[Int((c ^ UInt32(bytes[i])) & 0xff)] ^ (c >> 8) }
    return c
  }
}
