/// Where a `PageTableBuilder` gets its table pages from and how it reaches
/// them: firmware pages through the identity map in the loader, early boot
/// pages through the identity map or the physmap in the kernel.
public protocol PageTableMemory {
    /// A zeroed, page-aligned physical page for a new table, or nil.
    mutating func allocateTable() -> UInt64?
    /// The address the table at physical `phys` can be accessed at now.
    func tableAddress(_ phys: UInt64) -> UInt
}

public enum MapError: Error {
    case unaligned(UInt64)
    case overlap(UInt64)
    case outOfMemory
}

/// Builds page tables in `Format`'s entries: this architecture's
/// (`PageTableFormat`, through the `PageTableBuilder` alias) or another
/// layout that conforms to `PageTableLayout` (the GPU's, `GPUPageTable`).
public struct FormattedPageTableBuilder<Memory: PageTableMemory, Format: PageTableLayout> {
    public var memory: Memory

    /// Root for the low half (and everything, except on arm64).
    public let rootLow: UInt64
    /// Root for the high half: TTBR1 on arm64, the same table elsewhere.
    public let rootHigh: UInt64

    @inlinable
    public init(memory: Memory) throws(MapError) {
        var memory = memory
        guard let low = memory.allocateTable() else { throw .outOfMemory }
        let high: UInt64
        if Format.hasHighRoot {
            guard let table = memory.allocateTable() else { throw .outOfMemory }
            high = table
        } else {
            high = low
        }
        self.memory = memory
        rootLow = low
        rootHigh = high
    }

    /// Maps [virt, virt+size) to [phys, phys+size) using the largest pages
    /// that fit. All three must be page aligned; overlaps are an error.
    @inlinable
    public mutating func map(virt: UInt64, phys: UInt64, size: UInt64, _ attributes: MapAttributes) throws(MapError) {
        let pageSize = Format.pageSize(level: Format.levels - 1)
        guard virt % pageSize == 0, phys % pageSize == 0, size % pageSize == 0 else {
            throw .unaligned(virt)
        }
        var virt = virt, phys = phys, left = size
        while left > 0 {
            var level = Format.levels - 1
            for candidate in 0..<Format.levels where Format.leafAllowed(level: candidate) {
                let page = Format.pageSize(level: candidate)
                if virt % page == 0, phys % page == 0, left >= page {
                    level = candidate
                    break
                }
            }
            try mapOne(virt: virt, phys: phys, level: level, attributes)
            let page = Format.pageSize(level: level)
            virt &+= page
            phys += page
            left -= page
        }
    }

    @inlinable
    mutating func mapOne(virt: UInt64, phys: UInt64, level: Int, _ attributes: MapAttributes) throws(MapError) {
        var table = virt >> 63 != 0 ? rootHigh : rootLow
        for walk in 0..<level {
            let slot = unsafe entries(table) + Format.index(virt, level: walk)
            let entry = unsafe slot.pointee
            if Format.isPresent(entry) {
                guard Format.isTable(entry, level: walk) else { throw .overlap(virt) }
                table = Format.address(entry)
            } else {
                guard let next = memory.allocateTable() else { throw .outOfMemory }
                unsafe slot.pointee = Format.table(next)
                table = next
            }
        }
        let slot = unsafe entries(table) + Format.index(virt, level: level)
        guard unsafe !Format.isPresent(slot.pointee) else { throw .overlap(virt) }
        unsafe slot.pointee = Format.leaf(phys, level: level, attributes)
    }

    /// Unmaps [virt, virt+size): both page aligned. A large page the range
    /// covers only part of is split into the next level's pages first
    /// (the GPU's unmaps need it); a hole in the range is skipped. Tables
    /// left empty are kept.
    @inlinable
    public mutating func unmap(virt: UInt64, size: UInt64) throws(MapError) {
        let smallest = Format.pageSize(level: Format.levels - 1)
        guard virt % smallest == 0, size % smallest == 0 else { throw .unaligned(virt) }
        var virt = virt, left = size
        while left > 0 {
            var table = virt >> 63 != 0 ? rootHigh : rootLow
            var level = 0
            var step = smallest
            while true {
                let slot = unsafe entries(table) + Format.index(virt, level: level)
                let entry = unsafe slot.pointee
                guard Format.isPresent(entry) else {
                    step = Format.pageSize(level: level)
                    step -= virt % step
                    break
                }
                if Format.isTable(entry, level: level) {
                    table = Format.address(entry)
                    level += 1
                    continue
                }
                let page = Format.pageSize(level: level)
                if virt % page == 0, left >= page {
                    unsafe slot.pointee = 0
                    step = page
                    break
                }
                // Part of a large page: split it, then look again.
                guard let next = memory.allocateTable() else { throw .outOfMemory }
                let attributes = Format.attributes(entry, level: level)
                let base = Format.leafAddress(entry, level: level)
                let child = Format.pageSize(level: level + 1)
                let children = unsafe entries(next)
                for i in 0..<Int(page / child) {
                    unsafe children[i] = Format.leaf(base + UInt64(i) * child, level: level + 1, attributes)
                }
                unsafe slot.pointee = Format.table(next)
                table = next
                level += 1
            }
            step = min(step, left)
            virt &+= step
            left -= step
        }
    }

    @inlinable
    func entries(_ table: UInt64) -> UnsafeMutablePointer<UInt64> {
        unsafe UnsafeMutablePointer(bitPattern: memory.tableAddress(table))!
    }
}

/// The builder for this architecture's own format: the loader's and the
/// kernel's.
public typealias PageTableBuilder<Memory: PageTableMemory> = FormattedPageTableBuilder<Memory, PageTableFormat>
