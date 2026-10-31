import AcpiRoot
import CEFI
import CHandoff

/// Physical memory as the loader reads it: UEFI's identity map.
enum IdentityMap: PhysicalReader {
    static func withBytes<R>(_ phys: UInt64, count: Int, _ body: (RawSpan) -> R) -> R {
        unsafe withPhysical(phys, size: count, body)
    }
}

/// The ACPI tables the loader needs: where the RSDP is (for the kernel) and
/// the console's, SPCR or DBG2 (for the kernel's early console).
struct Acpi {
    let root: AcpiRoot<IdentityMap>
    /// Physical address of the ACPI 2.0+ RSDP.
    var rsdp: UInt64 { root.rsdp }

    /// Finds the RSDP in the UEFI configuration table and validates it.
    init?(systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>) {
        guard let address = unsafe configurationTable(systemTable, .acpi20Table),
              let root = AcpiRoot<IdentityMap>(rsdp: address)
        else { return nil }
        self.root = root
    }

    /// Tables at `rsdp` that the loader made itself (Devicetree.swift).
    init?(rsdp: UInt64) {
        guard let root = AcpiRoot<IdentityMap>(rsdp: rsdp) else { return nil }
        self.root = root
    }

    /// Physical address of the first valid table with this signature.
    func table(_ signature: StaticString) -> UInt64? { root.table(signature) }

    /// The console UART from SPCR, if it describes a usable one.
    func spcrConsole() -> croi_uart_t? {
        guard let spcr = table("SPCR") else { return nil }
        return unsafe withPhysical(spcr, size: 52) { (table: RawSpan) -> croi_uart_t? in
            // Interface type at 36, Generic Address Structure at 40.
            Self.uart(type: UInt16(table.load(fromByteOffset: 36, as: UInt8.self)), gas: table.extracting(40..<52))
        }
    }

    /// The first usable serial port in DBG2 (boards with no SPCR, such as
    /// the CIX Sky1, name their console here).
    func dbg2Console() -> croi_uart_t? {
        guard let dbg2 = table("DBG2") else { return nil }
        return root.withTable(dbg2) { (table: RawSpan) -> croi_uart_t? in
            guard table.byteCount >= 44 else { return nil }
            var device = Int(table.load(fromByteOffset: 36, as: UInt32.self))
            let count = Int(table.load(fromByteOffset: 40, as: UInt32.self))
            for _ in 0..<count {
                guard device + 22 <= table.byteCount else { return nil }
                let deviceLength = Int(table.load(fromByteOffset: device + 1, as: UInt16.self))
                let registers = Int(table.load(fromByteOffset: device + 3, as: UInt8.self))
                let portType = table.load(fromByteOffset: device + 12, as: UInt16.self)
                let subtype = table.load(fromByteOffset: device + 14, as: UInt16.self)
                let gasOffset = Int(table.load(fromByteOffset: device + 18, as: UInt16.self))
                if portType == 0x8000, registers >= 1, device + gasOffset + 12 <= table.byteCount,
                   let uart = Self.uart(type: subtype, gas: table.extracting((device + gasOffset)..<(device + gasOffset + 12))) {
                    return uart
                }
                guard deviceLength > 0 else { return nil }
                device += deviceLength
            }
            return nil
        }
    }

    /// A UART from an SPCR interface type / DBG2 serial subtype (the two
    /// share their numbering) and its Generic Address Structure.
    private static func uart(type: UInt16, gas: RawSpan) -> croi_uart_t? {
        let space = gas.load(fromByteOffset: 0, as: UInt8.self)
        let accessSize = gas.load(fromByteOffset: 3, as: UInt8.self)
        let address = gas.load(fromByteOffset: 4, as: UInt64.self)
        guard address != 0 else { return nil }

        var uart = croi_uart_t()
        uart.base = address
        switch type {
        case 0x00, 0x01, 0x12:  // 16550 full / subset / with GAS
            if space == 1 {     // system I/O
                uart.kind = CROI_UART_NS16550_PIO
            } else if space == 0 {
                uart.kind = CROI_UART_NS16550_MMIO
                let width: UInt32 = accessSize == 3 ? 4 : 1  // dword : byte
                uart.access_width = width
                uart.reg_shift = width == 4 ? 2 : 0
            } else {
                return nil
            }
        case 0x03, 0x0D, 0x0E:  // PL011 / SBSA generic (32-bit)
            guard space == 0 else { return nil }
            uart.kind = CROI_UART_PL011
            uart.access_width = 4
        default:
            return nil  // e.g. 0x13, Qualcomm GENI: not supported yet
        }
        return uart
    }
}
