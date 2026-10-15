import CKernel

/// Futexes and timers from user space (K7c; numbers in
/// user/include/croi/syscall.h). Zircon's calls.
extension Syscalls {
    static func syncCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        switch number {
        case 90:  // futex_wait(value_ptr, current_value, new_owner thread handle, deadline)
            let owner = try futexOwner(table, UInt32(truncatingIfNeeded: a[2]))
            defer { if let owner { Scheduler.unpin(owner) } }
            try Futexes.wait(a[0], expected: UInt32(truncatingIfNeeded: a[1]), owner: owner, deadline: a[3])
        case 91:  // futex_wake(value_ptr, count)
            try Futexes.wake(a[0], count: UInt32(truncatingIfNeeded: a[1]))
        case 95:  // timer_create(options, clock_id, out)
            try Policy.check(UInt32(CROI_POL_NEW_TIMER))
            guard a[1] <= 1 else { throw .invalidArgs }  // ZX_CLOCK_MONOTONIC, or BOOT (the same: no suspend)
            try check(a[2], 4)
            let timer = try TimerObjects.create(slackPolicy: UInt32(truncatingIfNeeded: a[0]))
            try put(try table.add(timer, rights: TimerObject.defaultRights), a[2])
        case 96:  // timer_set(timer, deadline, slack)
            guard Int64(bitPattern: a[2]) >= 0 else { throw .outOfRange }
            let timer = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .timer, rights: .write)
            TimerObjects.set(timer.object, deadline: a[1], slack: a[2])
        case 97:  // timer_cancel(timer)
            let timer = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .timer, rights: .write)
            TimerObjects.cancel(timer.object)
        default:
            throw .notSupported
        }
    }

    /// A futex owner from a thread handle (0: none), pinned (the caller
    /// unpins); a thread that isn't running has no scheduler thread to lend
    /// to, so none either.
    private static func futexOwner(_ table: borrowing HandleTable, _ handle: UInt32) throws(Status) -> ThreadPointer? {
        guard handle != 0 else { return nil }
        let thread = try table.get(handle, type: .thread)
        return Processes.pinnedThread(thread.object)
    }
}
