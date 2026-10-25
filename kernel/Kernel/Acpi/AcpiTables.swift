import AcpiRoot
import PageTables

/// Read-only access to the firmware's ACPI tables (after Zircon's
/// acpi_lite), through the physmap. Every table is checksum-validated
/// before use.
typealias AcpiTables = AcpiRoot<Physmap>

/// Physical memory as the kernel reads it: `withPhysicalBytes`.
enum Physmap: PhysicalReader {
    static func withBytes<R>(_ phys: UInt64, count: Int, _ body: (RawSpan) -> R) -> R {
        withPhysicalBytes(phys, count: count, body)
    }
}

/// Runs `body` with a read-only view of physical memory [phys, phys+count):
/// through the physmap when it covers the range, otherwise through a
/// temporary mapping (firmware may put tables in memory the physmap skips).
func withPhysicalBytes<R>(_ phys: UInt64, count: Int, _ body: (RawSpan) -> R) -> R {
    let pageSize = KernelLayout.pageSize
    let first = phys & ~(pageSize - 1)
    let last = (phys + UInt64(max(count, 1)) - 1) & ~(pageSize - 1)
    var inPhysmap = true
    var page = first
    while page <= last {
        if kernelAspace.query(KernelLayout.physmap(page)) == nil {
            inPhysmap = false
            break
        }
        page += pageSize
    }
    if inPhysmap {
        let span = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!,
                                  byteCount: count)
        return body(span)
    }
    let size = last - first + pageSize
    let window: UInt64
    do throws(VmError) {
        window = try kernelAspace.mapPhysical(first, size: size, MapAttributes(global: true))
    } catch {
        panic("acpi: can't map firmware table")
    }
    let span = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(window + (phys - first)))!,
                              byteCount: count)
    let result = body(span)
    try? kernelAspace.free(window)
    return result
}
