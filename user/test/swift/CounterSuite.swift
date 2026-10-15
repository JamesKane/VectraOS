import CroiRuntime

/// Counters (K10a): Zircon's calls and signals, rights, value bindings,
/// and the deadline a counter lends the thread its packet wakes (K10c,
/// ext 5). Moved here from usertest.c's mode 14 and mode 16's lending
/// check when V1 cut counter_write and counter_wait (D25): an add of the
/// difference sets a value, and a port is the one wait.
enum CounterSuite {
    static func run() {
        basics()
        rights()
        values()
        lending()
        print("swift: counters passed")
    }

    static var positive: UInt32 { UInt32(CROI_COUNTER_POSITIVE) }
    static var nonPositive: UInt32 { UInt32(CROI_COUNTER_NON_POSITIVE) }
    static var value: UInt32 { UInt32(CROI_BIND_VALUE) }

    static func add(_ counter: borrowing Handle, _ amount: Int64) -> Int64 {
        Sys.call(CROI_SYS_COUNTER_ADD, counter.arg, UInt64(bitPattern: amount))
    }

    static func read(_ counter: borrowing Handle) -> Int64? {
        var value: Int64 = 0
        return Sys.call(CROI_SYS_COUNTER_READ, counter.arg, Sys.address(&value)) == 0 ? value : nil
    }

    /// Sets the value with an add of the difference.
    static func set(_ counter: borrowing Handle, _ value: Int64) {
        guard let now = read(counter) else { return check(false, "counter_read") }
        check(add(counter, value &- now) == 0, "an add of the difference")
    }

    /// Zircon's: no options, NON_POSITIVE at 0, POSITIVE above it, an add
    /// that would overflow refused with the value unchanged.
    static func basics() {
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_COUNTER_CREATE, 1, Sys.address(&raw)) == Status.invalidArgs, "options are refused")
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        check(Port.signals(of: counter, nonPositive) & nonPositive != 0 && read(counter) == 0, "a new counter is 0")
        check(add(counter, 5) == 0 && Port.signals(of: counter, positive) & (positive | nonPositive) == positive,
              "POSITIVE, and only that, above 0")
        set(counter, -3)
        check(Port.signals(of: counter, nonPositive) & (positive | nonPositive) == nonPositive,
              "NON_POSITIVE below 0")
        set(counter, 0)
        set(counter, .max)  // from 0: the difference itself fits
        check(add(counter, 1) == Status.outOfRange && read(counter) == .max, "an overflow is refused, nothing changed")
        check(Sys.call(CROI_SYS_COUNTER_READ, counter.arg, 0) == Status.invalidArgs, "a null value pointer")
    }

    /// add needs READ and WRITE; a VALUE binding WAIT and READ.
    static func rights() {
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        let reader = Handle(duplicating: counter, rights: 1 << 2 | 1 << 14)  // READ, WAIT
        check(add(reader, 1) == Status.accessDenied && read(reader) == 0, "READ and WAIT: reads, can't add")
        let waiter = Handle(duplicating: counter, rights: 1 << 14)  // WAIT
        let port = Port()
        check(port.bind(waiter, value, key: 1, trigger: 0) == Status.accessDenied, "a VALUE binding needs READ")
    }

    /// VALUE bindings: a packet once the value is reached (at once if it
    /// is), with the target, the value and the time; none before;
    /// cancelled by port_cancel or by closing the handle bound through.
    static func values() {
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        let port = Port()
        check(port.bind(counter, value, key: 1, trigger: 0) == 0 && port.next()?.key == 1, "reached: at once")
        check(port.bind(counter, value, key: 2, trigger: UInt64(bitPattern: -5)) == 0 && port.next()?.key == 2,
              "a target below the value: at once")
        let before = Sys.now()
        check(port.bind(counter, value, key: 3, trigger: 10) == 0 && port.next(deadline: Sys.now() + 1_000_000) == nil,
              "not before it is reached")
        check(add(counter, 5) == 0 && port.empty, "not on the way")
        check(add(counter, 7) == 0, "past it")
        guard let reached = port.next() else { return check(false, "a packet once reached") }
        check(reached.type == UInt32(CROI_PKT_TYPE_COUNTER) && reached.key == 3 && reached.payload.0 == 10
                  && reached.payload.1 == 12 && reached.payload.2 >= before,
              "the target, the value reached, and the time")
        check(port.empty, "once")
        check(port.bind(counter, value, key: 4, trigger: 100) == 0 && port.cancel(counter, key: 4) == 0, "cancelled")
        set(counter, 200)
        check(port.empty, "nothing after port_cancel")
        do {
            let through = Handle(duplicating: counter)
            check(port.bind(through, value, key: 5, trigger: 300) == 0, "bound through a duplicate")
        }  // the duplicate closes
        set(counter, 400)
        check(port.empty, "closing the handle drops its binding")
    }

    struct Lent {
        var port: UInt32
        var before: Int64 = -1
        var after: Int64 = -1
        var periodStart: Int64 = 0
        var afterBlocking: Int64 = -1
    }

    /// A counter with a deadline profile lends it to the fair thread its
    /// packet wakes, from the wakeup until the thread blocks again.
    static func lending() {
        let resource = Handle(adopting: croi_take_startup_handle(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0)))
        let deadline = profile(resource, deadline: true)
        let fair = profile(resource, deadline: false)
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        let weak = Handle(duplicating: counter, rights: 1 << 2 | 1 << 14)  // READ, WAIT
        func setProfile(_ target: borrowing Handle, _ profile: borrowing Handle, _ options: UInt64 = 0) -> Int64 {
            Sys.call(CROI_SYS_OBJECT_SET_PROFILE, target.arg, profile.arg, options)
        }
        check(setProfile(counter, fair) == Status.invalidArgs, "a counter lends only a deadline")
        check(setProfile(weak, deadline) == Status.accessDenied, "lending needs WRITE")
        check(setProfile(counter, deadline, UInt64(CROI_PROFILE_ALIGN_TIMELINE)) == Status.invalidArgs,
              "and takes no options")
        check(setProfile(counter, deadline) == 0, "a counter lends a deadline")

        let port = Port()
        check(port.bind(counter, value, key: 1, trigger: 1) == 0, "bound at 1")
        let state = UnsafeMutablePointer<Lent>.allocate(capacity: 1)
        unsafe state.initialize(to: Lent(port: port.handle.raw))
        let entry: @convention(c) (UInt64) -> Void = { argument in
            let lent = unsafe UnsafeMutablePointer<Lent>(bitPattern: UInt(argument))!
            unsafe lent.pointee.before = Sys.call(CROI_SYS_TEST_PROFILE, 0)
            var packet = croi_port_packet_t()
            _ = unsafe Sys.call(CROI_SYS_PORT_WAIT, UInt64(lent.pointee.port), .max, Sys.address(&packet))
            unsafe lent.pointee.after = Sys.call(CROI_SYS_TEST_PROFILE, 0)
            unsafe lent.pointee.periodStart = Sys.call(CROI_SYS_TEST_PROFILE, 3)
            Sys.sleep(1_000_000)
            unsafe lent.pointee.afterBlocking = Sys.call(CROI_SYS_TEST_PROFILE, 0)
            Thread.exit()
        }
        let worker = Thread(entry, UInt64(UInt(bitPattern: state)))
        Sys.sleep(10_000_000)  // it waits by now
        let added = Sys.now()
        check(add(counter, 1) == 0, "the counter reaches 1")
        worker.join()
        let lent = unsafe state.pointee
        unsafe state.deallocate()
        check(lent.before == 0, "the worker is fair")
        check(lent.after == 1, "woken on the counter's deadline")
        check(UInt64(bitPattern: lent.periodStart) >= added && UInt64(bitPattern: lent.periodStart) < Sys.now(),
              "its period starts at the wakeup")
        check(lent.afterBlocking == 0, "until it blocks again")
    }

    /// A profile: a 1 ms deadline every 4 ms, or a fair priority.
    static func profile(_ resource: borrowing Handle, deadline: Bool) -> Handle {
        var info = croi_profile_info_t()
        if deadline {
            info.flags = UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE)
            info.deadline_params = croi_sched_deadline_params_t(capacity: 1_000_000, relative_deadline: 4_000_000,
                                                                period: 4_000_000)
        } else {
            info.flags = UInt32(CROI_PROFILE_INFO_FLAG_PRIORITY)
            info.priority = 20
        }
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_PROFILE_CREATE, resource.arg, 0, Sys.address(&info), Sys.address(&out)) == 0,
              "creating a profile")
        return Handle(adopting: out)
    }
}
