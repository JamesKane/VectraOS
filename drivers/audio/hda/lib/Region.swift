// SPDX-License-Identifier: BSD-3-Clause

// Memory the controller reaches (the CORB, the RIRB, a BDL, a stream's
// buffer): its address here and its bus address, read and written a
// little-endian word at a time within its size.

import AudioDevice
import DriverHost
import Sys

@safe public struct Region: @unchecked Sendable {
  public let address: UInt
  public let bus: UInt64
  public let size: Int

  public init(_ memory: DMAMemory, bytes: Int) throws(Status) {
    let r = try unsafe memory.allocate(bytes: bytes)
    (address, bus, size) = unsafe (UInt(bitPattern: r.pointer), r.bus, bytes)
  }

  func at(_ o: Int, _ width: Int) -> UnsafeMutableRawPointer {
    precondition(o >= 0 && o + width <= size)
    return unsafe UnsafeMutableRawPointer(bitPattern: address + UInt(o))!
  }

  public func load32(_ o: Int) -> UInt32 { UInt32(littleEndian: unsafe at(o, 4).load(as: UInt32.self)) }
  public func store32(_ o: Int, _ v: UInt32) { unsafe at(o, 4).storeBytes(of: v.littleEndian, as: UInt32.self) }
  public func store64(_ o: Int, _ v: UInt64) { unsafe at(o, 8).storeBytes(of: v.littleEndian, as: UInt64.self) }

  /// Its first `count` bytes, as the audio class's buffer.
  public func buffer(_ count: Int) -> AudioBuffer {
    unsafe AudioBuffer(UnsafeMutableRawBufferPointer(start: at(0, count), count: count))
  }
}
