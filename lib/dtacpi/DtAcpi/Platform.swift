/// What the kernel needs to know about a RISC-V machine that its firmware
/// describes only by a devicetree, read from that tree: the harts, the
/// timebase, the ISA, the PLIC and the console UART. Tables.swift writes
/// it out as the ACPI tables the kernel reads on every other machine, so
/// the kernel stays ACPI-only (D51).
public struct Platform {
    public struct Hart {
        public var id: UInt64 = 0
        /// The PLIC context of the hart's S-mode external interrupt.
        public var context: UInt32 = .max
    }

    /// Where the ISA string came from.
    public enum IsaSource { case devicetree, knownCore, baseOnly }

    public struct Plic {
        public var base: UInt64
        public var size: UInt64
        public var sources: UInt16
        public var maxPriority: UInt16
    }

    public struct Uart {
        public var base: UInt64
        public var regShift: UInt8
        /// Register access width in bytes (1 or 4).
        public var width: UInt8
        /// Its PLIC source, 0 if the tree gives none.
        public var gsi: UInt32
        public var clock: UInt32
    }

    public static let maxHarts = 64

    public var harts = InlineArray<64, Hart>(repeating: Hart())
    public var hartCount = 0
    public var timebase: UInt64 = 0
    /// "rv64imafdc_zicsr_...", without a NUL.
    /// 2 KiB: QEMU's -cpu max lists 824 bytes of extensions.
    public var isa = InlineArray<2048, UInt8>(repeating: 0)
    public var isaCount = 0
    /// The ISA didn't fit: init fails rather than drop extensions.
    var isaOverflow = false
    public var isaSource = IsaSource.baseOnly
    /// The Zicbom/Zicbop/Zicboz block size, log2; 0 if unknown.
    public var cmoBlockLog2: UInt8 = 0
    /// RHCT's MMU type (0 Sv39, 1 Sv48, 2 Sv57), if the tree says.
    public var mmuType: UInt8?
    public var plic: Plic?
    public var uart: Uart?
    /// The root's first compatible, for the tables' OEM table ID.
    public var boardId = InlineArray<8, UInt8>(repeating: UInt8(ascii: " "))

    public init() {}

    /// Reads `fdt`. `vendor` and `architecture` (mvendorid and marchid,
    /// from SBI) pick a known core's ISA when the tree lists only base
    /// letters, as the Orange Pi RV2's U-Boot does. Nil without harts.
    public init?(_ fdt: borrowing Fdt, vendor: UInt64, architecture: UInt64) {
        guard let root = fdt.root, let cpus = fdt.node("/cpus") else { return nil }
        if let compatible = fdt.property(root, "compatible") {
            for i in 0..<min(8, compatible.count) {
                let b = fdt.byte(compatible.lowerBound + i)
                if b == 0 { break }
                boardId[i] = b
            }
        }
        var first: Int?
        fdt.forEachChild(of: cpus) { cpu in
            guard fdt.nameIs(cpu, "cpu"), fdt.isEnabled(cpu), hartCount < Self.maxHarts,
                  let id = fdt.reg(cpu)?.address
            else { return true }
            harts[hartCount] = Hart(id: id)
            hartCount += 1
            if first == nil { first = cpu }
            return true
        }
        guard let first else { return nil }
        timebase = fdt.u64(cpus, "timebase-frequency") ?? fdt.u64(first, "timebase-frequency") ?? 0
        if let mmu = fdt.property(first, "mmu-type") {
            if fdt.stringEquals(mmu.lowerBound, "riscv,sv39") { mmuType = 0 }
            if fdt.stringEquals(mmu.lowerBound, "riscv,sv48") { mmuType = 1 }
            if fdt.stringEquals(mmu.lowerBound, "riscv,sv57") { mmuType = 2 }
        }
        if let size = fdt.u32(first, "riscv,cbom-block-size"), size.nonzeroBitCount == 1 {
            cmoBlockLog2 = UInt8(size.trailingZeroBitCount)
        }
        readIsa(fdt, first)
        if isaSource == .baseOnly, let core = Self.knownCore(vendor: vendor, architecture: architecture) {
            isaCount = 0
            append(core.isa)
            isaSource = .knownCore
            if cmoBlockLog2 == 0 { cmoBlockLog2 = core.cmoBlockLog2 }
        }
        guard !isaOverflow else { return nil }
        readPlic(fdt)
        readUart(fdt)
    }

    // MARK: The ISA

    /// Cores whose firmware's tree may list only base letters, with what
    /// they implement. The X60 (SpacemiT K1): RVA22 with V (Linux's
    /// k1.dtsi, docs/boards/orangepi-rv2).
    static let knownCores: InlineArray<1, (vendor: UInt64, architecture: UInt64, isa: StaticString, cmoBlockLog2: UInt8)> = [
        (0x710, 0x8000_0000_5800_0001,
         "rv64imafdcv_zicbom_zicbop_zicboz_zicntr_zicond_zicsr_zifencei_zihintpause_zihpm_zfh_zfhmin_zba_zbb_zbc_zbs_zkt_zvfh_zvkt_sscofpmf_sstc_svinval_svnapot_svpbmt",
         6),
    ]

    static func knownCore(vendor: UInt64, architecture: UInt64)
        -> (vendor: UInt64, architecture: UInt64, isa: StaticString, cmoBlockLog2: UInt8)? {
        for i in knownCores.indices where knownCores[i].vendor == vendor && knownCores[i].architecture == architecture {
            return knownCores[i]
        }
        return nil
    }

    /// The hart's `riscv,isa-extensions` (letters, then '_' and the rest),
    /// else its `riscv,isa` string. Base letters alone stay baseOnly.
    private mutating func readIsa(_ fdt: borrowing Fdt, _ cpu: Int) {
        if let list = fdt.property(cpu, "riscv,isa-extensions") {
            append("rv64")
            forEachString(fdt, list) { start, count in
                if count == 1 { append(fdt.byte(start)) }
            }
            forEachString(fdt, list) { start, count in
                guard count > 1 else { return }
                append(UInt8(ascii: "_"))
                for i in 0..<count { append(fdt.byte(start + i)) }
            }
        } else if let string = fdt.property(cpu, "riscv,isa") {
            for at in string where fdt.byte(at) != 0 {
                let b = fdt.byte(at)
                append(b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") ? b | 0x20 : b)
            }
        }
        var multiLetter = false
        for i in 0..<isaCount where isa[i] == UInt8(ascii: "_") { multiLetter = true }
        isaSource = multiLetter ? .devicetree : .baseOnly
    }

    private func forEachString(_ fdt: borrowing Fdt, _ list: Range<Int>, _ body: (Int, Int) -> Void) {
        var start = list.lowerBound
        while start < list.upperBound {
            var end = start
            while end < list.upperBound, fdt.byte(end) != 0 { end += 1 }
            if end > start { body(start, end - start) }
            start = end + 1
        }
    }

    private mutating func append(_ byte: UInt8) {
        guard isaCount < isa.count else {
            isaOverflow = true
            return
        }
        isa[isaCount] = byte
        isaCount += 1
    }

    private mutating func append(_ text: StaticString) {
        for i in 0..<text.utf8CodeUnitCount { append(unsafe text.utf8Start[i]) }
    }

    // MARK: Devices

    /// The PLIC, and each hart's S-mode context from its
    /// `interrupts-extended`: one (cpu-intc phandle, cause) pair per
    /// context, cause 9 being S-mode external (0xffffffff: not wired).
    private mutating func readPlic(_ fdt: borrowing Fdt) {
        guard let node = fdt.first(compatible: "riscv,plic0") ?? fdt.first(compatible: "sifive,plic-1.0.0"),
              let reg = fdt.reg(node), let sources = fdt.u32(node, "riscv,ndev"),
              let contexts = fdt.property(node, "interrupts-extended")
        else { return }
        plic = Plic(base: reg.address, size: reg.size, sources: UInt16(truncatingIfNeeded: sources),
                    maxPriority: UInt16(truncatingIfNeeded: fdt.u32(node, "riscv,max-priority") ?? 7))
        var context: UInt32 = 0
        var at = contexts.lowerBound
        while at + 8 <= contexts.upperBound {
            let phandle = fdt.be32(at), cause = fdt.be32(at + 4)
            if cause == 9, let intc = fdt.node(phandle: phandle), let cpu = fdt.parent(of: intc),
               let id = fdt.reg(cpu)?.address {
                for i in 0..<hartCount where harts[i].id == id { harts[i].context = context }
            }
            context += 1
            at += 8
        }
    }

    /// The console: `/chosen`'s `stdout-path` (a path or an alias, before
    /// any ':'), if it's a 16550.
    private mutating func readUart(_ fdt: borrowing Fdt) {
        guard let chosen = fdt.node("/chosen"), let path = fdt.property(chosen, "stdout-path") else { return }
        var end = path.lowerBound
        while end < path.upperBound, fdt.byte(end) != 0, fdt.byte(end) != UInt8(ascii: ":") { end += 1 }
        let name = path.lowerBound..<end
        var node: Int?
        if name.count > 0, fdt.byte(name.lowerBound) == UInt8(ascii: "/") {
            node = fdt.node(atPath: name)
        } else if let aliases = fdt.node("/aliases") {
            fdt.forEachProperty(of: aliases) { alias, value in
                var same = fdt.byte(alias + name.count) == 0
                for i in 0..<name.count where fdt.byte(alias + i) != fdt.byte(name.lowerBound + i) { same = false }
                if same { node = fdt.node(atPath: value) }
                return !same
            }
        }
        guard let node, fdt.contains(node, "compatible", "ns16550a") || fdt.contains(node, "compatible", "ns16550")
            || fdt.contains(node, "compatible", "snps,dw-apb-uart") || fdt.contains(node, "compatible", "intel,xscale-uart")
            || fdt.contains(node, "compatible", "spacemit,k1-uart"),
            let reg = fdt.reg(node)
        else { return }
        let interrupts = fdt.property(node, "interrupts")
        uart = Uart(base: reg.address, regShift: UInt8(truncatingIfNeeded: fdt.u32(node, "reg-shift") ?? 0),
                    width: UInt8(truncatingIfNeeded: fdt.u32(node, "reg-io-width") ?? 1),
                    gsi: interrupts.map { $0.count >= 4 ? fdt.be32($0.lowerBound) : 0 } ?? 0,
                    clock: fdt.u32(node, "clock-frequency") ?? 0)
    }
}
