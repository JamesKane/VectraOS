import Synchronization
import CKernel

/// Channels and object info from user space (K7b; numbers in
/// user/include/croi/syscall.h, layouts in include/ipc.h). Zircon's calls,
/// except that channel_read and channel_write take arrays of items (D41).
extension Syscalls {
    static func ipcCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 80:  // channel_create(options, out0, out1)
            try Policy.check(UInt32(CROI_POL_NEW_CHANNEL))
            guard a[0] == 0 else { throw .invalidArgs }
            try check(a[1], 4)
            try check(a[2], 4)
            let (first, second) = try Channels.create()
            let h0: UInt32
            do throws(Status) {
                h0 = try table.add(first, rights: ChannelObject.defaultRights)
            } catch {
                second.release()
                throw error
            }
            let h1 = try table.add(second, rights: ChannelObject.defaultRights)
            try put(h0, a[1])
            try put(h1, a[2])
        case 83:  // channel_call(channel, options, deadline, args, actual_bytes, actual_handles)
            // Unreadable args: the handles to send are unknown, so none
            // are consumed (Zircon's too).
            var args = croi_channel_call_args_t()
            let copied = withUnsafeMutableBytes(of: &args) { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[3], UInt64(raw.count))
            }
            guard copied == 0 else { throw .invalidArgs }
            let channel: ObjectRef
            do throws(Status) {
                guard a[1] == 0 else { throw .invalidArgs }
                try check(a[4], 4)
                try check(a[5], 4)
                if args.rd_num_bytes > 0 { try check(args.rd_bytes, Int(args.rd_num_bytes)) }
                if args.rd_num_handles > 0 { try check(args.rd_handles, Int(args.rd_num_handles) * 4) }
                channel = try table.get(handle, type: .channel, rights: .read | .write)
            } catch {
                discard(table, handles: args.wr_handles, count: UInt64(args.wr_num_handles))
                throw error
            }
            let message = try build(table, channel: channel.object, bytes: args.wr_bytes, count: UInt64(args.wr_num_bytes),
                                    handles: args.wr_handles, handleCount: UInt64(args.wr_num_handles))
            let reply = try Channels.call(channel.object, message, deadline: a[2])
            try put(reply.pointee.bytes, a[4])
            try put(reply.pointee.handles, a[5])
            guard reply.pointee.bytes <= args.rd_num_bytes, reply.pointee.handles <= args.rd_num_handles else {
                reply.free()
                throw .bufferTooSmall
            }
            try deliver(reply, to: table, bytes: args.rd_bytes, handles: args.rd_handles)
        case 86:  // object_get_info(handle, topic, buffer, buffer_size, size_t *actual, size_t *avail)
            if try taskInfo(a, table) { return }  // K13e's topics (InfoTopics.swift)
            if a[1] == UInt64(CROI_INFO_VMAR) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_vmar_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_vmar_t>.size)
                let vmar = try table.get(handle, type: .vmar, rights: .inspect)
                let v = VmarPointer(object: vmar.object).info
                try put(croi_info_vmar_t(base: v.base, len: v.size), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_TASK_STATS) {
                let size = MemoryLayout<croi_info_task_stats_t>.size
                guard a[3] >= UInt64(size) else { throw .bufferTooSmall }
                try check(a[2], size)
                let process = try table.get(handle, type: .process, rights: .inspect)
                let record = ProcessPointer(object: process.object).pointee.aspaceRecord
                let stats: croi_info_task_stats_t
                do throws(VmError) {
                    stats = try UserAspace.withView(record) { (aspace: borrowing UserAspace) throws(VmError) in
                        try aspace.taskStats()
                    }
                } catch {
                    throw .badState  // the process is gone
                }
                try put(stats, a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_KMEM_STATS) {
                let size = MemoryLayout<croi_info_kmem_stats_t>.size
                guard a[3] >= UInt64(size) else { throw .bufferTooSmall }
                try check(a[2], size)
                try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_INFO_BASE))
                try put(KernelMemory.stats(), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_BTI) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_bti_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_bti_t>.size)
                let bti = try table.get(handle, type: .bti, rights: .inspect)
                try put(Dma.info(bti.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_BTI_PROPERTIES) {
                guard a[3] >= UInt64(MemoryLayout<croi_bti_properties_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_bti_properties_t>.size)
                let bti = try table.get(handle, type: .bti, rights: .inspect)
                try put(Dma.properties(bti.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_MSI) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_msi_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_msi_t>.size)
                let msi = try table.get(handle, type: .msi, rights: .inspect)
                try put(Msis.info(msi.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_THREAD_TRACE) {  // K10d
                guard a[3] >= UInt64(MemoryLayout<croi_info_thread_trace_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_thread_trace_t>.size)
                let thread = try table.get(handle, type: .thread, rights: .inspect)
                try put(croi_info_thread_trace_t(trace_id: Processes.traceId(thread.object), reserved: 0), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_VMAR_JIT) {  // K15b
                guard a[3] >= UInt64(MemoryLayout<croi_info_vmar_jit_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_vmar_jit_t>.size)
                let vmar = try table.get(handle, type: .vmar, rights: .inspect)
                let v = VmarPointer(object: vmar.object).info
                let kind = try vmStatus { () throws(VmError) -> (reservation: Bool, jit: Bool, key: UInt8) in
                    try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) -> (reservation: Bool, jit: Bool, key: UInt8) in
                        try aspace.regionKind(v.region)
                    }
                }
                var info = croi_info_vmar_jit_t()
                info.flags = (kind.reservation ? UInt32(CROI_VMAR_JIT_FLAG_RESERVATION) : 0)
                    | (kind.jit ? UInt32(CROI_VMAR_JIT_FLAG_JIT) : 0)
                info.mechanism = !kind.reservation ? UInt32(CROI_JIT_MECHANISM_NONE)
                    : kind.key != 0 ? UInt32(CROI_JIT_MECHANISM_PROTECTION_KEYS) : UInt32(CROI_JIT_MECHANISM_VIEWS)
                info.key = UInt32(kind.key)
                try put(info, a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_MEMORY_ACCOUNT) {  // K15a
                guard a[3] >= UInt64(MemoryLayout<croi_info_memory_account_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_memory_account_t>.size)
                let account = try table.get(handle, type: .memoryAccount, rights: .inspect)
                try put(Accounts.info(account.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_DEBUGLOG) {  // K10d
                guard a[3] >= UInt64(MemoryLayout<croi_info_debuglog_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_debuglog_t>.size)
                _ = try table.get(handle, type: .log)
                try put(DebugLog.progress, a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_RESOURCE) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_resource_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_resource_t>.size)
                let resource = try table.get(handle, type: .resource, rights: .inspect)
                try put(Resources.info(resource.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_HANDLE_COUNT) {  // K13a, Zircon's: INSPECT
                guard a[3] >= UInt64(MemoryLayout<croi_info_handle_count_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_handle_count_t>.size)
                let object = try table.get(handle, rights: .inspect)
                try put(croi_info_handle_count_t(handle_count: object.object.header.handleCount.load(ordering: .relaxed)),
                        a[2])
                return
            }
            guard a[1] == UInt64(CROI_INFO_HANDLE_BASIC) else { throw .notSupported }
            guard a[3] >= UInt64(MemoryLayout<croi_info_handle_basic_t>.size) else { throw .bufferTooSmall }
            try check(a[2], MemoryLayout<croi_info_handle_basic_t>.size)
            var rights = Rights()
            let object = try table.get(handle, have: &rights)
            try put(croi_info_handle_basic_t(koid: object.koid, rights: rights.rawValue, type: object.type.rawValue,
                                             related_koid: Channels.relatedKoid(object.object), reserved: (0, 0)),
                    a[2])
        default:
            throw .notSupported
        }
    }

    /// A message from user memory: `count` bytes at `bytes`, and the
    /// handles listed at `handles` moved out of `table`. As in Zircon, the
    /// listed handles are consumed whether or not this succeeds (or the
    /// write after it: a failed write frees the message, closing them),
    /// unless the list itself can't be read. Each needs TRANSFER and may
    /// not be the channel written to; a repeat finds its handle gone (BAD_
    /// HANDLE). The first error is returned.
    private static func build(_ table: borrowing HandleTable, channel: ObjectPointer, bytes: UInt64, count: UInt64,
                              handles: UInt64, handleCount: UInt64) throws(Status) -> MessagePointer {
        func consume(_ table: borrowing HandleTable) { discard(table, handles: handles, count: handleCount) }
        guard count <= UInt64(CROI_CHANNEL_MAX_BYTES), handleCount <= UInt64(CROI_CHANNEL_MAX_HANDLES) else {
            consume(table)
            throw .outOfRange
        }
        guard let message = MessagePointer.allocate(bytes: UInt32(count), handles: UInt32(handleCount)) else {
            consume(table)
            throw .noMemory
        }
        if count > 0 {
            let copied = unsafe UserCopy.from(UnsafeMutableRawPointer(bitPattern: UInt(message.data))!, bytes, count)
            guard copied == 0 else {
                message.free()
                consume(table)
                throw .invalidArgs
            }
        }
        if handleCount == 0 { return message }  // no 256-byte buffer to clear
        var values = InlineArray<64, UInt32>(repeating: 0)
        if handleCount > 0 {
            var span = values.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, handles, handleCount * 4)
            }
            guard copied == 0 else {
                message.free()
                throw .invalidArgs
            }
        }
        var failure: Status? = nil
        for i in 0..<Int(handleCount) {
            do throws(Status) {
                let (object, rights) = try table.take(values[i])
                guard object.address != channel.address else {
                    object.releaseTaken()
                    throw .notSupported
                }
                guard rights.contains(.transfer) else {
                    object.releaseTaken()
                    throw .accessDenied
                }
                message.setHandle(i, object: object.address, rights: rights)
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure {
            message.free()
            throw failure
        }
        return message
    }

    /// Zircon's remove_user_handles: closes the `count` handles listed at
    /// `handles`, 64 at a time, skipping bad values and stopping only where
    /// the list can't be read.
    private static func discard(_ table: borrowing HandleTable, handles: UInt64, count: UInt64) {
        let count = count & 0xFFFF_FFFF  // a uint32_t in the ABI
        var values = InlineArray<64, UInt32>(repeating: 0)
        var done: UInt64 = 0
        while done < count {
            let chunk = min(count - done, 64)
            var span = values.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, handles &+ done * 4, chunk * 4)
            }
            guard copied == 0 else { return }
            for i in 0..<Int(chunk) { try? table.close(values[i]) }
            done += chunk
        }
    }

    /// channel_write(items, count) (D41): one message to each item's
    /// channel (croi_channel_write_item_t, ipc.h), going on past an item
    /// that fails; each item's handles consumed either way, its status
    /// written back. Returns how many succeeded; a bad pointer or count
    /// fails the call before any item, consuming nothing.
    static func writeChannels(_ table: borrowing HandleTable, items: UInt64, count: UInt64) throws(Status) -> Int64 {
        let itemSize: UInt64 = 40
        guard count > 0, count <= UInt64(CROI_CHANNEL_MAX_ITEMS) else { throw .invalidArgs }
        try check(items, Int(count * itemSize))
        var done: Int64 = 0
        for i in 0..<count {
            let address = items + i * itemSize
            // channel | options << 32, bytes, handles, num_bytes | num_handles << 32, status | reserved << 32
            var raw = InlineArray<5, UInt64>(repeating: 0)
            var span = raw.mutableSpan
            let copied = span.withUnsafeMutableBytes { unsafe UserCopy.from($0.baseAddress!, address, itemSize) }
            guard copied == 0 else { throw .invalidArgs }
            var status: Int32 = 0
            do throws(Status) {
                try writeMessage(table, channel: UInt32(truncatingIfNeeded: raw[0]),
                                 valid: raw[0] >> 32 == 0 && raw[4] >> 32 == 0, bytes: raw[1],
                                 count: raw[3] & 0xffff_ffff, handles: raw[2], handleCount: raw[3] >> 32)
            } catch {
                status = error.rawValue
            }
            try put(status, address + 32)
            if status == 0 { done += 1 }
        }
        return done
    }

    /// One channel_write item: Zircon's channel_write. `valid`: its
    /// options and reserved field are 0.
    private static func writeMessage(_ table: borrowing HandleTable, channel handle: UInt32, valid: Bool,
                                     bytes: UInt64, count: UInt64, handles: UInt64,
                                     handleCount: UInt64) throws(Status) {
        let channel: ObjectRef
        do throws(Status) {
            guard valid else { throw .invalidArgs }
            channel = try table.get(handle, type: .channel, rights: .write)
        } catch {
            discard(table, handles: handles, count: handleCount)
            throw error
        }
        let message = try build(table, channel: channel.object, bytes: bytes, count: count, handles: handles,
                                handleCount: handleCount)
        message.pointee.txid = message.pointee.bytes >= 4
            ? unsafe UnsafePointer<UInt32>(bitPattern: UInt(message.data))!.pointee : 0
        if try Channels.write(channel.object, message) {
            Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_CHANNEL_FULL_WRITE))
        }
    }

    /// channel_read(items, count) (D41): one message from each item's
    /// channel (croi_channel_read_item_t, ipc.h), going on past an item
    /// that fails; each item's actual sizes (on success and
    /// BUFFER_TOO_SMALL) and status written back. Returns how many
    /// succeeded; a bad pointer or count fails the call before any item.
    static func readChannels(_ table: borrowing HandleTable, items: UInt64, count: UInt64) throws(Status) -> Int64 {
        let itemSize: UInt64 = 48
        guard count > 0, count <= UInt64(CROI_CHANNEL_MAX_ITEMS) else { throw .invalidArgs }
        try check(items, Int(count * itemSize))
        var done: Int64 = 0
        for i in 0..<count {
            let address = items + i * itemSize
            // channel | options << 32, bytes, handles, capacities, actuals, status | reserved << 32
            var raw = InlineArray<6, UInt64>(repeating: 0)
            var span = raw.mutableSpan
            let copied = span.withUnsafeMutableBytes { unsafe UserCopy.from($0.baseAddress!, address, itemSize) }
            guard copied == 0 else { throw .invalidArgs }
            var actual: UInt64 = 0
            var status: Int32 = 0
            do throws(Status) {
                guard raw[5] >> 32 == 0 else { throw .invalidArgs }
                try readMessage(table, channel: UInt32(truncatingIfNeeded: raw[0]), options: raw[0] >> 32,
                                bytes: raw[1], handles: raw[2], capacity: raw[3], actual: &actual)
            } catch {
                status = error.rawValue
            }
            try put(actual, address + 32)
            try put(status, address + 40)
            if status == 0 { done += 1 }
        }
        return done
    }

    /// One channel_read item: Zircon's channel_read, the capacities packed
    /// (bytes | handles << 32) and the message's size set in `actual`
    /// (the same way) once known.
    private static func readMessage(_ table: borrowing HandleTable, channel handle: UInt32, options: UInt64,
                                    bytes: UInt64, handles: UInt64, capacity packed: UInt64,
                                    actual: inout UInt64) throws(Status) {
        // Zircon's order: the handle, then the options (MAY_DISCARD).
        let channel = try table.get(handle, type: .channel, rights: .read)
        guard options & ~UInt64(CROI_CHANNEL_READ_MAY_DISCARD) == 0 else { throw .notSupported }
        let capacity = (bytes: UInt32(truncatingIfNeeded: packed), handles: UInt32(truncatingIfNeeded: packed >> 32))
        // The message read is the one whose size was checked (another
        // reader may take it meanwhile: then peek again).
        var taken: MessagePointer? = nil
        while taken == nil {
            let size = try Channels.peek(channel.object)
            actual = UInt64(size.bytes) | UInt64(size.handles) << 32
            guard size.bytes <= capacity.bytes, size.handles <= capacity.handles else {
                if options != 0, let dropped = Channels.discard(channel.object, ifLargerThan: capacity) { dropped.free() }
                throw .bufferTooSmall
            }
            if size.bytes > 0 { try check(bytes, Int(size.bytes)) }
            if size.handles > 0 { try check(handles, Int(size.handles) * 4) }
            taken = try Channels.read(channel.object, ifFits: size)
        }
        try deliver(taken!, to: table, bytes: bytes, handles: handles)
    }

    /// handle_close (handle_close_many until D33, K13e): 64 at a time; 0 (ZX_HANDLE_INVALID) skipped;
    /// a bad value BAD_HANDLE but the rest still closed; an unreadable
    /// chunk stops there.
    static func closeHandles(_ table: borrowing HandleTable, handles: UInt64, count: UInt64) throws(Status) {
        var values = InlineArray<64, UInt32>(repeating: 0)
        var done: UInt64 = 0
        var bad = false
        while done < count {
            let chunk = min(count - done, 64)
            var span = values.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, handles &+ done * 4, chunk * 4)
            }
            guard copied == 0 else { throw .invalidArgs }
            for i in 0..<Int(chunk) where values[i] != 0 {
                do throws(Status) { try table.close(values[i]) } catch { bad = true }
            }
            done += chunk
        }
        if bad { throw .badHandle }
    }

    /// handle_duplicate(items, count) (D39): duplicates, or with CONSUME
    /// replaces (D34), each item's handle (croi_handle_duplicate_item_t,
    /// ipc.h), in order, stopping at the first failure. Each processed
    /// item's status is written back, and its new handle if it has one;
    /// returns how many succeeded. A bad pointer or count fails the whole
    /// call before any item is done, as object_bind's does.
    static func duplicateHandles(_ table: borrowing HandleTable, items: UInt64, count: UInt64) throws(Status) -> Int64 {
        let itemSize: UInt64 = 24
        guard count > 0, count <= UInt64(CROI_HANDLE_DUPLICATE_MAX_ITEMS) else { throw .invalidArgs }
        try Syscalls.check(items, Int(count * itemSize))
        for i in 0..<count {
            let address = items + i * itemSize
            var raw = InlineArray<3, UInt64>(repeating: 0)  // handle | rights << 32, options | out << 32, status
            var span = raw.mutableSpan
            let copied = span.withUnsafeMutableBufferPointer { unsafe UserCopy.from($0.baseAddress!, address, itemSize) }
            guard copied == 0 else { throw .invalidArgs }
            let handle = UInt32(truncatingIfNeeded: raw[0])
            let rights = Rights(rawValue: UInt32(truncatingIfNeeded: raw[0] >> 32))
            let options = UInt32(truncatingIfNeeded: raw[1])
            var status: Int32 = 0
            var added: UInt32 = 0
            do throws(Status) {
                guard raw[2] >> 32 == 0 else { throw .invalidArgs }  // reserved
                if options == UInt32(CROI_HANDLE_DUPLICATE_CONSUME) {
                    added = try table.replace(handle, rights: rights)
                } else {
                    guard options == 0 else { throw .invalidArgs }
                    added = try table.duplicate(handle, rights: rights)
                }
            } catch {
                status = error.rawValue
            }
            do throws(Status) {
                if added != 0 { try Syscalls.put(added, address + 12) }
                try Syscalls.put(status, address + 16)
            } catch {
                if added != 0 { try? table.close(added) }  // nobody could learn its value
                throw error
            }
            if status != 0 { return Int64(i) }
        }
        return Int64(count)
    }

    /// Copies a message out: bytes to `bytes`, its objects into `table`
    /// with their values at `handles`. Frees it.
    private static func deliver(_ message: MessagePointer, to table: borrowing HandleTable, bytes: UInt64,
                                handles: UInt64) throws(Status) {
        defer { message.free() }
        if message.pointee.bytes > 0 {
            let copied = unsafe UserCopy.to(bytes, UnsafeRawPointer(bitPattern: UInt(message.data))!,
                                            UInt64(message.pointee.bytes))
            guard copied == 0 else { throw .invalidArgs }
        }
        for i in 0..<Int(message.pointee.handles) {
            let entry = message.handle(i)
            let value = try table.add(ObjectPointer(address: entry.object), rights: entry.rights)
            ObjectPointer(address: entry.object).header.handleCount.subtract(1, ordering: .relaxed)  // landed
            message.setHandle(i, object: 0, rights: Rights(rawValue: 0))  // the table's now
            try put(value, handles + UInt64(i) * 4)
        }
    }
}
