// SPDX-License-Identifier: BSD-3-Clause

// The POSIX system interfaces tier 1's C++ runtime needs (M6d), over croi,
// runtime-free as the rest of the floor: clock_gettime, clock_getres and
// nanosleep on croi's monotonic clock (the realtime clock is the monotonic
// one until croi has a UTC clock a time service sets), sched_yield,
// sysconf's processor counts (croi's topology page) and page size,
// getauxval and elf_aux_info (the CPU's features, from the same page),
// getpagesize, gethostname ("localhost"), isatty (no terminals yet), getentropy and arc4random_buf
// (croi's CPRNG; Embedded Swift's hasher seeds from the second), _Exit,
// and dl_iterate_phdr over the program and the libraries it was linked
// with (D124). They set errno as POSIX says, through the libc's location
// function.

import CroiSyscall
import TDNative

@_extern(c, "__errno_location") func errnoLocation() -> UnsafeMutablePointer<Int32>
#if arch(x86_64)
@_extern(c, "td_cpuid") func cpuid(_ leaf: UInt32, _ sub: UInt32, _ out: UnsafeMutablePointer<UInt32>)
#endif

/// errno.h's numbers these use (Linux's values).
enum PosixError {
  static let noEntry: Int32 = 2  // ENOENT
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

/// The auxiliary vector's entries getauxval and elf_aux_info answer, from
/// the topology page's features (D128) rather than a vector: AT_PAGESZ
/// (6), AT_HWCAP (16) and AT_HWCAP2 (26), whose bits are Linux's for each
/// arch. Features beyond the record read as absent.
enum Auxiliary {
  static func value(_ type: UInt) -> UInt? {
    switch type {
    case 6: return 4096
    case 16: return hwcap
    case 26: return hwcap2
    default: return nil
    }
  }

  #if arch(x86_64)
  /// Linux's: CPUID 1's EDX, which the baseline fixes.
  static var hwcap: UInt {
    var regs = InlineArray<4, UInt32>(repeating: 0)
    var span = regs.mutableSpan
    span.withUnsafeMutableBufferPointer { unsafe cpuid(1, 0, $0.baseAddress!) }
    return UInt(regs[3])
  }
  static var hwcap2: UInt { 0 }
  #elseif arch(arm64)
  /// HWCAP_FP, ASIMD, CRC32, ATOMICS, FPHP, ASIMDHP, ASIMDRDM, LRCPC and
  /// ASIMDDP: the baseline's.
  static let baseline: UInt = 1 << 0 | 1 << 1 | 1 << 7 | 1 << 8 | 1 << 9 | 1 << 10 | 1 << 12 | 1 << 15 | 1 << 20
  static var hwcap: UInt {
    let features = Runtime.cpuFeatures().features
    let bits: InlineArray<7, (feature: UInt64, hwcap: UInt)> = [
      (CROI_FEATURE_AES, 1 << 3), (CROI_FEATURE_PMULL, 1 << 4), (CROI_FEATURE_SHA1, 1 << 5),
      (CROI_FEATURE_SHA2, 1 << 6), (CROI_FEATURE_SHA3, 1 << 17), (CROI_FEATURE_SHA512, 1 << 21),
      (CROI_FEATURE_SVE, 1 << 22),
    ]
    var hwcap = baseline
    for i in bits.indices where features & bits[i].feature != 0 { hwcap |= bits[i].hwcap }
    return hwcap
  }
  /// HWCAP2_SVE2, I8MM and BF16.
  static var hwcap2: UInt {
    let features = Runtime.cpuFeatures().features
    let bits: InlineArray<3, (feature: UInt64, hwcap: UInt)> = [
      (CROI_FEATURE_SVE2, 1 << 1), (CROI_FEATURE_I8MM, 1 << 13), (CROI_FEATURE_BF16, 1 << 14),
    ]
    var hwcap: UInt = 0
    for i in bits.indices where features & bits[i].feature != 0 { hwcap |= bits[i].hwcap }
    return hwcap
  }
  #elseif arch(riscv64)
  /// One bit per single-letter extension, 'a' as bit 0: the baseline's
  /// IMAFDC, and V.
  static var hwcap: UInt {
    let baseline: UInt = 1 << 8 | 1 << 12 | 1 << 0 | 1 << 5 | 1 << 3 | 1 << 2  // I, M, A, F, D, C
    return Runtime.cpuFeatures().features & CROI_FEATURE_V != 0 ? baseline | 1 << 21 : baseline
  }
  static var hwcap2: UInt { 0 }
  #endif
}

/// getauxval (Linux's <sys/auxv.h>): an entry Auxiliary answers, or 0
/// with errno ENOENT.
@c public func getauxval(_ type: UInt) -> UInt {
  guard let value = Auxiliary.value(type) else {
    unsafe errnoLocation().pointee = PosixError.noEntry
    return 0
  }
  return value
}

/// elf_aux_info (FreeBSD's): the entry into `buffer`, an int for
/// AT_PAGESZ and an unsigned long for the rest; 0, ENOENT for an entry it
/// doesn't answer, or EINVAL for a buffer of the wrong size.
@c public func elf_aux_info(_ type: Int32, _ buffer: UnsafeMutableRawPointer?, _ length: Int32) -> Int32 {
  guard type >= 0, let value = Auxiliary.value(UInt(type)) else { return PosixError.noEntry }
  guard let buffer else { return PosixError.invalid }
  if type == 6 {
    guard length == 4 else { return PosixError.invalid }
    unsafe buffer.storeBytes(of: Int32(value), as: Int32.self)
  } else {
    guard length == 8 else { return PosixError.invalid }
    unsafe buffer.storeBytes(of: value, as: UInt.self)
  }
  return 0
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
