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
        Sys.call(CROI_SYS_COUNTER_ADD, counter.arg, UInt64(bitPattern: amount))
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
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, counter.arg, UInt64(wait | transfer), Sys.address(&narrowed)) == 0,
              "a duplicate with WAIT and TRANSFER")
        check(Sys.call(CROI_SYS_COUNTER_ADD, UInt64(narrowed), 1) == Status.accessDenied, "can't add (no WRITE)")
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
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, counter.arg, UInt64(wait | transfer), Sys.address(&undupable)) == 0,
              "a handle without DUPLICATE")
        var replaced: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, UInt64(undupable), UInt64(wait), Sys.address(&replaced), consumeOption)
                  == 0 && replaced != undupable, "replaced with fewer rights")
        check(croi_handle_close(undupable) == Status.badHandle, "the old handle is gone")
        var refused: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, UInt64(replaced), UInt64(wait | transfer), Sys.address(&refused),
                       consumeOption) == Status.invalidArgs && croi_handle_close(replaced) == Status.badHandle,
              "more rights refused, and consumed all the same")
        var other: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, counter.arg, UInt64(wait), Sys.address(&other), 2) == Status.invalidArgs,
              "an unknown option")
    }

    /// port_queue's packets come back as queued.
    static func packets() {
        let port = Port()
        var packet = croi_port_packet_t()
        packet.key = 42
        packet.payload = (1, 2, 3, 4)
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, Sys.address(&packet)) == 0, "a user packet queued")
        guard let got = port.next(deadline: Sys.now() + 1_000_000_000) else { return check(false, "and read") }
        check(got.key == 42 && got.type == UInt32(CROI_PKT_TYPE_USER) && got.payload.3 == 4, "as it was queued")
    }

    /// Names: set and read back (truncated to 31), a short buffer, a handle
    /// without SET_PROPERTY, a thread's name from thread_create.
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
        let unnamable = Handle(duplicating: vmo, rights: (1 << 0) | (1 << 2) | (1 << 14) | (1 << 15))
        check(setName(unnamable.arg, "x") == Status.accessDenied, "not without SET_PROPERTY")
        var thread: UInt32 = 0
        let worker: StaticString = "worker"
        check(unsafe Sys.call(CROI_SYS_THREAD_CREATE, UInt64(croi_process_self()),
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
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, Sys.address(&packet)) == 0, "a packet with key 5")
        packet.key = 6
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, Sys.address(&packet)) == 0, "and one with key 6")
        check(Sys.call(CROI_SYS_PORT_CANCEL, port.handle.arg, 0, 5) == 0, "key 5 cancelled")
        check(Sys.call(CROI_SYS_PORT_CANCEL, port.handle.arg, 0, 5) == Status.notFound, "nothing left with key 5")
        check(add(counter, 1) == 0, "the counter signals")
        check(port.next()?.key == 6 && port.empty, "only key 6's packet is left")
    }

    /// Job debuggers: each sees a new process's PROCESS_STARTING in turn
    /// (its initial thread waits in the exception), and a closed one no
    /// longer counts as attached; the next start prunes it.
    static func jobDebuggers() {
        let root = Handle(adopting: croi_take_startup_handle(croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0)))
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
        var actual: (UInt32, UInt32) = (0, 0)
        guard Sys.call(CROI_SYS_CHANNEL_READ, channel.arg, 0, Sys.address(&info), Sys.address(&handle),
                       UInt64(MemoryLayout<croi_exception_info_t>.size) | 1 << 32, Sys.address(&actual)) == 0,
              actual.1 == 1 else { return nil }
        return Handle(adopting: handle)
    }
}
