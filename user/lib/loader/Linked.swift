import CroiRuntime

/// A program that needs libraries, loaded and linked by the process that
/// starts it (D124): the program and each DT_NEEDED name, breadth first,
/// from bootfs's `lib/NAME`, each mapped once into a VMAR of its own at a
/// random place in the new process (read-only segments straight from
/// bootfs, so every process shares them) and, for the while it takes to
/// link them, into this process too (system/ld's LinkSet relocates them
/// through those views). Every symbol is bound before the program runs,
/// each object's RELRO is then made read only, and a record of the set
/// (croi_link_map_t, processargs.h) goes on the top of the program's
/// stack for its runtime: the TLS blocks to lay out, the initializers to
/// run and the objects dlopen and dl_iterate_phdr report. Sys's process
/// start uses this; userboot starts static programs alone.
extension Program {
    /// Why a linked program couldn't be loaded, naming the object, and the
    /// status to return.
    public struct LinkFailure: Error {
        public let message: String
        public let status: Int64
    }

    /// Whether `elf`, whose bytes are `fileBytes`, names a library it needs
    /// (a DT_NEEDED entry).
    public static func needsLibraries(_ elf: ElfImage, _ fileBytes: RawSpan) -> Bool {
        guard let dynamic = elf.dynamic, var at = elf.fileOffset(of: dynamic, length: 16) else { return false }
        let bad = ElfImage.Error("bad dynamic section")
        while let tag = try? fileBytes.elfRead(UInt64.self, at: at, else: bad), tag != 0 {
            if tag == 1 { return true }
            at += 16
        }
        return false
    }

    /// One object of the set, as it is mapped.
    struct Mapped {
        let elf: ElfImage
        let delta: UInt64
        /// Its VMAR in the new process (the root's, for an ET_EXEC), and
        /// whether it's one of its own, to close.
        let vmar: UInt32, own: Bool
        let view: UInt32, viewBase: UInt64
        let phdr: UInt64, phnum: UInt64
    }

    /// Loads the program `file` of the bootfs image `bootfs` (a VMO) and
    /// what it needs from the same image's `lib/`, linked, into the process
    /// whose root VMAR is `vmar`. `name` names the program in messages.
    public static func loadLinked(_ name: String, file: Bootfs.File, bootfs: UInt32, into vmar: UInt32)
        throws(LinkFailure) -> Loaded {
        func fail(_ message: String, _ status: Int64 = CROI_ERR_INVALID_ARGS) -> LinkFailure {
            LinkFailure(message: message, status: status)
        }
        func failed(_ who: String, _ e: LoadFailure) -> LinkFailure {
            fail("\(who): \(e.what) failed (\(e.status))", e.status)
        }
        let own = td_runtime_vmar_root
        var size: UInt64 = 0
        var base: UInt64 = 0
        guard unsafe croi_vmo_size(bootfs, &size) == 0,
              unsafe croi_vmar_map(own, UInt32(CROI_VM_PERM_READ), 0, bootfs, 0, size, &base) == 0
        else { throw fail("\(name): bootfs can't be read") }
        defer { _ = croi_vmar_unmap(own, base, size) }
        let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(base))!, byteCount: Int(size))

        var region = croi_info_vmar_t()
        do throws(LoadFailure) {
            try Segments.call("reading its VMAR", croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(vmar),
                                                                UInt64(CROI_INFO_VMAR), Segments.address(&region),
                                                                UInt64(MemoryLayout<croi_info_vmar_t>.size), 0, 0))
        } catch {
            throw failed(name, error)
        }

        var set = LinkSet(machine: ElfImage.machine)
        var mapped: [Mapped] = []
        defer {
            for m in mapped {
                destroy(m.view)
                _ = croi_handle_close(m.view)
                if m.own { _ = croi_handle_close(m.vmar) }
            }
        }
        var next: (name: String, file: Bootfs.File)? = (name, file)
        while let (who, file) = next.map({ ($0.name, $0.file) }) {
            let fileBytes = image.extracting(Int(file.offset)..<Int(file.offset + file.length))
            let elf: ElfImage
            do throws(ElfImage.Error) {
                elf = try ElfImage(parsing: fileBytes)
            } catch {
                throw fail("\(who): \(error.reason)")
            }
            guard let dynamic = elf.dynamic, mapped.isEmpty || elf.kind == .pie else {
                throw fail("\(who): not a shared object")
            }
            let m = try map(who, elf, file: file, fileBytes: fileBytes, bootfs: bootfs, base: base, into: vmar, region)
            mapped.append(m)
            let bias = UInt(m.delta), view = UInt(m.viewBase &- elf.base)
            let object: DynamicObject
            do throws(LinkError) {
                object = try DynamicObject(bias: bias, view: view, dynamicAt: UInt(dynamic), machine: ElfImage.machine)
            } catch {
                throw fail("\(who): \(describe(error))")
            }
            set.add(who, object, tls: elf.tlsSegment.map {
                LinkSet.TLS(image: bias &+ UInt($0.vaddr), fileSize: Int($0.fileSize), size: Int($0.size),
                            align: Int($0.align))
            })
            next = nil
            if let needed = set.nextNeeded() {
                let path = Array(("lib/" + needed).utf8)
                do throws(Bootfs.Error) {
                    next = (needed, try Bootfs.find(path.span, in: image))
                } catch {
                    throw fail("\(who): needs \(needed), which bootfs's lib/ doesn't have", CROI_ERR_NOT_FOUND)
                }
            }
        }

        set.layOutTLS()
        do throws(LinkSet.BindError) {
            try set.bind()
        } catch {
            throw fail("\(error.object): \(describe(error.error))", CROI_ERR_NOT_FOUND)
        }
        for m in mapped {
            guard let relro = m.elf.relro else { continue }
            let status = croi_vmar_protect(m.vmar, UInt32(CROI_VM_PERM_READ), relro.start &+ m.delta, relro.end - relro.start)
            guard status == 0 else { throw fail("\(name): protecting a RELRO failed (\(status))", status) }
        }

        let program = mapped[0]
        let stackSize = ((program.elf.stackSize ?? defaultStackSize) + pageSize - 1) & ~(pageSize - 1)
        let record = handover(set, mapped)
        guard UInt64(record.count) + 4096 <= stackSize else { throw fail("\(name): too many objects for its stack") }
        do throws(LoadFailure) {
            let stack = try makeStack(in: vmar, size: stackSize)
            // The record at the top, written through a mapping of our own,
            // its addresses where the program will see them.
            let at = (stack.top - UInt64(record.count)) & ~15
            var rebased = record
            rebase(&rebased, to: UInt(at))
            var scratch: UInt64 = 0
            try Segments.call("mapping its stack", unsafe croi_vmar_map(own, UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE),
                                                                        0, stack.vmo, 0, stackSize, &scratch))
            unsafe rebased.withUnsafeBytes { bytes in
                unsafe UnsafeMutableRawPointer(bitPattern: UInt(scratch + (at - stack.base)))!
                    .copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
            _ = croi_vmar_unmap(own, scratch, stackSize)
            _ = croi_handle_close(stack.vmo)
            return Loaded(entry: program.elf.entry &+ program.delta, stack: at & ~15, handover: at)
        } catch {
            throw failed(name, error)
        }
    }

    /// `elf` mapped into the new process (a PIE at a random place, an
    /// ET_EXEC where it was linked) and into a view here.
    static func map(_ who: String, _ elf: ElfImage, file: Bootfs.File, fileBytes: RawSpan, bootfs: UInt32,
                    base: UInt64, into vmar: UInt32, _ region: croi_info_vmar_t) throws(LinkFailure) -> Mapped {
        do throws(LoadFailure) {
            var target = (vmar: vmar, base: region.base)
            var delta: UInt64 = 0
            if elf.kind == .pie {
                target = try randomPlace(in: vmar, region, size: elf.size)
                delta = target.base &- elf.base
            }
            var view: UInt32 = 0
            var viewBase: UInt64 = 0
            let canMap = UInt64(CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE)
            let status = croi_syscall6(CROI_SYS_VMAR_ALLOCATE, UInt64(td_runtime_vmar_root) | canMap << 32, 0, elf.size,
                                       Segments.address(&view), Segments.address(&viewBase), 0)
            guard status == 0 else {
                if target.vmar != vmar { _ = croi_handle_close(target.vmar) }
                throw LoadFailure(what: "making room to link it", status: status)
            }
            let header = fileBytes.extracting(0..<min(64, fileBytes.byteCount))
            let bad = ElfImage.Error("header")
            let phoff = (try? header.elfRead(UInt64.self, at: 32, else: bad)) ?? 0
            let phnum = UInt64((try? header.elfRead(UInt16.self, at: 56, else: bad)) ?? 0)
            var phdr: UInt64 = 0
            for i in 0..<elf.segmentCount {
                let s = elf.segments[i]
                if phoff >= s.offset, phoff - s.offset < s.filesz { phdr = s.vaddr + (phoff - s.offset) &+ delta }
            }
            let m = Mapped(elf: elf, delta: delta, vmar: target.vmar, own: target.vmar != vmar, view: view,
                           viewBase: viewBase, phdr: phdr, phnum: phnum)
            do throws(LoadFailure) {
                try Segments.map(elf, file: file, fileBytes: fileBytes, source: bootfs, sourceBase: base,
                                 into: target.vmar, vmarBase: target.base, delta: delta, relocate: false, view: view)
            } catch {
                destroy(view)
                _ = croi_handle_close(view)
                if m.own { _ = croi_handle_close(m.vmar) }
                throw error
            }
            return m
        } catch {
            throw LinkFailure(message: "\(who): \(error.what) failed (\(error.status))", status: error.status)
        }
    }

    /// A stack of `size` bytes mapped in the new process: its VMO (the
    /// caller closes it), base and top.
    static func makeStack(in vmar: UInt32, size: UInt64) throws(LoadFailure) -> (vmo: UInt32, base: UInt64, top: UInt64) {
        var stack: UInt32 = 0
        var stackBase: UInt64 = 0
        try Segments.call("making its stack", croi_syscall6(CROI_SYS_VMO_CREATE, size, 0, Segments.address(&stack), 0, 0, 0))
        let status = unsafe croi_vmar_map(vmar, UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE), 0, stack, 0, size,
                                          &stackBase)
        guard status == 0 else {
            _ = croi_handle_close(stack)
            throw LoadFailure(what: "mapping its stack", status: status)
        }
        return (stack, stackBase, stackBase + size)
    }

    /// The record of the set (croi_link_map_t, then a croi_link_object_t
    /// each, then the names), its name pointers as offsets into it until
    /// `rebase` places it.
    static func handover(_ set: LinkSet, _ mapped: [Mapped]) -> [UInt8] {
        var words: [UInt64] = [UInt64(CROI_LINK_MAP_MAGIC), UInt64(CROI_LINK_MAP_VERSION), UInt64(set.members.count),
                               UInt64(set.threadArea.align), UInt64(set.threadArea.below), UInt64(set.threadArea.above)]
        let headerWords = MemoryLayout<croi_link_map_t>.size / 8, objectWords = MemoryLayout<croi_link_object_t>.size / 8
        var names: [UInt8] = []
        let namesAt = 8 * (headerWords + objectWords * set.members.count)
        for (m, o) in zip(set.members, mapped) {
            let t = m.tls
            let start = words.count
            words += [UInt64(o.delta), o.phdr, o.phnum, UInt64(m.object.bias) &+ (o.elf.dynamic ?? 0),
                      UInt64(namesAt + names.count),
                      UInt64(t?.image ?? 0), UInt64(t?.fileSize ?? 0), UInt64(t?.size ?? 0),
                      UInt64(bitPattern: Int64(t == nil ? 0 : m.threadOffset)),
                      UInt64(m.object.initFunction ?? 0), UInt64(m.object.initArray.address),
                      UInt64(m.object.initArray.count)]
            precondition(words.count - start == objectWords)
            names += Array(m.name.utf8) + [0]
        }
        var bytes: [UInt8] = []
        for w in words { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: w >> UInt64(8 * i))) } }
        return bytes + names
    }

    /// Makes the record's name offsets addresses, for a record at `at`.
    static func rebase(_ record: inout [UInt8], to at: UInt) {
        func word(_ i: Int) -> UInt64 {
            var w: UInt64 = 0
            for b in 0..<8 { w |= UInt64(record[8 * i + b]) << UInt64(8 * b) }
            return w
        }
        let headerWords = MemoryLayout<croi_link_map_t>.size / 8, objectWords = MemoryLayout<croi_link_object_t>.size / 8
        for o in 0..<Int(word(2)) {
            let i = headerWords + o * objectWords + 4  // name
            let w = word(i) &+ UInt64(at)
            for b in 0..<8 { record[8 * i + b] = UInt8(truncatingIfNeeded: w >> UInt64(8 * b)) }
        }
    }

    /// Unmaps a view and everything in it.
    static func destroy(_ vmar: UInt32) {
        _ = croi_syscall6(UInt64(CROI_SYS_VMAR_DESTROY), UInt64(vmar), 0, 0, 0, 0, 0)
    }

    static func describe(_ e: LinkError) -> String {
        switch e {
        case .badDynamic(let what): "can't link: \(what)"
        case .unsupportedRelocation(let type): "relocation type \(type) isn't supported"
        case .undefinedSymbol(let name): "undefined symbol \(name)"
        }
    }
}
