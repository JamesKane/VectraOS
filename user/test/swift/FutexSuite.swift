import CroiRuntime

/// Futexes (Futex.swift): wait and wake, and an owner running on a
/// deadline waiter's profile. Moved here from usertest.c's mode 8 when V1
/// cut futex_requeue, wake_single_owner and get_owner (D22): todhchai's
/// Lock and pthreads use wait and wake only. That a wake clears the owner
/// (get_owner read it) is now the kernel's check that no futex record is
/// left once the suites end: an owned record is never retired.
enum FutexSuite {
    static func run() {
        let words = Mapping(Handle(vmo: pageSize), length: pageSize)
        basics(words.address)
        wakeCount(words.address + 4)
        inheritance(words.address + 8)
        print("swift: futex passed")
    }

    static func basics(_ word: UInt64) {
        check(Sys.call(CROI_SYS_FUTEX_WAIT, word, 1, 0, Sys.now() + 1_000_000_000) == Status.badState,
              "a word that isn't the value expected: BAD_STATE")
        check(Sys.call(CROI_SYS_FUTEX_WAIT, word, 0, 0, Sys.now()) == Status.timedOut, "a deadline passed")
        check(Sys.call(CROI_SYS_FUTEX_WAIT, word + 1, 0, 0, Sys.now()) == Status.invalidArgs, "a misaligned word")
        check(Sys.call(CROI_SYS_FUTEX_WAKE, word, 10) == 0, "waking nobody")
    }

    struct Waiter {
        var word: UInt64
        var result: Int64 = 1
    }

    /// Two waiters: a wake of one ends exactly one, a wake of the rest the
    /// other.
    static func wakeCount(_ word: UInt64) {
        let waiters = UnsafeMutablePointer<Waiter>.allocate(capacity: 2)
        unsafe waiters.initialize(to: Waiter(word: word))
        unsafe (waiters + 1).initialize(to: Waiter(word: word))
        let entry: @convention(c) (UInt64) -> Void = { argument in
            let waiter = unsafe UnsafeMutablePointer<Waiter>(bitPattern: UInt(argument))!
            let word = unsafe waiter.pointee.word
            unsafe waiter.pointee.result = Sys.call(CROI_SYS_FUTEX_WAIT, word, 0, 0, Sys.now() + 5_000_000_000)
            Thread.exit()
        }
        let address = UInt64(UInt(bitPattern: waiters))
        let first = Thread(entry, address)
        let second = Thread(entry, address + UInt64(MemoryLayout<Waiter>.stride))
        let ends = Port()
        check(ends.bind(first.handle, UInt32(CROI_BIND_SIGNALS), key: 1,
                        trigger: UInt64(CROI_SIGNAL_TASK_TERMINATED)) == 0
                  && ends.bind(second.handle, UInt32(CROI_BIND_SIGNALS), key: 2,
                               trigger: UInt64(CROI_SIGNAL_TASK_TERMINATED)) == 0, "binding the waiters' ends")
        check(waitsOnFutex(first) && waitsOnFutex(second), "both wait")
        check(Sys.call(CROI_SYS_FUTEX_WAKE, word, 1) == 0, "a wake of one")
        let woken = ends.next(deadline: Sys.now() + 2_000_000_000)
        check(woken != nil, "one waiter ends")
        check(ends.next(deadline: Sys.now() + 50_000_000) == nil, "the other still waits")
        check(Sys.call(CROI_SYS_FUTEX_WAKE, word, 10) == 0, "a wake of the rest")
        let other = ends.next(deadline: Sys.now() + 2_000_000_000)
        check(other != nil && other!.key != woken!.key, "the other ends")
        first.join()
        second.join()
        let results = unsafe (waiters.pointee.result, (waiters + 1).pointee.result)
        check(results == (0, 0), "both were woken")
        unsafe waiters.deallocate()
    }

    /// Whether `thread` is blocked in futex_wait, within two seconds.
    static func waitsOnFutex(_ thread: borrowing Thread) -> Bool {
        let giveUp = Sys.now() + 2_000_000_000
        while Sys.now() < giveUp {
            var info = croi_info_thread_t()
            check(Sys.call(CROI_SYS_OBJECT_GET_INFO, thread.handle.arg, UInt64(CROI_INFO_THREAD), Sys.address(&info),
                           UInt64(MemoryLayout<croi_info_thread_t>.size)) == 0, "a thread's state")
            if info.state == UInt32(CROI_THREAD_STATE_BLOCKED_FUTEX) { return true }
            Sys.sleep(1_000_000)
        }
        return false
    }

    struct Owner {
        var word: UInt64
        var profile: Int64 = 0
    }

    /// We wait on a deadline profile with a fair thread named as the
    /// futex's owner: it runs on our deadline until it wakes us. The
    /// deadline context is the one runSuites lends test_profile.
    static func inheritance(_ word: UInt64) {
        let state = UnsafeMutablePointer<Owner>.allocate(capacity: 1)
        unsafe state.initialize(to: Owner(word: word))
        let entry: @convention(c) (UInt64) -> Void = { argument in
            let owner = unsafe UnsafeMutablePointer<Owner>(bitPattern: UInt(argument))!
            let giveUp = Sys.now() + 2_000_000_000
            while Sys.now() < giveUp, Sys.call(CROI_SYS_TEST, 0) != 1 {}
            unsafe owner.pointee.profile = Sys.call(CROI_SYS_TEST, 0)
            let word = unsafe owner.pointee.word
            _ = Sys.call(CROI_SYS_FUTEX_WAKE, word, 1)
            Thread.exit()
        }
        let owner = Thread(entry, UInt64(UInt(bitPattern: state)))
        let bound = Sys.call(CROI_SYS_TEST, 1)
        let waited = Sys.call(CROI_SYS_FUTEX_WAIT, word, 0, owner.handle.arg, Sys.now() + 3_000_000_000)
        let unbound = Sys.call(CROI_SYS_TEST, 2)
        owner.join()
        check(bound == 0 && unbound == 0, "bound to the deadline context and back")
        check(waited == 0, "woken by the owner")
        let profile = unsafe state.pointee.profile
        check(profile == 1, "the owner ran on our deadline profile")
        unsafe state.deallocate()
    }
}
