import CKernel
import Synchronization

/// One registered wait on an object (Zircon's SignalObserver): a thread in
/// `counter_wait`, or an object_bind binding (a port packet). Heap records,
/// linked from the object's header, guarded by the object's lock. V1 cut
/// object_wait_one and wait_many (D23): ports are the one wait.
struct Observer {
    enum Kind {
        /// A waiting thread: its WaitState, and its item index.
        case wait(state: UInt64, index: Int)
        /// object_bind ONCE: queue `packet` (allocated up front) to `port`
        /// with `key`, once. Holds a reference to the port.
        case port(port: UInt64, key: UInt64, packet: UInt64, options: UInt32)
        /// object_bind PERSISTENT: `source`'s packet (it holds the port),
        /// queued at every event and coalesced while it waits to be read.
        case source(port: UInt64, key: UInt64, source: UInt64, options: UInt32)
    }

    var next: ObserverPointer?
    let kind: Kind
    /// Signals that satisfy it.
    let trigger: UInt32
    /// The handle it was registered through (cancelled when that closes).
    let table: UInt64
    let handle: UInt32
    /// A counter's value wait (K10a): satisfied when the counter's value
    /// is at least `atValue`, whatever the signals.
    var byValue = false
    var atValue: Int64 = 0
    /// A counter's CHANGE binding: fires at every add or write, whatever
    /// the signals (the ring doorbell).
    var onChange = false
}

@safe struct ObserverPointer: Equatable {
    let address: UInt64

    var pointee: Observer {
        unsafeAddress { unsafe UnsafePointer<Observer>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<Observer>(bitPattern: UInt(address))! }
    }
}

/// A waiting thread's state: where it blocks, and what woke it. Heap, so
/// that it outlives every observer that may touch it (they are removed,
/// under their objects' locks, before it is freed). Scheduler lock.
struct WaitState {
    var queue: QueuePointer
    var done = false
    var canceled = false
    var firedIndex = -1
}

@safe struct WaitStatePointer {
    let address: UInt64

    var pointee: WaitState {
        unsafeAddress { unsafe UnsafePointer<WaitState>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<WaitState>(bitPattern: UInt(address))! }
    }

    static func allocate() throws(Status) -> WaitStatePointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<WaitState>.size) else { throw .noMemory }
        unsafe raw.bindMemory(to: WaitState.self, capacity: 1).initialize(to: WaitState(queue: QueuePointer.allocate()))
        return WaitStatePointer(address: UInt64(UInt(bitPattern: raw)))
    }

    /// The running thread's own wait state, reset for a new wait: kept on
    /// the thread, so waiting allocates nothing after the first time.
    static func forCurrentThread() throws(Status) -> WaitStatePointer {
        let thread = Scheduler.current
        if thread.pointee.waitState == 0 { thread.pointee.waitState = try allocate().address }
        let state = WaitStatePointer(address: thread.pointee.waitState)
        Scheduler.locked {
            state.pointee.done = false
            state.pointee.canceled = false
            state.pointee.firedIndex = -1
        }
        return state
    }

    func free() {
        pointee.queue.deallocate()
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(address))!)
    }

    /// Marks the wait finished (by `index`, or canceled) and wakes the
    /// thread. Any context with the object lock held.
    /// `lending`: the waking object's profile (K10c, ext 5), lent to the
    /// woken thread until it next blocks.
    func finish(index: Int, canceled: Bool, lending: Profile? = nil) {
        Scheduler.locked {
            guard !pointee.done else { return }
            pointee.done = true
            pointee.canceled = canceled
            pointee.firedIndex = index
            Scheduler.wakeAll(pointee.queue, lending: lending)
        }
    }
}

enum Observers {
    static var edge: UInt32 { 1 << 1 }       // ZX_WAIT_ASYNC_EDGE
    static var timestamp: UInt32 { 1 << 0 }  // ZX_WAIT_ASYNC_TIMESTAMP

    /// Runs every observer `object`'s current signals satisfy; port
    /// observers fire once and go, persistent ones fire and stay. `changed`:
    /// a counter's value was set (CHANGE bindings fire). Object lock held.
    static func notify(_ object: ObjectPointer, changed: Bool = false) {
        let signals = object.header.signals
        let type = object.header.type
        let value = type == .counter || type == .timeline ? Counters.valueLocked(object) : 0
        var previous: ObserverPointer? = nil
        var cursor = object.header.observers
        while let observer = cursor {
            cursor = observer.pointee.next
            let satisfied = observer.pointee.byValue ? value >= observer.pointee.atValue
                                                     : observer.pointee.trigger & signals != 0
            if case .source(_, _, let source, let options) = observer.pointee.kind {
                previous = observer
                let packets = PacketSourcePointer(address: source)
                if observer.pointee.onChange {
                    if changed { packets.fire(value: UInt64(bitPattern: value), word3: Clock.now()) }
                } else if satisfied {
                    packets.fireSignal(trigger: observer.pointee.trigger, observed: signals,
                                       timestamp: options & timestamp != 0 ? Clock.now() : 0)
                }
                continue
            }
            guard satisfied else {
                previous = observer
                continue
            }
            switch observer.pointee.kind {
            case .wait(let state, let index):
                WaitStatePointer(address: state).finish(index: index, canceled: false, lending: lend(of: object))
                previous = observer
            case .port(let port, _, let packet, let options):
                if let previous { previous.pointee.next = observer.pointee.next } else { object.header.observers = observer.pointee.next }
                Ports.untrack(port, object)
                if observer.pointee.byValue {
                    fireValuePort(port, QueuedPacketPointer(address: packet), observer.pointee.atValue, value)
                } else {
                    firePort(port, QueuedPacketPointer(address: packet), observer.pointee.trigger, signals, options)
                }
                unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
            case .source:
                break  // handled above
            }
        }
    }

    private static func firePort(_ port: UInt64, _ record: QueuedPacketPointer, _ trigger: UInt32,
                                 _ observed: UInt32, _ options: UInt32) {
        record.pointee.packet.payload[0] = UInt64(observed) << 32 | UInt64(trigger)
        record.pointee.packet.payload[1] = 1  // count
        if options & timestamp != 0 { record.pointee.packet.payload[2] = Clock.now() }
        let pointer = ObjectPointer(address: port)
        Ports.enqueue(PortPointer(object: pointer), record)
        pointer.release()  // the observer's reference; the queue keeps the port alive
    }

    /// The profile an object lends the threads it wakes directly (K10c:
    /// counters and timelines that carry one). Object lock held.
    static func lend(of object: ObjectPointer) -> Profile? {
        switch object.header.type {
        case .counter: CounterPointer(object: object).pointee.lend
        case .timeline: TimelinePointer(object: object).pointee.lend
        default: nil
        }
    }

    /// A counter value wait's packet: what was waited for, what the counter
    /// reached, and when.
    static func fireValuePort(_ port: UInt64, _ record: QueuedPacketPointer, _ target: Int64, _ value: Int64) {
        record.pointee.packet.payload[0] = UInt64(bitPattern: target)
        record.pointee.packet.payload[1] = UInt64(bitPattern: value)
        record.pointee.packet.payload[2] = Clock.now()
        let pointer = ObjectPointer(address: port)
        Ports.enqueue(PortPointer(object: pointer), record)
        pointer.release()  // the observer's reference; the queue keeps the port alive
    }

    /// object_bind SIGNALS ONCE: a one-shot packet to `port` with `key`
    /// when `handle`'s object has any of `signals` (now, unless `edge`).
    static func waitAsync(_ table: borrowing HandleTable, _ handle: UInt32, port: borrowing ObjectRef, key: UInt64,
                          signals: UInt32, options: UInt32) throws(Status) {
        guard options & ~(edge | timestamp) == 0 else { throw .invalidArgs }
        let object = try table.get(handle, rights: .wait)
        // Zircon raises at its observer limit and still registers (review fix).
        if Ports.overObserverLimit(port.object) {
            Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_PORT_TOO_MANY_OBSERVERS))
        }
        let record = try QueuedPacketPointer.allocate(PortPacket(key: key, type: PortPacket.signalOne),
                                                      table: table.address, handle: handle)
        port.object.retain()  // the observer's
        do throws(Status) {
            try object.object.header.lock.withLock { () throws(Status) in
                if options & edge == 0, object.object.header.signals & signals != 0 {
                    firePort(port.object.address, record, signals, object.object.header.signals, options)
                    return
                }
                _ = try add(object.object, Observer(kind: .port(port: port.object.address, key: key,
                                                               packet: record.address, options: options),
                                                   trigger: signals, table: table.address, handle: handle))
            }
        } catch {
            record.free()
            port.object.release()
            throw error
        }
    }

    /// Adds an observer. Object lock held.
    static func add(_ object: ObjectPointer, _ observer: Observer) throws(Status) -> ObserverPointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<Observer>.size) else { throw .noMemory }
        var record = observer
        record.next = object.header.observers
        unsafe raw.bindMemory(to: Observer.self, capacity: 1).initialize(to: record)
        let pointer = ObserverPointer(address: UInt64(UInt(bitPattern: raw)))
        object.header.observers = pointer
        if let port = observer.kind.port { Ports.track(port, object) }
        return pointer
    }

    /// Unlinks and frees an observer if it is still there. Object lock held.
    static func remove(_ object: ObjectPointer, _ observer: ObserverPointer) {
        var previous: ObserverPointer? = nil
        var cursor = object.header.observers
        while let current = cursor {
            if current == observer {
                if let previous { previous.pointee.next = current.pointee.next } else { object.header.observers = current.pointee.next }
                if let port = current.pointee.kind.port { Ports.untrack(port, object) }
                if case .source(_, _, let source, _) = current.pointee.kind { PacketSourcePointer(address: source).retire() }
                unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(current.address))!)
                return
            }
            previous = current
            cursor = current.pointee.next
        }
    }

    /// The handle `handle` of `table` closed: its waits are canceled (the
    /// waiting threads remove their own observers; async waits just go).
    static func handleClosed(_ object: ObjectPointer, table: UInt64, handle: UInt32) {
        if object.header.type == .interrupt {
            InterruptObjects.handleClosed(object, table: table, handle: handle)  // an interrupt_wait through it
        } else if object.header.type == .pmt {
            Dma.handleClosed(object)  // its only handle: quarantined if still pinned
        }
        object.header.lock.withLock {
            var previous: ObserverPointer? = nil
            var cursor = object.header.observers
            while let observer = cursor {
                cursor = observer.pointee.next
                guard observer.pointee.table == table, observer.pointee.handle == handle else {
                    previous = observer
                    continue
                }
                switch observer.pointee.kind {
                case .wait(let state, let index):
                    WaitStatePointer(address: state).finish(index: index, canceled: true)
                    previous = observer
                case .port(let port, _, let packet, _):
                    if let previous { previous.pointee.next = observer.pointee.next } else { object.header.observers = observer.pointee.next }
                    Ports.untrack(port, object)
                    QueuedPacketPointer(address: packet).free()
                    ObjectPointer(address: port).release()
                    unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                case .source(let port, _, let source, _):
                    if let previous { previous.pointee.next = observer.pointee.next } else { object.header.observers = observer.pointee.next }
                    Ports.untrack(port, object)
                    PacketSourcePointer(address: source).retire()
                    unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                }
            }
        }
    }

    /// object_bind SIGNALS PERSISTENT, or a counter's CHANGE: `source`'s
    /// packet to `port` at every event that has any of `signals` (CHANGE:
    /// every add or write), coalesced while queued. SIGNALS also fires now
    /// if the object already has one, unless `edge`.
    static func bindPersistent(_ table: borrowing HandleTable, _ handle: UInt32, port: borrowing ObjectRef,
                               key: UInt64, signals: UInt32, onChange: Bool, options: UInt32) throws(Status) {
        guard options & ~(edge | timestamp) == 0 else { throw .invalidArgs }
        let object = onChange ? try table.get(handle, type: .counter, rights: .wait | .read)
                              : try table.get(handle, rights: .wait)
        if Ports.overObserverLimit(port.object) {
            Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_PORT_TOO_MANY_OBSERVERS))
        }
        let type = onChange ? UInt32(CROI_PKT_TYPE_COUNTER_CHANGE) : PortPacket.signalOne
        let source = try PacketSourcePointer.make(port: port, key: key, type: type, countIndex: onChange ? 2 : 1,
                                                  table: table.address, handle: handle)
        do throws(Status) {
            try object.object.header.lock.withLock { () throws(Status) in
                var observer = Observer(kind: .source(port: port.object.address, key: key, source: source.address,
                                                      options: options),
                                        trigger: signals, table: table.address, handle: handle)
                observer.onChange = onChange
                _ = try add(object.object, observer)
                let now = object.object.header.signals
                if !onChange, options & edge == 0, now & signals != 0 {
                    source.fireSignal(trigger: signals, observed: now,
                                      timestamp: options & timestamp != 0 ? Clock.now() : 0)
                }
            }
        } catch {
            source.retire()
            throw error
        }
    }
}

extension Observer.Kind {
    /// The port a port or persistent observer reports to.
    var port: UInt64? {
        switch self {
        case .port(let port, _, _, _), .source(let port, _, _, _): port
        case .wait: nil
        }
    }
}
