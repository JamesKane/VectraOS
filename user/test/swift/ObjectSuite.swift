import CroiRuntime

/// Handles, signals through ports, user packets, names and the small
/// calls. Moved here from usertest.c's mode 0 and small_calls when V1 cut
/// events, object_signal, object_wait_one and object_wait_many (D23): a
/// counter is the signal source a user can drive, and a port is the one
/// wait.
enum ObjectSuite {
    static func run() {
        signals()
        handles()
        packets()
        names()
        closeMany()
        cancelKey()
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
        check(Sys.call(CROI_SYS_HANDLE_CLOSE, UInt64(narrowed)) == 0, "closed")
        check(Sys.call(CROI_SYS_HANDLE_CLOSE, UInt64(narrowed)) == Status.badHandle, "and gone")
        check(Sys.call(CROI_SYS_PORT_CREATE, 0, 0x10) == Status.invalidArgs, "a bad out pointer is an error")
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

    /// handle_close_many: 0 skipped, a bad value reported, the rest closed.
    static func closeMany() {
        var list = InlineArray<4, UInt32>(repeating: 0)
        check(Sys.call(CROI_SYS_COUNTER_CREATE, 0, Sys.address(&list[0])) == 0
                  && Sys.call(CROI_SYS_COUNTER_CREATE, 0, Sys.address(&list[3])) == 0, "two counters")
        list[2] = 0x7FFF_FFF0
        let (first, last) = (list[0], list[3])
        check(Sys.call(CROI_SYS_HANDLE_CLOSE_MANY, Sys.address(&list), 4) == Status.badHandle, "a bad value reported")
        check(Sys.call(CROI_SYS_HANDLE_CLOSE, UInt64(first)) == Status.badHandle
                  && Sys.call(CROI_SYS_HANDLE_CLOSE, UInt64(last)) == Status.badHandle, "the rest closed")
        check(Sys.call(CROI_SYS_HANDLE_CLOSE_MANY, Sys.address(&list), 2) == Status.badHandle, "a closed one is bad")
        list[0] = 0
        check(Sys.call(CROI_SYS_HANDLE_CLOSE_MANY, Sys.address(&list), 2) == 0, "zeros are skipped")
    }

    /// port_cancel_key: a binding and a queued user packet with key 5 go;
    /// key 6's stays.
    static func cancelKey() {
        let port = Port()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        check(port.bind(counter, UInt32(CROI_BIND_SIGNALS), key: 5, trigger: UInt64(positive)) == 0, "bound to key 5")
        var packet = croi_port_packet_t()
        packet.key = 5
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, Sys.address(&packet)) == 0, "a packet with key 5")
        packet.key = 6
        check(Sys.call(CROI_SYS_PORT_QUEUE, port.handle.arg, Sys.address(&packet)) == 0, "and one with key 6")
        check(Sys.call(CROI_SYS_PORT_CANCEL_KEY, port.handle.arg, 1, 5) == Status.invalidArgs, "an unknown option")
        check(Sys.call(CROI_SYS_PORT_CANCEL_KEY, port.handle.arg, 0, 5) == 0, "key 5 cancelled")
        check(Sys.call(CROI_SYS_PORT_CANCEL_KEY, port.handle.arg, 0, 5) == Status.notFound, "nothing left with key 5")
        check(add(counter, 1) == 0, "the counter signals")
        check(port.next()?.key == 6 && port.empty, "only key 6's packet is left")
    }
}
