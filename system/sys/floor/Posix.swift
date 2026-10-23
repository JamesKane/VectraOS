// SPDX-License-Identifier: BSD-3-Clause

// The POSIX system interfaces tier 1's C++ runtime needs (M6d), over croi,
// runtime-free as the rest of the floor: clock_gettime, clock_getres and
// nanosleep on croi's monotonic clock (the realtime clock is the monotonic
// one until croi has a UTC clock a time service sets), sched_yield,
// sysconf's processor counts (croi's topology page) and page size,
// getpagesize, gethostname ("localhost"), isatty (no terminals yet), getentropy and arc4random_buf
// (croi's CPRNG; Embedded Swift's hasher seeds from the second), _Exit,
// and dl_iterate_phdr over the program and the libraries it was linked
// with (D124). They set errno as POSIX says, through the libc's location
// function.

import CroiSyscall
import TDNative

@_extern(c, "__errno_location") func errnoLocation() -> UnsafeMutablePointer<Int32>

/// errno.h's numbers these use (Linux's values).
enum PosixError {
  static let invalid: Int32 = 22  // EINVAL
  static let notATerminal: Int32 = 25  // ENOTTY

  static func fail(_ e: Int32) -> Int32 {
    unsafe errnoLocation().pointee = e
    return -1
  }
}

/// The clock ids the clocks take: all croi's monotonic clock so far.
enum Clocks {
  static func known(_ clock: Int32) -> Bool { clock == 0 || clock == 1 || clock == 4 || clock == 6 || clock == 7 }
}

/// clock_gettime (POSIX XSH): CLOCK_REALTIME (0) and CLOCK_MONOTONIC (1),
/// and Linux's CLOCK_MONOTONIC_RAW (4), CLOCK_MONOTONIC_COARSE (6) and
/// CLOCK_BOOTTIME (7), which are all croi's monotonic clock, in
/// nanoseconds. `ts` is a struct timespec: seconds and nanoseconds, two
/// 64-bit words.
@c public func clock_gettime(_ clock: Int32, _ ts: UnsafeMutablePointer<Int64>?) -> Int32 {
  guard Clocks.known(clock), let ts = unsafe ts else { return PosixError.fail(PosixError.invalid) }
  // CLOCK_REALTIME is the UTC clock the process was given (M6g), else
  // monotonic; the rest are monotonic.
  let now = clock == 0 ? td_utc_now() : Runtime.monotonic()
  unsafe ts[0] = now / 1_000_000_000
  unsafe ts[1] = now % 1_000_000_000
  return 0
}

/// clock_getres (POSIX XSH): the clocks clock_gettime has count
/// nanoseconds.
@c public func clock_getres(_ clock: Int32, _ res: UnsafeMutablePointer<Int64>?) -> Int32 {
  guard Clocks.known(clock) else { return PosixError.fail(PosixError.invalid) }
  if let res = unsafe res {
    unsafe res[0] = 0
    unsafe res[1] = 1
  }
  return 0
}

/// nanosleep (POSIX XSH): the thread's sleep (td_sleep) to a deadline on
/// the monotonic clock. Nothing interrupts it (croi has no signals), so `remaining` is
/// never written.
@c public func nanosleep(_ duration: UnsafePointer<Int64>?, _ remaining: UnsafeMutablePointer<Int64>?) -> Int32 {
  guard let duration = unsafe duration else { return PosixError.fail(PosixError.invalid) }
  let seconds = unsafe duration[0], nanoseconds = unsafe duration[1]
  guard seconds >= 0, nanoseconds >= 0, nanoseconds < 1_000_000_000 else {
    return PosixError.fail(PosixError.invalid)
  }
  // Saturating: a duration past the clock's range sleeps forever.
  let (ns, o1) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
  let (total, o2) = ns.addingReportingOverflow(nanoseconds)
  let (deadline, o3) = Runtime.monotonic().addingReportingOverflow(total)
  let end = o1 || o2 || o3 ? Int64.max : deadline
  td_sleep(end)
  return 0
}

/// sched_yield (POSIX XSH): a sleep to a deadline already past. V1 has no
/// yield (nanosleep went, D25), so whether this gives up the CPU is the
/// scheduler's; it returns at once.
@c public func sched_yield() -> Int32 {
  td_sleep(0)
  return 0
}

/// sysconf (POSIX XSH), the names <unistd.h> defines: _SC_PAGESIZE (30),
/// _SC_NPROCESSORS_CONF (83) and _SC_NPROCESSORS_ONLN (84), every CPU
/// croi runs being online.
@c public func sysconf(_ name: Int32) -> Int {
  switch name {
  case 30: return 4096
  case 83, 84: return Runtime.cpuCount()
  default: return Int(PosixError.fail(PosixError.invalid))
  }
}

/// getpagesize (BSD's, which Linux's C libraries keep): croi's page.
@c public func getpagesize() -> Int32 { 4096 }

/// time (C23 §7.29.2.4): seconds since the epoch, the UTC clock's.
@c public func time(_ out: UnsafeMutablePointer<Int64>?) -> Int64 {
  let now = td_utc_now() / 1_000_000_000
  if let out = unsafe out { unsafe out.pointee = now }
  return now
}

/// getpid (POSIX XSH): the process's koid (object_get_info's
/// HANDLE_BASIC on its own handle), which croi never reuses.
@c public func getpid() -> Int32 {
  var info = croi_info_handle_basic_t()
  let status = withUnsafeMutablePointer(to: &info) { p in
    croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(td_runtime_process_self), UInt64(CROI_INFO_HANDLE_BASIC),
                  UInt64(UInt(bitPattern: p)), UInt64(MemoryLayout<croi_info_handle_basic_t>.size), 0, 0)
  }
  return status == 0 ? Int32(truncatingIfNeeded: info.koid) : 1
}

/// gethostname (POSIX XSH): "localhost", until croi has a name a service
/// sets; ENAMETOOLONG if it doesn't fit in `size` with its NUL.
@c public func gethostname(_ name: UnsafeMutablePointer<UInt8>?, _ size: Int) -> Int32 {
  let host: StaticString = "localhost"
  guard let name = unsafe name, size > host.utf8CodeUnitCount else { return PosixError.fail(36) }
  for i in 0..<host.utf8CodeUnitCount { unsafe name[i] = unsafe host.utf8Start[i] }
  unsafe name[host.utf8CodeUnitCount] = 0
  return 0
}

/// isatty (POSIX XSH): no file descriptor is a terminal yet.
@c public func isatty(_ fd: Int32) -> Int32 {
  _ = PosixError.fail(PosixError.notATerminal)
  return 0
}

/// getentropy (POSIX.1-2024): `length` bytes, at most 256, from croi's
/// CPRNG.
@c public func getentropy(_ buffer: UnsafeMutableRawPointer?, _ length: Int) -> Int32 {
  guard length <= 256, let buffer = unsafe buffer else { return PosixError.fail(PosixError.invalid) }
  _ = croi_syscall(CROI_SYS_CPRNG_DRAW, UInt64(UInt(bitPattern: buffer)), UInt64(length), 0, 0, 0)
  return 0
}

/// arc4random_buf (POSIX.1-2024): `length` bytes from croi's CPRNG, 256
/// a draw. Embedded Swift's Hasher seeds itself from it, which code that
/// keeps every function (an unoptimized hot image) refers to.
@c public func arc4random_buf(_ buffer: UnsafeMutableRawPointer?, _ length: Int) {
  guard let buffer = unsafe buffer else { return }
  var done = 0
  while done < length {
    let n = min(256, length - done)
    _ = croi_syscall(CROI_SYS_CPRNG_DRAW, UInt64(UInt(bitPattern: buffer + done)), UInt64(n), 0, 0, 0)
    done += n
  }
}

/// _Exit (C23 §7.24.4.5): the process ends now, with no handlers run and
/// stdout as it is.
@c(_Exit) public func exitNow(_ code: Int32) -> Never {
  _ = croi_syscall(CROI_SYS_PROCESS_EXIT, UInt64(bitPattern: Int64(code)), 0, 0, 0, 0)
  while true {}
}

/// dl_iterate_phdr's callback: the object's dl_phdr_info, its size, the
/// caller's data.
public typealias PhdrCallback = @convention(c) (UnsafeMutableRawPointer, Int, UnsafeMutableRawPointer?) -> Int32

/// dl_iterate_phdr (<link.h>): the callback for each object, the program
/// first, then the libraries it was linked with in load order (its
/// record, D124); a static program alone, with its program headers, which
/// follow its ELF header in its first segment, and its load bias (that of
/// the segment mapping the header, file offset 0). A callback's nonzero
/// result ends the walk and is returned.
@c public func dl_iterate_phdr(_ callback: PhdrCallback, _ data: UnsafeMutableRawPointer?) -> Int32 {
  // struct dl_phdr_info: dlpi_addr, dlpi_name, dlpi_phdr, dlpi_phnum (then
  // padding), dlpi_adds, dlpi_subs, dlpi_tls_modid, dlpi_tls_data.
  var info = InlineArray<8, UInt64>(repeating: 0)
  let empty: StaticString = ""
  let count = ThreadBlock.objectCount
  for i in 0..<count {
    let o = ThreadBlock.object(i)
    info[0] = o.base
    info[1] = i == 0 ? UInt64(UInt(bitPattern: unsafe empty.utf8Start)) : o.name
    info[2] = o.phdr
    info[3] = o.phnum
    info[4] = UInt64(count)
    // Its TLS: a module number, and the block in the calling thread.
    info[6] = o.tls_size > 0 ? UInt64(i + 1) : 0
    info[7] = o.tls_size > 0 ? UInt64(bitPattern: Int64(bitPattern: UInt64(ThreadBlock.threadPointer)) + o.tls_offset) : 0
    let result = withUnsafeMutablePointer(to: &info) { p in unsafe callback(UnsafeMutableRawPointer(p), 64, data) }
    if result != 0 { return result }
  }
  if count > 0 { return 0 }
  let header = unsafe td_image_header()!
  let phoff = unsafe header.load(fromByteOffset: 32, as: UInt64.self)  // e_phoff
  let entry = unsafe Int(header.load(fromByteOffset: 54, as: UInt16.self))  // e_phentsize
  let phnum = unsafe header.load(fromByteOffset: 56, as: UInt16.self)  // e_phnum
  for i in 0..<Int(phnum) {
    let ph = unsafe header + Int(phoff) + i * entry
    if unsafe ph.load(as: UInt32.self) == 1 && ph.load(fromByteOffset: 8, as: UInt64.self) == 0 {
      info[0] = unsafe UInt64(UInt(bitPattern: header)) &- ph.load(fromByteOffset: 16, as: UInt64.self)
    }
  }
  info[1] = UInt64(UInt(bitPattern: unsafe empty.utf8Start))
  info[2] = UInt64(UInt(bitPattern: header)) + phoff
  info[3] = UInt64(phnum)
  info[4] = 1  // dlpi_adds: objects loaded, the program only
  return withUnsafeMutablePointer(to: &info) { p in unsafe callback(UnsafeMutableRawPointer(p), 64, data) }
}
