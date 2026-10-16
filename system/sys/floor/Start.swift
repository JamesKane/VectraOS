// SPDX-License-Identifier: BSD-3-Clause

// The floor's start (M6c): what every native process runs before and after
// its `main`, tier 0's Embedded Swift and tier 1's full Swift alike.
// _start (entry/<arch>.S) calls td_start with the bootstrap channel, whose
// one message is Zircon's processargs (croi's processargs.h): a header, a
// handle-info word per handle, then the argument and environment strings.
//
// The floor never touches Swift's runtime (no arrays, strings, classes or
// lazy globals: it is compiled with -no-allocations), so that it can run
// beneath the full runtime as well as Embedded Swift: the message is kept
// on the heap whole, `argv` and `environ` point at its NUL-terminated
// strings, and the handles stay in a raw table until taken. LibSys's
// Swift-friendly views (Arguments, Environment, StartupHandles) are built
// over these, through td_floor.h's functions.
//
// Calls, values and layouts are croi/syscall.h's and its headers' (D45);
// the floor is VectraOS's one user runtime (D49).

import CroiSyscall
import LibC
import TDNative

/// What the runtime keeps for Sys (system/sys/backend/native): this process's
/// handle and its root VMAR, and the vDSO. Stored in C (runtime.c), so that
/// a shared object sees the program's (M5k).
public enum Runtime {
  public internal(set) static var processSelf: UInt32 {
    get { td_runtime_process_self }
    set { td_runtime_process_self = newValue }
  }
  public internal(set) static var vmarRoot: UInt32 {
    get { td_runtime_vmar_root }
    set { td_runtime_vmar_root = newValue }
  }
  /// The main thread's own handle.
  public internal(set) static var threadSelf: UInt32 {
    get { td_runtime_thread_self }
    set { td_runtime_thread_self = newValue }
  }
  static var vdsoClock: (@convention(c) () -> UInt64)? {
    get {
      td_runtime_vdso_clock == 0
        ? nil : unsafe unsafeBitCast(UInt(td_runtime_vdso_clock), to: (@convention(c) () -> UInt64).self)
    }
    set { td_runtime_vdso_clock = UInt64(UInt(bitPattern: unsafe unsafeBitCast(newValue, to: UnsafeRawPointer?.self))) }
  }

  /// Nanoseconds on the monotonic clock: the vDSO's, with no kernel call
  /// (V1 cut the clock call, D26); 0 without a vDSO.
  public static func monotonic() -> Int64 {
    if let clock = vdsoClock { return Int64(bitPattern: clock()) }
    return 0
  }

  /// The vDSO's header (croi_vdso_header_t): each function's offset from
  /// it, the clock's and the topology page's.
  static func findClock(_ base: UInt64) {
    guard base != 0, let header = unsafe UnsafeRawPointer(bitPattern: UInt(base)) else { return }
    let h = unsafe header.load(as: croi_vdso_header_t.self)
    guard h.magic == CROI_VDSO_MAGIC, h.version >= 1 else { return }
    td_runtime_vdso_base = base
    vdsoClock = unsafe unsafeBitCast(header + Int(h.clock_monotonic), to: (@convention(c) () -> UInt64).self)
    td_runtime_vdso_topology = UInt64(UInt(bitPattern: unsafe header + Int(h.topology)))
  }

  /// The CPUs croi runs: its topology page's count (the vDSO's), or 1.
  public static func cpuCount() -> Int {
    guard td_runtime_vdso_topology != 0 else { return 1 }
    let page = unsafe unsafeBitCast(UInt(td_runtime_vdso_topology), to: (@convention(c) () -> UnsafeRawPointer).self)()
    return max(1, Int(unsafe td_topology_cpu_count(page)))
  }
}

/// A handle-info word (processargs.h): the type, and an argument.
@inline(__always) func info(_ type: UInt32, _ argument: UInt32 = 0) -> UInt32 { croi_pa_hnd(type, argument) }

/// What the process was started with, as the floor keeps it: the
/// processargs message on the heap, the handles in a table (a slot 0 once
/// taken), and C's argv and environ.
public enum ProcessStart {
  nonisolated(unsafe) static var message: UnsafeMutablePointer<UInt8>? = nil
  nonisolated(unsafe) public internal(set) static var handleCount = 0
  nonisolated(unsafe) static var infos: UnsafeMutablePointer<UInt32>? = nil
  nonisolated(unsafe) static var handles: UnsafeMutablePointer<UInt32>? = nil
  nonisolated(unsafe) public internal(set) static var argc: Int32 = 0
  nonisolated(unsafe) public internal(set) static var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
  /// The names table: each PA_NS_DIR handle's path, by its argument.
  nonisolated(unsafe) public internal(set) static var nameCount: Int32 = 0
  nonisolated(unsafe) public internal(set) static var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil

  /// The handle started with `info`, the caller's from then on; nil if
  /// there was none or it was taken.
  public static func take(_ info: UInt32) -> UInt32? {
    guard let infos = unsafe infos, let handles = unsafe handles else { return nil }
    for i in 0..<handleCount where unsafe infos[i] == info && handles[i] != 0 {
      let h = unsafe handles[i]
      unsafe handles[i] = 0
      return h
    }
    return nil
  }

  /// The info word of handle `i` if it hasn't been taken, else nil.
  public static func remaining(_ i: Int) -> UInt32? {
    guard i < handleCount, let infos = unsafe infos, let handles = unsafe handles, unsafe handles[i] != 0 else {
      return nil
    }
    return unsafe infos[i]
  }

  /// The environment, as C's environ (runtime.c's).
  public static var environ: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? { unsafe TDNative.environ }
}

/// Ends the process with `code`: the handlers atexit and __cxa_atexit
/// registered, last first, then stdout written out.
public func exit(_ code: Int64) -> Never {
  td_run_exit_handlers()
  Stdout.flush()
  td_stdio_end()
  _ = croi_syscall(CROI_SYS_PROCESS_EXIT, UInt64(bitPattern: code), 0, 0, 0, 0)
  while true {}
}

/// A little-endian word of the message.
@inline(__always) func word(_ m: UnsafePointer<UInt8>, _ size: Int, _ at: Int) -> UInt32 {
  guard at >= 0, at + 4 <= size else { return 0 }
  return unsafe UInt32(m[at]) | UInt32(m[at + 1]) << 8 | UInt32(m[at + 2]) << 16 | UInt32(m[at + 3]) << 24
}

/// Up to `number` NUL-terminated strings from `offset` in the message,
/// pointed at from `into` (room for `number + 1`, ended by a null); how many.
func strings(_ m: UnsafeMutablePointer<UInt8>, _ size: Int, _ offset: UInt32, _ number: UInt32,
             into: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int
{
  var n = 0
  var at = Int(offset)
  while n < Int(number) && at < size {
    unsafe into[n] = unsafe UnsafeMutableRawPointer(m + at).assumingMemoryBound(to: CChar.self)
    while unsafe at < size && m[at] != 0 { at += 1 }
    if at == size { break }  // unterminated: not a string
    at += 1
    n += 1
  }
  unsafe into[n] = nil
  return n
}

@c public func td_start(_ bootstrap: UInt64, _ arg2: UInt64, _ vdso: UInt64) -> Never {
  // The message is read onto the stack: the heap needs the root VMAR,
  // which is in it.
  var bytes = InlineArray<4096, UInt8>(repeating: 0)
  var handles = InlineArray<64, UInt32>(repeating: 0)
  var actualBytes: UInt32 = 0, actualHandles: UInt32 = 0
  let channel = UInt32(truncatingIfNeeded: bootstrap)
  let status = withUnsafeMutablePointer(to: &bytes) { b in
    withUnsafeMutablePointer(to: &handles) { h in
      let table = unsafe UnsafeMutableRawPointer(h).assumingMemoryBound(to: UInt32.self)
      return unsafe croi_channel_read(channel, 0, UnsafeMutableRawPointer(b), table, 4096, 64, &actualBytes,
                                      &actualHandles)
    }
  }
  _ = croi_handle_close(channel)
  let size = status == 0 ? Int(actualBytes) : 0
  let count = status == 0 ? Int(actualHandles) : 0

  withUnsafeMutablePointer(to: &bytes) { b in
    withUnsafeMutablePointer(to: &handles) { h in
      let m = unsafe UnsafeMutableRawPointer(b).assumingMemoryBound(to: UInt8.self)
      let hs = unsafe UnsafeMutableRawPointer(h).assumingMemoryBound(to: UInt32.self)
      let header = size >= MemoryLayout<croi_proc_args_t>.size
        ? unsafe UnsafeRawPointer(m).loadUnaligned(as: croi_proc_args_t.self) : croi_proc_args_t()
      let valid = header.protocol == CROI_PROCARGS_PROTOCOL && header.version == CROI_PROCARGS_VERSION
        && Int(header.handle_info_off) + 4 * count <= size
      // What the floor itself needs, found before anything allocates.
      var vmar: UInt32 = 0, log: UInt32 = 0, thread: UInt32 = 0
      if valid {
        for i in 0..<count {
          let kind = unsafe word(m, size, Int(header.handle_info_off) + 4 * i)
          if kind == info(CROI_PA_VMAR_ROOT) && vmar == 0 { vmar = unsafe hs[i] }
          // stdout, the debuglog (byte streams on the ring come with D46).
          if kind == info(CROI_PA_FD, 1) && log == 0 { log = unsafe hs[i] }
          if kind == info(CROI_PA_THREAD_SELF) && thread == 0 { thread = unsafe hs[i] }
        }
      }
      // The thread pointer first: the trace and locks may read it from here on.
      ThreadBlock.installMain(thread: thread)
      Heap.vmar = vmar
      Stdout.log = log
      Runtime.vmarRoot = vmar
      Runtime.findClock(vdso)
      // Then its TLS, now that there's a heap to put it in.
      ThreadBlock.installMainTLS(thread: thread)
      // From here, allocations are counted on each thread's own (M6m).
      td_heap_tls_ready = 1

      // The message and the handle table onto the heap, for the program's life.
      let kept = unsafe malloc(max(size, 1))!.assumingMemoryBound(to: UInt8.self)
      unsafe kept.update(from: m, count: size)
      unsafe ProcessStart.message = kept
      if valid {
        let infos = unsafe malloc(max(4 * count, 4))!.assumingMemoryBound(to: UInt32.self)
        let table = unsafe malloc(max(4 * count, 4))!.assumingMemoryBound(to: UInt32.self)
        for i in 0..<count {
          unsafe infos[i] = unsafe word(m, size, Int(header.handle_info_off) + 4 * i)
          unsafe table[i] = unsafe hs[i]
        }
        unsafe ProcessStart.infos = infos
        unsafe ProcessStart.handles = table
        ProcessStart.handleCount = count
      }
      // argv and environ, pointing into the kept message.
      let argCount = valid ? header.args_num : 0
      let envCount = valid ? header.environ_num : 0
      let argv = unsafe malloc(8 * (Int(argCount) + 1))!.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
      let envp = unsafe malloc(8 * (Int(envCount) + 1))!.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
      ProcessStart.argc = Int32(valid ? unsafe strings(kept, size, header.args_off, argCount, into: argv) : 0)
      if !valid { unsafe argv[0] = nil }
      if valid { _ = unsafe strings(kept, size, header.environ_off, envCount, into: envp) } else { unsafe envp[0] = nil }
      unsafe ProcessStart.argv = argv
      unsafe environ = envp
      let nameCount = valid ? header.names_num : 0
      let names = unsafe malloc(8 * (Int(nameCount) + 1))!.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
      ProcessStart.nameCount = Int32(valid ? unsafe strings(kept, size, header.names_off, nameCount, into: names) : 0)
      if !valid { unsafe names[0] = nil }
      unsafe ProcessStart.names = names
    }
  }
  // stdout, the root VMAR and the process's own handles stay the runtime's.
  _ = ProcessStart.take(info(CROI_PA_FD, 1))
  _ = ProcessStart.take(info(CROI_PA_VMAR_ROOT))
  Runtime.processSelf = ProcessStart.take(info(CROI_PA_PROC_SELF)) ?? 0
  Runtime.threadSelf = ProcessStart.take(info(CROI_PA_THREAD_SELF)) ?? 0
  // stdio, if the parent gave it (D46): stdout and stdin on rings.
  td_stdio_start()
  // The UTC page, mapped read only for td_utc_now (D48); the mapping keeps
  // it. Argument 1, a writable one, stays the time service's.
  if let utc = ProcessStart.take(info(CROI_PA_VMO_UTC)) {
    var mapped: UInt64 = 0
    if unsafe croi_vmar_map(td_runtime_vmar_root, UInt32(CROI_VM_PERM_READ), 0, utc, 0, 4096, &mapped) == 0 {
      td_runtime_utc_page = mapped
    }
    _ = croi_handle_close(utc)
  }

  // The program's initializers (a full Swift runtime registers its metadata
  // from them), then its main.
  td_run_initializers()
  let code = unsafe main(ProcessStart.argc, ProcessStart.argv)
  exit(Int64(code))
}

@c public func __stack_chk_fail() -> Never {
  Stdout.write("stack smashed: process ends\n")
  exit(-1)
}

/// getenv (C23 §7.24.4.6) under its C name, over the process's environment.
@c(getenv) public func exportedGetenv(_ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
  guard let env = unsafe environ else { return nil }
  return unsafe LibC.getenv(name, in: UnsafePointer(env))
}

/// The program's argv and argc, for a runtime that asks (Swift's
/// CommandLine, M6e): kept for the process's life.
@c public func td_argv(_ argc: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
  if let argc = unsafe argc { unsafe argc.pointee = ProcessStart.argc }
  return unsafe ProcessStart.argv
}

/// exit (C23 §7.24.4.4) under its C name.
@c(exit) public func exportedExit(_ code: Int32) -> Never { exit(Int64(code)) }

// td_floor.h: the above for what can't import this module (tier 1's Sys).
@c public func td_monotonic() -> Int64 { Runtime.monotonic() }

@c public func td_exit(_ code: Int64) -> Never { exit(code) }

// td_floor.h's, its TD_EXITS_MAX 128 (the floor sees td_native.h alone).
@c public func td_exits(_ message: UnsafePointer<CChar>?) -> Never {
  var length = 0
  if let m = unsafe message { while length < 127, unsafe m[length] != 0 { length += 1 } }
  guard length > 0, let m = unsafe message else { exit(0) }
  if let page = ProcessStart.take(info(CROI_PA_VMO_STATUS)) {
    var mapped: UInt64 = 0
    let perms = UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_PERM_WRITE)
    if unsafe croi_vmar_map(td_runtime_vmar_root, perms, 0, page, 0, 4096, &mapped) == 0,
      let to = unsafe UnsafeMutablePointer<CChar>(bitPattern: UInt(mapped))
    {
      for i in 0..<length { unsafe to[i] = m[i] }
      unsafe to[length] = 0
    }
    _ = croi_handle_close(page)
  }
  // A number says itself as a code too.
  var code: Int64 = 0
  for i in 0..<length {
    let c = unsafe m[i]
    guard c >= 0x30, c <= 0x39, code < 256 else {
      code = 256
      break
    }
    code = code * 10 + Int64(c - 0x30)
  }
  exit(code > 0 && code < 256 ? code : 1)
}
@c public func td_startup_take(_ info: UInt32) -> UInt32 { ProcessStart.take(info) ?? 0 }
@c public func td_startup_count() -> Int { ProcessStart.handleCount }
@c public func td_startup_info(_ i: Int) -> UInt32 { ProcessStart.remaining(i) ?? 0 }
@c public func td_startup_names(_ count: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
  if let count = unsafe count { unsafe count.pointee = ProcessStart.nameCount }
  return unsafe ProcessStart.names
}
