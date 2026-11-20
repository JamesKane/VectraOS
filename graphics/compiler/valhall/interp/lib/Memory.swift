// SPDX-License-Identifier: BSD-3-Clause

// The interpreter's GPU memory: a sparse, byte-addressed space of 64-bit
// addresses, in 4 KiB pages. Host only (a test tool, D174 §7).
//
// A page exists once it is mapped, or written through the host-side
// `write` helpers. An access to an address no page covers is an MMU fault
// (valhall 12a §12a.1.6: "an unmapped address raises an MMU fault"); the
// interpreter reports it as `Fault.unmapped`. Fresh pages are zero unless a
// fill byte is given.

public final class GpuMemory {
  public static let pageSize = 4096
  var pages: [UInt64: [UInt8]] = [:]

  public init() {}

  /// Maps `[base, base + size)`, zero-filled (or `fill`), keeping pages already there.
  public func map(_ base: UInt64, size: Int, fill: UInt8 = 0) {
    guard size > 0 else { return }
    let first = base / 4096
    let last = (base &+ UInt64(size) &- 1) / 4096
    var p = first
    while true {
      if pages[p] == nil { pages[p] = [UInt8](repeating: fill, count: 4096) }
      if p == last { break }
      p += 1
    }
  }

  public func isMapped(_ address: UInt64, size: Int = 1) -> Bool {
    var a = address
    var left = size
    while left > 0 {
      guard pages[a / 4096] != nil else { return false }
      let step = min(left, 4096 - Int(a % 4096))
      a &+= UInt64(step)
      left -= step
    }
    return true
  }

  /// One byte, or nil when unmapped.
  public func byte(_ address: UInt64) -> UInt8? {
    pages[address / 4096]?[Int(address % 4096)]
  }

  func setByte(_ address: UInt64, _ value: UInt8) -> Bool {
    guard pages[address / 4096] != nil else { return false }
    pages[address / 4096]![Int(address % 4096)] = value
    return true
  }

  /// Reads `size` bytes (little-endian value), at most 8; nil when any byte is unmapped.
  public func readLE(_ address: UInt64, size: Int) -> UInt64? {
    var v: UInt64 = 0
    for i in 0..<size {
      guard let b = byte(address &+ UInt64(i)) else { return nil }
      v |= UInt64(b) << UInt64(8 * i)
    }
    return v
  }

  /// Writes the low `size` bytes of `value`; false when any byte is unmapped (nothing is written then).
  @discardableResult
  public func writeLE(_ address: UInt64, size: Int, value: UInt64) -> Bool {
    guard isMapped(address, size: size) else { return false }
    for i in 0..<size { _ = setByte(address &+ UInt64(i), UInt8(truncatingIfNeeded: value >> UInt64(8 * i))) }
    return true
  }

  // MARK: Host-side helpers (map what they touch).

  public func write(_ address: UInt64, bytes: [UInt8]) {
    map(address, size: bytes.count)
    for (i, b) in bytes.enumerated() { _ = setByte(address &+ UInt64(i), b) }
  }

  public func write32(_ address: UInt64, _ value: UInt32) {
    map(address, size: 4)
    writeLE(address, size: 4, value: UInt64(value))
  }

  public func write32(_ address: UInt64, _ values: [UInt32]) {
    for (i, v) in values.enumerated() { write32(address &+ UInt64(4 * i), v) }
  }

  public func write64(_ address: UInt64, _ value: UInt64) {
    map(address, size: 8)
    writeLE(address, size: 8, value: value)
  }

  public func read32(_ address: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: readLE(address, size: 4) ?? 0)
  }

  public func read32(_ address: UInt64, count: Int) -> [UInt32] {
    (0..<count).map { read32(address &+ UInt64(4 * $0)) }
  }

  public func read64(_ address: UInt64) -> UInt64 { readLE(address, size: 8) ?? 0 }

  public func read(_ address: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { byte(address &+ UInt64($0)) ?? 0 }
  }
}
