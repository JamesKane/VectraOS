import CKernel

/// object_bind (V1, docs/syscall-audit.md): the one way an event source
/// reports to a port. It replaced object_wait_async, interrupt_bind,
/// counter_wait_async, thread_bind_overrun_port and
/// account_bind_pressure_port, and takes a batch (principle 12): a
/// dispatcher arms every channel, a driver its IRQs and doorbells, in one
/// call.
///
/// Each item (croi_bind_item_t, port.h) names a source, a kind and a key:
/// - SIGNALS: ONCE (Zircon's wait_async) or PERSISTENT (a packet at every
///   event that leaves a trigger signal asserted, coalesced while queued;
///   the reader drains until the object would block, as with EPOLLET).
/// - VALUE: ONCE, a counter reaching a value (a fence).
/// - CHANGE: PERSISTENT, every add or write of a counter (a doorbell).
/// - INTERRUPT, OVERRUN, PRESSURE: PERSISTENT, the kernel events of an
///   interrupt, a thread's or interrupt's budget, a memory account.
/// port_cancel(port, source, key) undoes any of them, as does closing the
/// handle a SIGNALS, VALUE or CHANGE binding was made through. OVERRUN and
/// PRESSURE last until their object goes or is bound again.
enum Bind {
    static var maxItems: UInt64 { UInt64(CROI_BIND_MAX_ITEMS) }
    static var itemSize: UInt64 { 32 }

    /// Binds `count` items at `items` to `port`, in order, stopping at the
    /// first failure. Each processed item's status is written back; returns
    /// how many succeeded. A bad port, pointer or count fails the whole
    /// call before any item is bound.
    static func call(_ table: borrowing HandleTable, port portHandle: UInt32, items: UInt64,
                     count: UInt64) throws(Status) -> Int64 {
        guard count > 0, count <= maxItems else { throw .invalidArgs }
        let port = try table.get(portHandle, type: .port, rights: .write)
        try Syscalls.check(items, Int(count * itemSize))
        for i in 0..<count {
            let address = items + i * itemSize
            var raw = InlineArray<4, UInt64>(repeating: 0)  // handle | options << 32, key, trigger, status
            var span = raw.mutableSpan
            let copied = span.withUnsafeMutableBufferPointer { unsafe UserCopy.from($0.baseAddress!, address, itemSize) }
            guard copied == 0 else { throw .invalidArgs }
            var status: Int32 = 0
            do throws(Status) {
                guard raw[3] >> 32 == 0 else { throw .invalidArgs }  // reserved
                try one(table, port, handle: UInt32(truncatingIfNeeded: raw[0]),
                        options: UInt32(truncatingIfNeeded: raw[0] >> 32), key: raw[1], trigger: raw[2])
            } catch {
                status = error.rawValue
            }
            try Syscalls.put(status, address + 24)
            if status != 0 { return Int64(i) }
        }
        return Int64(count)
    }

    private static func one(_ table: borrowing HandleTable, _ port: borrowing ObjectRef, handle: UInt32,
                            options: UInt32, key: UInt64, trigger: UInt64) throws(Status) {
        let kind = options & UInt32(CROI_BIND_KIND_MASK)
        let persistent = options & UInt32(CROI_BIND_PERSISTENT) != 0
        let flags = options & ~UInt32(CROI_BIND_KIND_MASK | CROI_BIND_PERSISTENT)
        // The SIGNALS flags, as Observers spells them.
        var signalOptions: UInt32 = 0
        if flags & UInt32(CROI_BIND_EDGE) != 0 { signalOptions |= Observers.edge }
        if flags & UInt32(CROI_BIND_TIMESTAMP) != 0 { signalOptions |= Observers.timestamp }
        guard flags & ~UInt32(CROI_BIND_EDGE | CROI_BIND_TIMESTAMP) == 0 else { throw .invalidArgs }
        switch kind {
        case UInt32(CROI_BIND_SIGNALS):
            guard trigger <= UInt64(UInt32.max) else { throw .invalidArgs }
            if persistent {
                try Observers.bindPersistent(table, handle, port: port, key: key, signals: UInt32(trigger),
                                             onChange: false, options: signalOptions)
            } else {
                try Observers.waitAsync(table, handle, port: port, key: key, signals: UInt32(trigger),
                                        options: signalOptions)
            }
            return
        case UInt32(CROI_BIND_VALUE):
            guard !persistent, flags == 0 else { throw .invalidArgs }
            try Counters.waitAsync(table, handle, port: port, key: key, target: Int64(bitPattern: trigger))
            return
        default:
            break
        }
        // The rest are kernel events: persistent by nature.
        guard persistent, flags == 0, trigger == 0 else { throw .invalidArgs }
        switch kind {
        case UInt32(CROI_BIND_CHANGE):
            try Observers.bindPersistent(table, handle, port: port, key: key, signals: 0, onChange: true, options: 0)
        case UInt32(CROI_BIND_INTERRUPT):
            let interrupt = try table.get(handle, type: .interrupt, rights: .read)
            guard PortPointer(object: port.object).pointee.bindToInterrupt else { throw .wrongType }
            try InterruptObjects.bind(interrupt.object, port: port.object, key: key)
        case UInt32(CROI_BIND_OVERRUN):
            try bindOverrun(table, handle, port: port, key: key)
        case UInt32(CROI_BIND_PRESSURE):
            let ref = try table.get(handle, type: .memoryAccount, rights: .write)
            let account = MemoryAccountObjectPointer(object: ref.object).pointee.account
            let source = try PacketSourcePointer.make(port: port, key: key, type: PortPacket.memoryPressure)
            let old = account.pointee.lock.withLock { () -> UInt64 in
                let old = account.pointee.pressureSource
                account.pointee.pressureSource = source.address
                return old
            }
            if old != 0 { PacketSourcePointer(address: old).retire() }
        default:
            throw .invalidArgs
        }
    }

    /// OVERRUN (K10d; interrupts K14e): budget overrun packets from a
    /// thread's or an interrupt's deadline profile.
    private static func bindOverrun(_ table: borrowing HandleTable, _ handle: UInt32, port: borrowing ObjectRef,
                                    key: UInt64) throws(Status) {
        if try table.get(handle).type == .interrupt {
            let interrupt = try table.get(handle, rights: .write)
            let source = try PacketSourcePointer.make(port: port, key: key, type: PortPacket.budgetOverrun)
            guard let old = InterruptObjects.bindOverrunSource(interrupt.object, source.address) else {
                source.retire()
                throw .badState
            }
            if old != 0 { PacketSourcePointer(address: old).retire() }
            return
        }
        let thread = try table.get(handle, type: .thread, rights: .manageThread)
        guard let target = Processes.pinnedThread(thread.object) else { throw .badState }
        defer { Scheduler.unpin(target) }
        let source = try PacketSourcePointer.make(port: port, key: key, type: PortPacket.budgetOverrun)
        guard let old = Scheduler.bindOverrunSource(target, source.address) else {
            source.retire()
            throw .badState
        }
        if old != 0 { PacketSourcePointer(address: old).retire() }
    }
}
