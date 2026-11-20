import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for supply leases (D169): a supply over an MMIO range,
/// with a physical VMO bound and mapped. One that is ended with a holder
/// that never lets go: at the deadline the mapping is gone, a fault in it is
/// refused, the VMO can't be mapped again. One whose holder unmaps and
/// closes when told: the end takes no forced path, and its time is the
/// `supply.end_to_clear` budget. A BTI and an interrupt bound and revoked.
/// The state machine's own interleavings are SupplyCheckTests'. Nothing is
/// read from the device (the page just has to exist as a physical range):
/// the probes ask the page tables and the fault handler. Panics on failure.
enum SupplySelfTest {
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var tableAddress: UInt64 = 0
    nonisolated(unsafe) static var heldObject: UInt64 = 0
    nonisolated(unsafe) static var heldHandle: UInt32 = 0
    nonisolated(unsafe) static var heldAt: UInt64 = 0
    nonisolated(unsafe) static var faultAt: UInt64 = 0

    /// A physical range no RAM covers, for a window nothing reads.
    private static var devicePage: UInt64 {
        #if arch(x86_64)
        return 0xFED0_0000  // the HPET's
        #elseif arch(arm64)
        return 0x0900_0000  // QEMU virt's UART
        #else
        return 0x1000_0000  // QEMU virt's UART
        #endif
    }

    static func run(_ console: Uart) {
        let page = KernelLayout.pageSize
        let base = devicePage
        guard !PhysicalMap.overlapsDenied(base, page) else {
            console.write("  supply: no device page to bind on this machine, skipped\n")
            return
        }
        let liveBefore = Objects.live.load(ordering: .relaxed)
        let forcedBefore = Supplies.forcedEnds.load(ordering: .relaxed)
        let ending = UInt32(CROI_SIGNAL_SUPPLY_ENDING), ended = UInt32(CROI_SIGNAL_SUPPLY_ENDED)
        var median: UInt64 = 0
        do throws(VmError) {
            let space = try UserAspace()
            aspace = space.record.address
            let table = HandleTable()
            tableAddress = table.address

            // A supply over the page; the resource isn't kept.
            let supply = newSupply(base, page)

            // One that is ended with its holder holding: the deadline.
            let vmo = try Vmo(physical: base, size: page, cache: .device)
            let object = wrapped(vmo)
            let handle = added(table, object)
            let at = try space.map(vmo, size: page, rights: .read)
            expect(space.query(at) != nil, "the window isn't mapped")
            expect(status({ () throws(Status) in try Supplies.bind(supply, object) }) == nil, "bind")
            expect(status({ () throws(Status) in try Supplies.bind(supply, object) }) == .alreadyBound, "bound twice")
            expect(status({ () throws(Status) in try Supplies.bind(supply, supply) }) == .wrongType, "a supply bound")
            // Not in the supply's resource: refused.
            let elsewhere = try Vmo(physical: base + 4 * page, size: page, cache: .device)
            let other = wrapped(elsewhere)
            expect(status({ () throws(Status) in try Supplies.bind(supply, other) }) == .invalidArgs, "outside the resource")
            other.release()
            expect(object.signals & ending == 0 && supply.signals & ended == 0, "signals before the end")

            let started = Clock.now()
            expect(status({ () throws(Status) in try Supplies.end(supply, deadline: started + 2_000_000) }) == nil, "end")
            let forcedTook = Clock.now() - started
            expect(forcedTook >= 2_000_000, "ended before its deadline with the holder holding")
            expect(Supplies.forcedEnds.load(ordering: .relaxed) == forcedBefore + 1, "the forced path wasn't taken")
            expect(object.signals & ending != 0 && supply.signals & ended != 0, "SUPPLY_ENDING / SUPPLY_ENDED")
            expect(space.query(at) == nil, "the mapping survived the end")
            faultAt = at
            expect(run(fault) == Int(Status.accessDenied.rawValue), "a fault in the window was resolved")
            expect(space.query(at) == nil, "the fault mapped it again")
            do throws(VmError) {
                _ = try space.map(vmo, size: page, rights: .read)
                panic("supply self-test: an ended supply's window was mapped")
            } catch {
                expect(error == .badState, "map error")
            }
            expect(status({ () throws(Status) in try Supplies.end(supply, deadline: 0) }) == .badState, "ended twice")
            let late = newSupply(base, page)
            expect(status({ () throws(Status) in try Supplies.bind(late, object) }) == .badState, "bound after its supply ended")
            late.release()
            try? table.close(handle)
            supply.release()

            // A holder that lets go when told: no forced path.
            var times = InlineArray<5, UInt64>(repeating: 0)
            for i in 0..<5 {
                let supply = newSupply(base, page)
                let vmo = try Vmo(physical: base, size: page, cache: .device)
                let object = wrapped(vmo)
                let handle = added(table, object)
                let at = try space.map(vmo, size: page, rights: .read)
                expect(status({ () throws(Status) in try Supplies.bind(supply, object) }) == nil, "bind")
                heldObject = object.address
                heldHandle = handle
                heldAt = at
                let holder: ThreadHandle
                do throws(VmError) {
                    holder = try Scheduler.spawn("supply", release, 0)
                } catch {
                    panic("supply self-test: spawn failed")
                }
                let begin = Clock.now()
                expect(status({ () throws(Status) in try Supplies.end(supply, deadline: begin + 2_000_000_000) }) == nil, "end 2")
                times[i] = Clock.now() - begin
                expect(holder.join() == 0, "the holder failed")
                expect(Supplies.forcedEnds.load(ordering: .relaxed) == forcedBefore + 1, "a forced path with a holder that let go")
                expect(space.query(at) == nil, "the window is still mapped")
                expect(supply.signals & ended != 0, "SUPPLY_ENDED")
                expect(VmoPointer(address: UnsafeVmoObject(object).vmo).leaseRevoked, "not revoked")
                supply.release()
            }
            // The median of five.
            for i in 0..<5 {
                for j in (i + 1)..<5 where times[j] < times[i] { (times[i], times[j]) = (times[j], times[i]) }
            }
            median = times[2]

            // A BTI with no IOMMU and an interrupt, bound and revoked.
            guard let btiObject = Objects.allocate(BtiObject(btiId: 0)) else { panic("supply self-test: memory") }
            let interrupt = made { () throws(Status) in try InterruptObjects.makeForMsi() }
            let both = newSupply(base, page)
            expect(status({ () throws(Status) in try Supplies.bind(both, btiObject) }) == nil, "bind a BTI")
            expect(status({ () throws(Status) in try Supplies.bind(both, interrupt) }) == nil, "bind an interrupt")
            expect(status({ () throws(Status) in try Supplies.end(both, deadline: 0) }) == nil, "end both")
            expect(Dma.btiRevoked(btiObject), "BTI not revoked")
            let again = newSupply(base, page)
            expect(status({ () throws(Status) in try Supplies.bind(again, btiObject) }) == .badState, "a revoked BTI bound")
            expect(status({ () throws(Status) in try Supplies.bind(again, interrupt) }) == .badState, "a revoked interrupt bound")
            again.release()
            both.release()
            interrupt.release()
            btiObject.release()
            _ = space
        } catch {
            panic("supply self-test: out of memory")
        }
        aspace = 0
        guard Supplies.forcedEnds.load(ordering: .relaxed) == forcedBefore + 1 else { panic("supply self-test: forced ends") }
        guard Objects.live.load(ordering: .relaxed) == liveBefore else { panic("supply self-test: objects leaked") }
        console.write("  supply: bound window mapped and taken away at the deadline (a fault is refused, no new map), ")
        console.write("a holder that lets go ends with no forced path, BTI and interrupt revoked\n")
        Budgets.report(console, "supply.end_to_clear", median)
    }

    /// The holder: waits to be told, then unmaps its window and closes its handle.
    private static let release: Thread.Entry = { _ in
        let object = ObjectPointer(address: heldObject)
        let giveUp = Clock.now() + 1_000_000_000
        while object.signals & UInt32(CROI_SIGNAL_SUPPLY_ENDING) == 0 {
            guard Clock.now() < giveUp else { return 1 }
            Scheduler.yield()
        }
        do throws(VmError) {
            try UserAspace.withView(UserAspacePointer(address: aspace)) { (view: borrowing UserAspace) throws(VmError) in
                try view.unmap(mappingAt: heldAt)
            }
        } catch {
            return 2
        }
        do throws(Status) {
            try HandleTable.withBorrowed(tableAddress) { (table: borrowing HandleTable) throws(Status) in
                try table.close(heldHandle)
            }
        } catch {
            return 3
        }
        return 0
    }

    /// A fault in the window, as a user thread's access would be: its status.
    private static let fault: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        do throws(Status) {
            try UserAspaces.handleFault(at: faultAt, write: false, execute: false)
            return 0
        } catch {
            return Int(error.rawValue)
        }
    }

    private static func run(_ entry: Thread.Entry) -> Int {
        do throws(VmError) {
            return try Scheduler.spawn("supply", entry, 0).join()
        } catch {
            panic("supply self-test: spawn failed")
        }
    }

    /// A resource over `[base, base+size)` of MMIO, made directly (the root
    /// filter refuses the pages the kernel itself drives).
    private static func makeResource(_ base: UInt64, _ size: UInt64) -> ObjectPointer {
        guard let object = Objects.allocate(ResourceObject(kind: UInt32(CROI_RSRC_KIND_MMIO), base: base, size: size,
                                                           flags: 0)) else { panic("supply self-test: memory") }
        return object
    }

    /// A supply over [base, base+size); the resource isn't kept.
    private static func newSupply(_ base: UInt64, _ size: UInt64) -> ObjectPointer {
        let resource = makeResource(base, size)
        defer { resource.release() }
        return made { () throws(Status) in try Supplies.create(resource: resource) }
    }

    private static func made(_ body: () throws(Status) -> ObjectPointer) -> ObjectPointer {
        do throws(Status) {
            return try body()
        } catch {
            panic("supply self-test: make failed")
        }
    }

    private static func wrapped(_ vmo: borrowing Vmo) -> ObjectPointer {
        do throws(Status) {
            return try VmoObject.wrap(vmo.record)
        } catch {
            panic("supply self-test: wrap failed")
        }
    }

    /// A handle to `object` (consuming the caller's reference, which stays
    /// good while the handle is open).
    private static func added(_ table: borrowing HandleTable, _ object: ObjectPointer) -> UInt32 {
        do throws(Status) {
            return try table.add(object, rights: VmoObject.physicalRights)
        } catch {
            panic("supply self-test: handle table")
        }
    }

    private static func status(_ body: () throws(Status) -> Void) -> Status? {
        do throws(Status) {
            try body()
            return nil
        } catch {
            return error
        }
    }

    private static func expect(_ condition: Bool, _ what: StaticString) {
        guard condition else {
            panic(what)
        }
    }
}
