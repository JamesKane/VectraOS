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
        func writeBytes(_ from: UnsafeRawPointer, _ count: Int) -> (Int, Bool)
        func writeEnd() -> (Bool, Bool)
        func readBytes(_ to: UnsafeMutableRawPointer, _ max: Int) -> (Int, Bool, Bool)
        func slot(_ i: UInt64) -> UnsafeMutableRawPointer
        var position: UInt64 { get }
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
        func writeBytes(_ from: UnsafeRawPointer, _ count: Int) -> (Int, Bool) {
            let r = ring.write(bytes: from, count: count)
            return (r.written, r.wake)
        }
        func writeEnd() -> (Bool, Bool) {
            let r = ring.writeEnd()
            return (r.done, r.wake)
        }
        func readBytes(_ to: UnsafeMutableRawPointer, _ max: Int) -> (Int, Bool, Bool) {
            let r = ring.read(bytes: to, max: max)
            return (r.count, r.ended, r.wake)
        }
        func slot(_ i: UInt64) -> UnsafeMutableRawPointer { ring.slot(i) }
        var position: UInt64 { ring.position }
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
        func writeBytes(_ from: UnsafeRawPointer, _ count: Int) -> (Int, Bool) {
            var wake = false
            let n = croi_ring_write_bytes(&ring, from, UInt64(count), &wake)
            return (Int(n), wake)
        }
        func writeEnd() -> (Bool, Bool) {
            var wake = false
            let done = croi_ring_write_end(&ring, &wake)
            return (done, wake)
        }
        func readBytes(_ to: UnsafeMutableRawPointer, _ max: Int) -> (Int, Bool, Bool) {
            var ended = false, wake = false
            let n = croi_ring_read_bytes(&ring, to, UInt64(max), &ended, &wake)
            return (Int(n), ended, wake)
        }
        func slot(_ i: UInt64) -> UnsafeMutableRawPointer { croi_ring_slot(&ring, i) }
        var position: UInt64 { ring.cursor }
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
                    Checker.expect(records > 2 || dropped == 0, "\(dropped) of \(records) records dropped, but the writer never lapped the reader")
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

    // MARK: BYTE_STREAM

    /// A writer sends `chunks` (their sizes; byte i is i + 1) and then the
    /// end mark through two slots of 16 bytes' payload, so that it fills;
    /// a reader takes `readSize` bytes at a time, so that reads fall inside
    /// slots. Every byte must arrive in order, once, and the end only after
    /// the last; both sleep when they must. The checker's memory is words,
    /// so sizes here are multiples of 8: ByteStreamTests covers any sizes
    /// on the hardware.
    static func streamModel(_ implementation: Implementation, chunks: [Int], readSize: Int,
                            mutation: Checker.Mutation = .init()) -> Checker.Result {
        let slotSize = 24
        let size = RingLayout.size(slotSize: slotSize, count: 2)!
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 128)
        defer { region.deallocate() }
        let base = region.baseAddress!
        let total = chunks.reduce(0, +)
        var writer: Side?, reader: Side?
        var model = Checker.Model(
            name: "byte stream, \(implementation), \(chunks) by \(readSize)", regions: [region], counters: 2,
            reset: {
                _ = Ring<NativeMemory>.create(base, size: size, slotSize: slotSize, count: 2, format: 7,
                                              flags: RingLayout.byteStream)
                writer = attach(implementation, base, size, producer: true, slotSize: slotSize,
                                flags: RingLayout.byteStream)
                reader = attach(implementation, base, size, producer: false, slotSize: slotSize,
                                flags: RingLayout.byteStream)
            },
            threads: [
                {  // the writer
                    let side = writer!
                    var sent = 0
                    for chunk in chunks {
                        var bytes = (0..<chunk).map { UInt8(sent + $0 + 1) }
                        var off = 0
                        while off < chunk {
                            let (n, wake) = bytes.withUnsafeMutableBytes { side.writeBytes($0.baseAddress! + off, chunk - off) }
                            if wake { Checker.kernelAdd(data) }
                            if n == 0 { sleep(side, on: space, recheck: true) }
                            off += n
                        }
                        sent += chunk
                    }
                    while true {
                        let (done, wake) = side.writeEnd()
                        if wake { Checker.kernelAdd(data) }
                        if done { break }
                        sleep(side, on: space, recheck: true)
                    }
                },
                {  // the reader
                    let side = reader!
                    var received = 0, ended = false
                    var buffer = [UInt8](repeating: 0, count: readSize)
                    while !ended {
                        let (n, end, wake) = buffer.withUnsafeMutableBytes { side.readBytes($0.baseAddress!, readSize) }
                        if wake { Checker.kernelAdd(space) }
                        for i in 0..<n {
                            Checker.expect(buffer[i] == UInt8(received + i + 1),
                                           "byte \(received + i) read as \(buffer[i])")
                        }
                        received += n
                        ended = end
                        if n == 0 && !end { sleep(side, on: data, recheck: true) }
                    }
                    Checker.expect(received == total, "the end after \(received) of \(total) bytes")
                },
            ],
            final: { done, _ in done.allSatisfy { $0 } ? nil : "a side sleeps with work waiting (a lost wake)" })
        model.mutation = mutation
        return Checker.check(model)
    }

    @Test(arguments: Implementation.allCases)
    func byteStream(_ implementation: Implementation) {
        let result = Self.streamModel(implementation, chunks: [16, 8], readSize: 8)
        #expect(result.ok, "\(result.failure ?? "")")
        #expect(result.finals > 0)
        print("ring check: byte stream, \(implementation): \(result.states) states, \(result.executions) runs")
    }

    /// Without the writer's release, the reader reads bytes before they land.
    @Test(arguments: Implementation.allCases)
    func brokenByteStream(_ implementation: Implementation) {
        var mutation = Checker.Mutation()
        mutation.relaxReleases = [0]
        let result = Self.streamModel(implementation, chunks: [16, 8], readSize: 8, mutation: mutation)
        #expect(!result.ok, "\(implementation): a relaxed publish should fail")
    }

    /// Chunks longer than a slot's payload, and a second chunk that needs
    /// two slots when only one may be free: the writer's clamps to the
    /// payload and to the free slots.
    @Test(arguments: Implementation.allCases)
    func byteStreamSplit(_ implementation: Implementation) {
        let result = Self.streamModel(implementation, chunks: [8, 24], readSize: 8)
        #expect(result.ok, "\(result.failure ?? "")")
        #expect(result.finals > 0)
        print("ring check: byte stream split, \(implementation): \(result.states) states, \(result.executions) runs")
    }

    // MARK: What the models never reach
    //
    // The model threads run well-formed traffic through rings made right.
    // These tests run one thread on both implementations, with the checker's
    // hooks on the hardware's atomics, and make what the models cannot:
    // doorbells rung or not, a hostile cursor or header, arguments that
    // are refused, a side that attaches to a ring in use.

    /// A ring of `count` slots of `slotSize` made in aligned memory, and
    /// pokes at its words as a hostile peer would make them.
    final class Fixture {
        let region: UnsafeMutableRawBufferPointer
        let base: UnsafeMutableRawPointer
        let size: Int
        init(slotSize: Int, count: Int, flags: UInt16 = 0) {
            size = RingLayout.size(slotSize: slotSize, count: count)!
            region = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 128)
            _ = region.initializeMemory(as: UInt8.self, repeating: 0)
            base = region.baseAddress!
            let made = Ring<NativeMemory>.create(base, size: size, slotSize: slotSize, count: count, format: 7,
                                                 flags: flags)
            precondition(made)
        }
        // No deinit: the sides keep the address, and a value's life ends at its last use, not
        // its scope's end (a few hundred bytes a test is left to the process).
        func poke64(_ offset: Int, _ value: UInt64) { base.storeBytes(of: value, toByteOffset: offset, as: UInt64.self) }
        func poke32(_ offset: Int, _ value: UInt32) { base.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
        func poke16(_ offset: Int, _ value: UInt16) { base.storeBytes(of: value, toByteOffset: offset, as: UInt16.self) }
    }

    /// Doorbells: a publish or release says to ring only when the other side
    /// announced its sleep, and a sleep not taken or ended withdraws the
    /// announcement. (The models don't judge doorbells rung for nothing:
    /// that is the target's ring_kicks budget.)
    @Test(arguments: Implementation.allCases)
    func doorbellFlags(_ implementation: Implementation) {
        let f = Fixture(slotSize: 16, count: 2)
        let producer = Self.attach(implementation, f.base, f.size, producer: true, slotSize: 16)
        let consumer = Self.attach(implementation, f.base, f.size, producer: false, slotSize: 16)
        var entry: (UInt64, UInt64) = (1, 1)
        func put() { withUnsafeBytes(of: &entry) { producer.put($0.baseAddress!) } }

        // Both busy: nothing rings.
        #expect(producer.space() == 2)
        put()
        #expect(!producer.publish(1), "a publish rang a consumer that was not asleep")
        #expect(consumer.ready() == 1)
        #expect(!consumer.release(1), "a release rang a producer that was not asleep")
        // The consumer sleeps on the empty ring: the next publish rings.
        #expect(consumer.ready() == 0)
        #expect(consumer.prepareSleep(), "a consumer on an empty ring may sleep")
        put()
        #expect(producer.publish(1), "a publish did not ring a sleeping consumer")
        // A sleep not taken (the ring is not empty) withdraws its word.
        #expect(!consumer.prepareSleep(), "a consumer may not sleep with a slot waiting")
        put()
        #expect(!producer.publish(1), "a withdrawn sleep was still announced")
        #expect(consumer.ready() == 2)  // a full ring is not a broken one
        #expect(!consumer.release(2))
        // A sleep ended withdraws its word.
        #expect(consumer.prepareSleep())
        consumer.endSleep()
        put()
        #expect(!producer.publish(1), "an ended sleep was still announced")
        #expect(consumer.ready() == 1)
        #expect(!consumer.release(1))
        // The producer sleeps on the full ring: the next release rings.
        put()
        #expect(!producer.publish(1))
        put()
        #expect(!producer.publish(1))
        #expect(producer.space() == 0)
        #expect(producer.prepareSleep(), "a producer on a full ring may sleep")
        #expect(consumer.ready() == 2)
        #expect(consumer.release(1), "a release did not ring a sleeping producer")
        #expect(!producer.prepareSleep(), "a producer may not sleep with room")
        #expect(!consumer.release(1), "a withdrawn sleep was still announced")
        #expect(producer.space() == 2)
        // And a sleep ended.
        put()
        #expect(!producer.publish(1))
        put()
        #expect(!producer.publish(1))
        #expect(producer.prepareSleep())
        producer.endSleep()
        #expect(consumer.ready() == 2)
        #expect(!consumer.release(1), "an ended sleep was still announced")
    }

    /// A cursor that runs past the other's marks the ring broken for good,
    /// and a broken ring neither counts slots nor says to sleep.
    @Test(arguments: Implementation.allCases)
    func hostileCursors(_ implementation: Implementation) {
        let f = Fixture(slotSize: 16, count: 2)
        let producer = Self.attach(implementation, f.base, f.size, producer: true, slotSize: 16)
        var entry: (UInt64, UInt64) = (1, 1)
        for _ in 0..<2 {
            withUnsafeBytes(of: &entry) { producer.put($0.baseAddress!) }
            _ = producer.publish(1)
        }
        #expect(producer.space() == 0)
        f.poke64(RingLayout.consumerLine, 1000)  // the consumer's head is past our tail
        #expect(producer.space() == 0, "a consumer past the producer left room")
        f.poke64(RingLayout.consumerLine, 0)  // as if it were full again
        #expect(!producer.prepareSleep(), "a broken ring said to sleep")
        f.poke64(RingLayout.consumerLine, 2)  // as if it were empty
        #expect(producer.space() == 0, "a broken ring mended itself")

        let g = Fixture(slotSize: 16, count: 2)
        let writer = Self.attach(implementation, g.base, g.size, producer: true, slotSize: 16)
        let reader = Self.attach(implementation, g.base, g.size, producer: false, slotSize: 16)
        withUnsafeBytes(of: &entry) { writer.put($0.baseAddress!) }
        _ = writer.publish(1)
        #expect(reader.ready() == 1)
        g.poke64(RingLayout.producerLine, 1000)  // the producer's tail is far ahead
        #expect(reader.ready() == 0, "a producer ahead of the ring left slots ready")
        g.poke64(RingLayout.producerLine, 1)
        #expect(reader.ready() == 0, "a broken ring mended itself")
        g.poke64(RingLayout.producerLine, 0)
        #expect(!reader.prepareSleep(), "a broken ring said to sleep")
    }

    /// Cursors are free-running: a slot's index wraps at the ring's size, and
    /// each slot is copied whole.
    @Test(arguments: Implementation.allCases)
    func slotWraparound(_ implementation: Implementation) {
        let f = Fixture(slotSize: 16, count: 2)
        let producer = Self.attach(implementation, f.base, f.size, producer: true, slotSize: 16)
        let consumer = Self.attach(implementation, f.base, f.size, producer: false, slotSize: 16)
        for round in 0..<6 {
            let n = UInt64(round)
            let expected0 = f.base + RingLayout.slots + Int(n & 1) * 16
            let expected1 = f.base + RingLayout.slots + Int((n + 1) & 1) * 16
            let wraps = producer.slot(0) == expected0 && producer.slot(1) == expected1
            #expect(wraps, "round \(round): the slot index did not wrap")
            if !wraps { break }
            var entry: (UInt64, UInt64) = (n + 1, n + 100)
            withUnsafeBytes(of: &entry) { producer.put($0.baseAddress!) }
            _ = producer.publish(1)
            #expect(consumer.ready() == 1)
            var got: (UInt64, UInt64) = (0, 0)
            withUnsafeMutableBytes(of: &got) { consumer.get(0, $0.baseAddress!) }
            #expect(got.0 == n + 1 && got.1 == n + 100, "round \(round): the slot came out as \(got)")
            _ = consumer.release(1)
        }
    }

    /// A side that attaches to a ring in use takes up its cursor where it
    /// stands.
    @Test(arguments: Implementation.allCases)
    func reattach(_ implementation: Implementation) {
        let f = Fixture(slotSize: 16, count: 2)
        let producer = Self.attach(implementation, f.base, f.size, producer: true, slotSize: 16)
        var entry: (UInt64, UInt64) = (1, 1)
        withUnsafeBytes(of: &entry) { producer.put($0.baseAddress!) }
        _ = producer.publish(1)
        let again = Self.attach(implementation, f.base, f.size, producer: true, slotSize: 16)
        #expect(again.position == 1, "a producer attached to a ring in use started at \(again.position)")
        #expect(again.space() == 1)
        let consumer = Self.attach(implementation, f.base, f.size, producer: false, slotSize: 16)
        #expect(consumer.position == 0)
        #expect(consumer.ready() == 1)
        _ = consumer.release(1)
        let later = Self.attach(implementation, f.base, f.size, producer: false, slotSize: 16)
        #expect(later.position == 1, "a consumer attached to a ring in use started at \(later.position)")
        #expect(later.ready() == 0)
    }

    /// OVERWRITE: the writer goes on from its cursor, and a reader starts at
    /// the oldest record still there.
    @Test(arguments: Implementation.allCases)
    func overwriteAttach(_ implementation: Implementation) {
        let flags = RingLayout.overwrite
        let f = Fixture(slotSize: 24, count: 2, flags: flags)
        let writer = Self.attach(implementation, f.base, f.size, producer: true, slotSize: 24, flags: flags)
        func write(_ side: Side, _ n: UInt64) {
            var record = (UInt64(0), n &* 3 &+ 7, n &* 5 &+ 1)
            withUnsafeBytes(of: &record) { side.write($0.baseAddress!) }
        }
        #expect(Self.attach(implementation, f.base, f.size, producer: false, slotSize: 24, flags: flags).position == 0)
        for n in UInt64(0)..<3 { write(writer, n) }
        let reader = Self.attach(implementation, f.base, f.size, producer: false, slotSize: 24, flags: flags)
        #expect(reader.position == 1, "a reader attached at \(reader.position), not at the oldest record there")
        var dropped: UInt64 = 0
        for want in UInt64(1)...2 {
            var record: (UInt64, UInt64, UInt64) = (0, 0, 0)
            let got = withUnsafeMutableBytes(of: &record) { reader.read($0.baseAddress!, &dropped) }
            #expect(got && record.0 == want && record.1 == want &* 3 &+ 7, "record \(want) read as \(record)")
        }
        var spare: (UInt64, UInt64, UInt64) = (0, 0, 0)
        let more = withUnsafeMutableBytes(of: &spare) { reader.read($0.baseAddress!, &dropped) }
        #expect(!more)
        #expect(dropped == 0)
        let second = Self.attach(implementation, f.base, f.size, producer: true, slotSize: 24, flags: flags)
        #expect(second.position == 3, "a writer attached to a ring in use started at \(second.position)")
        write(second, 3)
        #expect(Self.attach(implementation, f.base, f.size, producer: false, slotSize: 24, flags: flags).position == 2)
    }

    /// What a ring may be made of, and what attach accepts of a header it
    /// did not write.
    @Test(arguments: Implementation.allCases)
    func layoutValidation(_ implementation: Implementation) {
        func size(_ slotSize: Int, _ count: Int) -> Int? {
            switch implementation {
            case .swift:
                return RingLayout.size(slotSize: slotSize, count: count)
            case .c:
                let n = croi_ring_size(UInt32(slotSize), UInt32(count))
                return n == 0 ? nil : Int(n)
            }
        }
        #expect(size(16, 2) == 416)
        #expect(size(8, 1) == 392)
        #expect(size(65536, 1) == 65920)
        #expect(size(8, 1 << 20) == 384 + (8 << 20))
        let invalid: [(Int, Int)] = [(0, 2), (12, 2), (65544, 2), (16, 0), (16, 3), (16, 1 << 21)]
        for (slotSize, count) in invalid {
            #expect(size(slotSize, count) == nil, "a ring of \(count) slots of \(slotSize) bytes is not one")
        }

        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 128)
        defer { region.deallocate() }
        let base = region.baseAddress!
        func create(_ size: Int, _ slotSize: Int, _ count: Int, _ flags: UInt16) -> Bool {
            _ = region.initializeMemory(as: UInt8.self, repeating: 0)
            switch implementation {
            case .swift:
                return Ring<NativeMemory>.create(base, size: size, slotSize: slotSize, count: count, format: 7,
                                                 flags: flags)
            case .c:
                return croi_ring_create(base, UInt64(size), UInt32(slotSize), UInt32(count), 7, flags)
            }
        }
        #expect(create(416, 16, 2, 0), "a ring that fits exactly")
        #expect(!create(408, 16, 2, 0), "a ring that does not fit")
        #expect(!create(1024, 16, 3, 0), "three slots")
        #expect(create(1024, 16, 2, RingLayout.overwrite))
        #expect(create(1024, 24, 2, RingLayout.byteStream))
        #expect(!create(1024, 16, 2, 4), "a flag no one defined")
        #expect(!create(1024, 16, 2, RingLayout.overwrite | RingLayout.byteStream), "both modes")
        #expect(!create(1024, 8, 2, RingLayout.byteStream), "a stream of slots with no room for bytes")

        let f = Fixture(slotSize: 16, count: 2)
        func attaches(_ f: Fixture, size: Int? = nil, producer: Bool = true, slotSize: Int = 16, format: UInt64 = 7,
                      flags: UInt16 = 0) -> Bool {
            let size = size ?? f.size
            switch implementation {
            case .swift:
                let ring = Ring<NativeMemory>(attaching: f.base, size: size, producer: producer, slotSize: slotSize,
                                              format: format, flags: flags)
                return ring != nil
            case .c:
                var ring = croi_ring_t()
                return croi_ring_attach(&ring, f.base, UInt64(size), producer, UInt32(slotSize), format, flags)
            }
        }
        let header = RingLayout.header
        #expect(attaches(f))
        #expect(attaches(f, producer: false))
        #expect(!attaches(f, size: 408), "a mapping shorter than the ring")
        #expect(!attaches(f, slotSize: 8), "a slot size the side does not expect")
        #expect(!attaches(f, format: 8), "a format the side does not expect")
        #expect(!attaches(f, flags: RingLayout.overwrite), "a mode the side does not expect")
        f.poke32(header, 0)
        #expect(!attaches(f), "no magic")
        f.poke32(header, RingLayout.magic)
        f.poke16(header + 4, 2)
        #expect(!attaches(f), "another version")
        f.poke16(header + 4, RingLayout.version)
        f.poke32(header + 12, 3)
        #expect(!attaches(f), "three slots")
        f.poke32(header + 12, 0)
        #expect(!attaches(f), "no slots")
        f.poke32(header + 12, 4)
        #expect(!attaches(f), "more slots than are mapped")
        f.poke32(header + 12, 2)
        #expect(attaches(f))
        f.poke16(header + 6, RingLayout.byteStream)  // a stream of slots with no room for bytes
        f.poke32(header + 8, 8)
        #expect(!attaches(f, slotSize: 8, flags: RingLayout.byteStream), "a stream of slots with no room for bytes")
    }

    /// An attach that failed leaves a ring on which every call fails.
    @Test func failedAttachIsBroken() {
        let f = Fixture(slotSize: 16, count: 2)
        var ring = croi_ring_t()
        let attached = croi_ring_attach(&ring, f.base, UInt64(f.size), true, 16, 99, 0)
        #expect(!attached)
        #expect(croi_ring_space(&ring) == 0)
        #expect(croi_ring_ready(&ring) == 0)
        #expect(!croi_ring_prepare_sleep(&ring))
        var record: UInt64 = 0, dropped: UInt64 = 0
        #expect(!croi_ring_read(&ring, &record, &dropped))
    }

    // MARK: BYTE_STREAM edges

    static func bytes(_ range: ClosedRange<UInt8>) -> [UInt8] { Array(range) }

    @discardableResult
    static func write(_ side: Side, _ bytes: [UInt8]) -> (Int, Bool) {
        bytes.withUnsafeBytes { side.writeBytes($0.baseAddress!, bytes.count) }
    }

    /// What a byte stream does that its models don't ask of it: refuse to
    /// write into a full ring, ignore what follows the end mark, keep a
    /// slot's header as first read, refuse a header that is nonsense for
    /// good, take no more than asked, and ring only a sleeper.
    @Test(arguments: Implementation.allCases)
    func byteStreamEdges(_ implementation: Implementation) {
        let flags = RingLayout.byteStream
        func stream(_ count: Int) -> (Fixture, Side, Side) {
            let f = Fixture(slotSize: 24, count: count, flags: flags)
            return (f, Self.attach(implementation, f.base, f.size, producer: true, slotSize: 24, flags: flags),
                    Self.attach(implementation, f.base, f.size, producer: false, slotSize: 24, flags: flags))
        }
        var buffer = [UInt8](repeating: 0, count: 64)
        func take(_ side: Side, _ max: Int) -> (Int, Bool, Bool) {
            buffer.withUnsafeMutableBytes { side.readBytes($0.baseAddress!, max) }
        }

        // A full ring takes nothing, rings nobody for it, and takes no end mark.
        do {
            let (f, writer, _) = stream(2)
            let (n, wake) = Self.write(writer, Self.bytes(1...32))
            #expect(n == 32 && !wake)
            f.poke32(RingLayout.consumerLine + RingLayout.waitingOffset, 1)  // the reader sleeps
            let (more, moreWake) = Self.write(writer, Self.bytes(1...8))
            #expect(more == 0 && !moreWake, "a write into a full ring wrote \(more) and rang \(moreWake)")
            let (done, endWake) = writer.writeEnd()
            #expect(!done && !endWake, "an end mark went into a full ring")
        }

        // Bytes after the end mark are not read, in the same batch or later;
        // every slot read is freed.
        do {
            let (_, writer, reader) = stream(8)
            Self.write(writer, Self.bytes(1...8))
            #expect(writer.writeEnd() == (true, false))
            Self.write(writer, Self.bytes(9...16))
            let (n, ended, wake) = take(reader, 100)
            #expect(n == 8 && ended && !wake, "the first read gave \(n) bytes, ended \(ended)")
            #expect(Array(buffer[0..<8]) == Self.bytes(1...8))
            let (again, stillEnded, _) = take(reader, 100)
            #expect(again == 0 && stillEnded, "a read after the end gave \(again) bytes")
            #expect(writer.space() == 7, "the data and the end mark are freed, the byte after it is not")
        }

        // A slot's header is read once: a writer that changes it afterwards
        // changes nothing.
        do {
            let (f, writer, reader) = stream(4)
            Self.write(writer, Self.bytes(1...16))
            let (first, _, _) = take(reader, 8)
            #expect(first == 8)
            f.poke32(RingLayout.slots, 1000)
            let (second, _, wake) = take(reader, 8)
            #expect(second == 8 && !wake, "the rest of the slot came as \(second) bytes")
            #expect(Array(buffer[0..<8]) == Self.bytes(9...16))
        }

        // A header that is nonsense breaks the ring for good.
        do {
            let (f, writer, reader) = stream(4)
            Self.write(writer, Self.bytes(1...16))
            f.poke32(RingLayout.slots, 17)
            #expect(take(reader, 100) == (0, false, false), "a length past the slot was read")
            f.poke32(RingLayout.slots, 16)
            #expect(take(reader, 100) == (0, false, false), "a broken ring mended itself")
        }
        do {
            let (f, writer, reader) = stream(4)
            Self.write(writer, Self.bytes(1...16))
            f.poke32(RingLayout.slots + 4, 2)
            #expect(take(reader, 100) == (0, false, false), "a flag no one defined was read")
        }

        // A read takes no more than it was asked for.
        do {
            let (_, writer, reader) = stream(4)
            Self.write(writer, Self.bytes(1...16))
            let (n, _, _) = take(reader, 4)
            #expect(n == 4, "asked for 4 bytes, got \(n)")
        }

        // A read rings the writer only if it freed a slot and the writer sleeps.
        do {
            let (f, writer, reader) = stream(4)
            f.poke32(RingLayout.producerLine + RingLayout.waitingOffset, 1)
            #expect(take(reader, 8) == (0, false, false), "a read of nothing rang the writer")
            Self.write(writer, Self.bytes(1...8))
            #expect(take(reader, 8) == (8, false, true), "a read that freed a slot did not ring")
        }
    }
}
