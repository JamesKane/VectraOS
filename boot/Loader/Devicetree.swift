import CEFI
import CLoader
import DtAcpi
import Fmt

#if arch(riscv64)
extension Acpi {
    /// RISC-V firmware that gives no ACPI tables, only a devicetree (the
    /// Orange Pi RV2's U-Boot): the tables made from it (lib/dtacpi, D51),
    /// in ACPI reclaim memory as firmware's would be, so the kernel reads
    /// the machine the one way. Nil without a devicetree the library can
    /// read; the caller then reports what the RHCT check finds missing.
    @unsafe static func fromDevicetree(
        _ systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>, _ boot: BootServices, console: Console
    ) throws(LoaderError) -> Acpi? {
        guard let dtb = unsafe configurationTable(systemTable, .devicetree),
              let size = unsafe withPhysical(dtb, size: 40, { Fdt.totalSize($0) })
        else { return nil }
        // The core's IDs pick its ISA when the tree lists only base letters.
        var ids = InlineArray<4, UInt64>(repeating: 0)
        withUnsafeMutablePointer(to: &ids) {
            unsafe croi_arch_cpu_ids(UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt64.self))
        }
        let platform: Platform? = unsafe withPhysical(dtb, size: size) { (bytes: RawSpan) -> Platform? in
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
