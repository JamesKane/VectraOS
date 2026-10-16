import CKernel
import PageTables
import Synchronization

/// The kernel trace (roadmap "Trace", the core of requirement 18): one
/// trace ring per CPU (include/trace.h, D50: a 128-byte trace header, then
/// a one ring of 40-byte slots, each the ring's sequence and a 32-byte
/// record), written only by its own CPU with interrupts masked, so no
/// lock, through `Ring.swift`'s OVERWRITE writer, as the debuglog is.
///
/// A probe is `Trace.event(category, kind, a, b)`: inlined, it costs one
/// relaxed load of the category mask and a branch when the category is
/// off, and evaluates its arguments only when it is on.
///
/// Stopping needs no IPI (ADR-0049): a writer sets its CPU's
/// `traceWriting` flag and then re-reads the mask; `stop` clears the mask
/// and then waits until it has seen every flag clear. Both sides use
/// sequentially consistent accesses, so a writer either sees the mask
/// clear or is waited for.
///
/// Each CPU's ring is a contiguous VMO, mapped into the kernel to write;
/// trace_configure hands the VMOs out, and user space maps them read-only
/// and reads them as any OVERWRITE ring's reader does.
enum Trace {
    nonisolated(unsafe) private static var session: UInt64 = 0
    nonisolated(unsafe) private static var pagesPerCpu = 0
    nonisolated(unsafe) private static var ringVmos = InlineArray<64, UInt64>(repeating: 0)

    static var slotSize: Int { MemoryLayout<croi_trace_slot_t>.size }
    static var format: UInt64 { UInt64(CROI_TRACE_RING_FORMAT) }
    static var flags: UInt16 { RingLayout.overwrite }
    static var ringOffset: Int { Int(CROI_TRACE_RING_HEADER) }

    /// A CPU's ring, as the self-tests read it.
    struct Header {
        /// Records ever written (the ring's cursor).
        var head: UInt64
        /// Slots: a power of two.
        var capacity: UInt64
        var drops: UInt64
        var frequency: UInt64
    }

    /// Records an event if `category` is on.
    @inline(__always)
    static func event(_ category: UInt32, _ kind: UInt16, _ a: @autoclosure () -> UInt64 = 0,
                      _ b: @autoclosure () -> UInt64 = 0) {
        if croi_trace_categories() & category != 0 {
            write(category, kind, a(), b())
        }
    }

    @inline(never)
    static func write(_ category: UInt32, _ kind: UInt16, _ a: UInt64, _ b: UInt64) {
        let saved = arch_interrupts_save()
        let address = arch_percpu()
        guard address != 0 else {
            arch_interrupts_restore(saved)
            return
        }
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(address))!
        unsafe percpu.pointee.traceWriting.store(true, ordering: .sequentiallyConsistent)
        let ringAddress = unsafe percpu.pointee.traceRing
        if croi_trace_categories_ordered() & category != 0, ringAddress != 0, unsafe percpu.pointee.traceWriter != nil {
            let ring = unsafe UnsafeMutablePointer<croi_trace_ring_t>(bitPattern: UInt(ringAddress))!
            let time = arch_counter_read()
            if unsafe ring.pointee.mode == UInt32(CROI_TRACE_ONESHOT),
               unsafe (percpu.pointee.traceWriter?.position ?? 0) >= (percpu.pointee.traceWriter?.slotCount ?? 0) {
                if unsafe ring.pointee.drops == 0 { unsafe ring.pointee.first_drop = time }
                unsafe ring.pointee.drops += 1
                unsafe ring.pointee.last_drop = time
            } else {
                var slot = unsafe croi_trace_slot_t(sequence: 0, record: croi_trace_record_t(
                    time: time, kind: kind, cpu: UInt16(truncatingIfNeeded: percpu.pointee.number),
                    thread: percpu.pointee.traceThread, a: a, b: b))
                unsafe withUnsafeBytes(of: &slot) { bytes in
                    unsafe percpu.pointee.traceWriter?.write(from: bytes.baseAddress!)
                }
            }
        }
        unsafe percpu.pointee.traceWriting.store(false, ordering: .releasing)
        arch_interrupts_restore(saved)
    }

    // MARK: Control

    /// Starts recording `categories` into rings of `pages` ×
    /// CROI_TRACE_RECORDS_PER_PAGE records per CPU (pages rounded up to a
    /// power of two, so the ring's slots are one), discarding what was
    /// there.
    static func start(categories: UInt32, pages requested: Int, mode: UInt32,
                      sampleHz: UInt64 = UInt64(CROI_SAMPLE_DEFAULT_HZ)) throws(VmError) {
        stop()
        var pages = 1
        while pages < requested { pages *= 2 }
        if pages != pagesPerCpu {
            release()
            let size = mappedSize(pages)
            for cpu in 0..<Smp.count {
                let vmo = try Vmo(contiguous: size)
                guard case .contiguous(let base) = vmo.record.pointee.kind else { panic("trace: ring VMO") }
                let ring = try kernelAspace.mapPhysical(base, size: size, MapAttributes(writable: true, global: true))
                ringVmos[cpu] = vmo.keep().address
                unsafe percpu(cpu).pointee.traceRing = ring
            }
            pagesPerCpu = pages
        }
        session += 1
        for cpu in 0..<Smp.count { reset(cpu, mode: mode) }
        croi_trace_set_categories(categories)
        if categories & CROI_TRACE_SAMPLE != 0 { Sampler.start(hz: sampleHz) }
    }

    /// The bytes a CPU's trace ring takes, page rounded.
    private static func mappedSize(_ pages: Int) -> UInt64 {
        let ring = RingLayout.size(slotSize: slotSize, count: pages * Int(CROI_TRACE_RECORDS_PER_PAGE))!
        return (UInt64(ringOffset + ring) + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
    }

    /// Makes a CPU's trace ring anew, empty (recording stopped): zeroed,
    /// its header written, a ring made and its writer attached.
    private static func reset(_ cpu: Int, mode: UInt32) {
        let address = unsafe percpu(cpu).pointee.traceRing
        guard address != 0 else { return }
        let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(address))!
        let size = Int(mappedSize(pagesPerCpu))
        unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        unsafe base.assumingMemoryBound(to: croi_trace_ring_t.self).pointee = croi_trace_ring_t(
            frequency: Clock.frequency, session: session, drops: 0, first_drop: 0, last_drop: 0, mode: mode,
            cpu: UInt32(cpu), magic: UInt32(CROI_TRACE_RING_MAGIC), thread: 0,
            reserved: (0, 0, 0, 0, 0, 0, 0, 0, 0))
        let ring = unsafe base + ringOffset
        let count = pagesPerCpu * Int(CROI_TRACE_RECORDS_PER_PAGE)
        guard unsafe NativeRing.create(ring, size: size - ringOffset, slotSize: slotSize, count: count, format: format,
                                       flags: flags) else { panic("trace: making a ring") }
        unsafe percpu(cpu).pointee.traceWriter = unsafe NativeRing(attaching: ring, size: size - ringOffset,
                                                                  producer: true, slotSize: slotSize,
                                                                  format: format, flags: flags)
    }

    /// Stops recording; returns once no CPU is mid-record.
    static func stop() {
        Sampler.stop()
        croi_trace_set_categories(0)
        for cpu in 0..<Smp.count {
            while unsafe percpu(cpu).pointee.traceWriting.load(ordering: .sequentiallyConsistent) {
                arch_spin_pause()
            }
        }
    }

    /// Stops and frees the rings.
    static func release() {
        stop()
        guard pagesPerCpu > 0 else { return }
        for cpu in 0..<Smp.count {
            let ring = unsafe percpu(cpu).pointee.traceRing
            unsafe percpu(cpu).pointee.traceRing = 0
            unsafe percpu(cpu).pointee.traceWriter = nil
            do throws(VmError) {
                try kernelAspace.free(ring)
            } catch {
                panic("trace: freeing an unknown ring")
            }
            VmoPointer(address: ringVmos[cpu]).release()
            ringVmos[cpu] = 0
        }
        pagesPerCpu = 0
    }

    static var categories: UInt32 { croi_trace_categories() }

    /// Stops and empties every ring (keeping its memory and mode).
    static func rewind() {
        stop()
        for cpu in 0..<Smp.count {
            guard let ring = unsafe ring(cpu) else { continue }
            reset(cpu, mode: unsafe ring.pointee.mode)
        }
    }

    /// A CPU's ring VMO (for handing out), if rings exist.
    static func ringVmo(_ cpu: Int) -> VmoPointer? {
        ringVmos[cpu] == 0 ? nil : VmoPointer(address: ringVmos[cpu])
    }

    /// A CPU's ring (stop first for a stable view).
    static func header(_ cpu: Int) -> Header? {
        guard let ring = unsafe ring(cpu), unsafe percpu(cpu).pointee.traceWriter != nil else { return nil }
        return unsafe Header(head: percpu(cpu).pointee.traceWriter?.position ?? 0,
                             capacity: percpu(cpu).pointee.traceWriter?.slotCount ?? 0,
                             drops: ring.pointee.drops, frequency: ring.pointee.frequency)
    }

    /// The records a CPU's ring holds, oldest first, read as any reader
    /// reads it (stop first: a record being overwritten is skipped).
    static func forEachRecord(_ cpu: Int, _ body: (croi_trace_record_t) -> Void) {
        guard let header = unsafe ring(cpu) else { return }
        let base = unsafe UnsafeMutableRawPointer(header) + ringOffset
        let size = Int(mappedSize(pagesPerCpu)) - ringOffset
        guard var reader = unsafe NativeRing(attaching: base, size: size, producer: false, slotSize: slotSize,
                                             format: format, flags: flags) else { return }
        var slot = croi_trace_slot_t()
        var dropped: UInt64 = 0
        while unsafe withUnsafeMutableBytes(of: &slot, { bytes in
            unsafe reader.read(to: bytes.baseAddress!, dropped: &dropped)
        }) {
            body(slot.record)
        }
    }

    private static func percpu(_ cpu: Int) -> UnsafeMutablePointer<PerCpu> {
        unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
    }

    private static func ring(_ cpu: Int) -> UnsafeMutablePointer<croi_trace_ring_t>? {
        let address = unsafe percpu(cpu).pointee.traceRing
        guard address != 0 else { return nil }
        return unsafe UnsafeMutablePointer<croi_trace_ring_t>(bitPattern: UInt(address))
    }
}
