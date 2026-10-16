/// The one ring (architecture §3, D43) in Swift: the same format and
/// protocol as lib/ring/ring.h, which says what each part does. A host test
/// pins the two formats equal, and RingCheck model-checks both through
/// `Memory`. No syscalls: the caller rings doorbells and sleeps when a
/// call says to.
public enum RingLayout {
    public static var magic: UInt32 { 0x474e_5256 }  // "VRNG"
    public static var version: UInt16 { 1 }
    public static var producerLine: Int { 0 }
    public static var consumerLine: Int { 128 }
    public static var header: Int { 256 }
    public static var slots: Int { 384 }
    public static var waitingOffset: Int { 8 }
    public static var overwrite: UInt16 { 1 }
    public static var knownFlags: UInt16 { overwrite }
    public static var maxSlotSize: Int { 65536 }
    public static var maxSlots: Int { 1 << 20 }
    /// Header fields' offsets (croi_ring_header_t).
    static var magicOffset: Int { 0 }
    static var versionOffset: Int { 4 }
    static var flagsOffset: Int { 6 }
    static var slotSizeOffset: Int { 8 }
    static var slotCountOffset: Int { 12 }
    static var formatOffset: Int { 16 }

    /// The bytes a ring of `count` slots of `slotSize` takes; nil if the
    /// parameters aren't valid.
    public static func size(slotSize: Int, count: Int) -> Int? {
        guard slotSize > 0, slotSize % 8 == 0, slotSize <= maxSlotSize else { return nil }
        guard count > 0, count <= maxSlots, count & (count - 1) == 0 else { return nil }
        return slots + slotSize * count
    }
}

/// One side's private view of a ring: its producer or consumer, or an
/// OVERWRITE ring's writer or a reader.
@safe
public struct Ring<Memory: RingMemory>: ~Copyable {
    private let base: UnsafeMutableRawPointer
    public let slotSize: Int
    public let slotCount: UInt64
    public let format: UInt64
    public let flags: UInt16
    private let mask: UInt64
    private var cursor: UInt64
    private var other: UInt64 = 0
    private let ownLine: UnsafeMutableRawPointer?
    private let otherLine: UnsafeMutableRawPointer
    public let producer: Bool
    /// The other side broke the protocol: every call fails from here on.
    public private(set) var broken = false
    /// This side's cursor (ring.h's `cursor`): for an OVERWRITE reader,
    /// the sequence of the next record it will read.
    public var position: UInt64 { cursor }

    /// Makes a ring in `size` bytes of zeroed memory at `base`, once,
    /// before either side attaches. False if the parameters aren't valid
    /// or don't fit.
    @unsafe
    public static func create(_ base: UnsafeMutableRawPointer, size: Int, slotSize: Int, count: Int,
                              format: UInt64, flags: UInt16 = 0) -> Bool {
        guard let need = RingLayout.size(slotSize: slotSize, count: count), need <= size,
              flags & ~RingLayout.knownFlags == 0 else { return false }
        var header = InlineArray<16, UInt64>(repeating: 0)
        header[0] = UInt64(RingLayout.magic) | UInt64(RingLayout.version) << 32 | UInt64(flags) << 48
        header[1] = UInt64(slotSize) | UInt64(count) << 32
        header[2] = format
        header.span.withUnsafeBytes { bytes in
            unsafe Memory.copy(base + RingLayout.header, bytes.baseAddress!, bytes.count)
        }
        return true
    }

    /// Attaches to the ring mapped at `base` (`size` bytes mapped). The
    /// header must say what this side expects (its slot size, format and
    /// flags): whoever made the ring may be hostile. Nil otherwise. Takes
    /// the cursors as they stand.
    @unsafe
    public init?(attaching base: UnsafeMutableRawPointer, size: Int, producer: Bool, slotSize: Int, format: UInt64,
                 flags: UInt16 = 0) {
        guard size >= RingLayout.slots else { return nil }
        var header = InlineArray<16, UInt64>(repeating: 0)
        var span = header.mutableSpan
        span.withUnsafeMutableBytes { bytes in
            unsafe Memory.copy(bytes.baseAddress!, base + RingLayout.header, bytes.count)
        }
        let magic = UInt32(truncatingIfNeeded: header[0])
        let version = UInt16(truncatingIfNeeded: header[0] >> 32)
        let theirFlags = UInt16(truncatingIfNeeded: header[0] >> 48)
        let theirSlotSize = Int(UInt32(truncatingIfNeeded: header[1]))
        let count = Int(UInt32(truncatingIfNeeded: header[1] >> 32))
        guard magic == RingLayout.magic, version == RingLayout.version, theirFlags == flags,
              theirSlotSize == slotSize, header[2] == format,
              let need = RingLayout.size(slotSize: slotSize, count: count), need <= size else { return nil }
        unsafe self.base = base
        self.slotSize = slotSize
        self.slotCount = UInt64(count)
        self.format = format
        self.flags = flags
        self.mask = UInt64(count - 1)
        self.producer = producer
        let producerLine = unsafe base + RingLayout.producerLine
        let consumerLine = unsafe base + RingLayout.consumerLine
        if flags & RingLayout.overwrite != 0 {
            // The writer goes on from its cursor; a reader starts at the
            // oldest record still there.
            unsafe ownLine = producer ? producerLine : nil
            unsafe otherLine = producerLine
            let tail = unsafe Memory.load64(producerLine, .acquiring)
            cursor = producer ? tail : tail < UInt64(count) ? 0 : tail - UInt64(count)
            return
        }
        unsafe ownLine = producer ? producerLine : consumerLine
        unsafe otherLine = producer ? consumerLine : producerLine
        cursor = unsafe Memory.load64(ownLine!, .relaxed)
        other = unsafe Memory.load64(otherLine, .acquiring)
    }

    private func slot(at cursor: UInt64) -> UnsafeMutableRawPointer {
        unsafe base + RingLayout.slots + Int(cursor & mask) * slotSize
    }

    private var waiting: UnsafeMutableRawPointer { unsafe ownLine! + RingLayout.waitingOffset }
    private var otherWaiting: UnsafeMutableRawPointer { unsafe otherLine + RingLayout.waitingOffset }

    // MARK: The producer

    /// How many slots are free to fill (0: full, or broken).
    public mutating func space() -> UInt64 {
        guard !broken else { return 0 }
        other = unsafe Memory.load64(otherLine, .acquiring)
        let used = cursor &- other
        guard used <= slotCount else {  // the consumer's head ran past our tail
            broken = true
            return 0
        }
        return slotCount - used
    }

    /// The `i`th free slot (i < space()), to fill in place. Nothing is
    /// visible to the consumer until `publish`.
    public func slot(_ i: UInt64) -> UnsafeMutableRawPointer { unsafe slot(at: cursor &+ i) }

    /// Copies a slot's worth of bytes from `from` into the `i`th free slot.
    @unsafe
    public func put(_ i: UInt64, from: UnsafeRawPointer) {
        unsafe Memory.copy(slot(i), from, slotSize)
    }

    /// Publishes the next `count` slots. True if the consumer sleeps, and
    /// its doorbell must be rung.
    public mutating func publish(_ count: UInt64) -> Bool {
        cursor &+= count
        unsafe Memory.store64(ownLine!, cursor, .releasing)
        Memory.fence(.sequentiallyConsistent)
        return unsafe Memory.load32(otherWaiting, .relaxed) != 0
    }

    // MARK: The consumer

    /// How many slots are ready to read (0: empty, or broken).
    public mutating func ready() -> UInt64 {
        guard !broken else { return 0 }
        other = unsafe Memory.load64(otherLine, .acquiring)
        let ready = other &- cursor
        guard ready <= slotCount else {  // the producer's tail ran ahead of what fits
            broken = true
            return 0
        }
        return ready
    }

    /// Copies the `i`th ready slot (i < ready()) out to `to`.
    @unsafe
    public func get(_ i: UInt64, to: UnsafeMutableRawPointer) {
        unsafe Memory.copy(to, slot(at: cursor &+ i), slotSize)
    }

    /// Frees the next `count` slots. True if the producer sleeps waiting
    /// for space, and its doorbell must be rung.
    public mutating func release(_ count: UInt64) -> Bool {
        cursor &+= count
        unsafe Memory.store64(ownLine!, cursor, .releasing)
        Memory.fence(.sequentiallyConsistent)
        return unsafe Memory.load32(otherWaiting, .relaxed) != 0
    }

    // MARK: Sleeping, either side

    /// About to sleep (the consumer on an empty ring, the producer on a
    /// full one): says so, then looks once more. True if there is still
    /// nothing to do, and the caller may wait for its doorbell; false if
    /// the other side moved meanwhile (and the announcement is withdrawn).
    public mutating func prepareSleep() -> Bool {
        guard !broken else { return false }
        unsafe Memory.store32(waiting, 1, .relaxed)
        Memory.fence(.sequentiallyConsistent)
        let other = unsafe Memory.load64(otherLine, .acquiring)
        let idle = producer ? cursor &- other == slotCount : other == cursor
        if !idle { unsafe Memory.store32(waiting, 0, .relaxed) }
        return idle
    }

    /// Awake: the other side need not ring until the next `prepareSleep`.
    public func endSleep() {
        unsafe Memory.store32(waiting, 0, .relaxed)
    }

    // MARK: OVERWRITE

    /// Writes a slot's worth of bytes from `from` (its first 8, the
    /// sequence, are the ring's) as the next record, overwriting the
    /// oldest. Never waits.
    @unsafe
    public mutating func write(from: UnsafeRawPointer) {
        let slot = unsafe slot(at: cursor)
        unsafe Memory.store64(slot, ~0, .relaxed)
        Memory.fence(.releasing)  // the mark before the bytes
        unsafe Memory.copy(slot + 8, from + 8, slotSize - 8)
        unsafe Memory.store64(slot, cursor, .releasing)
        cursor &+= 1
        unsafe Memory.store64(ownLine!, cursor, .releasing)
    }

    /// Copies the next record out to `to`. True if there was one;
    /// `dropped` grows by the records the writer overwrote before this
    /// reader got to them. A record whose sequence isn't its cursor, before
    /// or after the copy, has been overwritten (or is being): it is dropped.
    @unsafe
    public mutating func read(to: UnsafeMutableRawPointer, dropped: inout UInt64) -> Bool {
        guard !broken else { return false }
        while true {
            let tail = unsafe Memory.load64(otherLine, .acquiring)
            if tail == cursor { return false }
            if tail &- cursor > slotCount {  // lapped: skip to the oldest still there
                dropped &+= tail &- slotCount &- cursor
                cursor = tail &- slotCount
            }
            let slot = unsafe slot(at: cursor)
            if unsafe Memory.load64(slot, .acquiring) == cursor {
                unsafe Memory.copy(to, slot, slotSize)
                Memory.fence(.acquiring)  // the bytes before the second look
                if unsafe Memory.load64(slot, .relaxed) == cursor {
                    cursor &+= 1
                    return true
                }
            }
            dropped &+= 1
            cursor &+= 1
        }
    }
}

/// The ring on the hardware's atomics.
public typealias NativeRing = Ring<NativeMemory>
