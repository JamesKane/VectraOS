import CroiRuntime

/// CPU idle states (cpu_set_idle_states, power.h), moved here from
/// usertest.c's checks 729-736 (mode 17) when check 731 failed twice on
/// rv64 with no way to tell which of its four parts had: each is a named
/// check now. Waits that judged a fixed 50 ms window poll up to a deadline
/// instead, so a slow vCPU takes longer rather than failing.
enum IdleSuite {
    static func run() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0)))
        refusals(root)
        chosen(root)
        bound(root)
        hardware(root)
        check(Sys.call(CROI_SYS_CPU_SET_IDLE_STATES, root.arg, 0, 0, 0) == 0, "CPU 0 back to halt only")
        print("swift: idle passed")
    }

    static var halt: croi_idle_state_t {
        croi_idle_state_t(exit_latency_ns: 1000, target_residency_ns: 1000, param: 0,
                          method: UInt32(CROI_IDLE_METHOD_HALT), flags: 0)
    }

    static func set(_ root: borrowing Handle, cpu: UInt64, _ states: inout InlineArray<9, croi_idle_state_t>,
                    _ count: UInt64) -> Int64 {
        Sys.call(CROI_SYS_CPU_SET_IDLE_STATES, root.arg, cpu, Sys.address(&states), count)
    }

    /// One CPU state's counters (zero if the topic has none).
    static func stats(_ root: borrowing Handle, cpu: UInt32, state: UInt32) -> croi_idle_state_stats_t {
        var all = InlineArray<128, croi_idle_state_stats_t>(repeating: croi_idle_state_stats_t())
        var actual: UInt64 = 0
        var available: UInt64 = 0
        guard Sys.call(CROI_SYS_OBJECT_GET_INFO, root.arg, UInt64(CROI_INFO_CPU_IDLE_STATES), Sys.address(&all),
                       UInt64(MemoryLayout<croi_idle_state_stats_t>.stride * 128), Sys.address(&actual),
                       Sys.address(&available)) == 0 else { return croi_idle_state_stats_t() }
        for i in 0..<Int(min(actual, 128)) where all[i].cpu == cpu && all[i].state == state { return all[i] }
        return croi_idle_state_stats_t()
    }

    /// Polls `condition` every 5 ms for up to 2 s.
    static func soon(_ condition: () -> Bool) -> Bool {
        let giveUp = Sys.now() + 2_000_000_000
        while !condition() && Sys.now() < giveUp { Sys.sleep(5_000_000) }
        return condition()
    }

    /// Too many states, latencies out of order, unknown flags and a method
    /// this CPU lacks are refused.
    static func refusals(_ root: borrowing Handle) {
        var table = InlineArray<9, croi_idle_state_t>(repeating: halt)
        for i in 0..<9 { table[i].exit_latency_ns = 1000 * UInt64(i + 1) }
        check(set(root, cpu: 0, &table, 9) == Status.invalidArgs, "too many states")
        var two = InlineArray<9, croi_idle_state_t>(repeating: halt)
        two[0].exit_latency_ns = 2000
        check(set(root, cpu: 0, &two, 2) == Status.invalidArgs, "latencies out of order")
        var flagged = InlineArray<9, croi_idle_state_t>(repeating: halt)
        flagged[0].flags = 1 << 7
        check(set(root, cpu: 0, &flagged, 1) == Status.invalidArgs, "an unknown flag")
        var foreign = InlineArray<9, croi_idle_state_t>(repeating: halt)
        #if arch(x86_64)
        foreign[0].method = UInt32(CROI_IDLE_METHOD_PSCI)
        #else
        foreign[0].method = UInt32(CROI_IDLE_METHOD_MWAIT)
        #endif
        check(set(root, cpu: 0, &foreign, 1) == Status.notSupported, "a method this CPU lacks")
    }

    /// CPU 0 gets a shallow state, a deep one (10 ms to wake) and a third
    /// that stops the timer: it enters the deep one, never demoted with
    /// nothing bounding it, and skips the third without entering it.
    static func chosen(_ root: borrowing Handle) {
        var three = InlineArray<9, croi_idle_state_t>(repeating: halt)
        three[1].exit_latency_ns = 10_000_000
        three[2].exit_latency_ns = 10_000_000
        three[2].flags = UInt32(CROI_IDLE_FLAG_TIMER_STOPS)
        check(set(root, cpu: 0, &three, 3) == 0, "three states on CPU 0")
        check(soon { stats(root, cpu: 0, state: 1).entries > 0 }, "the deep state entered")
        check(soon { stats(root, cpu: 0, state: 2).skipped > 0 }, "the timer-stopping state skipped")
        check(stats(root, cpu: 0, state: 2).entries == 0, "and never entered")
        check(stats(root, cpu: 0, state: 1).demoted == 0, "nothing demoted with no bound")
    }

    /// An interrupt on CPU 0 with a deadline profile (100 us every 1 ms: a
    /// bound of ~0.9 ms) keeps CPU 0 out of the 10 ms state until it goes.
    /// The RTC's, which stays quiet (V1 cut virtual interrupts, D29).
    static func bound(_ root: borrowing Handle) {
        let profile = InterruptSuite.deadlineProfile(root, 100_000, 1_000_000, 1_000_000)
        var raw: UInt32 = 0
        check(InterruptSuite.create(root, InterruptSuite.number, options: 0, &raw) == 0, "the RTC's interrupt")
        let interrupt = Handle(adopting: raw)
        // The profile makes CPU 0 choose again at once: counted from before it.
        let before = stats(root, cpu: 0, state: 1)
        check(InterruptSuite.setProfile(interrupt, profile, 0) == 0, "given the deadline profile")
        check(soon { stats(root, cpu: 0, state: 1).demoted > before.demoted }, "CPU 0 demoted from the deep state")
        // Its entries counted from once a demotion is seen, not from
        // before the profile: until then CPU 0 may rightly enter it, woken
        // meanwhile, or choosing with the bound it read just before the
        // profile came (the profile's kick then ends that idle at once).
        let bounded = stats(root, cpu: 0, state: 1)
        Sys.sleep(50_000_000)
        let during = stats(root, cpu: 0, state: 1)
        check(during.entries == bounded.entries, "and never entered it while bound")
        _ = consume interrupt
        check(soon { stats(root, cpu: 0, state: 1).entries > during.entries }, "entered again once the interrupt goes")
    }

    /// The hardware's own: MWAIT C1 (amd64, where the CPU has MONITOR) and
    /// PSCI standby (arm64), on CPU 0.
    static func hardware(_ root: borrowing Handle) {
        var state = InlineArray<9, croi_idle_state_t>(repeating: halt)
        #if arch(x86_64)
        state[0].method = UInt32(CROI_IDLE_METHOD_MWAIT)
        let installed = set(root, cpu: 0, &state, 1)
        check(installed == 0 || installed == Status.notSupported, "MWAIT installed, or no MONITOR")
        if installed == 0 { check(soon { stats(root, cpu: 0, state: 0).entries > 0 }, "MWAIT entered") }
        #elseif arch(arm64)
        state[0].method = UInt32(CROI_IDLE_METHOD_PSCI)
        check(set(root, cpu: 0, &state, 1) == 0, "PSCI standby installed")
        check(soon { stats(root, cpu: 0, state: 0).entries > 0 }, "PSCI standby entered")
        #endif
    }
}
