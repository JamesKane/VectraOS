import CKernel
import Fmt
import Synchronization

/// Boot self-test for PMU counters (K6e): per-thread counts follow their
/// thread (two threads share a CPU, one doing ten times the other's
/// spinning, and each counts only its own cycles), and overflow sampling
/// writes PMU-sourced samples for every busy thread (the spinner, and a
/// bystander on a third CPU) with the counter stopped on idle CPUs.
/// Without a PMU (QEMU TCG on amd64) it says so; the tick sampler covers
/// those machines. Panics on failure.
enum PmuSelfTest {
    nonisolated(unsafe) static var results = InlineArray<2, UInt64>(repeating: 0)
    nonisolated(unsafe) static var spinnerId: UInt32 = 0
    nonisolated(unsafe) static var bystanderId: UInt32 = 0

    static func run(_ console: Uart) {
        let userCycles = runUser()
        console.write("  pmu:    ")
        guard Pmu.kind != UInt32(CROI_PMU_KIND_NONE) else {
            console.write("none (tick sampling only)\n")
            return
        }
        let names: InlineArray<5, StaticString> = ["none", "Intel PerfMon", "AMD core counters", "Arm PMUv3",
                                                   "SBI PMU"]
        console.write(names[Int(Pmu.kind)])
        console.write(", ")
        console.write(decimal: UInt64(Pmu.counters))
        console.write(" counters, events ")
        console.write(hex: UInt64(Pmu.events))
        guard Pmu.events & 1 != 0 else {
            console.write("; no cycle event, nothing to test\n")
            return
        }

        // Per-thread: 1 ms vs 10 ms of spinning per round, interleaved.
        let cpu = Smp.count - 1
        let small = spawn(cpu, counted, 0), big = spawn(cpu, counted, 1)
        _ = small.join()
        _ = big.join()
        guard results[0] > 0, results[1] > 4 * results[0] else {
            console.write("\n  pmu:    cycles ")
            console.write(decimal: results[0])
            console.write(" vs ")
            console.write(decimal: results[1])
            console.write("\n")
            panic("pmu self-test: per-thread counts aren't per thread")
        }
        console.write("; per-thread cycles ")
        console.write(decimal: results[1] / results[0])
        console.write("x for 10x the work")

        guard Pmu.canSample else {
            console.write("; no overflow interrupt, tick sampling only\n")
            return
        }
        // Overflow sampling on cycles: about every 0.2-1 ms of busy CPU.
        do throws(VmError) {
            try Trace.start(categories: CROI_TRACE_SAMPLE, pages: 32, mode: UInt32(CROI_TRACE_ONESHOT), sampleHz: 1)
        } catch {
            panic("pmu self-test: trace start")
        }
        let before = Pmu.overflows.load(ordering: .relaxed)
        do throws(Status) {
            try Pmu.startSampling(event: UInt32(CROI_PMU_CYCLES), period: 1_000_000)
        } catch {
            panic("pmu self-test: sampling refused")
        }
        spinnerId = 0
        bystanderId = 0
        let spinner = spawn(cpu, spin, 0)
        // A busy thread on a third CPU meanwhile, as a background thread
        // (dlog-dumper, reclaim) may be at any time: it is sampled too.
        // Counting any sample off the spinner's CPU as "on an idle CPU"
        // made this test fail whenever such a thread ran long enough to
        // overflow (rv64 under TCG, whose cycle counter follows host time:
        // about 1 boot in 6, 2026-10-15).
        let bystanderCpu = (0..<Smp.count).first { $0 != cpu && $0 != Int(Cpu.current) }
        let bystander = bystanderCpu.map { spawn($0, bystand, 0) }
        _ = spinner.join()
        _ = bystander?.join()
        // Idle CPUs must have the counter stopped: asked of each CPU while
        // sampling is still on, so a CPU that went idle and kept it armed
        // is caught whichever CPU this thread now runs on.
        armedWhileIdle.store(0, ordering: .relaxed)
        Ipi.callOthers(checkIdleStopped, 0)
        let armedIdle = armedWhileIdle.load(ordering: .relaxed)
        Pmu.stopSampling()
        Trace.stop()
        let overflows = Pmu.overflows.load(ordering: .relaxed) - before
        var mine = 0, withFrames = 0, bystanderSamples = 0
        for other in 0..<Smp.count {
            Trace.forEachRecord(other) { record in
                if record.kind == UInt16(CROI_TK_SAMPLE), record.b & 0xFF == 1 + UInt64(CROI_PMU_CYCLES) {
                    if other == cpu, record.thread == spinnerId {
                        mine += 1
                        if record.a & CROI_SAMPLE_KERNEL != 0, record.b >> 8 >= 2 { withFrames += 1 }
                    } else if bystanderCpu == other, record.thread == bystanderId {
                        bystanderSamples += 1
                    }
                }
            }
        }
        guard mine >= 5, withFrames * 10 >= mine * 9, bystanderCpu == nil || bystanderSamples >= 1, armedIdle == 0 else {
            console.write("\n  pmu:    overflows ")
            console.write(decimal: overflows)
            console.write(", samples ")
            console.write(decimal: UInt64(mine))
            console.write(", with frames ")
            console.write(decimal: UInt64(withFrames))
            console.write(", bystander's ")
            console.write(decimal: UInt64(bystanderSamples))
            console.write(", idle CPUs with the counter running ")
            console.write(decimal: armedIdle)
            console.write("\n")
            panic("pmu self-test: overflow sampling")
        }
        console.write("; overflow sampling: ")
        console.write(decimal: UInt64(mine))
        console.write(" cycle samples with stacks, ")
        console.write(decimal: UInt64(bystanderSamples))
        console.write(" from a busy third CPU, counter stopped on idle CPUs; from user mode: ")
        console.write(decimal: userCycles)
        console.write(" cycles counted\n")
    }

    /// User mode 5: pmu_configure's thread counters and refusals. Returns
    /// the cycles the program counted between its two reads.
    private static func runUser() -> UInt64 {
        do throws(VmError) {
            let space = try UserAspace()
            aspace = space.record.address
            let size = (croi_user_program_size() + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
            let code = try Vmo(anonymous: size)
            code.writeBytes(at: 0, from: croi_user_program_address(), count: croi_user_program_size())
            try code.syncInstructions(offset: 0, size: croi_user_program_size())  // fresh pages may hold another program's code
            _ = try space.map(code, size: size, at: 0x100_0000, rights: .read | .execute)
            let stack = try Vmo(anonymous: 16 * 1024)
            _ = try space.map(stack, size: 16 * 1024, at: 0x200_0000, rights: .read | .write)
            let handles = HandleTable()  // a process's, from K7
            table = handles.address
            let exit = spawn(Smp.count - 1, user, 0).join()
            guard exit == 0x600D else {
                if let console = panicConsole {
                    console.write("  pmu:    user program exit ")
                    console.write(hex: UInt64(bitPattern: Int64(exit)))
                    console.write("\n")
                }
                panic("pmu self-test: user program failed a check")
            }
        } catch {
            panic("pmu self-test: out of memory")
        }
        return Syscalls.reported.load(ordering: .relaxed)
    }

    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var table: UInt64 = 0

    private static let user: Thread.Entry = { _ in
        UserTraps.enter(UserAspacePointer(address: aspace), handles: table, pc: 0x100_0000, sp: 0x200_0000 + 16 * 1024, arg0: 5,
                        arg1: 0)
    }

    /// CPUs that were idle with the sampling counter running.
    static let armedWhileIdle = Atomic<UInt64>(0)

    private static let checkIdleStopped: Ipi.Function = { _ in
        if Scheduler.current.pointee.isIdle, Pmu.samplingArmedHere { armedWhileIdle.add(1, ordering: .relaxed) }
    }

    private static let counted: Thread.Entry = { which in
        var events = InlineArray<4, UInt32>(repeating: 0)
        events[0] = UInt32(CROI_PMU_CYCLES)
        do throws(Status) {
            try Pmu.enableThread(events, count: 1)
        } catch {
            return -1
        }
        let slice: UInt64 = which == 0 ? 1_000_000 : 10_000_000
        for _ in 0..<5 {
            let end = Clock.now() + slice
            while Clock.now() < end {}
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        results[Int(which)] = Pmu.readThread()?[0] ?? 0
        Pmu.disableThread()
        return 0
    }

    private static let spin: Thread.Entry = { _ in
        spinnerId = Scheduler.current.pointee.traceId
        let end = Clock.now() + 60_000_000
        while Clock.now() < end {}
        return 0
    }

    private static let bystand: Thread.Entry = { _ in
        bystanderId = Scheduler.current.pointee.traceId
        let end = Clock.now() + 20_000_000
        while Clock.now() < end {}
        return 0
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("pmu", cpu: cpu, entry, argument)
        } catch {
            panic("pmu self-test: spawn failed")
        }
    }
}
