import CroiRuntime

/// The debuglog as a ring (D38): the one ring in OVERWRITE mode, read
/// through a read-only mapping of the VMO the kernel hands over, with its
/// counter for a doorbell. Moved here from the boot program's round trip
/// when V1 cut debuglog_read; RingCheck covers torn slots on the host.
enum DebuglogSuite {
    static func run() {
        let vmo = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_VMO_DEBUGLOG), 0)))
        let counter = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_DEBUGLOG_COUNTER), 0)))
        check(vmo.raw != 0 && counter.raw != 0, "the ring and its counter handed over")
        refusals(vmo, counter)
        let mapping = Mapping(vmo, length: mapped, permissions: UInt32(CROI_VM_PERM_READ))
        let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(mapping.address))!
        guard var ring = unsafe NativeRing(attaching: base, size: size, producer: false, slotSize: slotSize,
                                           format: UInt64(CROI_LOG_RING_FORMAT), flags: RingLayout.overwrite) else {
            return check(false, "a reader attached")
        }
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_DEBUGLOG_CREATE, 0, 0, Sys.address(&raw)) == 0, "a log made, with no resource")
        let log = Handle(adopting: raw)
        roundTrip(&ring, log)
        doorbell(&ring, log, counter)
        lapped(&ring, log)
        _ = consume mapping
        print("swift: debuglog passed")
    }

    static var slotSize: Int { Int(CROI_LOG_RECORD_MAX) }
    static var size: Int { RingLayout.size(slotSize: slotSize, count: Int(CROI_LOG_RING_SLOTS))! }
    static var mapped: UInt64 { (UInt64(size) + pageSize - 1) & ~(pageSize - 1) }
    static var headerSize: Int { MemoryLayout<croi_log_record_t>.size }

    /// Reading is holding the handles: neither writes, and debuglog_create
    /// takes no resource and no options.
    static func refusals(_ vmo: borrowing Handle, _ counter: borrowing Handle) {
        var at: UInt64 = 0
        let rw = UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_PERM_WRITE)
        check(unsafe croi_vmar_map(td_runtime_vmar_root, rw, 0, vmo.raw, 0, mapped, &at) == Status.accessDenied,
              "the ring can't be mapped writable")
        check(croi_counter_add(counter.raw, 1) == Status.accessDenied, "nor its counter added to")
        let resource = td_startup_take(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_DEBUGLOG_CREATE, UInt64(resource), 0, Sys.address(&out)) == Status.invalidArgs
                  && Sys.call(CROI_SYS_DEBUGLOG_CREATE, 0, 0x4000_0000, Sys.address(&out)) == Status.invalidArgs,
              "a log only writes")
        _ = croi_handle_close(resource)
    }

    static func write(_ log: borrowing Handle, _ text: StaticString) -> Bool {
        Sys.call(CROI_SYS_DEBUGLOG_WRITE, log.arg, 0, unsafe UInt64(UInt(bitPattern: text.utf8Start)),
                 UInt64(text.utf8CodeUnitCount)) == 0
    }

    static func read(_ ring: inout NativeRing, _ record: inout InlineArray<256, UInt8>,
                     _ dropped: inout UInt64) -> Bool {
        var span = record.mutableSpan
        return span.withUnsafeMutableBytes { unsafe ring.read(to: $0.baseAddress!, dropped: &dropped) }
    }

    /// Reads everything there is; the drops.
    static func drain(_ ring: inout NativeRing) -> UInt64 {
        var record = InlineArray<256, UInt8>(repeating: 0)
        var dropped: UInt64 = 0
        while read(&ring, &record, &dropped) {}
        return dropped
    }

    /// A record written comes back whole: its sequence, this process's
    /// koids, the severity and the text, zeros after it.
    static func roundTrip(_ ring: inout NativeRing, _ log: borrowing Handle) {
        _ = drain(&ring)
        let sequence = ring.position
        let text: StaticString = "swift: round trip"
        check(write(log, text), "a record written")
        var record = InlineArray<256, UInt8>(repeating: 0xff)
        var dropped: UInt64 = 0
        check(read(&ring, &record, &dropped) && dropped == 0, "and read back")
        let header = unsafe record.span.bytes.unsafeLoadUnaligned(as: croi_log_record_t.self)
        var basic = croi_info_handle_basic_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, UInt64(td_runtime_process_self), UInt64(CROI_INFO_HANDLE_BASIC),
                       Sys.address(&basic), UInt64(MemoryLayout<croi_info_handle_basic_t>.size), 0, 0) == 0,
              "this process's koid")
        var same = header.sequence == sequence && header.datalen == UInt16(text.utf8CodeUnitCount)
            && header.severity == UInt8(CROI_LOG_INFO) && header.pid == basic.koid && header.tid != 0
        for i in 0..<text.utf8CodeUnitCount where unsafe record[headerSize + i] != text.utf8Start[i] { same = false }
        for i in (headerSize + text.utf8CodeUnitCount)..<slotSize where record[i] != 0 { same = false }
        check(same, "with its sequence, koids, severity and text")
    }

    /// The counter is the producer cursor: a caught-up reader binds VALUE
    /// at its position plus one, and the next record rings it.
    static func doorbell(_ ring: inout NativeRing, _ log: borrowing Handle, _ counter: borrowing Handle) {
        _ = drain(&ring)
        let port = Port()
        check(port.bind(counter, UInt32(CROI_BIND_VALUE), key: 7, trigger: ring.position + 1) == 0,
              "a caught-up reader binds the counter")
        check(port.empty, "which waits while nothing is written")
        check(write(log, "swift: doorbell"), "a record written")
        let packet = port.next(deadline: Sys.now() + 1_000_000_000)
        check(packet != nil && packet!.key == 7 && packet!.type == UInt32(CROI_PKT_TYPE_COUNTER),
              "rings the doorbell")
        check(drain(&ring) == 0 && ring.position == packet!.payload.1,
              "whose value is the cursor")
    }

    /// A reader lapped by more than the ring holds skips to the oldest
    /// record still there and counts the rest as dropped.
    static func lapped(_ ring: inout NativeRing, _ log: borrowing Handle) {
        _ = drain(&ring)
        let start = ring.position
        let count = UInt64(CROI_LOG_RING_SLOTS) + 100
        var written = true
        for _ in 0..<count { written = written && write(log, "l") }
        check(written, "a lap of records written")
        var record = InlineArray<256, UInt8>(repeating: 0)
        var dropped: UInt64 = 0, kept: UInt64 = 0
        var ordered = true
        while read(&ring, &record, &dropped) {
            let header = unsafe record.span.bytes.unsafeLoadUnaligned(as: croi_log_record_t.self)
            ordered = ordered && header.sequence == ring.position - 1
            kept += 1
        }
        check(dropped >= 100 && kept <= UInt64(CROI_LOG_RING_SLOTS) && ordered
                  && kept + dropped == ring.position - start && ring.position - start >= count,
              "a lapped reader resynchronises and counts its drops")
    }
}
