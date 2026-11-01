import Fdt
import _Volatile

/// A board's EEPROM, which holds what only firmware knows and puts in no
/// tree: the Orange Pi RV2's U-Boot reads its network addresses from an
/// `atmel,24c02` on the SpacemiT K1's I2C (TWSI) and gives them to no one.
/// The loader reads it the same way, polled, while firmware's setup of the
/// bus (its pins) still stands: the 256 bytes, which DtAcpi's Onie parses.
/// Found in firmware's tree, under a TWSI this table knows: its registers
/// and the APBC register that gates and resets it (k1-syscon(3)'s table),
/// turned on first, since on the K1 an access to a gated block stalls the
/// CPU. An entry joins when a board needs one.
enum BoardEeprom {
    static let controllers: InlineArray<1, (base: UInt64, apbc: UInt64)> = [
        (0xD401_2000, 0xD401_5038),  // TWSI2
    ]

    /// The EEPROM's 256 bytes, or nil where firmware's tree has none under
    /// a known controller, or the read fails.
    @unsafe static func read(_ firmware: borrowing Fdt, _ boot: BootServices) -> InlineArray<256, UInt8>? {
        guard let root = firmware.root, let (base, apbc, address) = find(firmware, root, parent: nil) else { return nil }
        return Twsi(base: base, boot: boot).read(device: address, apbc: apbc)
    }

    /// The first `atmel,24c02` under a known controller: the controller,
    /// its APBC register and the EEPROM's bus address.
    private static func find(_ fdt: borrowing Fdt, _ node: Int, parent: Int?) -> (UInt64, UInt64, UInt8)? {
        if let parent, fdt.contains(node, "compatible", "atmel,24c02"), let at = fdt.reg(parent),
           let reg = fdt.property(node, "reg"), reg.count == 4 {
            for i in controllers.indices where controllers[i].base == at.address {
                return (controllers[i].base, controllers[i].apbc, fdt.byte(reg.upperBound - 1))
            }
        }
        var c = fdt.firstChild(of: node)
        while let child = c {
            c = fdt.nextSibling(of: child)
            if let found = find(fdt, child, parent: node) { return found }
        }
        return nil
    }

    /// The K1's TWSI, as Linux's i2c-k1 drives it, polled.
    struct Twsi {
        let base: UInt64
        let boot: BootServices

        // Registers and bits (i2c-k1.c).
        static let icr: UInt64 = 0x0, isr: UInt64 = 0x4, idbr: UInt64 = 0xC
        static let start: UInt32 = 1 << 0, stop: UInt32 = 1 << 1, nak: UInt32 = 1 << 2, transfer: UInt32 = 1 << 3
        static let clockEnable: UInt32 = 1 << 13, unitEnable: UInt32 = 1 << 14, noGeneralCall: UInt32 = 1 << 21
        static let acked: UInt32 = 1 << 14, busBusy: UInt32 = 1 << 16, arbitrationLost: UInt32 = 1 << 18
        static let sent: UInt32 = 1 << 19, received: UInt32 = 1 << 20, busError: UInt32 = 1 << 22

        func load(_ register: UInt64) -> UInt32 {
            unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(register)).load()
        }
        func store(_ register: UInt64, _ value: UInt32) {
            unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(register)).store(value)
        }

        /// Waits up to 10 ms for `bits` in the status, cleared once seen;
        /// false on a timeout, a lost arbitration or a bus error.
        func wait(_ bits: UInt32) -> Bool {
            for _ in 0..<1000 {
                let s = unsafe load(base + Self.isr)
                if s & (Self.arbitrationLost | Self.busError) != 0 { return false }
                if s & bits != 0 {
                    unsafe store(base + Self.isr, s & bits)
                    return true
                }
                unsafe boot.stall(10)
            }
            return false
        }

        /// One byte out, with the control bits given; false if it wasn't
        /// acknowledged.
        func send(_ byte: UInt8, _ control: UInt32, _ mode: UInt32) -> Bool {
            unsafe store(base + Self.idbr, UInt32(byte))
            unsafe store(base + Self.icr, mode | control | Self.transfer)
            let sent = unsafe wait(Self.sent)
            let status = unsafe load(base + Self.isr)
            return sent && status & Self.acked == 0
        }

        /// The 256 bytes of the 24c02 at `device`: its word address 0
        /// written, then a repeated start and every byte read, the last
        /// NAKed with a stop.
        func read(device: UInt8, apbc: UInt64) -> InlineArray<256, UInt8>? {
            // Its function and bus clocks on, its reset released.
            unsafe store(apbc, unsafe load(apbc) & ~0x4 | 0x3)
            unsafe boot.stall(10)
            let mode = unsafe load(base + Self.icr) & 0x0000_0300 | Self.unitEnable | Self.clockEnable | Self.noGeneralCall
            unsafe store(base + Self.icr, mode)
            unsafe store(base + Self.isr, unsafe load(base + Self.isr))
            for _ in 0..<100 where unsafe load(base + Self.isr) & Self.busBusy != 0 { unsafe boot.stall(10) }
            defer { unsafe store(base + Self.icr, mode) }
            guard unsafe send(device << 1, Self.start, mode), unsafe send(0, 0, mode),
                  unsafe send(device << 1 | 1, Self.start, mode)
            else {
                unsafe store(base + Self.icr, mode | Self.stop | Self.transfer)
                return nil
            }
            var out = InlineArray<256, UInt8>(repeating: 0)
            for i in 0..<256 {
                unsafe store(base + Self.icr, mode | Self.transfer | (i == 255 ? Self.stop | Self.nak : 0))
                guard unsafe wait(Self.received) else { return nil }
                out[i] = UInt8(truncatingIfNeeded: unsafe load(base + Self.idbr))
            }
            return out
        }
    }
}
