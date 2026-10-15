import CKernel

/// Counter syscalls (K10a; numbers in user/include/croi/syscall.h, values
/// in counter.h): Zircon's counter_create, add and read with its rights.
/// counter_write and counter_wait went in V1 (D25): an add of the
/// difference, and object_bind VALUE or CHANGE (Bind.swift). Display
/// timelines (170-173) went in V1 too (D27): a counter.
extension Syscalls {
    static func counterCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                            _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 160:  // counter_create(options, out)
            guard a[0] == 0 else { throw .invalidArgs }
            try check(a[1], MemoryLayout<UInt32>.size)
            try addAndPut(try Counters.create(), rights: CounterObject.defaultRights, a[1], table)
        case 161:  // counter_add(counter, amount): READ and WRITE (the result reveals the value)
            try Counters.add(try table.get(handle, type: .counter, rights: .read | .write).object,
                             Int64(bitPattern: a[1]))
        case 162:  // counter_read(counter, value out)
            guard a[1] != 0 else { throw .invalidArgs }
            try check(a[1], MemoryLayout<Int64>.size)
            try put(Counters.read(try table.get(handle, type: .counter, rights: .read).object), a[1])
        default:
            throw .notSupported
        }
    }
}
