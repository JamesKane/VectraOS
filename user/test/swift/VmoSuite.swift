import CroiRuntime

/// VMOs: executable replacement and the content size (ContentSize.swift),
/// moved here from usertest.c when V1 cut FIFOs, sockets and streams
/// (D21). Streams were the content size's main user; it stays as a VMO
/// property, the length Taisce's mapped files keep. Sizes and mappings
/// came from usertest.c's mode 0 when V1 cut vmo_map (D28); what a fault
/// reports and the copy race when it cut vmo_read and vmo_write (D37).
enum VmoSuite {
    static func run() {
        sizesAndMappings()
        executable()
        contentSize()
        referencesAndSlices()
        unbounded()
        sizeLock()
        faultStatuses()
        copyRace()
        vmarBatches()
        print("swift: vmo passed")
    }

    static var read: UInt32 { 1 << 2 }
    static var getProperty: UInt32 { 1 << 6 }
    static var setProperty: UInt32 { 1 << 7 }

    /// Sizes round up to a page, as Zircon's do, and no further than the
    /// address space allows. Two mappings of one VMO share its pages,
    /// across a page boundary too.
    static func sizesAndMappings() {
        let odd = Handle(vmo: 3584)
        var size: UInt64 = 0
        check(unsafe croi_vmo_size(odd.raw, &size) == 0 && size == pageSize,
              "a VMO's size rounds up to a page")
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE, ~0, 0, Sys.address(&out)) == Status.outOfRange,
              "a size that can't round up is out of range")
        let vmo = Handle(vmo: 2 * pageSize)
        let writer = Mapping(vmo, length: 2 * pageSize)
        let reader = Mapping(vmo, length: 2 * pageSize, permissions: UInt32(CROI_VM_PERM_READ))
        check(writer.address != reader.address, "two mappings")
        let start = pageSize - 32
        for i in UInt64(0)..<64 { writer[start + i] = UInt8(truncatingIfNeeded: i) &+ 0x41 }
        var same = true
        for i in UInt64(0)..<64 where reader[start + i] != UInt8(truncatingIfNeeded: i) &+ 0x41 { same = false }
        check(same, "one mapping reads what another wrote, across a page boundary")
    }

    /// An anonymous VMO isn't executable until replaced with a VMEX
    /// resource (the root resource here); the call consumes the handle,
    /// even when it refuses.
    static func executable() {
        let resource = Handle(adopting: croi_take_startup_handle(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0)))
        let rx = UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_PERM_EXECUTE)
        var vmo: UInt32 = 0, other: UInt32 = 0, exec: UInt32 = 0
        var at: UInt64 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE, pageSize, 0, Sys.address(&vmo)) == 0, "a VMO")
        check(unsafe croi_vmar_map(croi_vmar_root_self(), rx, 0, vmo, 0, pageSize, &at) == Status.accessDenied,
              "an anonymous VMO isn't executable")
        check(Sys.duplicate(UInt64(vmo), 1 << 31, &other) == 0, "a duplicate")
        check(Sys.call(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, UInt64(other), UInt64(vmo), Sys.address(&exec))
                  == Status.wrongType, "the resource must be a resource")
        check(croi_handle_close(other) == Status.badHandle, "a refusal still consumes the VMO")
        check(Sys.call(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, UInt64(vmo), resource.arg, Sys.address(&exec)) == 0,
              "replaced as executable")
        let executable = Handle(adopting: exec)
        check(croi_handle_close(vmo) == Status.badHandle, "the old handle is gone")
        _ = Mapping(executable, length: pageSize,
                    permissions: UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_PERM_EXECUTE))
    }

    /// The content size reads as the size asked for, at most the VMO's;
    /// cutting it zeroes what was past it.
    static func contentSize() {
        let odd = Handle(vmo: 2 * pageSize + 100)
        var size: UInt64 = 0
        check(unsafe croi_vmo_size(odd.raw, &size) == 0 && size == 3 * pageSize
                  && odd.contentSize == 2 * pageSize + 100, "an unaligned VMO: whole pages, the content size asked for")
        let vmo = Handle(vmo: 2 * pageSize)
        check(vmo.contentSize == 2 * pageSize, "the content size reads as the size until set")
        check(vmo.setContentSize(2 * pageSize + 1) == Status.outOfRange, "not past the VMO")
        let map = Mapping(vmo, length: 2 * pageSize)
        map[3] = UInt8(ascii: "h")
        map[20] = UInt8(ascii: "w")
        map[pageSize + 1] = UInt8(ascii: "p")
        check(vmo.setContentSize(4) == 0 && vmo.contentSize == 4, "set")
        check(map[3] == UInt8(ascii: "h") && map[20] == 0 && map[pageSize + 1] == 0, "cutting zeroes past it")
        check(vmo.setContentSize(2 * pageSize) == 0 && map[20] == 0, "growing it zeroes nothing back")
        let weak = Handle(duplicating: vmo, rights: read | getProperty | setProperty)
        check(weak.setContentSize(8) == Status.accessDenied && weak.contentSize == 2 * pageSize,
              "setting it needs WRITE")
    }

    /// A reference shares its root's content size; a slice has its own,
    /// over its parent's pages.
    static func referencesAndSlices() {
        let grow = Handle(vmo: 2 * pageSize, options: UInt64(CROI_VMO_CREATE_RESIZABLE))
        let ref = child(grow, UInt32(CROI_VMO_CHILD_REFERENCE), 0, 0)
        check(grow.setContentSize(100) == 0 && ref.contentSize == 100, "a reference sees its root's")
        check(ref.setContentSize(50) == 0 && grow.contentSize == 50, "and sets it")
        let big = Handle(vmo: 2 * pageSize)
        let window = child(big, UInt32(CROI_VMO_CHILD_SLICE), pageSize, pageSize)
        let map = Mapping(big, length: 2 * pageSize)
        map[pageSize + 4] = UInt8(ascii: "o")
        map[pageSize + 9] = UInt8(ascii: "x")
        check(window.contentSize == pageSize && window.setContentSize(5) == 0 && window.contentSize == 5
                  && big.contentSize == 2 * pageSize, "a slice has its own")
        check(map[pageSize + 4] == UInt8(ascii: "o") && map[pageSize + 9] == 0, "cutting a slice's zeroes its parent's pages")
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE_CHILD, grow.arg, UInt64(CROI_VMO_CHILD_SLICE), pageSize, pageSize,
                       Sys.address(&out)) == Status.notSupported, "no slices of a resizable VMO")
    }

    static func child(_ parent: borrowing Handle, _ options: UInt32, _ offset: UInt64, _ length: UInt64) -> Handle {
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE_CHILD, parent.arg, UInt64(options), offset, length, Sys.address(&out)) == 0,
              "a child VMO")
        return Handle(adopting: out)
    }

    /// An UNBOUNDED VMO's content size is the size asked for; cutting it
    /// zeroes far out, at the cost of what is committed.
    static func unbounded() {
        let far: UInt64 = 1 << 60
        let vmo = Handle(vmo: 3 * pageSize, options: UInt64(CROI_VMO_CREATE_UNBOUNDED))
        check(vmo.contentSize == 3 * pageSize, "UNBOUNDED: the size asked for")
        let map = Mapping(vmo, offset: far, length: pageSize)
        map[4] = UInt8(ascii: "U")
        check(vmo.setContentSize(10) == 0 && vmo.contentSize == 10 && map[4] == 0, "cut: zero far out")
    }

    /// One VMO's size lock: a content size change waiting for its pager
    /// holds it, so vmo_set_size of that VMO waits, while another VMO's
    /// change goes ahead (review 2: one global lock stalled it).
    struct SizeWork {
        var vmo: UInt32
        var resize: Bool
        var value: UInt64
        var result: Int64 = 1
    }

    static func sizeLock() {
        let pager = Handle(creating: CROI_SYS_PAGER_CREATE)
        let port = Port()
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_PAGER_CREATE_VMO, pager.arg, UInt64(CROI_VMO_RESIZABLE), port.handle.arg, 5,
                       4 * pageSize, Sys.address(&raw)) == 0, "a pager VMO")
        let paged = Handle(adopting: raw)
        let anon = Handle(vmo: 4 * pageSize)
        let work = UnsafeMutablePointer<SizeWork>.allocate(capacity: 3)
        unsafe work.initialize(to: SizeWork(vmo: paged.raw, resize: false, value: 10))  // needs page 0
        unsafe (work + 1).initialize(to: SizeWork(vmo: anon.raw, resize: false, value: 100))
        unsafe (work + 2).initialize(to: SizeWork(vmo: paged.raw, resize: true, value: 2 * pageSize))
        let entry: @convention(c) (UInt64) -> Void = { argument in
            let work = unsafe UnsafeMutablePointer<SizeWork>(bitPattern: UInt(argument))!
            let vmo = unsafe UInt64(work.pointee.vmo)
            var value = unsafe work.pointee.value
            unsafe work.pointee.result = work.pointee.resize
                ? Sys.call(CROI_SYS_VMO_SET_SIZE, vmo, value)
                : Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, vmo, UInt64(CROI_PROP_VMO_CONTENT_SIZE), Sys.address(&value), 8)
            Thread.exit()
        }
        let address = UInt64(UInt(bitPattern: work))
        let blocked = Thread(entry, address)
        guard let request = port.next(deadline: Sys.now() + 5_000_000_000) else {
            return check(false, "the pager is asked for page 0")
        }
        check(request.type == UInt32(CROI_PKT_TYPE_PAGE_REQUEST), "a page request")
        Sys.sleep(20_000_000)
        let other = Thread(entry, address + UInt64(MemoryLayout<SizeWork>.stride))
        let resizer = Thread(entry, address + 2 * UInt64(MemoryLayout<SizeWork>.stride))
        let otherEnded = other.ended(by: Sys.now() + 1_000_000_000)
        let otherResult = unsafe (work + 1).pointee.result
        check(otherEnded && otherResult == 0, "another VMO's size changes meanwhile")
        other.join()
        check(!resizer.ended(by: Sys.now() + 50_000_000), "vmo_set_size of the same VMO waits")
        let aux = Handle(vmo: 4 * pageSize)
        check(Sys.call(CROI_SYS_PAGER_SUPPLY_PAGES, pager.arg, paged.arg, 0, 4 * pageSize, aux.arg, 0) == 0,
              "the pager answers")
        blocked.join()
        resizer.join()
        var size: UInt64 = 0
        let results = unsafe (work.pointee.result, (work + 2).pointee.result)
        check(results == (0, 0), "both land once supplied")
        check(unsafe croi_vmo_size(paged.raw, &size) == 0 && size == 2 * pageSize
                  && paged.contentSize == 2 * pageSize, "the resize came second")
        unsafe work.deallocate()
    }

    /// What a fault reports (D37): with vmo_read cut, a reader learns why
    /// a page couldn't be had from its fault's exception, whose synth_code
    /// is the status, as in Zircon: the pager's FAIL status, BAD_STATE
    /// once the pager detached, OUT_OF_RANGE past a shrunk end, NOT_FOUND
    /// for a discarded VMO, ACCESS_DENIED for a write the mapping doesn't
    /// allow. The faults come to this process's exception channel.
    static func faultStatuses() {
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, UInt64(croi_process_self()), 0, Sys.address(&raw)) == 0,
              "this process's exception channel")
        let channel = Handle(adopting: raw)
        let pager = Handle(creating: CROI_SYS_PAGER_CREATE)
        let port = Port()
        check(Sys.call(CROI_SYS_PAGER_CREATE_VMO, pager.arg, 0, port.handle.arg, 7, 2 * pageSize, Sys.address(&raw)) == 0,
              "a pager VMO")
        let paged = Handle(adopting: raw)
        let map = Mapping(paged, length: 2 * pageSize, permissions: UInt32(CROI_VM_PERM_READ))
        let reader = Thread(touch, map.address)
        let request = port.next(deadline: Sys.now() + 5_000_000_000)
        check(request?.type == UInt32(CROI_PKT_TYPE_PAGE_REQUEST), "a fault asks the pager")
        check(Sys.call(CROI_SYS_PAGER_OP_RANGE, pager.arg, UInt64(CROI_PAGER_OP_FAIL), paged.arg, 0, pageSize,
                       UInt64(bitPattern: -40)) == 0, "the pager fails it")
        check(faultStatus(channel, reader) == -40, "the fault carries the pager's status (IO)")
        check(Sys.call(CROI_SYS_PAGER_DETACH_VMO, pager.arg, paged.arg) == 0, "the pager detached")
        check(faultStatus(channel, Thread(touch, map.address + pageSize)) == Status.badState, "then BAD_STATE")

        let resizable = Handle(vmo: 2 * pageSize, options: UInt64(CROI_VMO_CREATE_RESIZABLE))
        let whole = Mapping(resizable, length: 2 * pageSize)
        check(Sys.call(CROI_SYS_VMO_SET_SIZE, resizable.arg, pageSize) == 0, "a VMO shrunk under its mapping")
        check(faultStatus(channel, Thread(touch, whole.address + pageSize)) == Status.outOfRange, "OUT_OF_RANGE past its end")

        let discardable = Handle(vmo: pageSize, options: UInt64(CROI_VMO_CREATE_DISCARDABLE))
        var state = croi_vmo_lock_state_t()
        check(Sys.call(CROI_SYS_VMO_OP_RANGE, discardable.arg, UInt64(CROI_VMO_OP_LOCK), 0, pageSize, Sys.address(&state),
                       UInt64(MemoryLayout<croi_vmo_lock_state_t>.size)) == 0, "a discardable VMO locked")
        let kept = Mapping(discardable, length: pageSize)
        kept[0] = 1
        check(Sys.call(CROI_SYS_VMO_OP_RANGE, discardable.arg, UInt64(CROI_VMO_OP_UNLOCK), 0, pageSize) == 0
                  && MemorySuite.hook(6, 6) == 0 && MemorySuite.hook(7, 100, 6) >= 1, "unlocked, aged and discarded")
        check(faultStatus(channel, Thread(touch, kept.address)) == Status.notFound, "NOT_FOUND once discarded")

        let readOnly = Mapping(Handle(vmo: pageSize), length: pageSize, permissions: UInt32(CROI_VM_PERM_READ))
        check(faultStatus(channel, Thread(touch, readOnly.address | 1)) == Status.accessDenied,
              "ACCESS_DENIED for a write the mapping doesn't allow")
    }

    /// Reads the byte at `argument`, or writes it if bit 0 is set, then exits.
    static let touch: @convention(c) (UInt64) -> Void = { argument in
        let byte = unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(argument & ~1))!
        if argument & 1 != 0 {
            unsafe byte.pointee = 1
        } else {
            _ = Sys.call(CROI_SYS_NULL, UInt64(unsafe byte.pointee))  // used, so it is read
        }
        Thread.exit()
    }

    /// The status `thread`'s page fault reported on `channel`; the thread
    /// is ended. nil if no page fault came.
    static func faultStatus(_ channel: borrowing Handle, _ thread: consuming Thread) -> Int64? {
        var info = croi_exception_info_t()
        guard let exception = ObjectSuite.exception(on: channel, &info) else {
            thread.join()
            return nil
        }
        var report = croi_exception_report_t()
        let reported = Sys.call(CROI_SYS_OBJECT_GET_INFO, thread.handle.arg, UInt64(CROI_INFO_THREAD_EXCEPTION_REPORT),
                                Sys.address(&report), UInt64(MemoryLayout<croi_exception_report_t>.size), 0, 0)
        var ending = UInt32(CROI_EXCEPTION_STATE_THREAD_EXIT)
        check(Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, exception.arg, UInt64(CROI_PROP_EXCEPTION_STATE),
                       Sys.address(&ending), 4) == 0, "the faulting thread ended")
        _ = consume exception
        thread.join()
        guard reported == 0, info.type == UInt32(CROI_EXCP_FATAL_PAGE_FAULT) else { return nil }
        return Int64(Int32(bitPattern: report.context.synth_code))
    }

    /// K14h, from usertest.c's copy_race when V1 cut vmo_read (D37): the
    /// kernel copies a VMO's page under its VMO's lock, which
    /// process_read_memory still does. A writer fills a page with 'V' and
    /// decommits it, over and over; a polluter does the same with 'J' in a
    /// VMO of its own, so a freed page soon holds 'J'. A reader copying a
    /// page after it was freed would see a 'J'.
    struct Race {
        var vmo: UInt32
        var byte: UInt8
        var stop: UInt32 = 0
    }

    static func copyRace() {
        let shared = Handle(vmo: pageSize)
        let polluted = Handle(vmo: pageSize)
        let work = UnsafeMutablePointer<Race>.allocate(capacity: 2)
        unsafe work.initialize(to: Race(vmo: shared.raw, byte: UInt8(ascii: "V")))
        unsafe (work + 1).initialize(to: Race(vmo: polluted.raw, byte: UInt8(ascii: "J")))
        let address = UInt64(UInt(bitPattern: work))
        let writer = Thread(filler, address)
        let polluter = Thread(filler, address + UInt64(MemoryLayout<Race>.stride))
        let view = Mapping(shared, length: pageSize, permissions: UInt32(CROI_VM_PERM_READ))
        let viewed = view.address
        var page = InlineArray<4096, UInt8>(repeating: 0)
        let end = Sys.now() + 300_000_000
        var clean = true
        var reads = 0
        while Sys.now() < end && clean {
            var actual: UInt64 = 0
            var span = page.mutableSpan
            let status = span.withUnsafeMutableBytes { bytes in
                unsafe Sys.call(CROI_SYS_PROCESS_READ_MEMORY, UInt64(croi_process_self()), viewed,
                                UInt64(UInt(bitPattern: bytes.baseAddress)), pageSize, Sys.address(&actual))
            }
            guard status == 0 else { break }
            reads += 1
            for i in 0..<4096 where page[i] == UInt8(ascii: "J") { clean = false }
        }
        unsafe work.pointee.stop = 1
        unsafe (work + 1).pointee.stop = 1
        writer.join()
        polluter.join()
        check(clean, "no read sees a freed page's new contents")
        check(reads > 0, "process_read_memory reads the page")
        unsafe work.deallocate()
    }

    /// Fills its VMO's page with its byte through a mapping and decommits
    /// it, over and over until told to stop.
    static let filler: @convention(c) (UInt64) -> Void = { argument in
        let race = unsafe UnsafeMutablePointer<Race>(bitPattern: UInt(argument))!
        let vmo = unsafe UInt64(race.pointee.vmo)
        let byte = unsafe race.pointee.byte
        let own = croi_vmar_root_self()
        var at: UInt64 = 0
        check(unsafe croi_vmar_map(own, UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE), 0,
                                   UInt32(truncatingIfNeeded: vmo), 0, pageSize, &at) == 0, "a filler's mapping")
        let page = unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(at))!
        while unsafe race.pointee.stop == 0 {
            for i in 0..<Int(pageSize) { unsafe page[i] = byte }
            _ = Sys.call(CROI_SYS_VMO_OP_RANGE, vmo, UInt64(CROI_VMO_OP_DECOMMIT), 0, pageSize)
        }
        _ = croi_vmar_unmap(own, at, pageSize)
        Thread.exit()
    }

    /// vmar_map, vmar_unmap and vmar_protect take arrays (D42): a map
    /// stops at its first failure, leaving what it mapped; an unmap or a
    /// protect goes on past a range that fails.
    static func vmarBatches() {
        let vmo = Handle(vmo: 4 * pageSize)
        let own = croi_vmar_root_self()
        let rw = UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE)
        var maps = InlineArray<4, croi_vmar_map_item_t>(
            repeating: croi_vmar_map_item_t(vmo: vmo.raw, options: rw, vmar_offset: 0, vmo_offset: 0, len: pageSize,
                                            addr: 0, status: 1, reserved: 0))
        maps[1].vmo_offset = pageSize
        maps[2].vmo = 0  // no handle
        maps[3].vmo_offset = 3 * pageSize
        check(Sys.call(CROI_SYS_VMAR_MAP, UInt64(own), Sys.address(&maps), 4) == 2, "two of four mapped")
        check(maps[0].status == 0 && maps[1].status == 0 && Int64(maps[2].status) == Status.badHandle
                  && maps[3].status == 1 && maps[3].addr == 0, "the third failed, and the fourth was never tried")
        let first = unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(maps[0].addr))!
        let second = unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(maps[1].addr))!
        unsafe first.pointee = 0x5A
        unsafe second.pointee = 0xA5
        check(unsafe first.pointee == 0x5A && maps[0].addr != maps[1].addr, "each its own page")

        let range = croi_vmar_range_t(addr: maps[0].addr, len: pageSize, options: UInt32(CROI_VM_PERM_READ), status: 1)
        var ranges = InlineArray<3, croi_vmar_range_t>(repeating: range)
        ranges[1].addr = 0  // outside the VMAR
        ranges[2].addr = maps[1].addr
        check(Sys.call(CROI_SYS_VMAR_PROTECT, UInt64(own), Sys.address(&ranges), 3) == 2
                  && ranges[0].status == 0 && Int64(ranges[1].status) == Status.invalidArgs && ranges[2].status == 0,
              "a protect goes on past a range that fails")
        check(unsafe first.pointee == 0x5A && second.pointee == 0xA5, "still readable")
        for i in 0..<3 { ranges[i].options = 0 }
        ranges[1].options = 1  // unmap takes none
        check(Sys.call(CROI_SYS_VMAR_UNMAP, UInt64(own), Sys.address(&ranges), 3) == 2
                  && ranges[0].status == 0 && Int64(ranges[1].status) == Status.invalidArgs && ranges[2].status == 0,
              "an unmap too")
        check(Sys.call(CROI_SYS_VMAR_MAP, UInt64(own), Sys.address(&maps), 0) == Status.invalidArgs
                  && Sys.call(CROI_SYS_VMAR_UNMAP, UInt64(own), Sys.address(&ranges), 65) == Status.invalidArgs,
              "a count of 0 or over 64 is refused")
    }
}
