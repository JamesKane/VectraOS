import CKernel

/// Supply syscalls (D169; numbers in user/include/croi/syscall.h, values and
/// semantics in supply.h): supply_create, supply_bind and supply_end.
extension Syscalls {
    static func supplyCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                           _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 246:  // supply_create(MMIO resource, out)
            try check(a[1], MemoryLayout<UInt32>.size)
            let resource = try table.get(handle, type: .resource)
            let object = try Supplies.create(resource: resource.object)
            try addAndPut(object, rights: SupplyObject.defaultRights, a[1], table)
        case 247:  // supply_bind(supply, object): WRITE on both
            let supply = try table.get(handle, type: .supply, rights: .write)
            let object = try table.get(UInt32(truncatingIfNeeded: a[1]), rights: .write)
            try Supplies.bind(supply.object, object.object)
        case 248:  // supply_end(supply, deadline): returns when it has ended
            let supply = try table.get(handle, type: .supply, rights: .write)
            try Supplies.end(supply.object, deadline: a[1])
        default:
            throw .notSupported
        }
    }
}
