import _Volatile
import CHandoff
import CKernel
import Fmt
import Synchronization

/// Polled early-console UART, as described by the loader (from ACPI SPCR).
/// Assumes firmware already configured line settings. Writes `\n` as `\r\n`.
///
/// What the kernel writes waits in ConsoleBuffer for the debuglog's dumper
/// to print, so boot doesn't wait on the port (boot.console: 119 ms of the
/// Orange Pi's 200 ms to userboot was the banner at 115200 baud). A write
/// from a context that can't wake the dumper (a spin lock held, interrupts
/// masked) prints what waits and itself at once, as a panic, a fatal
/// exception and `Power.leave` do for good (`goDirect`), and every write
/// with `croi.console=direct` (a board that hangs before the dumper runs).
@safe struct Uart: TextOutput {
    private let config: croi_uart_t

    /// The UART's registers must be mapped (identity, device memory) for as
    /// long as this value is used.
    @unsafe init(_ config: croi_uart_t) {
        self.config = config
    }

    func write(utf8: Span<UInt8>) {
        // Whether this context may wake the dumper: read before the lock
        // masks interrupts.
        let mayWake = ConsoleBuffer.dumperRunning && arch_interrupts_enabled() && !Self.holdsSpinLock
        let wake = ConsoleLock.withLock { () -> Bool in
            let buffered = ConsoleBuffer.buffering && (mayWake || !ConsoleBuffer.dumperRunning)
            if !buffered { drainLocked() }
            var ended = false
            for i in utf8.indices {
                if utf8[i] == UInt8(ascii: "\n") {
                    ended = true
                    emit(UInt8(ascii: "\r"), buffered)
                }
                emit(utf8[i], buffered)
            }
            if !utf8.isEmpty { ConsoleLock.lineOpen = utf8[utf8.count - 1] != UInt8(ascii: "\n") }
            return buffered && ended && mayWake
        }
        if wake { DebugLog.kick() }
    }

    private static var holdsSpinLock: Bool {
        guard let percpu = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu())) else { return true }
        return unsafe percpu.pointee.spinLocksHeld != 0
    }

    /// A byte into the buffer, or to the port. A full buffer prints its
    /// oldest byte first: the writer waits on the port, nothing is lost.
    private func emit(_ byte: UInt8, _ buffered: Bool) {
        guard buffered else { return put(byte) }
        if ConsoleBuffer.tail - ConsoleBuffer.head == ConsoleBuffer.size {
            put(ConsoleBuffer.byte(at: ConsoleBuffer.head))
            ConsoleBuffer.head += 1
        }
        ConsoleBuffer.store(byte)
    }

    /// Prints what waits in the buffer (console lock held).
    private func drainLocked() {
        while ConsoleBuffer.head < ConsoleBuffer.tail {
            put(ConsoleBuffer.byte(at: ConsoleBuffer.head))
            ConsoleBuffer.head += 1
        }
    }

    /// Prints what waits, the dumper's: a FIFO's worth (32 bytes) taken
    /// under the console lock, and printed outside it, so writers, which
    /// only buffer, never wait on the port for the lock.
    func drainBuffered() {
        var chunk = InlineArray<32, UInt8>(repeating: 0)
        while true {
            let n = ConsoleLock.withLock { () -> Int in
                var n = 0
                while n < 32, ConsoleBuffer.head < ConsoleBuffer.tail {
                    chunk[n] = ConsoleBuffer.byte(at: ConsoleBuffer.head)
                    ConsoleBuffer.head += 1
                    n += 1
                }
                return n
            }
            if n == 0 { return }
            for i in 0..<n { put(chunk[i]) }
        }
    }

    /// Every write printed at once from here on, after what waits: for a
    /// panic, a fatal exception, or the machine's last moments, when the
    /// dumper may never run again.
    func goDirect() {
        ConsoleLock.withLock {
            drainLocked()
            ConsoleBuffer.buffering = false
        }
    }

    /// Writes whole lines (the debuglog dumper's) only at the start of a
    /// line: while another CPU is part way through one of its own (written
    /// as several calls), waits up to `patience` ns for it to finish.
    func writeLines(utf8: Span<UInt8>, patience: UInt64) {
        let giveUp = Clock.now() + patience
        while true {
            let done = ConsoleLock.withLock { () -> Bool in
                guard !ConsoleLock.lineOpen || ConsoleLock.lastWriter == Cpu.current || Clock.now() >= giveUp else {
                    return false
                }
                drainLocked()  // what the kernel wrote before it
                for i in utf8.indices {
                    if utf8[i] == UInt8(ascii: "\n") {
                        put(UInt8(ascii: "\r"))
                    }
                    put(utf8[i])
                }
                ConsoleLock.lineOpen = false
                return true
            }
            if done { return }
            Scheduler.sleep(until: Clock.now() + 1_000_000)
        }
    }

    /// Waits (up to `patience` ns) until everything written has left the
    /// transmitter: before the machine is turned off, which drops what an
    /// emulated UART still holds (power off, K10e).
    func drain(patience: UInt64) {
        let giveUp = Clock.now() + patience
        while Clock.now() < giveUp {
            switch config.kind {
            case CROI_UART_NS16550_PIO, CROI_UART_NS16550_MMIO:
                if ns16550Read(register: 5) & 0x40 != 0 { return }  // LSR.TEMT
            case CROI_UART_PL011:
                if unsafe mmio32(0x18).load() & 0x88 == 0x80 { return }  // FR.TXFE, not BUSY
            default:
                return
            }
            arch_spin_pause()
        }
    }

    private func put(_ byte: UInt8) {
        switch config.kind {
        case CROI_UART_NS16550_PIO, CROI_UART_NS16550_MMIO:
            // Wait for LSR.THRE, then write THR.
            while ns16550Read(register: 5) & 0x20 == 0 {}
            ns16550Write(register: 0, byte)
        case CROI_UART_PL011:
            // Wait while FR.TXFF, then write DR.
            while unsafe mmio32(0x18).load() & 0x20 != 0 {}
            unsafe mmio32(0x00).store(UInt32(byte))
        default:
            break
        }
    }

    private func ns16550Read(register: UInt64) -> UInt8 {
        #if arch(x86_64)
        if config.kind == CROI_UART_NS16550_PIO {
            return arch_inb(UInt16(truncatingIfNeeded: config.base + register))
        }
        #endif
        let offset = register << config.reg_shift
        return config.access_width == 4
            ? UInt8(truncatingIfNeeded: unsafe mmio32(offset).load())
            : unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(config.base + offset)).load()
    }

    private func ns16550Write(register: UInt64, _ value: UInt8) {
        #if arch(x86_64)
        if config.kind == CROI_UART_NS16550_PIO {
            arch_outb(UInt16(truncatingIfNeeded: config.base + register), value)
            return
        }
        #endif
        let offset = register << config.reg_shift
        if config.access_width == 4 {
            unsafe mmio32(offset).store(UInt32(value))
        } else {
            unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(config.base + offset)).store(value)
        }
    }

    @unsafe private func mmio32(_ offset: UInt64) -> VolatileMappedRegister<UInt32> {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(config.base + offset))
    }
}

extension croi_uart_t {
    /// The same UART, addressed through the physmap (MMIO kinds only).
    var inPhysmap: croi_uart_t {
        var uart = self
        if kind == CROI_UART_NS16550_MMIO || kind == CROI_UART_PL011 {
            uart.base = KernelLayout.physmap(base)
        }
        return uart
    }
}

/// The kernel's console output waiting for the dumper (console.h's
/// buffer, a ring of bytes): `head` and `tail` count bytes printed and
/// written since boot (console lock).
enum ConsoleBuffer {
    nonisolated(unsafe) static var head = 0
    nonisolated(unsafe) static var tail = 0
    /// Until `goDirect`: from kernel entry, unless `croi.console=direct`.
    nonisolated(unsafe) static var buffering = true
    /// The dumper has started: writes may wake it.
    nonisolated(unsafe) static var dumperRunning = false
    static var size: Int { Int(CROI_CONSOLE_BUFFER_SIZE) }
    /// Bytes wait (read without the lock by the dumper, which a writer
    /// wakes after writing them).
    static var pending: Bool { head != tail }

    static func byte(at n: Int) -> UInt8 { unsafe croi_console_buffer()[n % size] }

    static func store(_ byte: UInt8) {
        unsafe croi_console_buffer()[tail % size] = byte
        tail += 1
    }
}

/// Serializes console writes between CPUs a call at a time, so the
/// debuglog dumper and the boot code don't interleave characters. Masks
/// interrupts while held. Never deadlocks a panic: a CPU already holding it
/// (a fault while writing) goes straight through, and a waiter gives up
/// after 10^8 spins and writes anyway (the holder may be halted).
enum ConsoleLock {
    private static let holder = Atomic<UInt32>(0)
    /// The last write didn't end its line (lock held).
    nonisolated(unsafe) static var lineOpen = false
    nonisolated(unsafe) static var lastWriter: UInt32 = 0

    static func withLock<R>(_ body: () -> R) -> R {
        let saved = arch_interrupts_save()
        let me = Cpu.current + 1
        var owned = false
        if holder.load(ordering: .relaxed) != me {
            for _ in 0..<100_000_000 {
                if holder.compareExchange(expected: 0, desired: me, ordering: .acquiring).exchanged {
                    owned = true
                    break
                }
                arch_spin_pause()
            }
        }
        let result = body()
        lastWriter = me - 1
        if owned { holder.store(0, ordering: .releasing) }
        arch_interrupts_restore(saved)
        return result
    }
}
