import DmaLife
import ModelCheck
import Testing

/// A BTI's and its PMTs' lifetimes on the model checker (D166): the
/// kernel's lifetime logic (lib/dmalife/DmaLife.swift, the same file),
/// over a world whose objects are numbers in one checked region. Every
/// world call outside a lock is a step where the checker may switch
/// threads; a lock is one step, its body atomic. The invariants run at
/// every step and at the end.
///
/// The machine: one BTI, two PMTs over the same page, one process each
/// (and a third that releases the quarantine), each holding a handle to
/// the BTI. A process pins its PMT, may unpin it, and closes its handles
/// in an order of its own, as a driver or a process's death does.
enum DmaModel: DmaWorld {
    typealias Handle = Int

    // MARK: State, in one region

    static let theBti = 0
    static let names = ["bti", "pmt1", "pmt2"]
    // Slots of an object (16 a object), then the page's pin count.
    static let refs = 0, freed = 1, handles = 2, sState = 3, holds = 4, sNext = 5, held = 6, mapped = 7, made = 8
    static let livePins = 9, head = 10, quarantinedCount = 11, pending = 12, orphans = 13
    static let pageSlot = 48

    nonisolated(unsafe) static var mem: UnsafeMutablePointer<Int64>! = nil
    nonisolated(unsafe) static var hasDomainConfig = false
    nonisolated(unsafe) static var locked = false
    nonisolated(unsafe) static var restores7c = false
    nonisolated(unsafe) static var noListReference = false

    static var dropsBtiAtUnpin: Bool { restores7c }
    static var quarantineTakesNoReference: Bool { noListReference }

    static func get(_ o: Int, _ k: Int) -> Int64 {
        let value = mem[o * 16 + k]
        Checker.observe(UInt64(bitPattern: value))
        return value
    }
    static func put(_ o: Int, _ k: Int, _ v: Int64) { mem[o * 16 + k] = v }

    /// A world call outside a lock: where threads may switch, and where
    /// the invariants are looked at.
    static func gate(_ what: String, _ o: Int = -1) {
        if locked { return }
        Checker.step(o < 0 ? what : what + " " + names[o])
        invariants()
    }

    static func touch(_ o: Int, _ what: String) {
        Checker.expect(mem[o * 16 + freed] == 0, "\(what): \(names[o]) is freed")
    }

    // MARK: The world

    static func withBtiLock<R>(_ bti: Int, _ body: () -> R) -> R {
        gate("lock", bti)
        touch(bti, "lock")
        locked = true
        defer { locked = false }
        return body()
    }

    static func bti(of pmt: Int) -> Int {
        touch(pmt, "bti(of:)")
        return theBti
    }
    static func hasDomain(_ b: Int) -> Bool {
        touch(b, "domain")
        return hasDomainConfig
    }

    static func state(_ pmt: Int) -> DmaPmtState {
        gate("state?", pmt)
        touch(pmt, "state")
        switch get(pmt, sState) {
        case 0: return .live
        case 1: return .unpinned
        default: return .quarantined
        }
    }
    static func setState(_ pmt: Int, _ s: DmaPmtState) {
        gate("state=", pmt)
        touch(pmt, "setState")
        put(pmt, sState, s == .live ? 0 : s == .unpinned ? 1 : 2)
    }
    static func holdsBti(_ pmt: Int) -> Bool {
        gate("holds?", pmt)
        touch(pmt, "holdsBti")
        return get(pmt, holds) != 0
    }
    static func setHoldsBti(_ pmt: Int, _ h: Bool) {
        gate("holds=", pmt)
        touch(pmt, "setHoldsBti")
        put(pmt, holds, h ? 1 : 0)
    }
    static func next(_ pmt: Int) -> Int? {
        gate("next?", pmt)
        touch(pmt, "next")
        let n = Int(get(pmt, sNext))
        return n == 0 ? nil : n
    }
    static func setNext(_ pmt: Int, _ n: Int?) {
        gate("next=", pmt)
        touch(pmt, "setNext")
        put(pmt, sNext, Int64(n ?? 0))
    }

    static func quarantineHead(_ b: Int) -> Int? {
        gate("head?", b)
        touch(b, "quarantineHead")
        let h = Int(get(b, head))
        return h == 0 ? nil : h
    }
    static func setQuarantineHead(_ b: Int, _ h: Int?) {
        gate("head=", b)
        touch(b, "setQuarantineHead")
        put(b, head, Int64(h ?? 0))
    }
    static func quarantined(_ b: Int) -> UInt64 {
        gate("quarantined?", b)
        touch(b, "quarantined")
        return UInt64(get(b, quarantinedCount))
    }
    static func setQuarantined(_ b: Int, _ count: UInt64) {
        gate("quarantined=", b)
        touch(b, "setQuarantined")
        put(b, quarantinedCount, Int64(count))
    }
    static func addLivePin(_ b: Int) {
        gate("livePins+", b)
        touch(b, "addLivePin")
        put(b, livePins, get(b, livePins) + 1)
        put(b, pending, get(b, pending) - 1)
    }
    static func removeLivePin(_ b: Int) {
        gate("livePins-", b)
        touch(b, "removeLivePin")
        Checker.expect(get(b, livePins) > 0, "livePins below zero")
        put(b, livePins, get(b, livePins) - 1)
    }

    static func retain(_ o: Int) {
        gate("retain", o)
        touch(o, "retain")
        Checker.expect(get(o, refs) > 0, "retain of \(names[o]) after its last release")
        put(o, refs, get(o, refs) + 1)
    }
    static func release(_ o: Int) {
        gate("release", o)
        touch(o, "release")
        Checker.expect(get(o, refs) > 0, "release of \(names[o]) below zero")
        put(o, refs, get(o, refs) - 1)
        guard get(o, refs) == 0 else { return }
        if o == theBti {
            DmaLife<DmaModel>.destroyBti(o)
        } else if !DmaLife<DmaModel>.destroyPmt(o) {
            Checker.expect(false, "\(names[o]) destroyed while pinned")
        }
    }
    static func freePmt(_ p: Int) {
        gate("free", p)
        touch(p, "free")
        Checker.expect(get(p, refs) == 0, "\(names[p]) freed with references")
        put(p, freed, 1)
    }
    static func freeBti(_ b: Int) {
        gate("free", b)
        touch(b, "free")
        Checker.expect(get(b, refs) == 0, "bti freed with references")
        put(b, freed, 1)
    }

    static func unmapIo(_ p: Int) {
        gate("unmap", p)
        touch(p, "unmapIo")
        touch(theBti, "unmapIo reads its BTI's domain")
        put(p, mapped, 0)
    }
    static func dropPages(_ p: Int) {
        gate("unpin pages", p)
        touch(p, "dropPages")
        Checker.expect(get(p, held) == 1, "\(names[p])'s pages unpinned twice")
        put(p, held, 0)
        mem[pageSlot] -= 1
    }
    static func blockDevice(_ b: Int) {
        gate("block device", b)
        touch(b, "blockDevice")
        for p in 1...2 { put(p, mapped, 0) }
    }
    static func releaseIommu(_ b: Int) {
        gate("release iommu", b)
        touch(b, "releaseIommu")
    }
    static func orphaned(_ b: Int, count: UInt64) {
        gate("orphaned", b)
        touch(b, "orphaned")
        put(b, orphans, Int64(count))
    }

    /// The PMT `p` made over the BTI: its page pinned, mapped for the
    /// device behind a domain, its references the VMO's and its own.
    static func make(_ p: Int) -> Int? {
        gate("make", p)
        touch(theBti, "make over")
        put(p, refs, 1)
        put(p, handles, 1)
        put(p, sState, 0)
        put(p, holds, 1)
        put(p, held, 1)
        put(p, mapped, hasDomainConfig ? 1 : 0)
        put(p, made, 1)
        mem[pageSlot] += 1
        put(theBti, pending, get(theBti, pending) + 1)
        return p
    }

    // MARK: Invariants (D166 §3)

    static func invariants() {
        var holders: Int64 = 0, live: Int64 = 0, held: Int64 = 0
        for p in 1...2 where mem[p * 16 + made] != 0 {
            let isFreed = mem[p * 16 + freed] != 0
            let s = mem[p * 16 + sState], h = mem[p * 16 + DmaModel.held]
            held += h
            if isFreed {
                Checker.expect(h == 0, "\(names[p]) freed with its pages still pinned")
                Checker.expect(mem[p * 16 + mapped] == 0, "\(names[p]) freed with the device still mapped to it")
                continue
            }
            if mem[p * 16 + holds] != 0 { holders += 1 }
            if s == 0 { live += 1 }
            if s != 1 { Checker.expect(h == 1, "\(names[p]) is pinned or quarantined but its pages aren't") }
            if mem[p * 16 + mapped] != 0 { Checker.expect(h == 1, "the device is mapped to \(names[p])'s unpinned page") }
        }
        Checker.expect(mem[pageSlot] == held, "the page's pin count \(mem[pageSlot]) is not its PMTs' \(held)")
        Checker.expect(mem[theBti * 16 + refs] >= mem[theBti * 16 + handles] + holders,
                       "the BTI has \(mem[theBti * 16 + refs]) references for \(mem[theBti * 16 + handles]) handles and \(holders) PMTs")
        // Past its last reference the BTI is being destroyed: its list is walked.
        guard mem[theBti * 16 + freed] == 0, mem[theBti * 16 + refs] > 0 else { return }
        Checker.expect(mem[theBti * 16 + livePins] + mem[theBti * 16 + pending] == live,
                       "the BTI counts \(mem[theBti * 16 + livePins]) live pins and \(mem[theBti * 16 + pending]) coming, the PMTs \(live)")
        var length: Int64 = 0
        var at = Int(mem[theBti * 16 + head])
        while at != 0, length < 3 {
            length += 1
            let p = at
            Checker.expect(mem[p * 16 + freed] == 0, "\(names[p]) is freed but on the quarantine list")
            Checker.expect(mem[p * 16 + sState] == 2, "\(names[p]) is on the quarantine list but not quarantined")
            Checker.expect(mem[p * 16 + refs] >= mem[p * 16 + handles] + 1,
                           "\(names[p]) is on the quarantine list without the list's reference")
            at = Int(mem[p * 16 + sNext])
        }
        Checker.expect(length == mem[theBti * 16 + quarantinedCount],
                       "the BTI counts \(mem[theBti * 16 + quarantinedCount]) quarantined PMTs, its list has \(length)")
    }

    /// At the end: everything freed once, but the pinned pages an
    /// orphaned BTI left, which are exactly the PMTs it quarantined.
    static func finalCheck(_ done: [Bool]) -> String? {
        if !done.allSatisfy({ $0 }) { return "a thread didn't finish" }
        if mem[theBti * 16 + freed] == 0 { return "the BTI was never freed (refs \(mem[theBti * 16 + refs]))" }
        var left: Int64 = 0
        for p in 1...2 where mem[p * 16 + made] != 0 {
            if mem[p * 16 + freed] != 0 { continue }
            left += 1
            guard mem[p * 16 + sState] == 2, mem[p * 16 + refs] == 1, mem[p * 16 + held] == 1 else {
                return "\(names[p]) was never freed (state \(mem[p * 16 + sState]), refs \(mem[p * 16 + refs]))"
            }
        }
        if left != mem[theBti * 16 + orphans] { return "\(left) PMTs left pinned, the BTI orphaned \(mem[theBti * 16 + orphans])" }
        if hasDomainConfig, left != 0 { return "PMTs left pinned behind a domain" }
        if mem[pageSlot] != left { return "the page is pinned \(mem[pageSlot]) times, by \(left) PMTs" }
        return nil
    }
}

@Suite(.serialized)
struct DmaLifeCheckTests {
    enum Step {
        case pin(Int), unpin(Int), closePmt(Int), closeBti, releaseQuarantine
    }

    typealias World = DmaLife<DmaModel>

    /// A process: its steps in order, each a pmt handle's or the BTI's.
    static func run(_ steps: [Step]) {
        for step in steps {
            switch step {
            case .pin(let p):
                let made = World.pinned(DmaModel.theBti) { DmaModel.make(p) }
                Checker.expect(made == p, "pin failed")
            case .unpin(let p):
                Checker.expect(World.unpin(p), "unpin of a live PMT refused")
            case .closePmt(let p):
                DmaModel.gate("close handle", p)
                DmaModel.touch(p, "close handle")
                DmaModel.put(p, DmaModel.handles, 0)
                World.handleClosed(p)
                DmaModel.release(p)
            case .closeBti:
                DmaModel.gate("close handle", DmaModel.theBti)
                DmaModel.put(DmaModel.theBti, DmaModel.handles, DmaModel.get(DmaModel.theBti, DmaModel.handles) - 1)
                DmaModel.release(DmaModel.theBti)
            case .releaseQuarantine:
                World.releaseQuarantine(DmaModel.theBti)
            }
        }
    }

    static func check(_ name: String, domain: Bool, _ processes: [[Step]],
                      restores7c: Bool = false, noListReference: Bool = false) -> Checker.Result {
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 8, alignment: 8)
        defer { region.deallocate() }
        DmaModel.mem = region.baseAddress!.assumingMemoryBound(to: Int64.self)
        DmaModel.hasDomainConfig = domain
        DmaModel.restores7c = restores7c
        DmaModel.noListReference = noListReference
        DmaModel.locked = false
        defer {
            DmaModel.restores7c = false
            DmaModel.noListReference = false
        }
        let model = Checker.Model(
            name: name + (domain ? ", domain" : ", no domain"), regions: [region],
            reset: {
                DmaModel.locked = false
                DmaModel.put(DmaModel.theBti, DmaModel.refs, Int64(processes.count))
                DmaModel.put(DmaModel.theBti, DmaModel.handles, Int64(processes.count))
            },
            threads: processes.map { steps in { run(steps) } },
            final: { done, _ in DmaModel.finalCheck(done) })
        return Checker.check(model)
    }

    /// The machines: two or three processes with a handle each to the BTI,
    /// two of them with a PMT of their own.
    static let machines: [(String, [[Step]])] = [
        // 7c: the BTI's handle closed before the PMT is unpinned.
        ("close before unpin", [
            [.pin(1), .closeBti, .unpin(1), .closePmt(1)],
            [.pin(2), .closePmt(2), .closeBti],
            [.releaseQuarantine, .closeBti],
        ]),
        // Process death: the PMT's handle closed while pinned, the BTI's
        // after or between.
        ("death", [
            [.pin(1), .closePmt(1), .closeBti],
            [.pin(2), .closeBti, .closePmt(2)],
        ]),
        ("unpin, release", [
            [.pin(1), .unpin(1), .closePmt(1), .closeBti],
            [.pin(2), .closePmt(2), .releaseQuarantine, .closeBti],
        ]),
    ]

    @Test(arguments: [false, true])
    func lifetimes(_ domain: Bool) {
        for (name, processes) in Self.machines {
            let result = Self.check(name, domain: domain, processes)
            #expect(result.ok, "\(result.failure ?? "")")
            #expect(result.finals > 0)
            print("dma check: \(name), \(domain ? "domain" : "no domain"): \(result.states) states, "
                  + "\(result.executions) runs")
        }
    }

    /// The 7c bug restored (the PMT lets go of its BTI at unpin, not at
    /// destroy) and the quarantine taken without the list's reference:
    /// the checker finds each.
    @Test(arguments: [false, true])
    func brokenVariants(_ domain: Bool) {
        let closeBeforeUnpin = Self.machines[0].1
        let broken = [
            ("the PMT drops its BTI at unpin",
             Self.check("7c", domain: domain, closeBeforeUnpin, restores7c: true)),
            ("the quarantine without the list's reference",
             Self.check("no list reference", domain: domain, Self.machines[1].1, noListReference: true)),
        ]
        for (name, result) in broken {
            #expect(!result.ok, "\(name) should fail")
            if let failure = result.failure { print("dma check: \(name), as expected: \(failure.prefix(160))") }
        }
    }
}
