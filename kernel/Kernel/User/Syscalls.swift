import CKernel
import Fmt
import PageTables
import Synchronization

/// User mode (K6a): traps and syscalls from user threads, and starting
/// them. A user thread's registers are an arch_exception_frame_t at the top
/// of its kernel stack while it is in the kernel.
enum UserTraps {
    /// Exit codes for threads the kernel killed (the K7 exception channel
    /// replaces this).
    static var killedByFault: Int { 0xDEAD_0001 }
    static var killedByException: Int { 0xDEAD_0002 }

    /// Anything arch_exception gets from user mode.
    static func handle(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        if unsafe ExceptionFrame.isInterrupt(frame.pointee) {
            unsafe Interrupts.handle(frame)
            Scheduler.preemptIfRequested()
            leaving()
            return
        }
        if unsafe ExceptionFrame.isSyscall(frame.pointee) {
            unsafe ExceptionFrame.enteredSyscall(&frame.pointee)
            unsafe Syscalls.dispatch(frame)
            leaving()
            return
        }
        if let fault = unsafe ExceptionFrame.pageFault(frame.pointee) {
            arch_interrupts_enable()
            let me = Scheduler.current
            me.pointee.restartable = true  // a pager wait here may end for a suspension (K13g)
            // Why not, for the exception's synth_code (D37).
            var status: Int32 = 0
            do throws(Status) {
                try UserAspaces.handleFault(at: fault.address, write: fault.write, execute: fault.execute,
                                            protectionKey: fault.protectionKey)
            } catch {
                status = error.rawValue
            }
            let resolved = status == 0
            me.pointee.restartable = false
            let retry = Scheduler.locked { () -> Bool in
                defer { me.pointee.suspendRetry = false }
                return me.pointee.suspendRetry
            }
            _ = arch_interrupts_save()
            if resolved || retry {  // a fault left for a suspension is taken again after
                leaving()
                return
            }
            if unsafe offer(frame, synthCode: UInt32(bitPattern: status)) { return }
            unsafe killed("page fault", frame.pointee)
            die(killedByFault)
        }
        if unsafe offer(frame) { return }
        unsafe killed("exception", frame.pointee)
        die(killedByException)
    }

    /// Offers a fault or exception to the thread's exception handlers (K7d):
    /// true if one handled it and the thread goes back to user mode
    /// (perhaps where the handler moved it).
    private static func offer(_ frame: UnsafeMutablePointer<arch_exception_frame_t>, synthCode: UInt32 = 0) -> Bool {
        let type = unsafe ExceptionFrame.exceptionType(frame.pointee)
        unsafe HardwareDebug.trapped(frame)  // DR6 / a watchpoint's FAR, before interrupts (K13g)
        arch_interrupts_enable()
        let disposition = unsafe Exceptions.raise(type, frame: frame, synthCode: synthCode)
        _ = arch_interrupts_save()
        switch disposition {
        case .resume:
            leaving()
            return true
        case .exitThread:
            arch_interrupts_enable()
            Processes.exitThread(0)
        case .unhandled:
            return false
        }
    }

    /// A user thread's registers while it is in the kernel: the frame at
    /// the top of its kernel stack.
    static func userFrame(of thread: ThreadPointer) -> UnsafeMutablePointer<arch_exception_frame_t> {
        let top = thread.pointee.stack.top
        return unsafe UnsafeMutablePointer<arch_exception_frame_t>(
            bitPattern: UInt(top) - UInt(MemoryLayout<arch_exception_frame_t>.stride))!
    }

    /// On every way back to user mode: a suspended thread parks (K13g), a
    /// killed one exits instead.
    static func leaving() {
        let me = Scheduler.current
        if me.pointee.suspendPending { Debug.park() }
        guard me.pointee.killPending else { return }
        arch_interrupts_enable()
        Processes.checkKilled()
    }

    /// A fault or exception nothing handles: a process's thread takes its
    /// whole process with it (K7d brings exception channels); a kernel
    /// test's bare user thread just exits with `code`.
    private static func die(_ code: Int) -> Never {
        arch_interrupts_enable()
        guard Scheduler.current.pointee.object != 0 else { Scheduler.exit(code) }
        Processes.killCurrentProcess(code: TaskReturnCode.exceptionKill)
    }

    /// Logs why a user thread dies (until K7's exception channels report it).
    private static func killed(_ what: StaticString, _ f: arch_exception_frame_t) {
        guard let console = panicConsole else { return }
        console.write("  user:   thread killed by ")
        console.write(what)
        #if arch(x86_64)
        console.write(", vector ")
        console.write(decimal: f.vector)
        console.write(" at ")
        console.write(hex: f.rip)
        #elseif arch(arm64)
        console.write(", ESR ")
        console.write(hex: f.esr)
        console.write(" at ")
        console.write(hex: f.elr)
        #elseif arch(riscv64)
        console.write(", scause ")
        console.write(decimal: f.scause)
        console.write(" at ")
        console.write(hex: f.sepc)
        #endif
        console.write("\n")
    }

    /// Starts the calling thread in user mode in `aspace`, its syscalls
    /// using the handle table at `handles` (0: none). Never returns.
    static func enter(_ aspace: UserAspacePointer, handles: UInt64 = 0, pc: UInt64, sp: UInt64, arg0: UInt64,
                      arg1: UInt64, arg2: UInt64 = 0) -> Never {
        let thread = Scheduler.current
        thread.pointee.handleTable = handles
        // Never return to a kernel or non-canonical PC (Processes.start and
        // the debugger paths check it; this is the backstop).
        if pc >= UserLayout.top, thread.pointee.object != 0 { Processes.exitThread(Int(TaskReturnCode.exceptionKill)) }
        // Started while its thread or process is suspended (K13g): parks first.
        if thread.pointee.object != 0,
           ThreadObjectPointer(object: ObjectPointer(address: thread.pointee.object)).pointee.suspendCount.load(ordering: .acquiring) > 0 {
            _ = arch_interrupts_save()
            Debug.park()
            arch_interrupts_enable()
        }
        // Every user thread has FP/SIMD state (K6d), loaded before it runs.
        if thread.pointee.extendedState == 0 { thread.pointee.extendedState = ExtendedState.allocate() }
        if thread.pointee.extendedState != 0 {
            _ = arch_interrupts_save()  // no switch between loading and entering
            unsafe arch_xstate_restore(UnsafeRawPointer(bitPattern: UInt(thread.pointee.extendedState))!)
        }
        Scheduler.setAspace(aspace)
        let top = Scheduler.current.pointee.stack.top
        Scheduler.setKernelStack(top)
        Scheduler.current.pointee.enteredUser = true
        arch_enter_user(pc, sp, arg0, arg1, arg2, top)
    }
}

/// The syscall table (user/include/croi/syscall.h has the numbers and
/// calling convention). Results are a status (0 or a negative Zircon code)
/// or a value; out-parameters are written through the fault-recovering
/// copies, so a bad user pointer is INVALID_ARGS, never a crash.
enum Syscalls {
    static let reported = Atomic<UInt64>(0)
    static let count = Atomic<UInt64>(0)

    /// Runs the syscall in `frame` with interrupts on, and leaves its result
    /// in the return register. Back with interrupts masked.
    static func dispatch(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        // Still masked: counted on the CPU that took it.
        unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.stats.syscalls += 1
        arch_interrupts_enable()
        let number = unsafe ExceptionFrame.syscallNumber(frame.pointee)
        var a = InlineArray<6, UInt64>(repeating: 0)
        for i in 0..<6 { a[i] = unsafe ExceptionFrame.syscallArgument(frame.pointee, i) }
        count.add(1, ordering: .relaxed)
        Trace.event(CROI_TRACE_SYSCALL, UInt16(CROI_TK_SYSCALL_ENTER), number, a[0])
        let me = Scheduler.current
        me.pointee.restartable = restartable(number)
        let result = run(number, a)
        me.pointee.restartable = false
        Trace.event(CROI_TRACE_SYSCALL, UInt16(CROI_TK_SYSCALL_EXIT), number, UInt64(bitPattern: result))
        let retry = Scheduler.locked { () -> Bool in
            defer { me.pointee.suspendRetry = false }
            return me.pointee.suspendRetry
        }
        if retry {
            unsafe ExceptionFrame.restartSyscall(&frame.pointee)  // made again once resumed (K13g)
        } else {
            unsafe ExceptionFrame.setSyscallResult(&frame.pointee, UInt64(bitPattern: result))
        }
        Scheduler.preemptIfRequested()
        _ = arch_interrupts_save()
    }

    /// Syscalls a suspension may end and restart (K13g): their waits leave
    /// nothing behind, and deadlines are absolute: port_wait, futex_wait.
    /// (A user fault's pager wait restarts too, by taking the fault again.)
    static func restartable(_ number: UInt64) -> Bool {
        switch number {
        case 33, 90: true
        default: false
        }
    }

    private static func run(_ number: UInt64, _ a: InlineArray<6, UInt64>) -> Int64 {
        switch number {
        case 0: return 0  // null
        case 2: Processes.exitThread(Int(Int64(bitPattern: a[0])))
        case 63: Processes.exitProcess(Int64(bitPattern: a[0]))  // process_exit: no handles needed
        case 90 where a[2] == 0, 91:  // futexes are keyed by address space: only an owner needs a handle
            do throws(Status) {
                try futexCall(number, a, owner: nil)
                return 0
            } catch {
                return Int64(error.rawValue)
            }
        case 6:
            // Test hooks reboot the machine, evict everyone's pages and
            // (arm64) sign with the kernel's key: test boots only (review
            // fix; they were open to every process).
            guard debuggingEnabled else { return Int64(Status.notSupported.rawValue) }
            #if arch(arm64)
            // K14p: the kernel key's signature of a[1] (modifier a[2]), for
            // a user test to compare with its own key's.
            if a[0] == 11 { return Int64(bitPattern: arch_pac_sign(a[1], a[2])) }
            if a[0] == 12 { return BranchTargets.enabled ? 1 : 0 }  // K14r: guarded pages in use
            #endif
            if a[0] == 13 { return TestHooks.fire(a[1], at: a[2]) }
            if a[0] == 14 {  // CROI_TEST_REPORT: a value for the self-test (test_report until D35)
                reported.store(a[1], ordering: .relaxed)
                return 0
            }
            return (6...9).contains(a[0]) ? Reclaim.testHook(a) : TestHooks.profile(a[0])
        case 181, 182:  // cprng_draw(buffer, length), cprng_add_entropy(buffer, length): K11b
            return Random.call(number, a)
        default:
            break
        }
        let table = Scheduler.current.pointee.handleTable
        guard table != 0 else { return Int64(Status.badState.rawValue) }
        let result: Int64
        do throws(Status) {
            result = try HandleTable.withBorrowed(table) { (handles: borrowing HandleTable) throws(Status) -> Int64 in
                try objectCall(number, a, handles)
            }
        } catch {
            if error == .badHandle { try? Policy.check(UInt32(CROI_POL_BAD_HANDLE)) }  // the result stays BAD_HANDLE
            return Int64(error.rawValue)
        }
        // vmar_unmap_handle_close_thread_exit, unmapped and closed (1: the
        // close failed). The thread exits here, where no frame holds a
        // reference.
        if number == 75 {
            if result != 0 { return trapAfterUnmap() }
            Processes.exitThread(0)
        }
        return result
    }

    /// Zircon's vDSO traps (`__builtin_trap`) when the handle can't be
    /// closed: an undefined-instruction exception goes to the handlers.
    /// Resumed, the call returns BAD_HANDLE.
    private static func trapAfterUnmap() -> Int64 {
        let me = Scheduler.current
        let frame = unsafe UserTraps.userFrame(of: me)
        switch unsafe Exceptions.raise(UInt32(CROI_EXCP_UNDEFINED_INSTRUCTION), frame: frame) {
        case .resume: break
        case .exitThread: Processes.exitThread(0)
        case .unhandled:
            if me.pointee.object != 0 {
                let process = ThreadObjectPointer(object: ObjectPointer(address: me.pointee.object)).pointee.process
                Processes.kill(process: process, code: TaskReturnCode.exceptionKill)
            }
        }
        return Int64(Status.badHandle.rawValue)
    }

    private static func objectCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                                   _ table: borrowing HandleTable) throws(Status) -> Int64 {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 10:  // handle_close(const uint32_t *handles, count), D33
            try closeHandles(table, handles: a[0], count: a[1])
        case 11:  // handle_duplicate(items, count): returns how many succeeded (D39; CONSUME replaces, D34)
            return try duplicateHandles(table, items: a[0], count: a[1])
        case 22:  // object_bind(port, items, count): returns how many were bound
            return try Bind.call(table, port: handle, items: a[1], count: a[2])
        case 31:  // port_create(options, out): with CROI_PORT_RING, out[1] is the ring's VMO (D44)
            try Policy.check(UInt32(CROI_POL_NEW_PORT))
            let ring = a[0] & UInt64(CROI_PORT_RING) != 0
            try check(a[1], MemoryLayout<UInt32>.size * (ring ? 2 : 1))
            let port = try Ports.create(options: a[0])
            var vmo: ObjectPointer? = nil
            if ring {
                do throws(Status) {
                    vmo = try Ports.makeRing(port)
                } catch {
                    port.release()
                    throw error
                }
            }
            let portHandle: UInt32
            do throws(Status) {
                portHandle = try table.add(port, rights: PortObject.defaultRights)
            } catch {
                port.release()
                vmo?.release()
                throw error
            }
            if let vmo {
                do throws(Status) {
                    try put(try table.add(vmo, rights: Ports.ringRights), a[1] + 4)
                } catch {
                    vmo.release()
                    try? table.close(portHandle)
                    throw error
                }
            }
            try put(portHandle, a[1])
        case 32:  // port_queue(port, packets, count): returns how many were queued (D40)
            return try queuePackets(table, handle, packets: a[1], count: a[2])
        case 33:  // port_wait(port, deadline, packets, count, leeway): returns how many it took (D40)
            return try waitPackets(table, handle, deadline: a[1], packets: a[2], count: a[3], leeway: a[4])
        case 161:  // counter_add(items, count): returns how many succeeded (D40)
            return try addCounters(table, items: a[0], count: a[1])
        case 142:  // interrupt_ack(items, count): returns how many succeeded (D40)
            return try ackInterrupts(table, items: a[0], count: a[1])
        case 71:  // vmar_map(vmar, items, count): returns how many were mapped (D42)
            return try vmarMap(table, vmar: handle, items: a[1], count: a[2])
        case 72, 73:  // vmar_unmap, vmar_protect(vmar, ranges, count): returns how many succeeded (D42)
            return try vmarRanges(table, protect: number == 73, vmar: handle, ranges: a[1], count: a[2])
        case 81:  // channel_write(items, count): returns how many succeeded (D41)
            return try writeChannels(table, items: a[0], count: a[1])
        case 82:  // channel_read(items, count): returns how many succeeded (D41)
            return try readChannels(table, items: a[0], count: a[1])
        case 34:  // port_cancel(port, source or 0, key); 0 cancels the key from every source (D32)
            let source = UInt32(truncatingIfNeeded: a[1])
            if source == 0 {
                try Ports.cancelKey(table, port: handle, key: a[2])
            } else {
                try Ports.cancel(table, port: handle, source: source, key: a[2])
            }
        case 40:  // vmo_create
            try Policy.check(UInt32(CROI_POL_NEW_VMO))
            try check(a[2], MemoryLayout<UInt32>.size)
            // K15a: charged to the caller's process's account, or with
            // CROI_VMO_CHARGE_TO to the account handle in the fourth argument.
            let chargeTo = a[1] & UInt64(CROI_VMO_CHARGE_TO) != 0
            let account = try Accounts.forNewVmo(table, chargeTo: chargeTo ? UInt32(truncatingIfNeeded: a[3]) : nil)
            defer { account?.release() }
            let (vmo, rights) = try VmoObject.create(size: a[0], options: a[1] & ~UInt64(CROI_VMO_CHARGE_TO),
                                                     account: account)
            try put(try table.add(vmo, rights: rights), a[2])
        case 48:  // vmo_create_child(vmo, options, offset, size, uint32_t *out), K11a
            try VmoObject.createChildCall(a, table)
        case 49:  // vmo_replace_as_executable(vmo, vmex, out), K13b: the handle goes either way
            try check(a[2], MemoryLayout<UInt32>.size)
            _ = try table.get(handle, type: .vmo)
            do throws(Status) {
                try Resources.check(table, UInt32(truncatingIfNeeded: a[1]), system: UInt64(CROI_RSRC_SYSTEM_VMEX_BASE))
            } catch {
                try? table.close(handle)
                throw error
            }
            let (object, rights) = try table.take(handle)  // its rights from the same lookup (review fix)
            guard object.header.type == .vmo else {  // replaced meanwhile: gone either way
                object.release()
                throw .wrongType
            }
            do throws(Status) {
                try put(try table.add(object, rights: rights | .execute), a[2])
            } catch {
                object.release()
                throw error
            }
        case 50:  // trace_configure
            switch a[1] {
            case 0: try TraceControl.start(table, handle, categories: UInt32(truncatingIfNeeded: a[2]),
                                           pages: Int(clamping: a[3]),  // review fix: Int(a[3]) trapped past 2^63
                                           mode: UInt32(truncatingIfNeeded: a[4]), sampleHz: a[5])
            case 1: try TraceControl.stop(table, handle)
            case 2: try TraceControl.rewind(table, handle)
            case 3: try TraceControl.mark(table, handle, a[2], a[3])
            case 4:  // rings: a handle per CPU into uint32_t[a[3]] at a[2]; returns the count
                guard a[3] >= UInt64(Smp.count) else { throw .bufferTooSmall }
                try check(a[2], Smp.count * 4)
                let rings = try TraceControl.rings(table, handle)
                for i in 0..<rings.count {
                    do throws(Status) {
                        try put(rings[i], a[2] + UInt64(i) * 4)
                    } catch {
                        for j in 0..<rings.count { try? table.close(rings[j]) }
                        throw error
                    }
                }
                return Int64(rings.count)
            default: throw .invalidArgs
            }
        case 51:  // pmu_configure
            try pmuConfigure(table, handle, a)
        case 75:
            return try unmapAndClose(a, table)
        case 60...79, 244:  // 244: vmar_map_view (K15b)
            try taskCall(number, a, table)
        case 45, 46, 47, 130...149:
            try driverCall(number, a, table)
        case 150...159:
            try dmaCall(number, a, table)
        case 160...179:
            try counterCall(number, a, table)
        case 234:  // smc_call(resource, const croi_smc_parameters_t *, croi_smc_result_t *), K13i
            try smcCall(a, table)
        case 233:  // vmo_set_size(vmo, size), K13h
            try VmoObject.setSize(table, handle, a[1])
        case 230...232:
            try debugCall(number, a, table)
        case 240...243:
            try accountCall(number, a, table)  // K15a
        case 202...208:
            try pagerCall(number, a, table)
        case 180:  // system_powerctl
            try Power.call(a, table)
        case 120...129:
            try Profiles.call(number, a, table)
        case 110...119:
            return try DebugLogs.call(number, a, table)
        case 100...109:
            try exceptionCall(number, a, table)
        case 86 where a[1] == UInt64(CROI_INFO_CPU_STATS):  // returns a count
            return try CpuStatistics.info(a, table)
        case 86 where a[1] == UInt64(CROI_INFO_CPU_IDLE_STATES):  // K15c
            try idleInfo(a, table)
        case 245:  // cpu_set_idle_states (K15c)
            try idleCall(a, table)
        case 80...89, 210...215:
            try ipcCall(number, a, table)
        case 90:  // with an owner (`run` takes the rest)
            try syncCall(number, a, table)
        default:
            throw .notSupported
        }
        return 0
    }

    /// pmu_configure: a thread's own counters need nothing; sampling
    /// (every thread on every CPU) needs the tracing resource.
    private static func pmuConfigure(_ table: borrowing HandleTable, _ handle: UInt32,
                                     _ a: InlineArray<6, UInt64>) throws(Status) {
        switch a[1] {
        case 0:
            try check(a[2], MemoryLayout<croi_pmu_info_t>.size)
            try put(croi_pmu_info_t(kind: Pmu.kind, counters: UInt32(Pmu.threadCounters), events: Pmu.events,
                                    sampling: Pmu.canSample ? 1 : 0), a[2])
        case 1:
            try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_TRACING_BASE))
            try Pmu.startSampling(event: UInt32(truncatingIfNeeded: a[2]), period: a[3])
        case 2:
            try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_TRACING_BASE))
            Pmu.stopSampling()
        case 3:
            guard a[2] >= 1, a[2] <= UInt64(CROI_PMU_THREAD_EVENTS) else { throw .invalidArgs }
            var events = InlineArray<4, UInt32>(repeating: 0)
            var span = events.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[3], a[2] * 4)
            }
            guard copied == 0 else { throw .invalidArgs }
            try Pmu.enableThread(events, count: Int(a[2]))
        case 4:
            try check(a[2], 32)
            guard let values = Pmu.readThread() else { throw .badState }
            try put(values, a[2])
        case 5:
            Pmu.disableThread()
        default:
            throw .invalidArgs
        }
    }

    // MARK: User memory

    /// Copies `value` out to user address `address`.
    static func put<T: BitwiseCopyable>(_ value: T, _ address: UInt64) throws(Status) {
        var copy = value
        let result = withUnsafeBytes(of: &copy) { unsafe UserCopy.to(address, $0.baseAddress!, UInt64($0.count)) }
        guard result == 0 else { throw .invalidArgs }
    }

    /// Checks an out-pointer is writable before doing anything (so a bad
    /// pointer doesn't leave a handle created that nobody can close).
    /// Checks an out-pointer is writable user memory before acting, so a
    /// bad pointer fails the call before it changes anything (the copy
    /// out still recovers from faults). Asks the address space's mappings:
    /// nothing is read or written, so any size works.
    static func check(_ address: UInt64, _ size: Int) throws(Status) {
        guard size > 0 else { return }
        let me = Scheduler.current
        guard let aspace = me.pointee.aspace else { throw .invalidArgs }
        // K14m: inside the mapping the last check found, with the mappings
        // unchanged since (a thread's address space never changes), no
        // lock: as good as the locked answer, which could also be stale by
        // the time the copy runs (the copy recovers from faults either way).
        let (end, overflow) = address.addingReportingOverflow(UInt64(size))
        if !overflow, address >= me.pointee.coverStart, end <= me.pointee.coverEnd,
           aspace.pointee.mapGeneration.load(ordering: .acquiring) == me.pointee.coverGeneration {
            return
        }
        guard let found = UserAspace.borrowing(aspace).coverage(address, size: UInt64(size), rights: .write) else {
            throw .invalidArgs
        }
        if found.end > found.start {
            me.pointee.coverStart = found.start
            me.pointee.coverEnd = found.end
            me.pointee.coverGeneration = found.generation
        }
    }

    /// port_queue (D40): `count` user packets in order, stopping at the
    /// first that fails (one it can't read too: the packets are only
    /// read, so read-only memory will do); how many were queued, or the
    /// first one's status.
    private static func queuePackets(_ table: borrowing HandleTable, _ port: UInt32, packets: UInt64,
                                     count: UInt64) throws(Status) -> Int64 {
        let size = UInt64(MemoryLayout<PortPacket>.size)
        guard count > 0, count <= UInt64(CROI_PORT_MAX_PACKETS) else { throw .invalidArgs }
        for i in 0..<count {
            do throws(Status) {
                try Ports.queue(table, port, try getPacket(packets + i * size))
            } catch {
                if i == 0 { throw error }
                return Int64(i)
            }
        }
        return Int64(count)
    }

    /// port_wait (D40): waits for the first packet, then takes up to
    /// `count` in all without waiting again; how many it took. With a
    /// count of 0, a ring port's wait for its ring (D44).
    private static func waitPackets(_ table: borrowing HandleTable, _ port: UInt32, deadline: UInt64,
                                    packets: UInt64, count: UInt64, leeway: UInt64) throws(Status) -> Int64 {
        let size = UInt64(MemoryLayout<PortPacket>.size)
        if count == 0 {
            try Ports.waitRing(table, port, deadline: deadline, leeway: leeway)
            return 0
        }
        guard count <= UInt64(CROI_PORT_MAX_PACKETS) else { throw .invalidArgs }
        try check(packets, Int(count * size))
        try putPacket(try Ports.wait(table, port, deadline: deadline, leeway: leeway), packets)
        var taken: UInt64 = 1
        while taken < count, let packet = try Ports.poll(table, port) {
            do throws(Status) { try putPacket(packet, packets + taken * size) } catch { break }
            taken += 1
        }
        return Int64(taken)
    }

    /// The batched calls that go on past a failed item (counter_add and
    /// interrupt_ack, D40): `count` items of `size` bytes, each a handle,
    /// an int32 status written back, and for counter_add an int64. Returns
    /// how many succeeded; a bad pointer or count fails before any item.
    static func eachItem(_ items: UInt64, count: UInt64, max: UInt32, size: UInt64,
                         _ body: (UInt32, UInt64) throws(Status) -> Void) throws(Status) -> Int64 {
        guard count > 0, count <= UInt64(max) else { throw .invalidArgs }
        try check(items, Int(count * size))
        var done: Int64 = 0
        for i in 0..<count {
            let address = items + i * size
            var raw = InlineArray<2, UInt64>(repeating: 0)  // handle | status << 32, then the int64
            var span = raw.mutableSpan
            let copied = span.withUnsafeMutableBytes { unsafe UserCopy.from($0.baseAddress!, address, size) }
            guard copied == 0 else { throw .invalidArgs }
            var status: Int32 = 0
            do throws(Status) { try body(UInt32(truncatingIfNeeded: raw[0]), raw[1]) } catch { status = error.rawValue }
            try put(status, address + 4)
            if status == 0 { done += 1 }
        }
        return done
    }

    private static func getPacket(_ address: UInt64) throws(Status) -> PortPacket {
        var raw = InlineArray<6, UInt64>(repeating: 0)  // key, type|status, payload[4]
        var span = raw.mutableSpan
        let copied = span.withUnsafeMutableBufferPointer { unsafe UserCopy.from($0.baseAddress!, address, 48) }
        guard copied == 0 else { throw .invalidArgs }
        var packet = PortPacket(key: raw[0], type: UInt32(truncatingIfNeeded: raw[1]),
                                status: Int32(truncatingIfNeeded: Int64(bitPattern: raw[1] >> 32)))
        for i in 0..<4 { packet.payload[i] = raw[2 + i] }
        return packet
    }

    private static func putPacket(_ packet: PortPacket, _ address: UInt64) throws(Status) {
        var raw = InlineArray<6, UInt64>(repeating: 0)
        raw[0] = packet.key
        raw[1] = UInt64(packet.type) | UInt64(UInt32(bitPattern: packet.status)) << 32
        for i in 0..<4 { raw[2 + i] = packet.payload[i] }
        let copied = raw.span.withUnsafeBufferPointer { unsafe UserCopy.to(address, $0.baseAddress!, 48) }
        guard copied == 0 else { throw .invalidArgs }
    }
}

#if arch(x86_64)
/// The SYSCALL entry's handler (exceptions.S).
@c @implementation
func arch_syscall(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
    unsafe Syscalls.dispatch(frame)
    // Back to user mode by sysretq: the kill check UserTraps.handle makes
    // on every other way back. Without it a killed thread whose syscalls
    // returned (an interrupted wait, a retry loop) ran on until an
    // interrupt caught it in user mode: on an idle, tickless CPU, seconds
    // (Todhchai's compositor kill).
    UserTraps.leaving()
}
#endif

/// The only way syscalls touch user memory: the user range is checked
/// first (the fault-recovering copies would happily write kernel pages
/// through a pointer user space chose: SMAP only guards user pages), then
/// the arch copy. 0 or -1, as the arch functions.
enum UserCopy {
    @unsafe static func from(_ destination: UnsafeMutableRawPointer, _ source: UInt64, _ length: UInt64) -> Int32 {
        guard length == 0 || UserLayout.contains(source, length) else { return -1 }
        return unsafe arch_copy_from_user(destination, source, length)
    }

    /// A 32-bit user word, without paging anything in (interrupts must be
    /// masked, e.g. under the scheduler lock): nil if it isn't resident or
    /// isn't readable.
    static func wordNoPageIn(_ address: UInt64) -> UInt32? {
        guard UserLayout.contains(address, 4) else { return nil }
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe percpu.pointee.noPageIn = true
        var value: UInt32 = 0
        let result = withUnsafeMutableBytes(of: &value) { unsafe arch_copy_from_user($0.baseAddress!, address, 4) }
        unsafe percpu.pointee.noPageIn = false
        return result == 0 ? value : nil
    }

    @unsafe static func to(_ destination: UInt64, _ source: UnsafeRawPointer, _ length: UInt64) -> Int32 {
        guard length == 0 || UserLayout.contains(destination, length) else { return -1 }
        return unsafe arch_copy_to_user(destination, source, length)
    }

    /// `to` and `from` without paging anything in (interrupts masked, e.g.
    /// under a VMO's lock): a fault fails the copy (K14h, VmoUserCopy).
    @unsafe static func toNoPageIn(_ destination: UInt64, _ source: UnsafeRawPointer, _ length: UInt64) -> Int32 {
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe percpu.pointee.noPageIn = true
        let result = unsafe to(destination, source, length)
        unsafe percpu.pointee.noPageIn = false
        return result
    }

    @unsafe static func fromNoPageIn(_ destination: UnsafeMutableRawPointer, _ source: UInt64, _ length: UInt64) -> Int32 {
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe percpu.pointee.noPageIn = true
        let result = unsafe from(destination, source, length)
        unsafe percpu.pointee.noPageIn = false
        return result
    }
}

/// Test-only syscall 6 (`test_profile`), until profiles are objects:
/// op 0 reports whether the calling thread's effective profile is a
/// deadline one (1) or fair (0); op 1 binds the caller to the deadline
/// context a kernel self-test provided; op 2 unbinds it.
enum TestHooks {
    nonisolated(unsafe) static var deadlineContext: SchedContextPointer? = nil

    static func profile(_ op: UInt64) -> Int64 {
        let me = Scheduler.current
        switch op {
        case 0: return Scheduler.effectiveProfile(of: me).discipline == .deadline ? 1 : 0
        case 1:
            guard let context = deadlineContext else { return Int64(Status.badState.rawValue) }
            Scheduler.bind(me, context)
            return 0
        case 2:
            Scheduler.bind(me, nil)
            return 0
        case 3: return Int64(bitPattern: Scheduler.currentPeriod().start)     // K10c tests
        case 4: return Int64(bitPattern: Scheduler.currentPeriod().deadline)
        case 5: return Int64(Cpu.current)  // K10d tests
        case 10: return Int64(Scheduler.borrowedCpu())  // K14e: the borrowed context's CPU, or -1
        default: return Int64(Status.invalidArgs.rawValue)
        }
    }

    /// Fires the interrupt object `handle` names as its device would, at
    /// `time`: V1 cut virtual interrupts (D29), and a test can't make a
    /// real device fire on demand everywhere (arm64's PL031 counts whole
    /// seconds).
    static func fire(_ handle: UInt64, at time: UInt64) -> Int64 {
        let table = Scheduler.current.pointee.handleTable
        guard table != 0, time != 0 else { return Int64(Status.badState.rawValue) }
        do throws(Status) {
            try HandleTable.withBorrowed(table) { (handles: borrowing HandleTable) throws(Status) in
                InterruptObjects.fire(try handles.get(UInt32(truncatingIfNeeded: handle), type: .interrupt).object,
                                      at: time)
            }
            return 0
        } catch {
            return Int64(error.rawValue)
        }
    }
}
