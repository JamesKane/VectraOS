// SPDX-License-Identifier: BSD-3-Clause

// The page tables of an Arm Mali CSF GPU's MMU, as a `PageTableLayout` for
// `FormattedPageTableBuilder` (chinese-wall's panthor 04 §4.6 and §4.7, and
// 05 §5.3): AArch64 stage-1 descriptors, 4 KiB granule, one range from VA 0.
// 4 KiB pages at the last level and 2 MiB blocks at the one above; 1 GiB
// blocks are never made. Pure Swift, so the same code is the driver's and
// the host tests'.
//
// `levels` is a static constant of the layout, so a depth is a type:
// `GPUPageTable` for 40 to 48 VA bits (4 levels), and `GPUPageTable39` for
// up to 39 (3 levels, as the MCU's 32 bits needs). The descriptors are one
// code in `GPUDescriptor`, the two types only name the depth.

/// The descriptors, whatever the depth.
public enum GPUDescriptor {
    static let valid: UInt64 = 1 << 0
    static let tableOrPage: UInt64 = 1 << 1
    static let accessPermission1: UInt64 = 1 << 6  // AP[1]: always set
    static let readOnly: UInt64 = 1 << 7  // AP[2]
    static let accessFlag: UInt64 = 1 << 10
    static let notGlobal: UInt64 = 1 << 11
    static let privilegedNoExecute: UInt64 = 1 << 53
    static let executeNever: UInt64 = 1 << 54
    static let addressMask: UInt64 = 0x0000_FFFF_FFFF_F000

    /// The attribute index of a cache policy: 1 for cached mappings (write-back),
    /// 0 for the rest (non-cacheable).
    public static func attrIndex(_ cache: CachePolicy) -> UInt64 { cache == .cached ? 1 : 0 }

    public static func table(_ phys: UInt64) -> UInt64 { phys & addressMask | valid | tableOrPage }

    /// A leaf: a page at `last` (the final level), a block at the level above.
    public static func leaf(_ phys: UInt64, isPage: Bool, _ a: MapAttributes) -> UInt64 {
        var e = phys & addressMask | valid | accessPermission1 | accessFlag | notGlobal
        if isPage { e |= tableOrPage }
        if a.cache == .cached {
            e |= attrIndex(.cached) << 2 | 3 << 8  // inner shareable
        } else {
            e |= attrIndex(a.cache) << 2 | 2 << 8  // outer shareable
        }
        if !a.writable { e |= readOnly }
        if !a.executable { e |= privilegedNoExecute | executeNever }
        return e
    }

    public static func attributes(_ e: UInt64) -> MapAttributes {
        MapAttributes(writable: e & readOnly == 0, executable: e & executeNever == 0,
                      cache: e >> 2 & 7 == 1 ? .cached : .uncached)
    }
}

/// Four levels (the root's 512 entries cover 48 VA bits).
public enum GPUPageTable: PageTableLayout {
    @inlinable public static var levels: Int { 4 }
    @inlinable public static var hasHighRoot: Bool { false }
    /// Blocks only at level 2; 1 GiB blocks are never made.
    @inlinable public static func leafAllowed(level: Int) -> Bool { level >= levels - 2 }
    @inlinable public static func table(_ phys: UInt64) -> UInt64 { GPUDescriptor.table(phys) }
    @inlinable public static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        GPUDescriptor.leaf(phys, isPage: level == levels - 1, a)
    }
    @inlinable public static func isPresent(_ e: UInt64) -> Bool { e & 1 != 0 }
    @inlinable public static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && level < levels - 1 && e & 2 != 0
    }
    @inlinable public static func address(_ e: UInt64) -> UInt64 { e & 0x0000_FFFF_FFFF_F000 }
    @inlinable public static func attributes(_ e: UInt64, level: Int) -> MapAttributes { GPUDescriptor.attributes(e) }
}

/// Three levels: up to 39 VA bits, the MCU's 32 among them (a root of 4
/// entries; the table is still a page).
public enum GPUPageTable39: PageTableLayout {
    @inlinable public static var levels: Int { 3 }
    @inlinable public static var hasHighRoot: Bool { false }
    @inlinable public static func leafAllowed(level: Int) -> Bool { level >= levels - 2 }
    @inlinable public static func table(_ phys: UInt64) -> UInt64 { GPUDescriptor.table(phys) }
    @inlinable public static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        GPUDescriptor.leaf(phys, isPage: level == levels - 1, a)
    }
    @inlinable public static func isPresent(_ e: UInt64) -> Bool { e & 1 != 0 }
    @inlinable public static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && level < levels - 1 && e & 2 != 0
    }
    @inlinable public static func address(_ e: UInt64) -> UInt64 { e & 0x0000_FFFF_FFFF_F000 }
    @inlinable public static func attributes(_ e: UInt64, level: Int) -> MapAttributes { GPUDescriptor.attributes(e) }
}

/// The values the driver writes to an address space's registers.
public enum GPUAddressSpace {
    /// The table depth for `vaBits` (MMU_FEATURES[7:0]): ceil((bits - 12) / 9).
    public static func levels(vaBits: Int) -> Int { (vaBits - 12 + 8) / 9 }

    /// AS_MEMATTR's entry for a MAIR byte (panthor 04 §4.7.2): write-back on
    /// both levels is memory type 2 with explicit allocation, its hints the
    /// inner nibble's, and shareability 0 (GPU-internal) or, when coherent,
    /// 1 (the CPU's inner domain); anything else is non-cacheable, 0x4C.
    public static func memAttrEntry(mair: UInt8, coherent: Bool) -> UInt8 {
        let outer = mair >> 4, inner = mair & 0xF
        guard outer & 3 != 0, outer & 4 != 0, inner & 4 != 0 else { return 0x4C }
        let writeAllocate = inner & 1, readAllocate = inner >> 1 & 1
        return 2 << 6 | (coherent ? 1 : 0) << 4 | 3 << 2 | readAllocate << 1 | writeAllocate
    }

    /// The MAIR the page tables' attribute indices mean (04 §4.7.1): 0 non-cacheable,
    /// 1 write-back with both allocates, 2 device (never used), 3 inner
    /// non-cacheable and outer write-back (never used), the rest unset.
    public static let mair: [UInt8] = [0x44, 0xFF, 0x04, 0xF4, 0, 0, 0, 0]

    /// AS_MEMATTR: byte i is the entry of MAIR index i. 0x4C4C4C4C_8C4C8F4C
    /// when not coherent, 0x4C4C4C4C_9C4C9F4C when coherent (05 §5.3.3).
    public static func memAttr(coherent: Bool) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(memAttrEntry(mair: mair[i], coherent: coherent)) << UInt64(8 * i)
        }
        return value
    }

    /// AS_TRANSCFG (04 §4.3.1, 05 §5.3.2): ADRMODE 6, INA_BITS = 55 - VA
    /// bits, walks write-back and read-allocating, outer shareable when
    /// coherent. 0x4200_01C6 for 48 bits, 0x6200_01C6 when coherent.
    public static func transCfg(vaBits: Int, coherent: Bool) -> UInt64 {
        let ina = UInt64(55 - vaBits) & 0x1F
        let sh: UInt64 = coherent ? 2 : 0
        return 6 | ina << 6 | 2 << 24 | sh << 28 | 1 << 30
    }

    /// AS_TRANSCFG of a disabled slot (04 §4.3.2): ADRMODE unmapped.
    public static let transCfgUnmapped: UInt64 = 1
}
