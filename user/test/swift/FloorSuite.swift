import CroiRuntime

/// The floor, the one user runtime (D49), through its C interface: the
/// thread's port and its waits and sleeps (V1 cut the thread waits and
/// nanosleep, D23, D25), the environment, errno, the POSIX clock, the
/// heap's C calls and the CPU's features (D128).
enum FloorSuite {
    static func run() {
        threadPort()
        sleeps()
        waits()
        environment()
        posix()
        heap()
        cpuFeatures()
        print("swift: floor passed")
    }

    static var millisecond: Int64 { 1_000_000 }

    /// Made on first use, then the same port.
    static func threadPort() {
        let port = td_thread_port()
        check(port != 0 && td_thread_port() == port, "the thread's port, made once")
    }

    /// A sleep lasts until its deadline.
    static func sleeps() {
        let start = td_monotonic()
        td_sleep(start + 2 * millisecond)
        check(td_monotonic() >= start + 2 * millisecond, "a sleep reaches its deadline")
        td_sleep(0)
        check(true, "a sleep to a deadline passed returns")
    }

    /// A wait sees what it binds for; a timed-out one leaves no binding
    /// and no packet on the thread's port.
    static func waits() {
        var raw = InlineArray<2, UInt32>(repeating: 0)
        check(unsafe withUnsafeMutablePointer(to: &raw) { p in
            let ends = unsafe UnsafeMutableRawPointer(p).assumingMemoryBound(to: UInt32.self)
            return unsafe Sys.call(CROI_SYS_CHANNEL_CREATE, 0, UInt64(UInt(bitPattern: ends)),
                                   UInt64(UInt(bitPattern: ends + 1)))
        } == 0, "a channel")
        let near = Handle(adopting: raw[0]), far = Handle(adopting: raw[1])

        var observed: UInt32 = 0
        let readable = UInt32(CROI_SIGNAL_READABLE)
        check(unsafe td_wait_one(near.raw, readable, td_monotonic() + millisecond, &observed)
                  == Int32(CROI_ERR_TIMED_OUT), "a wait times out")
        let byte: StaticString = "x"
        check(Sys.writeChannel(far.arg, bytes: unsafe UInt64(UInt(bitPattern: byte.utf8Start)), count: 1, handles: 0,
                               handleCount: 0) == 0, "a message sent")
        var packet = croi_port_packet_t()
        check(unsafe td_port_wait(td_thread_port(), td_monotonic() + millisecond, &packet) == Int32(CROI_ERR_TIMED_OUT),
              "and its binding went with it")
        check(unsafe td_wait_one(near.raw, readable, Int64.max, &observed) == 0 && observed & readable != 0,
              "a wait sees the signal")
        check(unsafe td_wait_one(0x7FFF_FFF0, readable, Int64.max, nil) == Int32(CROI_ERR_BAD_HANDLE),
              "a wait on no handle fails")

        let thread = Thread(ends, 0)
        check(unsafe td_wait_one(thread.handle.raw, UInt32(CROI_SIGNAL_TASK_TERMINATED), Int64.max, nil) == 0,
              "a thread's end waited for")
        _ = consume thread
    }

    static let ends: @convention(c) (UInt64) -> Void = { _ in Thread.exit() }

    /// getenv finds this run's suite.
    static func environment() {
        let name: StaticString = "swift.suite"
        guard let value = unsafe getenv(UnsafeRawPointer(name.utf8Start).assumingMemoryBound(to: CChar.self)) else {
            return check(false, "getenv finds the suite")
        }
        check(unsafe strlen(value) == 5 && value[0] == 0x66 && value[4] == 0x72, "getenv finds the suite")  // "floor"
    }

    /// errno is the thread's; the clock is monotonic time; the pid is the
    /// process's koid.
    static func posix() {
        check(unsafe __errno_location() != nil, "errno has a home")
        var ts = timespec()
        let before = td_monotonic()
        check(unsafe clock_gettime(CLOCK_MONOTONIC, &ts) == 0, "clock_gettime(CLOCK_MONOTONIC)")
        let now = Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
        check(now >= before && now <= td_monotonic(), "is monotonic time")
        // clock_nanosleep: until an absolute time, and for a duration.
        var until = timespec()
        _ = unsafe clock_gettime(CLOCK_MONOTONIC, &until)
        let due = Int64(until.tv_sec) * 1_000_000_000 + Int64(until.tv_nsec) + 2 * millisecond
        until.tv_sec = due / 1_000_000_000
        until.tv_nsec = Int(due % 1_000_000_000)
        check(unsafe clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &until, nil) == 0 && td_monotonic() >= due,
              "clock_nanosleep until an absolute time")
        var span = timespec()
        span.tv_nsec = Int(millisecond)
        let start = td_monotonic()
        check(unsafe clock_nanosleep(CLOCK_MONOTONIC, 0, &span, nil) == 0 && td_monotonic() >= start + millisecond,
              "clock_nanosleep for a duration")
        span.tv_nsec = 1_000_000_000
        check(unsafe clock_nanosleep(CLOCK_MONOTONIC, 0, &span, nil) == 22,
              "clock_nanosleep refuses a bad time, returning the error")
        var basic = croi_info_handle_basic_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, UInt64(td_runtime_process_self), UInt64(CROI_INFO_HANDLE_BASIC),
                       Sys.address(&basic), UInt64(MemoryLayout<croi_info_handle_basic_t>.size)) == 0, "own koid")
        check(getpid() == Int32(truncatingIfNeeded: basic.koid), "getpid is the koid")
    }

    /// calloc zeroes; realloc keeps the contents as it grows.
    static func heap() {
        guard let zeroed = unsafe calloc(64, 64) else { return check(false, "calloc") }
        var clear = true
        for i in 0..<4096 where unsafe zeroed.load(fromByteOffset: i, as: UInt8.self) != 0 { clear = false }
        check(clear, "calloc zeroes")
        for i in 0..<4096 { unsafe zeroed.storeBytes(of: UInt8(truncatingIfNeeded: i), toByteOffset: i, as: UInt8.self) }
        guard let grown = unsafe realloc(zeroed, 256 * 1024) else { return check(false, "realloc") }
        var kept = true
        for i in 0..<4096 where unsafe grown.load(fromByteOffset: i, as: UInt8.self) != UInt8(truncatingIfNeeded: i) {
            kept = false
        }
        check(kept, "realloc keeps the contents")
        unsafe free(grown)
    }

    /// The tier is what the features make it; getauxval and elf_aux_info
    /// give the baseline's bits and the record's.
    static func cpuFeatures() {
        let tier = td_cpu_tier(), features = td_cpu_features()
        check(tier >= 1 && tier <= 3, "a tier from 1 to 3")
        let tier2 = CROI_TIER_2_FEATURES, tier3 = CROI_TIER_3_FEATURES
        let made: UInt32 = tier3 != 0 && features & tier3 == tier3 ? 3 : features & tier2 == tier2 ? 2 : 1
        check(made == tier, "the tier its features make")
        #if arch(x86_64)
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe td_cpuid(7, 0, $0.baseAddress!) }
        check(features & CROI_FEATURE_AVX2 == 0 || regs[1] & (1 << 5) != 0, "AVX2 only where CPUID has it")
        check(td_cpu_vector_bytes() == 0, "no vector length")
        let baseline: UInt = 1 << 25 | 1 << 26  // SSE, SSE2
        #elseif arch(arm64)
        check(features & CROI_FEATURE_SVE == 0 || td_cpu_vector_bytes() >= 16, "SVE's vector length")
        check(features & CROI_FEATURE_SVE2 == 0 || features & CROI_FEATURE_SVE != 0, "SVE2 within SVE")
        let baseline: UInt = 1 << 0 | 1 << 1 | 1 << 8 | 1 << 20  // FP, ASIMD, ATOMICS, ASIMDDP
        check((getauxval(UInt(AT_HWCAP)) & 1 << 22 != 0) == (features & CROI_FEATURE_SVE != 0), "HWCAP_SVE")
        check((getauxval(UInt(AT_HWCAP2)) & 1 << 1 != 0) == (features & CROI_FEATURE_SVE2 != 0), "HWCAP2_SVE2")
        #else
        check((td_cpu_vector_bytes() != 0) == (features & CROI_FEATURE_V != 0), "V's vlenb")
        let baseline: UInt = 1 << 8 | 1 << 12 | 1 << 0 | 1 << 5 | 1 << 3 | 1 << 2  // IMAFDC
        #endif
        check(getauxval(UInt(AT_HWCAP)) & baseline == baseline, "AT_HWCAP has the baseline")
        check(getauxval(UInt(AT_PAGESZ)) == 4096, "AT_PAGESZ")
        unsafe __errno_location().pointee = 0
        let unknown = getauxval(99)
        let error = unsafe __errno_location().pointee
        check(unknown == 0 && error == 2, "an unknown entry: ENOENT")
        var hwcap: UInt = 0
        check(unsafe elf_aux_info(AT_HWCAP, &hwcap, 8) == 0 && hwcap == getauxval(UInt(AT_HWCAP)),
              "elf_aux_info agrees")
        check(unsafe elf_aux_info(AT_HWCAP, &hwcap, 4) == 22, "elf_aux_info: EINVAL for a short buffer")
        check(unsafe elf_aux_info(99, &hwcap, 8) == 2, "elf_aux_info: ENOENT")
    }
}
