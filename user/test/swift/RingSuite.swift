import CroiRuntime

/// The one ring (D43) on the target: Ring.swift between two threads of
/// this process, through a VMO, with counters for doorbells, each bound
/// CHANGE to the sleeper's port (D20). RingCheck checks the protocol on
/// the host; this checks the code as built here, the doorbells, and
/// refusals.
enum RingSuite {
    static func run() {
        refusals()
        transfer(entries: 20_000, delay: 0, "entries arrive in order, whole")
        transfer(entries: 500, delay: 5_000_000, "and wake a consumer asleep first")
        print("swift: ring passed")
    }

    static var slotSize: Int { 64 }
    static var count: Int { 16 }
    static var format: UInt64 { 0x5249_4e47 }  // "RING": eight words, each the entry's number
    static var change: UInt32 { UInt32(CROI_BIND_CHANGE) | UInt32(CROI_BIND_PERSISTENT) }

    /// A ring refuses a side that expects another format, slot size or
    /// mode, and a mapping too small for its header.
    static func refusals() {
        let size = RingLayout.size(slotSize: slotSize, count: count)!
        let vmo = Handle(vmo: UInt64(size))
        let mapping = Mapping(vmo, length: (UInt64(size) + pageSize - 1) & ~(pageSize - 1))
        let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(mapping.address))!
        check(unsafe NativeRing.create(base, size: size, slotSize: slotSize, count: count, format: format),
              "a ring made")
        check(unsafe !NativeRing.create(base, size: size, slotSize: 12, count: count, format: format),
              "not with a ragged slot")
        let refused = unsafe NativeRing(attaching: base, size: size, producer: true, slotSize: slotSize,
                                        format: format + 1) == nil
            && NativeRing(attaching: base, size: size, producer: true, slotSize: 32, format: format) == nil
            && NativeRing(attaching: base, size: size, producer: true, slotSize: slotSize, format: format,
                          flags: RingLayout.overwrite) == nil
            && NativeRing(attaching: base, size: size - 8, producer: true, slotSize: slotSize, format: format) == nil
        check(refused, "a side expecting another ring is refused")
    }

    struct Shared {
        var base: UInt64 = 0
        var size = 0
        var entries: UInt64 = 0
        var delay: UInt64 = 0
        var dataBell: UInt32 = 0   // the consumer's doorbell
        var spaceBell: UInt32 = 0  // the producer's
        var spacePort: UInt32 = 0
        var kicks: UInt64 = 0
        var attached = false
    }

    /// The producer thread: fills what space there is, publishes it, and
    /// rings the consumer's doorbell when the ring says it sleeps; sleeps
    /// on its own when the ring is full.
    static let producer: @convention(c) (UInt64) -> Void = { argument in
        let shared = unsafe UnsafeMutablePointer<Shared>(bitPattern: UInt(argument))!
        if unsafe shared.pointee.delay > 0 { unsafe Sys.sleep(shared.pointee.delay) }
        let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(shared.pointee.base))!
        guard var ring = unsafe NativeRing(attaching: base, size: shared.pointee.size, producer: true,
                                           slotSize: slotSize, format: format) else { Thread.exit() }
        unsafe shared.pointee.attached = true
        let entries = unsafe shared.pointee.entries
        var entry = InlineArray<8, UInt64>(repeating: 0)
        var n: UInt64 = 0
        while n < entries {
            let space = min(ring.space(), entries - n)
            if space == 0 {
                if ring.prepareSleep() {
                    var packet = croi_port_packet_t()
                    _ = unsafe croi_port_wait(shared.pointee.spacePort, Sys.now() + 5_000_000_000, &packet, 0)
                }
                ring.endSleep()
                continue
            }
            for i in 0..<space {
                for w in 0..<8 { entry[w] = n + i }
                entry.span.withUnsafeBytes { unsafe ring.put(i, from: $0.baseAddress!) }
            }
            if ring.publish(space) {
                _ = unsafe croi_counter_add(shared.pointee.dataBell, 1)
                unsafe shared.pointee.kicks += 1
            }
            n += space
        }
        Thread.exit()
    }

    /// `entries` entries from a producer thread to this one through 16
    /// slots, both sleeping when they must; with `delay`, the producer
    /// starts late, so the consumer sleeps first.
    static func transfer(entries: UInt64, delay: UInt64, _ name: StaticString) {
        let size = RingLayout.size(slotSize: slotSize, count: count)!
        let vmo = Handle(vmo: UInt64(size))
        let mapping = Mapping(vmo, length: (UInt64(size) + pageSize - 1) & ~(pageSize - 1))
        let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(mapping.address))!
        check(unsafe NativeRing.create(base, size: size, slotSize: slotSize, count: count, format: format),
              "a ring made")
        let dataBell = Handle(creating: CROI_SYS_COUNTER_CREATE)
        let spaceBell = Handle(creating: CROI_SYS_COUNTER_CREATE)
        let dataPort = Port(), spacePort = Port()
        check(dataPort.bind(dataBell, change, key: 1) == 0 && spacePort.bind(spaceBell, change, key: 2) == 0,
              "doorbells bound")
        let shared = UnsafeMutablePointer<Shared>.allocate(capacity: 1)
        defer { unsafe shared.deallocate() }
        unsafe shared.initialize(to: Shared(base: mapping.address, size: size, entries: entries, delay: delay,
                                            dataBell: dataBell.raw, spaceBell: spaceBell.raw,
                                            spacePort: spacePort.handle.raw))
        guard var ring = unsafe NativeRing(attaching: base, size: size, producer: false, slotSize: slotSize,
                                           format: format) else { return check(false, "the consumer attached") }
        let thread = Thread(producer, UInt64(UInt(bitPattern: shared)))
        var entry = InlineArray<8, UInt64>(repeating: 0)
        var n: UInt64 = 0, wrong: UInt64 = 0, kicks: UInt64 = 0, sleeps: UInt64 = 0
        while n < entries {
            let ready = ring.ready()
            if ready == 0 {
                if ring.prepareSleep() {
                    sleeps += 1
                    guard dataPort.next(deadline: Sys.now() + 5_000_000_000) != nil else {
                        return check(false, "a doorbell rang")
                    }
                }
                ring.endSleep()
                continue
            }
            for i in 0..<ready {
                var span = entry.mutableSpan
                span.withUnsafeMutableBytes { unsafe ring.get(i, to: $0.baseAddress!) }
                for w in 0..<8 where entry[w] != n + i { wrong += 1 }
            }
            if ring.release(ready) {
                _ = croi_counter_add(spaceBell.raw, 1)
                kicks += 1
            }
            n += ready
        }
        thread.join()
        let attached = unsafe shared.pointee.attached, dataKicks = unsafe shared.pointee.kicks
        check(attached && wrong == 0 && !ring.broken, name)
        if delay > 0 { check(sleeps > 0 && dataKicks > 0, "the consumer slept, and was woken") }
        print("swift: ring: \(entries) entries, \(dataKicks) data and \(kicks) space doorbells, "
              + "\(sleeps) consumer sleeps")
        _ = consume vmo
        _ = consume mapping
    }
}
