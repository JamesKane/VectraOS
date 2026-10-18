import CroiRuntime

/// Syscall helpers for bin/m2: a failing call throws with what it was
/// doing and the status.
struct Failure: Error {
    let what: StaticString
    let status: Int64
}

enum Sys {
    static var sameRights: UInt64 { UInt64(CROI_RIGHT_SAME_RIGHTS) }

    static func call(_ number: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0,
                     _ a4: UInt64 = 0, _ a5: UInt64 = 0) -> Int64 {
        croi_syscall6(number, a0, a1, a2, a3, a4, a5)
    }

    static func check(_ what: StaticString, _ status: Int64) throws(Failure) {
        guard status == 0 else { throw Failure(what: what, status: status) }
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
    }

    /// object_bind of one item: the item's status, or the call's.
    static func bind(_ port: UInt32, _ handle: UInt32, _ options: UInt32, key: UInt64, trigger: UInt64) -> Int64 {
        var item = croi_bind_item_t(handle: handle, options: options, key: key, trigger: trigger, status: 1,
                                    reserved: 0)
        let bound = call(CROI_SYS_OBJECT_BIND, UInt64(port), address(&item), 1)
        return bound < 0 ? bound : bound == 1 ? 0 : Int64(item.status)
    }

    static func now() -> UInt64 { UInt64(td_monotonic()) }

    /// Whether timings are real (hardware or KVM), not QEMU TCG's: the
    /// kernel's rule (TraceSelfTest.enforcesCost). CPUID's hypervisor leaf
    /// says "TCGTCGTCGTCG" under TCG; arm64 and rv64 run only under TCG.
    static var timingIsReal: Bool {
        #if arch(x86_64)
            var r = InlineArray<4, UInt32>(repeating: 0)
            unsafe withUnsafeMutablePointer(to: &r) { p in
                unsafe td_cpuid(0x4000_0000, 0, UnsafeMutableRawPointer(p).assumingMemoryBound(to: UInt32.self))
            }
            return !(r[1] == 0x5447_4354 && r[2] == 0x4354_4743 && r[3] == 0x4743_5447)
        #else
            return false
        #endif
    }

    /// Whether a hypervisor runs this (CPUID leaf 1, ECX bit 31), whose
    /// host may stall a CPU at any moment; arm64 and rv64 can't tell, and
    /// are taken as not.
    static var underHypervisor: Bool {
        #if arch(x86_64)
            var r = InlineArray<4, UInt32>(repeating: 0)
            unsafe withUnsafeMutablePointer(to: &r) { p in
                unsafe td_cpuid(1, 0, UnsafeMutableRawPointer(p).assumingMemoryBound(to: UInt32.self))
            }
            return r[2] & (1 << 31) != 0
        #else
            return false
        #endif
    }

    /// A port nothing is bound to: every thread's sleep (V1 cut nanosleep,
    /// D25).
    nonisolated(unsafe) static var sleepPort: UInt32 = 0

    /// Sleeps until `deadline`: a port_wait that times out.
    static func sleep(until deadline: UInt64) {
        if sleepPort == 0 { _ = call(CROI_SYS_PORT_CREATE, 0, address(&sleepPort)) }
        var packet = croi_port_packet_t()
        _ = unsafe croi_port_wait(sleepPort, deadline, &packet, 0)
    }

    static func close(_ handle: UInt32) {
        if handle != 0 { _ = croi_handle_close(handle) }
    }

    static func say(_ text: StaticString) {
        unsafe td_stdout_write(UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self), text.utf8CodeUnitCount)
    }

    /// A counter: the bench's handshakes and wakes (V1 cut events, D23).
    static func counter() throws(Failure) -> UInt32 {
        var handle: UInt32 = 0
        try check("creating a counter", call(CROI_SYS_COUNTER_CREATE, 0, address(&handle)))
        return handle
    }

    /// Raises a handshake counter to POSITIVE.
    static func signal(_ counter: UInt32) {
        _ = croi_counter_add(counter, 1)
    }

    /// Waits for a handshake counter to be POSITIVE, and takes it back to 0.
    static func take(_ counter: UInt32) {
        wait(counter, UInt32(CROI_COUNTER_POSITIVE))
        _ = croi_counter_add(counter, -1)
    }

    /// Waits for any of `signals` on `handle`: a binding on a port of its
    /// own (ports are the one wait, D23).
    static func wait(_ handle: UInt32, _ signals: UInt32) {
        var port: UInt32 = 0
        guard call(CROI_SYS_PORT_CREATE, 0, address(&port)) == 0 else { return }
        var packet = croi_port_packet_t()
        if bind(port, handle, UInt32(CROI_BIND_SIGNALS), key: 0, trigger: UInt64(signals)) == 0 {
            _ = unsafe croi_port_wait(port, .max, &packet, 0)
        }
        close(port)
    }

    /// A profile (needs the root resource): a priority or deadline
    /// parameters, on the CPUs in `mask` (0: anywhere).
    static func profile(_ resource: UInt32, priority: Int32? = nil, deadline: (UInt64, UInt64)? = nil,
                        mask: UInt64 = 0) throws(Failure) -> UInt32 {
        var info = croi_profile_info_t()
        if let priority {
            info.flags |= UInt32(CROI_PROFILE_INFO_FLAG_PRIORITY)
            info.priority = priority
        }
        if let (capacity, period) = deadline {
            info.flags |= UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE)
            info.deadline_params = croi_sched_deadline_params_t(capacity: Int64(capacity),
                                                                relative_deadline: Int64(period),
                                                                period: Int64(period))
        }
        if mask != 0 {
            info.flags |= UInt32(CROI_PROFILE_INFO_FLAG_CPU_MASK)
            info.cpu_mask.0 = mask
        }
        var handle: UInt32 = 0
        try check("creating a profile", call(CROI_SYS_PROFILE_CREATE, UInt64(resource), 0, address(&info),
                                             address(&handle)))
        return handle
    }

    static func apply(_ profile: UInt32, to thread: UInt32) throws(Failure) {
        var refusal: UInt32 = 0
        try check("applying a profile", call(CROI_SYS_OBJECT_SET_PROFILE, UInt64(thread), UInt64(profile), 0,
                                             address(&refusal)))
    }

    typealias ThreadEntry = @convention(c) (UInt64, UInt64) -> Void

    /// Starts a thread in this process at `entry(argument, 0)` on a 64 KiB
    /// stack; returns its handle. The entry must end with thread_exit.
    static func spawn(_ entry: ThreadEntry, _ argument: UInt64) throws(Failure) -> UInt32 {
        let name: StaticString = "m2-worker"
        var thread: UInt32 = 0
        try check("creating a thread", call(CROI_SYS_THREAD_CREATE, UInt64(td_runtime_process_self),
                                            unsafe UInt64(UInt(bitPattern: name.utf8Start)),
                                            UInt64(name.utf8CodeUnitCount), 0, address(&thread)))
        let size: UInt64 = 64 * 1024
        var stack: UInt32 = 0
        var base: UInt64 = 0
        try check("making a stack", call(CROI_SYS_VMO_CREATE, size, 0, address(&stack)))
        let rw = UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE)
        try check("mapping a stack", unsafe croi_vmar_map(td_runtime_vmar_root, rw, 0, stack, 0, size, &base))
        close(stack)
        #if arch(x86_64)
        let sp = base + size - 8  // as if called: a C entry expects it
        #else
        let sp = base + size
        #endif
        let pc = unsafe UInt64(UInt(bitPattern: unsafeBitCast(entry, to: UnsafeRawPointer.self)))
        try check("starting a thread", call(CROI_SYS_THREAD_START, UInt64(thread), pc, sp, argument, 0))
        return thread
    }

    static func exitThread() -> Never {
        _ = call(CROI_SYS_THREAD_EXIT, 0)
        fatalError()
    }
}
