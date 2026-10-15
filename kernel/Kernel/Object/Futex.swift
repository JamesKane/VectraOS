import CKernel
import Synchronization

/// Futexes (K7c, requirement 10; Zircon's futex syscalls, with owners for
/// priority inheritance). A futex is a 32-bit word in user memory, keyed
/// by (address space, address); its wait queue exists while it has
/// waiters or an owner. The scheduler lock is the futex lock: a wait
/// compares the word and blocks under it, so a waker that changed the
/// word first can't be missed. The word is read without paging in (a
/// fault drops the lock, pages it in and retries).
///
/// Owners: `futex_wait` names the futex's owner (a thread handle, or none),
/// and the waiters lend it their profiles (K3b inheritance through an
/// owned queue). A cycle refuses the owner: the futex is left unowned,
/// where a kernel mutex would panic. `wake` clears the owner. V1 cut
/// requeue, wake_single_owner and get_owner (D22): todhchai's Lock and
/// pthreads use wait and wake only.
struct FutexRecord {
    var next: UInt64 = 0
    let aspace: UInt64
    let address: UInt64
    let queue: QueuePointer
    /// Waiters that still refer to it: counted in when they enqueue, out
    /// once they are running again (a woken waiter hasn't run yet when
    /// its waker returns).
    var users = 0
}

@safe struct FutexPointer: Equatable {
    let address: UInt64

    var pointee: FutexRecord {
        unsafeAddress { unsafe UnsafePointer<FutexRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<FutexRecord>(bitPattern: UInt(address))! }
    }

    var queue: QueuePointer { pointee.queue }

    static func allocate(aspace: UInt64, address: UInt64) -> FutexPointer? {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<FutexRecord>.size, alignment: 16) else { return nil }
        unsafe raw.bindMemory(to: FutexRecord.self, capacity: 1)
            .initialize(to: FutexRecord(aspace: aspace, address: address, queue: QueuePointer.allocate()))
        return FutexPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func free() {
        pointee.queue.deallocate()
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(address))!)
    }
}

enum Futexes {
    /// Buckets of futex records (scheduler lock).
    nonisolated(unsafe) private static var buckets = InlineArray<256, UInt64>(repeating: 0)
    static let live = Atomic<Int>(0)

    private static func bucket(_ aspace: UInt64, _ address: UInt64) -> Int {
        Int(truncatingIfNeeded: ((address >> 2) ^ (aspace >> 6)) & 255)
    }

    /// The futex at `address` in `aspace`, if it has a queue. Lock held.
    private static func find(_ aspace: UInt64, _ address: UInt64) -> FutexPointer? {
        var cursor = buckets[bucket(aspace, address)]
        while cursor != 0 {
            let record = FutexPointer(address: cursor)
            if record.pointee.aspace == aspace, record.pointee.address == address { return record }
            cursor = record.pointee.next
        }
        return nil
    }

    private static func insert(_ record: FutexPointer) {
        let index = bucket(record.pointee.aspace, record.pointee.address)
        record.pointee.next = buckets[index]
        buckets[index] = record.address
        live.add(1, ordering: .relaxed)
    }

    /// Unlinks `record` if no waiter refers to it and nobody owns it;
    /// returns it for freeing (outside the lock). Lock held.
    private static func retire(_ record: FutexPointer) -> FutexPointer? {
        guard record.pointee.users == 0, record.pointee.queue.pointee.isEmpty,
              record.pointee.queue.pointee.owner == nil else { return nil }
        let index = bucket(record.pointee.aspace, record.pointee.address)
        if buckets[index] == record.address {
            buckets[index] = record.pointee.next
        } else {
            var cursor = FutexPointer(address: buckets[index])
            while cursor.pointee.next != record.address { cursor = FutexPointer(address: cursor.pointee.next) }
            cursor.pointee.next = record.pointee.next
        }
        live.subtract(1, ordering: .relaxed)
        return record
    }

    private static func key(_ address: UInt64) throws(Status) -> UInt64 {
        guard address & 3 == 0, UserLayout.contains(address, 4) else { throw .invalidArgs }
        guard let aspace = Scheduler.current.pointee.aspace else { throw .badState }
        return aspace.address
    }

    /// Makes the word resident (outside the lock), after a no-page-in read
    /// faulted.
    private static func pageIn(_ address: UInt64) throws(Status) {
        var value: UInt32 = 0
        let copied = withUnsafeMutableBytes(of: &value) { unsafe UserCopy.from($0.baseAddress!, address, 4) }
        guard copied == 0 else { throw .invalidArgs }
    }

    // MARK: Syscalls

    /// futex_wait: blocks while the word at `address` is `expected`, with
    /// `owner` (nil: none) as the futex's owner, until woken or `deadline`.
    static func wait(_ address: UInt64, expected: UInt32, owner: ThreadPointer?, deadline: UInt64) throws(Status) {
        let aspace = try key(address)
        let me = Scheduler.current
        guard owner != me else { throw .invalidArgs }
        var spare = FutexPointer.allocate(aspace: aspace, address: address)
        defer { spare?.free() }
        while true {
            enum Outcome { case fault, changed, done(Thread.WaitResult) }
            var retired: FutexPointer? = nil
            let outcome = Scheduler.locked { () -> Outcome in
                guard let value = UserCopy.wordNoPageIn(address) else { return .fault }
                guard value == expected else { return .changed }
                let record: FutexPointer
                if let existing = find(aspace, address) {
                    record = existing
                } else {
                    guard let fresh = spare else { return .fault }  // no memory: retry allocates
                    spare = nil
                    insert(fresh)
                    record = fresh
                }
                if !Scheduler.setOwner(record.queue, owner, adding: me) { Scheduler.setOwner(record.queue, nil) }
                Trace.event(CROI_TRACE_FUTEX, UInt16(CROI_TK_FUTEX_WAIT), address,
                            UInt64(owner?.pointee.traceId ?? 0))
                record.pointee.users += 1
                let result = Scheduler.block(on: record.queue, deadline: deadline, interruptible: true)
                record.pointee.users -= 1
                // The last waiter gone (a timeout, a kill): no owner either,
                // as in Zircon (review fix: owned records never retired).
                if record.pointee.users == 0, record.queue.pointee.isEmpty {
                    Scheduler.setOwner(record.queue, nil)
                }
                retired = retire(record)
                return .done(result)
            }
            retired?.free()
            switch outcome {
            case .fault:
                if spare == nil, find(lockedAspace: aspace, address) == nil {
                    spare = FutexPointer.allocate(aspace: aspace, address: address)
                    guard spare != nil else { throw .noMemory }
                }
                try pageIn(address)
            case .changed:
                throw .badState
            case .done(let result):
                switch result {
                case .woken: return
                case .timedOut: throw .timedOut
                case .interrupted: throw .canceled
                }
            }
        }
    }

    private static func find(lockedAspace aspace: UInt64, _ address: UInt64) -> FutexPointer? {
        Scheduler.locked { find(aspace, address) }
    }

    /// futex_wake: wakes up to `count` waiters; the futex has no owner
    /// afterwards. Returns how many woke.
    @discardableResult
    static func wake(_ address: UInt64, count: UInt32) throws(Status) -> Int {
        let aspace = try key(address)
        var retired: FutexPointer? = nil
        let woken = Scheduler.locked { () -> Int in
            guard let record = find(aspace, address) else { return 0 }
            Scheduler.setOwner(record.queue, nil)
            var woken = 0
            while woken < Int(count), Scheduler.wakeOne(record.queue) { woken += 1 }
            retired = retire(record)
            return woken
        }
        retired?.free()
        Trace.event(CROI_TRACE_FUTEX, UInt16(CROI_TK_FUTEX_WAKE), address, UInt64(woken))
        return woken
    }
}
