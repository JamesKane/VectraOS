import CHandoff
import CKernel
import Elf
import PageTables

/// Warm boot (D101): the loader's work, done by the running kernel from
/// a kernel ELF and a bootfs held in VMOs, then its jump. The firmware is
/// long gone, so what the loader learned from it comes from the boot
/// handoff the kernel kept (`bootHandoff`) and the memory map and command
/// line saved here at boot, whose pages the PMM never sees as free.
///
/// Everything that can fail fails first, with nothing stopped: the ELF
/// is checked, then copied, loaded and relocated at a new KASLR base (never
/// where this kernel runs), the bootfs copied, and the boot page tables
/// and the handoff built, each in a physically contiguous run of its own.
/// The new memory map is the saved one with the loader's and this kernel's
/// ranges (KERNEL, HANDOFF, BOOTFS) free again and the new runs typed so.
/// Then the debuglog drains as for a reboot, the other CPUs stop, the
/// IOMMUs go off, and `arch_warmboot_enter` loads the new tables and
/// enters the new kernel as the loader would. The tables map that
/// function's page at its address here too, so the jump survives the
/// switch.
///
/// amd64 only so far; arm64 (PSCI CPU_OFF, the MMU and caches around the
/// switch) and rv64 (SBI HSM) follow.
enum WarmBoot {
    /// The firmware's memory map, then the boot command line, in pages
    /// taken at boot (physical; 0: none kept).
    nonisolated(unsafe) static var saved: UInt64 = 0
    nonisolated(unsafe) static var savedRanges = 0
    nonisolated(unsafe) static var savedCmdline = 0

    static var page: UInt64 { KernelLayout.pageSize }
    static func pages(_ bytes: UInt64) -> UInt64 { (bytes + page - 1) / page }
    static let rangeSize = MemoryLayout<croi_mem_range_t>.size

    /// Keeps the memory map and the command line (boot, before the PMM
    /// reclaims the handoff's pages).
    static func capture(_ handoff: croi_handoff_t, _ allocator: inout BootAllocator) {
        let count = allocator.rangeCount
        let command = Int(handoff.cmdline_size)
        let bytes = UInt64(count * rangeSize + command)
        guard bytes > 0, let phys = allocator.allocate(pages: pages(bytes)) else { return }
        let base = unsafe UnsafeMutableRawPointer(bitPattern: allocator.tableAddress(phys))!
        for i in 0..<count {
            unsafe base.storeBytes(of: allocator.range(i), toByteOffset: i * rangeSize, as: croi_mem_range_t.self)
        }
        if command > 0, handoff.cmdline != 0 {
            let from = unsafe UnsafeRawPointer(bitPattern: allocator.tableAddress(handoff.cmdline))!
            unsafe (base + count * rangeSize).copyMemory(from: from, byteCount: command)
        }
        saved = phys
        savedRanges = count
        savedCmdline = command
    }

    static func physmap(_ phys: UInt64) -> UnsafeMutableRawPointer {
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
    }

    /// `bytes` of `vmo` from its start into the run at `phys` (absent
    /// pages as zeros).
    static func copy(_ vmo: VmoPointer, _ bytes: UInt64, to phys: UInt64) {
        var offset: UInt64 = 0
        while offset < bytes {
            let n = Int(min(page, bytes - offset))
            let to = unsafe physmap(phys + offset)
            vmo.withContent(at: offset) { (source: UInt64?) in
                if let source {
                    unsafe to.copyMemory(from: physmap(source), byteCount: n)
                } else {
                    unsafe to.initializeMemory(as: UInt8.self, repeating: 0, count: n)
                }
            }
            offset += page
        }
    }

    /// Table pages for the boot page tables, from the handoff's run.
    struct Pool: PageTableMemory {
        var next: UInt64
        let end: UInt64

        mutating func allocateTable() -> UInt64? {
            guard next < end else { return nil }
            defer { next += WarmBoot.page }
            unsafe WarmBoot.physmap(next).initializeMemory(as: UInt8.self, repeating: 0, count: Int(WarmBoot.page))
            return next
        }

        func tableAddress(_ phys: UInt64) -> UInt { UInt(KernelLayout.physmap(phys)) }
    }

    /// Whether `type` is RAM the boot tables identity-map (the loader's
    /// MemoryMap.isRam, in croi's types).
    static func isRam(_ type: UInt32) -> Bool {
        switch type {
        case CROI_MEM_FREE, CROI_MEM_ACPI_RECLAIM, CROI_MEM_ACPI_NVS, CROI_MEM_FIRMWARE_RUNTIME, CROI_MEM_PERSISTENT,
             CROI_MEM_KERNEL, CROI_MEM_HANDOFF, CROI_MEM_BOOTFS:
            return true
        default:
            return false
        }
    }

    /// A new KASLR base for an image of `size` bytes, in no 2 MiB of this
    /// kernel's own (whose trampoline page the new tables map too).
    static func base(size: UInt64, randomized: Bool, link: UInt64) throws(Status) -> UInt64 {
        let align = CROI_KASLR_ALIGN
        let old = bootHandoff.kernel_virt & ~(align - 1)
        let oldEnd = (bootHandoff.kernel_virt + bootHandoff.kernel_size + align - 1) & ~(align - 1)
        func clear(_ base: UInt64) -> Bool { base + ((size + align - 1) & ~(align - 1)) <= old || base >= oldEnd }
        guard randomized else {
            guard clear(link) else { throw .notSupported }  // croi.kaslr=off, and this kernel is at the link address
            return link
        }
        let slots = (CROI_KASLR_SIZE - ((size + align - 1) & ~(align - 1))) / align + 1
        var slot = Random.word() % slots
        for _ in 0..<slots {
            let base = CROI_KASLR_BASE + slot * align
            if clear(base) { return base }
            slot = (slot + 1) % slots
        }
        throw .noMemory
    }

    /// Whether `text` holds the word `word` (bytes, space separated).
    static func has(_ text: UnsafeRawBufferPointer, _ word: StaticString) -> Bool {
        let w = unsafe UnsafeRawBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
        var i = 0
        while i < text.count {
            var j = i
            while j < text.count, unsafe text[j] != 0x20, unsafe text[j] != 0 { j += 1 }
            if j - i == w.count, unsafe (0..<w.count).allSatisfy({ unsafe text[i + $0] == w[$0] }) { return true }
            i = j + 1
        }
        return false
    }

    /// The new memory map at `out` (room for `capacity`): the saved one,
    /// the loader's and this kernel's ranges free again, the new runs
    /// overlaid, sorted, adjacent same-type ranges merged. Its count.
    static func memoryMap(into out: UnsafeMutablePointer<croi_mem_range_t>, capacity: Int,
                          overlays: InlineArray<3, croi_mem_range_t>) -> Int {
        var count = 0
        func add(_ base: UInt64, _ size: UInt64, _ type: UInt32) {
            guard size > 0, count < capacity else { return }
            unsafe out[count] = croi_mem_range_t(base: base, size: size, type: type, reserved: 0)
            count += 1
        }
        let from = unsafe physmap(saved).assumingMemoryBound(to: croi_mem_range_t.self)
        for i in 0..<savedRanges {
            let r = unsafe from[i]
            let type = r.type == CROI_MEM_KERNEL || r.type == CROI_MEM_HANDOFF || r.type == CROI_MEM_BOOTFS
                ? CROI_MEM_FREE : r.type
            // What of it no overlay covers (they lie in free RAM).
            var at = r.base
            let end = r.base + r.size
            while at < end {
                var next = end
                var skip: UInt64 = 0
                for o in 0..<overlays.count where overlays[o].size > 0 {
                    let ob = overlays[o].base, oe = ob + overlays[o].size
                    if ob <= at && at < oe { skip = max(skip, oe) }
                    if ob > at && ob < next { next = ob }
                }
                if skip > 0 {
                    at = min(skip, end)
                    continue
                }
                add(at, next - at, type)
                at = next
            }
        }
        for o in 0..<overlays.count { add(overlays[o].base, overlays[o].size, overlays[o].type) }
        // Sorted by base (insertion: a few hundred at most), then merged.
        for i in 1..<max(count, 1) {
            let item = unsafe out[i]
            var j = i - 1
            while j >= 0, unsafe out[j].base > item.base {
                unsafe out[j + 1] = out[j]
                j -= 1
            }
            unsafe out[j + 1] = item
        }
        var merged = 0
        for i in 0..<count {
            let r = unsafe out[i]
            if merged > 0, unsafe out[merged - 1].type == r.type, unsafe out[merged - 1].base + out[merged - 1].size == r.base {
                unsafe out[merged - 1].size += r.size
            } else {
                unsafe out[merged] = r
                merged += 1
            }
        }
        return merged
    }

    /// The warm boot itself: returns only by throwing, with nothing
    /// stopped.
    static func boot(kernel: VmoPointer, bootfs: VmoPointer, cmdline: VmoPointer?, started: UInt64) throws(Status) -> Never {
        #if !arch(x86_64)
        throw .notSupported
        #else
        guard saved != 0 else { throw .notSupported }
        let kernelBytes = ContentSize.of(kernel), bootfsBytes = ContentSize.of(bootfs)
        let commandBytes = cmdline.map { ContentSize.of($0) } ?? 0
        guard kernelBytes > 0, kernelBytes <= 64 << 20, bootfsBytes > 0, commandBytes <= 4096 else { throw .invalidArgs }

        // The ELF, in a run of its own to parse and load from.
        guard let file = pmm.allocateContiguous(pages(kernelBytes)) else { throw .noMemory }
        copy(kernel, kernelBytes, to: file)
        let fileSpan = unsafe RawSpan(_unsafeStart: physmap(file), byteCount: Int(kernelBytes))
        let elf: ElfImage
        do throws(ElfImage.Error) { elf = try ElfImage(parsing: fileSpan) } catch { throw .invalidArgs }
        guard elf.kind == .pie, elf.size % page == 0 else { throw .invalidArgs }

        // The command line: the one given, else this boot's.
        let commandRun = commandBytes > 0 ? commandBytes : UInt64(savedCmdline)
        let commandFrom = saved + UInt64(savedRanges * rangeSize)
        var commandText = InlineArray<4096, UInt8>(repeating: 0)
        if commandBytes > 0, let cmdline {
            guard let scratch = pmm.allocatePage() else { throw .noMemory }
            copy(cmdline, commandBytes, to: scratch)
            for i in 0..<Int(commandBytes) { commandText[i] = unsafe physmap(scratch).load(fromByteOffset: i, as: UInt8.self) }
            pmm.free(scratch)
        } else {
            for i in 0..<savedCmdline { commandText[i] = unsafe physmap(commandFrom).load(fromByteOffset: i, as: UInt8.self) }
        }
        let kaslrOff = commandText.span.withUnsafeBytes { unsafe has(UnsafeRawBufferPointer(rebasing: $0[0..<Int(commandRun)]), "croi.kaslr=off") }

        // The image, at its new base.
        let base = try base(size: elf.size, randomized: !kaslrOff, link: elf.base)
        guard let image = pmm.allocateContiguous(elf.size / page) else { throw .noMemory }
        var imageSpan = unsafe MutableRawSpan(_unsafeStart: physmap(image), byteCount: Int(elf.size))
        do throws(ElfImage.Error) { try elf.load(from: fileSpan, into: &imageSpan, runningAt: base) } catch { throw .invalidArgs }
        let entry = base + (elf.entry - elf.base)

        // The bootfs.
        guard let bootfsRun = pmm.allocateContiguous(pages(bootfsBytes)) else { throw .noMemory }
        copy(bootfs, bootfsBytes, to: bootfsRun)

        // The handoff run: the block, its ranges, the command line, then
        // the table pages.
        let rangeCapacity = savedRanges + 8
        let rangesOffset = UInt64(MemoryLayout<croi_handoff_t>.size)
        let commandOffset = rangesOffset + UInt64(rangeCapacity * rangeSize)
        let dataPages = pages(commandOffset + commandRun)
        let tablePages: UInt64 = 256
        guard let handoffRun = pmm.allocateContiguous(dataPages + tablePages) else { throw .noMemory }
        unsafe physmap(handoffRun).initializeMemory(as: UInt8.self, repeating: 0, count: Int(dataPages * page))
        commandText.span.withUnsafeBytes { unsafe (physmap(handoffRun) + Int(commandOffset)).copyMemory(from: $0.baseAddress!, byteCount: Int(commandRun)) }

        // The memory map.
        var overlays = InlineArray<3, croi_mem_range_t>(repeating: croi_mem_range_t())
        overlays[0] = croi_mem_range_t(base: image, size: elf.size, type: CROI_MEM_KERNEL, reserved: 0)
        overlays[1] = croi_mem_range_t(base: bootfsRun, size: pages(bootfsBytes) * page, type: CROI_MEM_BOOTFS, reserved: 0)
        overlays[2] = croi_mem_range_t(base: handoffRun, size: (dataPages + tablePages) * page, type: CROI_MEM_HANDOFF,
                                       reserved: 0)
        let ranges = unsafe (physmap(handoffRun) + Int(rangesOffset)).assumingMemoryBound(to: croi_mem_range_t.self)
        let rangeCount = unsafe memoryMap(into: ranges, capacity: rangeCapacity, overlays: overlays)

        // The boot page tables: all RAM identity mapped, the image W^X at
        // its base, the UART, and this kernel's trampoline where it is.
        var tables: PageTableBuilder<Pool>
        do throws(MapError) {
            tables = try PageTableBuilder(memory: Pool(next: handoffRun + dataPages * page,
                                                       end: handoffRun + (dataPages + tablePages) * page))
            var runStart: UInt64 = 0, runEnd: UInt64 = 0
            for i in 0..<rangeCount {
                let r = unsafe ranges[i]
                guard isRam(r.type), r.base < PageTableFormat.identityLimit else { continue }
                let end = min(r.base + r.size, PageTableFormat.identityLimit)
                if r.base == runEnd {
                    runEnd = end
                    continue
                }
                if runEnd > runStart {
                    try tables.map(virt: runStart, phys: runStart, size: runEnd - runStart,
                                   MapAttributes(writable: true, executable: true))
                }
                runStart = r.base
                runEnd = end
            }
            if runEnd > runStart {
                try tables.map(virt: runStart, phys: runStart, size: runEnd - runStart, MapAttributes(writable: true, executable: true))
            }
            for i in 0..<elf.segmentCount {
                let s = elf.segments[i]
                try tables.map(virt: base + (s.vaddr - elf.base), phys: image + (s.vaddr - elf.base),
                               size: (s.memsz + page - 1) & ~(page - 1),
                               MapAttributes(writable: s.writable, executable: s.executable, global: true))
            }
            let uart = bootHandoff.uart
            if uart.kind == CROI_UART_NS16550_MMIO || uart.kind == CROI_UART_PL011 {
                let at = uart.base & ~(page - 1)
                try tables.map(virt: at, phys: at, size: page, MapAttributes(writable: true, cache: .device))
            }
            let trampoline = arch_warmboot_address()
            try tables.map(virt: trampoline, phys: bootHandoff.kernel_phys + (trampoline - bootHandoff.kernel_virt), size: page,
                           MapAttributes(executable: true))
        } catch {
            throw .noMemory
        }

        // The handoff: the boot's, with the new image, bootfs, map,
        // command line and entropy.
        var handoff = bootHandoff
        handoff.kernel_phys = image
        handoff.kernel_virt = base
        handoff.kernel_size = elf.size
        handoff.memory_map = handoffRun + rangesOffset
        handoff.memory_map_count = UInt64(rangeCount)
        handoff.bootfs = bootfsRun
        handoff.bootfs_size = bootfsBytes
        handoff.cmdline = commandRun > 0 ? handoffRun + commandOffset : 0
        handoff.cmdline_size = commandRun
        handoff.entropy = (Random.word(), Random.word(), Random.word(), Random.word())
        handoff.entropy_size = 32
        unsafe physmap(handoffRun).storeBytes(of: handoff, as: croi_handoff_t.self)

        // From the boot CPU, as firmware boots: the new kernel takes the
        // CPU it starts on for its boot CPU and starts the others, which
        // must not include firmware's boot CPU (its APIC's BSP bit, CPU 0's
        // record). This thread moves there first.
        Scheduler.applyProfile(Scheduler.current, weight: nil, context: nil, affinity: 1)
        for _ in 0..<100 where Cpu.current != 0 { Scheduler.sleep(until: Clock.now() + 1_000_000) }  // a wakeup moves it
        guard Cpu.current == 0 else { throw .badState }

        // No way back from here.
        let (draining, drained, stopped) = Power.leave()
        LocalApic.quiesceThisCpu()
        Vtd.turnOff()
        Amdvi.turnOff()
        if let console = panicConsole {
            console.write("croi kernel: warm boot, ")
            console.write(decimal: UInt64(stopped))
            console.write(" other CPUs stopped, into a new kernel at ")
            console.write(hex: base)
            console.write("\n")
            Budgets.report(console, "power.warmboot_kernel", (draining - started) + (Clock.now() - drained))
            console.drain(patience: 100_000_000)
        }
        arch_warmboot_enter(tables.rootLow, tables.rootHigh, entry, handoffRun)
        #endif
    }
}
