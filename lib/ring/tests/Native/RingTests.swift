import CRing
import Dispatch
import Ring
import Testing

/// The ring's two implementations (D43) on the hardware: one format, the
/// same refusals, and each feeding the other across real threads.
struct RingTests {
    static func buffer(slotSize: Int, count: Int) -> UnsafeMutableRawBufferPointer {
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: RingLayout.size(slotSize: slotSize, count: count)!,
                                                            alignment: 128)
        region.initializeMemory(as: UInt8.self, repeating: 0)
        return region
    }

    /// ring.h and Ring.swift agree on every constant, and make the same bytes.
    @Test func oneFormat() {
        #expect(RingLayout.magic == CROI_RING_MAGIC && UInt32(RingLayout.version) == CROI_RING_VERSION)
        #expect(RingLayout.producerLine == Int(CROI_RING_PRODUCER_LINE)
                    && RingLayout.consumerLine == Int(CROI_RING_CONSUMER_LINE)
                    && RingLayout.header == Int(CROI_RING_HEADER) && RingLayout.slots == Int(CROI_RING_SLOTS)
                    && RingLayout.waitingOffset == Int(CROI_RING_WAITING_OFFSET))
        #expect(UInt32(RingLayout.overwrite) == CROI_RING_OVERWRITE
                    && RingLayout.maxSlotSize == Int(CROI_RING_MAX_SLOT_SIZE)
                    && RingLayout.maxSlots == Int(CROI_RING_MAX_SLOTS))
        #expect(MemoryLayout<croi_ring_header_t>.size == 128)
        for (slotSize, count) in [(8, 1), (64, 256), (24, 3), (12, 4), (0, 4), (65544, 2), (8, 1 << 21)] {
            let swift = RingLayout.size(slotSize: slotSize, count: count) ?? 0
            #expect(UInt64(swift) == croi_ring_size(UInt32(slotSize), UInt32(count)), "\(slotSize) x \(count)")
        }
        let a = Self.buffer(slotSize: 48, count: 8), b = Self.buffer(slotSize: 48, count: 8)
        defer { a.deallocate(); b.deallocate() }
        #expect(NativeRing.create(a.baseAddress!, size: a.count, slotSize: 48, count: 8, format: 0x1234,
                                  flags: RingLayout.overwrite))
        #expect(croi_ring_create(b.baseAddress!, UInt64(b.count), 48, 8, 0x1234, UInt16(CROI_RING_OVERWRITE)))
        #expect(a.elementsEqual(b), "the same header")
    }

    /// Both refuse a header that isn't what they expect, and a ring too
    /// small for what its header says.
    @Test func refusals() {
        let region = Self.buffer(slotSize: 16, count: 4)
        defer { region.deallocate() }
        let base = region.baseAddress!
        #expect(!NativeRing.create(base, size: region.count, slotSize: 12, count: 4, format: 1), "a ragged slot")
        #expect(!NativeRing.create(base, size: region.count, slotSize: 16, count: 3, format: 1), "not a power of two")
        #expect(!NativeRing.create(base, size: region.count - 1, slotSize: 16, count: 4, format: 1), "too small")
        #expect(NativeRing.create(base, size: region.count, slotSize: 16, count: 4, format: 1))
        for (slotSize, format, flags, size) in [(32, 1, 0, region.count), (16, 2, 0, region.count),
                                                (16, 1, 1, region.count), (16, 1, 0, region.count - 8)] {
            let refused = NativeRing(attaching: base, size: size, producer: true, slotSize: slotSize,
                                     format: UInt64(format), flags: UInt16(flags)) == nil
            #expect(refused)
            var c = croi_ring_t()
            #expect(!croi_ring_attach(&c, base, UInt64(size), true, UInt32(slotSize), UInt64(format), UInt16(flags)))
        }
        base.storeBytes(of: 0, toByteOffset: RingLayout.header, as: UInt32.self)
        var c = croi_ring_t()
        let refused = NativeRing(attaching: base, size: region.count, producer: true, slotSize: 16, format: 1) == nil
        #expect(refused && !croi_ring_attach(&c, base, UInt64(region.count), true, 16, 1, 0), "a bad magic")
    }

    /// A producer cursor that runs past what fits breaks the ring for the
    /// consumer for good; a consumer cursor past the producer's, for the
    /// producer.
    @Test func brokenPeers() {
        let region = Self.buffer(slotSize: 16, count: 4)
        defer { region.deallocate() }
        let base = region.baseAddress!
        #expect(NativeRing.create(base, size: region.count, slotSize: 16, count: 4, format: 1))
        var consumer = NativeRing(attaching: base, size: region.count, producer: false, slotSize: 16, format: 1)!
        var c = croi_ring_t()
        #expect(croi_ring_attach(&c, base, UInt64(region.count), false, 16, 1, 0))
        base.storeBytes(of: UInt64(5), toByteOffset: RingLayout.producerLine, as: UInt64.self)
        let consumerBroken = consumer.ready() == 0 && consumer.broken
        #expect(consumerBroken && croi_ring_ready(&c) == 0 && c.broken)
        base.storeBytes(of: UInt64(4), toByteOffset: RingLayout.producerLine, as: UInt64.self)
        let stays = consumer.ready() == 0
        #expect(stays, "and stays broken")

        #expect(NativeRing.create(base, size: region.count, slotSize: 16, count: 4, format: 1))
        base.storeBytes(of: UInt64(0), toByteOffset: RingLayout.producerLine, as: UInt64.self)
        var producer = NativeRing(attaching: base, size: region.count, producer: true, slotSize: 16, format: 1)!
        var p = croi_ring_t()
        #expect(croi_ring_attach(&p, base, UInt64(region.count), true, 16, 1, 0))
        base.storeBytes(of: UInt64(1), toByteOffset: RingLayout.consumerLine, as: UInt64.self)
        let producerBroken = producer.space() == 0 && producer.broken
        #expect(producerBroken && croi_ring_space(&p) == 0 && p.broken)
    }

    /// OVERWRITE: a reader lapped by the writer keeps the newest slots'
    /// worth and counts the rest as dropped.
    @Test func overwrite() {
        let region = Self.buffer(slotSize: 16, count: 4)
        defer { region.deallocate() }
        let base = region.baseAddress!
        #expect(NativeRing.create(base, size: region.count, slotSize: 16, count: 4, format: 2,
                                  flags: RingLayout.overwrite))
        var writer = NativeRing(attaching: base, size: region.count, producer: true, slotSize: 16, format: 2,
                                flags: RingLayout.overwrite)!
        var swift = NativeRing(attaching: base, size: region.count, producer: false, slotSize: 16, format: 2,
                               flags: RingLayout.overwrite)!
        var c = croi_ring_t()
        #expect(croi_ring_attach(&c, base, UInt64(region.count), false, 16, 2, UInt16(CROI_RING_OVERWRITE)))
        for n: UInt64 in 0..<10 {
            var record = (UInt64(0), n * 10)
            withUnsafeBytes(of: &record) { writer.write(from: $0.baseAddress!) }
        }
        var swiftDropped: UInt64 = 0, cDropped: UInt64 = 0
        var swiftKept: [UInt64] = [], cKept: [UInt64] = []
        var record: (UInt64, UInt64) = (0, 0)
        while withUnsafeMutableBytes(of: &record, { swift.read(to: $0.baseAddress!, dropped: &swiftDropped) }) {
            #expect(record.1 == record.0 * 10)
            swiftKept.append(record.0)
        }
        while withUnsafeMutableBytes(of: &record, { croi_ring_read(&c, $0.baseAddress!, &cDropped) }) {
            #expect(record.1 == record.0 * 10)
            cKept.append(record.0)
        }
        #expect(swiftKept == [6, 7, 8, 9] && swiftDropped == 6)
        #expect(cKept == [6, 7, 8, 9] && cDropped == 6)
    }

    /// A million 64-byte entries from one implementation to the other on
    /// two threads, each checked, spinning (no doorbells) when it must wait.
    @Test(arguments: [true, false])
    func acrossThreads(swiftProduces: Bool) async {
        let count = 64, slotSize = 64, entries: UInt64 = 1_000_000
        let region = Self.buffer(slotSize: slotSize, count: count)
        defer { region.deallocate() }
        let base = region.baseAddress!
        #expect(croi_ring_create(base, UInt64(region.count), UInt32(slotSize), UInt32(count), 9, 0))
        let address = UInt(bitPattern: base), size = region.count
        let producer = Thread {
            let base = UnsafeMutableRawPointer(bitPattern: address)!
            var entry = InlineArray<8, UInt64>(repeating: 0)
            if swiftProduces {
                var ring = NativeRing(attaching: base, size: size, producer: true, slotSize: slotSize, format: 9)!
                var n: UInt64 = 0
                while n < entries {
                    let space = min(ring.space(), entries - n)
                    for i in 0..<space {
                        for w in 0..<8 { entry[w] = n + i }
                        entry.span.withUnsafeBytes { ring.put(i, from: $0.baseAddress!) }
                    }
                    if space > 0 { _ = ring.publish(space) }
                    n += space
                }
            } else {
                var ring = croi_ring_t()
                precondition(croi_ring_attach(&ring, base, UInt64(size), true, UInt32(slotSize), 9, 0))
                var n: UInt64 = 0
                while n < entries {
                    let space = min(croi_ring_space(&ring), entries - n)
                    for i in 0..<space {
                        for w in 0..<8 { entry[w] = n + i }
                        entry.span.withUnsafeBytes { croi_ring_put(&ring, i, $0.baseAddress!) }
                    }
                    if space > 0 { _ = croi_ring_publish(&ring, space) }
                    n += space
                }
            }
        }
        var wrong: UInt64 = 0
        var entry = InlineArray<8, UInt64>(repeating: 0)
        var n: UInt64 = 0
        if swiftProduces {
            var ring = croi_ring_t()
            #expect(croi_ring_attach(&ring, base, UInt64(size), false, UInt32(slotSize), 9, 0))
            while n < entries {
                let ready = croi_ring_ready(&ring)
                for i in 0..<ready {
                    var span = entry.mutableSpan
                    span.withUnsafeMutableBytes { croi_ring_get(&ring, i, $0.baseAddress!) }
                    for w in 0..<8 where entry[w] != n + i { wrong += 1 }
                }
                if ready > 0 { _ = croi_ring_release(&ring, ready) }
                n += ready
            }
        } else {
            var ring = NativeRing(attaching: base, size: size, producer: false, slotSize: slotSize, format: 9)!
            while n < entries {
                let ready = ring.ready()
                for i in 0..<ready {
                    var span = entry.mutableSpan
                    span.withUnsafeMutableBytes { ring.get(i, to: $0.baseAddress!) }
                    for w in 0..<8 where entry[w] != n + i { wrong += 1 }
                }
                if ready > 0 { _ = ring.release(ready) }
                n += ready
            }
        }
        producer.join()
        #expect(wrong == 0 && n == entries)
    }

    /// A thread that runs `body`, and can be waited for.
    final class Thread: @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        init(_ body: @escaping @Sendable () -> Void) {
            DispatchQueue.global().async { [finished] in
                body()
                finished.signal()
            }
        }
        func join() { finished.wait() }
    }
}
