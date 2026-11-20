// The lifetime logic of a BTI and its PMTs (D166), generic over a world.
// Swift, with no imports: the kernel compiles this file into its own
// module (kernel/CMakeLists.txt) with its objects as the world
// (Dma.swift), and the host's DmaLife target compiles the same file for
// DmaLifeCheckTests, whose world is a model the checker (lib/check)
// explores every interleaving of.
//
// A PMT holds its VMO and, while live or unpinned, its BTI (`holdsBti`).
// A handle closed on a live PMT moves it to its BTI's quarantine list,
// which then holds it instead. Every change to a PMT's state, `holdsBti`
// or `next`, and to a BTI's `livePins`, `quarantined` and list, happens
// under the BTI's lock; a reference is dropped after the lock is.

/// A PMT's state: pinned and held by its handle, unpinned, or pinned and
/// held by its BTI's quarantine list.
public enum DmaPmtState: Equatable {
    case live, unpinned, quarantined
}

/// What the logic touches: objects named by handles (addresses in the
/// kernel), their fields, their references, and the pages behind a PMT.
/// The world's functions are the kernel's own operations, one for one.
public protocol DmaWorld {
    associatedtype Handle: Equatable

    /// Runs `body` with the BTI's lock held.
    static func withBtiLock<R>(_ bti: Handle, _ body: () -> R) -> R

    /// The BTI a PMT was made over (never changes).
    static func bti(of pmt: Handle) -> Handle
    /// Whether the BTI has an IOMMU domain (never changes while it lives).
    static func hasDomain(_ bti: Handle) -> Bool

    static func state(_ pmt: Handle) -> DmaPmtState
    static func setState(_ pmt: Handle, _ state: DmaPmtState)
    static func holdsBti(_ pmt: Handle) -> Bool
    static func setHoldsBti(_ pmt: Handle, _ holds: Bool)
    static func next(_ pmt: Handle) -> Handle?
    static func setNext(_ pmt: Handle, _ next: Handle?)

    static func quarantineHead(_ bti: Handle) -> Handle?
    static func setQuarantineHead(_ bti: Handle, _ head: Handle?)
    static func quarantined(_ bti: Handle) -> UInt64
    static func setQuarantined(_ bti: Handle, _ count: UInt64)
    /// livePins += 1 or -= 1.
    static func addLivePin(_ bti: Handle)
    static func removeLivePin(_ bti: Handle)

    static func retain(_ object: Handle)
    /// Drops a reference; the last destroys the object, which calls
    /// `DmaLife.destroyPmt` or `destroyBti`.
    static func release(_ object: Handle)
    /// Gives the object's memory back (its count reached zero).
    static func freePmt(_ pmt: Handle)
    static func freeBti(_ bti: Handle)

    /// The device loses the PMT's pages: its I/O range unmapped, IOTLB
    /// invalidated (nothing when it has none).
    static func unmapIo(_ pmt: Handle)
    /// The VMO range unpinned and the PMT's reference to the VMO dropped.
    static func dropPages(_ pmt: Handle)
    /// The BTI's device is blocked: nothing can reach its pages any more.
    static func blockDevice(_ bti: Handle)
    /// Drops the BTI's reference to its IOMMU.
    static func releaseIommu(_ bti: Handle)
    /// The BTI went with `count` quarantined PMTs that nobody can release
    /// now: their pages stay pinned for good.
    static func orphaned(_ bti: Handle, count: UInt64)

    /// Broken variants for the check (D166): the world says which one it
    /// runs. The kernel's are false and compile away.
    static var dropsBtiAtUnpin: Bool { get }
    static var quarantineTakesNoReference: Bool { get }
}

extension DmaWorld {
    public static var dropsBtiAtUnpin: Bool { false }
    public static var quarantineTakesNoReference: Bool { false }
}

public enum DmaLife<W: DmaWorld> {
    /// The last step of bti_pin: the PMT's references (`make` takes the
    /// VMO's and allocates, nil when it can't) and the BTI's count.
    public static func pinned(_ bti: W.Handle, make: () -> W.Handle?) -> W.Handle? {
        W.retain(bti)
        guard let pmt = make() else {
            W.release(bti)
            return nil
        }
        W.withBtiLock(bti) { W.addLivePin(bti) }
        return pmt
    }

    /// pmt_unpin: false if the PMT wasn't live. Its handle is closed
    /// after; the PMT keeps its BTI until it is destroyed (`holdsBti`).
    public static func unpin(_ pmt: W.Handle) -> Bool {
        let bti = W.bti(of: pmt)
        let was = W.withBtiLock(bti) { () -> Bool in
            guard W.state(pmt) == .live else { return false }
            W.setState(pmt, .unpinned)
            W.removeLivePin(bti)
            if W.dropsBtiAtUnpin { W.setHoldsBti(pmt, false) }
            return true
        }
        guard was else { return false }
        releasePages(pmt, domained: W.hasDomain(bti))
        if W.dropsBtiAtUnpin { W.release(bti) }
        return true
    }

    /// A PMT's handle was closed: if it is still pinned, the BTI takes it
    /// into quarantine (the device may still be using the pages).
    public static func handleClosed(_ pmt: W.Handle) {
        let bti = W.bti(of: pmt)
        let quarantined = W.withBtiLock(bti) { () -> Bool in
            guard W.state(pmt) == .live else { return false }
            W.setState(pmt, .quarantined)
            W.setNext(pmt, W.quarantineHead(bti))
            W.setQuarantineHead(bti, pmt)
            W.setQuarantined(bti, W.quarantined(bti) + 1)
            W.removeLivePin(bti)
            W.setHoldsBti(pmt, false)  // the BTI now holds the PMT
            if !W.quarantineTakesNoReference { W.retain(pmt) }  // the list's
            return true
        }
        if quarantined { W.release(bti) }  // the PMT's own: the BTI now holds it
    }

    /// bti_release_quarantine: unpins and frees every quarantined PMT.
    public static func releaseQuarantine(_ bti: W.Handle) {
        var list = W.withBtiLock(bti) { () -> W.Handle? in
            let head = W.quarantineHead(bti)
            W.setQuarantineHead(bti, nil)
            W.setQuarantined(bti, 0)
            return head
        }
        while let pmt = list {
            list = W.next(pmt)
            W.setState(pmt, .unpinned)
            releasePages(pmt, domained: W.hasDomain(bti))
            W.release(pmt)  // the list's
        }
    }

    /// The PMT's last reference is gone. Live PMTs are quarantined when
    /// their handle closes, so only unpinned ones get here (false if not).
    public static func destroyPmt(_ pmt: W.Handle) -> Bool {
        guard W.state(pmt) == .unpinned else { return false }
        let bti = W.holdsBti(pmt) ? W.bti(of: pmt) : nil
        W.freePmt(pmt)
        if let bti { W.release(bti) }  // may destroy the BTI (and detach its domain)
        return true
    }

    /// The BTI's last reference is gone. With a domain the device is
    /// blocked first, so quarantined pages are safe to give back; without
    /// one they stay pinned for good (Zircon's orphaned BTI).
    public static func destroyBti(_ bti: W.Handle) {
        if W.hasDomain(bti) {
            W.blockDevice(bti)
            var list = W.quarantineHead(bti)
            while let pmt = list {
                list = W.next(pmt)
                W.setState(pmt, .unpinned)
                releasePages(pmt, domained: false)
                W.release(pmt)
            }
            W.releaseIommu(bti)
            W.freeBti(bti)
            return
        }
        let count = W.quarantined(bti)
        if count > 0 { W.orphaned(bti, count: count) }
        W.freeBti(bti)
    }

    /// Unpins the VMO range and drops the PMT's reference to the VMO. On
    /// an IOMMU the device loses the pages first; `domained` false when
    /// there is none or it is gone (the device blocked).
    static func releasePages(_ pmt: W.Handle, domained: Bool) {
        if domained { W.unmapIo(pmt) }
        W.dropPages(pmt)
    }
}
