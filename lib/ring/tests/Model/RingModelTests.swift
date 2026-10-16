import CRingChecked
import Ring
import RingCheck
import Testing

/// RingCheck on the real ring code (D43), Ring.swift and ring.h alike: the
/// wake protocol both ways, OVERWRITE's torn slots, and broken variants
/// that the checker must catch (NeoVectra's ring_model_test, rewritten
/// for the real code).
@Suite(.serialized)
struct RingModelTests {
    // MARK: The two implementations, behind one face

    protocol Side: AnyObject {
        func space() -> UInt64
        func put(_ from: UnsafeRawPointer)
        func publish(_ count: UInt64) -> Bool
        func ready() -> UInt64
        func get(_ i: UInt64, _ to: UnsafeMutableRawPointer)
        func release(_ count: UInt64) -> Bool
        func prepareSleep() -> Bool
        func endSleep()
        func write(_ from: UnsafeRawPointer)
        func read(_ to: UnsafeMutableRawPointer, _ dropped: inout UInt64) -> Bool
    }

    final class SwiftSide: Side {
        var ring: Ring<CheckedMemory>
        init(_ base: UnsafeMutableRawPointer, _ size: Int, producer: Bool, slotSize: Int, flags: UInt16) {
            ring = Ring(attaching: base, size: size, producer: producer, slotSize: slotSize, format: 7,
                        flags: flags)!
        }
        func space() -> UInt64 { ring.space() }
        func put(_ from: UnsafeRawPointer) { ring.put(0, from: from) }
        func publish(_ count: UInt64) -> Bool { ring.publish(count) }
        func ready() -> UInt64 { ring.ready() }
        func get(_ i: UInt64, _ to: UnsafeMutableRawPointer) { ring.get(i, to: to) }
        func release(_ count: UInt64) -> Bool { ring.release(count) }
        func prepareSleep() -> Bool { ring.prepareSleep() }
        func endSleep() { ring.endSleep() }
        func write(_ from: UnsafeRawPointer) { ring.write(from: from) }
        func read(_ to: UnsafeMutableRawPointer, _ dropped: inout UInt64) -> Bool { ring.read(to: to, dropped: &dropped) }
    }

    final class CSide: Side {
        var ring = croi_ring_t()
        init(_ base: UnsafeMutableRawPointer, _ size: Int, producer: Bool, slotSize: Int, flags: UInt16) {
            let attached = croi_ring_attach(&ring, base, UInt64(size), producer, UInt32(slotSize), 7, flags)
            precondition(attached)
        }
        func space() -> UInt64 { croi_ring_space(&ring) }
        func put(_ from: UnsafeRawPointer) { croi_ring_put(&ring, 0, from) }
        func publish(_ count: UInt64) -> Bool { croi_ring_publish(&ring, count) }
        func ready() -> UInt64 { croi_ring_ready(&ring) }
        func get(_ i: UInt64, _ to: UnsafeMutableRawPointer) { croi_ring_get(&ring, i, to) }
        func release(_ count: UInt64) -> Bool { croi_ring_release(&ring, count) }
        func prepareSleep() -> Bool { croi_ring_prepare_sleep(&ring) }
        func endSleep() { croi_ring_end_sleep(&ring) }
        func write(_ from: UnsafeRawPointer) { croi_ring_write(&ring, from) }
        func read(_ to: UnsafeMutableRawPointer, _ dropped: inout UInt64) -> Bool { croi_ring_read(&ring, to, &dropped) }
    }

    enum Implementation: CaseIterable { case swift, c }

    static func attach(_ implementation: Implementation, _ base: UnsafeMutableRawPointer, _ size: Int,
                       producer: Bool, slotSize: Int, flags: UInt16 = 0) -> Side {
        switch implementation {
        case .swift: SwiftSide(base, size, producer: producer, slotSize: slotSize, flags: flags)
        case .c: CSide(base, size, producer: producer, slotSize: slotSize, flags: flags)
        }
    }

    // MARK: The wake protocol

    static let data = 0, space = 1  // the doorbells: the consumer's, the producer's

    /// Sleeps on `bell` as a ring side does: reads the doorbell, announces
    /// the sleep, looks once more, and waits only if there is still nothing
    /// to do. Without `recheck`, it sleeps whatever the second look said.
    static func sleep(_ side: Side, on bell: Int, recheck: Bool) {
        let seen = Checker.kernelLoad(bell)
        if side.prepareSleep() || !recheck { Checker.kernelWaitAbove(bell, seen) }
        side.endSleep()
    }

    /// A producer sends `entries` 16-byte entries (both words the entry's
    /// number) through a ring of two slots, so that it fills, and a
    /// consumer checks each; both sleep when they must.
    static func wakeModel(_ implementation: Implementation, entries: UInt64, recheck: Bool = true,
                          mutation: Checker.Mutation = .init()) -> Checker.Result {
        let slotSize = 16
        let size = RingLayout.size(slotSize: slotSize, count: 2)!
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 128)
        defer { region.deallocate() }
        let base = region.baseAddress!
        var producer: Side?, consumer: Side?
        var model = Checker.Model(
            name: "wakes, \(implementation), \(entries) entries", regions: [region], counters: 2,
            reset: {
                _ = Ring<NativeMemory>.create(base, size: size, slotSize: slotSize, count: 2, format: 7)
                producer = attach(implementation, base, size, producer: true, slotSize: slotSize)
                consumer = attach(implementation, base, size, producer: false, slotSize: slotSize)
            },
            threads: [
                {  // the producer
                    let side = producer!
                    for n in 1...entries {
                        while side.space() == 0 { sleep(side, on: space, recheck: recheck) }
                        var entry = (n, n)
                        withUnsafeBytes(of: &entry) { side.put($0.baseAddress!) }
                        if side.publish(1) { Checker.kernelAdd(data) }
                    }
                },
                {  // the consumer
                    let side = consumer!
                    var received: UInt64 = 0
                    while received < entries {
                        let ready = side.ready()
                        if ready == 0 {
                            sleep(side, on: data, recheck: recheck)
                            continue
                        }
                        for i in 0..<ready {
                            var entry: (UInt64, UInt64) = (0, 0)
                            withUnsafeMutableBytes(of: &entry) { side.get(i, $0.baseAddress!) }
                            received += 1
                            Checker.expect(entry == (received, received),
                                           "entry \(received) read as \(entry.0), \(entry.1)")
                        }
                        if side.release(ready) { Checker.kernelAdd(space) }
                    }
                },
            ],
            final: { done, _ in
                done.allSatisfy { $0 } ? nil : "a side sleeps with work waiting (a lost wake)"
            })
        model.mutation = mutation
        return Checker.check(model)
    }

    @Test(arguments: Implementation.allCases)
    func wakes(_ implementation: Implementation) {
        for entries: UInt64 in [1, 3] {
            let result = Self.wakeModel(implementation, entries: entries)
            #expect(result.ok, "\(result.failure ?? "")")
            #expect(result.finals > 0)
            print("ring check: wakes, \(implementation), \(entries): \(result.states) states, "
                  + "\(result.executions) runs")
        }
    }

    /// Each fence, the producer's release and the recheck are needed:
    /// without any one of them the checker finds the failure. (The
    /// consumer's release keeps its copies before its cursor: load-store
    /// order, which the checker doesn't model; see Checker.)
    @Test(arguments: Implementation.allCases)
    func brokenWakes(_ implementation: Implementation) {
        var producerFence = Checker.Mutation()
        producerFence.dropSequentialFences = [0]
        var consumerFence = Checker.Mutation()
        consumerFence.dropSequentialFences = [1]
        var producerRelease = Checker.Mutation()
        producerRelease.relaxReleases = [0]
        let broken: [(String, Checker.Result)] = [
            ("no producer fence", Self.wakeModel(implementation, entries: 3, mutation: producerFence)),
            ("no consumer fence", Self.wakeModel(implementation, entries: 3, mutation: consumerFence)),
            ("relaxed publish", Self.wakeModel(implementation, entries: 3, mutation: producerRelease)),
            ("no recheck", Self.wakeModel(implementation, entries: 3, recheck: false)),
        ]
        for (name, result) in broken {
            #expect(!result.ok, "\(implementation): \(name) should fail")
            if let failure = result.failure { print("ring check: \(name), as expected: \(failure.prefix(120))") }
        }
    }

    // MARK: OVERWRITE

    /// A writer writes `records` 24-byte records (the sequence, then two
    /// words that are the sequence's) into two slots, lapping a reader
    /// that keeps whatever it can: every record kept must be whole, in
    /// order, and kept plus dropped must come to all of them. The doorbell
    /// is D38's: the writer adds one per record, so its value is the
    /// writer's cursor, and a reader that has caught up waits for it to
    /// pass its own.
    static func overwriteModel(_ implementation: Implementation, records: UInt64,
                               mutation: Checker.Mutation = .init()) -> Checker.Result {
        let slotSize = 24
        let size = RingLayout.size(slotSize: slotSize, count: 2)!
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 128)
        defer { region.deallocate() }
        let base = region.baseAddress!
        let written = 0
        var writer: Side?, reader: Side?
        var model = Checker.Model(
            name: "overwrite, \(implementation), \(records) records", regions: [region], counters: 1,
            reset: {
                _ = Ring<NativeMemory>.create(base, size: size, slotSize: slotSize, count: 2, format: 7,
                                              flags: RingLayout.overwrite)
                writer = attach(implementation, base, size, producer: true, slotSize: slotSize,
                                flags: RingLayout.overwrite)
                reader = attach(implementation, base, size, producer: false, slotSize: slotSize,
                                flags: RingLayout.overwrite)
            },
            threads: [
                {  // the writer
                    let side = writer!
                    for n in 0..<records {
                        var record = (UInt64(0), n &* 3 &+ 7, n &* 5 &+ 1)
                        withUnsafeBytes(of: &record) { side.write($0.baseAddress!) }
                        Checker.kernelAdd(written)
                    }
                },
                {  // the reader
                    let side = reader!
                    var kept: UInt64 = 0, dropped: UInt64 = 0, last: UInt64? = nil
                    while kept + dropped < records {
                        var record: (UInt64, UInt64, UInt64) = (0, 0, 0)
                        let got = withUnsafeMutableBytes(of: &record) { side.read($0.baseAddress!, &dropped) }
                        if got {
                            let n = record.0
                            Checker.expect(record.1 == n &* 3 &+ 7 && record.2 == n &* 5 &+ 1,
                                           "record \(n) torn: \(record.1), \(record.2)")
                            Checker.expect(last.map { n > $0 } ?? true, "record \(n) after \(last ?? 0)")
                            last = n
                            kept += 1
                            continue
                        }
                        Checker.kernelWaitAbove(written, Int64(kept + dropped))
                    }
                    Checker.expect(kept + dropped == records, "kept \(kept) and dropped \(dropped) of \(records)")
                },
            ],
            final: { done, _ in done.allSatisfy { $0 } ? nil : "a thread never finished" })
        model.mutation = mutation
        return Checker.check(model)
    }

    @Test(arguments: Implementation.allCases)
    func overwrite(_ implementation: Implementation) {
        for records: UInt64 in [1, 3] {
            let result = Self.overwriteModel(implementation, records: records)
            #expect(result.ok, "\(result.failure ?? "")")
            print("ring check: overwrite, \(implementation), \(records): \(result.states) states, "
                  + "\(result.executions) runs")
        }
    }

    /// Without the writer's release orders, a reader keeps a torn record.
    @Test(arguments: Implementation.allCases)
    func brokenOverwrite(_ implementation: Implementation) {
        var mutation = Checker.Mutation()
        mutation.relaxReleases = [0]
        let result = Self.overwriteModel(implementation, records: 3, mutation: mutation)
        #expect(!result.ok, "\(implementation): relaxed writer should fail")
    }
}
