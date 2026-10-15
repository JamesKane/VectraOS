import CKernel

/// Futexes from user space (K7c; numbers in user/include/croi/syscall.h).
/// Zircon's calls. Timer objects went in V1 (D25): port_wait's deadline.
extension Syscalls {
    static func syncCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        switch number {
        case 90:  // futex_wait(value_ptr, current_value, new_owner thread handle, deadline)
            let owner = try futexOwner(table, UInt32(truncatingIfNeeded: a[2]))
            defer { if let owner { Scheduler.unpin(owner) } }
            try Futexes.wait(a[0], expected: UInt32(truncatingIfNeeded: a[1]), owner: owner, deadline: a[3])
        case 91:  // futex_wake(value_ptr, count)
            try Futexes.wake(a[0], count: UInt32(truncatingIfNeeded: a[1]))
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
