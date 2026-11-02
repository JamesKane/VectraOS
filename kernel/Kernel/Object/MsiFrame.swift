import _Volatile
import CKernel
import PageTables

/// An MSI frame (D156): vectors a device signals by writing the vector's
/// number to one address, which a block outside the interrupt controller
/// latches and raises on one wired interrupt for them all. DesignWare
/// PCIe's integrated MSI receiver is the one kind: its target address's
/// two registers, then 8 groups of 32 vectors, each group's enable, mask
/// and status registers 12 bytes apart (spacemit-k1 09 §9.7). The
/// kernel takes the wired number (DeviceIrqs.setKernelHandler, as an
/// IOMMU's fault interrupt), and its handler clears each pending status
/// bit and fires the vector's interrupt object. A frame is the kernel's
/// until it restarts: the object (type 64) is how msi_allocate names it,
/// and its last handle closing leaves the frame in place.
struct MsiFrame: ~Copyable {
    /// The kernel's mapping of the frame's first register (shared: the
    /// driver keeps its resource over it).
    let registers: UInt64
    let target: UInt64
    let number: UInt32
    /// The allocations and handlers; held while the wired interrupt fires
    /// objects (lock order: frame -> object, as DeviceIrqs' table lock).
    let lock = SpinLock()
    /// The mask registers, a leaf: masking runs under an object's lock.
    let maskLock = SpinLock()
    /// A bit per vector allocated, a group a word.
    var inUse = InlineArray<8, UInt32>(repeating: 0)
    /// Each vector's interrupt object, 0 for none (`lock`).
    var handlers = InlineArray<256, UInt64>(repeating: 0)

    static var vectors: UInt32 { 256 }
    static var addressLow: UInt64 { 0x0 }
    static var addressHigh: UInt64 { 0x4 }
    static func enable(_ group: Int) -> UInt64 { 0x8 + 12 * UInt64(group) }
    static func mask(_ group: Int) -> UInt64 { 0xC + 12 * UInt64(group) }
    static func status(_ group: Int) -> UInt64 { 0x10 + 12 * UInt64(group) }
    /// The registers' extent from the first.
    static var span: UInt64 { 0x10 + 12 * 7 + 4 }
}

@safe struct MsiFramePointer {
    let address: UInt64

    var pointee: MsiFrame {
        unsafeAddress { unsafe UnsafePointer<MsiFrame>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<MsiFrame>(bitPattern: UInt(address))! }
    }
}

/// The handle's side: which frame.
struct MsiFrameObject: ~Copyable {
    var header = ObjectHeader(type: .msiFrame)
    let frame: UInt64

    static var defaultRights: Rights { .basic }
}

@safe struct MsiFrameObjectPointer {
    let object: ObjectPointer

    var pointee: MsiFrameObject {
        unsafeAddress { unsafe UnsafePointer<MsiFrameObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<MsiFrameObject>(bitPattern: UInt(object.address))! }
    }
}

enum MsiFrames {
    /// msi_frame_create (the caller checked the MSI system resource and
    /// the IRQ resource for `number`): the frame over `vmo` at `offset`,
    /// its target programmed, every vector enabled and masked, and the
    /// wired number taken. NO_RESOURCES: the kernel's wired numbers are
    /// all taken, or `number` isn't one it can take.
    static func create(kind: UInt32, number: UInt32, vmo: VmoPointer, offset: UInt64,
                       target: UInt64) throws(Status) -> ObjectPointer {
        guard kind == UInt32(CROI_MSI_FRAME_DWC) else { throw .invalidArgs }
        guard case .physical(let base) = vmo.pointee.kind, vmo.pointee.cache == .device,
              offset & 3 == 0, !offset.addingReportingOverflow(MsiFrame.span).overflow,
              offset + MsiFrame.span <= vmo.pointee.size else { throw .invalidArgs }
        guard DeviceIrqs.isValid(number) else { throw .noResources }
        let page = KernelLayout.pageSize
        let mapBase = (base + offset) & ~(page - 1)
        let mapSize = (base + offset + MsiFrame.span + page - 1) & ~(page - 1) - mapBase
        let window: UInt64
        do throws(VmError) {
            window = try kernelAspace.mapPhysical(mapBase, size: mapSize,
                                                  MapAttributes(writable: true, cache: .device, global: true),
                                                  shared: true)
        } catch {
            throw .noMemory
        }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<MsiFrame>.size) else {
            try? kernelAspace.free(window)
            throw .noMemory
        }
        let frame = MsiFramePointer(address: UInt64(UInt(bitPattern: raw)))
        unsafe raw.bindMemory(to: MsiFrame.self, capacity: 1).initialize(to: MsiFrame(
            registers: window + (base + offset - mapBase), target: target, number: number))
        let r = frame.pointee.registers
        write32(r + MsiFrame.addressLow, UInt32(truncatingIfNeeded: target))
        write32(r + MsiFrame.addressHigh, UInt32(truncatingIfNeeded: target >> 32))
        for g in 0..<8 {
            write32(r + MsiFrame.mask(g), ~0)
            write32(r + MsiFrame.enable(g), ~0)
            write32(r + MsiFrame.status(g), ~0)
        }
        guard let object = Objects.allocate(MsiFrameObject(frame: frame.address)) else {
            try? kernelAspace.free(window)
            unsafe heap.free(raw)
            throw .noMemory
        }
        // From here the frame is the kernel's for good: a handler that
        // can't be set up may still be in the table, so on failure the
        // frame is left, not freed.
        guard DeviceIrqs.setKernelHandler(number, level: true, service, frame.address) else {
            object.release()
            throw .noResources
        }
        return object
    }

    /// The object went; the frame stays (its wired number can't be given
    /// back).
    static func destroy(_ object: ObjectPointer) {
        Objects.free(object, as: MsiFrameObject.self)
    }

    static func frame(_ object: ObjectPointer) -> UInt64 { MsiFrameObjectPointer(object: object).pointee.frame }

    /// `count` (a power of two up to 32) free vectors of `frame`, aligned
    /// to `count`; the first, or nil.
    static func allocate(_ frame: UInt64, count: UInt32) -> UInt32? {
        let f = MsiFramePointer(address: frame)
        return f.pointee.lock.withLock { () -> UInt32? in
            let mask: UInt32 = count >= 32 ? ~0 : (1 << count) - 1
            var first: UInt32 = 0
            while first + count <= MsiFrame.vectors {
                let g = Int(first / 32), bits = mask << (first % 32)
                if f.pointee.inUse[g] & bits == 0 {
                    f.pointee.inUse[g] |= bits
                    return first
                }
                first += count
            }
            return nil
        }
    }

    static func free(_ frame: UInt64, vector: UInt32, count: UInt32) {
        let f = MsiFramePointer(address: frame)
        f.pointee.lock.withLock {
            let mask: UInt32 = count >= 32 ? ~0 : (1 << count) - 1
            f.pointee.inUse[Int(vector / 32)] &= ~(mask << (vector % 32))
        }
    }

    static func target(_ frame: UInt64) -> UInt64 { MsiFramePointer(address: frame).pointee.target }

    /// Installs `object` for `vector` (0 removes it); once it returns, no
    /// run of the handler is still firing the previous one.
    static func setHandler(_ frame: UInt64, vector: UInt32, _ object: UInt64) {
        let f = MsiFramePointer(address: frame)
        f.pointee.lock.withLock { f.pointee.handlers[Int(vector)] = object }
    }

    /// Masks or unmasks `vector` in the frame.
    static func setMasked(_ frame: UInt64, vector: UInt32, _ masked: Bool) {
        let f = MsiFramePointer(address: frame)
        f.pointee.maskLock.withLock {
            let at = f.pointee.registers + MsiFrame.mask(Int(vector / 32)), bit: UInt32 = 1 << (vector % 32)
            write32(at, masked ? read32(at) | bit : read32(at) & ~bit)
        }
    }

    /// The wired interrupt (interrupt context): each group's pending
    /// vectors cleared, then their objects fired. A vector that arrives
    /// meanwhile sets its bit again and holds the line.
    static let service: DeviceIrqs.KernelHandler = { frame in
        let f = MsiFramePointer(address: frame)
        f.pointee.lock.withLock {
            for g in 0..<8 {
                let at = f.pointee.registers + MsiFrame.status(g)
                var pending = read32(at)
                guard pending != 0 else { continue }
                write32(at, pending)
                while pending != 0 {
                    let bit = pending.trailingZeroBitCount
                    pending &= pending - 1
                    let object = f.pointee.handlers[g * 32 + bit]
                    if object != 0 { InterruptObjects.fire(ObjectPointer(address: object)) }
                }
            }
        }
    }

    private static func read32(_ address: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).load()
    }
    private static func write32(_ address: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
    }
}
