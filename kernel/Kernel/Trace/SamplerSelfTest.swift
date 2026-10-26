import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for tick sampling (K6e): a kernel thread and a user
/// thread spin three frames deep while sampling runs at 1 kHz. Their
/// samples must carry their PCs and return addresses (kernel ones as image
/// offsets; user ones within the program, also from samples taken in a
/// syscall), each SAMPLE followed by its FRAMES records, and idle CPUs must
/// have no sampling timer armed (a tick on one would only lapse). Panics on
/// failure.
enum SamplerSelfTest {
    static var codeAt: UInt64 { 0x100_0000 }
    static var stackAt: UInt64 { 0x200_0000 }
    static var stackSize: UInt64 { 16 * 1024 }
    static var spinNs: UInt64 { 80_000_000 }
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var spinnerId: UInt32 = 0

    struct Counts {
        var samples = 0
        var withFrames = 0
        var inSyscall = 0
        var malformed = 0
        var foreign = 0
    }

    static func run(_ console: Uart) {
        let cpu = Smp.count - 1
        spinnerId = 0
        // Kernel.
        start()
        let kernelSpinner = spawn(cpu, spinKernel, 0)
        while spinnerId == 0 { Scheduler.sleep(until: Clock.now() + 1_000_000) }
        Scheduler.sleep(until: Clock.now() + 20_000_000)
        // A thread runs 3 ms on a third CPU and exits: that CPU was
        // sampled, then idled. Idle CPUs must have no sampling timer
        // (tickless), asked of each CPU while sampling is on, as the PMU
        // test does. Counting every sample and armed timer off the
        // spinner's CPU failed whenever a background thread (dlog-dumper,
        // reclaim) ran in the window: rv64 under TCG, three boots on
        // 2026-10-15. And with nothing run on them, idle CPUs were never
        // armed, so the check proved nothing.
        let bystanderCpu = (0..<Smp.count).first { $0 != cpu && $0 != Int(Cpu.current) }
        if let bystanderCpu { _ = spawn(bystanderCpu, bystand, 0).join() }
        Scheduler.sleep(until: Clock.now() + 5_000_000)
        armedWhileIdle.store(0, ordering: .relaxed)
        _ = Ipi.callOthers(checkIdleDisarmed, 0)
        let armedIdle = armedWhileIdle.load(ordering: .relaxed)
        _ = kernelSpinner.join()
        Trace.stop()
        let kernelId = spinnerId
        let kernel = scan(cpu, thread: kernelId, user: false)
        guard kernel.samples >= 20, kernel.withFrames * 10 >= kernel.samples * 9, kernel.malformed == 0,
              kernel.foreign == 0 else {
            report(console, "kernel", kernel)
            // Each CPU's timers and what its hardware is armed for: a dead
            // timer or a stalled vCPU (seen once under heavy host load,
            // 0 samples in the spinner's 80 ms; roadmap).
            Scheduler.dump(to: console)
            panic("sampler self-test: kernel samples")
        }
        guard armedIdle == 0 else {
            console.write("  sample: idle CPUs with a sampling timer armed ")
            console.write(decimal: armedIdle)
            console.write("\n")
            panic("sampler self-test: an idle CPU was ticking")
        }

        // Bursts shorter than the timer's slack, the CPU idle between them:
        // the period counts busy time, so about one sample in twenty
        // bursts (8 ms busy, 8 samples). A timer re-armed for a whole
        // period at each switch took none, and one re-armed for the rest
        // of it with slack almost none.
        start()
        spinnerId = 0
        _ = spawn(cpu, burstKernel, 0).join()
        Trace.stop()
        let bursts = scan(cpu, thread: spinnerId, user: false)
        guard bursts.samples >= 3, bursts.malformed == 0, bursts.foreign == 0 else {
            report(console, "bursts", bursts)
            panic("sampler self-test: bursts unsampled")
        }

        // User.
        var user = Counts()
        do throws(VmError) {
            let space = try UserAspace()
            aspace = space.record.address
            let size = (croi_user_program_size() + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
            let code = try Vmo(anonymous: size)
            code.writeBytes(at: 0, from: croi_user_program_address(), count: croi_user_program_size())
            try code.syncInstructions(offset: 0, size: croi_user_program_size())  // fresh pages may hold another program's code
            _ = try space.map(code, size: size, at: codeAt, rights: .read | .execute)
            let stack = try Vmo(anonymous: stackSize)
            _ = try space.map(stack, size: stackSize, at: stackAt, rights: .read | .write)
            start()
            spinnerId = 0
            let userSpinner = spawn(cpu, spinUser, 0)
            // It spins until its stack's lowest word is set (a clock read
            // would put samples in the vDSO, outside the program), timed
            // from when it starts.
            while spinnerId == 0 { Scheduler.sleep(until: Clock.now() + 1_000_000) }
            Scheduler.sleep(until: Clock.now() + spinNs)
            let stop: UInt64 = 1
            withUnsafeBytes(of: stop) { stack.writeBytes(at: 0, from: UInt64(UInt(bitPattern: $0.baseAddress!)), count: 8) }
            let code0 = userSpinner.join()
            Trace.stop()
            guard code0 == 0x600D else { panic("sampler self-test: user program failed") }
            user = scan(cpu, thread: spinnerId, user: true)
        } catch {
            panic("sampler self-test: out of memory")
        }
        guard user.samples >= 20, user.withFrames * 10 >= user.samples * 9, user.malformed == 0, user.foreign == 0,
              user.inSyscall > 0 else {
            report(console, "user", user)
            var total = 0, firstThread: UInt32 = 0
            Trace.forEachRecord(cpu) { record in
                if record.kind == UInt16(CROI_TK_SAMPLE) {
                    if total == 0 { firstThread = record.thread }
                    total += 1
                }
            }
            console.write("  sample: on cpu: ")
            console.write(decimal: UInt64(total))
            console.write(" samples, first thread ")
            console.write(hex: UInt64(firstThread))
            console.write(", spinner ")
            console.write(hex: UInt64(spinnerId))
            console.write(", arm failures ")
            console.write(decimal: Sampler.armFailures.load(ordering: .relaxed))
            console.write(", lapses ")
            console.write(decimal: Sampler.lapses.load(ordering: .relaxed))
            let percpu = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
            console.write(", armed ")
            console.write(hex: unsafe percpu.pointee.samplerArmed)
            let id = unsafe percpu.pointee.samplerTimer
            let state = Timers.inspect(cpu: cpu, id: id)
            console.write(" timer ")
            console.write(decimal: UInt64(id))
            console.write(state.deadline != nil ? " pending, due in " : " gone")
            if let due = state.deadline { console.write(decimal: due &- Clock.now()) }
            console.write(", programmed in ")
            console.write(decimal: state.programmed &- Clock.now())
            console.write(", pending ")
            console.write(decimal: UInt64(state.pending))
            console.write(", irqs ")
            console.write(decimal: state.interrupts)
            console.write("\n")
            panic("sampler self-test: user samples")
        }
        console.write("  sample: 1 kHz tick: kernel spinner ")
        console.write(decimal: UInt64(kernel.samples))
        console.write(" samples, short bursts ")
        console.write(decimal: UInt64(bursts.samples))
        console.write(", user spinner ")
        console.write(decimal: UInt64(user.samples))
        console.write(" (")
        console.write(decimal: UInt64(user.inSyscall))
        console.write(" in a syscall), frame-pointer stacks resolved; idle CPUs untouched\n")
    }

    private static func start() {
        do throws(VmError) {
            try Trace.start(categories: CROI_TRACE_SAMPLE, pages: 32, mode: UInt32(CROI_TRACE_ONESHOT), sampleHz: 1000)
        } catch {
            panic("sampler self-test: trace start")
        }
    }

    /// Checks `thread`'s samples on `cpu`: each SAMPLE is followed by its
    /// FRAMES; the PC and every frame lie in the kernel's text, or (user)
    /// in the user program, with at least two user frames.
    private static func scan(_ cpu: Int, thread: UInt32, user: Bool) -> Counts {
        var counts = Counts()
        var pendingFrames = 0
        var addresses = InlineArray<17, UInt64>(repeating: 0)
        var filled = 0
        var mine = false
        let textSize = kernel_text_end() - kernel_image_start()
        let userEnd = codeAt + croi_user_program_size()
        func isKernelText(_ a: UInt64) -> Bool { a & CROI_SAMPLE_KERNEL != 0 && a & ~CROI_SAMPLE_KERNEL < textSize }
        func isUserCode(_ a: UInt64) -> Bool { a >= codeAt && a < userEnd }
        func finish() {
            guard mine else { return }
            var userFrames = 0, kernelFrames = 0, other = 0
            for i in 1..<filled {
                if isKernelText(addresses[i]) { kernelFrames += 1 } else if isUserCode(addresses[i]) { userFrames += 1 } else { other += 1 }
            }
            let pcKernel = isKernelText(addresses[0])
            if user {
                if !pcKernel, !isUserCode(addresses[0]) { counts.foreign += 1 }
                if pcKernel, userFrames >= 3 { counts.inSyscall += 1 }
                if userFrames >= 2, other == 0 { counts.withFrames += 1 }
                if other != 0, !pcKernel { counts.foreign += 1 }
            } else {
                if !pcKernel || userFrames != 0 || other != 0 { counts.foreign += 1 }
                if kernelFrames >= 2 { counts.withFrames += 1 }
            }
        }
        Trace.forEachRecord(cpu) { record in
            if record.kind == UInt16(CROI_TK_SAMPLE) {
                if pendingFrames != 0 { counts.malformed += 1 }
                finish()
                mine = record.thread == thread
                if mine { counts.samples += 1 }
                let frames = Int(record.b >> 8)
                pendingFrames = (frames + 1) / 2
                addresses[0] = record.a
                filled = 1
                if frames > Int(CROI_SAMPLE_MAX_FRAMES) { counts.malformed += 1 }
            } else if record.kind == UInt16(CROI_TK_FRAMES) {
                guard pendingFrames > 0 else {
                    counts.malformed += 1
                    return
                }
                pendingFrames -= 1
                for value in [record.a, record.b] as InlineArray<2, UInt64> where value != 0 && filled < 17 {
                    addresses[filled] = value
                    filled += 1
                }
            }
        }
        if pendingFrames != 0 { counts.malformed += 1 }
        finish()
        return counts
    }

    /// CPUs that were idle with a sampling timer armed.
    static let armedWhileIdle = Atomic<UInt64>(0)

    private static let checkIdleDisarmed: Ipi.Function = { _ in
        let percpu = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        if Scheduler.current.pointee.isIdle, unsafe percpu.pointee.samplerArmed != 0 {
            armedWhileIdle.add(1, ordering: .relaxed)
        }
    }

    private static func report(_ console: Uart, _ what: StaticString, _ c: Counts) {
        console.write("  sample: ")
        console.write(what)
        console.write(": samples ")
        console.write(decimal: UInt64(c.samples))
        console.write(", with frames ")
        console.write(decimal: UInt64(c.withFrames))
        console.write(", in syscall ")
        console.write(decimal: UInt64(c.inSyscall))
        console.write(", malformed ")
        console.write(decimal: UInt64(c.malformed))
        console.write(", foreign ")
        console.write(decimal: UInt64(c.foreign))
        // Why there were none, if so: ticks that lapsed (idle, or no
        // interrupt frame) end a CPU's sampling until its next switch.
        console.write(", lapses ")
        console.write(decimal: Sampler.lapses.load(ordering: .relaxed))
        console.write(", arm failures ")
        console.write(decimal: Sampler.armFailures.load(ordering: .relaxed))
        console.write("\n")
    }

    private static let spinKernel: Thread.Entry = { _ in
        spinnerId = Scheduler.current.pointee.traceId
        return Int(truncatingIfNeeded: spin1(Clock.now() + spinNs))
    }

    static var burstNs: UInt64 { 50_000 }
    static var burstCount: Int { 160 }

    /// `burstCount` spins of a twentieth of the 1 kHz period, shorter than
    /// a timer's slack (an eighth), each followed by a sleep of four times
    /// as long, which idles the CPU.
    private static let burstKernel: Thread.Entry = { _ in
        spinnerId = Scheduler.current.pointee.traceId
        var n: UInt64 = 0
        for _ in 0..<burstCount {
            n &+= spin1(Clock.now() + burstNs)
            Scheduler.sleep(until: Clock.now() + 4 * burstNs)
        }
        return Int(truncatingIfNeeded: n)
    }

    @inline(never) private static func spin1(_ end: UInt64) -> UInt64 { spin2(end) &+ 1 }
    @inline(never) private static func spin2(_ end: UInt64) -> UInt64 { spin3(end) &+ 1 }
    @inline(never) private static func spin3(_ end: UInt64) -> UInt64 {
        var n: UInt64 = 0
        while Clock.now() < end { n &+= 1 }
        return n
    }

    private static let bystand: Thread.Entry = { _ in
        let end = Clock.now() + 3_000_000
        while Clock.now() < end {}
        return 0
    }

    private static let spinUser: Thread.Entry = { _ in
        spinnerId = Scheduler.current.pointee.traceId
        UserTraps.enter(UserAspacePointer(address: aspace), pc: codeAt, sp: stackAt + stackSize, arg0: 4, arg1: stackAt)
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("sample", cpu: cpu, entry, argument)
        } catch {
            panic("sampler self-test: spawn failed")
        }
    }
}
