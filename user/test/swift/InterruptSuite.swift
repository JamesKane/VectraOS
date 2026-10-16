import CroiRuntime

/// Interrupt objects (K9c, K9d, K14e), moved here from usertest.c's modes
/// 11 and 16 when V1 cut interrupt_wait, interrupt_destroy and virtual
/// interrupts (D29): a bound port is the one way to wait, and closing the
/// last handle destroys. Where a check needs an interrupt on demand, a
/// test hook fires it as its device would (`fire`). The kernel runs this
/// suite on its own (ProcessSelfTest.runInterrupts) and then checks that
/// the RTC was taken on CPU 1 and reports the wake latency measured here
/// (irq.wait_wake_median).
enum InterruptSuite {
    static func run() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0)))
        stateMachine(root)
        rtc(root)
        msi(root)
        handoff(root)
        print("swift: interrupts passed")
    }

    // Each machine's RTC: amd64 the CMOS RTC's periodic interrupt (GSI 8,
    // edge), arm64 the PL031 alarm (INTID 34, level), rv64 the goldfish
    // RTC alarm (GSI 11, level).
    #if arch(x86_64)
    static var number: UInt64 { 8 }
    static var level: Bool { false }
    static var waits: Int { 16 }
    #elseif arch(arm64)
    static var number: UInt64 { 34 }
    static var level: Bool { true }
    static var waits: Int { 1 }  // the PL031 matches whole seconds
    #else
    static var number: UInt64 { 11 }
    static var level: Bool { true }
    static var waits: Int { 8 }
    #endif

    static var persistent: UInt32 { UInt32(CROI_BIND_INTERRUPT) | UInt32(CROI_BIND_PERSISTENT) }

    // MARK: The state machine

    /// Packets one at a time, each after an ack; a fire while unbound is
    /// kept until bound; a binding taken back returns its packet; closing
    /// the last handle destroys. Fired by the test hook (the RTC stays
    /// quiet).
    static func stateMachine(_ root: borrowing Handle) {
        let irq = resource(root, UInt32(CROI_RSRC_KIND_IRQ), number, 1)
        var raw: UInt32 = 0
        check(create(irq, number, options: 0x10, &raw) == Status.invalidArgs,
              "no virtual interrupts (a counter is one)")
        check(create(irq, number, options: 0, &raw) == 0, "an interrupt object")
        let interrupt = Handle(adopting: raw)
        check(ack(interrupt) == Status.badState, "no ack unbound")
        let plain = Port()
        let port = Port(options: UInt64(CROI_PORT_BIND_TO_INTERRUPT))
        check(plain.bind(interrupt, persistent, key: 9) == Status.wrongType, "only a port made for interrupts")
        check(port.bind(interrupt, UInt32(CROI_BIND_INTERRUPT), key: 9) == Status.invalidArgs, "bound until unbound")
        check(port.bind(interrupt, persistent, key: 9) == 0, "bound")
        check(port.bind(interrupt, persistent, key: 9) == Status.alreadyBound, "bound once")

        check(fire(interrupt, 1111) == 0, "fired")
        let first = port.next(deadline: Sys.now() + 1_000_000_000)
        check(first?.type == UInt32(CROI_PKT_TYPE_INTERRUPT) && first?.key == 9 && first?.payload.0 == 1111,
              "a packet with the fire's time")
        check(fire(interrupt, 2222) == 0 && port.empty, "the next waits for an ack")
        check(ack(interrupt) == 0 && port.next()?.payload.0 == 2222, "a fire meanwhile is sent on the ack")
        check(ack(interrupt) == 0 && port.empty, "quiet once acked with nothing pending")

        check(fire(interrupt, 3333) == 0 && port.cancel(interrupt, key: 9) == 0
                  && port.cancel(interrupt, key: 9) == Status.notFound && port.empty,
              "unbinding takes the queued packet back; NOT_FOUND once unbound")
        check(fire(interrupt, 4444) == 0 && port.empty, "unbound, a fire is kept")
        check(port.bind(interrupt, persistent, key: 10) == 0 && port.next()?.payload.0 == 3333,
              "bound again: the packet taken back goes out")
        check(ack(interrupt) == 0 && port.empty, "one pending fire at a time, the first one's time")

        // interrupt_ack takes an array (D40), and goes on past an item that
        // fails.
        check(fire(interrupt, 4500) == 0 && port.next()?.payload.0 == 4500, "fired again")
        check(fire(interrupt, 4600) == 0 && port.empty, "and kept until an ack")
        var items = InlineArray<2, croi_interrupt_ack_item_t>(repeating: croi_interrupt_ack_item_t(interrupt: 0, status: 1))
        items[1].interrupt = interrupt.raw
        check(Sys.call(CROI_SYS_INTERRUPT_ACK, Sys.address(&items), 2) == 1 && Int64(items[0].status) == Status.badHandle
                  && items[1].status == 0, "a batch acks past a bad handle")
        check(port.next()?.payload.0 == 4600 && ack(interrupt) == 0 && port.empty, "and sends the fire it kept")
        check(Sys.call(CROI_SYS_INTERRUPT_ACK, Sys.address(&items), 0) == Status.invalidArgs, "an empty batch is refused")

        // A duplicate keeps it; the last handle's close destroys it, so
        // its number is free again.
        let other = Handle(duplicating: interrupt)
        close(interrupt)
        check(fire(other, 5555) == 0 && port.next()?.payload.0 == 5555, "alive while a handle is")
        close(other)
        check(port.next(deadline: Sys.now() + 20_000_000) == nil, "destroyed with its last handle")
        check(create(irq, number, options: 0, &raw) == 0, "its number free again")
        close(Handle(adopting: raw))
    }

    // MARK: A real device

    /// The RTC's interrupt, routed to CPU 1, through a port: a level
    /// interrupt fires again on an ack while asserted, an edge's further
    /// edges wait for the ack; then the wake latency from the fire's time.
    static func rtc(_ root: borrowing Handle) {
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_PORT_CREATE, 4, Sys.address(&raw)) == Status.invalidArgs,
              "port options: BIND_TO_INTERRUPT and RING only")
        let port = Port(options: UInt64(CROI_PORT_BIND_TO_INTERRUPT))
        let device = Rtc(root)

        // Creation: the IRQ resource must cover the number; one object per number.
        let irq = resource(root, UInt32(CROI_RSRC_KIND_IRQ), number, 1)
        check(create(irq, number + 1, options: 0, &raw) == Status.outOfRange, "the IRQ resource covers the number")
        check(create(root, 5000, options: 0, &raw) == Status.invalidArgs, "a number the controller has")
        check(create(irq, number, options: 1 << 8, &raw) == Status.invalidArgs, "known options only")
        check(create(irq, number, options: UInt32(CROI_INTERRUPT_MODE_EDGE_BOTH), &raw) == Status.notSupported,
              "no edge-both")
        check(create(irq, number, options: 0, &raw) == 0, "the RTC's interrupt")
        let interrupt = Handle(adopting: raw)
        check(create(irq, number, options: 0, &raw) == Status.alreadyBound, "one object per number")
        // Affinity: to CPU 1 (the kernel checks where it was taken).
        check(affinity(interrupt, 0) == Status.invalidArgs && affinity(interrupt, 1 << 63) == Status.invalidArgs,
              "affinity: a CPU that takes interrupts")
        check(affinity(interrupt, 1 << 1) == 0, "affinity: CPU 1")

        check(port.bind(interrupt, persistent, key: 42) == 0, "bound")
        let before = Sys.now()
        device.start()
        let fired = port.next(deadline: Sys.now() + 3_000_000_000)
        let after = Sys.now()
        check(fired?.type == UInt32(CROI_PKT_TYPE_INTERRUPT) && fired?.key == 42, "the RTC's interrupt arrives")
        check((fired?.payload.0 ?? 0) >= before && (fired?.payload.0 ?? .max) <= after, "stamped when it fired")
        #if arch(arm64)
        // Level: still asserted, so an ack without clearing it fires again.
        // (Not on rv64: QEMU's PLIC sets pending only on a rising line, so a
        // source completed while still high never comes back; real gateways
        // forward it again.)
        check(ack(interrupt) == 0 && port.next(deadline: Sys.now() + 500_000_000)?.key == 42,
              "a level interrupt still asserted fires again on its ack")
        device.stop()
        #elseif arch(riscv64)
        device.stop()
        #else
        // Edge: further edges while unacked are only remembered, then sent on ack.
        device.clear()
        Sys.sleep(20_000_000)
        check(port.empty, "edges wait for the ack")
        check(ack(interrupt) == 0 && port.next(deadline: Sys.now() + 500_000_000)?.key == 42, "and are sent on it")
        device.stop()
        for _ in 0..<3 where port.next() != nil {}
        #endif
        // Quiet once the device is: ack, then nothing more.
        _ = ack(interrupt)
        for _ in 0..<3 where port.next(deadline: Sys.now() + 20_000_000) != nil { _ = ack(interrupt) }
        check(port.next(deadline: Sys.now() + 50_000_000) == nil, "quiet once the device is")
        check(port.cancel(interrupt, key: 42) == 0, "unbound")

        // The wake latency: from the fire's time to the port_wait's return.
        check(port.bind(interrupt, persistent, key: 43) == 0, "bound again")
        var latencies = InlineArray<16, UInt64>(repeating: 0)
        device.start()
        for i in 0..<waits {
            guard let packet = port.next(deadline: Sys.now() + 3_000_000_000) else {
                return check(false, "every fire reaches the port")
            }
            latencies[i] = Sys.now() &- packet.payload.0
            device.clear()
            check(packet.payload.0 != 0 && ack(interrupt) == 0, "stamped, and acked")
            if level && i + 1 < waits { device.start() }
        }
        device.stop()
        for i in 1..<waits {  // insertion sort for the median
            let value = latencies[i]
            var j = i
            while j > 0 && latencies[j - 1] > value {
                latencies[j] = latencies[j - 1]
                j -= 1
            }
            latencies[j] = value
        }
        _ = Sys.call(CROI_SYS_TEST, CROI_TEST_REPORT, latencies[waits / 2])

        close(interrupt)
        check(create(irq, number, options: 0, &raw) == 0, "closed: its number free again")
        close(Handle(adopting: raw))
    }

    /// The RTC, quiet until started.
    struct Rtc: ~Copyable {
        #if arch(x86_64)
        let ports: Handle

        init(_ root: borrowing Handle) {
            ports = InterruptSuite.resource(root, UInt32(CROI_RSRC_KIND_IOPORT), 0x70, 2)
            check(Sys.call(CROI_SYS_IOPORTS_REQUEST, ports.arg, 0x70, 2) == 0, "the CMOS RTC's ports")
        }

        func read(_ register: UInt8) -> UInt8 {
            td_port_out(0x70, 1, UInt32(0x80 | register))  // NMIs stay off while we poke
            return UInt8(truncatingIfNeeded: td_port_in(0x71, 1))
        }

        func write(_ register: UInt8, _ value: UInt8) {
            td_port_out(0x70, 1, UInt32(0x80 | register))
            td_port_out(0x71, 1, UInt32(value))
        }

        func start() {  // 1024 Hz periodic
            write(0xA, read(0xA) & 0xF0 | 6)
            write(0xB, read(0xB) | 0x40)
            _ = read(0xC)
        }

        func clear() { _ = read(0xC) }

        func stop() {
            write(0xB, read(0xB) & ~0x40)
            _ = read(0xC)
        }
        #else
        let registers: Device

        init(_ root: borrowing Handle) {
            #if arch(arm64)
            let base: UInt64 = 0x0901_0000
            #else
            let base: UInt64 = 0x10_1000
            #endif
            registers = Device(root, base, pageSize, policy: UInt32(CROI_CACHE_POLICY_UNCACHED_DEVICE))
        }

        #if arch(arm64)
        func start() {  // the next second
            registers.write32(4, registers.read32(0) &+ 1)  // RTCMR = RTCDR + 1
            registers.write32(16, 1)  // RTCIMSC
        }

        func clear() { registers.write32(28, 1) }  // RTCICR

        func stop() {
            registers.write32(16, 0)
            registers.write32(28, 1)
        }
        #else
        func start() {  // 1 ms from now
            var now = UInt64(registers.read32(0))  // TIME_LOW latches TIME_HIGH
            now |= UInt64(registers.read32(4)) << 32
            now += 1_000_000
            registers.write32(16, 1)  // IRQ_ENABLED
            registers.write32(12, UInt32(truncatingIfNeeded: now >> 32))
            registers.write32(8, UInt32(truncatingIfNeeded: now))  // ALARM_LOW arms it
        }

        func clear() { registers.write32(28, 1) }  // CLEAR_INTERRUPT

        func stop() {
            registers.write32(16, 0)
            registers.write32(20, 1)  // CLEAR_ALARM
            registers.write32(28, 1)
        }
        #endif
        #endif
    }

    // MARK: MSI

    // amd64: edu delivers a real MSI to a port; virtio-blk's MSI-X table
    // (not enabled, so it never fires) shows the kernel programming,
    // masking and moving its entries. Both are found by scanning bus 0 and
    // skipped if absent (other machines boot this kernel too), and every
    // config register touched is put back. arm64 goes through the GICv3
    // ITS (the message is its doorbell and an EventID, the LPI less 8192;
    // a move keeps it), rv64 through AIA's IMSICs (a hart's file and an
    // identity; a move changes the address) and has none on the PLIC.
    #if arch(arm64)
    static var its: Bool { true }
    #else
    static var its: Bool { false }
    #endif
    #if arch(riscv64)
    static var imsic: Bool { true }
    #else
    static var imsic: Bool { false }
    #endif

    /// K12f: with interrupt remapping (VT-d) a message is in the
    /// remappable format (bit 4, SHV bit 3, data 0) and names an entry the
    /// kernel wrote; old-style messages are blocked.
    static func remapped(_ address: UInt64) -> Bool { address & 0x10 != 0 }
    /// K12g: with AMD-Vi the address is the plain one and the data an
    /// index the kernel allocated (0x100 up; vectors are 0xB0-0xEF).
    static func amdRemapped(_ data: UInt32) -> Bool { data >= 0x100 }
    /// The remapping entry a remappable address names (bits 19:5 and 2).
    static func entry(_ address: UInt32) -> UInt32 { (address >> 5) & 0x7FFF | ((address >> 2) & 1) << 15 }

    static func msi(_ root: borrowing Handle) {
        var raw: UInt32 = 0
        if imsic {
            // rv64 without AIA (the PLIC): no MSIs at all.
            let status = Sys.call(CROI_SYS_MSI_ALLOCATE, root.arg, 1, Sys.address(&raw))
            if status == Status.notSupported { return }
            check(status == 0, "an MSI allocation through the IMSIC")
            close(Handle(adopting: raw))
        }
        let bus = Device(root, ecam() ?? 0xE000_0000, 32 * 0x8000)  // bus 0, devices 0-31, function 0

        // Allocations: the MSI resource; a power of two up to 32.
        let tracing = resource(root, UInt32(CROI_RSRC_KIND_SYSTEM), UInt64(CROI_RSRC_SYSTEM_TRACING_BASE), 1)
        check(Sys.call(CROI_SYS_MSI_ALLOCATE, tracing.arg, 1, Sys.address(&raw)) == Status.outOfRange,
              "MSIs need the MSI resource")
        check(Sys.call(CROI_SYS_MSI_ALLOCATE, root.arg, 3, Sys.address(&raw)) == Status.invalidArgs
                  && Sys.call(CROI_SYS_MSI_ALLOCATE, root.arg, 64, Sys.address(&raw)) == Status.invalidArgs,
              "a power of two up to 32")
        check(Sys.call(CROI_SYS_MSI_ALLOCATE, root.arg, 1, Sys.address(&raw)) == 0, "an MSI allocation")
        let msi = Handle(adopting: raw)
        var info = croi_info_msi_t()
        check(msiInfo(msi, &info) && valid(info) && info.num_irq == 1 && info.interrupt_count == 0,
              "the message the device writes")

        var capability: UInt64 = 0
        let edu = find(bus, mask: ~0, id: 0x11e8_1234, capabilityId: 0x05, &capability)
        if edu != 0 { eduMessage(root, bus, edu, capability, msi, &info) }
        close(msi)
        msiX(root, bus)
    }

    /// edu's MSI: interrupt objects for it, then a message to a port.
    static func eduMessage(_ root: borrowing Handle, _ bus: borrowing Device, _ edu: UInt64, _ cap: UInt64,
                           _ msi: borrowing Handle, _ info: inout croi_info_msi_t) {
        let command = bus.read32(edu + 4) & 0xFFFF
        bus.write32(edu + 4, command | 1 << 1 | 1 << 2 | 1 << 10)  // memory, bus master, no INTx
        // Interrupt objects: the capability must be MSI's; ids once each.
        var raw: UInt32 = 0
        let anon = Handle(vmo: pageSize)
        check(msiCreate(msi, 0, 0, anon, 0, &raw) == Status.invalidArgs, "a physical VMO")
        check(msiCreate(msi, 0, 0, bus.vmo, edu, &raw) == Status.invalidArgs, "at an MSI capability")
        check(msiCreate(msi, 0, 1, bus.vmo, edu + cap, &raw) == Status.invalidArgs, "an id of the allocation")
        check(msiCreate(msi, 2, 0, bus.vmo, edu + cap, &raw) == Status.invalidArgs, "known options")
        check(msiCreate(msi, 0, 0, bus.vmo, edu + cap, &raw) == 0, "edu's interrupt object")
        let interrupt = Handle(adopting: raw)
        check(msiCreate(msi, 0, 0, bus.vmo, edu + cap, &raw) == Status.alreadyBound, "one object per id")
        check(msiInfo(msi, &info) && info.interrupt_count == 1, "counted in the allocation")
        check(affinity(interrupt, 2) == Status.notSupported, "a plain MSI doesn't move")

        // The driver programs the capability from the info and enables MSI.
        let control = bus.read16(edu + cap + 2)
        let wide = control & 1 << 7 != 0
        bus.write32(edu + cap + 4, UInt32(truncatingIfNeeded: info.target_addr))
        if wide {
            bus.write32(edu + cap + 8, UInt32(truncatingIfNeeded: info.target_addr >> 32))
            bus.write16(edu + cap + 0xC, UInt16(truncatingIfNeeded: info.target_data))
        } else {
            bus.write16(edu + cap + 8, UInt16(truncatingIfNeeded: info.target_data))
        }
        bus.write16(edu + cap + 2, control & ~(7 << 4) | 1)  // one message, enabled

        // edu raises an interrupt when 0x60 is written; it reaches the port.
        let registers = Device(root, bar(bus, edu, 0), pageSize)
        registers.write32(4, 0x1234_5678)  // liveness: reads back inverted
        check(registers.read32(4) == ~0x1234_5678, "edu is alive")
        let port = Port(options: UInt64(CROI_PORT_BIND_TO_INTERRUPT))
        let before = Sys.now()
        check(port.bind(interrupt, persistent, key: 77) == 0, "bound")
        registers.write32(0x60, 1)
        let fired = port.next(deadline: Sys.now() + 1_000_000_000)
        check(fired?.type == UInt32(CROI_PKT_TYPE_INTERRUPT) && fired?.key == 77 && (fired?.payload.0 ?? 0) >= before
                  && registers.read32(0x24) == 1, "edu's MSI reaches the port")
        registers.write32(0x64, 1)
        check(ack(interrupt) == 0 && port.next(deadline: Sys.now() + 20_000_000) == nil, "acked: nothing more")
        check(port.cancel(interrupt, key: 77) == 0, "unbound")
        // VT-d isn't checked: QEMU's model passes compatibility-format MSIs
        // through whatever CFI says (hardware with CFIS clear, as croi
        // leaves it, blocks them).
        if its || amdRemapped(info.target_data) {
            // An old-style message for the same vector is blocked: nothing
            // arrives (AMD-Vi: index 0xB0 up to 0xFF is no entry). arm64: an
            // event not mapped for edu, at the ITS's doorbell.
            bus.write32(edu + cap + 4, its ? UInt32(truncatingIfNeeded: info.target_addr) : 0xFEE0_0000)
            bus.write16(edu + cap + (wide ? 0xC : 8),
                        UInt16(truncatingIfNeeded: its ? info.target_data + 64 : info.base_irq_id))
            check(port.bind(interrupt, persistent, key: 78) == 0 && ack(interrupt) == 0, "bound and acked")
            registers.write32(0x60, 4)
            check(port.next(deadline: Sys.now() + 20_000_000) == nil, "a message not the kernel's is blocked")
            registers.write32(0x64, 4)
            _ = port.cancel(interrupt, key: 78)
        }
        bus.write16(edu + cap + 2, control)  // MSI as it was
        bus.write32(edu + 4, command)        // and the command register
    }

    /// MSI-X: virtio-blk's table. Entries programmed from the allocation,
    /// unmasked; entry 1 moved to CPU 1 (QEMU's APIC IDs are CPU
    /// numbers); cleared and masked when the objects go.
    static func msiX(_ root: borrowing Handle, _ bus: borrowing Device) {
        var msix: UInt64 = 0
        let virtio = find(bus, mask: 0xFFFF, id: 0x1af4, capabilityId: 0x11, &msix)
        guard virtio != 0 else { return }
        let control = bus.read16(virtio + msix + 2)
        check(control & 0x7FF >= 1 && control & 0x8000 == 0, "virtio's MSI-X table, not enabled")
        let command = bus.read32(virtio + 4) & 0xFFFF
        bus.write32(virtio + 4, command | 1 << 1)
        defer { bus.write32(virtio + 4, command) }
        let table = UInt64(bus.read32(virtio + msix + 4))
        let base = bar(bus, virtio, table & 7)
        guard base != 0 else { return }  // no address assigned: nothing to look at
        let tableBase = base + (table & ~7)
        let entries = Device(root, tableBase & ~(pageSize - 1), pageSize)
        let at = tableBase & (pageSize - 1)
        func e(_ i: UInt64) -> UInt32 { entries.read32(at + 4 * i) }

        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_MSI_ALLOCATE, root.arg, 2, Sys.address(&raw)) == 0, "two MSIs")
        let msi = Handle(adopting: raw)
        var info = croi_info_msi_t()
        check(msiInfo(msi, &info) && info.base_irq_id % 2 == 0, "aligned to their count")
        let mode = UInt32(CROI_MSI_MODE_MSI_X)
        check(msiCreate(msi, mode, 0, entries.vmo, at, &raw) == 0, "entry 0's interrupt object")
        let x0 = Handle(adopting: raw)
        check(msiCreate(msi, mode, 1, entries.vmo, at, &raw) == 0, "entry 1's interrupt object")
        let x1 = Handle(adopting: raw)
        let address = UInt32(truncatingIfNeeded: info.target_addr)
        let data = info.target_data
        // Remapped: one entry per vector (consecutive handles, data 0), the
        // move to CPU 1 a handle in its range (entries 128 + cpu * 64 + vector).
        let r = !its && !imsic && remapped(info.target_addr)
        let amd = !its && !imsic && amdRemapped(data)
        check(e(0) == address && e(1) == 0 && e(2) == data && e(3) & 1 == 0
                  && (r ? entry(e(4)) == entry(e(0)) + 1 && e(6) == 0 : e(4) == address && e(6) == data + 1)
                  && e(7) & 1 == 0, "entries programmed and unmasked")
        check(affinity(x1, 1 << 1) == 0, "entry 1 to CPU 1")
        let moved = imsic ? e(4) != address && e(4) != 0 && e(6) == data + 1
            : its ? e(4) == address && e(6) == data + 1
            : r ? (entry(e(4)) &- 128) / 64 == 1 && e(6) == 0
            : amd ? e(4) == 0xFEE0_0000 && e(6) >= 0x100 && e(6) < 0x800 && e(6) != data + 1
            : (e(4) >> 12) & 0xFF == 1 && e(6) >= 0xB0 && e(6) < 0xF0
        check(moved && e(7) & 1 == 0 && e(0) == address, "moved, entry 0 untouched")
        close(x1)
        check(e(4) == 0 && e(6) == 0 && e(7) & 1 == 1, "closed: its entry cleared and masked")
        close(x0)
        check(e(0) == 0 && e(3) & 1 == 1, "and entry 0's")
    }

    /// Whether `info` is the message this machine's controller takes.
    static func valid(_ info: croi_info_msi_t) -> Bool {
        let address = info.target_addr, data = info.target_data, base = info.base_irq_id
        let message = imsic ? address != 0 && data == base
            : its ? address != 0 && base >= 8192 && data == base - 8192
            : remapped(address) ? address & ~0xFFFFF == 0xFEE0_0000 && address & 8 != 0 && data == 0
            : amdRemapped(data) ? address == 0xFEE0_0000 && data < 0x800
            : address & ~0xFF000 == 0xFEE0_0000 && data == base
        return message && (its || imsic || (base >= 0xB0 && base < 0xF0))
    }

    static func msiInfo(_ msi: borrowing Handle, _ info: inout croi_info_msi_t) -> Bool {
        Sys.call(CROI_SYS_OBJECT_GET_INFO, msi.arg, UInt64(CROI_INFO_MSI), Sys.address(&info),
                 UInt64(MemoryLayout<croi_info_msi_t>.size)) == 0
    }

    static func msiCreate(_ msi: borrowing Handle, _ options: UInt32, _ id: UInt64, _ vmo: borrowing Handle,
                          _ offset: UInt64, _ out: inout UInt32) -> Int64 {
        Sys.call(CROI_SYS_MSI_CREATE, msi.arg, UInt64(options), id, vmo.arg, offset, Sys.address(&out))
    }

    /// PCI segment 0's ECAM, from the environment the kernel gave this
    /// suite (`swift.ecam=0x<hex>`), or nil.
    static func ecam() -> UInt64? {
        let prefix: StaticString = "swift.ecam=0x"
        var index = 0
        while let entry = unsafe environ[index] {
            index += 1
            let length = unsafe strlen(entry)
            guard length > prefix.utf8CodeUnitCount else { continue }
            var matches = true
            for j in 0..<prefix.utf8CodeUnitCount where unsafe UInt8(bitPattern: entry[j]) != prefix.utf8Start[j] {
                matches = false
            }
            guard matches else { continue }
            var value: UInt64 = 0
            for j in prefix.utf8CodeUnitCount..<length {
                let digit = unsafe UInt8(bitPattern: entry[j])
                value = value << 4 | UInt64(digit <= 0x39 ? digit - 0x30 : (digit | 0x20) - 0x57)
            }
            return value == 0 ? nil : value
        }
        return nil
    }

    // Config space: bus 0's function-0 devices, 32 KiB apart.

    /// The offset of capability `id` in the function at `function`, or 0.
    static func capability(_ bus: borrowing Device, _ function: UInt64, _ id: UInt8) -> UInt64 {
        guard bus.read8(function + 6) & 0x10 != 0 else { return 0 }
        var at = UInt64(bus.read8(function + 0x34) & 0xFC)
        var n = 0
        while at != 0 && n < 48 {
            if bus.read8(function + at) == id { return at }
            at = UInt64(bus.read8(function + at + 1) & 0xFC)
            n += 1
        }
        return 0
    }

    /// A memory BAR's address (32 or 64-bit).
    static func bar(_ bus: borrowing Device, _ function: UInt64, _ index: UInt64) -> UInt64 {
        let low = bus.read32(function + 0x10 + 4 * index)
        var address = UInt64(low & ~0xF)
        if (low >> 1) & 3 == 2 { address |= UInt64(bus.read32(function + 0x14 + 4 * index)) << 32 }
        return address
    }

    /// Bus 0's function-0 device with this ID and capability (its config
    /// space's offset in `bus`, and the capability's), or 0.
    static func find(_ bus: borrowing Device, mask: UInt32, id: UInt32, capabilityId: UInt8,
                     _ at: inout UInt64) -> UInt64 {
        for device in UInt64(0)..<32 {
            let function = device << 15
            guard bus.read32(function) & mask == id else { continue }
            at = capability(bus, function, capabilityId)
            if at != 0 { return function }
        }
        return 0
    }

    // MARK: A handed-off context (ext 5, K14e)

    struct Handoff {
        var port: UInt32
        var interrupt: UInt32
        var round: UInt32 = 0     // rounds done
        var spinning: UInt32 = 0  // in round 3, waiting to be withdrawn
        var release: UInt32 = 0
        var deadline = InlineArray<4, Int64>(repeating: 0)
        var borrowed = InlineArray<4, Int64>(repeating: 0)
        var cpu = InlineArray<4, Int64>(repeating: 0)
        var start = InlineArray<4, Int64>(repeating: 0)
        var fellBack: Int64 = 0   // round 1: ns until the spent budget sent it back to its own, or -1
        var withdrawn: Int64 = 0  // round 3: back on its own while running, once the context was replaced
    }

    /// An interrupt that hands the thread its packet wakes an admitted
    /// context: the thread runs on it at once, wakeups within a period
    /// share its budget, an overrun is reported and the thread carries on
    /// on its own, and a lend replacing it withdraws it at once.
    static func handoff(_ root: borrowing Handle) {
        // 2 ms of budget every 2 s: the CBS rule keeps one period across
        // wakeups that come within half a second.
        let handoff = deadlineProfile(root, 2_000_000, 2_000_000_000, 2_000_000_000)
        let huge = deadlineProfile(root, 10_000_000, 10_000_000, 10_000_000)
        let lend = deadlineProfile(root, 1_000_000, 4_000_000, 4_000_000)
        let fair = CounterSuite.profile(root, deadline: false)
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        let irq = resource(root, UInt32(CROI_RSRC_KIND_IRQ), number, 1)
        var raw: UInt32 = 0
        check(create(irq, number, options: 0, &raw) == 0, "an interrupt object")
        let interrupt = Handle(adopting: raw)
        let overruns = Port()
        let handOff = UInt64(CROI_PROFILE_HANDOFF)
        var refusal: UInt32 = 99
        // Interrupts only, deadline profiles only, admitted (refused with a
        // reason); its overruns go to a port.
        check(setProfile(counter, handoff, handOff) == Status.invalidArgs, "HANDOFF is an interrupt's")
        check(setProfile(interrupt, fair, handOff) == Status.invalidArgs, "HANDOFF takes a deadline profile")
        check(overruns.bind(interrupt, UInt32(CROI_BIND_OVERRUN) | UInt32(CROI_BIND_PERSISTENT), key: 7)
                  == Status.badState, "no overruns without a context")
        check(setProfile(interrupt, huge, handOff, &refusal) == Status.noResources
                  && refusal & 0xFF == UInt32(CROI_ADMISSION_CPU_OVERLOADED), "refused with a reason")
        check(setProfile(interrupt, handoff, handOff, &refusal) == 0 && refusal == UInt32(CROI_ADMISSION_ACCEPTED),
              "admitted")
        check(overruns.bind(interrupt, UInt32(CROI_BIND_OVERRUN) | UInt32(CROI_BIND_PERSISTENT), key: 7) == 0,
              "its overruns to a port")
        let port = Port(options: UInt64(CROI_PORT_BIND_TO_INTERRUPT))
        check(port.bind(interrupt, persistent, key: 1) == 0, "bound")

        let state = UnsafeMutablePointer<Handoff>.allocate(capacity: 1)
        unsafe state.initialize(to: Handoff(port: port.handle.raw, interrupt: interrupt.raw))
        let entry: @convention(c) (UInt64) -> Void = { argument in
            let h = unsafe UnsafeMutablePointer<Handoff>(bitPattern: UInt(argument))!
            for i in 0..<4 {
                var packet = croi_port_packet_t()
                _ = unsafe croi_port_wait(h.pointee.port, .max, &packet, 0)
                _ = unsafe croi_interrupt_ack(h.pointee.interrupt)
                unsafe h.pointee.deadline[i] = Sys.call(CROI_SYS_TEST, 0)
                unsafe h.pointee.borrowed[i] = Sys.call(CROI_SYS_TEST, 10)
                unsafe h.pointee.cpu[i] = Sys.call(CROI_SYS_TEST, 5)
                unsafe h.pointee.start[i] = Sys.call(CROI_SYS_TEST, 3)
                let t0 = Sys.now()
                if i == 0 {
                    while Sys.now() - t0 < 500_000 {}  // some of the budget
                } else if i == 1 {
                    unsafe h.pointee.fellBack = -1  // the rest, and past it
                    while Sys.now() - t0 < 2_000_000_000 {
                        if Sys.call(CROI_SYS_TEST, 10) == -1 {
                            unsafe h.pointee.fellBack = Int64(Sys.now() - t0)
                            break
                        }
                    }
                } else if i == 3 {
                    unsafe h.pointee.spinning = 1
                    while unsafe h.pointee.release == 0 && Sys.now() - t0 < 5_000_000_000 {}
                    unsafe h.pointee.withdrawn = Sys.call(CROI_SYS_TEST, 10) == -1
                        && Sys.call(CROI_SYS_TEST, 0) == 0 ? 1 : 0
                }
                unsafe h.pointee.round = UInt32(i + 1)
            }
            Thread.exit()
        }
        let worker = Thread(entry, UInt64(UInt(bitPattern: state)))
        for i in UInt32(0)..<3 {
            check(blockedInPortWait(worker.handle) && fire(interrupt, Sys.now()) == 0
                      && done(i + 1, { unsafe state.pointee.round }), "woken by its interrupt's packet")
        }
        let h = unsafe state.pointee
        check(h.deadline[0] == 1 && h.borrowed[0] >= 0 && h.borrowed[0] == h.cpu[0],
              "a fair thread woken runs on the context's deadline, on its CPU")
        let overrun = overruns.next(deadline: Sys.now() + 1_000_000_000)
        check(h.deadline[1] == 1, "woken again, on the context's deadline")
        check(h.start[1] == h.start[0], "within the period: the same period")
        check(h.fellBack >= 0, "back on its own once the budget is spent")
        check(overrun?.type == UInt32(CROI_PKT_TYPE_BUDGET_OVERRUN) && overrun?.key == 7
                  && (overrun?.payload.1 ?? 0) >= 1, "an overrun reported")
        check(h.deadline[2] == 0 && h.borrowed[2] == -1, "woken while the budget is spent: on its own")
        // A new context (fresh budget); replaced by a lend while the woken
        // thread runs on it, it is withdrawn at once.
        check(setProfile(interrupt, handoff, handOff, &refusal) == 0 && blockedInPortWait(worker.handle)
                  && fire(interrupt, Sys.now()) == 0 && done(1, { unsafe state.pointee.spinning }), "a fresh context")
        let replaced = unsafe (state.pointee.deadline[3], state.pointee.borrowed[3])
        check(replaced.0 == 1 && replaced.1 >= 0 && setProfile(interrupt, lend, 0) == 0, "on it, then a lend")
        unsafe state.pointee.release = 1
        worker.join()
        check(unsafe state.pointee.withdrawn == 1, "withdrawn at once")
        unsafe state.deallocate()
    }

    /// Waits until `thread` is blocked in port_wait (a fire before that
    /// queues a packet its port_wait takes without a wakeup to hand
    /// anything on).
    static func blockedInPortWait(_ thread: borrowing Handle) -> Bool {
        let giveUp = Sys.now() + 2_000_000_000
        var info = croi_info_thread_t()
        var actual: UInt64 = 0, available: UInt64 = 0
        while Sys.now() < giveUp {
            if Sys.call(CROI_SYS_OBJECT_GET_INFO, thread.arg, UInt64(CROI_INFO_THREAD), Sys.address(&info),
                        UInt64(MemoryLayout<croi_info_thread_t>.size), Sys.address(&actual), Sys.address(&available)) == 0
                && info.state == UInt32(CROI_THREAD_STATE_BLOCKED_PORT) {
                return true
            }
            Sys.sleep(200_000)
        }
        return false
    }

    /// Waits up to five seconds for `word` to reach `want`.
    static func done(_ want: UInt32, _ word: () -> UInt32) -> Bool {
        let giveUp = Sys.now() + 5_000_000_000
        while word() < want && Sys.now() < giveUp { Sys.sleep(200_000) }
        return word() >= want
    }

    static func deadlineProfile(_ root: borrowing Handle, _ capacity: Int64, _ deadline: Int64,
                                _ period: Int64) -> Handle {
        var info = croi_profile_info_t()
        info.flags = UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE)
        info.deadline_params = croi_sched_deadline_params_t(capacity: capacity, relative_deadline: deadline,
                                                            period: period)
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_PROFILE_CREATE, root.arg, 0, Sys.address(&info), Sys.address(&out)) == 0,
              "creating a deadline profile")
        return Handle(adopting: out)
    }

    static func setProfile(_ target: borrowing Handle, _ profile: borrowing Handle, _ options: UInt64) -> Int64 {
        Sys.call(CROI_SYS_OBJECT_SET_PROFILE, target.arg, profile.arg, options)
    }

    static func setProfile(_ target: borrowing Handle, _ profile: borrowing Handle, _ options: UInt64,
                           _ refusal: inout UInt32) -> Int64 {
        Sys.call(CROI_SYS_OBJECT_SET_PROFILE, target.arg, profile.arg, options, Sys.address(&refusal))
    }

    // MARK: Calls

    static func resource(_ parent: borrowing Handle, _ kind: UInt32, _ base: UInt64, _ size: UInt64) -> Handle {
        let name: StaticString = "drv"
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_RESOURCE_CREATE, parent.arg | UInt64(kind) << 32, base, size,
                       unsafe UInt64(UInt(bitPattern: name.utf8Start)), 3, Sys.address(&out)) == 0,
              "creating a resource")
        return Handle(adopting: out)
    }

    static func create(_ resource: borrowing Handle, _ number: UInt64, options: UInt32, _ out: inout UInt32) -> Int64 {
        Sys.call(CROI_SYS_INTERRUPT_CREATE, resource.arg, number, UInt64(options), Sys.address(&out))
    }

    static func ack(_ interrupt: borrowing Handle) -> Int64 { croi_interrupt_ack(interrupt.raw) }

    static func affinity(_ interrupt: borrowing Handle, _ mask: UInt64) -> Int64 {
        Sys.call(CROI_SYS_INTERRUPT_SET_AFFINITY, interrupt.arg, mask)
    }

    /// The test hook that fires an interrupt as its device would, at `time`.
    static func fire(_ interrupt: borrowing Handle, _ time: UInt64) -> Int64 {
        Sys.call(CROI_SYS_TEST, 13, interrupt.arg, time)
    }

    static func close(_ handle: consuming Handle) {}
}

/// A device's registers, or config space: a physical VMO under a resource,
/// mapped read/write.
struct Device: ~Copyable {
    let vmo: Handle
    let mapping: Mapping
    let address: UInt64

    init(_ resource: borrowing Handle, _ base: UInt64, _ size: UInt64, policy: UInt32? = nil) {
        let first = base & ~(pageSize - 1)
        let length = ((base + size + pageSize - 1) & ~(pageSize - 1)) - first
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_VMO_CREATE_PHYSICAL, resource.arg, first, length, Sys.address(&raw)) == 0,
              "a physical VMO")
        let vmo = Handle(adopting: raw)
        if let policy {
            check(Sys.call(CROI_SYS_VMO_SET_CACHE_POLICY, vmo.arg, UInt64(policy)) == 0, "its cache policy")
        }
        let mapping = Mapping(vmo, length: length)
        address = mapping.address + (base - first)
        self.vmo = vmo
        self.mapping = mapping
    }

    func read8(_ offset: UInt64) -> UInt8 { croi_mmio_read8(address + offset) }
    func read16(_ offset: UInt64) -> UInt16 { croi_mmio_read16(address + offset) }
    func read32(_ offset: UInt64) -> UInt32 { croi_mmio_read32(address + offset) }
    func write16(_ offset: UInt64, _ value: UInt16) { croi_mmio_write16(address + offset, value) }
    func write32(_ offset: UInt64, _ value: UInt32) { croi_mmio_write32(address + offset, value) }
}
