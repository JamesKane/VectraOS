import CroiRuntime

/// What a driver host does with the root resource (K9a, K9b): resources
/// (ranges, exclusivity, the root filter, info), a physical VMO over a
/// device's registers read through a mapping, cache policy, VMO range
/// ops, IO ports (amd64), zero-size VMOs, and the boot data with the
/// firmware memory it points at. Moved here from usertest.c's mode 10,
/// which named QEMU's addresses. A machine's come from the boot data (its
/// RAM, the RSDP, SMBIOS, the framebuffer) and from the environment the
/// kernel gives this suite (ProcessSelfTest.runDrivers): a page the kernel
/// drives (`swift.kernelmmio=`), the first ECAM window's first bus, whose device
/// 0 is the device it reads (`swift.ecam=`), and whether the boot tests
/// drew their pattern on the framebuffer (`swift.fbpattern=`).
enum DriverSuite {
    static func run() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0)))
        let boot = BootData(Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTDATA), 0))))
        resources(root, boot)
        cachePolicy()
        rangeOps()
        ioPorts(root)
        let empty = Handle(vmo: 0)
        var size: UInt64 = 1
        check(unsafe croi_vmo_size(empty.raw, &size) == 0 && size == 0, "a zero-size VMO (Zircon's)")
        _ = consume empty
        firmware(root, boot)
        print("swift: drivers passed")
    }

    // MARK: Resources

    /// The root filter, an exclusive resource over the device's page, a
    /// physical VMO through it, and what closing gives back.
    static func resources(_ root: borrowing Handle, _ boot: borrowing BootData) {
        let ram = boot.firstRamPage
        let kernelMmio = Suite.hex("swift.kernelmmio=") ?? 0
        let device = Suite.hex("swift.ecam=") ?? 0
        check(ram != 0 && kernelMmio != 0 && device != 0, "RAM, a kernel page and a device to read")
        var raw: UInt32 = 0, other: UInt32 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE_PHYSICAL, root.arg, ram, pageSize, Sys.address(&raw)) == Status.accessDenied
                  && create(root, CROI_RSRC_KIND_MMIO, ram, pageSize, &raw) == Status.accessDenied,
              "RAM refused, as a physical VMO and as a resource")
        check(create(root, CROI_RSRC_KIND_MMIO, kernelMmio, pageSize, &raw) == Status.accessDenied,
              "the kernel's own registers refused")

        // Exclusive: overlaps refused, exclusive or not; no children.
        check(create(root, CROI_RSRC_KIND_MMIO | CROI_RSRC_FLAG_EXCLUSIVE, device, pageSize, &raw) == 0,
              "an exclusive resource over the device's page")
        var mmio = Handle(adopting: raw)
        check(create(root, CROI_RSRC_KIND_MMIO | CROI_RSRC_FLAG_EXCLUSIVE, device, pageSize, &other) == Status.notFound
                  && create(root, CROI_RSRC_KIND_MMIO, device + 8, 8, &other) == Status.notFound
                  && create(mmio, CROI_RSRC_KIND_MMIO, device, 8, &other) == Status.invalidArgs,
              "overlaps refused, and an exclusive resource has no children")
        var info = croi_info_resource_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, mmio.arg, UInt64(CROI_INFO_RESOURCE), Sys.address(&info),
                       UInt64(MemoryLayout<croi_info_resource_t>.size)) == 0
                  && info.kind == UInt32(CROI_RSRC_KIND_MMIO) && info.base == device && info.size == pageSize
                  && info.flags & UInt32(CROI_RSRC_FLAG_EXCLUSIVE) != 0 && info.name.0 == 0x64 && info.name.3 == 0,
              "info says what it is")

        // A physical VMO through it: other kinds and ranges refused.
        check(create(root, CROI_RSRC_KIND_IRQ, 40, 1, &raw) == 0, "an interrupt resource")
        let irq = Handle(adopting: raw)
        check(Sys.call(CROI_SYS_VMO_CREATE_PHYSICAL, irq.arg, device, pageSize, Sys.address(&other)) == Status.wrongType
                  && Sys.call(CROI_SYS_VMO_CREATE_PHYSICAL, mmio.arg, device + pageSize, pageSize, Sys.address(&other))
                      == Status.outOfRange
                  && Sys.call(CROI_SYS_VMO_CREATE_PHYSICAL, mmio.arg, device + 1, pageSize, Sys.address(&other))
                      == Status.invalidArgs,
              "a physical VMO only through an MMIO resource covering it, page aligned")
        do {
            // Mapped, the device answers (uncached by default): a function
            // at bus 0 device 0, its vendor ID.
            let registers = Device(mmio, device, pageSize, permissions: UInt32(CROI_VM_PERM_READ))
            let vendor = registers.read32(0) & 0xFFFF
            check(vendor != 0xFFFF && vendor != 0, "the device answers through the mapping")
            // Device memory: no policy change while mapped.
            check(Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, registers.vmo.arg, UInt64(CROI_CACHE_POLICY_UNCACHED))
                      == Status.badState
                      && Sys.call(CROI_SYS_VMO_OP_RANGE, registers.vmo.arg, UInt64(CROI_VMO_OP_CACHE_CLEAN), 0, pageSize)
                          == 0,
                  "no cache policy change while mapped; cache ops allowed")
        }

        // Closed, the range is free for anyone again; a child can't grow.
        _ = consume mmio
        check(create(root, CROI_RSRC_KIND_MMIO, device, pageSize, &raw) == 0, "the range is free once closed")
        mmio = Handle(adopting: raw)
        check(create(mmio, CROI_RSRC_KIND_MMIO, device + 0x100, 0x100, &other) == 0, "a child inside it")
        let child = Handle(adopting: other)
        check(create(child, CROI_RSRC_KIND_MMIO, device, 0x200, &raw) == Status.accessDenied,
              "a grandchild outside its parent refused")

        // System resources: size 1 inside the system space; ROOT can't be minted.
        check(create(root, CROI_RSRC_KIND_SYSTEM, UInt64(CROI_RSRC_SYSTEM_TRACING_BASE), 1, &raw) == 0,
              "a system resource")
        _ = Handle(adopting: raw)
        check(create(root, CROI_RSRC_KIND_SYSTEM, UInt64(CROI_RSRC_SYSTEM_COUNT), 1, &raw) == Status.notFound
                  && create(root, 3, 0, 1, &raw) == Status.invalidArgs,
              "outside the system space, or ROOT, refused")
        _ = consume irq
    }

    // MARK: Anonymous VMOs

    /// Cache policy on an anonymous VMO: only unmapped; MAP needed; bad
    /// values refused.
    static func cachePolicy() {
        let anon = Handle(vmo: 3 * pageSize)
        check(Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, anon.arg, 7) == Status.invalidArgs, "an unknown policy refused")
        let readonly = Handle(duplicating: anon, rights: 1 << 2 | 1 << 15)
        check(Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, readonly.arg, UInt64(CROI_CACHE_POLICY_CACHED))
                  == Status.accessDenied, "a policy needs MAP")
        check(Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, anon.arg, UInt64(CROI_CACHE_POLICY_WRITE_COMBINING)) == 0
                  && Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, anon.arg, UInt64(CROI_CACHE_POLICY_CACHED)) == 0,
              "set and set back while unmapped")
    }

    /// op_range: commit, zero part of it, cache ops, decommit, and the
    /// refusals.
    static func rangeOps() {
        let anon = Handle(vmo: 3 * pageSize)
        let readonly = Handle(duplicating: anon, rights: 1 << 2 | 1 << 15)
        func op(_ handle: borrowing Handle, _ op: some BinaryInteger, _ offset: UInt64, _ length: UInt64) -> Int64 {
            Sys.call(CROI_SYS_VMO_OP_RANGE, handle.arg, UInt64(op), offset, length)
        }
        check(op(anon, CROI_VMO_OP_COMMIT, 100, 2 * pageSize) == 0, "committed")
        do {
            let mapping = Mapping(anon, length: 3 * pageSize)
            for i in 0..<UInt64(64) { mapping[pageSize - 32 + i] = 0xAB }
            check(op(anon, CROI_VMO_OP_ZERO, pageSize - 16, 32) == 0
                      && mapping[pageSize - 32] == 0xAB && mapping[pageSize - 17] == 0xAB
                      && mapping[pageSize - 16] == 0 && mapping[pageSize + 15] == 0 && mapping[pageSize + 16] == 0xAB,
                  "zeroing part of a page leaves the rest")
            check(op(anon, CROI_VMO_OP_ZERO, 0, 3 * pageSize) == 0
                      && mapping[pageSize - 32] == 0 && mapping[pageSize + 31] == 0,
                  "zeroing it all")
        }
        check(op(anon, CROI_VMO_OP_CACHE_CLEAN, 8, 100) == 0
                  && op(anon, CROI_VMO_OP_CACHE_CLEAN_INVALIDATE, 0, 3 * pageSize) == 0
                  && op(anon, CROI_VMO_OP_CACHE_SYNC, 0, pageSize) == 0
                  && op(anon, CROI_VMO_OP_DECOMMIT, 0, 3 * pageSize) == 0,
              "cache ops and decommit")
        check(op(anon, CROI_VMO_OP_CACHE_CLEAN, 0, 0) == Status.invalidArgs
                  && op(anon, CROI_VMO_OP_CACHE_INVALIDATE, 0, pageSize) == Status.notSupported
                  && op(anon, CROI_VMO_OP_DECOMMIT, 1, pageSize) == Status.invalidArgs
                  && op(anon, CROI_VMO_OP_COMMIT, 2 * pageSize, 2 * pageSize) == Status.outOfRange
                  && op(anon, 99, 0, pageSize) == Status.invalidArgs
                  && op(readonly, CROI_VMO_OP_COMMIT, 0, pageSize) == Status.accessDenied
                  && op(readonly, CROI_VMO_OP_CACHE_CLEAN, 0, pageSize) == 0,
              "op_range's refusals")
    }

    // MARK: IO ports

    /// amd64: a port allowed after a request, refused again after the
    /// release (a thread's outb then raises a general exception). Elsewhere
    /// there are none.
    static func ioPorts(_ root: borrowing Handle) {
        #if arch(x86_64)
        var raw: UInt32 = 0, other: UInt32 = 0
        check(create(root, CROI_RSRC_KIND_IOPORT, 0x80, 1, &raw) == 0, "an IO port resource")
        let ports = Handle(adopting: raw)
        check(create(root, CROI_RSRC_KIND_IOPORT, 0x20, 2, &other) == Status.accessDenied, "the 8259's ports refused")
        check(Sys.call(CROI_SYS_IOPORTS_REQUEST, ports.arg, 0x81, 1) == Status.outOfRange
                  && Sys.call(CROI_SYS_IOPORTS_REQUEST, ports.arg, 0x80, 1) == 0,
              "a port requested inside its resource")
        td_port_out(0x80, 1, 0)
        check(Sys.call(CROI_SYS_IOPORTS_RELEASE, ports.arg, 0x80, 1) == 0, "and released")
        check(Sys.call(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, UInt64(td_runtime_process_self), 0, Sys.address(&raw))
                  == 0, "an exception channel")
        let channel = Handle(adopting: raw)
        let worker = Thread({ _ in
            td_port_out(0x80, 1, 0)
            Thread.exit()
        }, 0)
        var info = croi_exception_info_t()
        guard let exception = ObjectSuite.exception(on: channel, &info) else {
            check(false, "a released port faults")
            return
        }
        check(info.type == UInt32(CROI_EXCP_GENERAL), "a general exception")
        var state = UInt32(CROI_EXCEPTION_STATE_THREAD_EXIT)
        check(Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, exception.arg, UInt64(CROI_PROP_EXCEPTION_STATE),
                       Sys.address(&state), 4) == 0, "the thread ended")
        _ = consume exception
        worker.join()
        _ = consume channel
        #else
        check(Sys.call(CROI_SYS_IOPORTS_REQUEST, root.arg, 0x80, 1) == Status.notSupported, "no IO ports")
        #endif
    }

    // MARK: Firmware

    /// The ACPI tables through physical VMOs (cached only), RAM refused
    /// whatever its range, SMBIOS, and the framebuffer.
    static func firmware(_ root: borrowing Handle, _ boot: borrowing BootData) {
        check(boot.rsdp != 0 && boot.rangeCount > 0, "the RSDP and the memory ranges")
        for i in 1..<boot.rangeCount {
            check(boot.range(i - 1).paddr + boot.range(i - 1).length <= boot.range(i).paddr, "ranges sorted, apart")
        }
        // The RSDP is in firmware memory (RESERVED): an MMIO resource over
        // it, cached only.
        var raw: UInt32 = 0
        let first = boot.rsdp & ~(pageSize - 1)
        let pages = ((boot.rsdp + 36 + pageSize - 1) & ~(pageSize - 1)) - first
        check(boot.type(of: boot.rsdp) == UInt32(CROI_ZBI_MEM_TYPE_RESERVED)
                  && boot.type(of: boot.firstRamPage) == UInt32(CROI_ZBI_MEM_TYPE_RAM),
              "the RSDP in RESERVED memory, RAM in RAM")
        check(create(root, CROI_RSRC_KIND_MMIO, first, pages, &raw) == 0, "a resource over the RSDP")
        let mmio = Handle(adopting: raw)
        check(Sys.call(CROI_SYS_VMO_CREATE_PHYSICAL, mmio.arg, first, pages, Sys.address(&raw)) == 0,
              "a physical VMO over it")
        do {
            let vmo = Handle(adopting: raw)
            check(Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, vmo.arg, UInt64(CROI_CACHE_POLICY_UNCACHED))
                      == Status.accessDenied
                      && Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, vmo.arg, UInt64(CROI_CACHE_POLICY_WRITE_COMBINING))
                          == Status.accessDenied,
                  "firmware memory is cached only")
        }
        let xsdt: UInt64
        do {
            let table = Device(mmio, boot.rsdp, 36, policy: UInt32(CROI_CACHE_POLICY_CACHED),
                               permissions: UInt32(CROI_VM_PERM_READ))
            check(table.read8(0) == 0x52 && table.read8(1) == 0x53 && table.read8(2) == 0x44 && table.read8(7) == 0x20
                      && table.read8(15) >= 2 && checksum(table, 36) == 0,
                  "the RSDP: its signature, revision 2, its checksum")
            xsdt = UInt64(table.read32(24)) | UInt64(table.read32(28)) << 32
        }
        _ = consume mmio
        // The XSDT, through the root resource: whole and summing to zero.
        let length: UInt64
        do {
            let header = Device(root, xsdt, 36, policy: UInt32(CROI_CACHE_POLICY_CACHED),
                                permissions: UInt32(CROI_VM_PERM_READ))
            length = UInt64(header.read32(4))
            check(header.read8(0) == 0x58 && header.read8(1) == 0x53 && header.read8(2) == 0x44
                      && header.read8(3) == 0x54 && length >= 36 && length < 65536,
                  "the XSDT's header")
        }
        do {
            let table = Device(root, xsdt, length, policy: UInt32(CROI_CACHE_POLICY_CACHED),
                               permissions: UInt32(CROI_VM_PERM_READ))
            check(checksum(table, length) == 0, "the XSDT sums to zero")
        }
        // RAM stays refused, whatever range it is.
        for i in 0..<boot.rangeCount where boot.range(i).type == UInt32(CROI_ZBI_MEM_TYPE_RAM) {
            let page = (boot.range(i).paddr + pageSize - 1) & ~(pageSize - 1)
            check(Sys.call(CROI_SYS_VMO_CREATE_PHYSICAL, root.arg, page, pageSize, Sys.address(&raw))
                      == Status.accessDenied, "every RAM range refused")
        }
        // SMBIOS, if firmware has it: the entry point's anchor.
        if boot.smbios != 0 {
            let anchor = Device(root, boot.smbios, 5, policy: UInt32(CROI_CACHE_POLICY_CACHED),
                                permissions: UInt32(CROI_VM_PERM_READ))
            check(anchor.read8(0) == 0x5F && anchor.read8(1) == 0x53 && anchor.read8(2) == 0x4D
                      && (anchor.read8(3) == 0x5F || (anchor.read8(3) == 0x33 && anchor.read8(4) == 0x5F)),
                  "SMBIOS's anchor")
        }
        framebuffer(root, boot)
    }

    /// The framebuffer (PERIPHERAL), mapped write-combining; with the boot
    /// tests, the kernel's pattern is there: background (16, 48, 96) and a
    /// (240, 192, 32) block at (16, 16) sized 64x32.
    static func framebuffer(_ root: borrowing Handle, _ boot: borrowing BootData) {
        guard let fb = boot.framebuffer else { return }
        check(boot.type(of: fb.base) == UInt32(CROI_ZBI_MEM_TYPE_PERIPHERAL) && fb.width >= 80 && fb.height >= 48
                  && fb.stride >= fb.width, "the framebuffer in PERIPHERAL memory")
        guard Suite.hex("swift.fbpattern=") == 1 else { return }
        let rgb = fb.format == UInt32(CROI_ZBI_PIXEL_FORMAT_RGB_X888)
        check(rgb || fb.format == UInt32(CROI_ZBI_PIXEL_FORMAT_BGR_888_X), "a pixel format we know")
        let background: UInt32 = rgb ? 0x103060 : 0x603010
        let block: UInt32 = rgb ? 0xF0C020 : 0x20C0F0
        let pixels = Device(root, fb.base, UInt64(fb.stride) * UInt64(fb.height) * 4,
                            policy: UInt32(CROI_CACHE_POLICY_WRITE_COMBINING))
        check(pixels.read32(0) & 0xFFFFFF == background
                  && pixels.read32((30 * UInt64(fb.stride) + 40) * 4) & 0xFFFFFF == block,
              "the kernel's pattern, read write-combining")
    }

    // MARK: Helpers

    /// resource_create named "drv": its status.
    static func create(_ parent: borrowing Handle, _ options: some BinaryInteger, _ base: UInt64, _ size: UInt64,
                       _ out: inout UInt32) -> Int64 {
        let name: StaticString = "drv"
        return Sys.call(CROI_SYS_RESOURCE_CREATE, parent.arg | UInt64(options) << 32, base, size,
                        unsafe UInt64(UInt(bitPattern: name.utf8Start)), 3, Sys.address(&out))
    }

    static func checksum(_ table: borrowing Device, _ length: UInt64) -> UInt8 {
        var sum: UInt8 = 0
        for i in 0..<length { sum &+= table.read8(i) }
        return sum
    }

    /// The boot data: the kernel's ZBI container of firmware items
    /// (zbi.h), read only.
    struct BootData: ~Copyable {
        let mapping: Mapping
        var rsdp: UInt64 = 0
        var smbios: UInt64 = 0
        var framebuffer: croi_zbi_swfb_t? = nil
        private var ranges: UInt64 = 0  // the first croi_zbi_mem_range_t's address
        private(set) var rangeCount = 0

        init(_ vmo: consuming Handle) {
            var size: UInt64 = 0
            check(unsafe croi_vmo_size(vmo.raw, &size) == 0 && size >= pageSize, "the boot data's size")
            var at: UInt64 = 0
            check(unsafe croi_vmar_map(td_runtime_vmar_root, UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_PERM_WRITE), 0,
                                       vmo.raw, 0, size, &at) == Status.accessDenied,
                  "the boot data can't be mapped writable")
            mapping = Mapping(vmo, length: size, permissions: UInt32(CROI_VM_PERM_READ))
            let container = BootData.header(mapping.address)
            check(container.type == UInt32(CROI_ZBI_TYPE_CONTAINER) && container.extra == UInt32(CROI_ZBI_CONTAINER_MAGIC)
                      && container.flags & UInt32(CROI_ZBI_FLAGS_VERSION) != 0
                      && container.magic == UInt32(CROI_ZBI_ITEM_MAGIC)
                      && UInt64(container.length) % UInt64(CROI_ZBI_ALIGNMENT) == 0
                      && UInt64(container.length) + 32 <= size,
                  "a ZBI container")
            let end = 32 + UInt64(container.length)
            var offset: UInt64 = 32
            while offset < end {
                let item = BootData.header(mapping.address + offset)
                let payload = mapping.address + offset + 32
                check(item.magic == UInt32(CROI_ZBI_ITEM_MAGIC) && item.flags & UInt32(CROI_ZBI_FLAGS_VERSION) != 0
                          && item.crc32 == UInt32(CROI_ZBI_ITEM_NO_CRC32) && offset + 32 + UInt64(item.length) <= end,
                      "every item well formed")
                switch item.type {
                case UInt32(CROI_ZBI_TYPE_ACPI_RSDP) where item.length == 8:
                    rsdp = unsafe UnsafePointer<UInt64>(bitPattern: UInt(payload))!.pointee
                case UInt32(CROI_ZBI_TYPE_SMBIOS) where item.length == 8:
                    smbios = unsafe UnsafePointer<UInt64>(bitPattern: UInt(payload))!.pointee
                case UInt32(CROI_ZBI_TYPE_FRAMEBUFFER) where Int(item.length) == MemoryLayout<croi_zbi_swfb_t>.size:
                    framebuffer = unsafe UnsafePointer<croi_zbi_swfb_t>(bitPattern: UInt(payload))!.pointee
                case UInt32(CROI_ZBI_TYPE_MEM_CONFIG)
                    where Int(item.length) % MemoryLayout<croi_zbi_mem_range_t>.size == 0:
                    ranges = payload
                    rangeCount = Int(item.length) / MemoryLayout<croi_zbi_mem_range_t>.size
                default:
                    break
                }
                let aligned = (UInt64(item.length) + UInt64(CROI_ZBI_ALIGNMENT) - 1) & ~(UInt64(CROI_ZBI_ALIGNMENT) - 1)
                offset += 32 + aligned
            }
        }

        private static func header(_ address: UInt64) -> croi_zbi_header_t {
            unsafe UnsafePointer<croi_zbi_header_t>(bitPattern: UInt(address))!.pointee
        }

        func range(_ i: Int) -> croi_zbi_mem_range_t {
            unsafe UnsafePointer<croi_zbi_mem_range_t>(bitPattern: UInt(ranges))![i]
        }

        /// The MEM_CONFIG type of the range holding `paddr`, 0 if none.
        func type(of paddr: UInt64) -> UInt32 {
            for i in 0..<rangeCount where range(i).paddr <= paddr && paddr - range(i).paddr < range(i).length {
                return range(i).type
            }
            return 0
        }

        /// The first whole page of RAM past page 0 (a PC's RAM starts at
        /// 0), or 0.
        var firstRamPage: UInt64 {
            for i in 0..<rangeCount where range(i).type == UInt32(CROI_ZBI_MEM_TYPE_RAM) {
                let page = max((range(i).paddr + pageSize - 1) & ~(pageSize - 1), pageSize)
                if page + pageSize <= range(i).paddr + range(i).length { return page }
            }
            return 0
        }
    }
}
