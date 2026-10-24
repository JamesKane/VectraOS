import CKernel
import Fmt

#if arch(arm64)
/// The IORT's reserved memory (RMRs) on a real SMMUv3, the first the IORT
/// names (QEMU's has no RMR, so a stream is given a stand-in): claimed, a
/// stream with reserved memory has it identity mapped in its domain;
/// released, it goes back to bypass, which keeps that memory reachable,
/// where one without aborts. Only stream entries are written: requester id
/// 0xF8 (00:1f.0) has no device on QEMU or the CIX Sky1. The unit is
/// unbound after, for devmgr's iommu_create.
enum SmmuV3SelfTest {
    static func run(_ console: Uart) {
        guard Iort.smmuCount > 0 else { return }
        let rid: UInt16 = 0xF8
        guard let sid = Iort.streamId(rid, smmu: 0) else { return }
        let address: UInt64
        do throws(Status) {
            address = try SmmuV3.bindUnit(index: 0, base: Iort.smmus[0].registerBase)
        } catch {
            panic("smmuv3 self-test: the unit")
        }
        let unit = SmmuUnitPointer(address: address)
        func config() -> UInt64 { (unsafe unit.entry(sid).pointee >> 1) & 7 }

        // Without reserved memory: released to abort.
        guard !Iort.hasReserved(smmu: 0, stream: sid), let plain = try? SmmuV3.attach(unit, requesterId: rid) else {
            panic("smmuv3 self-test: claiming a stream")
        }
        SmmuV3.detach(plain)
        guard config() == 0 else { panic("smmuv3 self-test: released without an RMR, not aborted") }

        // A stand-in RMR, a page of ours, for that stream.
        guard let page = pmm.allocatePage(.alloc),
              Iort.rmrRangeCount < Iort.rmrRanges.count, Iort.rmrStreamCount < Iort.rmrStreams.count else {
            panic("smmuv3 self-test: no room for a stand-in RMR")
        }
        Iort.rmrRanges[Iort.rmrRangeCount] = (base: page, size: KernelLayout.pageSize)
        Iort.rmrStreams[Iort.rmrStreamCount] = Iort.RmrStreams(smmu: 0, firstStream: sid, lastStream: sid,
                                                               first: Iort.rmrRangeCount, count: 1)
        Iort.rmrRangeCount += 1
        Iort.rmrStreamCount += 1
        defer {
            Iort.rmrRangeCount -= 1
            Iort.rmrStreamCount -= 1
            pmm.free(page)
            SmmuV3.unbind(address)
        }
        guard let reserved = try? SmmuV3.attach(unit, requesterId: rid) else {
            panic("smmuv3 self-test: claiming a stream with an RMR")
        }
        var mapped = false
        for i in 0..<reserved.pointee.used.count where reserved.pointee.used[i].base == page { mapped = true }
        guard mapped else { panic("smmuv3 self-test: an RMR not identity mapped when claimed") }
        SmmuV3.detach(reserved)
        guard config() == 0b100 else { panic("smmuv3 self-test: released with an RMR, not back to bypass") }
        console.write("  smmuv3: an RMR's memory identity mapped when its stream is claimed, bypass when ")
        console.write("released (abort without one)\n")
    }
}
#endif
