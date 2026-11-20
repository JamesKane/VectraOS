import ModelCheck
import SupplyLife
import Testing

/// A supply's lifetime on the model checker (D169, D166's pattern): the
/// kernel's logic (lib/supplylife/SupplyLife.swift, the same file) over a
/// world whose supplies and objects are numbers in one checked region. Every
/// world call outside a lock is a step where the checker may switch
/// threads; a lock is one step, its body atomic. The invariants run at every
/// step and at the end.
///
/// The machine: up to two supplies, and a VMO (a register window), an
/// interrupt and a BTI that providers bind to them while a holder maps,
/// waits for SUPPLY_ENDING, and lets go (or doesn't, until the deadline).
enum SupplyModel: SupplyWorld {
    typealias Handle = Int

    // MARK: State, in one region

    // Supplies 1, 2; objects 3 (VMO), 4 (interrupt), 5 (BTI). 16 slots each.
    static let supplies = [1, 2], objects = [3, 4, 5]
    static let vmo = 3, irq = 4, bti = 5
    static let names = ["-", "S1", "S2", "vmo", "irq", "bti"]
    // Common.
    static let refs = 0, freed = 1, handles = 2
    // A supply.
    static let sState = 3, nb = 4, b0 = 5, endedSig = 8, forcedFlag = 9, nbAtEnd = 10, ended = 11
    // An object.
    static let leases = 3, revoked = 4, endingSig = 5, mapped = 6, cleared = 7, stopped = 8
    // Counters: 0 progress (something the ender waits for may have changed),
    // 8 a supply ended, 9 any object told its supply is ending.
    static let progress = 0, endedCounter = 8, endingCounter = 9

    nonisolated(unsafe) static var mem: UnsafeMutablePointer<Int64>! = nil
    nonisolated(unsafe) static var hasDomain = false
    nonisolated(unsafe) static var locked = false
    nonisolated(unsafe) static var endsBeforeClear = false
    nonisolated(unsafe) static var bindsOnEnded = false

    static var signalsEndedBeforeClear: Bool { endsBeforeClear }
    static var bindsOnEndedSupply: Bool { bindsOnEnded }

    static func get(_ o: Int, _ k: Int) -> Int64 {
        let value = mem[o * 16 + k]
        Checker.observe(UInt64(bitPattern: value))
        return value
    }
    static func put(_ o: Int, _ k: Int, _ v: Int64) { mem[o * 16 + k] = v }

    static func gate(_ what: String, _ o: Int = -1) {
        if locked { return }
        Checker.step(o < 0 ? what : what + " " + names[o])
        invariants()
    }

    static func touch(_ o: Int, _ what: String) {
        Checker.expect(mem[o * 16 + freed] == 0, "\(what): \(names[o]) is freed")
    }

    // MARK: The world

    static func withLock<R>(_ supply: Int, _ body: () -> R) -> R {
        gate("lock", supply)
        touch(supply, "lock")
        locked = true
        defer { locked = false }
        return body()
    }

    static func state(_ s: Int) -> SupplyState {
        gate("state?", s)
        touch(s, "state")
        switch get(s, sState) {
        case 0: return .live
        case 1: return .ending
        default: return .ended
        }
    }
    static func setState(_ s: Int, _ state: SupplyState) {
        gate("state=", s)
        touch(s, "setState")
        put(s, sState, state == .live ? 0 : state == .ending ? 1 : 2)
        if state == .ending { put(s, nbAtEnd, get(s, nb)) }
        if state == .ended { put(s, ended, 1) }
    }
    // The list is read where nobody changes it (the lock's body, or after the supply stopped taking
    // bindings): not a step.
    static func bindingCount(_ s: Int) -> Int {
        touch(s, "bindingCount")
        return Int(get(s, nb))
    }
    static func binding(_ s: Int, _ i: Int) -> Int {
        touch(s, "binding")
        return Int(get(s, b0 + i))
    }
    static func appendBinding(_ s: Int, _ o: Int) -> Bool {
        gate("append", s)
        touch(s, "appendBinding")
        let n = Int(get(s, nb))
        guard n < 3 else { return false }
        put(s, b0 + n, Int64(o))
        put(s, nb, Int64(n + 1))
        return true
    }

    static func kind(_ o: Int) -> SupplyKind { o == vmo ? .vmo : o == irq ? .interrupt : .bti }

    static func lease(_ o: Int) -> Bool {
        gate("lease", o)
        touch(o, "lease")
        guard get(o, revoked) == 0 else { return false }
        put(o, leases, get(o, leases) + 1)
        return true
    }
    static func unlease(_ o: Int) {
        gate("unlease", o)
        touch(o, "unlease")
        Checker.expect(get(o, leases) > 0, "leases of \(names[o]) below zero")
        put(o, leases, get(o, leases) - 1)
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
        if get(o, refs) == 0 {
            Checker.expect(get(o, handles) == 0, "\(names[o]) freed with handles")
            put(o, freed, 1)
        }
    }
    static func signalEnding(_ o: Int) {
        gate("signal ending", o)
        touch(o, "signalEnding")
        put(o, endingSig, 1)
        Checker.kernelAdd(endingCounter)
    }
    static func released(_ o: Int) -> Bool {
        gate("released?", o)
        touch(o, "released")
        if get(o, handles) != 0 { return false }
        return o != vmo || get(o, mapped) == 0
    }
    static func revoke(_ o: Int) {
        gate("revoke", o)
        touch(o, "revoke")
        put(o, revoked, 1)
    }
    static func clear(_ o: Int) {
        gate("clear", o)
        touch(o, "clear")
        Checker.expect(get(o, revoked) == 1, "\(names[o]) cleared before it was revoked")
        switch kind(o) {
        case .vmo: put(o, mapped, 0)
        case .interrupt: put(o, stopped, 1)  // masked
        case .bti: put(o, stopped, hasDomain ? 1 : 2)  // aborted, or recorded untranslated
        }
        put(o, cleared, 1)
    }
    static func signalEnded(_ s: Int) {
        gate("signal ended", s)
        touch(s, "signalEnded")
        Checker.expect(get(s, sState) == 2, "SUPPLY_ENDED before the supply is ended")
        put(s, endedSig, 1)
        Checker.kernelAdd(endedCounter)
        Checker.kernelAdd(endingCounter)
    }
    static func freeSupply(_ s: Int) {
        gate("free", s)
        touch(s, "free")
        Checker.expect(get(s, refs) == 0, "\(names[s]) freed with references")
        put(s, freed, 1)
    }

    static func now() -> UInt64 {
        gate("now")
        let value = mem[clockSlot]
        Checker.observe(UInt64(bitPattern: value))
        return UInt64(value)
    }
    static func changeToken() -> Int64 { Checker.kernelLoad(progress) }
    static func await(_ token: Int64, round: Int, deadline: UInt64) {
        Checker.kernelWaitAbove(progress, token)
    }
    static func forced(_ s: Int) {
        gate("forced", s)
        touch(s, "forced")
        Checker.expect(mem[clockSlot] >= deadlineValue, "the forced path before the deadline")
        put(s, forcedFlag, 1)
    }

    static let clockSlot = 112
    static let deadlineValue: Int64 = 50

    // MARK: The processes' own operations

    /// A holder maps the window, if its VMO isn't revoked (the object's lock:
    /// the check and the map are one step).
    static func tryMap() {
        gate("map", vmo)
        touch(vmo, "map")
        if get(vmo, revoked) != 0 { return }
        for s in supplies where get(s, ended) != 0 {
            for i in 0..<Int(get(s, nb)) where get(s, b0 + i) == Int64(vmo) {
                Checker.expect(false, "the window was mapped though \(names[s]) ended")
            }
        }
        put(vmo, mapped, get(vmo, mapped) + 1)
    }
    static func unmap() {
        gate("unmap", vmo)
        touch(vmo, "unmap")
        put(vmo, mapped, 0)
        Checker.kernelAdd(progress)
    }
    /// A handle to an object closed: its reference too.
    static func closeObjectHandle(_ o: Int) {
        gate("close handle", o)
        touch(o, "close handle")
        Checker.expect(get(o, handles) > 0, "handle of \(names[o]) closed twice")
        put(o, handles, get(o, handles) - 1)
        put(o, refs, get(o, refs) - 1)
        if get(o, refs) == 0 {
            Checker.expect(get(o, handles) == 0, "\(names[o]) freed with handles")
            put(o, freed, 1)
        }
        Checker.kernelAdd(progress)
    }

    // MARK: Invariants (D169 §8)

    static func invariants() {
        for s in supplies where mem[s * 16 + freed] == 0 && mem[s * 16 + refs] > 0 {
            let state = mem[s * 16 + sState]
            let count = Int(mem[s * 16 + nb])
            if state != 0 {
                Checker.expect(mem[s * 16 + nbAtEnd] == Int64(count), "\(names[s]) took a binding after it began to end")
            }
            if mem[s * 16 + endedSig] != 0 {
                Checker.expect(state == 2, "\(names[s]) is signalled ended but isn't")
            }
            if state == 2 {
                // Ended: nothing bound is usable and nothing is in use.
                for i in 0..<count {
                    let o = Int(mem[s * 16 + b0 + i])
                    Checker.expect(mem[o * 16 + revoked] == 1, "\(names[s]) is ended but \(names[o]) isn't revoked")
                    Checker.expect(mem[o * 16 + cleared] == 1, "\(names[s]) is ended but \(names[o]) isn't cleared")
                    if o == vmo { Checker.expect(mem[o * 16 + mapped] == 0, "\(names[s]) is ended but its window is mapped") }
                    if o == irq { Checker.expect(mem[o * 16 + stopped] == 1, "\(names[s]) is ended but its interrupt isn't masked") }
                    if o == bti {
                        Checker.expect(mem[o * 16 + stopped] == (hasDomain ? 1 : 2),
                                       "\(names[s]) is ended but its BTI is neither aborted nor recorded untranslated")
                    }
                }
            }
            if mem[s * 16 + forcedFlag] != 0 { Checker.expect(mem[clockSlot] >= deadlineValue, "forced before the deadline") }
        }
        for o in objects where mem[o * 16 + freed] == 0 {
            Checker.expect(mem[o * 16 + refs] >= mem[o * 16 + handles], "\(names[o]) has fewer references than handles")
            Checker.expect(mem[o * 16 + leases] >= 0, "\(names[o])'s leases below zero")
        }
    }

    /// At the end: everything freed once, and the forced path as the machine
    /// says.
    static func finalCheck(_ done: [Bool], _ expectForced: Bool?, _ supplyCount: Int) -> String? {
        if !done.allSatisfy({ $0 }) { return "a thread didn't finish" }
        for s in supplies.prefix(supplyCount) where mem[s * 16 + freed] == 0 {
            return "\(names[s]) was never freed (refs \(mem[s * 16 + refs]))"
        }
        for o in objects where mem[o * 16 + freed] == 0 {
            return "\(names[o]) was never freed (refs \(mem[o * 16 + refs]), leases \(mem[o * 16 + leases]))"
        }
        for o in objects where mem[o * 16 + leases] != 0 { return "\(names[o]) is still leased" }
        if let expectForced {
            let any = supplies.prefix(supplyCount).contains { mem[$0 * 16 + forcedFlag] != 0 }
            if any != expectForced { return expectForced ? "the deadline was never used" : "the forced path with a holder that let go" }
        }
        return nil
    }
}

@Suite(.serialized)
struct SupplyCheckTests {
    enum Step {
        case bind(Int, Int), end(Int), closeSupply(Int)
        case map, awaitAny, awaitEnded, unmap, close(Int), tick
    }

    typealias World = SupplyLife<SupplyModel>

    static func run(_ steps: [Step]) {
        for step in steps {
            switch step {
            case .bind(let s, let o):
                _ = World.bind(s, o)
            case .end(let s):
                _ = World.end(s, deadline: UInt64(SupplyModel.deadlineValue))
            case .closeSupply(let s):
                SupplyModel.gate("close handle", s)
                SupplyModel.touch(s, "close handle")
                SupplyModel.put(s, SupplyModel.handles, SupplyModel.get(s, SupplyModel.handles) - 1)
                SupplyModel.put(s, SupplyModel.refs, SupplyModel.get(s, SupplyModel.refs) - 1)
                if SupplyModel.get(s, SupplyModel.refs) == 0 { World.destroy(s) }
            case .map:
                SupplyModel.tryMap()
            case .awaitAny:
                Checker.kernelWaitAbove(SupplyModel.endingCounter, 0)
            case .awaitEnded:
                Checker.kernelWaitAbove(SupplyModel.endedCounter, 0)
            case .unmap:
                SupplyModel.unmap()
            case .close(let o):
                SupplyModel.closeObjectHandle(o)
            case .tick:
                SupplyModel.gate("tick")
                SupplyModel.mem[SupplyModel.clockSlot] = 100
                Checker.kernelAdd(SupplyModel.progress)
            }
        }
    }

    struct Machine {
        var name: String
        /// Each process, and how many supply handles it holds (they start
        /// with one reference each).
        var processes: [[Step]]
        var supplyHandles: [Int]
        var expectForced: Bool?
    }

    static func check(_ machine: Machine, domain: Bool, endsBeforeClear: Bool = false,
                      bindsOnEnded: Bool = false) -> Checker.Result {
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: 128 * 8, alignment: 8)
        defer { region.deallocate() }
        SupplyModel.mem = region.baseAddress!.assumingMemoryBound(to: Int64.self)
        SupplyModel.hasDomain = domain
        SupplyModel.locked = false
        SupplyModel.endsBeforeClear = endsBeforeClear
        SupplyModel.bindsOnEnded = bindsOnEnded
        defer {
            SupplyModel.endsBeforeClear = false
            SupplyModel.bindsOnEnded = false
        }
        let supplyCount = machine.supplyHandles.count
        let model = Checker.Model(
            name: machine.name + (domain ? ", domain" : ", no domain"), regions: [region], counters: 10,
            reset: {
                SupplyModel.locked = false
                // A handle to an object for each close step: what a process holds of it.
                for o in SupplyModel.objects {
                    var held: Int64 = 0
                    for steps in machine.processes { for case .close(let c) in steps where c == o { held += 1 } }
                    SupplyModel.put(o, SupplyModel.refs, held)
                    SupplyModel.put(o, SupplyModel.handles, held)
                    if held == 0 { SupplyModel.put(o, SupplyModel.freed, 1) }  // not in this machine
                }
                for (i, handles) in machine.supplyHandles.enumerated() {
                    SupplyModel.put(i + 1, SupplyModel.refs, Int64(handles))
                    SupplyModel.put(i + 1, SupplyModel.handles, Int64(handles))
                }
            },
            threads: machine.processes.map { steps in { run(steps) } },
            final: { done, _ in SupplyModel.finalCheck(done, machine.expectForced, supplyCount) })
        return Checker.check(model)
    }

    static let vmo = SupplyModel.vmo, irq = SupplyModel.irq, bti = SupplyModel.bti

    /// Each process holds a handle to what it binds, as a syscall's caller
    /// does, and closes it before the supply ends (an end waits for every
    /// handle to be closed).
    static let machines: [Machine] = [
        // A holder that lets go when told: the deadline is never needed.
        Machine(name: "prompt holder",
                processes: [[.bind(1, vmo), .bind(1, irq), .bind(1, bti), .close(vmo), .close(irq), .close(bti),
                             .end(1), .closeSupply(1)],
                            [.map, .awaitAny, .map, .unmap, .close(vmo), .close(irq), .close(bti)]],
                supplyHandles: [1], expectForced: false),
        // A holder that doesn't until the supply has ended: the deadline.
        Machine(name: "stubborn holder",
                processes: [[.bind(1, vmo), .bind(1, irq), .bind(1, bti), .close(vmo), .close(irq), .close(bti),
                             .end(1), .closeSupply(1)],
                            [.map, .awaitEnded, .unmap, .close(vmo), .close(irq), .close(bti)],
                            [.tick]],
                supplyHandles: [1], expectForced: true),
        // Two providers: one binds while the other ends.
        Machine(name: "bind races end",
                processes: [[.bind(1, vmo), .close(vmo), .end(1), .closeSupply(1)],
                            [.bind(1, irq), .close(irq), .closeSupply(1)],
                            [.map, .awaitAny, .unmap, .close(vmo), .close(irq)]],
                supplyHandles: [2], expectForced: false),
        // The window bound to two supplies, one ended and one closed live: a bind to the
        // revoked window is refused, or the window is on both.
        Machine(name: "two supplies",
                processes: [[.bind(1, vmo), .close(vmo), .end(1), .closeSupply(1)],
                            [.bind(2, vmo), .close(vmo), .closeSupply(2)],
                            [.map, .unmap, .close(vmo)]],
                supplyHandles: [1, 1], expectForced: nil),
        // A supply closed without ending: what it bound goes on as it was.
        Machine(name: "closed live",
                processes: [[.bind(1, vmo), .bind(1, bti), .close(vmo), .close(bti), .closeSupply(1)],
                            [.map, .unmap, .map, .unmap, .close(vmo), .close(bti)]],
                supplyHandles: [1], expectForced: nil),
    ]

    @Test(arguments: [false, true])
    func lifetimes(_ domain: Bool) {
        for machine in Self.machines {
            // The domain matters to a BTI only.
            if domain, !machine.processes.joined().contains(where: { if case .close(SupplyModel.bti) = $0 { true } else { false } }) { continue }
            let result = Self.check(machine, domain: domain)
            #expect(result.ok, "\(result.failure ?? "")")
            #expect(result.finals > 0)
            print("supply check: \(machine.name), \(domain ? "domain" : "no domain"): \(result.states) states, "
                  + "\(result.executions) runs")
        }
    }

    /// The safeguards each shown able to fail: the supply signalled ended
    /// before its objects are taken away, and a bind taken on a supply that
    /// is ending or ended.
    @Test(arguments: [false, true])
    func brokenVariants(_ domain: Bool) {
        let broken = [
            ("ended signalled before the clear", Self.check(Self.machines[0], domain: domain, endsBeforeClear: true)),
            ("a bind accepted on an ending supply", Self.check(Self.machines[2], domain: domain, bindsOnEnded: true)),
        ]
        for (name, result) in broken {
            #expect(!result.ok, "\(name) should fail")
            if let failure = result.failure { print("supply check: \(name), as expected: \(failure.prefix(160))") }
        }
    }
}
