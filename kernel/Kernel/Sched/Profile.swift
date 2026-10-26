import CKernel

/// Fixed-point scales used by the scheduler.
enum SchedScale {
    /// Utilization (budget / period): 1.0 is 1 << 20.
    static var one: UInt64 { 1 << 20 }
    /// CPU capacity (processing rate): the reference core is 1024.
    static var capacityOne: UInt64 { 1024 }
}

/// A deadline reservation, in ns: `capacity` of work on a capacity-1024
/// CPU within `deadline` of each period's start, every `period`. On a
/// slower CPU the same work takes longer, so budgets are charged in
/// capacity-scaled time.
struct DeadlineParams: Equatable {
    var capacity: UInt64
    var deadline: UInt64
    var period: UInt64

    init(capacity: UInt64, deadline: UInt64, period: UInt64) {
        self.capacity = capacity
        self.deadline = deadline
        self.period = period
    }

    init(capacity: UInt64, period: UInt64) {
        self.init(capacity: capacity, deadline: period, period: period)
    }

    /// capacity / period, fixed point.
    var utilization: UInt64 { capacity * SchedScale.one / period }

    var isValid: Bool {
        capacity >= 50_000 && capacity <= deadline && deadline <= period && period <= 10_000_000_000
    }
}

/// How a thread is scheduled: fair share by weight, or a deadline
/// reservation (EDF). Zircon's base/effective profile.
struct Profile: Equatable {
    enum Discipline { case fair, deadline }

    var discipline: Discipline
    var weight: UInt64
    var params: DeadlineParams

    static func fair(weight: UInt64) -> Profile {
        Profile(discipline: .fair, weight: weight, params: DeadlineParams(capacity: 0, deadline: 0, period: 1))
    }

    static func deadline(_ params: DeadlineParams) -> Profile {
        Profile(discipline: .deadline, weight: 0, params: params)
    }

    /// Order on a wait queue, smaller first: deadline threads by relative
    /// deadline, then fair threads by weight, heaviest first.
    var waitKey: UInt64 {
        switch discipline {
        case .deadline: min(params.deadline, 1 << 62)
        case .fair: (1 << 62) + (1 << 32) - min(weight, 1 << 32)
        }
    }

    /// Zircon's priority -> weight table (kPriorityToWeightTable, 0...31).
    static func weight(priority: Int) -> UInt64 {
        let table: InlineArray<32, UInt16> = [
            53, 58, 64, 71, 78, 85, 94, 103, 114, 125, 138, 152, 167, 184, 202, 222,
            245, 269, 296, 326, 358, 394, 434, 477, 525, 578, 635, 699, 769, 846, 930, 1024,
        ]
        return UInt64(table[max(0, min(31, priority))])
    }
}

/// What a thread inherits through the owned wait queues it holds
/// (Zircon's InheritedProfileValues): fair waiters' weights add up;
/// deadline waiters' utilizations add up, with the tightest deadline.
struct InheritedProfile {
    var totalWeight: UInt64 = 0
    var utilization: UInt64 = 0
    var minDeadline: UInt64 = .max

    mutating func add(_ profile: Profile) {
        switch profile.discipline {
        case .fair:
            totalWeight += profile.weight
        case .deadline:
            utilization += profile.params.utilization
            minDeadline = min(minDeadline, profile.params.deadline)
        }
    }

    /// The effective profile of a thread with `base` that inherits this
    /// (Zircon's RecomputeEffectiveProfile). Inherited deadline work turns
    /// a fair thread into a deadline one for as long as it lasts.
    func applied(to base: Profile) -> Profile {
        let cap = SchedScale.one  // at most one CPU's worth
        if base.discipline == .deadline {
            let utilization = min(cap, utilization + base.params.utilization)
            let deadline = min(minDeadline, base.params.deadline)
            guard utilization != base.params.utilization || deadline != base.params.deadline else { return base }
            return .deadline(DeadlineParams(capacity: utilization * deadline / SchedScale.one,
                                             deadline: deadline, period: deadline))
        }
        if utilization > 0 {
            let utilization = min(cap, utilization)
            return .deadline(DeadlineParams(capacity: utilization * minDeadline / SchedScale.one,
                                            deadline: minDeadline, period: minDeadline))
        }
        return .fair(weight: base.weight + totalWeight)
    }
}

/// Why a deadline reservation was refused (ext 4: admission answers with
/// a reason instead of accepting everything, as Zircon does).
enum AdmissionRefusal: Error, Equatable {
    /// Capacity, deadline and period must satisfy 50 µs <= C <= D <= P <= 10 s.
    case invalidParameters
    /// No CPU the reservation may use (affinity, reserved CPUs).
    case noEligibleCpu
    /// Every eligible CPU would exceed its admission bound; `cpu` came
    /// closest.
    case cpuOverloaded(cpu: Int)
    /// The account's real-time budget is used up.
    case accountExhausted
}

/// A per-user real-time budget (ext 4): the total utilization the
/// reservations charged to it may hold. Owned like a kernel object; K5
/// turns it into a dispatcher.
struct SchedAccount: ~Copyable {
    let record: AccountPointer

    /// `limit` is a utilization (SchedScale.one = one reference CPU).
    init(limit: UInt64) {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<AccountRecord>.size) else {
            panic("sched: out of memory for an account")
        }
        unsafe raw.bindMemory(to: AccountRecord.self, capacity: 1).initialize(to: AccountRecord(limit: limit))
        record = AccountPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    var used: UInt64 { Scheduler.locked { record.pointee.used } }

    deinit {
        Scheduler.locked {
            guard record.pointee.used == 0 else { panic("sched: account destroyed with reservations charged") }
        }
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(record.address))!)
    }
}

struct AccountRecord {
    let limit: UInt64
    var used: UInt64 = 0
}

@safe struct AccountPointer: Equatable {
    let address: UInt64

    var pointee: AccountRecord {
        unsafeAddress { unsafe UnsafePointer<AccountRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<AccountRecord>(bitPattern: UInt(address))! }
    }
}

/// A scheduling context (seL4 MCS style): the right to CPU time, separate
/// from the threads that use it. A fair context carries a weight; a
/// deadline context is an admitted reservation on one CPU, so a thread
/// bound to it is never moved to a core it wasn't admitted on.
///
/// Separate objects are the basis for IPC deadline donation (ext 2: a
/// server runs on its caller's context), budget overrun notification
/// (ext 3), admission against a per-user budget (ext 4) and the `frame`
/// intent hint (ext 10).
struct SchedContextRecord {
    enum Intent { case none, frame }

    let profile: Profile
    /// The admitted CPU (deadline), or -1.
    let cpu: Int
    let account: AccountPointer?
    /// Charged utilization in the CPU's own time (capacity-scaled).
    let wallUtilization: UInt64
    /// CPUs reserved for this tag (ext 8) are the only ones its threads
    /// use, and nothing else runs there. 0: none.
    let reservation: UInt32
    var intent = Intent.none
    var boundThreads = 0
    /// Periods in which the budget ran out before the work was done.
    var overruns: UInt64 = 0
    /// Ext 3: a port reporting overruns (a PacketSource), or 0.
    var overrunSource: UInt64 = 0
    /// Ext 5 (K14e): a context an interrupt object hands to the thread it
    /// wakes. Its period and budget live here across wakeups (the CBS rule
    /// at each), so wakeups share one budget; `borrower` runs on it now.
    var handoffStarted = false
    var handoffPeriodStart: UInt64 = 0
    var handoffDeadline: UInt64 = 0
    var handoffRemaining: Int64 = 0
    var borrower: ThreadPointer?
    var next: SchedContextPointer?
}

@safe struct SchedContextPointer: Equatable {
    let address: UInt64

    var pointee: SchedContextRecord {
        unsafeAddress { unsafe UnsafePointer<SchedContextRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<SchedContextRecord>(bitPattern: UInt(address))! }
    }
}

/// The owner of a scheduling context. Dropping it releases the admitted
/// reservation; no thread may still be bound.
struct SchedContext: ~Copyable {
    let record: SchedContextPointer

    /// A fair context.
    init(weight: UInt64, reservation: UInt32 = 0) {
        record = Scheduler.makeContext(.fair(weight: weight), cpu: -1, account: nil, wallUtilization: 0,
                                       reservation: reservation)
    }

    /// An admitted deadline reservation, or the reason it was refused.
    /// `account` is a `SchedAccount`'s record (borrowed: the account must
    /// outlive the context).
    init(deadline params: DeadlineParams, affinity: UInt64 = .max, account: AccountPointer? = nil,
         reservation: UInt32 = 0) throws(AdmissionRefusal) {
        record = try Scheduler.admit(params, affinity: affinity, account: account, reservation: reservation)
        Scheduler.publishPowerHints()
    }

    /// Takes ownership of a context someone gave up with `leak()`.
    init(owning record: SchedContextPointer) {
        self.record = record
    }

    /// Gives up ownership without destroying it (a thread will own it).
    @export(interface)
    consuming func leak() -> SchedContextPointer {
        let record = self.record
        discard self
        return record
    }

    var cpu: Int { record.pointee.cpu }
    var overruns: UInt64 { Scheduler.locked { record.pointee.overruns } }

    /// Ext 3: reports overruns to `port` (budgetOverrun packets with `key`;
    /// the count says how many since the last one was read).
    func bindOverrunPort(_ port: borrowing ObjectRef, key: UInt64) throws(Status) {
        let source = try PacketSourcePointer.make(port: port, key: key, type: PortPacket.budgetOverrun)
        let old = Scheduler.locked { () -> UInt64 in
            let old = record.pointee.overrunSource
            record.pointee.overrunSource = source.address
            return old
        }
        if old != 0 { PacketSourcePointer(address: old).retire() }
    }

    deinit {
        let source = record.pointee.overrunSource
        Scheduler.destroyContext(record)
        Scheduler.publishPowerHints()
        if source != 0 { PacketSourcePointer(address: source).retire() }
    }
}

/// Default CPU capacities from the core type, until the user-space power
/// service supplies real ones from `_CPC` (a privileged call, as in
/// Zircon). Relative numbers only; `Scheduler` scales them so the
/// biggest core present is 1024.
enum CoreCapacity {
    static func estimate(coreType: UInt32) -> UInt64 {
        #if arch(x86_64)
        switch coreType {
        case 0x20: return 640   // Intel Atom-class E-core
        default: return 1024    // Intel Core P-core, or not hybrid
        }
        #elseif arch(arm64)
        guard coreType >> 16 == 0x41 else { return 1024 }  // Arm Ltd. parts only
        switch coreType & 0xFFFF {
        case 0xD03, 0xD05, 0xD46, 0xD80: return 280  // A53, A55, A510, A520
        case 0xD0B, 0xD0D, 0xD41: return 800         // A76, A77, A78
        case 0xD47, 0xD4D: return 900                // A710, A715
        default: return 1024                         // A720, A725, X-series, unknown
        }
        #else
        return 1024
        #endif
    }
}

/// Fair threads' placement policy (D68, amended 2026-10-26: race to
/// completion). A runnable fair thread goes where it can run soonest and
/// fastest, so its work ends early and the CPUs idle sooner: the least
/// loaded CPU (an idle one first), the biggest capacity among equally
/// loaded ones, and its last CPU (warm caches) among equals. `steal`
/// takes from the CPU with the most fair threads waiting, the smallest
/// among equals, so waiting work leaves the slowest queues first, and
/// never a CPU's only thread. A channel_call's request and reply go on
/// the waker's CPU when it has nothing else to run and no bigger CPU is
/// idle. Only these choices are the policy: placing by a thread's recent demand
/// (D68's proposal) would replace them, and their candidates, here.
enum FairPlacement {
    /// A CPU a thread may run on, as `Scheduler.place` sees it.
    struct Candidate {
        var cpu: Int
        /// Threads queued there, plus one if it is running a thread.
        var load: Int
        var capacity: UInt64
        var isLast: Bool
    }

    /// Whether `a` is a better CPU for the thread than `b`; with neither
    /// better, the one seen first (from the last CPU on) stays.
    static func prefers(_ a: Candidate, over b: Candidate) -> Bool {
        if a.load != b.load { return a.load < b.load }
        if a.capacity != b.capacity { return a.capacity > b.capacity }
        return a.isLast && !b.isLast
    }

    /// Whether `steal` may take from a CPU of `load` (as a `Candidate`'s):
    /// only one with something to spare, FreeBSD ULE's `steal_thresh` of 2
    /// (2026-10-26). A thread just woken onto an idle CPU is its whole
    /// load; taking it left the CPU woken for nothing and moved the thread
    /// off its warm caches. A client's CPU going idle after a request stole
    /// the server ~1 µs after the wakeup, 99% of fs's migrations on the
    /// Sky1, and both threads wandered over all its big cores.
    static func mayStealFrom(load: Int) -> Bool { load >= 2 }

    /// Whether a synchronous wake (`Scheduler.Wake`) puts the thread on
    /// the waker's CPU `waker` rather than on `best`, the CPU `prefers`
    /// chose: when the waker is all that runs there (nothing queued
    /// behind it), unless `best` is idle and bigger, which race to
    /// completion keeps (owner, 2026-10-26). Zircon places a call's
    /// request on the caller's CPU, and keeps the reply there because the
    /// server blocks within its 25 µs queue-time threshold; croi has no
    /// queue-time estimate, so the reply carries the hint too (D139).
    static func placesOnWaker(_ waker: Candidate, over best: Candidate) -> Bool {
        waker.load <= 1 && !(best.load == 0 && best.capacity > waker.capacity)
    }

    /// Whether `steal` should take from a CPU with `count` fair threads
    /// waiting and `capacity` rather than one with `otherCount` and
    /// `otherCapacity`.
    static func prefersSource(count: Int, capacity: UInt64, over otherCount: Int,
                              capacity otherCapacity: UInt64) -> Bool {
        if count != otherCount { return count > otherCount }
        return capacity < otherCapacity
    }
}
