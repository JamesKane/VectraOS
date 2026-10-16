import CroiRuntime

/// Handles, signals through ports, user packets, names and the small
/// calls. Moved here from usertest.c's mode 0 and small_calls when V1 cut
/// events, object_signal, object_wait_one and object_wait_many (D23): a
/// counter is the signal source a user can drive, and a port is the one
/// wait. Job debuggers came from mode 17's user_exceptions when V1 cut
/// thread_raise_exception (D30).
enum ObjectSuite {
    static func run() {
        signals()
        handles()
        packets()
        packetBatches()
        names()
        closeMany()
        cancelKey()
        jobDebuggers()
        print("swift: objects passed")
    }

    static var positive: UInt32 { UInt32(CROI_COUNTER_POSITIVE) }
    static var nonPositive: UInt32 { UInt32(CROI_COUNTER_NON_POSITIVE) }
    static var transfer: UInt32 { 1 << 1 }
    static var wait: UInt32 { 1 << 14 }

    static func add(_ counter: borrowing Handle, _ amount: Int64) -> Int64 {
        croi_counter_add(counter.raw, amount)
    }

    /// A counter's signals reach a port: not before they are asserted, then
    /// in one SIGNAL packet with the trigger and what was observed.
    static func signals() {
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        check(Port.signals(of: counter, nonPositive) & nonPositive != 0, "a new counter is NON_POSITIVE")
        let port = Port()
        check(port.bind(counter, UInt32(CROI_BIND_SIGNALS), key: 7, trigger: UInt64(positive)) == 0, "bound")
        check(port.next(deadline: Sys.now() + 1_000_000) == nil, "nothing before the signal")
        check(add(counter, 1) == 0, "counter_add")
        guard let packet = port.next(deadline: Sys.now() + 1_000_000_000) else {
            return check(false, "the signal arrives")
        }
        check(packet.key == 7 && packet.type == UInt32(CROI_PKT_TYPE_SIGNAL)
                  && UInt32(truncatingIfNeeded: packet.payload.0) == positive
                  && UInt32(truncatingIfNeeded: packet.payload.0 >> 32) & positive != 0,
              "a SIGNAL packet: the trigger and what was observed")
        check(port.empty, "once")
    }

    /// A duplicate with fewer rights can't do what they don't allow; a
    /// closed handle is gone.
    static func handles() {
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        var narrowed: UInt32 = 0
        check(Sys.duplicate(counter.arg, UInt64(wait | transfer), &narrowed) == 0,
              "a duplicate with WAIT and TRANSFER")
        check(croi_counter_add(narrowed, 1) == Status.accessDenied, "can't add (no WRITE)")
        check(croi_handle_close(narrowed) == 0, "closed")
        check(croi_handle_close(narrowed) == Status.badHandle, "and gone")
        check(Sys.call(CROI_SYS_PORT_CREATE, 0, 0x10) == Status.invalidArgs, "a bad out pointer is an error")
        consume()
    }

    /// handle_duplicate with CONSUME (handle_replace until D34): the old
    /// handle goes, even when the rights asked for are refused, and
    /// DUPLICATE isn't needed.
    static func consume() {
        let consumeOption = UInt64(CROI_HANDLE_DUPLICATE_CONSUME)
        var undupable: UInt32 = 0
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        check(Sys.duplicate(counter.arg, UInt64(wait | transfer), &undupable) == 0,
              "a handle without DUPLICATE")
        var replaced: UInt32 = 0
        check(Sys.duplicate(UInt64(undupable), UInt64(wait), &replaced, consumeOption)
                  == 0 && replaced != undupable, "replaced with fewer rights")
        check(croi_handle_close(undupable) == Status.badHandle, "the old handle is gone")
        var refused: UInt32 = 0
        check(Sys.duplicate(UInt64(replaced), UInt64(wait | transfer), &refused,
                            consumeOption) == Status.invalidArgs && croi_handle_close(replaced) == Status.badHandle,
              "more rights refused, and consumed all the same")
        var other: UInt32 = 0
        check(Sys.duplicate(counter.arg, UInt64(wait), &other, 2) == Status.invalidArgs,
              "an unknown option")
        duplicateMany()
    }

    /// handle_duplicate takes an array (D39), as object_bind does: in order,
    /// stopping at the first failure, each processed item's status written
    /// back, the count of successes returned; a bad count fails the call.
    static func duplicateMany() {
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        let item = { (handle: UInt32, rights: UInt32, options: UInt32) in
            croi_handle_duplicate_item_t(handle: handle, rights: rights, options: options, out: 0, status: 7,
                                         reserved: 0)
        }
        var items = [item(counter.raw, wait, 0), item(counter.raw, wait | transfer, 0),
                     item(counter.raw, wait, 0), item(0x12340003, wait, 0), item(counter.raw, wait, 0)]
        let done = items.withUnsafeMutableBufferPointer { buffer in
            unsafe Sys.call(CROI_SYS_HANDLE_DUPLICATE, UInt64(UInt(bitPattern: buffer.baseAddress)), 5)
        }
        check(done == 3 && items[0].status == 0 && items[1].status == 0 && items[2].status == 0,
              "three duplicated")
        check(items[0].out != 0 && items[1].out != 0 && items[2].out != 0 && items[0].out != items[1].out,
              "each with a new handle")
        check(Int64(items[3].status) == Status.badHandle && items[3].out == 0, "the fourth refused, with its status")
        check(items[4].status == 7, "the fifth not processed")
        var info = croi_info_handle_basic_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, UInt64(items[1].out), UInt64(CROI_INFO_HANDLE_BASIC), Sys.address(&info),
                       UInt64(MemoryLayout<croi_info_handle_basic_t>.size)) == 0 && info.rights == wait | transfer,
              "each copy has the rights asked for")
        var closing = [items[0].out, items[1].out, items[2].out]
        let closed = closing.withUnsafeMutableBufferPointer { buffer in
            unsafe Sys.call(CROI_SYS_HANDLE_CLOSE, UInt64(UInt(bitPattern: buffer.baseAddress)), 3)
        }
        check(closed == 0, "and each a handle of its own")
        var reserved = [croi_handle_duplicate_item_t(handle: counter.raw, rights: wait, options: 0, out: 0, status: 0,
                                                     reserved: 1)]
        let refusedReserved = reserved.withUnsafeMutableBufferPointer { buffer in
            unsafe Sys.call(CROI_SYS_HANDLE_DUPLICATE, UInt64(UInt(bitPattern: buffer.baseAddress)), 1)
        }
        check(refusedReserved == 0 && Int64(reserved[0].status) == Status.invalidArgs, "a reserved field set")
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, 0, 0) == Status.invalidArgs
                  && Sys.call(CROI_SYS_HANDLE_DUPLICATE, UInt64(UInt(bitPattern: 0x1000)),
                              UInt64(CROI_HANDLE_DUPLICATE_MAX_ITEMS) + 1) == Status.invalidArgs,
              "no items, or too many")
    }

    /// port_queue's packets come back as queued.
    static func packets() {
        let port = Port()
        var packet = croi_port_packet_t()
        packet.key = 42
        packet.payload = (1, 2, 3, 4)
        check(unsafe croi_port_queue(port.handle.raw, &packet) == 0, "a user packet queued")
        guard let got = port.next(deadline: Sys.now() + 1_000_000_000) else { return check(false, "and read") }
        check(got.key == 42 && got.type == UInt32(CROI_PKT_TYPE_USER) && got.payload.3 == 4, "as it was queued")
    }

    /// Names: set and read back (truncated to 31), a short buffer, a handle
    /// without SET_PROPERTY, a thread's name from thread_create.
    /// port_queue and port_wait take arrays (D40): a wait takes what is
    /// queued, in order, up to its count, and waits only while none is.
    static func packetBatches() {
        let port = Port()
        var packets = InlineArray<3, croi_port_packet_t>(repeating: croi_port_packet_t())
        for i in 0..<3 { packets[i].key = UInt64(i + 1) }
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, Sys.address(&packets), 3) == 3, "three packets in one call")
        var out = InlineArray<4, croi_port_packet_t>(repeating: croi_port_packet_t())
        check(Sys.call(CROI_SYS_PORT_WAIT, port.handle.arg, 0, Sys.address(&out), 2) == 2
                  && out[0].key == 1 && out[1].key == 2, "a wait takes two, in order")
        check(Sys.call(CROI_SYS_PORT_WAIT, port.handle.arg, Sys.now() + 1_000_000_000, Sys.address(&out), 4) == 1
                  && out[0].key == 3, "then the one left, without waiting for more")
        check(Sys.call(CROI_SYS_PORT_WAIT, port.handle.arg, 0, Sys.address(&out), 4) == Status.timedOut, "then none")
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, Sys.address(&packets), 0) == Status.invalidArgs
                  && Sys.call(CROI_SYS_PORT_WAIT, port.handle.arg, 0, Sys.address(&out), 65) == Status.invalidArgs,
              "a count of 0 or over 64 is refused")
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, 8, 1) == Status.invalidArgs && port.empty,
              "an unreadable packet is not queued")
    }

    static func names() {
        let vmo = Handle(vmo: pageSize)
        var name = InlineArray<32, UInt8>(repeating: 0xFF)
        func setName(_ handle: UInt64, _ text: StaticString, _ length: Int? = nil) -> Int64 {
            unsafe Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, handle, UInt64(CROI_PROP_NAME),
                            UInt64(UInt(bitPattern: text.utf8Start)), UInt64(length ?? text.utf8CodeUnitCount))
        }
        func getName(_ handle: UInt64, _ capacity: UInt64 = 32) -> Int64 {
            Sys.call(CROI_SYS_OBJECT_GET_PROPERTY, handle, UInt64(CROI_PROP_NAME), Sys.address(&name), capacity)
        }
        check(setName(vmo.arg, "buffer\0junk", 11) == 0, "a name set")
        check(getName(vmo.arg, 31) == Status.bufferTooSmall, "a short buffer")
        check(getName(vmo.arg) == 0 && name[0] == UInt8(ascii: "b") && name[5] == UInt8(ascii: "r") && name[6] == 0
                  && name[7] == 0, "read back to its NUL, zero filled")
        check(setName(vmo.arg, "0123456789abcdefghijklmnopqrstuvwxyz") == 0 && getName(vmo.arg) == 0
                  && name[30] == UInt8(ascii: "u") && name[31] == 0, "truncated to 31")
        let unnamable = Handle(duplicating: vmo, rights: CROI_RIGHT_DUPLICATE | CROI_RIGHT_READ | CROI_RIGHT_WAIT | CROI_RIGHT_INSPECT)
        check(setName(unnamable.arg, "x") == Status.accessDenied, "not without SET_PROPERTY")
        var thread: UInt32 = 0
        let worker: StaticString = "worker"
        check(unsafe Sys.call(CROI_SYS_THREAD_CREATE, UInt64(td_runtime_process_self),
                              UInt64(UInt(bitPattern: worker.utf8Start)), 6, 0, Sys.address(&thread)) == 0,
              "a thread")
        let named = Handle(adopting: thread)
        check(getName(named.arg) == 0 && name[0] == UInt8(ascii: "w") && name[5] == UInt8(ascii: "r") && name[6] == 0,
              "named by thread_create")
    }

    /// handle_close takes an array (handle_close_many until D33): 0
    /// skipped, a bad value reported, the rest closed.
    static func closeMany() {
        var list = InlineArray<4, UInt32>(repeating: 0)
        check(Sys.call(CROI_SYS_COUNTER_CREATE, 0, Sys.address(&list[0])) == 0
                  && Sys.call(CROI_SYS_COUNTER_CREATE, 0, Sys.address(&list[3])) == 0, "two counters")
        list[2] = 0x7FFF_FFF0
        let (first, last) = (list[0], list[3])
        check(Sys.call(CROI_SYS_HANDLE_CLOSE, Sys.address(&list), 4) == Status.badHandle, "a bad value reported")
        check(croi_handle_close(first) == Status.badHandle
                  && croi_handle_close(last) == Status.badHandle, "the rest closed")
        check(Sys.call(CROI_SYS_HANDLE_CLOSE, Sys.address(&list), 2) == Status.badHandle, "a closed one is bad")
        list[0] = 0
        check(Sys.call(CROI_SYS_HANDLE_CLOSE, Sys.address(&list), 2) == 0, "zeros are skipped")
    }

    /// port_cancel with source 0 (port_cancel_key until D32): a binding
    /// and a queued user packet with key 5 go; key 6's stays.
    static func cancelKey() {
        let port = Port()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        check(port.bind(counter, UInt32(CROI_BIND_SIGNALS), key: 5, trigger: UInt64(positive)) == 0, "bound to key 5")
        var packet = croi_port_packet_t()
        packet.key = 5
        check(unsafe croi_port_queue(port.handle.raw, &packet) == 0, "a packet with key 5")
        packet.key = 6
        check(unsafe croi_port_queue(port.handle.raw, &packet) == 0, "and one with key 6")
        check(Sys.call(CROI_SYS_PORT_CANCEL, port.handle.arg, 0, 5) == 0, "key 5 cancelled")
        check(Sys.call(CROI_SYS_PORT_CANCEL, port.handle.arg, 0, 5) == Status.notFound, "nothing left with key 5")
        check(add(counter, 1) == 0, "the counter signals")
        check(port.next()?.key == 6 && port.empty, "only key 6's packet is left")
    }

    /// Job debuggers: each sees a new process's PROCESS_STARTING in turn
    /// (its initial thread waits in the exception), and a closed one no
    /// longer counts as attached; the next start prunes it.
    static func jobDebuggers() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0)))
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_JOB_CREATE, root.arg, 0, Sys.address(&raw)) == 0, "a job")
        let job = Handle(adopting: raw)
        var first: UInt32 = 0, second: UInt32 = 0
        check(Sys.call(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, job.arg, UInt64(CROI_EXCEPTION_CHANNEL_DEBUGGER),
                       Sys.address(&first)) == 0
                  && Sys.call(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, job.arg, UInt64(CROI_EXCEPTION_CHANNEL_DEBUGGER),
                              Sys.address(&second)) == 0, "two job debuggers")
        let a = Handle(adopting: first)
        let b = Handle(adopting: second)
        check(attached(job), "the job has a debugger attached")
        let debuggee = start(in: job)
        var info = croi_exception_info_t()
        let firstSeen = exception(on: a, &info)
        check(firstSeen != nil && info.type == UInt32(CROI_EXCP_PROCESS_STARTING) && info.tid == koid(debuggee.thread),
              "the first debugger sees the process start")
        _ = consume firstSeen
        let secondSeen = exception(on: b, &info)
        check(secondSeen != nil && info.type == UInt32(CROI_EXCP_PROCESS_STARTING), "then the second")
        check(Sys.call(CROI_SYS_TASK_KILL, debuggee.process.arg) == 0, "killed waiting in the exception")
        _ = consume secondSeen
        check(Port.signals(of: debuggee.process, UInt32(CROI_SIGNAL_TASK_TERMINATED), deadline: Sys.now() + 3_000_000_000)
                  & UInt32(CROI_SIGNAL_TASK_TERMINATED) != 0, "and ends")
        _ = consume a
        _ = consume b
        check(!attached(job), "closed, they no longer count")
        let again = start(in: job)
        check(Sys.call(CROI_SYS_TASK_KILL, again.process.arg) == 0, "the next start prunes them, and nothing waits")
    }

    static func attached(_ job: borrowing Handle) -> Bool {
        var info = croi_info_job_t()
        var counts: (UInt64, UInt64) = (0, 0)
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, job.arg, UInt64(CROI_INFO_JOB), Sys.address(&info),
                       UInt64(MemoryLayout<croi_info_job_t>.size), Sys.address(&counts.0), Sys.address(&counts.1)) == 0,
              "job info")
        return info.debugger_attached != 0
    }

    static func koid(_ handle: borrowing Handle) -> UInt64 {
        var info = croi_info_handle_basic_t()
        var counts: (UInt64, UInt64) = (0, 0)
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, handle.arg, UInt64(CROI_INFO_HANDLE_BASIC), Sys.address(&info),
                       UInt64(MemoryLayout<croi_info_handle_basic_t>.size), Sys.address(&counts.0),
                       Sys.address(&counts.1)) == 0, "handle info")
        return info.koid
    }

    /// A process in `job` with its initial thread started; it never reaches
    /// user mode while a debugger holds its PROCESS_STARTING.
    struct Debuggee: ~Copyable {
        let process: Handle
        let thread: Handle
    }

    static func start(in job: borrowing Handle) -> Debuggee {
        let name: StaticString = "debuggee"
        var process: UInt32 = 0, vmar: UInt32 = 0, thread: UInt32 = 0
        check(unsafe Sys.call(CROI_SYS_PROCESS_CREATE, job.arg, UInt64(UInt(bitPattern: name.utf8Start)), 8, 0,
                              Sys.address(&process), Sys.address(&vmar)) == 0, "a process")
        _ = Handle(adopting: vmar)
        check(unsafe Sys.call(CROI_SYS_THREAD_CREATE, UInt64(process), UInt64(UInt(bitPattern: name.utf8Start)), 8, 0,
                              Sys.address(&thread)) == 0, "its thread")
        check(Sys.call(CROI_SYS_PROCESS_START, UInt64(process), UInt64(thread), 0x1000, 0) == 0, "started")
        return Debuggee(process: Handle(adopting: process), thread: Handle(adopting: thread))
    }

    /// The next exception on a debugger channel, its handle owned.
    static func exception(on channel: borrowing Handle, _ info: inout croi_exception_info_t) -> Handle? {
        let readable = UInt32(CROI_SIGNAL_READABLE)
        guard Port.signals(of: channel, readable, deadline: Sys.now() + 3_000_000_000) & readable != 0 else {
            return nil
        }
        var handle: UInt32 = 0
        var actual: UInt64 = 0
        guard Sys.readChannel(channel.arg, 0, bytes: Sys.address(&info), handles: Sys.address(&handle),
                              capacity: UInt64(MemoryLayout<croi_exception_info_t>.size) | 1 << 32, &actual) == 0,
              actual >> 32 == 1 else { return nil }
        return Handle(adopting: handle)
    }
}
