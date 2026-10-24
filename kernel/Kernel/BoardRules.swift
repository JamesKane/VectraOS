import Fmt

/// Board rules (D126): what a board needs that its firmware's tables don't
/// say, compiled in and chosen by the firmware's identity, the FADT's OEM
/// ID and OEM table ID, as Linux's ACPI quirk tables are. Errata of a part
/// (the GIC's) are keyed on the part's own ID register where they are
/// handled, not here.
enum BoardRules {
    enum Board {
        case unknown
        /// QEMU's machines (edk2 and SeaBIOS give "BOCHS ").
        case qemu
        /// The CIX Sky1 (Orange Pi 6 Plus, Radxa Orion O6): CIX's reference
        /// firmware.
        case cixSky1
    }

    nonisolated(unsafe) private(set) static var board = Board.unknown

    /// Reads the firmware's identity (boot, from the ACPI tables).
    static func identify(_ acpi: AcpiTables) {
        guard let fadt = acpi.table("FACP") else { return }
        board = acpi.withTable(fadt) { (table: RawSpan) -> Board in
            guard table.byteCount >= 24 else { return .unknown }
            if matches(table, at: 10, "BOCHS ") { return .qemu }
            if matches(table, at: 10, "CIXTEK"), matches(table, at: 16, "SKY1EDK2") { return .cixSky1 }
            return .unknown
        }
    }

    /// The SBSA watchdog's refresh: the Sky1's refresh frame doesn't
    /// refresh, a write of WOR does (AbyssBSD found it, FreeBSD's
    /// sbsa_gwdt does the same).
    static var watchdogRefresh: SbsaWatchdog.RefreshMethod {
        board == .cixSky1 ? .offsetRegister : .refreshFrame
    }

    /// Whether an SMMUv3 firmware left enabled is the OS's to take over:
    /// the Sky1's PCIe unit, which no RMR needs. Its other unit (display,
    /// NPU) stays firmware's: its RMR keeps the display controllers'
    /// streams on the GOP framebuffer, which they are scanning out.
    static func takesOverSmmu(at base: UInt64) -> Bool {
        board == .cixSky1 && base == 0xB01_0000
    }

    /// The boot line: the board, and the rules it takes.
    static func describe(to out: some TextOutput) {
        switch board {
        case .unknown: out.write("no board rules (unknown firmware)")
        case .qemu: out.write("QEMU's firmware; no board rules")
        case .cixSky1:
            out.write("CIX Sky1 (CIXTEK SKY1EDK2): the watchdog refreshed through WOR, the PCIe SMMU taken over")
        }
    }

    private static func matches(_ table: RawSpan, at offset: Int, _ text: StaticString) -> Bool {
        for i in 0..<text.utf8CodeUnitCount {
            let wanted = unsafe text.utf8Start[i]
            guard table.load(fromByteOffset: offset + i, as: UInt8.self) == wanted else { return false }
        }
        return true
    }
}
