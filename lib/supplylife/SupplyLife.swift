// The lifetime logic of a supply and what is bound to it (D169), generic
// over a world. Swift, with no imports: the kernel compiles this file into
// its own module (kernel/CMakeLists.txt) with its objects as the world
// (Object/Supply.swift), and the host's SupplyLife target compiles the same
// file for SupplyCheckTests, whose world is a model the checker (lib/check)
// explores every interleaving of (D166's pattern).
//
// A supply stands for what powers a device. Objects are bound to it (a
// register window's physical VMO, an interrupt, a BTI): each is usable only
// while every supply it is bound to is live. Ending a supply takes them
// away from their holders, in this order:
//
//   1. the supply is `ending`: it takes no more bindings; each bound object
//      is signalled (SUPPLY_ENDING);
//   2. the ender waits until every holder has released its object, or the
//      deadline passes (the forced path);
//   3. every bound object is revoked (it can't be used again), then
//      cleared: a VMO's mappings removed and shot down, an interrupt
//      masked, a BTI's domain aborted;
//   4. only then the supply is `ended` and signalled (SUPPLY_ENDED), and
//      the provider may cut.
//
// A supply holds one reference to each object bound to it (taken at the
// bind, dropped when the supply is destroyed), so a bound object is never
// freed under the ending. The supply's lock guards its state and its list
// of bindings; the object's own lock is taken inside it (supply -> object).
// Nothing is held across the wait or the clearing, which take the address
// space, VMO, interrupt and IOMMU locks in their own orders.

/// What a bound object is.
public enum SupplyKind: Equatable {
    case vmo, interrupt, bti
}

/// A supply's state: it takes bindings, it is being ended (holders asked to
/// release), or it is over (nothing bound is usable).
public enum SupplyState: Equatable {
    case live, ending, ended
}

public enum SupplyBindResult: Equatable {
    case bound
    /// The supply is no longer live, or the object is bound to one that ended.
    case badState
    case alreadyBound
    case noMemory
}

/// What the logic touches: supplies and bound objects named by handles
/// (addresses in the kernel), their fields and references, and the clock.
/// The world's functions are the kernel's own operations, one for one.
public protocol SupplyWorld {
    associatedtype Handle: Equatable

    // The supply (a supply's lock guards its state and its bindings).
    static func withLock<R>(_ supply: Handle, _ body: () -> R) -> R
    static func state(_ supply: Handle) -> SupplyState
    static func setState(_ supply: Handle, _ state: SupplyState)
    static func bindingCount(_ supply: Handle) -> Int
    static func binding(_ supply: Handle, _ index: Int) -> Handle
    /// Adds a binding (false: out of memory).
    static func appendBinding(_ supply: Handle, _ object: Handle) -> Bool

    // A bound object.
    static func kind(_ object: Handle) -> SupplyKind
    /// Takes a lease on the object, under its own lock: false if it was
    /// revoked (a supply it was bound to has ended).
    static func lease(_ object: Handle) -> Bool
    static func unlease(_ object: Handle)
    static func retain(_ object: Handle)
    /// Drops a reference; the last frees the object.
    static func release(_ object: Handle)
    /// Asserts SUPPLY_ENDING on the object.
    static func signalEnding(_ object: Handle)
    /// Whether its holder is done with it: no handle but the supply's
    /// reference, no mapping, no pin.
    static func released(_ object: Handle) -> Bool
    /// From now on the object can't be used: maps, faults, pins and acks
    /// are refused.
    static func revoke(_ object: Handle)
    /// Takes what is in use away, and waits it out: a VMO's mappings
    /// removed and shot down, an interrupt masked for good, a BTI's domain
    /// aborted (a BTI with no IOMMU is recorded as untranslated).
    static func clear(_ object: Handle)
    /// Asserts SUPPLY_ENDED on the supply.
    static func signalEnded(_ supply: Handle)
    /// The supply's memory (its last reference is gone).
    static func freeSupply(_ supply: Handle)

    // Waiting.
    static func now() -> UInt64
    /// A value that changes when something the ender waits for may have:
    /// read before the conditions are, so a change in between isn't missed.
    static func changeToken() -> Int64
    /// Blocks until `token` is out of date, or a little while (round `round`)
    /// or `deadline`, whichever comes first.
    static func await(_ token: Int64, round: Int, deadline: UInt64)
    /// The deadline passed with a holder still holding: the forced path.
    static func forced(_ supply: Handle)

    /// Broken variants for the check (D169): the world says which one it
    /// runs. The kernel's are false and compile away.
    static var signalsEndedBeforeClear: Bool { get }
    static var bindsOnEndedSupply: Bool { get }
}

extension SupplyWorld {
    public static var signalsEndedBeforeClear: Bool { false }
    public static var bindsOnEndedSupply: Bool { false }
}

public enum SupplyLife<W: SupplyWorld> {
    /// supply_bind: `object` joins the supply, which holds a reference to
    /// it from now on.
    public static func bind(_ supply: W.Handle, _ object: W.Handle) -> SupplyBindResult {
        W.withLock(supply) { () -> SupplyBindResult in
            if !W.bindsOnEndedSupply, W.state(supply) != .live { return .badState }
            for i in 0..<W.bindingCount(supply) where W.binding(supply, i) == object { return .alreadyBound }
            guard W.lease(object) else { return .badState }
            W.retain(object)
            guard W.appendBinding(supply, object) else {
                W.unlease(object)
                W.release(object)  // not the last: the caller holds one
                return .noMemory
            }
            return .bound
        }
    }

    /// supply_end: false if the supply wasn't live (it is ending or ended
    /// already). Returns when the supply is ended.
    public static func end(_ supply: W.Handle, deadline: UInt64) -> Bool {
        let first = W.withLock(supply) { () -> Bool in
            guard W.state(supply) == .live else { return false }
            W.setState(supply, .ending)
            return true
        }
        guard first else { return false }
        // No more bindings: the list is the ender's.
        let count = W.bindingCount(supply)
        for i in 0..<count { W.signalEnding(W.binding(supply, i)) }

        var round = 0
        var forced = false
        while true {
            let token = W.changeToken()
            var all = true
            for i in 0..<count where !W.released(W.binding(supply, i)) {
                all = false
                break
            }
            if all { break }
            if W.now() >= deadline {
                forced = true
                break
            }
            W.await(token, round: round, deadline: deadline)
            round += 1
        }
        if forced { W.forced(supply) }

        if W.signalsEndedBeforeClear { finish(supply) }
        for i in 0..<count { W.revoke(W.binding(supply, i)) }
        for i in 0..<count { W.clear(W.binding(supply, i)) }
        if !W.signalsEndedBeforeClear { finish(supply) }
        return true
    }

    private static func finish(_ supply: W.Handle) {
        W.withLock(supply) { W.setState(supply, .ended) }
        W.signalEnded(supply)
    }

    /// The supply's last reference is gone: what it bound is let go (a
    /// supply that ended left its objects revoked; one that didn't leaves
    /// them as they are), and its references dropped.
    public static func destroy(_ supply: W.Handle) {
        let count = W.bindingCount(supply)
        for i in 0..<count {
            let object = W.binding(supply, i)
            W.unlease(object)
            W.release(object)
        }
        W.freeSupply(supply)
    }
}
