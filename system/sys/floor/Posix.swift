// SPDX-License-Identifier: BSD-3-Clause

// The POSIX system interfaces tier 1's C++ runtime needs (M6d), over croi,
// runtime-free as the rest of the floor: clock_gettime, clock_getres,
// nanosleep and clock_nanosleep on croi's monotonic clock (the realtime clock is the monotonic
// one until croi has a UTC clock a time service sets), sched_yield,
// sysconf's processor counts (croi's topology page) and page size,
// getauxval and elf_aux_info (the CPU's features, from the same page),
// getpagesize, mmap, munmap and mprotect (anonymous mappings: VMOs in the
// root VMAR), gethostname ("localhost"), isatty (no terminals yet), getentropy and arc4random_buf
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

/// clock_nanosleep (POSIX XSH): the thread's sleep for `request`, or with
/// TIMER_ABSTIME (1) until it on `clock`'s time (the monotonic clock's,
/// or the UTC clock's for CLOCK_REALTIME, its deadline turned to the
/// monotonic clock when the sleep starts). Like the other calls it
/// returns the error rather than setting errno; nothing interrupts it.
@c public func clock_nanosleep(_ clock: Int32, _ flags: Int32, _ request: UnsafePointer<Int64>?,
                               _ remaining: UnsafeMutablePointer<Int64>?) -> Int32 {
  guard Clocks.known(clock), flags & ~1 == 0, let request = unsafe request else { return PosixError.invalid }
  let seconds = unsafe request[0], nanoseconds = unsafe request[1]
  guard seconds >= 0, nanoseconds >= 0, nanoseconds < 1_000_000_000 else { return PosixError.invalid }
  let (ns, o1) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
  let (time, o2) = ns.addingReportingOverflow(nanoseconds)
  if o1 || o2 {
    td_sleep(Int64.max)
    return 0
  }
  let now = Runtime.monotonic()
  let end: Int64
  if flags & 1 != 0 {
    // A realtime deadline is so far off the monotonic one as the clocks are.
    let offset = clock == 0 ? td_utc_now() - now : 0
    end = time - offset
  } else {
    let (deadline, o3) = now.addingReportingOverflow(time)
    end = o3 ? Int64.max : deadline
  }
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

/// Anonymous mappings (<sys/mman.h>, Linux's values).
enum Mappings {
  static let protRead: Int32 = 1, protWrite: Int32 = 2, protExec: Int32 = 4
  static let shared: Int32 = 0x01, privately: Int32 = 0x02, fixed: Int32 = 0x10, anonymous: Int32 = 0x20
  static let failed = UInt(bitPattern: -1)

  /// The VMAR permissions for `prot`; nil for PROT_EXEC (W^X: executable
  /// memory comes only from a JIT reservation) or unknown bits.
  static func permissions(_ prot: Int32) -> UInt32? {
    guard prot & ~(protRead | protWrite | protExec) == 0, prot & protExec == 0 else { return nil }
    var p: UInt32 = 0
    if prot & protRead != 0 { p |= UInt32(CROI_VM_PERM_READ) }
    if prot & protWrite != 0 { p |= UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) }
    return p
  }

  static func pages(_ length: Int) -> UInt64 { (UInt64(length) + 4095) & ~4095 }
}

/// mmap (POSIX XSH): an anonymous mapping (MAP_ANONYMOUS, with
/// MAP_PRIVATE or MAP_SHARED, which are alike in a process without fork)
/// of `length` bytes rounded up to pages, zeroed, a fresh VMO mapped where
/// the root VMAR places it; `address` is a hint it ignores. MAP_FIXED,
/// file mappings (ENODEV) and PROT_EXEC (EACCES) are refused; MAP_FAILED
/// with errno.
@c public func mmap(_ address: UnsafeMutableRawPointer?, _ length: Int, _ prot: Int32, _ flags: Int32, _ fd: Int32,
                    _ offset: Int64) -> UnsafeMutableRawPointer? {
  let fail = { (e: Int32) -> UnsafeMutableRawPointer? in
    _ = PosixError.fail(e)
    return unsafe UnsafeMutableRawPointer(bitPattern: Mappings.failed)
  }
  guard length > 0, flags & (Mappings.shared | Mappings.privately) != 0, flags & Mappings.fixed == 0 else {
    return fail(PosixError.invalid)
  }
  guard flags & Mappings.anonymous != 0 else { return fail(19) }  // ENODEV: no file mappings yet
  guard let permissions = Mappings.permissions(prot) else { return fail(13) }  // EACCES
  let size = Mappings.pages(length)
  var vmo: UInt32 = 0
  let made = unsafe withUnsafeMutablePointer(to: &vmo) { p in
    unsafe croi_syscall(CROI_SYS_VMO_CREATE, size, 0, UInt64(UInt(bitPattern: p)), 0, 0)
  }
  guard made == 0 else { return fail(12) }  // ENOMEM
  defer { _ = croi_handle_close(vmo) }
  var mapped: UInt64 = 0
  // PROT_NONE: mapped readable, then every right taken away.
  let initial = permissions == 0 ? UInt32(CROI_VM_PERM_READ) : permissions
  guard unsafe croi_vmar_map(td_runtime_vmar_root, initial, 0, vmo, 0, size, &mapped) == 0 else { return fail(12) }
  if permissions == 0 { _ = croi_vmar_protect(td_runtime_vmar_root, 0, mapped, size) }
  return unsafe UnsafeMutableRawPointer(bitPattern: UInt(mapped))
}

/// munmap (POSIX XSH): unmaps the pages of [address, address+length).
@c public func munmap(_ address: UnsafeMutableRawPointer?, _ length: Int) -> Int32 {
  let at = UInt64(UInt(bitPattern: address))
  guard length > 0, at & 4095 == 0,
        croi_vmar_unmap(td_runtime_vmar_root, at, Mappings.pages(length)) == 0 else {
    return PosixError.fail(PosixError.invalid)
  }
  return 0
}

/// mprotect (POSIX XSH): the pages' rights, as mmap's; PROT_EXEC refused.
@c public func mprotect(_ address: UnsafeMutableRawPointer?, _ length: Int, _ prot: Int32) -> Int32 {
  let at = UInt64(UInt(bitPattern: address))
  guard let permissions = Mappings.permissions(prot) else { return PosixError.fail(13) }
  guard at & 4095 == 0, croi_vmar_protect(td_runtime_vmar_root, permissions, at, Mappings.pages(length)) == 0 else {
    return PosixError.fail(PosixError.invalid)
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
