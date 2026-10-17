import CroiRuntime

/// The suites' harness. The kernel boots this program with
/// `swift.suite=<name>` in its environment (ProgramSelfTest.runSuites);
/// each suite is a file of its own, and each check has a name, so a
/// failure says what broke instead of a number. New syscall tests go here,
/// not into user/test/usertest.c, which shrinks as the calls it tests are
/// cut or move.
enum Suite {
    static var prefix: StaticString { "swift.suite=" }

    /// Whether an environment entry is `swift.suite=` followed by `name`
    /// (any name if nil).
    static func requested(_ name: StaticString? = nil) -> Bool {
        var index = 0
        while let entry = unsafe environ[index] {
            index += 1
            let length = unsafe strlen(entry)
            guard unsafe starts(entry, length, prefix, at: 0) else { continue }
            guard let name else { return true }
            if unsafe length == prefix.utf8CodeUnitCount + name.utf8CodeUnitCount
                && starts(entry, length, name, at: prefix.utf8CodeUnitCount) { return true }
        }
        return false
    }

    @unsafe private static func starts(_ entry: UnsafePointer<CChar>, _ length: Int, _ text: StaticString,
                                       at offset: Int) -> Bool {
        guard length >= offset + text.utf8CodeUnitCount else { return false }
        for j in 0..<text.utf8CodeUnitCount where unsafe UInt8(bitPattern: entry[offset + j]) != text.utf8Start[j] {
            return false
        }
        return true
    }

    /// Runs the requested suite and exits: 0x600D if every check passed, 1
    /// at the first that didn't, 2 for a suite nobody knows.
    static func run() -> Never {
        if requested("bind") {
            BindSuite.run()
        } else if requested("vmo") {
            VmoSuite.run()
        } else if requested("futex") {
            FutexSuite.run()
        } else if requested("channel") {
            ChannelSuite.run()
        } else if requested("objects") {
            ObjectSuite.run()
        } else if requested("counters") {
            CounterSuite.run()
        } else if requested("time") {
            TimeSuite.run()
        } else if requested("memory") {
            MemorySuite.run()
        } else if requested("ring") {
            RingSuite.run()
        } else if requested("debuglog") {
            DebuglogSuite.run()
        } else if requested("portring") {
            PortRingSuite.run()
        } else if requested("floor") {
            FloorSuite.run()
        } else if requested("libc") {
            LibcSuite.run()
        } else if requested("idle") {
            IdleSuite.run()
        } else if requested("dma") {
            DmaSuite.run()
        } else if requested("interrupts") {
            InterruptSuite.run()  // run on its own (ProcessSelfTest.runInterrupts)
        } else {
            print("swift: no such suite")
            td_exit(2)
        }
        td_exit(0x600D)
    }
}

/// One check: on failure, says which and ends the run.
func check(_ condition: Bool, _ name: StaticString) {
    guard condition else {
        print("swift: FAILED: ", terminator: "")
        print(name)
        td_exit(1)
    }
}

/// Status codes the suites expect (object.h, D45).
enum Status {
    static var notSupported: Int64 { CROI_ERR_NOT_SUPPORTED }
    static var noResources: Int64 { CROI_ERR_NO_RESOURCES }
    static var invalidArgs: Int64 { CROI_ERR_INVALID_ARGS }
    static var badHandle: Int64 { CROI_ERR_BAD_HANDLE }
    static var wrongType: Int64 { CROI_ERR_WRONG_TYPE }
    static var outOfRange: Int64 { CROI_ERR_OUT_OF_RANGE }
    static var bufferTooSmall: Int64 { CROI_ERR_BUFFER_TOO_SMALL }
    static var badState: Int64 { CROI_ERR_BAD_STATE }
    static var timedOut: Int64 { CROI_ERR_TIMED_OUT }
    static var shouldWait: Int64 { CROI_ERR_SHOULD_WAIT }
    static var peerClosed: Int64 { CROI_ERR_PEER_CLOSED }
    static var notFound: Int64 { CROI_ERR_NOT_FOUND }
    static var alreadyBound: Int64 { CROI_ERR_ALREADY_BOUND }
    static var accessDenied: Int64 { CROI_ERR_ACCESS_DENIED }
}

/// The page size on every target.
var pageSize: UInt64 { 4096 }

/// Calls on the kernel, raw.
enum Sys {
    static func call(_ number: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0,
                     _ a4: UInt64 = 0, _ a5: UInt64 = 0) -> Int64 {
        croi_syscall6(number, a0, a1, a2, a3, a4, a5)
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        unsafe withUnsafeMutablePointer(to: &value) { unsafe UInt64(UInt(bitPattern: $0)) }
    }

    /// One handle_duplicate item (D39): 0, or the item's or call's status.
    static func duplicate(_ handle: UInt64, _ rights: UInt64, _ out: inout UInt32, _ options: UInt64 = 0) -> Int64 {
        unsafe croi_handle_duplicate(UInt32(truncatingIfNeeded: handle), UInt32(truncatingIfNeeded: rights), &out,
                                     UInt32(truncatingIfNeeded: options))
    }

    /// One channel_read item (D41): 0, or the item's or call's status. The
    /// capacities and the message's size in `actual` are packed (bytes |
    /// handles << 32).
    static func readChannel(_ channel: UInt64, _ options: UInt64, bytes: UInt64, handles: UInt64, capacity: UInt64,
                            _ actual: inout UInt64) -> Int64 {
        var item = croi_channel_read_item_t(channel: UInt32(truncatingIfNeeded: channel),
                                            options: UInt32(truncatingIfNeeded: options), bytes: bytes,
                                            handles: handles, num_bytes: UInt32(truncatingIfNeeded: capacity),
                                            num_handles: UInt32(truncatingIfNeeded: capacity >> 32),
                                            actual_bytes: 0, actual_handles: 0, status: 1, reserved: 0)
        let done = call(CROI_SYS_CHANNEL_READ, address(&item), 1)
        actual = UInt64(item.actual_bytes) | UInt64(item.actual_handles) << 32
        return done < 0 ? done : Int64(item.status)
    }

    /// One channel_write item (D41): 0, or the item's or call's status.
    static func writeChannel(_ channel: UInt64, bytes: UInt64, count: UInt64, handles: UInt64,
                             handleCount: UInt64) -> Int64 {
        var item = croi_channel_write_item_t(channel: UInt32(truncatingIfNeeded: channel), options: 0, bytes: bytes,
                                             handles: handles, num_bytes: UInt32(truncatingIfNeeded: count),
                                             num_handles: UInt32(truncatingIfNeeded: handleCount), status: 1,
                                             reserved: 0)
        let done = call(CROI_SYS_CHANNEL_WRITE, address(&item), 1)
        return done < 0 ? done : Int64(item.status)
    }

    static func now() -> UInt64 { UInt64(td_monotonic()) }

    /// Sleeps `nanoseconds`: a port_wait on an empty port (principle 10).
    /// Not the floor's td_sleep: the suites' threads are raw ones, with no
    /// floor block for a port.
    static func sleep(_ nanoseconds: UInt64) {
        let port = Port()
        _ = port.next(deadline: now() + nanoseconds)
    }
}

/// A handle the suite owns: closed when it goes.
struct Handle: ~Copyable {
    let raw: UInt32

    /// A new object from a `create(options, out)` call (ports, counters).
    init(creating number: UInt64, options: UInt64 = 0) {
        var out: UInt32 = 0
        check(Sys.call(number, options, Sys.address(&out)) == 0, "creating an object")
        raw = out
    }

    /// A handle a call made.
    init(adopting raw: UInt32) { self.raw = raw }

    /// A new VMO.
    init(vmo size: UInt64, options: UInt64 = 0) {
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE, size, options, Sys.address(&out)) == 0, "creating a VMO")
        raw = out
    }

    init(duplicating other: borrowing Handle, rights: UInt32 = CROI_RIGHT_SAME_RIGHTS) {
        var out: UInt32 = 0
        check(Sys.duplicate(UInt64(other.raw), UInt64(rights), &out) == 0,
              "duplicating a handle")
        raw = out
    }

    var arg: UInt64 { UInt64(raw) }

    /// A VMO's content size property.
    var contentSize: UInt64 {
        var size: UInt64 = 0
        check(Sys.call(CROI_SYS_OBJECT_GET_PROPERTY, arg, UInt64(CROI_PROP_VMO_CONTENT_SIZE), Sys.address(&size), 8)
                  == 0, "reading the content size")
        return size
    }

    /// Sets a VMO's content size property: the call's status.
    func setContentSize(_ size: UInt64) -> Int64 {
        var value = size
        return Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, arg, UInt64(CROI_PROP_VMO_CONTENT_SIZE), Sys.address(&value), 8)
    }

    deinit { _ = croi_handle_close(raw) }
}

/// A port, with object_bind and port_wait.
struct Port: ~Copyable {
    let handle: Handle

    /// `options`: CROI_PORT_BIND_TO_INTERRUPT for interrupts' packets.
    init(options: UInt64 = 0) { handle = Handle(creating: CROI_SYS_PORT_CREATE, options: options) }

    /// object_bind of one item: its status, or the call's.
    func bind(_ source: borrowing Handle, _ options: UInt32, key: UInt64, trigger: UInt64 = 0) -> Int64 {
        var items = InlineArray<1, croi_bind_item_t>(repeating: item(source, options, key: key, trigger: trigger))
        let bound = bind(&items)
        return bound < 0 ? bound : Int64(items[0].status)
    }

    /// object_bind of every item: how many were bound, or the call's status.
    func bind<let n: Int>(_ items: inout InlineArray<n, croi_bind_item_t>, count: Int = n) -> Int64 {
        Sys.call(CROI_SYS_OBJECT_BIND, handle.arg, Sys.address(&items), UInt64(count))
    }

    func item(_ source: borrowing Handle, _ options: UInt32, key: UInt64, trigger: UInt64 = 0) -> croi_bind_item_t {
        croi_bind_item_t(handle: source.raw, options: options, key: key, trigger: trigger, status: 1, reserved: 0)
    }

    func cancel(_ source: borrowing Handle, key: UInt64) -> Int64 {
        Sys.call(CROI_SYS_PORT_CANCEL, handle.arg, source.arg, key)
    }

    /// The next packet, waiting until `deadline` (0: don't wait) give or
    /// take `leeway`; nil if none came.
    func next(deadline: UInt64 = 0, leeway: UInt64 = 0) -> croi_port_packet_t? {
        var packet = croi_port_packet_t()
        let status = unsafe croi_port_wait(handle.raw, deadline, &packet, leeway)
        check(status == 0 || status == Status.timedOut, "port_wait's status")
        return status == 0 ? packet : nil
    }

    /// Nothing is queued.
    var empty: Bool { next() == nil }

    /// The signals `source` has once any of `signals` is asserted, or 0 if
    /// none is by `deadline` (0: now). V1 cut object_wait_one (D23): a ONCE
    /// binding on a port of its own, cancelled if it didn't fire, since a
    /// pending binding holds its port.
    static func signals(of source: borrowing Handle, _ signals: UInt32, deadline: UInt64 = 0) -> UInt32 {
        let port = Port()
        guard port.bind(source, UInt32(CROI_BIND_SIGNALS), key: 0, trigger: UInt64(signals)) == 0 else { return 0 }
        guard let packet = port.next(deadline: deadline) else {
            _ = port.cancel(source, key: 0)
            return 0
        }
        return UInt32(truncatingIfNeeded: packet.payload.0 >> 32)
    }
}

/// A VMO mapped into the root VMAR, unmapped when it goes. Suites read and
/// write VMOs through mappings: vmo_read and vmo_write are cut in V1.
struct Mapping: ~Copyable {
    let address: UInt64
    let length: UInt64

    init(_ vmo: borrowing Handle, offset: UInt64 = 0, length: UInt64,
         permissions: UInt32 = UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_PERM_WRITE)) {
        var at: UInt64 = 0
        let status = unsafe croi_vmar_map(td_runtime_vmar_root, UInt32(permissions), 0,
                              vmo.raw, offset, length, &at)
        check(status == 0, "mapping a VMO")
        address = at
        self.length = length
    }

    subscript(_ offset: UInt64) -> UInt8 {
        get {
            check(offset < length, "a mapped offset")
            return unsafe UnsafePointer<UInt8>(bitPattern: UInt(address + offset))!.pointee
        }
        nonmutating set {
            check(offset < length, "a mapped offset")
            unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(address + offset))!.pointee = newValue
        }
    }

    deinit { _ = croi_vmar_unmap(td_runtime_vmar_root, address, length) }
}

/// A thread of this process running `entry(argument)` on a stack of its
/// own; `entry` ends with `Thread.exit()`. Joined through the floor's wait
/// (object_wait_one is cut in V1).
struct Thread: ~Copyable {
    let handle: Handle
    let stack: Mapping
    static var stackSize: UInt64 { 16384 }

    init(_ entry: @convention(c) (UInt64) -> Void, _ argument: UInt64) {
        stack = Mapping(Handle(vmo: Thread.stackSize), length: Thread.stackSize)
        var out: UInt32 = 0
        let name: StaticString = "t"
        check(Sys.call(CROI_SYS_THREAD_CREATE, UInt64(td_runtime_process_self), unsafe UInt64(UInt(bitPattern: name.utf8Start)),
                       1, 0, Sys.address(&out)) == 0, "creating a thread")
        handle = Handle(adopting: out)
        var top = stack.address + Thread.stackSize
        #if arch(x86_64)
        top -= 8  // entered as if called
        #endif
        let pc = unsafe UInt64(UInt(bitPattern: unsafeBitCast(entry, to: UnsafeRawPointer.self)))
        check(Sys.call(CROI_SYS_THREAD_START, handle.arg, pc, top, argument) == 0, "starting a thread")
    }

    /// Whether it ended by `deadline`: the floor's wait.
    func ended(by deadline: UInt64) -> Bool {
        let status = unsafe td_wait_one(handle.raw, UInt32(CROI_SIGNAL_TASK_TERMINATED), Int64(deadline), nil)
        check(status == 0 || status == Int32(CROI_ERR_TIMED_OUT), "waiting for a thread's end")
        return status == 0
    }

    /// Waits up to five seconds for it to end; a check fails if it doesn't.
    consuming func join() {
        check(ended(by: Sys.now() + 5_000_000_000), "a thread ends")
    }

    static func exit() -> Never {
        _ = Sys.call(CROI_SYS_THREAD_EXIT)
        fatalError()
    }
}
