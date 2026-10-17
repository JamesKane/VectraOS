import CroiRuntime

/// DMA objects (K9e) as a driver host uses them (V2 item 7c). A PMT keeps
/// its BTI until the PMT goes, so a driver may close its BTI's last handle
/// while memory is still pinned and unpin afterwards: pmt_unpin closes the
/// PMT's handle after the unpin, and that close takes the BTI's lock
/// (the kernel panicked on the freed BTI's lock when the unpin dropped
/// the last reference). Through the stub IOMMU, so on every machine.
enum DmaSuite {
    static func run() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0)))
        unpinAfterTheBTI(root)
        print("swift: dma passed")
    }

    static func unpinAfterTheBTI(_ root: borrowing Handle) {
        let system = InterruptSuite.resource(root, UInt32(CROI_RSRC_KIND_SYSTEM), UInt64(CROI_RSRC_SYSTEM_IOMMU_BASE), 1)
        var desc: UInt8 = 0
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_IOMMU_CREATE, system.arg, UInt64(CROI_IOMMU_TYPE_STUB), Sys.address(&desc), 1,
                       Sys.address(&raw)) == 0, "the stub IOMMU")
        let iommu = Handle(adopting: raw)
        check(Sys.call(CROI_SYS_BTI_CREATE, iommu.arg, 0, 0x7C, Sys.address(&raw)) == 0, "a BTI")
        let bti = Handle(adopting: raw)
        let vmo = Handle(vmo: 2 * pageSize)
        var addresses: (UInt64, UInt64) = (0, 0)
        var pmt: UInt32 = 0
        let rw = UInt64(CROI_BTI_PERM_READ | CROI_BTI_PERM_WRITE)
        check(Sys.call(CROI_SYS_BTI_PIN, bti.arg | rw << 32, vmo.arg | 2 << 32, 0, 2 * pageSize,
                       Sys.address(&addresses), Sys.address(&pmt)) == 0 && addresses.0 != 0, "two pages pinned")
        _ = consume bti  // its last handle, with the PMT live
        check(Sys.call(CROI_SYS_PMT_UNPIN, UInt64(pmt)) == 0, "unpinned after the BTI's last handle closed")
        check(croi_handle_close(pmt) == Status.badHandle, "pmt_unpin consumed its handle")
        // The BTI, its PMT and the VMO's pin all go: the harness checks nothing is left.
        _ = consume iommu
    }
}
