import CKernel
import Synchronization

/// An interrupt object (K9c; Zircon's InterruptDispatcher): a device
/// interrupt (`DeviceIrqs`) or an MSI, delivered as a packet to the port
/// it is bound to and re-armed by ack. V1 cut interrupt_wait, virtual
/// interrupts (interrupt_trigger) and interrupt_destroy (D29): a port is
/// the one way to wait, a counter is a virtual interrupt, and closing the
/// last handle destroys it.
///
/// States as Zircon's: IDLE, TRIGGERED (fired, not bound yet), NEEDACK
/// (delivered; a further fire only records its timestamp), DESTROYED. A
/// level interrupt is masked when it fires and unmasked on ack, so it
/// can't storm while its driver works.
///
/// Locks: the header lock guards the state, taken in interrupt context
/// too. Lock order: irq table -> object -> controller, port packets,
/// scheduler.
struct InterruptObject: ~Copyable {
    enum State { case idle, triggered, needAck, destroyed }

    var header = ObjectHeader(type: .interrupt)
    var state = State.idle
    /// The first unconsumed fire's time (0: none pending).
    var timestamp: UInt64 = 0
    /// Level-triggered: masked when it fires, unmasked when re-armed.
    let level: Bool
    let activeLow: Bool
    let number: UInt32
    /// Installed as its number's handler (a create that lost the race to
    /// another object isn't, and must not unregister it).
    var registered = false
    /// An MSI's state (`MsiState` on the heap), or 0.
    var msi: UInt64 = 0
    /// The bound port (holding a reference), or 0.
    var port: UInt64 = 0
    /// The packet it queues to that port (never allocated when firing).
    let packet: QueuedPacketPointer
    /// The CPUs it may go to and the one it does (device interrupts).
    var affinity: UInt64 = 1
    var cpu = 0
    /// Ext 5 (K14e): an admitted scheduling context it owns (a
    /// SchedContextRecord's address, 0 for none); the thread its packet
    /// wakes from its port runs on it at once, sharing its budget across
    /// wakeups.
    var context: UInt64 = 0
    /// Ext 5 (K10c): a deadline profile the thread its packet wakes runs on
    /// from its wakeup until it next blocks (object_set_profile).
    var lend: Profile? = nil

    /// ZX_DEFAULT_INTERRUPT_RIGHTS.
    static var defaultRights: Rights { Rights.basic.union(.read | .write | .signal) }
}

@safe struct InterruptPointer {
    let object: ObjectPointer

    var pointee: InterruptObject {
        unsafeAddress { unsafe UnsafePointer<InterruptObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress {
            unsafe UnsafeMutablePointer<InterruptObject>(bitPattern: UInt(object.address))!
        }
    }
}

enum InterruptObjects {
    // MARK: Creation and teardown

    /// interrupt_create: a device interrupt on `number` (the caller checked
    /// its IRQ resource), routed to the boot CPU and unmasked.
    static func create(number: UInt32, options: UInt32) throws(Status) -> ObjectPointer {
        let known = UInt32(CROI_INTERRUPT_REMAP_IRQ | CROI_INTERRUPT_MODE_MASK | CROI_INTERRUPT_TIMESTAMP_MONO)
        guard options & ~known == 0 else { throw .invalidArgs }
        let vector = options & UInt32(CROI_INTERRUPT_REMAP_IRQ) != 0 ? DeviceIrqs.remapIsa(number) : number
        guard DeviceIrqs.isValid(vector) else { throw .invalidArgs }
        var (level, activeLow) = DeviceIrqs.defaultMode(vector)
        switch options & UInt32(CROI_INTERRUPT_MODE_MASK) {
        case UInt32(CROI_INTERRUPT_MODE_DEFAULT): ()
        case UInt32(CROI_INTERRUPT_MODE_EDGE_LOW): (level, activeLow) = (false, true)
        case UInt32(CROI_INTERRUPT_MODE_EDGE_HIGH): (level, activeLow) = (false, false)
        case UInt32(CROI_INTERRUPT_MODE_LEVEL_LOW): (level, activeLow) = (true, true)
        case UInt32(CROI_INTERRUPT_MODE_LEVEL_HIGH): (level, activeLow) = (true, false)
        case UInt32(CROI_INTERRUPT_MODE_EDGE_BOTH): throw .notSupported
        default: throw .invalidArgs
        }
        let object = try make(level: level, activeLow: activeLow, number: vector)
        do throws(Status) {
            try DeviceIrqs.register(vector, object)
            InterruptPointer(object: object).pointee.registered = true
        } catch {
            object.release()
            throw error
        }
        do throws(Status) {
            try DeviceIrqs.configure(vector, level: level, activeLow: activeLow, cpu: 0)
        } catch {
            object.release()  // destroys: unregisters
            throw error
        }
        DeviceIrqs.unmask(vector)
        return object
    }

    /// An interrupt object for an MSI (MsiInterrupts.create attaches it).
    /// MSIs are masked while delivered, as level interrupts are (Zircon's
    /// UNMASK_PREWAIT | MASK_POSTWAIT).
    static func makeForMsi() throws(Status) -> ObjectPointer {
        try make(level: true, activeLow: false, number: 0)
    }

    private static func make(level: Bool, activeLow: Bool, number: UInt32) throws(Status) -> ObjectPointer {
        let packet = try QueuedPacketPointer.allocate(PortPacket(type: PortPacket.interrupt), source: Ports.interruptOwned)
        guard let object = Objects.allocate(InterruptObject(level: level, activeLow: activeLow, number: number,
                                                            packet: packet)) else {
            packet.free()
            throw .noMemory
        }
        return object
    }

    /// The last reference went (Objects.destroy).
    static func destroyObject(_ object: ObjectPointer) {
        destroy(object)
        latencyChanged(object, gone: true)
        let interrupt = InterruptPointer(object: object)
        let port = interrupt.pointee.port
        if port != 0 {
            _ = Ports.removeInterrupt(PortPointer(object: ObjectPointer(address: port)), interrupt.pointee.packet)
            ObjectPointer(address: port).release()
        }
        free(object)
    }

    private static func free(_ object: ObjectPointer) {
        let interrupt = InterruptPointer(object: object)
        dropContext(interrupt.pointee.context)
        if interrupt.pointee.msi != 0 { MsiInterrupts.free(MsiStatePointer(address: interrupt.pointee.msi)) }
        interrupt.pointee.packet.free()
        Objects.free(object, as: InterruptObject.self)
    }

    /// The last reference went (interrupt_destroy until V1, D29): no more
    /// fires, and a bound packet still queued is taken back.
    private static func destroy(_ object: ObjectPointer) {
        let interrupt = InterruptPointer(object: object)
        object.header.lock.withLock { interrupt.pointee.state = .destroyed }
        if interrupt.pointee.msi != 0 {
            MsiInterrupts.detach(MsiStatePointer(address: interrupt.pointee.msi))
        } else if interrupt.pointee.registered {
            DeviceIrqs.mask(interrupt.pointee.number)
            DeviceIrqs.unregister(interrupt.pointee.number)  // no handler running once it returns
        }
        object.header.lock.withLock {
            if interrupt.pointee.port != 0 {
                _ = Ports.removeInterrupt(PortPointer(object: ObjectPointer(address: interrupt.pointee.port)),
                                          interrupt.pointee.packet)
            }
        }
    }

    // MARK: Firing

    /// The interrupt fired: from its device (interrupt context, irq table
    /// lock held), or from a test (TestHooks, at `time`).
    static func fire(_ object: ObjectPointer, at time: UInt64 = 0) {
        let interrupt = InterruptPointer(object: object)
        object.header.lock.withLock {
            guard interrupt.pointee.state != .destroyed else { return }
            if interrupt.pointee.timestamp == 0 { interrupt.pointee.timestamp = time != 0 ? time : Clock.now() }
            deliver(interrupt)
        }
    }

    /// Delivers a pending fire: a packet unless one awaits its ack; kept
    /// until bound if unbound. Object lock held.
    private static func deliver(_ interrupt: InterruptPointer) {
        if interrupt.pointee.port != 0 {
            guard interrupt.pointee.state != .needAck else { return }  // sent once acked
            sendPacket(interrupt)
            interrupt.pointee.state = .needAck
        } else {
            if interrupt.pointee.level { maskSource(interrupt) }
            if interrupt.pointee.state != .needAck { interrupt.pointee.state = .triggered }
        }
    }

    /// Queues the bound packet with the pending timestamp, waking a thread
    /// from the port on the context (ext 5) or the lent profile (K10c).
    /// Object lock held.
    @discardableResult
    private static func sendPacket(_ interrupt: InterruptPointer) -> Bool {
        let context = interrupt.pointee.context
        let sent = Ports.queueInterrupt(PortPointer(object: ObjectPointer(address: interrupt.pointee.port)),
                                        interrupt.pointee.packet, timestamp: interrupt.pointee.timestamp,
                                        handingOff: context != 0 ? SchedContextPointer(address: context) : nil,
                                        lending: interrupt.pointee.lend)
        if interrupt.pointee.level { maskSource(interrupt) }
        interrupt.pointee.timestamp = 0
        return sent
    }

    /// Ext 5: hands `context` (admitted, now the object's) to the threads
    /// its packets wake from now on, or nil for none; a profile lent before is
    /// dropped. A context it had is withdrawn from whoever runs on it,
    /// then destroyed.
    static func setContext(_ object: ObjectPointer, _ context: consuming SchedContext?, lend: Profile?) {
        let record = context?.leak()
        let old = object.header.lock.withLock { () -> UInt64 in
            let interrupt = InterruptPointer(object: object)
            let old = interrupt.pointee.context
            interrupt.pointee.context = record?.address ?? 0
            interrupt.pointee.lend = lend
            return old
        }
        dropContext(old)
        latencyChanged(object)
    }

    private static func dropContext(_ address: UInt64) {
        guard address != 0 else { return }
        let context = SchedContextPointer(address: address)
        Scheduler.withdraw(context)
        _ = SchedContext(owning: context)  // nobody on it now: destroyed
    }

    /// Ext 3 for the handed-off context: its overruns go to `source` (a
    /// PacketSource); the one bound before is returned, nil without a
    /// context. Under the object lock, so the context can't go meanwhile.
    static func bindOverrunSource(_ object: ObjectPointer, _ source: UInt64) -> UInt64? {
        object.header.lock.withLock { () -> UInt64? in
            let address = InterruptPointer(object: object).pointee.context
            guard address != 0 else { return nil }
            return Scheduler.locked { () -> UInt64 in
                let context = SchedContextPointer(address: address)
                let old = context.pointee.overrunSource
                context.pointee.overrunSource = source
                return old
            }
        }
    }

    /// Masks / unmasks where it comes from: its controller pin, or its
    /// MSI-X entry or MSI mask bit. Object lock held.
    private static func maskSource(_ interrupt: InterruptPointer) {
        if interrupt.pointee.msi != 0 {
            MsiInterrupts.setMasked(MsiStatePointer(address: interrupt.pointee.msi), true)
        } else {
            DeviceIrqs.mask(interrupt.pointee.number)
        }
    }

    private static func unmaskSource(_ interrupt: InterruptPointer) {
        if interrupt.pointee.msi != 0 {
            MsiInterrupts.setMasked(MsiStatePointer(address: interrupt.pointee.msi), false)
        } else {
            DeviceIrqs.unmask(interrupt.pointee.number)
        }
    }

    // MARK: Ports

    /// object_bind INTERRUPT: packets to `port` with `key` from now on (one
    /// already pending is sent at once).
    static func bind(_ object: ObjectPointer, port: ObjectPointer, key: UInt64) throws(Status) {
        let interrupt = InterruptPointer(object: object)
        try object.header.lock.withLock { () throws(Status) in
            guard interrupt.pointee.state != .destroyed else { throw .canceled }
            guard interrupt.pointee.port == 0 else { throw .alreadyBound }
            port.retain()
            interrupt.pointee.port = port.address
            interrupt.pointee.packet.pointee.packet.key = key
            if interrupt.pointee.state == .triggered {
                sendPacket(interrupt)
                interrupt.pointee.state = .needAck
            }
        }
    }

    /// port_cancel(port, interrupt, key): unbinds it if it is bound there
    /// with `key`; whether it was.
    static func cancel(_ object: ObjectPointer, port: ObjectPointer, key: UInt64) -> Bool {
        let bound = object.header.lock.withLock {
            let interrupt = InterruptPointer(object: object)
            return interrupt.pointee.port == port.address && interrupt.pointee.packet.pointee.packet.key == key
        }
        guard bound else { return false }
        return (try? unbind(object, port: port)) != nil
    }

    /// Unbinding: a packet still queued is taken back and the interrupt
    /// counts as triggered again, so it isn't lost.
    static func unbind(_ object: ObjectPointer, port: ObjectPointer) throws(Status) {
        let interrupt = InterruptPointer(object: object)
        try object.header.lock.withLock { () throws(Status) in
            guard interrupt.pointee.port == port.address else { throw .notFound }
            guard interrupt.pointee.state != .destroyed else { throw .canceled }
            let removed = Ports.removeInterrupt(PortPointer(object: port), interrupt.pointee.packet)
            interrupt.pointee.port = 0
            if interrupt.pointee.state == .needAck && removed {
                interrupt.pointee.state = .triggered
                interrupt.pointee.timestamp = interrupt.pointee.packet.pointee.packet.payload[0]
            }
            interrupt.pointee.packet.pointee.packet.key = 0
        }
        port.release()  // the binding's reference
    }

    /// interrupt_ack: re-arms a bound interrupt; a fire recorded meanwhile
    /// is sent at once.
    static func ack(_ object: ObjectPointer) throws(Status) {
        let interrupt = InterruptPointer(object: object)
        try object.header.lock.withLock { () throws(Status) in
            guard interrupt.pointee.port != 0 else { throw .badState }
            guard interrupt.pointee.state != .destroyed else { throw .canceled }
            if interrupt.pointee.state == .needAck {
                if interrupt.pointee.level { unmaskSource(interrupt) }
                if interrupt.pointee.timestamp != 0 {
                    guard sendPacket(interrupt) else { throw .badState }  // the last one is still queued
                } else {
                    interrupt.pointee.state = .idle
                }
            }
        }
    }

    // MARK: Affinity

    /// interrupt_set_affinity (croi's): routes it to the lowest CPU of
    /// `mask` that takes interrupts.
    static func setAffinity(_ object: ObjectPointer, mask: UInt64) throws(Status) {
        let interrupt = InterruptPointer(object: object)
        var cpu = -1
        let tag = Scheduler.currentReservation  // K10d: never onto another job's reserved CPU
        for i in 0..<Smp.count where mask & (1 << UInt64(i)) != 0 && Scheduler.mayRoute(cpu: i, tag: tag) {
            let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[i]))!
            if unsafe record.pointee.interruptsReady.load(ordering: .acquiring) {
                cpu = i
                break
            }
        }
        guard cpu >= 0 else { throw .invalidArgs }
        try object.header.lock.withLock { () throws(Status) in
            guard interrupt.pointee.state != .destroyed else { throw .canceled }
            // Open again after the move unless it waits for an ack.
            let parked = interrupt.pointee.level && (interrupt.pointee.state == .needAck
                || interrupt.pointee.state == .triggered)
            if interrupt.pointee.msi != 0 {
                try MsiInterrupts.retarget(MsiStatePointer(address: interrupt.pointee.msi), object, cpu: cpu,
                                           masked: parked)
            } else {
                let number = interrupt.pointee.number
                try DeviceIrqs.configure(number, level: interrupt.pointee.level,
                                         activeLow: interrupt.pointee.activeLow, cpu: cpu)
                if !parked { DeviceIrqs.unmask(number) }  // configure masked it
            }
            interrupt.pointee.affinity = mask
            interrupt.pointee.cpu = cpu
        }
        latencyChanged(object)  // K15c: its bound moves with it
    }

    /// K15c (Todhchai ext 11): an interrupt with a deadline profile (lent
    /// or handed off) bounds the wake latency of the CPU it is routed to,
    /// as an admitted deadline thread does, so the idle governor never
    /// leaves that CPU in a state slower to wake than its deadline allows.
    static func latencyChanged(_ object: ObjectPointer, gone: Bool = false) {
        let (cpu, params) = object.header.lock.withLock { () -> (Int, DeadlineParams?) in
            let interrupt = InterruptPointer(object: object)
            if !gone, interrupt.pointee.context != 0 {
                return (interrupt.pointee.cpu, SchedContextPointer(address: interrupt.pointee.context).pointee.profile.params)
            }
            if !gone, let lent = interrupt.pointee.lend, lent.discipline == .deadline {
                return (interrupt.pointee.cpu, lent.params)
            }
            return (interrupt.pointee.cpu, nil)
        }
        Scheduler.setInterruptLatency(object.address, cpu: cpu, params)
    }

}
