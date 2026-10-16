import CRing
import Ring
import Testing

/// BYTE_STREAM (D46) on both implementations: the format and refusals,
/// reads and writes of any size with the end mark after the bytes, a
/// hostile header breaking the ring, and each implementation feeding the
/// other across threads.
struct ByteStreamTests {
    static let flags = RingLayout.byteStream

    @Test func oneFormat() {
        #expect(UInt32(RingLayout.byteStream) == CROI_RING_BYTE_STREAM)
        #expect(RingLayout.streamHeader == Int(CROI_RING_STREAM_HEADER) && RingLayout.streamEnd == CROI_RING_STREAM_END)
        let region = RingTests.buffer(slotSize: 16, count: 4)
        defer { region.deallocate() }
        let base = region.baseAddress!
        // Not both modes, and a slot must hold more than its header.
        #expect(!NativeRing.create(base, size: region.count, slotSize: 16, count: 4, format: 1,
                                   flags: RingLayout.overwrite | Self.flags))
        #expect(!croi_ring_create(base, UInt64(region.count), 16, 4, 1, UInt16(CROI_RING_OVERWRITE | CROI_RING_BYTE_STREAM)))
        #expect(!NativeRing.create(base, size: region.count, slotSize: 8, count: 4, format: 1, flags: Self.flags))
        #expect(!croi_ring_create(base, UInt64(region.count), 8, 4, 1, UInt16(CROI_RING_BYTE_STREAM)))
    }

    /// Writes of 0 to 40 bytes and reads of 1 to 23, each implementation
    /// writing and the other reading: the same bytes, the end mark once
    /// after the last, and a writer that fills the ring told so.
    @Test(arguments: [true, false])
    func anySizes(swiftWrites: Bool) {
        let slotSize = 24, count = 8
        let region = RingTests.buffer(slotSize: slotSize, count: count)
        defer { region.deallocate() }
        let base = region.baseAddress!
        #expect(NativeRing.create(base, size: region.count, slotSize: slotSize, count: count, format: 3, flags: Self.flags))
        var swift = NativeRing(attaching: base, size: region.count, producer: swiftWrites, slotSize: slotSize, format: 3,
                               flags: Self.flags)!
        var c = croi_ring_t()
        #expect(croi_ring_attach(&c, base, UInt64(region.count), !swiftWrites, UInt32(slotSize), 3,
                                 UInt16(CROI_RING_BYTE_STREAM)))
        let total = 5000
        let source = (0..<total).map { UInt8(truncatingIfNeeded: $0 * 31 + $0 / 7) }
        var sent = 0, received: [UInt8] = [], ended = false, endSent = false, sizes = 0
        var buffer = [UInt8](repeating: 0, count: 64)
        while !ended {
            // Write some: a size from 0 to 40, as much as fits.
            if sent < total {
                let n = min(sizes % 41, total - sent)
                let written = source.withUnsafeBytes { s in
                    swiftWrites ? swift.write(bytes: s.baseAddress! + sent, count: n).written
                        : { var wake = false; return Int(croi_ring_write_bytes(&c, s.baseAddress! + sent, UInt64(n), &wake)) }()
                }
                sent += written
            } else if !endSent {
                var wake = false
                endSent = swiftWrites ? swift.writeEnd().done : croi_ring_write_end(&c, &wake)
            }
            // Read some: from 1 to 23.
            let max = 1 + sizes % 23
            let got = buffer.withUnsafeMutableBytes { b -> Int in
                if swiftWrites {
                    var wake = false
                    return Int(croi_ring_read_bytes(&c, b.baseAddress!, UInt64(max), &ended, &wake))
                }
                let r = swift.read(bytes: b.baseAddress!, max: max)
                ended = r.ended
                return r.count
            }
            received += buffer[..<got]
            sizes += 1
            #expect(sizes < 100_000, "the stream stalled")
            if sizes >= 100_000 { break }
        }
        #expect(received == source)
        #expect(endSent && ended)
        // Ended stays ended.
        let again = buffer.withUnsafeMutableBytes { b -> (Int, Bool) in
            if swiftWrites {
                var wake = false, e = false
                return (Int(croi_ring_read_bytes(&c, b.baseAddress!, 8, &e, &wake)), e)
            }
            let r = swift.read(bytes: b.baseAddress!, max: 8)
            return (r.count, r.ended)
        }
        #expect(again == (0, true))
    }

    /// A slot claiming more bytes than it holds, or flags it doesn't know,
    /// breaks the ring for its reader.
    @Test func hostileHeaders() {
        for bad: UInt64 in [17, UInt64(2) << 32, UInt64.max] {
            let region = RingTests.buffer(slotSize: 24, count: 4)
            defer { region.deallocate() }
            let base = region.baseAddress!
            #expect(NativeRing.create(base, size: region.count, slotSize: 24, count: 4, format: 3, flags: Self.flags))
            var writer = NativeRing(attaching: base, size: region.count, producer: true, slotSize: 24, format: 3,
                                    flags: Self.flags)!
            var bytes: [UInt8] = [1, 2, 3]
            _ = bytes.withUnsafeBytes { writer.write(bytes: $0.baseAddress!, count: 3) }
            base.storeBytes(of: bad.littleEndian, toByteOffset: RingLayout.slots, as: UInt64.self)
            var swift = NativeRing(attaching: base, size: region.count, producer: false, slotSize: 24, format: 3,
                                   flags: Self.flags)!
            var c = croi_ring_t()
            #expect(croi_ring_attach(&c, base, UInt64(region.count), false, 24, 3, UInt16(CROI_RING_BYTE_STREAM)))
            let s = bytes.withUnsafeMutableBytes { swift.read(bytes: $0.baseAddress!, max: 3) }
            var ended = false, wake = false
            let n = bytes.withUnsafeMutableBytes { croi_ring_read_bytes(&c, $0.baseAddress!, 3, &ended, &wake) }
            let swiftBroken = swift.broken
            #expect(s.count == 0 && swiftBroken && n == 0 && c.broken, "header \(bad)")
        }
    }

    /// Four megabytes from one implementation to the other on two threads,
    /// in writes and reads of sizes that don't line up with the slots.
    @Test(arguments: [true, false])
    func acrossThreads(swiftWrites: Bool) {
        let slotSize = 256, count = 64, total = 4 << 20
        let region = RingTests.buffer(slotSize: slotSize, count: count)
        defer { region.deallocate() }
        let base = region.baseAddress!
        #expect(croi_ring_create(base, UInt64(region.count), UInt32(slotSize), UInt32(count), 4,
                                 UInt16(CROI_RING_BYTE_STREAM)))
        let address = UInt(bitPattern: base), size = region.count
        @Sendable func byte(_ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: i &* 131 &+ i >> 11) }
        let writer = RingTests.Thread {
            let base = UnsafeMutableRawPointer(bitPattern: address)!
            var chunk = [UInt8](repeating: 0, count: 1000)
            var sent = 0, step = 0
            var swift = swiftWrites
                ? NativeRing(attaching: base, size: size, producer: true, slotSize: slotSize, format: 4,
                             flags: RingLayout.byteStream) : nil
            var c = croi_ring_t()
            if !swiftWrites { precondition(croi_ring_attach(&c, base, UInt64(size), true, UInt32(slotSize), 4,
                                                            UInt16(CROI_RING_BYTE_STREAM))) }
            while sent < total {
                let n = min(1 + (step * 397) % 1000, total - sent)
                for i in 0..<n { chunk[i] = byte(sent + i) }
                var off = 0
                while off < n {
                    let w = chunk.withUnsafeBytes { b -> Int in
                        if swift != nil { return swift!.write(bytes: b.baseAddress! + off, count: n - off).written }
                        var wake = false
                        return Int(croi_ring_write_bytes(&c, b.baseAddress! + off, UInt64(n - off), &wake))
                    }
                    off += w
                }
                sent += n
                step += 1
            }
            var done = false
            while !done {
                if swift != nil { done = swift!.writeEnd().done } else { var wake = false; done = croi_ring_write_end(&c, &wake) }
            }
        }
        var received = 0, wrong = 0, ended = false, step = 0
        var buffer = [UInt8](repeating: 0, count: 777)
        var swift = !swiftWrites
            ? NativeRing(attaching: base, size: size, producer: false, slotSize: slotSize, format: 4,
                         flags: Self.flags) : nil
        var c = croi_ring_t()
        if swiftWrites {
            #expect(croi_ring_attach(&c, base, UInt64(size), false, UInt32(slotSize), 4, UInt16(CROI_RING_BYTE_STREAM)))
        }
        while !ended {
            let max = 1 + (step * 211) % 777
            let got = buffer.withUnsafeMutableBytes { b -> Int in
                if swift != nil {
                    let r = swift!.read(bytes: b.baseAddress!, max: max)
                    ended = r.ended
                    return r.count
                }
                var wake = false
                return Int(croi_ring_read_bytes(&c, b.baseAddress!, UInt64(max), &ended, &wake))
            }
            for i in 0..<got where buffer[i] != byte(received + i) { wrong += 1 }
            received += got
            step += 1
        }
        writer.join()
        #expect(wrong == 0 && received == total)
    }
}
