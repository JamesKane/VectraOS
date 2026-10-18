// SPDX-License-Identifier: BSD-3-Clause

// A disk image's GUID partition table (UEFI 2.10 §5.3), for `vx disk`:
// a protective MBR, the primary header and its 128 entries, the
// partitions from sector 2048 on, each on a 1 MiB boundary, and the
// backup entries and header at the disk's end. What it gives is the
// table's sectors, to write into a file of the disk's size (the rest left
// a hole).

public enum GPT {
  public static let sectorSize = 512
  public static let entries = 128
  public static let entrySize = 128
  /// Taisce's partitions' type: a GUID of VectraOS's own.
  public static let taisceType: [UInt8] = [0x5A, 0x1C, 0x7E, 0x4B, 0x0E, 0x3D, 0x4F, 0x9A,
                                           0x8C, 0x21, 0x56, 0x0B, 0xD7, 0x39, 0xE4, 0x12]

  public struct Partition: Equatable, Sendable {
    public var name: String
    /// Its sectors: nil for the rest of the disk (the last only).
    public var sectors: UInt64?
    public var type: [UInt8]
    public init(name: String, sectors: UInt64?, type: [UInt8] = GPT.taisceType) {
      self.name = name
      self.sectors = sectors
      self.type = type
    }
  }

  public struct LaidOut: Equatable, Sendable {
    public var name: String
    public var first: UInt64
    /// Its last sector, included, as GPT counts.
    public var last: UInt64
  }

  public struct Failure: Error, Equatable, CustomStringConvertible {
    public let description: String
  }

  /// Where each partition goes on a disk of `sectors`.
  public static func layout(_ parts: [Partition], sectors: UInt64) throws(Failure) -> [LaidOut] {
    let tableSectors = UInt64(entries * entrySize / sectorSize)
    guard sectors > 2048 + tableSectors + 1 else { throw Failure(description: "a disk too small for a table") }
    guard parts.count <= entries else { throw Failure(description: "more than \(entries) partitions") }
    let end = sectors - tableSectors - 1  // the backup's entries start here
    var at: UInt64 = 2048
    var out: [LaidOut] = []
    for (i, p) in parts.enumerated() {
      guard !p.name.isEmpty, p.name.utf16.count <= 36 else {
        throw Failure(description: "a partition's name is 1 to 36 characters: '\(p.name)'")
      }
      let n: UInt64
      if let s = p.sectors {
        n = s
      } else {
        guard i == parts.count - 1 else { throw Failure(description: "only the last partition takes the rest") }
        n = end > at ? end - at : 0
      }
      guard n > 0, at + n <= end else { throw Failure(description: "'\(p.name)' doesn't fit") }
      out.append(LaidOut(name: p.name, first: at, last: at + n - 1))
      at = (at + n + 2047) / 2048 * 2048
    }
    return out
  }

  /// The table's sectors for `parts` on a disk of `sectors`: each write's
  /// offset in bytes and its bytes. `guid` makes each new GUID (the
  /// disk's, then each partition's).
  public static func table(_ parts: [Partition], sectors: UInt64, guid: () -> [UInt8]) throws(Failure)
    -> [(offset: UInt64, bytes: [UInt8])]
  {
    let laid = try layout(parts, sectors: sectors)
    let tableSectors = UInt64(entries * entrySize / sectorSize)
    let disk = guid()
    var table = [UInt8](repeating: 0, count: entries * entrySize)
    for (i, (p, l)) in zip(parts, laid).enumerated() {
      let e = i * entrySize
      table.replaceSubrange(e..<(e + 16), with: p.type)
      table.replaceSubrange((e + 16)..<(e + 32), with: guid())
      put(&table, e + 32, l.first, 8)
      put(&table, e + 40, l.last, 8)
      for (j, u) in p.name.utf16.enumerated() { put(&table, e + 56 + 2 * j, UInt64(u), 2) }
    }
    let tableCRC = crc32(table)
    func header(at mine: UInt64, other: UInt64, entriesAt: UInt64) -> [UInt8] {
      var h = [UInt8](repeating: 0, count: sectorSize)
      h.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
      put(&h, 8, 0x0001_0000, 4)  // revision 1.0
      put(&h, 12, 92, 4)
      put(&h, 24, mine, 8)
      put(&h, 32, other, 8)
      put(&h, 40, 2 + tableSectors, 8)  // the first usable sector
      put(&h, 48, sectors - tableSectors - 2, 8)  // the last
      h.replaceSubrange(56..<72, with: disk)
      put(&h, 72, entriesAt, 8)
      put(&h, 80, UInt64(entries), 4)
      put(&h, 84, UInt64(entrySize), 4)
      put(&h, 88, UInt64(tableCRC), 4)
      put(&h, 16, UInt64(crc32(Array(h[0..<92]))), 4)
      return h
    }
    // The protective MBR: one partition of type 0xEE over the disk.
    var mbr = [UInt8](repeating: 0, count: sectorSize)
    mbr[446 + 4] = 0xEE
    put(&mbr, 446 + 1, 0x000200, 3)  // CHS of sector 1
    put(&mbr, 446 + 5, 0xFFFFFF, 3)
    put(&mbr, 446 + 8, 1, 4)
    put(&mbr, 446 + 12, Swift.min(sectors - 1, 0xFFFF_FFFF), 4)
    mbr[510] = 0x55
    mbr[511] = 0xAA
    let size = UInt64(sectorSize)
    let last = sectors - 1
    return [
      (0, mbr),
      (size, header(at: 1, other: last, entriesAt: 2)),
      (2 * size, table),
      ((last - tableSectors) * size, table),
      (last * size, header(at: last, other: 1, entriesAt: last - tableSectors)),
    ]
  }

  static func put(_ b: inout [UInt8], _ at: Int, _ v: UInt64, _ width: Int) {
    for i in 0..<width { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
  }

  /// CRC-32 (IEEE 802.3, reflected), as GPT's checksums are.
  public static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes {
      crc ^= UInt32(b)
      for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
  }
}
