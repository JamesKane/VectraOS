// SPDX-License-Identifier: BSD-3-Clause

// virtio-blk (Virtual I/O Device 1.2 §5.2): its feature bits, its
// configuration's capacity (512-byte sectors) and block size, and a
// request's form: a 16-byte header the device reads (type, sector), the
// data, and a status byte it writes.

import Virtio

public enum Block {
  public enum Feature {
    public static let sizeMax: UInt64 = 1 << 1
    public static let segMax: UInt64 = 1 << 2
    public static let readOnly: UInt64 = 1 << 5
    public static let blockSize: UInt64 = 1 << 6
    public static let flush: UInt64 = 1 << 9
  }

  /// Request types (§5.2.6).
  public static let read: UInt32 = 0
  public static let write: UInt32 = 1
  public static let flush: UInt32 = 4
  public static let getID: UInt32 = 8

  /// The status byte: 0 OK, 1 IOERR, 2 UNSUPP.
  public static let ok: UInt8 = 0

  public static let sectorSize = 512

  /// The header's 16 bytes.
  public static func header(type: UInt32, sector: UInt64) -> [UInt8] {
    var b: [UInt8] = []
    for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: type >> (8 * UInt32(i)))) }
    b += [0, 0, 0, 0]
    for i in 0..<8 { b.append(UInt8(truncatingIfNeeded: sector >> (8 * UInt64(i)))) }
    return b
  }

  /// The configuration's capacity, in sectors, and block size (if offered).
  public static func geometry<W: Window>(_ d: Device<W>) -> (sectors: UInt64, blockSize: Int) {
    let sectors = d.config(0, width: 8)
    let size = d.features & Feature.blockSize != 0 ? Int(d.config(20, width: 4)) : sectorSize
    return (sectors, size)
  }
}
