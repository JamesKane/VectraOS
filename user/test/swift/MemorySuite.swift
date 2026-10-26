import CroiRuntime

/// The system's memory levels through the root account (D31). Moved here
/// from usertest.c's reclaim checks when V1 cut system_get_event: a
/// PRESSURE binding on the root account replaced its five events. And a
/// pager VMO's pages charged to its account, which gives them up before
/// a commit against it fails (D131).
enum MemorySuite {
    static func run() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_ROOT_ACCOUNT), 0)))
        rootAccount(root)
        levels(root)
        pagerCharge(Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))))
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
        check(td_memory_bytes() == now.limit, "the topology page's RAM is its limit")
        check(UInt64(sysconf(Int32(_SC_PHYS_PAGES))) * 4096 == now.limit, "and sysconf's")
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

    static func committed(_ vmo: borrowing Handle) -> UInt64 {
        var v = croi_info_vmo_t()
        var counts: (UInt64, UInt64) = (0, 0)
        guard Sys.call(CROI_SYS_OBJECT_GET_INFO, vmo.arg, UInt64(CROI_INFO_VMO), Sys.address(&v),
                       UInt64(MemoryLayout<croi_info_vmo_t>.size), Sys.address(&counts.0),
                       Sys.address(&counts.1)) == 0 else { return ~0 }
        return v.committed_bytes
    }

    static func commit(_ vmo: borrowing Handle, _ pages: UInt64) -> Int64 {
        Sys.call(CROI_SYS_VMO_OP_RANGE, vmo.arg, UInt64(CROI_VMO_OP_COMMIT), 0, pages * pageSize, 0, 0)
    }

    /// A pager VMO's pages are charged to its account as they are
    /// supplied, and leave it when they go: evicted, or with the VMO. An
    /// account at its limit gives up its own clean pager pages before a
    /// commit against it fails, and a supply with none to give up fails.
    static func pagerCharge(_ resource: borrowing Handle) {
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_ACCOUNT_CREATE, resource.arg, 8 * pageSize, 50 | 75 << 32, Sys.address(&raw)) == 0,
              "an account of 8 pages")
        let account = Handle(adopting: raw)
        let pager = Handle(creating: CROI_SYS_PAGER_CREATE)
        let port = Port()
        check(Sys.call(CROI_SYS_PAGER_CREATE_VMO, pager.arg, UInt64(CROI_VMO_CHARGE_TO) | account.arg << 32,
                       port.handle.arg, 1, 16 * pageSize, Sys.address(&raw)) == 0, "a pager VMO charged to it")
        let paged = Handle(adopting: raw)
        let aux = Handle(vmo: 16 * pageSize)
        check(Sys.call(CROI_SYS_PAGER_SUPPLY_PAGES, pager.arg, paged.arg, 0, 4 * pageSize, aux.arg, 0) == 0
                  && info(account).charged == 4 * pageSize, "supplied pages are charged")
        check(Sys.call(CROI_SYS_VMO_CREATE, 16 * pageSize, UInt64(CROI_VMO_CHARGE_TO), Sys.address(&raw), account.arg) == 0,
              "an anonymous VMO charged to it")
        let anon = Handle(adopting: raw)
        check(commit(anon, 6) == 0, "a commit past the limit takes the pager's clean pages")
        let left = committed(paged)
        check(info(account).charged == 8 * pageSize && left == 2 * pageSize, "two of them, and the charge with them")
        check(commit(anon, 9) == Status.noMemory && committed(paged) == 0
                  && info(account).charged == 8 * pageSize, "with none left, past the limit fails")
        check(Sys.call(CROI_SYS_PAGER_SUPPLY_PAGES, pager.arg, paged.arg, 0, pageSize, aux.arg, 0) == Status.noMemory
                  && info(account).charged == 8 * pageSize, "so does a supply")
        _ = consume anon
        check(Sys.call(CROI_SYS_PAGER_SUPPLY_PAGES, pager.arg, paged.arg, 0, 2 * pageSize, aux.arg, 0) == 0
                  && info(account).charged == 2 * pageSize, "room again")
        _ = consume paged
        check(info(account).charged == 0, "the VMO's pages leave with it")
    }
}
