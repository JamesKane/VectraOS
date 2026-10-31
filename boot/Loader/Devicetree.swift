import CEFI
import CHandoff
import CLoader
import DtAcpi
import Fdt
import Fmt

#if arch(riscv64)
/// The devicetree a machine whose firmware gives only one runs on (D154):
/// ours from the ESP's `\dtb\`, merged with what only firmware knows, or
/// firmware's own where the ESP has none for it. In loader memory or
/// firmware's; the handoff copies it.
struct ChosenTree {
    var phys: UInt64
    var size: Int
}

extension Acpi {
    /// Firmware's devicetree, when it gives one and no ACPI tables.
    @unsafe static func firmwareTree(_ systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>) -> ChosenTree? {
        guard unsafe Acpi(systemTable: systemTable) == nil,
              let dtb = unsafe configurationTable(systemTable, .devicetree),
              let size = unsafe withPhysical(dtb, size: 40, { Fdt.totalSize($0) })
        else { return nil }
        return ChosenTree(phys: dtb, size: size)
    }

    /// The tree to run on, chosen while the ESP is open: the one of ours
    /// whose root compatible holds firmware's first, or whose board a known
    /// firmware identity names (lib/dtacpi's Devicetree), merged into fresh
    /// pages; else firmware's. Says which on the console. Nil without a
    /// firmware tree, or with ACPI tables.
    @unsafe static func chooseDevicetree(
        _ systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>, _ boot: BootServices, _ volume: borrowing BootVolume,
        console: Console
    ) throws(LoaderError) -> ChosenTree? {
        guard let firmware = unsafe firmwareTree(systemTable) else { return nil }
        var match: Devicetree.Match? = nil
        var name = InlineArray<96, UInt8>(repeating: 0)
        var nameCount = 0
        let ours = try unsafe volume.find(under: "\\dtb", limit: 1 << 20) { buffer, size, file in
            let found = unsafe withPhysical(firmware.phys, size: firmware.size) { (theirs: RawSpan) -> Devicetree.Match? in
                let mine = unsafe RawSpan(_unsafeStart: buffer, byteCount: size)
                guard let fdt = Fdt(mine), let fw = Fdt(theirs) else { return nil }
                return Devicetree.matches(fdt, firmware: fw)
            }
            guard let found else { return false }
            match = found
            nameCount = min(file.count, name.count)
            for i in 0..<nameCount { name[i] = file[i] }
            return true
        }
        guard let ours = unsafe ours, let match else {
            console.write("devicetree: the firmware's, as the ESP has no tree for its \"")
            unsafe writeFirstCompatible(firmware, console)
            console.write("\"\n")
            return firmware
        }
        defer { unsafe boot.freePool(ours.buffer) }

        // A reserved range firmware's tree names stays only if UEFI's map
        // doesn't give that memory to the kernel.
        let capacity = unsafe ours.size + firmware.size + 4096
        let pages = (UInt64(capacity) + pageSize - 1) / pageSize
        let phys = try boot.allocatePages(pages, type: EfiLoaderData)
        let map = try MemoryMap(boot: boot)
        let size = unsafe withPhysical(firmware.phys, size: firmware.size) { (theirs: RawSpan) -> Int? in
            let mine = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(ours.buffer), byteCount: ours.size)
            guard let fdt = Fdt(mine), let fw = Fdt(theirs) else { return nil }
            return unsafe withPhysicalMutable(phys, size: capacity) { (out: inout MutableRawSpan) in
                Devicetree.merge(fdt, firmware: fw, keep: { address, size in
                    var free = false
                    map.forEach { (type: UInt32, base: UInt64, length: UInt64) in
                        if MemoryMap.handoffType(type) == CROI_MEM_FREE, base < address + size, address < base + length {
                            free = true
                        }
                    }
                    return !free
                }, into: &out)
            }
        }
        guard let size else { throw .unsupported("devicetree: the merged tree doesn't fit", UInt64(capacity)) }
        console.write("devicetree: ours, dtb/")
        console.write(utf8: name.span.extracting(0..<nameCount))
        console.write(match == .compatible ? " (its compatible)\n" : " (the firmware's identity)\n")
        return ChosenTree(phys: phys, size: size)
    }

    @unsafe private static func writeFirstCompatible(_ tree: ChosenTree, _ console: Console) {
        unsafe withPhysical(tree.phys, size: tree.size) { (bytes: RawSpan) in
            guard let fdt = Fdt(bytes), let root = fdt.root, let list = fdt.property(root, "compatible") else { return }
            var text = InlineArray<64, UInt8>(repeating: 0)
            var count = 0
            while list.lowerBound + count < list.upperBound, count < text.count, fdt.byte(list.lowerBound + count) != 0 {
                text[count] = fdt.byte(list.lowerBound + count)
                count += 1
            }
            console.write(utf8: text.span.extracting(0..<count))
        }
    }

    /// The ACPI tables made from `tree` (lib/dtacpi, D51), in ACPI reclaim
    /// memory as firmware's would be, so the kernel reads the machine the
    /// one way. Nil if the library can't read the tree; the caller then
    /// reports what the RHCT check finds missing.
    @unsafe static func fromDevicetree(_ tree: ChosenTree, _ boot: BootServices, console: Console) throws(LoaderError) -> Acpi? {
        // The core's IDs pick its ISA when the tree lists only base letters.
        var ids = InlineArray<4, UInt64>(repeating: 0)
        withUnsafeMutablePointer(to: &ids) {
            unsafe croi_arch_cpu_ids(UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt64.self))
        }
        let platform: Platform? = unsafe withPhysical(tree.phys, size: tree.size) { (bytes: RawSpan) -> Platform? in
            guard let fdt = Fdt(bytes) else { return nil }
            return Platform(fdt, vendor: ids[0], architecture: ids[1])
        }
        guard let platform else { return nil }
        let pages = (UInt64(platform.tablesSize) + pageSize - 1) / pageSize
        let phys = try boot.allocatePages(pages, type: EfiACPIReclaimMemory)
        let rsdp = unsafe withPhysicalMutable(phys, size: Int(pages * pageSize)) { (span: inout MutableRawSpan) in
            platform.writeTables(into: &span, at: phys)
        }
        guard let rsdp else { return nil }
        console.write("acpi: made from the devicetree: ")
        console.write(decimal: UInt64(platform.hartCount))
        console.write(" harts, isa from ")
        switch platform.isaSource {
        case .devicetree: console.write("the devicetree")
        case .knownCore: console.write("the core's IDs")
        case .baseOnly: console.write("the devicetree (base letters only)")
        }
        console.write(", core ")
        console.write(hex: ids[0])
        console.write("/")
        console.write(hex: ids[1])
        console.write("\n")
        return unsafe Acpi(rsdp: phys + UInt64(rsdp))
    }
}
#endif
