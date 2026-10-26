import CKernel
import Synchronization

/// A port packet, laid out as zx_port_packet_t: key, type, status, and 32
/// bytes of payload (for signal packets: trigger, observed, count,
/// timestamp).
struct PortPacket: Equatable {
    var key: UInt64 = 0
    var type: UInt32 = 0
    var status: Int32 = 0
    var payload = InlineArray<4, UInt64>(repeating: 0)

    static func == (a: PortPacket, b: PortPacket) -> Bool {
        a.key == b.key && a.type == b.type && a.status == b.status && a.payload[0] == b.payload[0]
            && a.payload[1] == b.payload[1] && a.payload[2] == b.payload[2] && a.payload[3] == b.payload[3]
    }

    /// Packet types: Zircon's, then croi's own kernel sources.
    static var user: UInt32 { 0 }
    static var signalOne: UInt32 { 1 }
    /// An interrupt object's (payload[0]: timestamp).
    static var interrupt: UInt32 { 7 }
    /// Ext 3: a deadline reservation overran its budget (count in payload[2]).
    static var budgetOverrun: UInt32 { 0x80 }
    /// Ext 6: a memory account crossed its pressure level (bytes charged in
    /// payload[1], count in payload[2]).
    static var memoryPressure: UInt32 { 0x81 }
    /// K13d: a pager VMO's request (payload: command, offset, length).
    static var pageRequest: UInt32 { 9 }

    // Signal payload: trigger (low 32 of [0]), observed (high 32 of [0]), count, timestamp.
    var trigger: UInt32 { UInt32(truncatingIfNeeded: payload[0]) }
    var observed: UInt32 { UInt32(truncatingIfNeeded: payload[0] >> 32) }
    var count: UInt64 { payload[2] }
}

/// A queued packet. Owned by the queue (from object_bind ONCE or
/// port_queue: freed when dequeued), by a packet source (a kernel event or
/// a PERSISTENT binding), or by an interrupt object
/// (both reused: never freed here).
struct QueuedPacket {
    var next: UInt64 = 0
    var packet: PortPacket
    /// 0, the PacketSource that owns this record, or `Ports.interruptOwned`.
    let source: UInt64
    /// An interrupt packet is on its port's interrupt list (packets lock).
    var interruptQueued = false
    /// For cancellation: the object and handle a signal packet came from.
    let originTable: UInt64
    let originHandle: UInt32
}

@safe struct QueuedPacketPointer: Equatable {
    let address: UInt64

    var pointee: QueuedPacket {
        unsafeAddress { unsafe UnsafePointer<QueuedPacket>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<QueuedPacket>(bitPattern: UInt(address))! }
    }

    static func allocate(_ packet: PortPacket, source: UInt64 = 0, table: UInt64 = 0,
                         handle: UInt32 = 0) throws(Status) -> QueuedPacketPointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<QueuedPacket>.size) else { throw .noMemory }
        unsafe raw.bindMemory(to: QueuedPacket.self, capacity: 1).initialize(
            to: QueuedPacket(packet: packet, source: source, originTable: table, originHandle: handle))
        return QueuedPacketPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func free() {
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(address))!)
    }
}

/// A port (Zircon's PortDispatcher): a FIFO of packets and the threads
/// waiting for them. `packetsLock` guards the queue; waiters block on the
/// scheduler. Lock order: object -> scheduler -> packets. A port created
/// with BIND_TO_INTERRUPT also has interrupt objects' packets, on a list
/// of their own that is read first (Zircon's).
struct PortObject: ~Copyable {
    var header = ObjectHeader(type: .port)
    let packetsLock = SpinLock()
    var head: UInt64 = 0
    var tail: UInt64 = 0
    var queued = 0
    /// port_queue's packets among them (review fix: they had no bound;
    /// Zircon's limit is `Ports.maxUserPackets`).
    var userQueued = 0
    let waiters = QueuePointer.allocate()
    let bindToInterrupt: Bool
    var interruptHead: UInt64 = 0
    var interruptTail: UInt64 = 0
    /// D44: a port made with CROI_PORT_RING delivers its packets into the
    /// one ring, in a pinned page of a contiguous VMO the reader maps and
    /// the kernel writes through the physmap. The queue above holds what
    /// the ring has no room for yet (packets lock).
    var ring: NativeRing? = nil
    var hasRing = false
    var ringVmo: UInt64 = 0
    /// K13e: the objects with async waits to this port, once per observer
    /// (port_cancel with source 0 finds them here). Under `packetsLock`; an entry
    /// means an observer is registered, so the object is alive (objects
    /// lose their observers before their last reference: handle close).
    var watched = UniqueArray<UInt64>()

    /// ZX_DEFAULT_PORT_RIGHTS: no WAIT (ports are waited on with port_wait).
    static var defaultRights: Rights { Rights.basic.subtracting(.wait).union(.read | .write) }
}

extension QueuedPacketPointer {
    /// A port_queue packet: no source, no origin handle, not an interrupt's.
    var isUserPacket: Bool {
        pointee.source == 0 && pointee.originTable == 0 && pointee.packet.type == PortPacket.user
    }
}

@safe struct PortPointer {
    let object: ObjectPointer

    var pointee: PortObject {
        unsafeAddress { unsafe UnsafePointer<PortObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PortObject>(bitPattern: UInt(object.address))! }
    }
}

enum Ports {
    /// `QueuedPacket.source` of an interrupt object's packet.
    static var interruptOwned: UInt64 { ~0 }

    static var ringSlots: Int { Int(CROI_PORT_RING_SLOTS) }
    static var ringFormat: UInt64 { UInt64(CROI_PORT_RING_FORMAT) }
    static var packetSize: Int { MemoryLayout<PortPacket>.size }
    /// The ring VMO's rights: the reader maps it read-write (its cursor is
    /// in it), and can't resize it or change its cache policy.
    static var ringRights: Rights { .basic | .read | .write | .map | .getProperty }

    static func create(options: UInt64 = 0) throws(Status) -> ObjectPointer {
        let known = UInt64(CROI_PORT_BIND_TO_INTERRUPT) | UInt64(CROI_PORT_RING)
        guard options & ~known == 0 else { throw .invalidArgs }
        let interrupts = options & UInt64(CROI_PORT_BIND_TO_INTERRUPT) != 0
        guard let object = Objects.allocate(PortObject(bindToInterrupt: interrupts)) else { throw .noMemory }
        return object
    }

    /// D44: gives a new port its ring; the ring's VMO object, for the
    /// creator's handle. The page is pinned, so it is never decommitted
    /// or lent while the kernel writes it.
    static func makeRing(_ object: ObjectPointer) throws(Status) -> ObjectPointer {
        let page = KernelLayout.pageSize
        let vmo = try vmStatus { () throws(VmError) -> Vmo in try Vmo(contiguous: page) }
        guard case .contiguous(let phys) = vmo.record.pointee.kind else { panic("port: ring VMO") }
        let vmoObject = try VmoObject.wrap(vmo.record)
        do throws(VmError) {
            try vmo.pin(offset: 0, size: page)
        } catch {
            vmoObject.release()
            throw error.status
        }
        let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
        guard unsafe NativeRing.create(base, size: Int(page), slotSize: packetSize, count: ringSlots,
                                       format: ringFormat) else { panic("port: making a ring") }
        let port = PortPointer(object: object)
        port.pointee.ring = unsafe NativeRing(attaching: base, size: Int(page), producer: true, slotSize: packetSize,
                                              format: ringFormat)
        port.pointee.hasRing = true
        port.pointee.ringVmo = vmo.keep().address  // the port's reference
        return vmoObject
    }

    static func destroy(_ object: ObjectPointer) {
        let port = PortPointer(object: object)
        while let (_, record) = pop(port) {
            if let record { release(record) }
        }
        if port.pointee.hasRing {
            let vmo = VmoPointer(address: port.pointee.ringVmo)
            try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in
                v.unpin(offset: 0, size: KernelLayout.pageSize)
            }
            vmo.release()
        }
        port.pointee.waiters.deallocate()
        Objects.free(object, as: PortObject.self)
    }

    /// Queues `record` and wakes one waiter. Any context; the caller may
    /// hold an object lock, or (kernel sources) the scheduler lock.
    /// `wake`: what the packet's source gives the thread it wakes: a lent
    /// profile (K10c, ext 5: a counter's), or a synchronous wake (D139).
    static func enqueue(_ port: PortPointer, _ record: QueuedPacketPointer, schedulerLocked: Bool = false,
                        wake: Scheduler.Wake = .init()) {
        port.pointee.packetsLock.withLock {
            record.pointee.next = 0
            if port.pointee.tail != 0 {
                QueuedPacketPointer(address: port.pointee.tail).pointee.next = record.address
            } else {
                port.pointee.head = record.address
            }
            port.pointee.tail = record.address
            port.pointee.queued += 1
        }
        // D44: into the ring now, if it has room, so a busy reader needs no
        // syscall. Not under the scheduler lock: a delivered record goes
        // back to its source, which may free it. (`hasRing` is set before
        // the port has a handle, and never changes.)
        if port.pointee.hasRing, !schedulerLocked { deliver(port) }
        if schedulerLocked {
            Scheduler.wakeOne(port.pointee.waiters, wake)
        } else {
            Scheduler.locked { _ = Scheduler.wakeOne(port.pointee.waiters, wake) }
        }
    }

    /// Takes a queued kernel-source packet back out (its source is retiring);
    /// false if a reader already took it (and will hand it back).
    static func unqueue(_ port: PortPointer, _ record: QueuedPacketPointer) -> Bool {
        port.pointee.packetsLock.withLock { () -> Bool in
            var previous: UInt64 = 0
            var cursor = port.pointee.head
            while cursor != 0 {
                let next = QueuedPacketPointer(address: cursor).pointee.next
                if cursor == record.address {
                    if previous != 0 {
                        QueuedPacketPointer(address: previous).pointee.next = next
                    } else {
                        port.pointee.head = next
                    }
                    if port.pointee.tail == cursor { port.pointee.tail = previous }
                    port.pointee.queued -= 1
                    return true
                }
                previous = cursor
                cursor = next
            }
            return false
        }
    }

    /// The next packet (interrupts first), copied under the lock, and its
    /// record if it needs `release` (an interrupt's stays its object's).
    private static func pop(_ port: PortPointer) -> (PortPacket, QueuedPacketPointer?)? {
        port.pointee.packetsLock.withLock { () -> (PortPacket, QueuedPacketPointer?)? in popLocked(port) }
    }

    /// `pop` with the packets lock held; `interruptsOnly` leaves the main
    /// queue alone.
    private static func popLocked(_ port: PortPointer,
                                  interruptsOnly: Bool = false) -> (PortPacket, QueuedPacketPointer?)? {
        if port.pointee.interruptHead != 0 {
            let record = QueuedPacketPointer(address: port.pointee.interruptHead)
            port.pointee.interruptHead = record.pointee.next
            if port.pointee.interruptHead == 0 { port.pointee.interruptTail = 0 }
            record.pointee.interruptQueued = false
            port.pointee.queued -= 1
            return (record.pointee.packet, nil)
        }
        guard port.pointee.head != 0, !interruptsOnly else { return nil }
        let record = QueuedPacketPointer(address: port.pointee.head)
        port.pointee.head = record.pointee.next
        if port.pointee.head == 0 { port.pointee.tail = 0 }
        port.pointee.queued -= 1
        if record.isUserPacket { port.pointee.userQueued -= 1 }
        return (record.pointee.packet, record)
    }

    /// Records delivered into a ring, handed back once the packets lock
    /// drops (`release` takes the source's lock, and may free).
    struct Released: ~Copyable {
        var records = InlineArray<8, UInt64>(repeating: 0)
        var count = 0
        var full: Bool { count == 8 }

        mutating func add(_ record: QueuedPacketPointer) {
            records[count] = record.address
            count += 1
        }

        consuming func release() {
            for i in 0..<count { Ports.release(QueuedPacketPointer(address: records[i])) }
        }
    }

    /// D44: delivers what the ring has room for, a batch of records at a
    /// time. Not under the scheduler lock.
    private static func deliver(_ port: PortPointer) {
        while true {
            var released = Released()
            port.pointee.packetsLock.withLock { deliverLocked(port, &released) }
            let more = released.full
            released.release()
            if !more { return }
        }
    }

    /// D44: moves queued packets (interrupts first) into the port's ring
    /// while it has room and `released` has room for their records.
    /// Nothing if the port has no ring, or its reader broke it. Packets
    /// lock held.
    private static func deliverLocked(_ port: PortPointer, _ released: inout Released,
                                      interruptsOnly: Bool = false) {
        guard port.pointee.hasRing else { return }
        let space = port.pointee.ring!.space()
        var delivered: UInt64 = 0
        while delivered < space, !released.full,
              let (packet, record) = popLocked(port, interruptsOnly: interruptsOnly) {
            var copy = packet
            unsafe withUnsafeBytes(of: &copy) { unsafe port.pointee.ring!.put(delivered, from: $0.baseAddress!) }
            if let record { released.add(record) }
            delivered += 1
        }
        if delivered > 0 { _ = port.pointee.ring!.publish(delivered) }
    }

    /// Queues an interrupt object's packet with `timestamp` and wakes a
    /// waiter; false if it is still queued. Any context (interrupts too).
    /// `handingOff` / `lending`: the interrupt's context or lent profile
    /// for the thread it wakes (ext 5, K10c).
    static func queueInterrupt(_ port: PortPointer, _ record: QueuedPacketPointer, timestamp: UInt64,
                               handingOff context: SchedContextPointer?, lending: Profile?) -> Bool {
        let queued = port.pointee.packetsLock.withLock { () -> Bool in
            guard !record.pointee.interruptQueued else { return false }
            record.pointee.interruptQueued = true
            record.pointee.packet.type = PortPacket.interrupt
            record.pointee.packet.status = 0
            record.pointee.packet.payload[0] = timestamp
            record.pointee.next = 0
            if port.pointee.interruptTail != 0 {
                QueuedPacketPointer(address: port.pointee.interruptTail).pointee.next = record.address
            } else {
                port.pointee.interruptHead = record.address
            }
            port.pointee.interruptTail = record.address
            port.pointee.queued += 1
            // D44: an interrupt's record stays its object's, so it can go
            // into the ring from any context.
            var none = Released()
            deliverLocked(port, &none, interruptsOnly: true)
            none.release()
            return true
        }
        if queued {
            Scheduler.locked {
                if let context {
                    _ = Scheduler.wakeOne(port.pointee.waiters, handingOff: context)
                } else {
                    _ = Scheduler.wakeOne(port.pointee.waiters, Scheduler.Wake(lending: lending))
                }
            }
        }
        return queued
    }

    /// Takes an interrupt object's packet off its port; false if it wasn't
    /// queued (already read).
    static func removeInterrupt(_ port: PortPointer, _ record: QueuedPacketPointer) -> Bool {
        port.pointee.packetsLock.withLock { () -> Bool in
            guard record.pointee.interruptQueued else { return false }
            var previous: UInt64 = 0
            var cursor = port.pointee.interruptHead
            while cursor != 0, cursor != record.address {
                previous = cursor
                cursor = QueuedPacketPointer(address: cursor).pointee.next
            }
            guard cursor != 0 else { return false }
            if previous != 0 {
                QueuedPacketPointer(address: previous).pointee.next = record.pointee.next
            } else {
                port.pointee.interruptHead = record.pointee.next
            }
            if port.pointee.interruptTail == record.address { port.pointee.interruptTail = previous }
            record.pointee.interruptQueued = false
            port.pointee.queued -= 1
            return true
        }
    }

    /// Frees a dequeued record, or hands it back to its kernel source.
    fileprivate static func release(_ record: QueuedPacketPointer) {
        if record.pointee.source != 0 {
            PacketSourcePointer(address: record.pointee.source).dequeued()
        } else {
            record.free()
        }
    }

    // MARK: Syscall-shaped operations

    /// port_queue: a user packet (its type is forced to user).
    /// Zircon's per-port limits (kMaxAllocatedPacketCountPerPort, the
    /// kernel.port.max-observers default).
    static let maxUserPackets = 4096
    static let maxObservers = 50_000

    static func queue(_ table: borrowing HandleTable, _ handle: UInt32, _ packet: PortPacket) throws(Status) {
        let ref = try table.get(handle, type: .port, rights: .write)
        let port = PortPointer(object: ref.object)
        var user = packet
        user.type = PortPacket.user
        let record = try QueuedPacketPointer.allocate(user)
        let full = port.pointee.packetsLock.withLock { () -> Bool in
            guard port.pointee.userQueued <= maxUserPackets else { return true }
            port.pointee.userQueued += 1
            return false
        }
        guard !full else {
            record.free()
            // The caller sees the exception; unhandled, it is killed.
            Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_PORT_TOO_MANY_PACKETS))
            throw .shouldWait
        }
        enqueue(port, record)
    }

    /// A binding to `port` would be its `maxObservers`th or more.
    static func overObserverLimit(_ port: ObjectPointer) -> Bool {
        let p = PortPointer(object: port)
        return p.pointee.packetsLock.withLock { p.pointee.watched.count >= maxObservers }
    }

    /// port_wait: the next packet, waiting until `deadline` (timedOut), or
    /// up to `leeway` after it (principle 10).
    static func wait(_ table: borrowing HandleTable, _ handle: UInt32, deadline: UInt64,
                     leeway: UInt64 = 0) throws(Status) -> PortPacket {
        let ref = try table.get(handle, type: .port, rights: .read)
        let port = PortPointer(object: ref.object)
        guard !port.pointee.hasRing else { throw .invalidArgs }  // its packets are the ring's (D44)
        var popped: (PortPacket, QueuedPacketPointer?)? = nil
        Scheduler.locked {
            while true {
                if let next = pop(port) {
                    popped = next
                    return
                }
                let result = Scheduler.block(on: port.pointee.waiters, deadline: deadline, leeway: leeway,
                                             interruptible: true)
                if result == .interrupted || (result == .timedOut && port.pointee.queued == 0) { return }
            }
        }
        guard let (packet, record) = popped else { throw .timedOut }
        if let record { release(record) }
        return packet
    }

    /// port_wait on a ring port (D44, count 0): delivers what is queued,
    /// then waits until the ring isn't empty, until `deadline` (timedOut)
    /// give or take `leeway`. BAD_STATE once the reader has broken the
    /// ring (its cursor ran past the kernel's); INVALID_ARGS for a port
    /// with no ring.
    static func waitRing(_ table: borrowing HandleTable, _ handle: UInt32, deadline: UInt64,
                         leeway: UInt64 = 0) throws(Status) {
        let ref = try table.get(handle, type: .port, rights: .read)
        let port = PortPointer(object: ref.object)
        guard port.pointee.hasRing else { throw .invalidArgs }
        var timedOut = false
        while true {
            deliver(port)
            var outcome = RingWait.again
            Scheduler.locked {
                let state = port.pointee.packetsLock.withLock { () -> RingWait in
                    let space = port.pointee.ring!.space()
                    if port.pointee.ring!.isBroken() { return .broken }
                    if space < UInt64(ringSlots) { return .ready }
                    // Queued, and the ring has room: deliver it, outside
                    // the scheduler lock.
                    return port.pointee.queued > 0 ? .again : .empty
                }
                guard state == .empty else {
                    outcome = state
                    return
                }
                if timedOut {
                    outcome = .timedOut
                    return
                }
                let result = Scheduler.block(on: port.pointee.waiters, deadline: deadline, leeway: leeway,
                                             interruptible: true)
                if result == .interrupted {
                    outcome = .timedOut
                } else if result == .timedOut {
                    timedOut = true
                }
            }
            switch outcome {
            case .ready: return
            case .broken: throw .badState
            case .timedOut: throw .timedOut
            default: continue
            }
        }
    }

    private enum RingWait { case again, empty, ready, broken, timedOut }

    /// port_wait's packets after its first (D40): the next one, without
    /// waiting; nil if the port is empty.
    static func poll(_ table: borrowing HandleTable, _ handle: UInt32) throws(Status) -> PortPacket? {
        let ref = try table.get(handle, type: .port, rights: .read)
        guard let (packet, record) = pop(PortPointer(object: ref.object)) else { return nil }
        if let record { release(record) }
        return packet
    }

    /// port_cancel: drops the bindings `handle` made to this port under
    /// `key` (ONCE, PERSISTENT, an interrupt's), and their packets still
    /// queued. NOT_FOUND if there were none, as with source 0.
    static func cancel(_ table: borrowing HandleTable, port portHandle: UInt32, source handle: UInt32,
                       key: UInt64) throws(Status) {
        let portRef = try table.get(portHandle, type: .port, rights: .write)
        let source = try table.get(handle, rights: .wait)
        let port = PortPointer(object: portRef.object)
        var found = false
        if source.type == .interrupt { found = InterruptObjects.cancel(source.object, port: port.object, key: key) }
        if source.type == .memoryAccount {  // D31: the root account outlives every binder
            found = MemoryAccountObjectPointer(object: source.object).pointee.account
                .cancelPressure(port: port.object.address, key: key)
        }
        source.object.header.lock.withLock {
            var previous: ObserverPointer? = nil
            var cursor = source.object.header.observers
            while let observer = cursor {
                cursor = observer.pointee.next
                if case .port(let p, let k, let packet, _) = observer.pointee.kind, p == port.object.address, k == key,
                   observer.pointee.table == table.address, observer.pointee.handle == handle {
                    if let previous { previous.pointee.next = observer.pointee.next } else { source.object.header.observers = observer.pointee.next }
                    untrack(p, source.object)
                    QueuedPacketPointer(address: packet).free()
                    port.object.release()  // the observer's reference
                    unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                    found = true
                } else if case .source(let p, let k, let packets, _) = observer.pointee.kind, p == port.object.address,
                          k == key, observer.pointee.table == table.address, observer.pointee.handle == handle {
                    if let previous { previous.pointee.next = observer.pointee.next } else { source.object.header.observers = observer.pointee.next }
                    untrack(p, source.object)
                    PacketSourcePointer(address: packets).retire()
                    unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                    found = true
                } else {
                    previous = observer
                }
            }
        }
        // Packets already queued from that handle with that key.
        var removed = UniqueArray<QueuedPacketPointer>()
        port.pointee.packetsLock.withLock {
            var previous: UInt64 = 0
            var cursor = port.pointee.head
            while cursor != 0 {
                let record = QueuedPacketPointer(address: cursor)
                cursor = record.pointee.next
                if record.pointee.packet.key == key, record.pointee.originTable == table.address,
                   record.pointee.originHandle == handle {
                    if previous != 0 { QueuedPacketPointer(address: previous).pointee.next = record.pointee.next } else { port.pointee.head = record.pointee.next }
                    if port.pointee.tail == record.address { port.pointee.tail = previous }
                    port.pointee.queued -= 1
                    removed.append(record)
                } else {
                    previous = record.address
                }
            }
        }
        if removed.count > 0 { found = true }
        while let record = removed.popLast() { release(record) }
        guard found else { throw .notFound }
    }

    /// An async wait on `object` to `port` was added / went. Object lock held.
    static func track(_ port: UInt64, _ object: ObjectPointer) {
        let p = PortPointer(object: ObjectPointer(address: port))
        p.pointee.packetsLock.withLock { p.pointee.watched.append(object.address) }
    }

    static func untrack(_ port: UInt64, _ object: ObjectPointer) {
        let p = PortPointer(object: ObjectPointer(address: port))
        p.pointee.packetsLock.withLock {
            for i in 0..<p.pointee.watched.count where p.pointee.watched[i] == object.address {
                _ = p.pointee.watched.remove(at: i)
                return
            }
        }
    }

    /// port_cancel with source 0 (port_cancel_key until D32): every async
    /// wait to this port with `key`, whatever its source, and every queued
    /// packet with it (user packets too; not kernel sources' or
    /// interrupts'). NOT_FOUND if none.
    static func cancelKey(_ table: borrowing HandleTable, port portHandle: UInt32, key: UInt64) throws(Status) {
        let portRef = try table.get(portHandle, type: .port, rights: .write)
        let port = PortPointer(object: portRef.object)
        var objects = UniqueArray<UInt64>()
        port.pointee.packetsLock.withLock {
            for i in 0..<port.pointee.watched.count {
                let address = port.pointee.watched[i]
                var seen = false
                for j in 0..<objects.count where objects[j] == address { seen = true }
                if !seen, ObjectPointer(address: address).tryRetain() { objects.append(address) }
            }
        }
        var found = false
        for i in 0..<objects.count {
            let source = ObjectPointer(address: objects[i])
            source.header.lock.withLock {
                var previous: ObserverPointer? = nil
                var cursor = source.header.observers
                while let observer = cursor {
                    cursor = observer.pointee.next
                    if case .port(let p, let k, let packet, _) = observer.pointee.kind, p == port.object.address, k == key {
                        if let previous { previous.pointee.next = observer.pointee.next } else { source.header.observers = observer.pointee.next }
                        untrack(p, source)
                        QueuedPacketPointer(address: packet).free()
                        port.object.release()  // the observer's reference
                        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                        found = true
                    } else if case .source(let p, let k, let packets, _) = observer.pointee.kind,
                              p == port.object.address, k == key {
                        if let previous { previous.pointee.next = observer.pointee.next } else { source.header.observers = observer.pointee.next }
                        untrack(p, source)
                        PacketSourcePointer(address: packets).retire()
                        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                        found = true
                    } else {
                        previous = observer
                    }
                }
            }
            source.release()
        }
        var removed = UniqueArray<QueuedPacketPointer>()
        port.pointee.packetsLock.withLock {
            var previous: UInt64 = 0
            var cursor = port.pointee.head
            while cursor != 0 {
                let record = QueuedPacketPointer(address: cursor)
                cursor = record.pointee.next
                if record.pointee.packet.key == key, record.pointee.source == 0 {
                    if previous != 0 { QueuedPacketPointer(address: previous).pointee.next = record.pointee.next } else { port.pointee.head = record.pointee.next }
                    if port.pointee.tail == record.address { port.pointee.tail = previous }
                    port.pointee.queued -= 1
                    if record.isUserPacket { port.pointee.userQueued -= 1 }
                    removed.append(record)
                } else {
                    previous = record.address
                }
            }
        }
        if removed.count > 0 { found = true }
        while let record = removed.popLast() { release(record) }
        guard found else { throw .notFound }
    }

    static var queuedCount: (borrowing ObjectRef) -> Int {
        { ref in PortPointer(object: ref.object).pointee.packetsLock.withLock { PortPointer(object: ref.object).pointee.queued } }
    }
}

// MARK: Kernel packet sources (ext 3, ext 6)

/// A kernel event that reports to a port (budget overruns, memory
/// pressure): it owns one packet, so firing never allocates and may happen
/// with the scheduler lock held. While its packet is still queued, further
/// events only raise the packet's count.
struct PacketSource: ~Copyable {
    let port: UInt64
    let record: QueuedPacketPointer
    /// The payload word that counts events since the packet was last read:
    /// 2 for kernel events, 1 for a persistent signal binding (a signal
    /// packet's layout).
    let countIndex: Int
    var queued = false
    /// Its owner is gone; it goes when its queued packet is read.
    var retired = false
    let lock = SpinLock()
}

@safe struct PacketSourcePointer {
    let address: UInt64

    var pointee: PacketSource {
        unsafeAddress { unsafe UnsafePointer<PacketSource>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PacketSource>(bitPattern: UInt(address))! }
    }

    /// A source reporting to `port` with `key` and packet `type`; holds a
    /// reference to the port.
    /// `table` and `handle`: what it was bound through (port_cancel's match).
    static func make(port: borrowing ObjectRef, key: UInt64, type: UInt32, countIndex: Int = 2,
                     table: UInt64 = 0, handle: UInt32 = 0) throws(Status) -> PacketSourcePointer {
        guard port.type == .port else { throw .wrongType }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PacketSource>.size) else { throw .noMemory }
        let address = UInt64(UInt(bitPattern: raw))
        let record = try QueuedPacketPointer.allocate(PortPacket(key: key, type: type), source: address,
                                                      table: table, handle: handle)
        port.object.retain()
        unsafe raw.bindMemory(to: PacketSource.self, capacity: 1)
            .initialize(to: PacketSource(port: port.object.address, record: record, countIndex: countIndex))
        return PacketSourcePointer(address: address)
    }

    /// Reports an event (value in payload[1]; `word0` and `word3`, if
    /// given, in payload[0] and [3]). Any context.
    func fire(value: UInt64, word0: UInt64? = nil, word3: UInt64? = nil, schedulerLocked: Bool = false,
              wake: Scheduler.Wake = .init()) {
        let queue = pointee.lock.withLock { () -> Bool in
            if let word0 { pointee.record.pointee.packet.payload[0] = word0 }
            if let word3 { pointee.record.pointee.packet.payload[3] = word3 }
            pointee.record.pointee.packet.payload[1] = value
            return countAndQueueLocked()
        }
        if queue { enqueue(schedulerLocked: schedulerLocked, wake: wake) }
    }

    /// Reports a persistent signal binding's event, in a signal packet's
    /// layout: trigger | observed << 32, the count, and the time (0 unless
    /// asked for). Any context.
    func fireSignal(trigger: UInt32, observed: UInt32, timestamp: UInt64, wake: Scheduler.Wake = .init()) {
        let queue = pointee.lock.withLock { () -> Bool in
            pointee.record.pointee.packet.payload[0] = UInt64(observed) << 32 | UInt64(trigger)
            pointee.record.pointee.packet.payload[2] = timestamp
            return countAndQueueLocked()
        }
        if queue { enqueue(schedulerLocked: false, wake: wake) }
    }

    /// Counts the event; true if the packet must be queued (it wasn't).
    private func countAndQueueLocked() -> Bool {
        pointee.record.pointee.packet.payload[pointee.countIndex] += 1
        if pointee.queued { return false }
        pointee.queued = true
        return true
    }

    private func enqueue(schedulerLocked: Bool, wake: Scheduler.Wake) {
        Ports.enqueue(PortPointer(object: ObjectPointer(address: pointee.port)), pointee.record,
                      schedulerLocked: schedulerLocked, wake: wake)
    }

    /// Its packet was read: the next event queues it again, from count 0
    /// (or, retired, it goes now).
    func dequeued() {
        let gone = pointee.lock.withLock { () -> Bool in
            pointee.queued = false
            pointee.record.pointee.packet.payload[pointee.countIndex] = 0
            return pointee.retired
        }
        if gone { free() }
    }

    /// The owner (a context, an account) no longer reports: freed now, or
    /// once its queued packet is read.
    /// Its owner is going. A packet still queued is taken back (nobody may
    /// ever read it, and it holds the port); one a reader has already
    /// taken is freed when handed back (`dequeued`).
    func retire() {
        let now = pointee.lock.withLock { () -> Bool in
            pointee.retired = true
            if pointee.queued,
               Ports.unqueue(PortPointer(object: ObjectPointer(address: pointee.port)), pointee.record) {
                pointee.queued = false
            }
            return !pointee.queued
        }
        if now { free() }
    }

    private func free() {
        let port = ObjectPointer(address: pointee.port)
        pointee.record.free()
        let raw = unsafe UnsafeMutablePointer<PacketSource>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
        port.release()
    }
}

extension Ring {
    /// `broken` through a port's optional ring: a read through `!`
    /// would consume it, a mutating call doesn't.
    fileprivate mutating func isBroken() -> Bool { broken }
}
