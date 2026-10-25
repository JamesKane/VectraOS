import Synchronization
import CKernel

/// Device interrupts for interrupt objects (K9c): handlers by number
/// (amd64 GSI, arm64 INTID, rv64 GSI), routed to one CPU and masked while
/// nobody handles it. The per-arch controller code is in Interrupts.swift.
///
/// A level-triggered number may have up to `sharers` interrupt objects of
/// the same mode, as PCI's INTx lines are shared: a fire goes to each, and
/// the line stays masked while any of them holds it (`hold`, until its
/// ack). An edge-triggered number has one.
///
/// `tableLock` guards the handler table and is held while a handler runs,
/// so once `unregister` returns, no handler for that number is running.
/// `controllerLock` serializes controller programming and guards the
/// holds. Lock order: table -> object -> controller.
enum DeviceIrqs {
    private static let tableLock = SpinLock()
    private static let controllerLock = SpinLock()
    /// Objects a level number may have.
    static var sharers: Int { 4 }
    /// Interrupt objects by number, `sharers` slots each (0: none); each
    /// number's mode (0 none, else 1 | level << 1 | activeLow << 2) and
    /// how many of its objects hold it masked; the CPU that last took each
    /// number (for the boot test and dumps). Heap, sized at boot.
    nonisolated(unsafe) private static var handlers: UnsafeMutablePointer<UInt64>? = nil
    nonisolated(unsafe) private static var modes: UnsafeMutablePointer<UInt8>? = nil
    nonisolated(unsafe) private static var holds: UnsafeMutablePointer<UInt8>? = nil
    nonisolated(unsafe) private static var lastCpus: UnsafeMutablePointer<UInt8>? = nil

    /// Numbers are below this.
    static var limit: UInt32 {
        #if arch(x86_64)
        IoApic.gsiLimit
        #elseif arch(arm64)
        1020
        #elseif arch(riscv64)
        Aia.active ? Aia.gsiBase + Aia.sources + 1 : Plic.gsiBase + Plic.count
        #endif
    }

    /// Allocates the tables (after the controllers are found).
    static func initialize() {
        let count = Int(limit)
        let bytes = count * (8 * sharers + 3)
        guard let raw = unsafe heap.allocate(size: bytes) else { panic("irq: no memory for the handler table") }
        unsafe raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        unsafe handlers = raw.bindMemory(to: UInt64.self, capacity: count * sharers)
        let bytesAt = unsafe raw + count * 8 * sharers
        unsafe modes = bytesAt.bindMemory(to: UInt8.self, capacity: count)
        unsafe holds = (bytesAt + count).bindMemory(to: UInt8.self, capacity: count)
        unsafe lastCpus = (bytesAt + 2 * count).bindMemory(to: UInt8.self, capacity: count)
        #if arch(x86_64)
        let msiBytes = maxCpus * 8 + maxCpus * Int(msiVectorCount) * 8
        guard let msi = unsafe heap.allocate(size: msiBytes) else { panic("irq: no memory for the MSI tables") }
        unsafe msi.initializeMemory(as: UInt8.self, repeating: 0, count: msiBytes)
        unsafe msiInUse = msi.bindMemory(to: UInt64.self, capacity: maxCpus)
        unsafe msiHandlers = (msi + maxCpus * 8).bindMemory(to: UInt64.self, capacity: maxCpus * Int(msiVectorCount))
        #endif
    }

    /// A number a driver may have: the controller has it and the kernel
    /// doesn't use it.
    static func isValid(_ number: UInt32) -> Bool {
        guard number < limit, !kernelOwns(number) else { return false }
        #if arch(x86_64)
        return IoApic.isValid(number)
        #elseif arch(arm64)
        return GicV3.isValidSpi(number)
        #elseif arch(riscv64)
        return Aia.active ? Aia.isValid(number) : Plic.isValid(number)
        #endif
    }

    /// An ISA IRQ's number (amd64: through the MADT's overrides).
    static func remapIsa(_ irq: UInt32) -> UInt32 {
        #if arch(x86_64)
        return IoApic.remapIsa(irq)
        #else
        return irq
        #endif
    }

    /// The trigger mode and polarity firmware set up for `number`.
    static func defaultMode(_ number: UInt32) -> (level: Bool, activeLow: Bool) {
        #if arch(x86_64)
        return IoApic.defaultMode(number)
        #elseif arch(arm64)
        return (GicV3.spiIsLevel(number), false)
        #elseif arch(riscv64)
        return (true, false)
        #endif
    }

    /// Installs `object` as one of `number`'s handlers; whether it is the
    /// first, which configures the line. ALREADY_BOUND: an edge number
    /// that has one, or a level number with objects of another mode;
    /// NO_RESOURCES: `sharers` already.
    static func register(_ number: UInt32, _ object: ObjectPointer, level: Bool, activeLow: Bool) throws(Status) -> Bool {
        try tableLock.withLock { () throws(Status) -> Bool in
            guard let handlers = unsafe handlers, let modes = unsafe modes else { throw .notSupported }
            let mode: UInt8 = 1 | (level ? 2 : 0) | (activeLow ? 4 : 0)
            let base = Int(number) * sharers
            let current = unsafe modes[Int(number)]
            if current == 0 {
                unsafe handlers[base] = object.address
                unsafe modes[Int(number)] = mode
                return true
            }
            guard level, current == mode else { throw .alreadyBound }
            for i in 0..<sharers where unsafe handlers[base + i] == 0 {
                unsafe handlers[base + i] = object.address
                return false
            }
            throw .noResources
        }
    }

    /// Removes `object` from `number`'s handlers, none of its runs still
    /// going on once it returns; a hold it had (`held`) is released. The
    /// last one masks the line.
    static func unregister(_ number: UInt32, _ object: ObjectPointer, held: Bool) {
        tableLock.withLock {
            guard let handlers = unsafe handlers, let modes = unsafe modes else { return }
            let base = Int(number) * sharers
            var left = 0
            for i in 0..<sharers {
                if unsafe handlers[base + i] == object.address {
                    unsafe handlers[base + i] = 0
                } else if unsafe handlers[base + i] != 0 {
                    left += 1
                }
            }
            if left == 0 {
                unsafe modes[Int(number)] = 0
                controllerLock.withLock {
                    unsafe holds![Int(number)] = 0
                    setMaskedLocked(number, true)
                }
            } else if held {
                release(number)
            }
        }
    }

    /// An object holds `number` masked (a level fire, until its ack).
    static func hold(_ number: UInt32) {
        controllerLock.withLock {
            guard let holds = unsafe holds else { return }
            unsafe holds[Int(number)] &+= 1
            setMaskedLocked(number, true)
        }
    }

    /// An object's hold ends; the line opens when none holds it.
    static func release(_ number: UInt32) {
        controllerLock.withLock {
            guard let holds = unsafe holds else { return }
            if unsafe holds[Int(number)] > 0 { unsafe holds[Int(number)] -= 1 }
            if unsafe holds[Int(number)] == 0 { setMaskedLocked(number, false) }
        }
    }

    /// Unmasks `number` unless an object holds it (after `configure`,
    /// which masks).
    static func open(_ number: UInt32) {
        controllerLock.withLock {
            guard let holds = unsafe holds else { return }
            if unsafe holds[Int(number)] == 0 { setMaskedLocked(number, false) }
        }
    }

    /// Programs `number` (masked) with a mode, routed to `cpu`.
    /// NOT_SUPPORTED: a polarity the controller lacks, or a CPU it can't
    /// target.
    static func configure(_ number: UInt32, level: Bool, activeLow: Bool, cpu: Int) throws(Status) {
        let target = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.hardwareId
        #if arch(x86_64)
        if InterruptRemapping.enabled {
            // The entry first (vector 0x30 + GSI, the IOAPIC's source id),
            // then the pin pointing at it.
            guard InterruptRemapping.reaches(target) else { throw .notSupported }
            InterruptRemapping.set(InterruptRemapping.gsiIndex(number), vector: IoApic.firstVector + number,
                                   apicId: target, level: level, source: IoApic.sourceId(number))
            controllerLock.withLock { InterruptRemapping.programIoApic(number, level: level, activeLow: activeLow) }
            return
        }
        #endif
        try controllerLock.withLock { () throws(Status) in
            #if arch(x86_64)
            guard target <= 0xFF else { throw .notSupported }  // 8-bit destinations without remapping
            IoApic.program(number, level: level, activeLow: activeLow, apicId: target)
            #elseif arch(arm64)
            guard !activeLow else { throw .notSupported }  // the GIC takes active-high and rising edges only
            GicV3.programSpi(number, level: level, affinity: target)
            #elseif arch(riscv64)
            guard !activeLow else { throw .notSupported }  // PLIC gateways (and croi's APLIC use): active high
            if Aia.active {
                guard Aia.route(number, level: level, hart: target) else { throw .notSupported }
            } else {
                guard Plic.route(number, hart: target) else { throw .notSupported }
            }
            #endif
        }
    }

    static func mask(_ number: UInt32) { setMasked(number, true) }
    static func unmask(_ number: UInt32) { setMasked(number, false) }

    private static func setMasked(_ number: UInt32, _ masked: Bool) {
        controllerLock.withLock { setMaskedLocked(number, masked) }
    }

    /// Controller lock held.
    private static func setMaskedLocked(_ number: UInt32, _ masked: Bool) {
        #if arch(x86_64)
        IoApic.setMasked(number, masked)
        #elseif arch(arm64)
        GicV3.setSpiMasked(number, masked)
        #elseif arch(riscv64)
        if Aia.active { Aia.setMasked(number, masked) } else { Plic.setMasked(number, masked) }
        #endif
    }

    /// Runs `number`'s handlers (interrupt context, before the controller's
    /// end of interrupt). A number nobody handles is masked.
    static func dispatch(_ number: UInt32) {
        guard number < limit else { return }
        for i in 0..<kernelWiredCount.load(ordering: .acquiring) where kernelWired[i].number == number {
            kernelWired[i].handler?(kernelWired[i].argument)
            return
        }
        tableLock.withLock {
            guard let handlers = unsafe handlers, let lastCpus = unsafe lastCpus else { return }
            unsafe lastCpus[Int(number)] = UInt8(truncatingIfNeeded: Cpu.current)
            var fired = false
            for i in 0..<sharers {
                let object = unsafe handlers[Int(number) * sharers + i]
                guard object != 0 else { continue }
                InterruptObjects.fire(ObjectPointer(address: object))
                fired = true
            }
            if !fired { mask(number) }
        }
    }

    // MARK: Kernel-owned interrupts

    /// A kernel-owned interrupt's handler (an IOMMU's fault or event
    /// interrupt): a C-convention function and its argument.
    typealias KernelHandler = @convention(c) (UInt64) -> Void
    typealias KernelMsiHandler = KernelHandler

    /// Wired numbers the kernel handles: written once, before the device
    /// can raise them, never removed, read without `tableLock`; drivers
    /// can't bind them (`isValid`).
    nonisolated(unsafe) private static var kernelWired = InlineArray<8, (number: UInt32, handler: KernelHandler?, argument: UInt64)>(
        repeating: (0, nil, 0))
    private static let kernelWiredCount = Atomic<Int>(0)

    /// Takes `number` for the kernel: configured with the mode, routed to
    /// the boot CPU and unmasked. False if it isn't a usable number.
    static func setKernelHandler(_ number: UInt32, level: Bool, _ handler: KernelHandler, _ argument: UInt64) -> Bool {
        let index = kernelWiredCount.load(ordering: .relaxed)
        guard index < kernelWired.count, isValid(number) else { return false }
        kernelWired[index] = (number, handler, argument)
        kernelWiredCount.store(index + 1, ordering: .releasing)
        guard (try? configure(number, level: level, activeLow: false, cpu: 0)) != nil else { return false }
        unmask(number)
        return true
    }

    private static func kernelOwns(_ number: UInt32) -> Bool {
        for i in 0..<kernelWiredCount.load(ordering: .acquiring) where kernelWired[i].number == number { return true }
        return false
    }

    // MARK: MSI (K9d)

    #if arch(x86_64)
    /// Each CPU's MSI vectors: 0xB0..<0xF0 (the fixed ones are 0xF0 up).
    static var msiFirstVector: UInt32 { 0xB0 }
    static var msiVectorCount: UInt32 { 64 }
    private static var maxCpus: Int { 64 }
    /// Per CPU: a bit per vector in use; handlers by cpu * 64 + vector.
    nonisolated(unsafe) private static var msiInUse: UnsafeMutablePointer<UInt64>? = nil
    nonisolated(unsafe) private static var msiHandlers: UnsafeMutablePointer<UInt64>? = nil

    /// `count` (a power of two) contiguous vectors on `cpu`, aligned to
    /// `count` as multi-message MSI needs; the first, or nil.
    static func allocateMsi(cpu: Int, count: UInt32) -> UInt32? {
        tableLock.withLock { () -> UInt32? in
            guard let inUse = unsafe msiInUse, cpu < maxCpus else { return nil }
            let mask: UInt64 = count >= 64 ? ~0 : (1 << UInt64(count)) - 1
            var first: UInt32 = 0
            while first + count <= msiVectorCount {
                if unsafe inUse[cpu] & (mask << UInt64(first)) == 0 {
                    // AMD-Vi remapping: their indices too, or not at all.
                    guard InterruptRemapping.allocateMsiIndices(cpu: cpu, vector: msiFirstVector + first, count: count) else {
                        return nil
                    }
                    unsafe inUse[cpu] |= mask << UInt64(first)
                    return msiFirstVector + first
                }
                first += count
            }
            return nil
        }
    }

    static func freeMsi(cpu: Int, vector: UInt32, count: UInt32) {
        tableLock.withLock {
            guard let inUse = unsafe msiInUse else { return }
            let mask: UInt64 = count >= 64 ? ~0 : (1 << UInt64(count)) - 1
            unsafe inUse[cpu] &= ~(mask << UInt64(vector - msiFirstVector))
            InterruptRemapping.freeMsiIndices(cpu: cpu, vector: vector, count: count)
        }
    }

    static func apicId(cpu: Int) -> UInt64 {
        unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.hardwareId
    }

    /// What a device writes to deliver `vector` to `cpu`. With interrupt
    /// remapping, the remappable format naming its entry (written by
    /// `prepareMsi`); else the local APIC message address (physical
    /// destination) and data (fixed, edge). Nil for an APIC ID the format
    /// can't name.
    static func msiMessage(cpu: Int, vector: UInt32) -> (address: UInt64, data: UInt32)? {
        let apicId = apicId(cpu: cpu)
        if InterruptRemapping.enabled {
            guard InterruptRemapping.reaches(apicId) else { return nil }
            return InterruptRemapping.message(InterruptRemapping.msiIndex(cpu: cpu, vector: vector))
        }
        guard apicId <= 0xFF else { return nil }
        return (0xFEE0_0000 | apicId << 12, vector)
    }

    /// With interrupt remapping: the entry `msiMessage` names, delivering
    /// `vector` to `cpu` (edge), verifying `source` when known.
    static func prepareMsi(cpu: Int, vector: UInt32, source: UInt16?) {
        guard InterruptRemapping.enabled else { return }
        InterruptRemapping.set(InterruptRemapping.msiIndex(cpu: cpu, vector: vector), vector: vector,
                               apicId: apicId(cpu: cpu), level: false, source: source)
    }

    /// The entry no longer delivers (a device still using it faults).
    static func releaseMsi(cpu: Int, vector: UInt32) {
        guard InterruptRemapping.enabled else { return }
        InterruptRemapping.clear(InterruptRemapping.msiIndex(cpu: cpu, vector: vector))
    }

    /// Installs `object` for `vector` on `cpu` (0 removes it). Once it
    /// returns, no run of the previous handler is still going on.
    static func setMsiHandler(cpu: Int, vector: UInt32, _ object: UInt64) {
        tableLock.withLock {
            guard let handlers = unsafe msiHandlers else { return }
            unsafe handlers[cpu * Int(msiVectorCount) + Int(vector - msiFirstVector)] = object
        }
    }

    /// Kernel handlers by (CPU, vector): written once, before the device
    /// can send the MSI, never removed, read without `tableLock` (their
    /// owners allocate vectors under their own locks).
    nonisolated(unsafe) private static var kernelMsis = InlineArray<8, (cpu: Int, vector: UInt32, handler: KernelMsiHandler?, argument: UInt64)>(
        repeating: (0, 0, nil, 0))
    private static let kernelMsiCount = Atomic<Int>(0)

    /// Installs a kernel handler for `vector` on `cpu` (from allocateMsi).
    static func setKernelMsiHandler(cpu: Int, vector: UInt32, _ handler: KernelMsiHandler, _ argument: UInt64) {
        let index = kernelMsiCount.load(ordering: .relaxed)
        guard index < kernelMsis.count else { panic("irq: too many kernel MSIs") }
        kernelMsis[index] = (cpu, vector, handler, argument)
        kernelMsiCount.store(index + 1, ordering: .releasing)
    }

    /// An MSI arrived on this CPU (interrupt context, before EOI).
    static func dispatchMsi(_ vector: UInt32) {
        let cpu = Int(Cpu.current)
        for i in 0..<kernelMsiCount.load(ordering: .acquiring) where kernelMsis[i].cpu == cpu && kernelMsis[i].vector == vector {
            kernelMsis[i].handler?(kernelMsis[i].argument)
            return
        }
        tableLock.withLock {
            guard let handlers = unsafe msiHandlers else { return }
            let object = unsafe handlers[Int(Cpu.current) * Int(msiVectorCount) + Int(vector - msiFirstVector)]
            if object != 0 { InterruptObjects.fire(ObjectPointer(address: object)) }
        }
    }
    #endif

    #if arch(arm64)
    // MSIs through the GICv3 ITS (K12h): a "vector" is an LPI (8192 +
    // EventID), global; `cpu` is the collection it is delivered to.

    static func allocateMsi(cpu: Int, count: UInt32) -> UInt32? { Its.allocate(count: count) }

    static func freeMsi(cpu: Int, vector: UInt32, count: UInt32) { Its.free(lpi: vector, count: count) }

    /// The ITS's doorbell and the EventID; nil without an ITS.
    static func msiMessage(cpu: Int, vector: UInt32) -> (address: UInt64, data: UInt32)? {
        guard Its.ready else { return nil }
        return (Its.translater, vector - Its.firstLpi)
    }

    /// Installs `object` for the LPI (0 removes it); once it returns, no
    /// run of the previous handler is still going on.
    static func setMsiHandler(cpu: Int, vector: UInt32, _ object: UInt64) {
        tableLock.withLock { Its.setHandler(lpi: vector, object) }
    }

    /// An LPI arrived (interrupt context, before EOI).
    static func dispatchMsi(_ lpi: UInt32) {
        tableLock.withLock {
            let object = Its.handler(lpi)
            if object != 0 { InterruptObjects.fire(ObjectPointer(address: object)) }
        }
    }

    static func prepareMsi(cpu: Int, vector: UInt32, source: UInt16?) {}
    static func releaseMsi(cpu: Int, vector: UInt32) {}
    #endif

    #if arch(riscv64)
    // MSIs through AIA's IMSICs (K12i): a "vector" is an identity, global
    // across harts; `cpu` picks the hart file the message is sent to.

    static func allocateMsi(cpu: Int, count: UInt32) -> UInt32? { Aia.allocate(count: count) }

    static func freeMsi(cpu: Int, vector: UInt32, count: UInt32) { Aia.free(vector, count: count) }

    /// The hart's interrupt file and the identity; nil without AIA.
    static func msiMessage(cpu: Int, vector: UInt32) -> (address: UInt64, data: UInt32)? {
        guard Aia.active else { return nil }
        return Aia.message(cpu: cpu, identity: vector)
    }

    static func setMsiHandler(cpu: Int, vector: UInt32, _ object: UInt64) {
        tableLock.withLock { Aia.setHandler(vector, object) }
    }

    static func dispatchMsi(_ identity: UInt32) {
        tableLock.withLock {
            let object = Aia.handler(identity)
            if object != 0 { InterruptObjects.fire(ObjectPointer(address: object)) }
        }
    }

    static func prepareMsi(cpu: Int, vector: UInt32, source: UInt16?) {}
    static func releaseMsi(cpu: Int, vector: UInt32) {}
    #endif

    /// The CPU that last took `number` (boot test).
    static func lastCpu(_ number: UInt32) -> Int {
        tableLock.withLock {
            guard number < limit, let lastCpus = unsafe lastCpus else { return -1 }
            return Int(unsafe lastCpus[Int(number)])
        }
    }
}
