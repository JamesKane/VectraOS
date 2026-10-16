import CroiRuntime

/// The system's memory levels through the root account (D31). Moved here
/// from usertest.c's reclaim checks when V1 cut system_get_event: a
/// PRESSURE binding on the root account replaced its five events.
enum MemorySuite {
    static func run() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_ROOT_ACCOUNT), 0)))
        rootAccount(root)
        levels(root)
        print("swift: memory passed")
    }

    static func info(_ account: borrowing Handle) -> croi_info_memory_account_t {
        var info = croi_info_memory_account_t()
        var counts: (UInt64, UInt64) = (0, 0)
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, account.arg, UInt64(CROI_INFO_MEMORY_ACCOUNT), Sys.address(&info),
                       UInt64(MemoryLayout<croi_info_memory_account_t>.size), Sys.address(&counts.0),
                       Sys.address(&counts.1)) == 0, "account info")
        return info
    }

    /// Test hooks (syscall 6): 8 sets the watchdog's watermarks (OOM and
    /// imminent, critical, warning; bytes of free memory) with no
    /// hysteresis or eviction delay, all 0 the command line's; 9 reads
    /// the free bytes.
    static func hook(_ op: UInt64, _ a: UInt64 = 0, _ b: UInt64 = 0, _ c: UInt64 = 0) -> Int64 {
        Sys.call(CROI_SYS_TEST, op, a, b, c, 0, 0)
    }

    /// The root account: the RAM as its limit, what is in use as its
    /// charge; nothing charges it and its limit doesn't move.
    static func rootAccount(_ root: borrowing Handle) {
        let now = info(root)
        check(now.limit > 0 && now.charged > 0 && now.charged < now.limit, "the RAM, some of it in use")
        check(now.level == UInt32(CROI_MEMORY_LEVEL_NORMAL), "normal at rest")
        check(Sys.call(CROI_SYS_ACCOUNT_SET_LIMIT, root.arg, now.limit) == Status.notSupported, "its limit is the RAM's")
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE, pageSize, UInt64(CROI_VMO_CHARGE_TO), Sys.address(&out), root.arg)
                  == Status.accessDenied, "nothing charges it")
        let port = Port()
        check(port.bind(root, UInt32(CROI_BIND_PRESSURE) | UInt32(CROI_BIND_PERSISTENT), key: 1) == 0, "bound")
        check(port.next(deadline: Sys.now() + 20_000_000) == nil, "normal: nothing on binding")
    }

    /// Whether pressure packets reach `level` by the deadline. Packets
    /// coalesce while unread, so each carries the latest level; the
    /// watchdog may pass through levels on the way.
    static func reaches(_ port: borrowing Port, _ level: UInt32, within nanoseconds: UInt64 = 2_000_000_000) -> Bool {
        let deadline = Sys.now() + nanoseconds
        while let packet = port.next(deadline: deadline) {
            check(packet.type == UInt32(CROI_PKT_TYPE_MEMORY_PRESSURE) && packet.key == 2, "a pressure packet")
            if packet.payload.3 == UInt64(level) { return true }
        }
        return false
    }

    /// Watermarks just below free memory: 16 MiB committed is WARNING,
    /// 32 MiB CRITICAL, both freed NORMAL again. A new binding hears the
    /// level at once; port_cancel unbinds. (The root account outlives
    /// every binder, so a binding left behind would keep its port.)
    static func levels(_ root: borrowing Handle) {
        let mib: UInt64 = 1 << 20
        let free = UInt64(truncatingIfNeeded: hook(9))
        check(free > 64 * mib, "64 MiB free")
        let port = Port()
        check(port.bind(root, UInt32(CROI_BIND_PRESSURE) | UInt32(CROI_BIND_PERSISTENT), key: 2) == 0, "bound")
        check(hook(8, free / 4, free - 24 * mib, free - 12 * mib) == 0, "watermarks set")
        let first = Handle(vmo: 16 * mib)
        check(Sys.call(CROI_SYS_VMO_OP_RANGE, first.arg, UInt64(CROI_VMO_OP_COMMIT), 0, 16 * mib) == 0, "16 MiB")
        check(reaches(port, UInt32(CROI_MEMORY_LEVEL_WARNING)), "warning")
        let late = Port()
        check(late.bind(root, UInt32(CROI_BIND_PRESSURE) | UInt32(CROI_BIND_PERSISTENT), key: 2) == 0
                  && reaches(late, UInt32(CROI_MEMORY_LEVEL_WARNING), within: 0), "a new binding hears it at once")
        let second = Handle(vmo: 16 * mib)
        check(Sys.call(CROI_SYS_VMO_OP_RANGE, second.arg, UInt64(CROI_VMO_OP_COMMIT), 0, 16 * mib) == 0, "32 MiB")
        check(reaches(late, UInt32(CROI_MEMORY_LEVEL_CRITICAL)) && info(root).level == UInt32(CROI_MEMORY_LEVEL_CRITICAL),
              "critical")
        _ = consume first
        _ = consume second
        check(reaches(late, UInt32(CROI_MEMORY_LEVEL_NORMAL)), "normal again")
        check(late.cancel(root, key: 2) == 0, "port_cancel unbinds it")
        check(hook(8, free / 4, free - 24 * mib, free - 12 * mib) == 0, "watermarks set again")
        let third = Handle(vmo: 16 * mib)
        check(Sys.call(CROI_SYS_VMO_OP_RANGE, third.arg, UInt64(CROI_VMO_OP_COMMIT), 0, 16 * mib) == 0
                  && !reaches(late, UInt32(CROI_MEMORY_LEVEL_WARNING), within: 50_000_000)
                  && info(root).level == UInt32(CROI_MEMORY_LEVEL_WARNING), "and its port hears nothing more")
        _ = consume third
        check(hook(8) == 0, "the command line's watermarks back")
    }
}
