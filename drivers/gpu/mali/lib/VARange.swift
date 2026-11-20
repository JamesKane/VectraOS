// SPDX-License-Identifier: BSD-3-Clause

// The GPU's virtual addresses: the driver-owned allocator over a window
// (the MCU VM's auto-VA window, a user VM's kernel region), a user VM's
// layout, and the validation of a bind's range (chinese-wall's panthor 04
// section 4.8.1 to 4.8.3).

/// The GPU's page: the smallest leaf the tables map, whatever the CPU's.
public let gpuPageSize: UInt64 = 4096

/// Best-fit allocation of VA from a window, in a sorted array of free
/// ranges.
public struct VARegion: Sendable {
  struct Free: Sendable {
    var start: UInt64
    var end: UInt64
  }

  public let start: UInt64
  public let end: UInt64
  /// [POLICY] A user VM's allocations of 2 MiB and over start 2 MiB
  /// aligned; the MCU's window has no such rule.
  public let alignLarge: Bool
  var free: [Free]

  public init(start: UInt64, end: UInt64, alignLarge: Bool) {
    precondition(start <= end && start & (gpuPageSize - 1) == 0 && end & (gpuPageSize - 1) == 0)
    self.start = start
    self.end = end
    self.alignLarge = alignLarge
    free = start < end ? [Free(start: start, end: end)] : []
  }

  /// The MCU VM's auto-VA window: 64 MiB at 64 MiB (04 section 4.8.2). The
  /// firmware's shared interface sits at its base, reserved by the loader.
  public static func mcuWindow() -> VARegion {
    VARegion(start: 0x0400_0000, end: 0x0800_0000, alignLarge: false)
  }

  /// A size rounded up to the GPU page, not the CPU's. Nil on overflow
  /// or zero.
  public static func rounded(_ size: UInt64) -> UInt64? {
    if size == 0 || size > UInt64.max - (gpuPageSize - 1) { return nil }
    return (size + gpuPageSize - 1) & ~(gpuPageSize - 1)
  }

  public var freeBytes: UInt64 {
    var n: UInt64 = 0
    for f in free { n += f.end - f.start }
    return n
  }

  private func place(_ f: Free, size: UInt64) -> UInt64? {
    var at = f.start
    if alignLarge && size >= 2 << 20 {
      let a: UInt64 = 2 << 20
      let up = f.start & (a - 1) == 0 ? f.start : (f.start | (a - 1)) &+ 1
      if up < f.start { return nil }
      at = up
    }
    if at > f.end || f.end - at < size { return nil }
    return at
  }

  /// The best fit: the smallest free range that holds `size` once aligned,
  /// lowest address on a tie. Returns the VA, or nil.
  public mutating func allocate(size requested: UInt64) -> UInt64? {
    guard let size = VARegion.rounded(requested) else { return nil }
    var best = -1
    var bestSize: UInt64 = 0
    for i in 0..<free.count {
      if place(free[i], size: size) == nil { continue }
      let len = free[i].end - free[i].start
      if best < 0 || len < bestSize {
        best = i
        bestSize = len
      }
    }
    if best < 0 { return nil }
    let at = place(free[best], size: size)!
    carve(best, at, at + size)
    return at
  }

  /// Take a range at a caller-chosen address (the firmware's fixed
  /// sections, a driver object at a fixed VA). False if any of it is not
  /// free, or it is outside the window.
  public mutating func reserve(at: UInt64, size requested: UInt64) -> Bool {
    guard let size = VARegion.rounded(requested), at & (gpuPageSize - 1) == 0,
      at <= UInt64.max - size
    else { return false }
    for i in 0..<free.count where free[i].start <= at && at + size <= free[i].end {
      carve(i, at, at + size)
      return true
    }
    return false
  }

  private mutating func carve(_ i: Int, _ s: UInt64, _ e: UInt64) {
    let f = free[i]
    if f.start < s && e < f.end {
      free[i].end = s
      free.insert(Free(start: e, end: f.end), at: i + 1)
    } else if f.start < s {
      free[i].end = s
    } else if e < f.end {
      free[i].start = e
    } else {
      free.remove(at: i)
    }
  }

  /// Give a range back. False if it is not wholly taken inside the window.
  public mutating func release(at: UInt64, size requested: UInt64) -> Bool {
    guard let size = VARegion.rounded(requested), at >= start, at <= UInt64.max - size,
      at + size <= end
    else { return false }
    let e = at + size
    var i = 0
    while i < free.count && free[i].end <= at { i += 1 }
    if i < free.count && free[i].start < e { return false }  // overlaps free space
    // Insert, then merge with neighbours.
    free.insert(Free(start: at, end: e), at: i)
    if i + 1 < free.count && free[i].end == free[i + 1].start {
      free[i].end = free[i + 1].end
      free.remove(at: i + 1)
    }
    if i > 0 && free[i - 1].end == free[i].start {
      free[i - 1].end = free[i].end
      free.remove(at: i)
    }
    return true
  }
}

public enum VAError: Error, Equatable, Sendable {
  case vaBitsTooSmall
  case userSizeTooLarge
  case unaligned
  case empty
  case overflow
  case overlapsKernelRegion
}

/// A user VM's layout: the user region [0, K) that binds fill, and the
/// kernel region [K, 2^bits) the driver allocates from (04 section 4.8.1).
public struct UserVMLayout: Sendable {
  public static let minKernelRegion: UInt64 = 256 << 20

  public let vaBits: Int
  /// K, the user region's end, which is also what userspace is told.
  public let kernelStart: UInt64
  public var kernel: VARegion

  /// - Parameters:
  ///   - vaBits: MMU_FEATURES' VA bits.
  ///   - userSize: the size asked for, 0 to choose.
  ///   - cpuSpace: the process's CPU address-space size, so buffers can
  ///     share an address with the CPU's (0 if unknown).
  public init(vaBits: Int, userSize: UInt64, cpuSpace: UInt64) throws(VAError) {
    guard vaBits >= 29, vaBits <= 56 else { throw .vaBitsTooSmall }
    let f: UInt64 = 1 << UInt64(vaBits)
    var user = userSize
    if user != 0 {
      if user > f - UserVMLayout.minKernelRegion { throw .userSizeTooLarge }
    } else if cpuSpace != 0 && cpuSpace < f {
      user = cpuSpace
    } else if f > 4 << 30 {
      user = f / 2
    } else {
      user = f - UserVMLayout.minKernelRegion
    }
    if user > f - UserVMLayout.minKernelRegion { user = f - UserVMLayout.minKernelRegion }
    // The kernel region is the largest power of two within what is left.
    let left = f - user
    var region: UInt64 = 1
    while region <= left / 2 { region <<= 1 }
    self.vaBits = vaBits
    kernelStart = f - region
    kernel = VARegion(start: kernelStart, end: f, alignLarge: true)
  }

  /// A user bind's range: page-aligned, not empty, no overflow, wholly below K.
  public func validateBind(va: UInt64, size: UInt64) throws(VAError) {
    if va & (gpuPageSize - 1) != 0 || size & (gpuPageSize - 1) != 0 { throw .unaligned }
    if size == 0 { throw .empty }
    if va > UInt64.max - size { throw .overflow }
    if va + size > kernelStart { throw .overlapsKernelRegion }
  }
}
