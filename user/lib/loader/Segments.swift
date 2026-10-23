import CroiRuntime

/// Why loading stopped: what it was doing, and the call's status.
public struct LoadFailure: Error {
    public let what: StaticString
    public let status: Int64

    public init(what: StaticString, status: Int64) {
        self.what = what
        self.status = status
    }
}

/// An ELF file's PT_LOAD segments mapped from the VMO that holds the file
/// (bootfs): what userboot does for the first program and dlopen
/// (system/ld) for a shared object, one way. A segment that is all file
/// and has nothing to write (read-only code and data) is mapped straight
/// from the VMO's pages; anything else is a K11a child of the file's range
/// (pages copied at first touch, the part past the file's bytes zeroed),
/// with a static PIE's relative relocations written in when asked (a
/// shared object is relocated after mapping, by Ld). Every segment goes
/// in one vmar_map (D42), all or nothing; the segments' own VMOs are
/// closed once mapped (the mappings keep them).
public enum Segments {
    static var pageSize: UInt64 { 4096 }

    /// Maps `elf`'s segments, the file at `file` in `source` (also mapped
    /// readable at `sourceBase`; `fileBytes` its bytes), into `vmar`, whose
    /// base is `vmarBase`, each at its address plus `delta`. With `view`, a
    /// VMAR of the same size in this process, the same pages go there too,
    /// at the same offsets, readable and (where the segment is) writable,
    /// never executable: a spawner relocates a program's objects through it.
    public static func map(_ elf: ElfImage, file: Bootfs.File, fileBytes: RawSpan, source: UInt32, sourceBase: UInt64,
                           into vmar: UInt32, vmarBase: UInt64, delta: UInt64, relocate: Bool,
                           view: UInt32? = nil) throws(LoadFailure) {
        var items: [croi_vmar_map_item_t] = []
        var made: [UInt32] = []
        defer { for vmo in made { _ = croi_handle_close(vmo) } }
        for i in 0..<elf.segmentCount {
            if let item = try segment(elf.segments[i], of: elf, file: file, fileBytes: fileBytes, source: source,
                                      sourceBase: sourceBase, vmarBase: vmarBase, delta: delta, relocate: relocate,
                                      made: &made) {
                items.append(item)
            }
        }
        guard !items.isEmpty else { return }
        guard items.count <= Int(CROI_VMAR_MAX_ITEMS) else {
            throw LoadFailure(what: "counting its segments", status: CROI_ERR_INVALID_ARGS)
        }
        if let view {
            // The view holds the image alone, from its first page: an
            // ET_EXEC's `vmar` is the whole root.
            let keep = UInt32(CROI_VM_SPECIFIC | CROI_VM_PERM_READ | CROI_VM_PERM_WRITE)
            let shift = elf.base &+ delta &- vmarBase
            var seen = items.map { item in
                var i = item
                i.options &= keep
                i.vmar_offset -= shift
                return i
            }
            try mapAll(&seen, into: view, "mapping its segments to link")
        }
        try mapAll(&items, into: vmar, "mapping its segments")
    }

    /// One vmar_map of `items` into `vmar`, all or nothing.
    static func mapAll(_ items: inout [croi_vmar_map_item_t], into vmar: UInt32, _ what: StaticString)
        throws(LoadFailure) {
        let mapped = unsafe items.withUnsafeMutableBufferPointer { buffer in
            unsafe croi_syscall6(CROI_SYS_VMAR_MAP, UInt64(vmar), UInt64(UInt(bitPattern: buffer.baseAddress)),
                                 UInt64(buffer.count), 0, 0, 0)
        }
        try call(what, mapped < 0 ? mapped : mapped == items.count ? 0 : Int64(items[Int(mapped)].status))
    }

    /// A segment's vmar_map item: the source VMO itself for a read-only
    /// segment it holds as is; otherwise a VMO of its own, filled and
    /// relocated, added to `made`. Nil for an empty segment.
    static func segment(_ segment: ElfImage.Segment, of elf: ElfImage, file: Bootfs.File, fileBytes: RawSpan,
                        source: UInt32, sourceBase: UInt64, vmarBase: UInt64, delta: UInt64, relocate: Bool,
                        made: inout [UInt32]) throws(LoadFailure) -> croi_vmar_map_item_t? {
        let size = (segment.memsz + pageSize - 1) & ~(pageSize - 1)
        guard size > 0 else { return nil }
        let runAddress = segment.vaddr &+ delta
        guard runAddress >= vmarBase else { throw LoadFailure(what: "placing a segment", status: CROI_ERR_INVALID_ARGS) }
        var options = UInt32(CROI_VM_SPECIFIC)
        if segment.readable { options |= UInt32(CROI_VM_PERM_READ) }
        if segment.writable { options |= UInt32(CROI_VM_PERM_WRITE) }
        if segment.executable { options |= UInt32(CROI_VM_PERM_EXECUTE) }
        // K14r: code built with BTI landing pads runs on guarded pages.
        if segment.executable, elf.branchTargets { options |= UInt32(CROI_VM_PERM_GUARDED) }
        var relocations = 0
        if relocate {
            do throws(ElfImage.Error) {
                try elf.forEachRelocation(in: fileBytes) { (target, _) throws(ElfImage.Error) in
                    if target >= segment.vaddr, target - segment.vaddr < size { relocations += 1 }
                }
            } catch {
                throw LoadFailure(what: "reading its relocations", status: CROI_ERR_INVALID_ARGS)
            }
        }
        let fileOffset = file.offset + segment.offset
        func item(_ vmo: UInt32, _ offset: UInt64) -> croi_vmar_map_item_t {
            croi_vmar_map_item_t(vmo: vmo, options: options, vmar_offset: runAddress - vmarBase, vmo_offset: offset,
                                 len: size, addr: 0, status: 1, reserved: 0)
        }
        if !segment.writable, segment.filesz == segment.memsz, relocations == 0 { return item(source, fileOffset) }
        var vmo: UInt32 = 0
        if fileOffset % pageSize == 0 {
            try call("making a segment", croi_syscall6(UInt64(CROI_SYS_VMO_CREATE_CHILD), UInt64(source),
                                                       UInt64(CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE), fileOffset,
                                                       size, address(&vmo), 0))
            if segment.filesz < size {
                try call("zeroing a segment's tail", croi_syscall6(UInt64(CROI_SYS_VMO_OP_RANGE), UInt64(vmo),
                                                                   UInt64(CROI_VMO_OP_ZERO), segment.filesz,
                                                                   size - segment.filesz, 0, 0))
            }
        } else {
            try call("making a segment", croi_syscall6(CROI_SYS_VMO_CREATE, size, 0, address(&vmo), 0, 0, 0))
        }
        made.append(vmo)
        // A misaligned segment's bytes and the relocations are written
        // through a mapping of our own (V1 cut vmo_write, D37).
        let copied = fileOffset % pageSize != 0
        if copied || relocations > 0 {
            let own = td_runtime_vmar_root
            var scratch: UInt64 = 0
            let rw = UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE)
            try call("mapping a segment to fill", unsafe croi_vmar_map(own, rw, 0, vmo, 0, size, &scratch))
            defer { _ = croi_vmar_unmap(own, scratch, size) }
            let bytes = unsafe UnsafeMutableRawPointer(bitPattern: UInt(scratch))!
            if copied {
                unsafe bytes.copyMemory(from: UnsafeRawPointer(bitPattern: UInt(sourceBase + fileOffset))!,
                                        byteCount: Int(segment.filesz))
            }
            if relocations > 0 {
                do throws(ElfImage.Error) {
                    try elf.forEachRelocation(in: fileBytes) { (target, addend) throws(ElfImage.Error) in
                        guard target >= segment.vaddr, target - segment.vaddr < size else { return }
                        unsafe bytes.storeBytes(of: delta &+ addend, toByteOffset: Int(target - segment.vaddr),
                                                as: UInt64.self)
                    }
                } catch {
                    throw LoadFailure(what: "reading its relocations", status: CROI_ERR_INVALID_ARGS)
                }
            }
        }
        return item(vmo, 0)
    }

    public static func call(_ what: StaticString, _ status: Int64) throws(LoadFailure) {
        guard status == 0 else { throw LoadFailure(what: what, status: status) }
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
    }
}
