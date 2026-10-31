/// The ACPI tables a Platform makes (ACPI 6.6): an RSDP and its XSDT, a
/// hardware-reduced FADT and an empty DSDT, the MADT (a RINTC per hart and
/// the PLIC), the RHCT (timebase, ISA string, CMO and MMU nodes, a hart
/// info node per hart) and, with a console, the SPCR. Written into one
/// buffer at a known physical address, which the tables' pointers use.
extension Platform {
    /// Bytes `writeTables` needs.
    public var tablesSize: Int {
        let rhct = layoutRhct()
        return Layout(self, rhctSize: rhct.size).end
    }

    /// Writes the tables into `buffer`, which is at physical `address`,
    /// and returns the RSDP's offset in it; nil if the buffer is too small
    /// or the platform has no harts or PLIC.
    public func writeTables(into buffer: inout MutableRawSpan, at address: UInt64) -> Int? {
        let rhct = layoutRhct()
        let layout = Layout(self, rhctSize: rhct.size)
        guard hartCount > 0, plic != nil, layout.end <= buffer.byteCount else { return nil }
        for i in 0..<layout.end { buffer.storeBytes(of: 0, toByteOffset: i, as: UInt8.self) }
        var w = Writer()

        // RSDP (ACPI 2.0+): signature, checksum of the first 20 bytes,
        // OEM ID, revision 2, no RSDT, length, the XSDT, extended checksum.
        w.put(&buffer, layout.rsdp, "RSD PTR ")
        w.oemId(&buffer, layout.rsdp + 9)
        w.put8(&buffer, layout.rsdp + 15, 2)
        w.put32(&buffer, layout.rsdp + 20, 36)
        w.put64(&buffer, layout.rsdp + 24, address + UInt64(layout.xsdt))
        w.checksum(&buffer, layout.rsdp, 20, at: layout.rsdp + 8)
        w.checksum(&buffer, layout.rsdp, 36, at: layout.rsdp + 32)

        var entries = InlineArray<4, Int>(repeating: 0)
        var count = 0
        for t in [layout.fadt, layout.madt, layout.rhct, layout.spcr] as InlineArray<4, Int> where t != 0 {
            entries[count] = t
            count += 1
        }
        w.header(&buffer, layout.xsdt, "XSDT", length: 36 + 8 * count, revision: 1, boardId)
        for i in 0..<count { w.put64(&buffer, layout.xsdt + 36 + 8 * i, address + UInt64(entries[i])) }
        w.finish(&buffer, layout.xsdt, 36 + 8 * count)

        // FADT 6.5: hardware reduced (flags bit 20); the DSDT, also in the
        // 32-bit field when it fits.
        let dsdt = address + UInt64(layout.dsdt)
        w.header(&buffer, layout.fadt, "FACP", length: 276, revision: 6, boardId)
        if dsdt <= UInt64(UInt32.max) { w.put32(&buffer, layout.fadt + 40, UInt32(dsdt)) }
        w.put32(&buffer, layout.fadt + 112, 1 << 20)
        w.put8(&buffer, layout.fadt + 131, 5)
        w.put64(&buffer, layout.fadt + 140, dsdt)
        w.finish(&buffer, layout.fadt, 276)

        w.header(&buffer, layout.dsdt, "DSDT", length: 36, revision: 2, boardId)
        w.finish(&buffer, layout.dsdt, 36)

        writeMadt(&buffer, &w, layout.madt, layout.madtSize)
        writeRhct(&buffer, &w, layout.rhct, rhct)
        if layout.spcr != 0, let uart { writeSpcr(&buffer, &w, layout.spcr, uart) }
        return layout.rsdp
    }

    // MARK: MADT

    /// A RINTC (type 0x18, 36 bytes) per hart, its external interrupt
    /// controller ID the PLIC's (ID 0) context; then the PLIC (0x1B).
    private func writeMadt(_ b: inout MutableRawSpan, _ w: inout Writer, _ at: Int, _ size: Int) {
        w.header(&b, at, "APIC", length: size, revision: 6, boardId)
        var e = at + 44
        for i in 0..<hartCount {
            w.put8(&b, e, 0x18)
            w.put8(&b, e + 1, 36)
            w.put8(&b, e + 2, 1)
            w.put32(&b, e + 4, 1)  // enabled
            w.put64(&b, e + 8, harts[i].id)
            w.put32(&b, e + 16, UInt32(i))
            w.put32(&b, e + 20, harts[i].context == .max ? .max : harts[i].context & 0xFFFF)
            e += 36
        }
        if let plic {
            w.put8(&b, e, 0x1B)
            w.put8(&b, e + 1, 36)
            w.put8(&b, e + 2, 1)
            w.put16(&b, e + 12, plic.sources)
            w.put16(&b, e + 14, plic.maxPriority)
            w.put32(&b, e + 20, UInt32(truncatingIfNeeded: plic.size))
            w.put64(&b, e + 24, plic.base)
        }
        w.finish(&b, at, size)
    }

    // MARK: RHCT

    struct RhctLayout {
        var size = 0
        var isa = 0
        var isaLength = 0
        var cmo = 0
        var mmu = 0
        var hartInfo = 0
        var hartInfoLength = 0
        var nodes = 0
    }

    /// Node offsets within the RHCT: the ISA string node (its string
    /// NUL-terminated, the node padded to an even length), the CMO node if
    /// the block size is known, the MMU node if the type is, then a hart
    /// info node per hart naming them.
    func layoutRhct() -> RhctLayout {
        var r = RhctLayout()
        var at = 56
        r.isa = at
        r.isaLength = 8 + ((isaCount + 1 + 1) & ~1)
        at += r.isaLength
        var perHart = 1
        if cmoBlockLog2 != 0 {
            r.cmo = at
            at += 10
            perHart += 1
        }
        if mmuType != nil {
            r.mmu = at
            at += 8
            perHart += 1
        }
        r.hartInfo = at
        r.hartInfoLength = 12 + 4 * perHart
        at += r.hartInfoLength * hartCount
        r.nodes = perHart + hartCount
        r.size = at
        return r
    }

    private func writeRhct(_ b: inout MutableRawSpan, _ w: inout Writer, _ at: Int, _ r: RhctLayout) {
        w.header(&b, at, "RHCT", length: r.size, revision: 1, boardId)
        w.put64(&b, at + 40, timebase)
        w.put32(&b, at + 48, UInt32(r.nodes))
        w.put32(&b, at + 52, 56)

        w.node(&b, at + r.isa, type: 0, length: r.isaLength, revision: 1)
        w.put16(&b, at + r.isa + 6, UInt16(isaCount + 1))
        for i in 0..<isaCount { w.put8(&b, at + r.isa + 8 + i, isa[i]) }
        if r.cmo != 0 {
            w.node(&b, at + r.cmo, type: 1, length: 10, revision: 1)
            w.put8(&b, at + r.cmo + 7, cmoBlockLog2)  // CBOM
            w.put8(&b, at + r.cmo + 8, cmoBlockLog2)  // CBOP
            w.put8(&b, at + r.cmo + 9, cmoBlockLog2)  // CBOZ
        }
        if let mmuType, r.mmu != 0 {
            w.node(&b, at + r.mmu, type: 2, length: 8, revision: 1)
            w.put8(&b, at + r.mmu + 7, mmuType)
        }
        for i in 0..<hartCount {
            let node = at + r.hartInfo + i * r.hartInfoLength
            w.node(&b, node, type: 0xFFFF, length: r.hartInfoLength, revision: 1)
            var offsets = 0
            for o in [r.isa, r.cmo, r.mmu] as InlineArray<3, Int> where o != 0 {
                w.put32(&b, node + 12 + 4 * offsets, UInt32(o))
                offsets += 1
            }
            w.put16(&b, node + 6, UInt16(offsets))
            w.put32(&b, node + 8, UInt32(i))
        }
        w.finish(&b, at, r.size)
    }

    // MARK: SPCR

    /// SPCR 2: a 16550 described by its Generic Address Structure (0x12),
    /// at 115200 baud, interrupting through the PLIC if the tree says how.
    private func writeSpcr(_ b: inout MutableRawSpan, _ w: inout Writer, _ at: Int, _ uart: Uart) {
        w.header(&b, at, "SPCR", length: 80, revision: 2, boardId)
        w.put8(&b, at + 36, 0x12)
        w.put8(&b, at + 40, 0)                              // system memory
        w.put8(&b, at + 41, uart.width == 4 ? 32 : 8)       // register bit width
        w.put8(&b, at + 43, uart.width == 4 ? 3 : 1)        // dword or byte access
        w.put64(&b, at + 44, uart.base)
        if uart.gsi != 0 {
            w.put8(&b, at + 52, 0x10)                       // RISC-V PLIC
            w.put32(&b, at + 54, uart.gsi)
        }
        w.put8(&b, at + 58, 7)                              // 115200
        w.put16(&b, at + 64, 0xFFFF)                        // not PCI
        w.put16(&b, at + 66, 0xFFFF)
        w.finish(&b, at, 80)
    }
}

/// Where each table goes, 16-byte aligned, the RSDP first.
struct Layout {
    var rsdp = 0, xsdt = 0, fadt = 0, dsdt = 0, madt = 0, madtSize = 0, rhct = 0, spcr = 0, end = 0

    init(_ p: borrowing Platform, rhctSize: Int) {
        madtSize = 44 + 36 * p.hartCount + 36
        rsdp = 0
        xsdt = Self.next(rsdp, 36)
        fadt = Self.next(xsdt, 36 + 8 * 4)
        dsdt = Self.next(fadt, 276)
        madt = Self.next(dsdt, 36)
        rhct = Self.next(madt, madtSize)
        end = Self.next(rhct, rhctSize)
        if p.uart != nil {
            spcr = end
            end = Self.next(spcr, 80)
        }
    }

    static func next(_ at: Int, _ size: Int) -> Int { (at + size + 15) & ~15 }
}

/// Little-endian stores and the tables' common parts.
struct Writer {
    func put8(_ b: inout MutableRawSpan, _ at: Int, _ v: UInt8) { b.storeBytes(of: v, toByteOffset: at, as: UInt8.self) }
    func put16(_ b: inout MutableRawSpan, _ at: Int, _ v: UInt16) {
        b.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt16.self)
    }
    func put32(_ b: inout MutableRawSpan, _ at: Int, _ v: UInt32) {
        b.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt32.self)
    }
    func put64(_ b: inout MutableRawSpan, _ at: Int, _ v: UInt64) {
        b.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt64.self)
    }

    func put(_ b: inout MutableRawSpan, _ at: Int, _ text: StaticString) {
        for i in 0..<text.utf8CodeUnitCount { put8(&b, at + i, unsafe text.utf8Start[i]) }
    }

    /// "VECTRA": the tables are ours, made from a devicetree.
    func oemId(_ b: inout MutableRawSpan, _ at: Int) { put(&b, at, "VECTRA") }

    /// The 36-byte header, checksum left for `finish`.
    func header(_ b: inout MutableRawSpan, _ at: Int, _ signature: StaticString, length: Int, revision: UInt8,
                _ tableId: InlineArray<8, UInt8>) {
        put(&b, at, signature)
        put32(&b, at + 4, UInt32(length))
        put8(&b, at + 8, revision)
        oemId(&b, at + 10)
        for i in 0..<8 { put8(&b, at + 16 + i, tableId[i]) }
        put32(&b, at + 24, 1)
        put(&b, at + 28, "VXDT")
        put32(&b, at + 32, 1)
    }

    /// An RHCT node's header: type, length, revision.
    func node(_ b: inout MutableRawSpan, _ at: Int, type: UInt16, length: Int, revision: UInt16) {
        put16(&b, at, type)
        put16(&b, at + 2, UInt16(length))
        put16(&b, at + 4, revision)
    }

    func finish(_ b: inout MutableRawSpan, _ at: Int, _ length: Int) { checksum(&b, at, length, at: at + 9) }

    /// Sets the byte at `at` so that `count` bytes from `start` sum to 0.
    func checksum(_ b: inout MutableRawSpan, _ start: Int, _ count: Int, at: Int) {
        put8(&b, at, 0)
        var sum: UInt8 = 0
        do {
            let bytes = b.bytes
            for i in 0..<count { sum &+= bytes.load(fromByteOffset: start + i, as: UInt8.self) }
        }
        put8(&b, at, 0 &- sum)
    }
}
