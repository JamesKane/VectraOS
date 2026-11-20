import CKernel
import Fmt
import Synchronization

/// A supply (D169; croi's, Zircon has nothing like it, type 65): what powers
/// a device, held by the provider that controls it. Register windows
/// (physical VMOs), interrupts and BTIs are bound to it, and ending it takes
/// them from their holders before the provider cuts. The state machine is
/// lib/supplylife/SupplyLife.swift, generic over a world (D166's pattern) and
/// checked on the model checker; `KernelSupplyWorld` below is the kernel's.
///
/// Locks: the header lock guards `state` and `bindings`. Order: supply ->
/// object (the object's header lock, a VMO's lock) while binding. The
/// ending holds no lock across the wait or the clearing: they take aspace
/// -> vmo (unmapping), the interrupt's lock -> the irq table (masking) and
/// the BTI's IOMMU domain's lock -> unit (aborting) each on its own.
struct SupplyObject: ~Copyable {
    var header = ObjectHeader(type: .supply)
    var state = SupplyState.live
    /// The bound objects (addresses), each a reference the supply holds.
    var bindings = UniqueArray<UInt64>()
    /// The MMIO range of the resource it was made from, rounded to pages:
    /// the VMOs bound to it lie inside.
    let base: UInt64
    let end: UInt64

    /// The basic rights (WAIT: for SUPPLY_ENDED) and WRITE, which binds and
    /// ends: who may end it is who holds a handle with it.
    static var defaultRights: Rights { Rights.basic.union(.write) }
}

@safe struct SupplyPointer {
    let object: ObjectPointer

    var pointee: SupplyObject {
        unsafeAddress { unsafe UnsafePointer<SupplyObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<SupplyObject>(bitPattern: UInt(object.address))! }
    }
}

extension VmoPointer {
    /// Whether a supply it is bound to ended (D169): no mapping, no fault,
    /// no pin, no child any more.
    var leaseRevoked: Bool { pointee.lock.withLock { pointee.revoked } }
}

enum Supplies {
    /// Ends that reached their deadline with a holder holding (the forced
    /// path), for the self-test and the log.
    static let forcedEnds = Atomic<UInt64>(0)

    /// supply_create (the caller has the MMIO resource's object).
    static func create(resource: ObjectPointer) throws(Status) -> ObjectPointer {
        let r = unsafe Resources.pointer(resource)
        guard unsafe r.pointee.kind == UInt32(CROI_RSRC_KIND_MMIO) else { throw .wrongType }
        guard unsafe r.pointee.size > 0 else { throw .invalidArgs }  // a ranged root covers no device
        let page = KernelLayout.pageSize
        let base = unsafe r.pointee.base & ~(page - 1)
        let end = unsafe (r.pointee.base + r.pointee.size + page - 1) & ~(page - 1)
        guard let object = Objects.allocate(SupplyObject(base: base, end: end)) else { throw .noMemory }
        return object
    }

    /// supply_bind. WRONG_TYPE: not a VMO, interrupt or BTI; INVALID_ARGS: a
    /// VMO that isn't device memory inside the supply's resource, or has
    /// children or is one; BAD_STATE: the supply isn't live, or the object
    /// is bound to one that ended; ALREADY_BOUND: it is bound to this one.
    static func bind(_ supply: ObjectPointer, _ object: ObjectPointer) throws(Status) {
        switch object.header.type {
        case .vmo:
            let record = VmoPointer(address: UnsafeVmoObject(object).vmo)
            guard case .physical(let physical) = record.pointee.kind, !record.pointee.sharedReadOnly,
                  !record.pointee.cachedFirmware, !record.pointee.isAlias, record.pointee.parent == nil,
                  !record.pointee.slice else { throw .invalidArgs }
            let page = KernelLayout.pageSize
            let (low, high) = (physical & ~(page - 1), (physical + record.pointee.size + page - 1) & ~(page - 1))
            let pointer = SupplyPointer(object: supply)
            guard low >= pointer.pointee.base, high <= pointer.pointee.end else { throw .invalidArgs }
        case .interrupt, .bti:
            break
        default:
            throw .wrongType
        }
        switch SupplyLife<KernelSupplyWorld>.bind(supply, object) {
        case .bound: break
        case .badState: throw .badState
        case .alreadyBound: throw .alreadyBound
        case .noMemory: throw .noMemory
        }
    }

    /// supply_end: BAD_STATE if the supply is ending or ended already.
    static func end(_ supply: ObjectPointer, deadline: UInt64) throws(Status) {
        guard SupplyLife<KernelSupplyWorld>.end(supply, deadline: deadline) else { throw .badState }
    }

    static func destroy(_ object: ObjectPointer) {
        SupplyLife<KernelSupplyWorld>.destroy(object)
    }
}

/// The kernel's world for SupplyLife: the real objects.
enum KernelSupplyWorld: SupplyWorld {
    typealias Handle = ObjectPointer

    static func withLock<R>(_ supply: ObjectPointer, _ body: () -> R) -> R { supply.header.lock.withLock(body) }
    static func state(_ supply: ObjectPointer) -> SupplyState { SupplyPointer(object: supply).pointee.state }
    static func setState(_ supply: ObjectPointer, _ state: SupplyState) { SupplyPointer(object: supply).pointee.state = state }
    static func bindingCount(_ supply: ObjectPointer) -> Int { SupplyPointer(object: supply).pointee.bindings.count }
    static func binding(_ supply: ObjectPointer, _ index: Int) -> ObjectPointer {
        ObjectPointer(address: SupplyPointer(object: supply).pointee.bindings[index])
    }
    static func appendBinding(_ supply: ObjectPointer, _ object: ObjectPointer) -> Bool {
        SupplyPointer(object: supply).pointee.bindings.append(object.address)
        return true
    }

    static func kind(_ object: ObjectPointer) -> SupplyKind {
        switch object.header.type {
        case .vmo: .vmo
        case .interrupt: .interrupt
        case .bti: .bti
        default: panic("supply: a bound object of another type")
        }
    }

    static func lease(_ object: ObjectPointer) -> Bool {
        switch kind(object) {
        case .vmo:
            let record = VmoPointer(address: UnsafeVmoObject(object).vmo)
            // No children (one is a window the end can't find), checked with the
            // lease: a child is counted under the same lock (`childAdded`).
            return record.pointee.lock.withLock {
                guard !record.pointee.revoked, record.pointee.children == 0 else { return false }
                record.pointee.leases += 1
                return true
            }
        case .interrupt: return InterruptObjects.lease(object)
        case .bti: return Dma.lease(object)
        }
    }

    static func unlease(_ object: ObjectPointer) {
        switch kind(object) {
        case .vmo:
            let record = VmoPointer(address: UnsafeVmoObject(object).vmo)
            record.pointee.lock.withLock { record.pointee.leases -= 1 }
        case .interrupt: InterruptObjects.unlease(object)
        case .bti: Dma.unlease(object)
        }
    }

    static func retain(_ object: ObjectPointer) { object.retain() }
    static func release(_ object: ObjectPointer) { object.release() }

    static func signalEnding(_ object: ObjectPointer) {
        object.updateSignals(clear: 0, set: UInt32(CROI_SIGNAL_SUPPLY_ENDING))
    }

    /// No handle to it (the supply's reference isn't one) and nothing in use:
    /// a VMO unmapped everywhere, a BTI with no live pin.
    static func released(_ object: ObjectPointer) -> Bool {
        switch kind(object) {
        case .vmo:
            guard object.header.handleCount.load(ordering: .acquiring) == 0 else { return false }
            let record = VmoPointer(address: UnsafeVmoObject(object).vmo)
            return record.pointee.lock.withLock { record.pointee.mappers.count == 0 }
        case .interrupt:
            return object.header.handleCount.load(ordering: .acquiring) == 0
        case .bti:
            return Dma.released(object)
        }
    }

    static func revoke(_ object: ObjectPointer) {
        switch kind(object) {
        case .vmo:
            let record = VmoPointer(address: UnsafeVmoObject(object).vmo)
            record.pointee.lock.withLock { record.pointee.revoked = true }
        case .interrupt: InterruptObjects.revoke(object)
        case .bti: Dma.revoke(object)
        }
    }

    /// Every mapping of the VMO removed and shot down (after `revoked`, so
    /// nothing maps it again; the mappings stay as address ranges until their
    /// process unmaps them, and a stray access to one is a page fault); the
    /// interrupt masked; the BTI's domain aborted. Interrupts are on and no
    /// lock is held (unmapping waits for the TLB shootdown).
    static func clear(_ object: ObjectPointer) {
        switch kind(object) {
        case .vmo:
            let record = VmoPointer(address: UnsafeVmoObject(object).vmo)
            record.unmapEverywhere(0, record.pointee.size)
        case .interrupt: InterruptObjects.maskForSupply(object)
        case .bti: Dma.abort(object)
        }
    }

    static func signalEnded(_ supply: ObjectPointer) {
        supply.updateSignals(clear: 0, set: UInt32(CROI_SIGNAL_SUPPLY_ENDED))
    }

    static func freeSupply(_ supply: ObjectPointer) {
        Objects.free(supply, as: SupplyObject.self)
    }

    /// A thread that was killed in the wait stops waiting: its deadline is
    /// now (the forced path, which finishes the end).
    static func now() -> UInt64 {
        Scheduler.current.pointee.killPending ? .max : Clock.now()
    }

    static func changeToken() -> Int64 { 0 }

    /// Polls: a holder's release (a handle closing, an unmap) wakes no one,
    /// so the ender looks again after 20 µs, doubling to about 1 ms.
    static func await(_ token: Int64, round: Int, deadline: UInt64) {
        let step: UInt64 = 20_000 << UInt64(min(round, 6))
        let until = min(Clock.now() + step, deadline)
        Scheduler.locked { _ = Scheduler.block(on: nil, deadline: until, interruptible: true) }
    }

    static func forced(_ supply: ObjectPointer) {
        Supplies.forcedEnds.wrappingAdd(1, ordering: .relaxed)
        let koid = supply.header.koid
        KernelLog.write(UInt8(CROI_LOG_WARNING)) { out in
            out.write("supply: ")
            out.write(decimal: koid)
            out.write(" ended at its deadline with a holder still holding: its mappings were removed")
        }
    }
}
