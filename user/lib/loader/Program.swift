import CroiRuntime

/// A program loaded into a new process, ready for process_start: what
/// userboot does for the first program and Sys's `Process.start` for every
/// other (V2), one way. A static PIE goes in a child VMAR at a random place
/// in the lower half of the process's root VMAR (ASLR, from cprng_draw); an
/// ET_EXEC where it was linked. Its segments are mapped (`Segments`), its
/// PT_GNU_RELRO made read only once relocated, and a stack mapped as its
/// PT_GNU_STACK asks.
public enum Program {
    public static var defaultStackSize: UInt64 { 256 * 1024 }
    static var pageSize: UInt64 { 4096 }

    /// Where the process starts: its entry and the top of its stack; for a
    /// linked program, its record of the objects (croi_link_map_t), the
    /// first thread's second argument.
    public struct Loaded {
        public let entry: UInt64
        public let stack: UInt64
        public var handover: UInt64 = 0
    }

    /// Loads `elf`, the file at `file` in `source` (mapped readable at
    /// `sourceBase`; `fileBytes` its bytes), into the process whose root
    /// VMAR is `vmar`.
    public static func load(_ elf: ElfImage, file: Bootfs.File, fileBytes: RawSpan, source: UInt32, sourceBase: UInt64,
                            into vmar: UInt32) throws(LoadFailure) -> Loaded {
        var region = croi_info_vmar_t()
        try Segments.call("reading its VMAR", croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(vmar),
                                                            UInt64(CROI_INFO_VMAR), Segments.address(&region),
                                                            UInt64(MemoryLayout<croi_info_vmar_t>.size), 0, 0))
        var target = (vmar: vmar, base: region.base)
        var delta: UInt64 = 0
        if elf.kind == .pie {
            target = try randomPlace(in: vmar, region, size: elf.size)
            delta = target.base &- elf.base
        }
        defer { if target.vmar != vmar { _ = croi_handle_close(target.vmar) } }  // the region stays
        try Segments.map(elf, file: file, fileBytes: fileBytes, source: source, sourceBase: sourceBase,
                         into: target.vmar, vmarBase: target.base, delta: delta, relocate: true)
        if let relro = elf.relro {  // relocated: read only from here on
            try Segments.call("protecting its RELRO", croi_vmar_protect(target.vmar, UInt32(CROI_VM_PERM_READ),
                                                                        relro.start &+ delta, relro.end - relro.start))
        }
        let stackSize = ((elf.stackSize ?? defaultStackSize) + pageSize - 1) & ~(pageSize - 1)
        var stack: UInt32 = 0
        var stackBase: UInt64 = 0
        try Segments.call("making its stack", croi_syscall6(CROI_SYS_VMO_CREATE, stackSize, 0,
                                                            Segments.address(&stack), 0, 0, 0))
        defer { _ = croi_handle_close(stack) }  // the mapping keeps it
        try Segments.call("mapping its stack", unsafe croi_vmar_map(vmar, UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE),
                                                                    0, stack, 0, stackSize, &stackBase))
        return Loaded(entry: elf.entry &+ delta, stack: stackBase + stackSize)
    }

    /// A child VMAR of `size` bytes at a random page in the lower half of
    /// the root VMAR, retried where it collides.
    static func randomPlace(in root: UInt32, _ region: croi_info_vmar_t, size: UInt64) throws(LoadFailure)
        -> (vmar: UInt32, base: UInt64) {
        // Room for it in the lower half, else the subtraction (review fix:
        // it wrapped) and a modulus by zero pages.
        guard size < region.len / 2, (region.len / 2 - size) / pageSize > 0 else {
            throw LoadFailure(what: "placing it", status: CROI_ERR_OUT_OF_RANGE)
        }
        let pages = (region.len / 2 - size) / pageSize
        let canMap = UInt32(CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE | CROI_VM_CAN_MAP_EXECUTE | CROI_VM_SPECIFIC)
        for _ in 0..<16 {
            var random: UInt64 = 0
            try Segments.call("drawing a base", croi_syscall6(UInt64(CROI_SYS_CPRNG_DRAW), Segments.address(&random), 8,
                                                              0, 0, 0, 0))
            var child: UInt32 = 0
            var base: UInt64 = 0
            let status = croi_syscall6(CROI_SYS_VMAR_ALLOCATE, UInt64(root) | UInt64(canMap) << 32,
                                       (random % pages) * pageSize, size, Segments.address(&child),
                                       Segments.address(&base), 0)
            if status == 0 { return (child, base) }
            guard status == CROI_ERR_ALREADY_EXISTS else { throw LoadFailure(what: "placing it", status: status) }
        }
        throw LoadFailure(what: "placing it", status: CROI_ERR_NO_MEMORY)
    }

    /// The processargs message (processargs.h): the header, a handle-info
    /// word a handle, then the arguments, the environment and the names
    /// table, each a NUL-terminated string.
    public static func processArgs(infos: [UInt32], args: [[UInt8]], environment: [[UInt8]], names: [[UInt8]])
        -> [UInt8] {
        let header = MemoryLayout<croi_proc_args_t>.size
        func length(_ strings: [[UInt8]]) -> Int { strings.reduce(0) { $0 + $1.count + 1 } }
        var a = croi_proc_args_t()
        a.protocol = UInt32(CROI_PROCARGS_PROTOCOL)
        a.version = UInt32(CROI_PROCARGS_VERSION)
        a.handle_info_off = UInt32(header)
        a.args_off = UInt32(header + 4 * infos.count)
        a.args_num = UInt32(args.count)
        a.environ_off = a.args_off + UInt32(length(args))
        a.environ_num = UInt32(environment.count)
        a.names_off = a.environ_off + UInt32(length(environment))
        a.names_num = UInt32(names.count)
        var message: [UInt8] = []
        withUnsafeBytes(of: &a) { raw in
            for i in 0..<raw.count { message.append(unsafe raw[i]) }
        }
        for info in infos {
            for shift in stride(from: 0, to: 32, by: 8) { message.append(UInt8(truncatingIfNeeded: info >> UInt32(shift))) }
        }
        for s in args + environment + names {
            message.append(contentsOf: s)
            message.append(0)
        }
        return message
    }
}
