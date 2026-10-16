// The program's own ELF image as loaded: where its PT_GNU_RELRO pages are
// and whether the loader made them read only (the suites and m2 check
// both). The header is the floor's td_image_header (__ehdr_start).

import CroiRuntime

enum Image {
    /// This program's PT_GNU_RELRO pages as loaded (run addresses, page
    /// rounded as loaders protect them); nil if it has none.
    static func relro() -> (start: UInt64, end: UInt64)? {
        guard let header = unsafe td_image_header() else { return nil }
        let phoff = unsafe header.loadUnaligned(fromByteOffset: 32, as: UInt64.self)
        let phentsize = unsafe Int(header.loadUnaligned(fromByteOffset: 54, as: UInt16.self))
        let phnum = unsafe Int(header.loadUnaligned(fromByteOffset: 56, as: UInt16.self))
        // The load bias: where the header is less the link address of the
        // segment that starts at file offset 0 (0 for an ET_EXEC).
        var bias: UInt64? = nil
        var range: (vaddr: UInt64, memsz: UInt64)? = nil
        for i in 0..<phnum {
            let ph = unsafe header + Int(phoff) + i * phentsize
            let type = unsafe ph.loadUnaligned(as: UInt32.self)
            if type == 1, bias == nil, unsafe ph.loadUnaligned(fromByteOffset: 8, as: UInt64.self) == 0 {  // PT_LOAD
                bias = unsafe UInt64(UInt(bitPattern: header)) &- ph.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            }
            if type == 0x6474_E552 {  // PT_GNU_RELRO
                range = unsafe (ph.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                                ph.loadUnaligned(fromByteOffset: 40, as: UInt64.self))
            }
        }
        guard let bias, let range else { return nil }
        let start = (bias &+ range.vaddr) & ~4095
        let end = (bias &+ range.vaddr &+ range.memsz) & ~4095
        return end > start ? (start, end) : nil
    }

    /// Whether the loader made those pages read only: 1, 0 if any is
    /// writable (or not mapped), -1 if there are none or the maps can't be
    /// read.
    static func relroReadOnly() -> Int {
        guard let (start, end) = relro(), td_runtime_process_self != 0 else { return -1 }
        let capacity = 64
        let maps = UnsafeMutablePointer<croi_info_maps_t>.allocate(capacity: capacity)
        defer { unsafe maps.deallocate() }
        var counts = InlineArray<2, Int>(repeating: 0)  // actual, available
        let status = unsafe withUnsafeMutablePointer(to: &counts) { p in
            let words = unsafe UnsafeMutableRawPointer(p).assumingMemoryBound(to: Int.self)
            return unsafe croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(td_runtime_process_self),
                                        UInt64(CROI_INFO_PROCESS_MAPS), UInt64(UInt(bitPattern: maps)),
                                        UInt64(capacity * MemoryLayout<croi_info_maps_t>.stride),
                                        UInt64(UInt(bitPattern: words)), UInt64(UInt(bitPattern: words + 1)))
        }
        guard status == 0 else { return -1 }
        let actual = counts[0]
        // Every RELRO page in a mapping without WRITE, all of them covered.
        var covered: UInt64 = 0
        for i in 0..<actual {
            let map = unsafe maps[i]
            guard map.type == UInt32(CROI_INFO_MAPS_TYPE_MAPPING) else { continue }
            let lo = map.base, hi = map.base + map.size
            guard hi > start, lo < end else { continue }
            if unsafe map.u.mapping.mmu_flags & UInt32(CROI_VM_PERM_WRITE) != 0 { return 0 }
            covered += min(hi, end) - max(lo, start)
        }
        return covered == end - start ? 1 : 0
    }
}
