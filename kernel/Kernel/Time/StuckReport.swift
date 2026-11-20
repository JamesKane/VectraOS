import CKernel
import Fmt

/// The stuck report (`croi.watchdog_limit=SECONDS`): when the limit
/// expires, the watchdog's refreshes have stopped and the machine is about
/// to reset, so each live thread's wait goes to the debuglog first, grouped
/// by process: its process and thread (koid and name), its state, and what
/// it is blocked on (the syscall it is in and the object its handle names,
/// a futex's address, a pager fault) and when its wait times out. The
/// debuglog's dumper copies the lines to the console as they are written.
///
/// It runs on a kernel thread of its own, in a context that may be wrong
/// in any way, so it never waits for a lock and never allocates: the
/// scheduler's lock is taken with a bounded wait, one thread at a time
/// (`Scheduler.inspect`) and never held while a line is made; a process's
/// lock and its handle table's are tried once (process -> handle table, the
/// documented order) and a handle that can't be read says "busy". Lines are
/// built in a buffer on its stack. It stops at the first scheduler lock it
/// can't take, and says so. If the dumper doesn't empty the debuglog while
/// it writes, the lines also go straight to the console.
enum StuckReport {
    /// Spawned once the debuglog runs, if the limit was given.
    static func start() {
        do throws(VmError) {
            let reporter = try Scheduler.spawn("stuck-report", entry, 0)
            _ = consume reporter  // detached
        } catch {
            panicConsole?.write("watchdog: no thread for the stuck report\n")
        }
    }

    private static let entry: Thread.Entry = { _ in
        Scheduler.sleep(until: Watchdog.limitDeadline)
        run()
        return 0
    }

    /// How many records the debuglog may hold unprinted before the report
    /// waits for the dumper.
    private static var backlog: UInt64 { 48 }

    nonisolated(unsafe) private static var direct = false

    /// Writes one line, at most 120 bytes: to the debuglog (pid and tid 0),
    /// after waiting a little for the dumper to catch up, and to the
    /// console too if it has stopped.
    private static func emit(_ body: (LineBuffer) -> Void) {
        var storage = InlineArray<17, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        span.withUnsafeMutableBytes { raw in
            let line = unsafe LineBuffer(raw.baseAddress!)
            line.write("stuck: ")
            body(line)
            let length = unsafe raw.baseAddress!.load(as: Int.self)
            let text = unsafe Span(_unsafeStart: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + 8,
                                   count: length)
            var waits = 0
            while !direct {
                let progress = DebugLog.progress
                if progress.written &- progress.printed <= backlog { break }
                waits += 1
                if waits > 400 {  // 2 s: the dumper isn't printing
                    direct = true
                    break
                }
                Scheduler.sleep(until: Clock.now() + 5_000_000)
            }
            DebugLog.write(severity: UInt8(CROI_LOG_WARNING), flags: 0, text, pid: 0, tid: 0)
            if direct, let console = panicConsole {
                console.writeLines(utf8: text, patience: 50_000_000)
                console.write("\n")
            }
        }
    }

    // MARK: The report

    static func run() {
        emit {
            $0.write("croi.watchdog_limit=")
            $0.write(decimal: Watchdog.limitSeconds)
            $0.write(" s reached; each thread's wait, by process")
        }
        var threads = 0
        var processes = 0
        var complete = true
        var lead = Scheduler.Inspected()
        var other = Scheduler.Inspected()
        var index = 0
        scan: while true {
            switch Scheduler.inspect(nth: index, into: &lead) {
            case .end:
                break scan
            case .busy:
                complete = false
                break scan
            case .thread:
                break
            }
            index += 1
            threads += 1
            guard lead.object != 0 else {
                lead.release()
                continue
            }
            let process = ThreadObjectPointer(object: ObjectPointer(address: lead.object)).pointee.process
            // Its process's first thread in the list leads it.
            var first = true
            var j = 0
            while j < index - 1 {
                switch Scheduler.inspect(nth: j, into: &other) {
                case .thread:
                    if other.object != 0, ThreadObjectPointer(object: ObjectPointer(address: other.object)).pointee.process == process {
                        first = false
                    }
                    other.release()
                case .busy, .end:
                    break
                }
                if !first { break }
                j += 1
            }
            guard first else {
                lead.release()
                continue
            }
            processes += 1
            describe(process: process)
            // Every thread of it, the leader included.
            var k = 0
            while true {
                let result = k == index - 1 ? Scheduler.Inspected.Found.thread : Scheduler.inspect(nth: k, into: &other)
                if result != .thread {
                    if result == .busy { complete = false }
                    break
                }
                if k == index - 1 {
                    describe(thread: lead)
                } else {
                    if other.object != 0, ThreadObjectPointer(object: ObjectPointer(address: other.object)).pointee.process == process {
                        describe(thread: other)
                    }
                    other.release()
                }
                k += 1
            }
            lead.release()
        }
        lead.release()
        if complete {
            // The kernel's own threads.
            var heading = false
            var n = 0
            while true {
                let result = Scheduler.inspect(nth: n, into: &other)
                if result != .thread {
                    if result == .busy { complete = false }
                    break
                }
                n += 1
                if other.object == 0 {
                    if !heading {
                        heading = true
                        emit { $0.write("kernel threads") }
                    }
                    describe(thread: other)
                }
                other.release()
            }
        }
        if !complete { emit { $0.write("the scheduler's lock is busy; the report is cut short") } }
        let counted = threads
        let processed = processes
        emit {
            $0.write("end: ")
            $0.write(decimal: UInt64(counted))
            $0.write(" threads, ")
            $0.write(decimal: UInt64(processed))
            $0.write(" processes")
        }
    }

    private static func describe(process: ObjectPointer) {
        let record = ProcessPointer(object: process)
        let name = record.pointee.name
        let job = JobPointer(object: record.pointee.job).pointee.name
        emit {
            $0.write("process ")
            $0.write(decimal: process.header.koid)
            quote(name, to: $0)
            if job[0] != 0 {
                $0.write(", job")
                quote(job, to: $0)
            }
        }
    }

    private static func quote(_ name: ObjectName, to line: LineBuffer) {
        line.write(" \"")
        for i in 0..<(Names.maxLength - 1) {
            guard name[i] != 0 else { break }
            var byte = name[i]
            if byte < 0x20 || byte > 0x7E { byte = UInt8(ascii: "?") }
            let one = InlineArray<1, UInt8>(repeating: byte)
            line.write(utf8: one.span)
        }
        line.write("\"")
    }

    private static func describe(thread found: Scheduler.Inspected) {
        emit { line in
            if found.object != 0 {
                let thread = ThreadObjectPointer(object: ObjectPointer(address: found.object))
                line.write("  thread ")
                line.write(decimal: thread.object.header.koid)
                quote(thread.pointee.name, to: line)
            } else {
                line.write("  ")
                line.write(found.name)
            }
            switch found.state {
            case .running:
                line.write(": running on cpu ")
                line.write(decimal: UInt64(found.cpu))
            case .ready:
                line.write(": ready, cpu ")
                line.write(decimal: UInt64(found.cpu))
            case .dead:
                line.write(": dead")
            case .blocked:
                line.write(": blocked")
                what(found, line)
                timeout(found, line)
            }
        }
    }

    /// What a blocked thread waits on.
    private static func what(_ found: Scheduler.Inspected, _ line: LineBuffer) {
        guard found.object != 0 else { return }
        guard found.inUser else {
            line.write(" in the kernel")
            return
        }
        guard found.inSyscall else {
            line.write(" in a page fault, for a pager")
            return
        }
        let handle = UInt32(truncatingIfNeeded: found.argument0)
        switch found.syscall {
        case 33:
            line.write(" in port_wait on ")
            target(found, handle, line)
        case 83:
            line.write(" in channel_call on ")
            target(found, handle, line)
        case 90:
            line.write(" in futex_wait at ")
            line.write(hex: found.argument0)
        case 45, 76, 104, 152, 230, 231, 233:
            line.write(" in syscall ")
            line.write(decimal: found.syscall)
            line.write(", on pager-backed memory")
        default:
            line.write(" in syscall ")
            line.write(decimal: found.syscall)
            line.write(", handle ")
            line.write(hex: found.argument0)
        }
    }

    /// The object a handle of the thread's process names: its type and
    /// koid, "busy" if a lock needed for it isn't free.
    private static func target(_ found: Scheduler.Inspected, _ handle: UInt32, _ line: LineBuffer) {
        let process = ThreadObjectPointer(object: ObjectPointer(address: found.object)).pointee.process
        guard let saved = process.header.lock.tryAcquire() else {
            line.write("a handle (busy)")
            return
        }
        var peek = HandleTable.Peek.closed
        if ProcessPointer(object: process).pointee.handles?.address == found.handleTable {
            peek = HandleTable.peek(address: found.handleTable, handle)
        }
        process.header.lock.release(saved)
        switch peek {
        case .found(let type, let koid):
            line.write(typeName(type))
            line.write(" ")
            line.write(decimal: koid)
        case .closed:
            line.write("a closed handle")
        case .busy:
            line.write("a handle (busy)")
        }
        line.write(" (handle ")
        line.write(hex: UInt64(handle))
        line.write(")")
    }

    private static func typeName(_ type: ObjectType) -> StaticString {
        switch type {
        case .process: "process"
        case .thread: "thread"
        case .vmo: "vmo"
        case .channel: "channel"
        case .port: "port"
        case .interrupt: "interrupt"
        case .log: "log"
        case .resource: "resource"
        case .pager: "pager"
        case .suspendToken: "suspend token"
        case .job: "job"
        case .vmar: "vmar"
        case .iommu: "iommu"
        case .bti: "bti"
        case .pmt: "pmt"
        case .profile: "profile"
        case .exception: "exception"
        case .msi: "msi"
        case .counter: "counter"
        case .memoryAccount: "memory account"
        case .msiFrame: "msi frame"
        case .supply: "supply"
        case .none: "object"
        }
    }

    private static func timeout(_ found: Scheduler.Inspected, _ line: LineBuffer) {
        let now = Clock.now()
        if found.deadline == 0 {
            line.write(", no timeout")
        } else if found.deadline <= now {
            line.write(", timeout due")
        } else {
            line.write(", times out in ")
            line.write(decimal: (found.deadline - now) / 1_000_000)
            line.write(" ms")
        }
    }
}
