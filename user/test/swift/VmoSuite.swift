import CroiRuntime

/// VMOs: executable replacement and the content size (ContentSize.swift),
/// moved here from usertest.c when V1 cut FIFOs, sockets and streams
/// (D21). Streams were the content size's main user; it stays as a VMO
/// property, the length Taisce's mapped files keep. Sizes and mappings
/// came from usertest.c's mode 0 when V1 cut vmo_map (D28).
enum VmoSuite {
    static func run() {
        sizesAndMappings()
        executable()
        contentSize()
        referencesAndSlices()
        unbounded()
        sizeLock()
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
        check(Sys.call(CROI_SYS_VMO_GET_SIZE, odd.arg, Sys.address(&size)) == 0 && size == pageSize,
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
        let rx = UInt64(UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_PERM_EXECUTE)) << 32
        var vmo: UInt32 = 0, other: UInt32 = 0, exec: UInt32 = 0
        var at: UInt64 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE, pageSize, 0, Sys.address(&vmo)) == 0, "a VMO")
        check(Sys.call(CROI_SYS_VMAR_MAP, UInt64(croi_vmar_root_self()) | rx, 0, UInt64(vmo), 0, pageSize,
                       Sys.address(&at)) == Status.accessDenied, "an anonymous VMO isn't executable")
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, UInt64(vmo), 1 << 31, Sys.address(&other)) == 0, "a duplicate")
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
        check(Sys.call(CROI_SYS_VMO_GET_SIZE, odd.arg, Sys.address(&size)) == 0 && size == 3 * pageSize
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
        check(Sys.call(CROI_SYS_VMO_GET_SIZE, paged.arg, Sys.address(&size)) == 0 && size == 2 * pageSize
                  && paged.contentSize == 2 * pageSize, "the resize came second")
        unsafe work.deallocate()
    }
}
