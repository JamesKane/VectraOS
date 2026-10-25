import CKernel
import Fmt
import PageTables
import Synchronization

/// The debuglog (K8a; Zircon's dlog): since D38, the one ring (Ring.swift)
/// in OVERWRITE mode, of 512 slots of 256 bytes, each a record
/// (croi_log_record_t, log.h), so the oldest are overwritten when it is
/// full. Writers are user processes (`debuglog_write`) and the kernel,
/// serialised by the debuglog lock into the ring's one producer. Readers
/// map the ring's VMO read only and keep their own cursors; its counter
/// is the producer cursor, the doorbell a caught-up reader binds. A dumper
/// thread, a reader like any other, copies every record to the console
/// (`[sssss.mmm] pid:tid> text`), so writers never wait for the UART.
///
/// Lock order: debuglog -> object -> scheduler (the counter's add runs its
/// observers under the debuglog lock; nothing takes it under those).
enum DebugLog {
    static var slots: Int { Int(CROI_LOG_RING_SLOTS) }
    static var slotSize: Int { Int(CROI_LOG_RECORD_MAX) }
    static var headerSize: Int { MemoryLayout<croi_log_record_t>.size }
    static var format: UInt64 { UInt64(CROI_LOG_RING_FORMAT) }
    static var flags: UInt16 { RingLayout.overwrite }
    static var size: Int { RingLayout.size(slotSize: slotSize, count: slots)! }

    /// Where the ring is mapped in the kernel.
    nonisolated(unsafe) private static var base: UInt64 = 0
    /// The producer (debuglog lock).
    nonisolated(unsafe) private static var writer: NativeRing? = nil
    /// The ring's VMO and its counter, handed to readers (CROI_PA_VMO_DEBUGLOG,
    /// CROI_PA_DEBUGLOG_COUNTER); kept forever.
    nonisolated(unsafe) private(set) static var vmoObject = ObjectPointer(address: 0)
    nonisolated(unsafe) private(set) static var counter = ObjectPointer(address: 0)
    /// A reader's rights: map it read only, and bind (not add to) the counter.
    static var vmoRights: Rights { .basic | .read | .map | .getProperty }
    static var counterRights: Rights { .basic | .read }
    /// Records written: the producer cursor, for the dumper's sleep and
    /// CROI_INFO_DEBUGLOG.
    private static let written = Atomic<UInt64>(0)
    nonisolated(unsafe) private static var dumperQueue = QueuePointer(address: 0)
    /// Set at power off (K10e): the dumper stops at the end of its line, so
    /// the CPUs are halted with nobody part way through the console.
    static let quiet = Atomic<Bool>(false)
    /// Records the dumper has finished with (K10d: CROI_INFO_DEBUGLOG).
    private static let printed = Atomic<UInt64>(0)

    /// How far writing and printing have got.
    static var progress: croi_info_debuglog_t {
        croi_info_debuglog_t(written: written.load(ordering: .acquiring), printed: printed.load(ordering: .acquiring))
    }

    static func initialize() {
        let mapped = (UInt64(size) + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
        do throws(VmError) {
            let vmo = try Vmo(contiguous: mapped)
            guard case .contiguous(let phys) = vmo.record.pointee.kind else { panic("debuglog: ring VMO") }
            base = try kernelAspace.mapPhysical(phys, size: mapped, MapAttributes(writable: true, global: true))
            let at = unsafe UnsafeMutableRawPointer(bitPattern: UInt(base))!
            guard unsafe NativeRing.create(at, size: size, slotSize: slotSize, count: slots, format: format,
                                           flags: flags) else { panic("debuglog: making the ring") }
            writer = unsafe NativeRing(attaching: at, size: size, producer: true, slotSize: slotSize, format: format,
                                       flags: flags)
            do throws(Status) {
                vmoObject = try VmoObject.wrap(vmo.record)
                counter = try Counters.create()
            } catch {
                panic("debuglog: no memory for its objects")
            }
        } catch {
            panic("debuglog: no memory for the ring")
        }
        dumperQueue = QueuePointer.allocate()
        do throws(VmError) {
            let dumper = try Scheduler.spawn("dlog-dumper", dump, 0)
            _ = consume dumper  // detached
        } catch {
            panic("debuglog: no dumper thread")
        }
        ConsoleBuffer.dumperRunning = true
    }

    /// Wakes the dumper for the kernel console's buffer (Uart.write, from
    /// a context holding no spin lock).
    static func kick() {
        Scheduler.locked { _ = Scheduler.wakeAll(dumperQueue) }
    }

    /// A reader of the ring, in the kernel, from the oldest record still
    /// there.
    static func reader() -> NativeRing {
        unsafe NativeRing(attaching: UnsafeMutableRawPointer(bitPattern: UInt(base))!, size: size, producer: false,
                          slotSize: slotSize, format: format, flags: flags)!
    }

    /// Appends a record of `text` (truncated to CROI_LOG_RECORD_DATA_MAX
    /// bytes), from process `pid` / thread `tid` (0 for the kernel).
    static func write(severity: UInt8, flags: UInt8, _ text: Span<UInt8>, pid: UInt64, tid: UInt64) {
        let length = min(text.count, Int(CROI_LOG_RECORD_DATA_MAX))
        var record = InlineArray<256, UInt8>(repeating: 0)
        var header = croi_log_record_t()  // the ring sets the sequence
        header.datalen = UInt16(length)
        header.severity = severity
        header.flags = flags
        header.timestamp = Int64(bitPattern: Clock.now())
        header.pid = pid
        header.tid = tid
        do {
            var span = record.mutableSpan
            var bytes = span.mutableBytes
            unsafe bytes.storeBytes(of: header, toByteOffset: 0, as: croi_log_record_t.self)
            for i in 0..<length { bytes.storeBytes(of: text[i], toByteOffset: headerSize + i, as: UInt8.self) }
        }
        debugLogLock.withLock {
            record.span.withUnsafeBytes { unsafe writer!.write(from: $0.baseAddress!) }
            written.store(written.load(ordering: .relaxed) + 1, ordering: .releasing)
            // The doorbell: its value is the cursor, so a reader's VALUE
            // binding at its cursor plus one fires now.
            _ = try? Counters.add(counter, 1)
        }
        Scheduler.locked { _ = Scheduler.wakeAll(dumperQueue) }
    }

    /// The dumper thread: prints each record once, in order.
    private static let dump: Thread.Entry = { _ in
        var ring = reader()
        var record = InlineArray<256, UInt8>(repeating: 0)
        var line = InlineArray<320, UInt8>(repeating: 0)
        while true {
            Scheduler.locked {
                while (written.load(ordering: .acquiring) == ring.position && !ConsoleBuffer.pending)
                    || quiet.load(ordering: .acquiring)
                {
                    _ = Scheduler.block(on: dumperQueue, deadline: .max)
                }
            }
            // The kernel's own console output first, in its order.
            panicConsole?.drainBuffered()
            guard written.load(ordering: .acquiring) != ring.position else { continue }
            var dropped: UInt64 = 0
            var span = record.mutableSpan
            let got = span.withUnsafeMutableBytes { unsafe ring.read(to: $0.baseAddress!, dropped: &dropped) }
            let length = got ? record.span.withUnsafeBytes { format(UInt64(UInt(bitPattern: $0.baseAddress!)), into: &line) } : 0
            defer { printed.store(ring.position, ordering: .releasing) }
            guard let console = panicConsole else { continue }
            if dropped != 0 {
                console.write("[dlog: ")
                console.write(decimal: dropped)
                console.write(" records dropped]\n")
            }
            if got { console.writeLines(utf8: line.span.extracting(0..<length), patience: 50_000_000) }
        }
    }

    /// `[sssss.mmm] ppppp:ttttt> text\n`, as Zircon's dumper prints it.
    private static func format(_ at: UInt64, into line: inout InlineArray<320, UInt8>) -> Int {
        let record = unsafe UnsafePointer<croi_log_record_t>(bitPattern: UInt(at))!.pointee
        var n = 0
        func put(_ byte: UInt8) {
            line[n] = byte
            n += 1
        }
        func put(_ value: UInt64, width: Int) {
            var digits = InlineArray<20, UInt8>(repeating: UInt8(ascii: "0"))
            var v = value
            var count = 0
            repeat {
                digits[19 - count] = UInt8(ascii: "0") + UInt8(truncatingIfNeeded: v % 10)
                v /= 10
                count += 1
            } while v != 0
            for i in (20 - max(count, width))..<20 { put(digits[i]) }
        }
        let ms = UInt64(max(record.timestamp, 0)) / 1_000_000
        put(UInt8(ascii: "["))
        put(ms / 1000, width: 5)
        put(UInt8(ascii: "."))
        put(ms % 1000, width: 3)
        put(UInt8(ascii: "]"))
        put(UInt8(ascii: " "))
        put(record.pid, width: 5)
        put(UInt8(ascii: ":"))
        put(record.tid, width: 5)
        put(UInt8(ascii: ">"))
        put(UInt8(ascii: " "))
        let text = unsafe UnsafePointer<UInt8>(bitPattern: UInt(at) + UInt(headerSize))!
        var length = Int(record.datalen)
        while length > 0, unsafe text[length - 1] == UInt8(ascii: "\n") { length -= 1 }
        for i in 0..<length { put(unsafe text[i]) }
        put(UInt8(ascii: "\n"))
        return n
    }
}

let debugLogLock = SpinLock()

/// A debuglog handle's object (Zircon's LogDispatcher, type 12): it writes.
/// Reading is through the ring (D38).
struct LogObject: ~Copyable {
    var header = ObjectHeader(type: .log)

    static var rights: Rights { .basic | .write | .signal }
}

/// debuglog_create and debuglog_write (syscalls 110 and 111).
enum DebugLogs {
    static func create() throws(Status) -> (ObjectPointer, Rights) {
        guard let object = Objects.allocate(LogObject()) else { throw .noMemory }
        return (object, LogObject.rights)
    }

    static func destroy(_ object: ObjectPointer) {
        Objects.free(object, as: LogObject.self)
    }

    /// The calling thread's process and thread koids (0 for kernel threads).
    static func writerKoids() -> (pid: UInt64, tid: UInt64) {
        let thread = Scheduler.current.pointee.object
        guard thread != 0 else { return (0, 0) }
        let object = ThreadObjectPointer(object: ObjectPointer(address: thread))
        return (object.pointee.process.header.koid, object.object.header.koid)
    }

    static func call(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) -> Int64 {
        let handle = UInt32(truncatingIfNeeded: a[0])
        let options = UInt32(truncatingIfNeeded: a[1])
        switch number {
        case 110:  // debuglog_create(0, options 0, out)
            // No resource: every log only writes (Zircon lets a dynamic
            // linker log before it has one), and reading is the ring's.
            guard handle == 0, options == 0 else { throw .invalidArgs }
            try Syscalls.check(a[2], MemoryLayout<UInt32>.size)
            let (object, rights) = try create()
            try Syscalls.put(try table.add(object, rights: rights), a[2])
        case 111:  // debuglog_write(log, options, buffer, length)
            guard options & ~UInt32(CROI_LOG_FLAGS_MASK) == 0 else { throw .invalidArgs }
            _ = try table.get(handle, type: .log, rights: .write)
            let length = min(a[3], UInt64(CROI_LOG_RECORD_DATA_MAX))
            var buffer = InlineArray<216, UInt8>(repeating: 0)
            var span = buffer.mutableSpan
            let copied = span.withUnsafeMutableBytes { unsafe UserCopy.from($0.baseAddress!, a[2], length) }
            guard copied == 0 else { throw .invalidArgs }
            let (pid, tid) = writerKoids()
            DebugLog.write(severity: UInt8(CROI_LOG_INFO), flags: UInt8(truncatingIfNeeded: options),
                           buffer.span.extracting(0..<Int(length)), pid: pid, tid: tid)
        default:
            throw .notSupported
        }
        return 0
    }
}

/// Kernel debuglog records (pid and tid 0) built with TextOutput calls:
/// one line, up to 128 bytes (DMA's trust warnings, memory pressure).
enum KernelLog {
    static func write(_ severity: UInt8, _ body: (LineBuffer) -> Void) {
        guard let raw = unsafe heap.allocate(size: 136) else { return }
        let line = unsafe LineBuffer(raw)
        body(line)
        unsafe DebugLog.write(severity: severity, flags: 0,
                              Span(_unsafeStart: raw.assumingMemoryBound(to: UInt8.self) + 8,
                                   count: raw.load(as: Int.self)),
                              pid: 0, tid: 0)
        unsafe heap.free(raw)
    }
}

/// A 128-byte line in heap memory: a count word, then the bytes.
@safe struct LineBuffer: TextOutput {
    let raw: UnsafeMutableRawPointer

    @unsafe init(_ raw: UnsafeMutableRawPointer) {
        unsafe self.raw = raw
        unsafe raw.storeBytes(of: 0, as: Int.self)
    }

    func write(utf8: Span<UInt8>) {
        var count = unsafe raw.load(as: Int.self)
        for i in 0..<utf8.count where count < 128 {
            unsafe raw.storeBytes(of: utf8[i], toByteOffset: 8 + count, as: UInt8.self)
            count += 1
        }
        unsafe raw.storeBytes(of: count, as: Int.self)
    }
}
