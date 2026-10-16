import Ring
import RingCheckContext

/// RingCheck (D43): an exhaustive interleaving model checker that runs the
/// real ring code, Ring.swift through `CheckedMemory` and ring.h through
/// its CROI_RING_CHECKED hooks. A rewrite of NeoVectra's vx-check, which
/// checked hand-written models of the protocol instead.
///
/// A model is a few threads over a little shared memory. Each runs as a
/// coroutine and stops at every memory operation it makes; the checker
/// chooses which operation happens next, and when each buffered store
/// reaches memory, and so runs every order there is, depth first,
/// replaying each from the start. A state reached before is not explored
/// again: a state is the shared memory, the store buffers, the kernel
/// counters, and each thread's operation count and the hash of every value
/// it has loaded (its code is deterministic, so that fixes where it is).
///
/// The memory model: a thread's stores wait in its own buffer, where its
/// own loads see them, and reach memory in any order, except that two
/// stores to one address keep theirs, a release store waits for every
/// store before it, a release fence holds back the stores after it until
/// those before it are out, and a seq_cst fence waits until the buffer is
/// empty. That is the store reordering arm64 allows; it includes x86's
/// (TSO). Loads happen when they are made: neither another load nor a
/// later store overtakes one. arm64 allows both, and acquire loads and
/// release stores are what forbid them there, so this checker can't show
/// that those are needed (a consumer's release, which keeps its copies of
/// slots before its cursor, passes relaxed).
/// Kernel operations (the doorbells) act like syscalls: they wait for an
/// empty buffer, then act at once.
public final class Checker {
    /// What a model run found.
    public struct Result {
        public var ok: Bool
        public var states: Int
        public var executions: Int
        public var finals: Int
        /// Why it failed, and the order of operations that led there.
        public var failure: String?
    }

    /// Ways to break the code on purpose, per thread: a checker that can't
    /// find what these break proves nothing.
    public struct Mutation {
        public var dropSequentialFences: Set<Int> = []  // seq_cst fences do nothing
        public var relaxReleases: Set<Int> = []         // release stores and fences are relaxed
        public init() {}
    }

    public struct Model {
        public var name: String
        /// The shared memory: every operation inside it is the model's.
        public var regions: [UnsafeMutableRawBufferPointer]
        public var counters: Int
        /// Puts the shared memory and the threads' own state back as they
        /// start: every execution begins with it.
        public var reset: () -> Void
        public var threads: [() -> Void]
        /// In a state where nothing can move: nil if it is right, else why not.
        public var final: (_ done: [Bool], _ counters: [Int64]) -> String?
        public var mutation = Mutation()
        public var maxDepth = 600

        public init(name: String, regions: [UnsafeMutableRawBufferPointer], counters: Int = 0,
                    reset: @escaping () -> Void, threads: [() -> Void],
                    final: @escaping (_ done: [Bool], _ counters: [Int64]) -> String?) {
            self.name = name
            self.regions = regions
            self.counters = counters
            self.reset = reset
            self.threads = threads
            self.final = final
        }
    }

    // MARK: Running a model

    /// Runs every order of `model`'s operations.
    public static func check(_ model: Model) -> Result {
        let checker = Checker(model)
        current = checker
        defer { current = nil }
        return checker.explore()
    }

    nonisolated(unsafe) static var current: Checker?

    enum Op {
        case load(address: UInt, size: Int, order: RingOrder)
        case store(address: UInt, size: Int, value: UInt64, order: RingOrder)
        case fence(RingOrder)
        case copy(to: UInt, from: UInt, count: Int)
        case kernelAdd(counter: Int, amount: Int64)
        case kernelLoad(counter: Int)
        case kernelWaitAbove(counter: Int, seen: Int64)
    }

    struct Buffered: Hashable {
        var address: UInt
        var size: Int
        var value: UInt64
        var release: Bool
        var marker: Bool  // a release fence
    }

    final class Thread {
        let body: () -> Void
        var fiber: OpaquePointer?
        var pending: Op?
        var result: UInt64 = 0
        var done = false
        var buffer: [Buffered] = []
        var operations = 0
        var history: UInt64 = 0xcbf2_9ce4_8422_2325

        init(_ body: @escaping () -> Void) { self.body = body }

        func observe(_ value: UInt64) {
            history = (history ^ value) &* 0x100_0000_01b3
            history ^= history >> 29
        }
    }

    enum Action {
        case step(Int)
        case flush(Int, Int)  // thread, buffer entry
    }

    enum Outcome {
        case final(String?)
        case pruned
        case truncated
        case violation(String)
    }

    let model: Model
    var threads: [Thread] = []
    var counters: [Int64] = []
    var running = 0
    /// A model thread is running: its memory operations are the model's.
    var inThread = false
    var violation: String?
    var log: [String] = []
    var visited = Set<Fingerprint>()

    init(_ model: Model) { self.model = model }

    func explore() -> Result {
        var result = Result(ok: true, states: 0, executions: 0, finals: 0, failure: nil)
        var prefix: [Int] = []
        while true {
            let (choices, outcome) = run(prefix)
            result.executions += 1
            switch outcome {
            case .pruned: break
            case .final(nil): result.finals += 1
            case .final(let why?):
                result.ok = false
                result.failure = "\(model.name): \(why)\n  " + log.joined(separator: "\n  ")
            case .truncated:
                result.ok = false
                result.failure = "\(model.name): no end within \(model.maxDepth) steps\n  "
                    + log.suffix(40).joined(separator: "\n  ")
            case .violation(let why):
                result.ok = false
                result.failure = "\(model.name): \(why)\n  " + log.joined(separator: "\n  ")
            }
            if !result.ok { break }
            var path = choices
            while let last = path.last, last.choice + 1 >= last.count { path.removeLast() }
            guard !path.isEmpty else { break }
            prefix = path.map(\.choice)
            prefix[prefix.count - 1] += 1
        }
        result.states = visited.count
        return result
    }

    /// One execution, following `prefix` and then the first choice at each
    /// step.
    func run(_ prefix: [Int]) -> ([(choice: Int, count: Int)], Outcome) {
        for region in model.regions { region.initializeMemory(as: UInt8.self, repeating: 0) }
        model.reset()
        counters = Array(repeating: 0, count: model.counters)
        violation = nil
        log = []
        threads = model.threads.map { Thread($0) }
        defer {
            for thread in threads { if let fiber = thread.fiber { check_fiber_free(fiber) } }
            threads = []
        }
        for (i, thread) in threads.enumerated() {
            let box = Unmanaged.passUnretained(thread).toOpaque()
            thread.fiber = check_fiber_new(256 << 10, { argument in
                let thread = Unmanaged<Thread>.fromOpaque(argument!).takeUnretainedValue()
                thread.body()
            }, box)
            resume(i)
        }
        var choices: [(choice: Int, count: Int)] = []
        var depth = 0
        while true {
            if let why = violation { return (choices, .violation(why)) }
            if depth >= prefix.count, !visited.insert(fingerprint()).inserted { return (choices, .pruned) }
            let actions = enabled()
            if actions.isEmpty {
                let done = threads.map(\.done)
                return (choices, .final(model.final(done, counters)))
            }
            if depth >= model.maxDepth { return (choices, .truncated) }
            let choice = depth < prefix.count ? prefix[depth] : 0
            choices.append((choice, actions.count))
            apply(actions[choice])
            depth += 1
        }
    }

    func resume(_ i: Int) {
        running = i
        inThread = true
        if check_fiber_resume(threads[i].fiber) { threads[i].done = true }
        inThread = false
    }

    // MARK: What can happen next

    func enabled() -> [Action] {
        var actions: [Action] = []
        for (i, thread) in threads.enumerated() {
            if !thread.done, let op = thread.pending, canPerform(op, thread, i) { actions.append(.step(i)) }
            for j in thread.buffer.indices where canFlush(thread.buffer, j) { actions.append(.flush(i, j)) }
        }
        return actions
    }

    func canPerform(_ op: Op, _ thread: Thread, _ i: Int) -> Bool {
        switch op {
        case .fence(.sequentiallyConsistent):
            return thread.buffer.isEmpty || model.mutation.dropSequentialFences.contains(i)
        case .kernelAdd, .kernelLoad:
            return thread.buffer.isEmpty
        case .kernelWaitAbove(let counter, let seen):
            return thread.buffer.isEmpty && counters[counter] > seen
        default:
            return true
        }
    }

    func canFlush(_ buffer: [Buffered], _ j: Int) -> Bool {
        let entry = buffer[j]
        guard !entry.marker else { return false }
        if entry.release { return j == 0 }
        for k in 0..<j {
            if buffer[k].marker { return false }
            if overlaps(buffer[k], entry) { return false }
        }
        return true
    }

    func overlaps(_ a: Buffered, _ b: Buffered) -> Bool {
        a.address < b.address + UInt(b.size) && b.address < a.address + UInt(a.size)
    }

    func apply(_ action: Action) {
        switch action {
        case .flush(let i, let j):
            let entry = threads[i].buffer.remove(at: j)
            write(entry.address, entry.size, entry.value)
            while let first = threads[i].buffer.first, first.marker { threads[i].buffer.removeFirst() }
            log.append("T\(i) flush \(hex(entry.address)) = \(entry.value)")
        case .step(let i):
            let thread = threads[i]
            let op = thread.pending!
            thread.pending = nil
            thread.result = perform(op, thread, i)
            thread.operations += 1
            thread.observe(UInt64(thread.operations))
            thread.observe(thread.result)
            log.append("T\(i) \(describe(op)) -> \(thread.result)")
            resume(i)
        }
    }

    func perform(_ op: Op, _ thread: Thread, _ i: Int) -> UInt64 {
        switch op {
        case .load(let address, let size, _):
            return read(thread, address, size)
        case .store(let address, let size, let value, let order):
            precondition(order != .sequentiallyConsistent, "RingCheck: no seq_cst stores")
            let release = order == .releasing && !model.mutation.relaxReleases.contains(i)
            thread.buffer.append(Buffered(address: address, size: size, value: value, release: release, marker: false))
            return 0
        case .fence(let order):
            if order == .releasing, !thread.buffer.isEmpty, !model.mutation.relaxReleases.contains(i) {
                thread.buffer.append(Buffered(address: 0, size: 0, value: 0, release: false, marker: true))
            }
            return 0
        case .copy(let to, let from, let count):
            precondition(count % 8 == 0, "RingCheck: copies of whole words")
            for offset in stride(from: 0, to: count, by: 8) {
                let source = from + UInt(offset), target = to + UInt(offset)
                let value = shared(source) ? read(thread, source, 8)
                    : UnsafeRawPointer(bitPattern: source)!.loadUnaligned(as: UInt64.self)
                if shared(source) { thread.observe(value) }
                if shared(target) {
                    thread.buffer.append(Buffered(address: target, size: 8, value: value, release: false, marker: false))
                } else {
                    UnsafeMutableRawPointer(bitPattern: target)!.storeBytes(of: value, as: UInt64.self)
                }
            }
            return 0
        case .kernelAdd(let counter, let amount):
            counters[counter] += amount
            return 0
        case .kernelLoad(let counter):
            return UInt64(bitPattern: counters[counter])
        case .kernelWaitAbove(let counter, _):
            return UInt64(bitPattern: counters[counter])
        }
    }

    /// A load: this thread's newest buffered store to the address, else memory.
    func read(_ thread: Thread, _ address: UInt, _ size: Int) -> UInt64 {
        let probe = Buffered(address: address, size: size, value: 0, release: false, marker: false)
        for entry in thread.buffer.reversed() where !entry.marker && overlaps(entry, probe) {
            precondition(entry.address == address && entry.size == size, "RingCheck: a load across stores")
            return entry.value
        }
        let pointer = UnsafeRawPointer(bitPattern: address)!
        return size == 8 ? pointer.loadUnaligned(as: UInt64.self) : UInt64(pointer.loadUnaligned(as: UInt32.self))
    }

    func write(_ address: UInt, _ size: Int, _ value: UInt64) {
        let pointer = UnsafeMutableRawPointer(bitPattern: address)!
        if size == 8 { pointer.storeBytes(of: value, as: UInt64.self) }
        else { pointer.storeBytes(of: UInt32(truncatingIfNeeded: value), as: UInt32.self) }
    }

    func shared(_ address: UInt) -> Bool {
        model.regions.contains { region in
            let start = UInt(bitPattern: region.baseAddress)
            return address >= start && address < start + UInt(region.count)
        }
    }

    // MARK: States

    struct Fingerprint: Hashable {
        var a: Int
        var b: Int
    }

    func fingerprint() -> Fingerprint {
        var a = Hasher(), b = Hasher()
        b.combine(0x5eed)
        for region in model.regions {
            let bytes = UnsafeRawBufferPointer(region)
            a.combine(bytes: bytes)
            b.combine(bytes: bytes)
        }
        for counter in counters { a.combine(counter); b.combine(counter) }
        for thread in threads {
            for hasher in [0, 1] {
                var h = hasher == 0 ? a : b
                h.combine(thread.done)
                h.combine(thread.operations)
                h.combine(thread.history)
                h.combine(thread.buffer)
                if hasher == 0 { a = h } else { b = h }
            }
        }
        return Fingerprint(a: a.finalize(), b: b.finalize())
    }

    func describe(_ op: Op) -> String {
        switch op {
        case .load(let address, let size, let order): "load\(size * 8) \(hex(address)) \(order)"
        case .store(let address, let size, let value, let order): "store\(size * 8) \(hex(address)) = \(value) \(order)"
        case .fence(let order): "fence \(order)"
        case .copy(let to, let from, let count): "copy \(count) \(hex(from)) -> \(hex(to))"
        case .kernelAdd(let counter, let amount): "counter \(counter) += \(amount)"
        case .kernelLoad(let counter): "counter \(counter)?"
        case .kernelWaitAbove(let counter, let seen): "wait counter \(counter) > \(seen)"
        }
    }

    func hex(_ address: UInt) -> String {
        guard let region = model.regions.first(where: { region in
            let start = UInt(bitPattern: region.baseAddress)
            return address >= start && address < start + UInt(region.count)
        }) else { return "private" }
        return "+\(address - UInt(bitPattern: region.baseAddress))"
    }

    // MARK: From inside a model thread

    /// Waits for the checker to choose `op`, and returns what it gave.
    func submit(_ op: Op) -> UInt64 {
        let thread = threads[running]
        thread.pending = op
        check_fiber_yield()
        return thread.result
    }

    /// A model thread's own check: a failure ends the run with `why`.
    public static func expect(_ condition: Bool, _ why: @autoclosure () -> String) {
        guard !condition, let checker = current else { return }
        if checker.violation == nil { checker.violation = "T\(checker.running): \(why())" }
    }

    /// counter_add on a doorbell.
    public static func kernelAdd(_ counter: Int, _ amount: Int64 = 1) {
        _ = current!.submit(.kernelAdd(counter: counter, amount: amount))
    }

    /// A doorbell's value.
    public static func kernelLoad(_ counter: Int) -> Int64 {
        Int64(bitPattern: current!.submit(.kernelLoad(counter: counter)))
    }

    /// port_wait on a doorbell bound VALUE: sleeps until it is above `seen`.
    public static func kernelWaitAbove(_ counter: Int, _ seen: Int64) {
        _ = current!.submit(.kernelWaitAbove(counter: counter, seen: seen))
    }
}

/// The ring's memory operations as RingCheck's model threads make them.
/// Outside a model thread (a model's `reset`, or no check running), the
/// hardware's.
public enum CheckedMemory: RingMemory {
    public static func load64(_ address: UnsafeRawPointer, _ order: RingOrder) -> UInt64 {
        guard let checker = Checker.current, checker.inThread else { return NativeMemory.load64(address, order) }
        return checker.submit(.load(address: UInt(bitPattern: address), size: 8, order: order))
    }

    public static func load32(_ address: UnsafeRawPointer, _ order: RingOrder) -> UInt32 {
        guard let checker = Checker.current, checker.inThread else { return NativeMemory.load32(address, order) }
        return UInt32(truncatingIfNeeded: checker.submit(.load(address: UInt(bitPattern: address), size: 4, order: order)))
    }

    public static func store64(_ address: UnsafeMutableRawPointer, _ value: UInt64, _ order: RingOrder) {
        guard let checker = Checker.current, checker.inThread else { return NativeMemory.store64(address, value, order) }
        _ = checker.submit(.store(address: UInt(bitPattern: address), size: 8, value: value, order: order))
    }

    public static func store32(_ address: UnsafeMutableRawPointer, _ value: UInt32, _ order: RingOrder) {
        guard let checker = Checker.current, checker.inThread else { return NativeMemory.store32(address, value, order) }
        _ = checker.submit(.store(address: UInt(bitPattern: address), size: 4, value: UInt64(value), order: order))
    }

    public static func fence(_ order: RingOrder) {
        guard let checker = Checker.current, checker.inThread else { return NativeMemory.fence(order) }
        _ = checker.submit(.fence(order))
    }

    public static func copy(_ to: UnsafeMutableRawPointer, _ from: UnsafeRawPointer, _ count: Int) {
        guard let checker = Checker.current, checker.inThread else { return NativeMemory.copy(to, from, count) }
        _ = checker.submit(.copy(to: UInt(bitPattern: to), from: UInt(bitPattern: from), count: count))
    }
}

// MARK: ring.h's hooks (CROI_RING_CHECKED)

func order(_ c: Int32) -> RingOrder {
    switch c {
    case 0: .relaxed
    case 1, 2: .acquiring
    case 3: .releasing
    case 4, 5: .sequentiallyConsistent
    default: .sequentiallyConsistent
    }
}

@_cdecl("croi_ring_check_load")
public func croiRingCheckLoad(_ address: UnsafeRawPointer, _ size: UInt32, _ c: Int32) -> UInt64 {
    size == 8 ? CheckedMemory.load64(address, order(c)) : UInt64(CheckedMemory.load32(address, order(c)))
}

@_cdecl("croi_ring_check_store")
public func croiRingCheckStore(_ address: UnsafeMutableRawPointer, _ size: UInt32, _ value: UInt64, _ c: Int32) {
    if size == 8 { CheckedMemory.store64(address, value, order(c)) }
    else { CheckedMemory.store32(address, UInt32(truncatingIfNeeded: value), order(c)) }
}

@_cdecl("croi_ring_check_fence")
public func croiRingCheckFence(_ c: Int32) {
    CheckedMemory.fence(order(c))
}

@_cdecl("croi_ring_check_copy")
public func croiRingCheckCopy(_ to: UnsafeMutableRawPointer, _ from: UnsafeRawPointer, _ count: UInt64) {
    CheckedMemory.copy(to, from, Int(count))
}
