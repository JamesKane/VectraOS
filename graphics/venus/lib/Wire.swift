// SPDX-License-Identifier: BSD-3-Clause

// Venus's wire (M5d): what the generated encoders and decoders
// (generated/Protocol.swift) are written in. The rules are
// docs/research/venus-protocol.md §4: everything in 4-byte units, padding
// after an item (zeros, ours), u64s at any multiple of 4, an array as a
// u64 size and its elements (scalars packed at their natural size, the
// whole padded), a pointer to one value as a u64 marker, a handle as the
// object's u64 id.

/// Why a stream couldn't be decoded.
public enum VenusError: Error, Equatable {
  /// The stream ended inside an item.
  case truncated
  /// A reply for another command.
  case wrongCommand(UInt32)
  /// A struct's sType isn't the one expected.
  case wrongStructure(UInt32)
  /// A chain names a struct the caller's chain doesn't hold.
  case unknownStructure(UInt32)
  /// An array larger than the caller's storage, or a fixed array of
  /// another size.
  case badSize
  /// A value where the caller gave no storage for it.
  case noStorage
  /// Something the client never decodes (strings in replies).
  case unsupported
}

/// Writes a command stream, or measures one (`measuring`: only `count`
/// moves, and nothing is read through pointers or handles).
public struct VenusEncoder {
  public private(set) var bytes: [UInt8] = []
  public private(set) var count = 0
  public let measuring: Bool

  public init(measuring: Bool = false) {
    self.measuring = measuring
  }

  mutating func pad() {
    while count % 4 != 0 {
      if !measuring { bytes.append(0) }
      count += 1
    }
  }

  public mutating func u32(_ v: UInt32) {
    if !measuring {
      bytes.append(UInt8(truncatingIfNeeded: v))
      bytes.append(UInt8(truncatingIfNeeded: v >> 8))
      bytes.append(UInt8(truncatingIfNeeded: v >> 16))
      bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }
    count += 4
  }

  public mutating func u64(_ v: UInt64) {
    u32(UInt32(truncatingIfNeeded: v))
    u32(UInt32(truncatingIfNeeded: v >> 32))
  }

  /// A count or a marker.
  public mutating func size(_ n: Int) { u64(UInt64(n)) }

  /// A value of 4 or 8 bytes as it is in memory (integers, floats,
  /// enums, flags), little-endian.
  public mutating func raw<T: BitwiseCopyable>(_ v: T) {
    let size = MemoryLayout<T>.size
    if !measuring {
      withUnsafeBytes(of: v) { b in for i in 0..<size { bytes.append(unsafe b[i]) } }
    }
    count += size
    pad()
  }

  /// `n` bytes, then padding.
  public mutating func bytes(_ p: UnsafeRawPointer?, count n: Int) {
    if !measuring {
      if let p = unsafe p {
        for i in 0..<n { bytes.append(unsafe p.load(fromByteOffset: i, as: UInt8.self)) }
      } else {
        for _ in 0..<n { bytes.append(0) }
      }
    }
    count += n
    pad()
  }

  /// A fixed array (a C array member, imported as a tuple): its declared
  /// size, then all of its elements' bytes.
  public mutating func fixed<T: BitwiseCopyable>(_ v: T, count n: Int) {
    size(n)
    withUnsafeBytes(of: v) { b in unsafe bytes(b.baseAddress, count: b.count) }
  }

  /// A fixed array passed as a pointer (`const float blendConstants[4]`).
  public mutating func fixed<T: BitwiseCopyable>(_ p: UnsafePointer<T>?, count n: Int) {
    size(n)
    unsafe bytes(UnsafeRawPointer(p), count: n * MemoryLayout<T>.stride)
  }

  /// An array of scalars: its size, then its elements packed.
  public mutating func array<T: BitwiseCopyable>(_ p: UnsafePointer<T>?, count n: Int) {
    guard let p = unsafe p else { return size(0) }
    size(n)
    unsafe bytes(UnsafeRawPointer(p), count: n * MemoryLayout<T>.stride)
  }

  /// A byte array (`void*` with a length in bytes).
  public mutating func blob(_ p: UnsafeRawPointer?, count n: Int) {
    guard let p = unsafe p else { return size(0) }
    size(n)
    unsafe bytes(p, count: n)
  }

  /// A handle: its object's id.
  public mutating func handle(_ h: OpaquePointer?) {
    u64(measuring ? 0 : unsafe VenusObject.id(h))
  }

  /// An array of handles.
  public mutating func handles(_ p: UnsafePointer<OpaquePointer?>?, count n: Int) {
    guard let p = unsafe p else { return size(0) }
    size(n)
    for i in 0..<n { unsafe handle(p[i]) }
  }

  /// A NUL-terminated string: its length with the NUL, then its bytes.
  public mutating func string(_ s: UnsafePointer<CChar>?) {
    guard let s = unsafe s else { return size(0) }
    var n = 0
    while unsafe s[n] != 0 { n += 1 }
    size(n + 1)
    unsafe bytes(UnsafeRawPointer(s), count: n + 1)
  }

  /// An array of strings.
  public mutating func strings(_ p: UnsafePointer<UnsafePointer<CChar>?>?, count n: Int) {
    guard let p = unsafe p else { return size(0) }
    size(n)
    for i in 0..<n { unsafe string(p[i]) }
  }
}

/// Reads a reply stream.
@safe public struct VenusDecoder {
  let base: UnsafeRawPointer?
  public let end: Int
  public private(set) var at = 0

  public init(_ buffer: UnsafeRawBufferPointer) {
    unsafe base = buffer.baseAddress
    end = buffer.count
  }

  mutating func take(_ n: Int) throws(VenusError) -> Int {
    let padded = (n + 3) & ~3
    guard at + padded <= end else { throw .truncated }
    let start = at
    at += padded
    return start
  }

  func byte(_ i: Int) -> UInt8 { unsafe base!.load(fromByteOffset: i, as: UInt8.self) }

  public mutating func u32() throws(VenusError) -> UInt32 {
    let i = try take(4)
    return UInt32(byte(i)) | UInt32(byte(i + 1)) << 8 | UInt32(byte(i + 2)) << 16 | UInt32(byte(i + 3)) << 24
  }

  public mutating func u64() throws(VenusError) -> UInt64 {
    let low = try u32()
    return UInt64(low) | UInt64(try u32()) << 32
  }

  /// A count or a marker.
  public mutating func size() throws(VenusError) -> Int {
    let n = try u64()
    guard n <= UInt64(end) else { throw .badSize }
    return Int(n)
  }

  /// A value of 4 or 8 bytes, as `raw` wrote it.
  public mutating func raw<T: BitwiseCopyable>() throws(VenusError) -> T {
    let i = try take(MemoryLayout<T>.size)
    return unsafe base!.loadUnaligned(fromByteOffset: i, as: T.self)
  }

  /// An 8- or 16-bit value, carried in 4 bytes.
  public mutating func small<T: FixedWidthInteger>() throws(VenusError) -> T {
    T(truncatingIfNeeded: try u32())
  }

  /// `n` bytes into `p`, then padding.
  public mutating func bytes(into p: UnsafeMutableRawPointer, count n: Int) throws(VenusError) {
    let i = try take(n)
    unsafe p.copyMemory(from: base! + i, byteCount: n)
  }

  public mutating func skip(_ n: Int) throws(VenusError) { _ = try take(n) }

  /// A fixed array, into the tuple that holds it; a `char` array's last
  /// byte is NUL whatever came.
  public mutating func fixed<T: BitwiseCopyable>(_ v: inout T, count n: Int, string: Bool = false) throws(VenusError) {
    guard try size() == n else { throw .badSize }
    let i = try take(MemoryLayout<T>.size)
    let source = unsafe base! + i
    withUnsafeMutableBytes(of: &v) { b in
      unsafe b.baseAddress!.copyMemory(from: source, byteCount: b.count)
      if string, b.count > 0 { unsafe b[b.count - 1] = 0 }
    }
  }

  /// An array of scalars into `p`, which holds `capacity` of them.
  public mutating func array<T: BitwiseCopyable>(_ p: UnsafeMutablePointer<T>?, capacity: Int) throws(VenusError) {
    let n = try size()
    guard n > 0 else { return }
    guard let p = unsafe p else { throw .noStorage }
    guard n <= capacity else { throw .badSize }
    try unsafe bytes(into: UnsafeMutableRawPointer(p), count: n * MemoryLayout<T>.stride)
  }

  /// A byte array into `p`, which holds `capacity` bytes.
  public mutating func blob(_ p: UnsafeMutableRawPointer?, capacity: Int) throws(VenusError) {
    let n = try size()
    guard n > 0 else { return }
    guard let p = unsafe p else { throw .noStorage }
    guard n <= capacity else { throw .badSize }
    try unsafe bytes(into: p, count: n)
  }

  /// A marker: whether a value follows.
  public mutating func marker() throws(VenusError) -> Bool { try u64() != 0 }
}

/// The client's objects as the encoders see them: a handle points at an
/// object whose id is the u64 at offset 8 (offset 0 is the loader's
/// dispatch pointer in a dispatchable object, and kept free in the others
/// so every object is laid out alike). The client driver (M5e) makes them.
public enum VenusObject {
  public static let idOffset = 8

  public static func id(_ h: OpaquePointer?) -> UInt64 {
    guard let h = unsafe h else { return 0 }
    return unsafe UnsafeRawPointer(h).load(fromByteOffset: idOffset, as: UInt64.self)
  }
}

/// A value of any integer, enum or flags type as an Int, for array lengths.
@inline(__always)
public func venusInt<T: BitwiseCopyable>(_ v: T) -> Int {
  switch MemoryLayout<T>.size {
  case 1: return Int(unsafe unsafeBitCast(v, to: UInt8.self))
  case 2: return Int(unsafe unsafeBitCast(v, to: UInt16.self))
  case 4: return Int(unsafe unsafeBitCast(v, to: UInt32.self))
  default: return Int(truncatingIfNeeded: unsafe unsafeBitCast(v, to: UInt64.self))
  }
}
