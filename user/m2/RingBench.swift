import CroiRuntime

/// The one ring's budgets (D43, docs/performance.md, kernel and IPC):
/// throughput across cores with 64-byte slots (≥ 100 M slots/s, reported
/// as ns per 1000 slots), a submission and its completion with both sides
/// busy (< 300 ns), and the doorbells rung while both are busy
/// (ring_kicks = 0). Each side spins a while before it sleeps, as a busy
/// service would; it rings the other's doorbell only when the ring says
/// the other sleeps.
extension Bench {
    static var ringSlotSize: Int { 64 }
    static var ringFormat: UInt64 { 0x4d32 }  // "M2"
    /// How long a side spins on an idle ring before it sleeps.
    static var ringSpin: UInt64 { 50_000 }
    static var change: UInt32 { UInt32(CROI_BIND_CHANGE) | UInt32(CROI_BIND_PERSISTENT) }

    struct RingShared {
        var base: UInt64 = 0
        var size = 0
        var reply: UInt64 = 0  // the round trip's completion ring
        var entries: UInt64 = 0
        var dataBell: UInt32 = 0
        var dataPort: UInt32 = 0
        var spaceBell: UInt32 = 0
        var kicks: UInt64 = 0
        var wrong: UInt64 = 0
        var finished: UInt64 = 0  // ns
    }

    nonisolated(unsafe) static var ringShared = RingShared()

    /// A ring of `count` 64-byte slots in a VMO of its own, mapped here.
    static func makeRing(count: Int) throws(Failure) -> (base: UInt64, size: Int) {
        let size = RingLayout.size(slotSize: ringSlotSize, count: count)!
        let mapped = (UInt64(size) + 4095) & ~4095
        var vmo: UInt32 = 0, base: UInt64 = 0
        try Sys.check("making a ring", Sys.call(CROI_SYS_VMO_CREATE, mapped, 0, Sys.address(&vmo)))
        let rw = UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE)
        try Sys.check("mapping a ring", unsafe croi_vmar_map(td_runtime_vmar_root, rw, 0, vmo, 0, mapped, &base))
        Sys.close(vmo)
        guard unsafe NativeRing.create(UnsafeMutableRawPointer(bitPattern: UInt(base))!, size: size,
                                       slotSize: ringSlotSize, count: count, format: ringFormat) else {
            throw Failure(what: "making a ring", status: CROI_ERR_INVALID_ARGS)
        }
        return (base, size)
    }

    static func attach(_ base: UInt64, _ size: Int, producer: Bool) -> NativeRing? {
        unsafe NativeRing(attaching: UnsafeMutableRawPointer(bitPattern: UInt(base))!, size: size,
                          producer: producer, slotSize: ringSlotSize, format: ringFormat)
    }

    /// Spins until `idle` is false or `ringSpin` has passed; true if it is
    /// still idle.
    static func spin(_ idle: () -> Bool) -> Bool {
        let start = Sys.now()
        while idle() {
            for _ in 0..<64 where !idle() { return false }
            if Sys.now() - start > ringSpin { return true }
        }
        return false
    }

    static func sleep(on port: UInt32) {
        var packet = croi_port_packet_t()
        _ = unsafe croi_port_wait(port, Sys.now() + 1_000_000_000, &packet, 0)
    }

    // MARK: Throughput

    /// The consumer, on its own core: drains the ring, checks every word,
    /// sleeps on its doorbell when the ring stays empty.
    static let ringConsumer: Sys.ThreadEntry = { _, _ in
        Sys.take(go)  // pinned to its CPU first
        guard var ring = attach(ringShared.base, ringShared.size, producer: false) else { Sys.exitThread() }
        Sys.signal(ready)
        var entry = InlineArray<8, UInt64>(repeating: 0)
        var n: UInt64 = 0
        let entries = ringShared.entries
        while n < entries {
            var ready = ring.ready()
            if ready == 0 {
                if spin({ ring.ready() == 0 }) {
                    if ring.prepareSleep() { sleep(on: ringShared.dataPort) }
                    ring.endSleep()
                }
                continue
            }
            ready = min(ready, entries - n)
            for i in 0..<ready {
                var span = entry.mutableSpan
                span.withUnsafeMutableBytes { unsafe ring.get(i, to: $0.baseAddress!) }
                if entry[0] != n + i || entry[7] != n + i { ringShared.wrong += 1 }
            }
            if ring.release(ready) {
                _ = croi_counter_add(ringShared.spaceBell, 1)
                ringShared.kicks += 1
            }
            n += ready
        }
        ringShared.finished = Sys.now()
        Sys.exitThread()
    }

    /// `entries` slots from this core to the consumer's: the time per 1000
    /// slots and the doorbells rung, both sides.
    static func ringThroughput(resource: UInt32, thread: UInt32) throws(Failure) -> (UInt64, UInt64) {
        let entries: UInt64 = Sys.timingIsReal ? 4_000_000 : 200_000
        let (base, size) = try makeRing(count: 256)
        ready = try Sys.counter()
        go = try Sys.counter()
        let dataBell = try Sys.counter(), spaceBell = try Sys.counter()
        var dataPort: UInt32 = 0, spacePort: UInt32 = 0
        try Sys.check("creating a port", Sys.call(CROI_SYS_PORT_CREATE, 0, Sys.address(&dataPort)))
        try Sys.check("creating a port", Sys.call(CROI_SYS_PORT_CREATE, 0, Sys.address(&spacePort)))
        try Sys.check("binding a doorbell", Sys.bind(dataPort, dataBell, change, key: 0, trigger: 0))
        try Sys.check("binding a doorbell", Sys.bind(spacePort, spaceBell, change, key: 0, trigger: 0))
        ringShared = RingShared(base: base, size: size, entries: entries, dataBell: dataBell, dataPort: dataPort,
                                spaceBell: spaceBell)
        let producerProfile = try Sys.profile(resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.client)
        try Sys.apply(producerProfile, to: thread)
        Sys.close(producerProfile)
        let worker = try Sys.spawn(ringConsumer, 0)
        let consumerProfile = try Sys.profile(resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.waiter)
        try Sys.apply(consumerProfile, to: worker)
        Sys.close(consumerProfile)
        Sys.signal(go)
        Sys.take(ready)
        guard var ring = attach(base, size, producer: true) else { throw Failure(what: "attaching a ring", status: CROI_ERR_INVALID_ARGS) }
        var entry = InlineArray<8, UInt64>(repeating: 0)
        var kicks: UInt64 = 0
        var n: UInt64 = 0
        let start = Sys.now()
        while n < entries {
            var space = ring.space()
            if space == 0 {
                if spin({ ring.space() == 0 }) {
                    if ring.prepareSleep() { sleep(on: spacePort) }
                    ring.endSleep()
                }
                continue
            }
            space = min(space, entries - n)
            for i in 0..<space {
                for w in 0..<8 { entry[w] = n + i }
                entry.span.withUnsafeBytes { unsafe ring.put(i, from: $0.baseAddress!) }
            }
            if ring.publish(space) {
                _ = croi_counter_add(dataBell, 1)
                kicks += 1
            }
            n += space
        }
        Sys.wait(worker, UInt32(CROI_SIGNAL_TASK_TERMINATED))
        let elapsed = ringShared.finished - start
        for handle in [worker, ready, go, dataBell, spaceBell, dataPort, spacePort] { Sys.close(handle) }
        _ = croi_vmar_unmap(td_runtime_vmar_root, base, (UInt64(size) + 4095) & ~4095)
        guard ringShared.wrong == 0, !ring.broken else {
            throw Failure(what: "carrying ring entries", status: Int64(ringShared.wrong))
        }
        return (elapsed * 1000 / entries, kicks + ringShared.kicks)
    }

    // MARK: Submission and completion

    /// The server, on its own core: copies each submission to the
    /// completion ring, spinning; an entry of all ones stops it.
    static let ringServer: Sys.ThreadEntry = { _, _ in
        Sys.take(go)
        guard var requests = attach(ringShared.base, ringShared.size, producer: false),
              var replies = attach(ringShared.reply, ringShared.size, producer: true) else { Sys.exitThread() }
        Sys.signal(ready)
        var entry = InlineArray<8, UInt64>(repeating: 0)
        while true {
            let ready = requests.ready()
            if ready == 0 { continue }
            var stop = false
            for i in 0..<ready {
                var span = entry.mutableSpan
                span.withUnsafeMutableBytes { unsafe requests.get(i, to: $0.baseAddress!) }
                stop = stop || entry[0] == ~0
                while replies.space() == 0 {}
                entry.span.withUnsafeBytes { unsafe replies.put(0, from: $0.baseAddress!) }
                if replies.publish(1) { ringShared.kicks += 1 }
            }
            if requests.release(ready) { ringShared.kicks += 1 }
            if stop { break }
        }
        Sys.exitThread()
    }

    /// One submission and its completion at a time, both sides spinning:
    /// the mean round trip (ns) and the doorbells either side would ring.
    static func ringRoundTrip(resource: UInt32, thread: UInt32) throws(Failure) -> (UInt64, UInt64) {
        let trips: UInt64 = Sys.timingIsReal ? 100_000 : 5_000
        let (requestBase, size) = try makeRing(count: 64)
        let (replyBase, _) = try makeRing(count: 64)
        ready = try Sys.counter()
        go = try Sys.counter()
        ringShared = RingShared(base: requestBase, size: size, reply: replyBase)
        let worker = try Sys.spawn(ringServer, 0)
        let serverProfile = try Sys.profile(resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.waiter)
        try Sys.apply(serverProfile, to: worker)
        Sys.close(serverProfile)
        Sys.signal(go)
        Sys.take(ready)
        guard var requests = attach(requestBase, size, producer: true),
              var replies = attach(replyBase, size, producer: false) else {
            throw Failure(what: "attaching a ring", status: CROI_ERR_INVALID_ARGS)
        }
        var entry = InlineArray<8, UInt64>(repeating: 0)
        var kicks: UInt64 = 0, wrong: UInt64 = 0
        var start: UInt64 = 0
        let warmup: UInt64 = 1000
        for n in 0..<(warmup + trips) {
            if n == warmup { start = Sys.now() }
            entry[0] = n
            while requests.space() == 0 {}
            entry.span.withUnsafeBytes { unsafe requests.put(0, from: $0.baseAddress!) }
            if requests.publish(1) { kicks += 1 }
            while replies.ready() == 0 {}
            var span = entry.mutableSpan
            span.withUnsafeMutableBytes { unsafe replies.get(0, to: $0.baseAddress!) }
            if entry[0] != n { wrong += 1 }
            if replies.release(1) { kicks += 1 }
        }
        let elapsed = Sys.now() - start
        entry[0] = ~0
        while requests.space() == 0 {}
        entry.span.withUnsafeBytes { unsafe requests.put(0, from: $0.baseAddress!) }
        _ = requests.publish(1)
        Sys.wait(worker, UInt32(CROI_SIGNAL_TASK_TERMINATED))
        for handle in [worker, ready, go] { Sys.close(handle) }
        let mapped = (UInt64(size) + 4095) & ~4095
        _ = croi_vmar_unmap(td_runtime_vmar_root, requestBase, mapped)
        _ = croi_vmar_unmap(td_runtime_vmar_root, replyBase, mapped)
        guard wrong == 0 else { throw Failure(what: "completing ring submissions", status: Int64(wrong)) }
        return (elapsed / trips, kicks + ringShared.kicks)
    }
}
