// SPDX-License-Identifier: BSD-3-Clause

// errno (C23 §7.5), set from Swift (M6d): the C library's, through its
// location function, natively ours (native/errno.c, each thread's) and
// hosted glibc's, so the differential tests compare it too.

@_extern(c, "__errno_location") func errnoLocation() -> UnsafeMutablePointer<Int32>

/// The numbers the conversions set (errno.h's, Linux's values).
enum Errno {
  static let invalid: Int32 = 22  // EINVAL
  static let range: Int32 = 34  // ERANGE

  @inline(__always) static func set(_ value: Int32) { unsafe errnoLocation().pointee = value }
}
