import _Volatile
import AcpiRoot
import CKernel
import Fmt
import PageTables

/// The SBSA generic watchdog (Arm; described by the GTDT). During bring-up
/// a hang should become a reset, not a power cycle, so croi enables it and
/// refreshes it from a kernel timer. `croi.watchdog=off` leaves it alone.
///
/// The watchdog counts at the system counter frequency. Its first stage
/// fires after WOR ticks without a refresh, the second (a reset) after
/// another WOR, so the timeout is twice the offset.
struct SbsaWatchdog {
    /// How a refresh is done. The standard way writes the refresh frame;
    /// the CIX Sky1's refresh frame doesn't work and a refresh must rewrite
    /// WOR instead (a board rule chooses this).
    enum RefreshMethod {
        case refreshFrame
        case offsetRegister
    }

    /// Physical frames, as the GTDT gives them.
    struct Description: Equatable {
        var refreshFrame: UInt64
        var controlFrame: UInt64
        var interrupt: UInt32
    }

    let control: UInt64  // virtual
    let refresh: UInt64  // virtual
    let method: RefreshMethod
    private(set) var offset: UInt64 = 0

    init(control: UInt64, refresh: UInt64, method: RefreshMethod = .refreshFrame) {
        self.control = control
        self.refresh = refresh
        self.method = method
    }

    /// Programs a timeout of `ticks` (system counter ticks) and enables it.
    mutating func enable(timeoutTicks ticks: UInt64) {
        offset = ticks / 2
        write32(control + 0x8, UInt32(truncatingIfNeeded: offset))        // WOR[31:0]
        write32(control + 0xC, UInt32(truncatingIfNeeded: offset >> 32))  // WOR[47:32]
        write32(control + 0x0, 1)                                         // WCS.EN
    }

    func kick() {
        switch method {
        case .refreshFrame:
            write32(refresh + 0x0, 0)  // WRR: any write refreshes
        case .offsetRegister:
            write32(control + 0x8, UInt32(truncatingIfNeeded: offset))  // writing WOR refreshes
        }
    }

    func disable() {
        write32(control + 0x0, 0)  // WCS.EN off
    }

    // MARK: Discovery

    /// The first SBSA watchdog in the GTDT's platform timers.
    static func find(_ acpi: AcpiTables) -> Description? {
        guard let gtdt = acpi.table("GTDT") else { return nil }
        return acpi.withTable(gtdt) { (table: RawSpan) -> Description? in find(in: table) }
    }

    /// `find`, over a table already in hand (also used by the self-test).
    static func find(in table: RawSpan) -> Description? {
        guard table.byteCount >= 96 else { return nil }
        let count = Int(table.load(fromByteOffset: 88, as: UInt32.self))
        var offset = Int(table.load(fromByteOffset: 92, as: UInt32.self))
        for _ in 0..<count {
            guard offset >= 96, offset + 3 <= table.byteCount else { return nil }
            let type = table.load(fromByteOffset: offset, as: UInt8.self)
            let length = Int(table.load(fromByteOffset: offset + 1, as: UInt16.self))
            guard length > 0, offset + length <= table.byteCount else { return nil }
            if type == 1, length >= 28 {  // SBSA generic watchdog
                return Description(refreshFrame: table.load(fromByteOffset: offset + 4, as: UInt64.self),
                                   controlFrame: table.load(fromByteOffset: offset + 12, as: UInt64.self),
                                   interrupt: table.load(fromByteOffset: offset + 20, as: UInt32.self))
            }
            offset += length
        }
        return nil
    }

    private func write32(_ address: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
    }
}

#if arch(riscv64)
/// The SpacemiT K1's watchdog (chinese-wall's spacemit-k1 10), which no
/// table describes: our tree has no node for it, as upstream's has none,
/// so its addresses are the SoC's. A board rule (D126) runs it as the
/// watchdog and resets the SoC through it.
///
/// Each write to one of its registers follows an unlock pair (WFAR,
/// WSAR). Its 16-bit counter runs at 256 Hz, back to 0 at a write of
/// WCR, and a match of WMR with WMER's counter and reset bits on resets
/// the SoC. Its clocks and reset are the MPMU's WDTPCR; the MPMU's APRR
/// holds the watchdog's own reset bit, set each time it is armed, and
/// ARSR's bits 11:8 a reboot's reason, which a reset through it leaves
/// as 1 (a plain reboot). WSR says whether a match reset the SoC, but the
/// Orange Pi RV2's U-Boot clears it as it starts the watchdog itself (60 s,
/// stopped again before it boots us), and ARSR's low bits read 0x0c after
/// a reboot and after a hang alike: there, a reboot through it is known,
/// and a hang can't be told from a power-on.
struct K1Watchdog {
    /// What the last reset was, read before the watchdog is armed.
    enum Cause: Equatable {
        /// Nothing says it was the watchdog's: power on, the PMIC, or a
        /// hang whose WSR firmware cleared.
        case other
        /// A reboot through it (`reset`).
        case reboot
        /// A match nothing asked for: a hang.
        case expired
    }

    private var base: UInt64 = 0
    private var mpmu: UInt64 = 0  // the MPMU's first two pages

    private static var physical: UInt64 { 0xD408_0000 }
    private static var mpmuPhysical: UInt64 { 0xD405_0000 }
    private static var wdtpcr: UInt64 { 0x200 }  // bit 0 bus clock, 1 its clock, 2 held in reset
    private static var aprr: UInt64 { 0x1020 }
    private static var aprrWatchdogReset: UInt32 { 1 << 4 }
    private static var arsr: UInt64 { 0x1028 }
    private static var arsrReason: UInt32 { 0xF << 8 }
    private static var arsrPlainReboot: UInt32 { 1 << 8 }
    private static var wfar: UInt64 { 0xB0 }
    private static var wsar: UInt64 { 0xB4 }
    private static var wmer: UInt64 { 0xB8 }  // bit 0 counter, bit 1 reset
    private static var wmr: UInt64 { 0xBC }  // the match value
    private static var wsr: UInt64 { 0xC0 }  // status
    private static var wcr: UInt64 { 0xC8 }  // 1: the counter back to 0
    /// The counter's rate, and its largest match.
    static var ticksPerSecond: UInt64 { 256 }
    static var longestTimeoutSeconds: UInt64 { 255 }

    init() {}

    /// Over registers already mapped (the self-test's stand-ins).
    init(base: UInt64, mpmu: UInt64) {
        self.base = base
        self.mpmu = mpmu
    }

    var mapped: Bool { base != 0 }

    /// Maps its registers and the MPMU's (boot). A failure leaves it
    /// unused, and reset to SRST.
    mutating func map() {
        let device = MapAttributes(writable: true, cache: .device, global: true)
        let page = KernelLayout.pageSize
        do throws(VmError) {
            base = try kernelAspace.mapPhysical(Self.physical, size: page, device)
            mpmu = try kernelAspace.mapPhysical(Self.mpmuPhysical, size: 2 * page, device)
        } catch {
            base = 0
        }
    }

    /// Arms it for `seconds` (at most 255) and says what the last reset
    /// was, which it then forgets.
    func start(timeoutSeconds seconds: UInt64) -> Cause {
        guard mapped else { return .other }
        clockOn()
        let reason = read(mpmu + Self.arsr)
        let cause: Cause = reason & Self.arsrReason == Self.arsrPlainReboot ? .reboot
            : read(base + Self.wsr) != 0 ? .expired : .other
        store(mpmu + Self.arsr, reason & ~Self.arsrReason)
        write(Self.wcr, 1)
        write(Self.wmr, UInt32(min(seconds, Self.longestTimeoutSeconds) * Self.ticksPerSecond))
        write(Self.wmer, 3)
        holdOwnReset()
        write(Self.wsr, 0)
        return cause
    }

    func kick() {
        guard mapped else { return }
        write(Self.wcr, 1)
    }

    /// Its counter off. The clock stays on.
    func stop() {
        guard mapped else { return }
        write(Self.wcr, 1)
        write(Self.wmer, 0)
    }

    /// A match at the next tick, a plain reboot's reason left for the next
    /// boot. Returns if the SoC didn't reset.
    func reset() {
        guard mapped else { return }
        clockOn()
        store(mpmu + Self.arsr, read(mpmu + Self.arsr) & ~Self.arsrReason | Self.arsrPlainReboot)
        write(Self.wsr, 0)
        write(Self.wmr, 1)
        write(Self.wmer, 3)
        write(Self.wcr, 1)
        holdOwnReset()
        Clock.delay(nanoseconds: 100_000_000)
    }

    /// Both clocks on and its reset released, whatever firmware left.
    private func clockOn() {
        store(mpmu + Self.wdtpcr, read(mpmu + Self.wdtpcr) & ~4 | 3)
    }

    private func holdOwnReset() {
        store(mpmu + Self.aprr, read(mpmu + Self.aprr) | Self.aprrWatchdogReset)
    }

    private func write(_ offset: UInt64, _ value: UInt32) {
        store(base + Self.wfar, 0xBABA)
        store(base + Self.wsar, 0xEB10)
        store(base + offset, value)
    }

    private func read(_ address: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).load()
    }

    private func store(_ address: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
    }
}
#endif

/// The running watchdog, refreshed by a timer on the boot CPU: the GTDT's
/// SBSA watchdog, or a board's own (the K1's).
enum Watchdog {
    enum Unit {
        case sbsa(SbsaWatchdog)
        #if arch(riscv64)
        case k1
        #endif
    }

    /// What `start` found.
    enum Started {
        case none
        case sbsa
        #if arch(riscv64)
        case k1(K1Watchdog.Cause)
        #endif
    }

    nonisolated(unsafe) private static var active: Unit?
    #if arch(riscv64)
    /// The K1's, mapped by `Power.initialize` where the board has one: its
    /// reset too.
    nonisolated(unsafe) static var k1 = K1Watchdog()
    #endif
    static var timeoutSeconds: UInt64 { 30 }
    /// Every 20-25 s (the slack lets it ride on another wakeup): the one
    /// periodic wakeup left on an idle machine (K10f), 30 s timeout. The
    /// SBSA watchdog's first stage (WS0, 15 s) is only a signal nobody
    /// takes.
    private static var refreshNanoseconds: UInt64 { 20_000_000_000 }
    private static var refreshSlack: UInt64 { 5_000_000_000 }

    /// Maps and enables the board's watchdog or the GTDT's.
    static func start(_ acpi: AcpiTables) -> Started {
        #if arch(riscv64)
        if k1.mapped {
            let cause = k1.start(timeoutSeconds: timeoutSeconds)
            lastCause = cause
            active = .k1
            arm()
            return .k1(cause)
        }
        #endif
        guard let description = SbsaWatchdog.find(acpi) else { return .none }
        let device = MapAttributes(writable: true, cache: .device, global: true)
        let page = KernelLayout.pageSize
        let control: UInt64, refresh: UInt64
        do throws(VmError) {
            control = try kernelAspace.mapPhysical(description.controlFrame & ~(page - 1), size: page, device)
                + (description.controlFrame & (page - 1))
            refresh = try kernelAspace.mapPhysical(description.refreshFrame & ~(page - 1), size: page, device)
                + (description.refreshFrame & (page - 1))
        } catch {
            return .none
        }
        var watchdog = SbsaWatchdog(control: control, refresh: refresh, method: BoardRules.watchdogRefresh)
        watchdog.enable(timeoutTicks: Clock.frequency * timeoutSeconds)
        active = .sbsa(watchdog)
        arm()
        return .sbsa
    }

    #if arch(riscv64)
    nonisolated(unsafe) private static var lastCause = K1Watchdog.Cause.other
    #endif

    /// Once the debuglog runs: a reset the watchdog made, as a record, so
    /// `log` shows it where the console isn't watched.
    static func logCause() {
        #if arch(riscv64)
        switch lastCause {
        case .other: break
        case .reboot:
            KernelLog.write(UInt8(CROI_LOG_INFO)) { $0.write("watchdog: the last reset was a reboot through it") }
        case .expired:
            KernelLog.write(UInt8(CROI_LOG_WARNING)) {
                $0.write("watchdog: the last reset was the watchdog's, unasked (a hang)")
            }
        }
        #endif
    }

    /// `croi.watchdog=off`: the K1's stopped, since a kernel before a warm
    /// boot may have left it running; the SBSA watchdog left alone.
    static func leaveOff() {
        #if arch(riscv64)
        k1.stop()
        #endif
    }

    /// Stops the running one (a shutdown, with nothing left to refresh it).
    static func stop() {
        switch active {
        case .sbsa(let watchdog)?: watchdog.disable()
        #if arch(riscv64)
        case .k1?: k1.stop()
        #endif
        case nil: break
        }
        active = nil
    }

    private static func arm() {
        Timers.arm(deadline: Clock.now() + refreshNanoseconds, slack: refreshSlack, kickAndRearm, 0)
    }

    private static let kickAndRearm: Timers.Callback = { _, _ in
        switch active {
        case .sbsa(let watchdog)?: watchdog.kick()
        #if arch(riscv64)
        case .k1?: k1.kick()
        #endif
        case nil: return
        }
        arm()
    }
}
