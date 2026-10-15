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
        for i in 0..<croi_environ_count() {
            guard let entry = unsafe croi_environ(i) else { continue }
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
        } else {
            print("swift: no such suite")
            croi_exit(2)
        }
        croi_exit(0x600D)
    }
}

/// One check: on failure, says which and ends the run.
func check(_ condition: Bool, _ name: StaticString) {
    guard condition else {
        print("swift: FAILED: ", terminator: "")
        print(name)
        croi_exit(1)
    }
}

/// Status codes the suites expect (Zircon's values, kernel Status.swift).
enum Status {
    static var invalidArgs: Int64 { -10 }
    static var timedOut: Int64 { -21 }
}

/// Calls on the kernel, raw.
enum Sys {
    static func call(_ number: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0,
                     _ a4: UInt64 = 0) -> Int64 {
        croi_syscall(number, a0, a1, a2, a3, a4)
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        unsafe withUnsafeMutablePointer(to: &value) { unsafe UInt64(UInt(bitPattern: $0)) }
    }

    static func now() -> UInt64 { UInt64(bitPattern: call(CROI_SYS_CLOCK_MONOTONIC)) }
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

    init(duplicating other: borrowing Handle, rights: UInt32 = 1 << 31) {
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, UInt64(other.raw), UInt64(rights), Sys.address(&out)) == 0,
              "duplicating a handle")
        raw = out
    }

    var arg: UInt64 { UInt64(raw) }

    deinit { _ = Sys.call(CROI_SYS_HANDLE_CLOSE, UInt64(raw)) }
}

/// A port, with object_bind and port_wait.
struct Port: ~Copyable {
    let handle = Handle(creating: CROI_SYS_PORT_CREATE)

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
        let status = Sys.call(CROI_SYS_PORT_WAIT, handle.arg, deadline, Sys.address(&packet), leeway)
        check(status == 0 || status == Status.timedOut, "port_wait's status")
        return status == 0 ? packet : nil
    }

    /// Nothing is queued.
    var empty: Bool { next() == nil }
}
