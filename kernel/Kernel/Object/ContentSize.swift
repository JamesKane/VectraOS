import CKernel

/// A VMO's content size (ZX_PROP_VMO_CONTENT_SIZE): byte-granular, at most
/// the VMO's size, which it reads as until set. Taisce's mapped files keep
/// their length here. Streams kept it before V1 cut them (D21); it lives on
/// the VMO record (`contentSize`), and a reference shares its root's.
///
/// Size changes are serialized by the VMO's size lock (`withSizeLock`,
/// Zircon's per-VMO StreamSizeManager): setting the content size and
/// vmo_set_size both take it, so neither sees the end move under it. It
/// is a blocking mutex because zeroing may wait for a pager.
enum ContentSize {
    /// Runs `body` holding `vmo`'s size lock (its size owner's: a reference
    /// shares its root's). The queue is made on first use (NO_MEMORY if it
    /// can't be) and lives as long as the VMO record; the caller's
    /// reference keeps that alive.
    static func withSizeLock<R>(_ vmo: VmoPointer, _ body: () throws(Status) -> R) throws(Status) -> R {
        let vmo = vmo.sizeOwner
        var queue = vmo.pointee.lock.withLock { vmo.pointee.sizeQueue }
        if queue == 0 {
            guard let made = QueuePointer.tryAllocate() else { throw .noMemory }
            queue = vmo.pointee.lock.withLock { () -> UInt64 in
                if vmo.pointee.sizeQueue == 0 { vmo.pointee.sizeQueue = made.address }
                return vmo.pointee.sizeQueue
            }
            if queue != made.address { made.deallocate() }  // another thread's won
        }
        let lock = QueuePointer(address: queue)
        Scheduler.lockMutex(lock)
        defer { Scheduler.unlockMutex(lock) }
        return try body()
    }

    /// K14g: a reference shares its root's sizes (Zircon: its stream size
    /// manager); a slice of an anonymous VMO has its own, over its root's
    /// pages (`zero` goes there).
    static func of(_ vmo: VmoPointer) -> UInt64 {
        let vmo = vmo.sizeOwner
        return vmo.pointee.lock.withLock { vmo.pointee.contentSize ?? vmo.pointee.size }
    }

    /// Setting the property: OUT_OF_RANGE past the VMO; the bytes from the
    /// smaller of the old and new sizes to the VMO's end read as zero.
    static func set(_ vmo: VmoPointer, _ size: UInt64) throws(Status) {
        let vmo = vmo.sizeOwner
        guard case .anonymous = vmo.pointee.kind else { throw .notSupported }
        try withSizeLock(vmo) { () throws(Status) in try setLocked(vmo, size) }
    }

    /// Size lock held, so vmo_set_size can't move the VMO's end between the
    /// check and the zeroing (review 2: the check was outside every lock).
    private static func setLocked(_ vmo: VmoPointer, _ size: UInt64) throws(Status) {
        guard size <= vmo.pointee.lock.withLock({ vmo.pointee.size }) else { throw .outOfRange }
        let old = of(vmo)
        let from = min(old, size)
        // Zircon's: zeroed up to the new size's page end (a pager VMO's
        // pages requested and dirtied), and past it only what is committed
        // ("untracked": the rest of an UNBOUNDED VMO, K14i, is no loop).
        let aligned = (size + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
        if aligned > from { try zero(vmo, from, aligned - from) }
        let rest = max(aligned, from)
        let (pages, _) = vmo.target
        if rest < vmo.pointee.size {
            if pages.pointee.pager == nil, !pages.pointee.readsFromPager, pages.pointee.parent == nil, !pages.pointee.clone {
                try zero(vmo, rest, vmo.pointee.size - rest)  // absent reads zero: decommitted, sparsely
            } else if let source = pages.pointee.pager, !source.pointee.trapDirty, pages == vmo {
                Pagers.zeroPages(pages, rest, vmo.pointee.size, .untracked)  // K14k: Zircon's untracked zeros
            } else {
                try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in v.zeroOwn(rest, vmo.pointee.size) }
            }
        }
        vmo.pointee.lock.withLock { vmo.pointee.contentSize = size }
    }

    private static func zero(_ holder: VmoPointer, _ offset: UInt64, _ length: UInt64) throws(Status) {
        guard length > 0 else { return }
        let (vmo, shift) = holder.target
        let offset = offset + shift
        if vmo.pointee.pager != nil || vmo.pointee.readsFromPager {  // the pages written in place first
            try Pagers.ensureWritableForZero(vmo, offset, length)
        }
        do throws(VmError) {
            try Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in try v.zero(offset: offset, size: length) }
        } catch {
            throw error.status
        }
    }
}
