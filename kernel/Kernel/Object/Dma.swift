import CKernel
import Fmt
import PageTables
import Synchronization

/// DMA objects (K9e; Zircon's IommuDispatcher, BusTransactionInitiator-
/// Dispatcher and PinnedMemoryTokenDispatcher over its stub IOMMU, values
/// and semantics in include/dma.h).
///
/// An IOMMU object (type 23) is the stub (no translation: device
/// addresses are physical), a VT-d unit (K12a, Iommu/IntelIommu.swift) or
/// an AMD-Vi one (K12b, Iommu/AmdIommu.swift).
/// A BTI (24) carries croi's DMA properties (address width, window, memory
/// type) and counts its live PMTs; it owns the quarantine list. On VT-d it
/// holds its IOMMU and a domain: the device's own I/O address space, which
/// maps only what it pins. A PMT (26) holds a reference to its VMO and,
/// while live, one to its BTI; once quarantined the BTI holds a reference
/// to it instead. All PMT state changes happen under the BTI's lock.
struct IommuObject: ~Copyable {
    var header = ObjectHeader(type: .iommu)
    /// The unit (VtdUnit or AmdviUnit record), 0 for the stub.
    var unit: UInt64 = 0
    var kind: UInt8 = 0  // IommuKind's raw value

    /// ZX_DEFAULT_IOMMU_RIGHTS.
    static var defaultRights: Rights { Rights.basic.subtracting(.wait) }
}

struct BtiObject: ~Copyable {
    var header = ObjectHeader(type: .bti)
    var name = ObjectName(repeating: 0)
    let btiId: UInt64
    /// Behind an IOMMU: its object (a reference) and the device's domain
    /// (an IoDomain).
    var iommu: UInt64 = 0
    var domain: UInt64 = 0
    var properties = croi_bti_properties_t(address_bits: 64, memory_type: UInt32(CROI_BTI_MEMORY_COHERENT),
                                           window_base: 0, window_size: 0)
    var livePins: UInt64 = 0
    /// Quarantined PMTs (PmtObject.next links them), each holding a
    /// reference the list owns.
    var quarantine: UInt64 = 0
    var quarantined: UInt64 = 0
    /// D169: the supplies it is bound to, and whether one ended: bti_pin is
    /// refused, its domain (if any) is aborted. Under the header lock.
    var leases: UInt32 = 0
    var revoked = false

    /// ZX_DEFAULT_BTI_RIGHTS.
    static var defaultRights: Rights {
        Rights.basic.subtracting(.wait).union(.read | .write | .getProperty | .setProperty | .map)
    }
}

struct PmtObject: ~Copyable {
    var header = ObjectHeader(type: .pmt)
    let bti: ObjectPointer
    let vmo: VmoPointer
    let offset: UInt64
    let size: UInt64
    /// Behind an IOMMU: the I/O virtual address of the range's first byte (0: stub).
    var iova: UInt64 = 0
    var state = DmaPmtState.live
    var next: UInt64 = 0
    /// Whether it still holds its reference to `bti`: from bti_pin until it
    /// is destroyed, or until quarantine hands it to the BTI. Not dropped at
    /// unpin: closing the PMT's handle afterwards (pmt_unpin consumes it)
    /// takes the BTI's lock, and an unpin may drop the BTI's last reference
    /// (V2 7c: a driver that closed its BTI before unpinning panicked the
    /// kernel on the freed BTI's lock).
    var holdsBti = true

    /// ZX_DEFAULT_PMT_RIGHTS: it can't be duplicated or sent.
    static var defaultRights: Rights { .inspect }
}

@safe struct BtiPointer {
    let object: ObjectPointer

    var pointee: BtiObject {
        unsafeAddress { unsafe UnsafePointer<BtiObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<BtiObject>(bitPattern: UInt(object.address))! }
    }
}

@safe struct PmtPointer {
    let object: ObjectPointer

    var pointee: PmtObject {
        unsafeAddress { unsafe UnsafePointer<PmtObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PmtObject>(bitPattern: UInt(object.address))! }
    }
}

enum Dma {
    // MARK: IOMMUs and BTIs

    /// iommu_create (the caller checked the IOMMU resource and copied the
    /// descriptor in).
    static func createIommu(type: UInt32, descriptor: RawSpan) throws(Status) -> ObjectPointer {
        var unit: UInt64 = 0
        var kind: UInt8 = 0
        switch type {
        case UInt32(CROI_IOMMU_TYPE_STUB):
            guard descriptor.byteCount == 1 else { throw .invalidArgs }  // zx_iommu_desc_stub_t
        case UInt32(CROI_IOMMU_TYPE_INTEL):
            #if arch(x86_64)
            unit = try Vtd.create(descriptor)
            kind = IommuKind.vtd.rawValue
            #else
            throw .notSupported
            #endif
        case UInt32(CROI_IOMMU_TYPE_AMD):
            #if arch(x86_64)
            unit = try Amdvi.create(descriptor)
            kind = IommuKind.amd.rawValue
            #else
            throw .notSupported
            #endif
        case UInt32(CROI_IOMMU_TYPE_RISCV):
            #if arch(riscv64)
            unit = try RiscvIommus.create(descriptor)
            kind = IommuKind.riscv.rawValue
            #else
            throw .notSupported
            #endif
        case UInt32(CROI_IOMMU_TYPE_ARM_SMMU):
            #if arch(arm64)
            if descriptor.byteCount == 8, Iort.smmuV2(unsafe descriptor.unsafeLoadUnaligned(as: UInt64.self)) != nil {
                unit = try SmmuV2.create(descriptor)
                kind = IommuKind.smmuV2.rawValue
            } else {
                unit = try SmmuV3.create(descriptor)
                kind = IommuKind.smmu.rawValue
            }
            #else
            throw .notSupported
            #endif
        default:
            throw .invalidArgs
        }
        guard let object = Objects.allocate(IommuObject(unit: unit, kind: kind)) else {
            #if arch(x86_64) || arch(arm64) || arch(riscv64)
            if unit != 0 { Iommus.unbind(IommuKind(rawValue: kind)!, unit: unit) }
            #endif
            throw .noMemory
        }
        return object
    }

    static func destroyIommu(_ object: ObjectPointer) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        let iommu = unsafe UnsafePointer<IommuObject>(bitPattern: UInt(object.address))!
        if unsafe iommu.pointee.unit != 0 {
            unsafe Iommus.unbind(IommuKind(rawValue: iommu.pointee.kind)!, unit: iommu.pointee.unit)
        }
        #endif
        Objects.free(object, as: IommuObject.self)
    }

    /// bti_create: behind an IOMMU, claims device `id` (bus/device/function)
    /// with a domain of its own; on the stub, a BTI with no translation,
    /// which the debuglog records as a trust decision.
    static func createBti(_ iommu: ObjectPointer, id: UInt64) throws(Status) -> ObjectPointer {
        let record = unsafe UnsafePointer<IommuObject>(bitPattern: UInt(iommu.address))!
        let unit = unsafe record.pointee.unit
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if unit != 0 {
            let kind = unsafe IommuKind(rawValue: record.pointee.kind)!
            let domain = try Iommus.attach(kind, unit: unit, id: id)
            var bti = BtiObject(btiId: id)
            bti.iommu = iommu.address
            bti.domain = domain.address
            bti.properties.address_bits = UInt32(domain.pointee.inputBits)
            guard let object = Objects.allocate(bti) else {
                Iommus.detach(domain)
                throw .noMemory
            }
            iommu.retain()
            return object
        }
        #endif
        guard let object = Objects.allocate(BtiObject(btiId: id)) else { throw .noMemory }
        let (pid, _) = DebugLogs.writerKoids()
        KernelLog.write(UInt8(CROI_LOG_WARNING)) { out in
            out.write("bti: no-IOMMU BTI ")
            out.write(hex: id)
            out.write(" for process ")
            out.write(decimal: pid)
            out.write(": its DMA reaches physical memory")
        }
        return object
    }

    static func destroyBti(_ object: ObjectPointer) {
        DmaLife<KernelDmaWorld>.destroyBti(object)
    }

    static func info(_ object: ObjectPointer) -> croi_info_bti_t {
        let bti = BtiPointer(object: object)
        return object.header.lock.withLock {
            croi_info_bti_t(minimum_contiguity: KernelLayout.pageSize,
                            aspace_size: bti.pointee.domain == 0 ? .max : 1 << UInt64(bti.pointee.properties.address_bits),
                            pmo_count: bti.pointee.livePins, quarantine_count: bti.pointee.quarantined)
        }
    }

    static func properties(_ object: ObjectPointer) -> croi_bti_properties_t {
        object.header.lock.withLock { BtiPointer(object: object).pointee.properties }
    }

    /// bti_set_properties: only narrows; the memory type changes only
    /// while nothing is pinned or quarantined.
    static func setProperties(_ object: ObjectPointer, _ wanted: croi_bti_properties_t) throws(Status) {
        let bti = BtiPointer(object: object)
        guard wanted.address_bits >= 12, wanted.address_bits <= 64,
              wanted.memory_type <= UInt32(CROI_BTI_MEMORY_NONCOHERENT),
              !wanted.window_base.addingReportingOverflow(wanted.window_size).overflow else { throw .invalidArgs }
        try object.header.lock.withLock { () throws(Status) in
            let current = bti.pointee.properties
            let (base, end) = window(current)
            let (newBase, newEnd) = window(wanted)
            guard wanted.address_bits <= current.address_bits, newBase >= base, newEnd <= end else {
                throw .accessDenied  // a widening
            }
            if wanted.memory_type != current.memory_type {
                guard bti.pointee.livePins == 0, bti.pointee.quarantined == 0 else { throw .badState }
            }
            bti.pointee.properties = wanted
        }
    }

    /// The device addresses [base, end) the properties allow.
    private static func window(_ p: croi_bti_properties_t) -> (UInt64, UInt64) {
        let reach: UInt64 = p.address_bits >= 64 ? .max : (1 << UInt64(p.address_bits))
        guard p.window_size != 0 else { return (0, reach) }
        return (p.window_base, min(p.window_base + p.window_size, reach))
    }

    // MARK: Supplies (D169)

    /// A supply takes it: false if one it was bound to ended.
    static func lease(_ object: ObjectPointer) -> Bool {
        object.header.lock.withLock {
            let bti = BtiPointer(object: object)
            guard !bti.pointee.revoked else { return false }
            bti.pointee.leases += 1
            return true
        }
    }

    static func unlease(_ object: ObjectPointer) {
        object.header.lock.withLock { BtiPointer(object: object).pointee.leases -= 1 }
    }

    /// From now on bti_pin is refused.
    static func revoke(_ object: ObjectPointer) {
        object.header.lock.withLock { BtiPointer(object: object).pointee.revoked = true }
    }

    static func btiRevoked(_ object: ObjectPointer) -> Bool {
        object.header.lock.withLock { BtiPointer(object: object).pointee.revoked }
    }

    /// Nobody holds it: no handle, no live pin.
    static func released(_ object: ObjectPointer) -> Bool {
        guard object.header.handleCount.load(ordering: .acquiring) == 0 else { return false }
        return object.header.lock.withLock { BtiPointer(object: object).pointee.livePins == 0 }
    }

    /// The device's DMA stops: behind an IOMMU its domain is aborted (every
    /// access faults there, and the abort is waited out); with none it is an
    /// untranslated master the kernel can't stop, and its pins stay pinned
    /// until the provider reports the device reset.
    static func abort(_ object: ObjectPointer) {
        let bti = BtiPointer(object: object)
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if bti.pointee.domain != 0 {
            IoDomains.abort(IoDomainPointer(address: bti.pointee.domain))
            return
        }
        #endif
        let id = bti.pointee.btiId
        KernelLog.write(UInt8(CROI_LOG_WARNING)) { out in
            out.write("bti: BTI ")
            out.write(hex: id)
            out.write(" has no IOMMU: its supply ended but its DMA can't be stopped, its pins stay until it is reset")
        }
    }

    // MARK: Contiguous VMOs

    /// vmo_create_contiguous(bti, ...): inside the BTI's window and width,
    /// with its memory type.
    static func createContiguous(_ object: ObjectPointer, size: UInt64, alignLog2: Int,
                                 account: MemoryAccountPointer? = nil) throws(Status) -> Vmo {
        let p = properties(object)
        // Behind an IOMMU the window constrains I/O addresses, not where
        // the pages are.
        let (base, end) = BtiPointer(object: object).pointee.domain == 0 ? window(p) : (0, .max)
        let cache: CachePolicy = p.memory_type == UInt32(CROI_BTI_MEMORY_NONCOHERENT) ? .uncached : .cached
        do throws(VmError) {
            return try Vmo(contiguous: size, alignLog2: alignLog2, cache: cache, floor: base, limit: end, account: account)
        } catch {
            throw error == .outOfMemory ? .noMemory : .invalidArgs
        }
    }

    // MARK: Pinning

    /// bti_pin: pins the range and makes a live PMT. The caller writes the
    /// addresses (`address(of:)`) and unpins if that fails.
    static func pin(_ object: ObjectPointer, vmo: VmoPointer, offset: UInt64, size: UInt64,
                    writable: Bool) throws(Status) -> ObjectPointer {
        let bti = BtiPointer(object: object)
        guard size > 0 else { throw .invalidArgs }
        // D169: a BTI or a VMO whose supply ended is no longer usable.
        guard !vmo.leaseRevoked, !btiRevoked(object) else { throw .badState }
        // Before paging in (review fix: ensureRange's loop trapped on a
        // range wrapping past 2^64).
        guard !offset.addingReportingOverflow(size).overflow, offset + size <= vmo.pointee.size else {
            throw .outOfRange
        }
        try Pagers.ensureRange(vmo, offset, size)
        do throws(VmError) {
            try Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in try v.pin(offset: offset, size: size) }
        } catch {
            throw error.status
        }
        func unpinVmo() {
            try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in v.unpin(offset: offset, size: size) }
        }
        let (base, end) = window(properties(object))
        var iova: UInt64 = 0
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if bti.pointee.domain != 0 {
            // I/O addresses from the window, each page mapped for the device.
            let domain = IoDomainPointer(address: bti.pointee.domain)
            do throws(Status) {
                iova = try IoDomains.reserve(domain, size: size, low: base, high: end)
            } catch {
                unpinVmo()
                throw error == .noMemory ? .outOfRange : error
            }
            var at: UInt64 = 0
            while at < size {
                do throws(Status) {
                    guard let phys = vmo.lookup(at: offset + at) else { throw .badState }
                    try IoDomains.map(domain, iova: iova + at, phys: phys, write: writable,
                                      cached: properties(object).memory_type != UInt32(CROI_BTI_MEMORY_NONCOHERENT))
                } catch {
                    IoDomains.unmap(domain, iova: iova, size: at)
                    IoDomains.release(domain, iova: iova)
                    unpinVmo()
                    throw error
                }
                at += KernelLayout.pageSize
            }
        }
        #endif
        // Without an IOMMU: every page inside the BTI's reach (device
        // address = physical).
        var at = offset
        while iova == 0, at < offset + size {
            guard let phys = vmo.lookup(at: at), phys >= base, phys + KernelLayout.pageSize <= end else {
                unpinVmo()
                throw .outOfRange
            }
            at += KernelLayout.pageSize
        }
        let placed = iova
        let made = DmaLife<KernelDmaWorld>.pinned(object) { () -> ObjectPointer? in
            vmo.retain()
            var record = PmtObject(bti: object, vmo: vmo, offset: offset, size: size)
            record.iova = placed
            guard let pmt = Objects.allocate(record) else {
                vmo.release()
                return nil
            }
            return pmt
        }
        guard let pmt = made else {
            #if arch(x86_64) || arch(arm64) || arch(riscv64)
            if iova != 0 {
                let domain = IoDomainPointer(address: bti.pointee.domain)
                IoDomains.unmap(domain, iova: iova, size: size)
                IoDomains.release(domain, iova: iova)
            }
            #endif
            unpinVmo()
            throw .noMemory
        }
        // D169: an ending that revoked the BTI after the check above aborted
        // the domain before or after these pages were mapped: either way they
        // go, and the pin is refused (the flag is set before the abort).
        if btiRevoked(object) {
            _ = DmaLife<KernelDmaWorld>.unpin(pmt)
            pmt.release()
            throw .badState
        }
        return pmt
    }

    /// The device address of byte `offset` of a live PMT's range.
    static func address(_ pmt: ObjectPointer, at offset: UInt64) -> UInt64 {
        let p = PmtPointer(object: pmt)
        if p.pointee.iova != 0 { return p.pointee.iova + offset }
        return p.pointee.vmo.lookup(at: p.pointee.offset + offset) ?? 0
    }

    /// pmt_unpin (and failure paths of bti_pin): the pages go back to the
    /// VMO's control. Its handle is closed after; the PMT keeps its BTI
    /// until it is destroyed (`holdsBti`).
    static func unpin(_ pmt: ObjectPointer) throws(Status) {
        // D169: a BTI with no IOMMU whose supply ended is an untranslated
        // master the kernel can't stop: its pages stay pinned, in quarantine,
        // until the provider reports the device reset (bti_release_quarantine).
        let bti = PmtPointer(object: pmt).pointee.bti
        if BtiPointer(object: bti).pointee.domain == 0, btiRevoked(bti) {
            guard KernelDmaWorld.state(pmt) == .live else { throw .badState }
            DmaLife<KernelDmaWorld>.handleClosed(pmt)
            return
        }
        guard DmaLife<KernelDmaWorld>.unpin(pmt) else { throw .badState }
    }

    /// A PMT's handle was closed: if it is still pinned, the BTI takes it
    /// into quarantine (the device may still be using the pages).
    static func handleClosed(_ pmt: ObjectPointer) {
        DmaLife<KernelDmaWorld>.handleClosed(pmt)
    }

    /// bti_release_quarantine: unpins and frees every quarantined PMT.
    static func releaseQuarantine(_ object: ObjectPointer) {
        DmaLife<KernelDmaWorld>.releaseQuarantine(object)
    }

    static func destroyPmt(_ object: ObjectPointer) {
        // Live PMTs are quarantined when their handle closes, so only
        // unpinned ones get here.
        guard DmaLife<KernelDmaWorld>.destroyPmt(object) else { panic("pmt: destroyed while pinned") }
    }
}

/// The kernel's world for DmaLife (lib/dmalife): the real objects. Every
/// call is the operation Dma.swift made before the logic moved out, in the
/// same order under the same locks.
enum KernelDmaWorld: DmaWorld {
    typealias Handle = ObjectPointer

    static func withBtiLock<R>(_ bti: ObjectPointer, _ body: () -> R) -> R {
        bti.header.lock.withLock(body)
    }

    static func bti(of pmt: ObjectPointer) -> ObjectPointer { PmtPointer(object: pmt).pointee.bti }
    static func hasDomain(_ bti: ObjectPointer) -> Bool { BtiPointer(object: bti).pointee.domain != 0 }

    static func state(_ pmt: ObjectPointer) -> DmaPmtState { PmtPointer(object: pmt).pointee.state }
    static func setState(_ pmt: ObjectPointer, _ state: DmaPmtState) { PmtPointer(object: pmt).pointee.state = state }
    static func holdsBti(_ pmt: ObjectPointer) -> Bool { PmtPointer(object: pmt).pointee.holdsBti }
    static func setHoldsBti(_ pmt: ObjectPointer, _ holds: Bool) { PmtPointer(object: pmt).pointee.holdsBti = holds }
    static func next(_ pmt: ObjectPointer) -> ObjectPointer? {
        let next = PmtPointer(object: pmt).pointee.next
        return next == 0 ? nil : ObjectPointer(address: next)
    }
    static func setNext(_ pmt: ObjectPointer, _ next: ObjectPointer?) {
        PmtPointer(object: pmt).pointee.next = next?.address ?? 0
    }

    static func quarantineHead(_ bti: ObjectPointer) -> ObjectPointer? {
        let head = BtiPointer(object: bti).pointee.quarantine
        return head == 0 ? nil : ObjectPointer(address: head)
    }
    static func setQuarantineHead(_ bti: ObjectPointer, _ head: ObjectPointer?) {
        BtiPointer(object: bti).pointee.quarantine = head?.address ?? 0
    }
    static func quarantined(_ bti: ObjectPointer) -> UInt64 { BtiPointer(object: bti).pointee.quarantined }
    static func setQuarantined(_ bti: ObjectPointer, _ count: UInt64) { BtiPointer(object: bti).pointee.quarantined = count }
    static func addLivePin(_ bti: ObjectPointer) { BtiPointer(object: bti).pointee.livePins += 1 }
    static func removeLivePin(_ bti: ObjectPointer) { BtiPointer(object: bti).pointee.livePins -= 1 }

    static func retain(_ object: ObjectPointer) { object.retain() }
    static func release(_ object: ObjectPointer) { object.release() }
    static func freePmt(_ pmt: ObjectPointer) { Objects.free(pmt, as: PmtObject.self) }
    static func freeBti(_ bti: ObjectPointer) { Objects.free(bti, as: BtiObject.self) }

    static func unmapIo(_ pmt: ObjectPointer) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        let p = PmtPointer(object: pmt)
        let domain = BtiPointer(object: p.pointee.bti).pointee.domain
        if domain != 0, p.pointee.iova != 0 {
            IoDomains.unmap(IoDomainPointer(address: domain), iova: p.pointee.iova, size: p.pointee.size)
            IoDomains.release(IoDomainPointer(address: domain), iova: p.pointee.iova)
        }
        #endif
    }

    static func dropPages(_ pmt: ObjectPointer) {
        let p = PmtPointer(object: pmt)
        let vmo = p.pointee.vmo
        let (offset, size) = (p.pointee.offset, p.pointee.size)
        try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in v.unpin(offset: offset, size: size) }
        vmo.release()
    }

    static func blockDevice(_ bti: ObjectPointer) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        Iommus.detach(IoDomainPointer(address: BtiPointer(object: bti).pointee.domain))
        #endif
    }

    static func releaseIommu(_ bti: ObjectPointer) {
        ObjectPointer(address: BtiPointer(object: bti).pointee.iommu).release()
    }

    static func orphaned(_ bti: ObjectPointer, count: UInt64) {
        let id = BtiPointer(object: bti).pointee.btiId
        KernelLog.write(UInt8(CROI_LOG_WARNING)) { out in
            out.write("bti: BTI ")
            out.write(hex: id)
            out.write(" went with ")
            out.write(decimal: count)
            out.write(" quarantined PMTs: their pages stay pinned")
        }
    }
}
