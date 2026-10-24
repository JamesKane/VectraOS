import CLoader

/// The arch's baseline (D51-D53), which every user program is compiled to
/// assume: the loader refuses a CPU below it, naming what is missing,
/// rather than let a program fault on its first such instruction.
enum Baseline {
    /// What the baseline is called, for the refusal.
    static var name: StaticString {
        #if arch(x86_64)
        "ivybridge"
        #elseif arch(arm64)
        "armv8.2-a+fp16+dotprod+rcpc"
        #else
        "rva22u64"
        #endif
    }

    /// The first feature the baseline needs that this CPU lacks, or nil.
    @unsafe static func missing(_ acpi: Acpi?) -> StaticString? {
        #if !arch(riscv64)
        var ids = InlineArray<4, UInt64>(repeating: 0)
        withUnsafeMutablePointer(to: &ids) {
            unsafe croi_arch_cpu_ids(UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt64.self))
        }
        #endif
        #if arch(x86_64)
        let ecx1 = ids[0], ebx7 = ids[1], eaxD1 = ids[2]
        let leaf1: InlineArray<11, (bit: UInt64, name: StaticString)> = [
            (0, "SSE3"), (1, "PCLMULQDQ"), (9, "SSSE3"), (13, "CMPXCHG16B"), (19, "SSE4.1"), (20, "SSE4.2"),
            (23, "POPCNT"), (26, "XSAVE"), (28, "AVX"), (29, "F16C"), (30, "RDRAND"),
        ]
        for i in leaf1.indices where ecx1 >> leaf1[i].bit & 1 == 0 { return leaf1[i].name }
        if ebx7 & 1 == 0 { return "FSGSBASE" }
        if eaxD1 & 1 == 0 { return "XSAVEOPT" }
        return nil
        #elseif arch(arm64)
        let isar0 = ids[0], isar1 = ids[1], pfr0 = ids[2]
        @inline(__always) func field(_ reg: UInt64, _ shift: UInt64) -> UInt64 { reg >> shift & 0xF }
        if field(isar0, 16) < 1 { return "CRC32" }
        if field(isar0, 20) < 2 { return "LSE atomics" }
        if field(isar0, 28) < 1 { return "RDM" }
        if field(isar0, 44) < 1 { return "dot product" }
        if field(isar1, 20) < 1 { return "LRCPC" }
        // FP and AdvSIMD: 0xF is none, 0 without half precision, 1 with it.
        if field(pfr0, 16) != 1 { return "FP16" }
        if field(pfr0, 20) != 1 { return "AdvSIMD FP16" }
        return nil
        #else
        return acpi.map { unsafe rv64Missing($0) } ?? "RHCT"
        #endif
    }

    #if arch(riscv64)
    /// RVA22U64's extensions that code generation uses, against every
    /// hart's ISA string in the RHCT.
    @unsafe private static func rv64Missing(_ acpi: Acpi) -> StaticString? {
        guard let rhct = acpi.table("RHCT") else { return "RHCT" }
        let length = unsafe withPhysical(rhct, size: 8) { Int($0.load(fromByteOffset: 4, as: UInt32.self)) }
        return unsafe withPhysical(rhct, size: length) { (table: RawSpan) -> StaticString? in
            guard table.byteCount >= 56 else { return "RHCT" }
            let count = Int(table.load(fromByteOffset: 48, as: UInt32.self))
            var offset = Int(table.load(fromByteOffset: 52, as: UInt32.self))
            var strings = 0
            for _ in 0..<count {
                guard offset + 8 <= table.byteCount else { break }
                let type = table.load(fromByteOffset: offset, as: UInt16.self)
                let nodeLength = Int(table.load(fromByteOffset: offset + 2, as: UInt16.self))
                guard nodeLength >= 8, offset + nodeLength <= table.byteCount else { break }
                if type == 0 {  // ISA string node
                    let isaLength = Int(table.load(fromByteOffset: offset + 6, as: UInt16.self))
                    let isa = table.extracting((offset + 8)..<min(offset + 8 + isaLength, offset + nodeLength))
                    if let missing = isaMissing(isa) { return missing }
                    strings += 1
                }
                offset += nodeLength
            }
            return strings > 0 ? nil : "RHCT ISA string"
        }
    }

    /// The first of the baseline's letters or extensions `isa` lacks
    /// ("rv64imafdc_zicsr_zba_..."; 'g' implies imafd).
    private static func isaMissing(_ isa: RawSpan) -> StaticString? {
        var end = 0
        while end < isa.byteCount, isa.load(fromByteOffset: end, as: UInt8.self) != 0 { end += 1 }
        let letters: InlineArray<6, (letter: UInt8, name: StaticString)> = [
            (UInt8(ascii: "i"), "I"), (UInt8(ascii: "m"), "M"), (UInt8(ascii: "a"), "A"),
            (UInt8(ascii: "f"), "F"), (UInt8(ascii: "d"), "D"), (UInt8(ascii: "c"), "C"),
        ]
        for l in letters.indices {
            var found = false
            var i = 4  // past "rv64"
            while i < end, isa.load(fromByteOffset: i, as: UInt8.self) != UInt8(ascii: "_") {
                let c = isa.load(fromByteOffset: i, as: UInt8.self) | 0x20
                if c == letters[l].letter || (c == UInt8(ascii: "g") && letters[l].letter != UInt8(ascii: "c")) {
                    found = true
                }
                i += 1
            }
            if !found { return letters[l].name }
        }
        let extensions: InlineArray<8, StaticString> = [
            "zba", "zbb", "zbs", "zfhmin", "zicbom", "zicbop", "zicboz", "zihintpause",
        ]
        for e in extensions.indices where !has(isa, end, extensions[e]) { return extensions[e] }
        return nil
    }

    /// Whether `isa`'s first `end` bytes list multi-letter extension `name`.
    private static func has(_ isa: RawSpan, _ end: Int, _ name: StaticString) -> Bool {
        let count = name.utf8CodeUnitCount
        var start = 0
        while start <= end {
            var stop = start
            while stop < end, isa.load(fromByteOffset: stop, as: UInt8.self) != UInt8(ascii: "_") { stop += 1 }
            if stop - start == count {
                var same = true
                for i in 0..<count {
                    let wanted = unsafe name.utf8Start[i]
                    if isa.load(fromByteOffset: start + i, as: UInt8.self) | 0x20 != wanted { same = false }
                }
                if same { return true }
            }
            start = stop + 1
        }
        return false
    }
    #endif
}
