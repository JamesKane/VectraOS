/// How an image reads physical memory: the loader through UEFI's identity
/// map, the kernel through its physmap.
public protocol PhysicalReader {
    static func withBytes<R>(_ phys: UInt64, count: Int, _ body: (RawSpan) -> R) -> R
}

/// The firmware's ACPI tables from the RSDP (ACPI 2.0+, after Zircon's
/// acpi_lite): the XSDT's tables, each checksum-validated before use.
/// Shared by the loader and the kernel; it allocates nothing.
public struct AcpiRoot<Memory: PhysicalReader> {
    /// Physical address of the RSDP.
    public let rsdp: UInt64
    let xsdt: UInt64

    public init?(rsdp: UInt64) {
        guard rsdp != 0 else { return nil }
        let xsdt: UInt64? = Memory.withBytes(rsdp, count: 36) { (bytes: RawSpan) -> UInt64? in
            guard bytes.load(fromByteOffset: 0, as: UInt64.self) == 0x2052_5450_2044_5352,  // "RSD PTR "
                  bytes.load(fromByteOffset: 15, as: UInt8.self) >= 2,                     // revision
                  Self.checksum(bytes.extracting(0..<20)) == 0, Self.checksum(bytes) == 0
            else { return nil }
            return bytes.load(fromByteOffset: 24, as: UInt64.self)
        }
        guard let xsdt, Self.validLength(xsdt) != nil else { return nil }
        self.rsdp = rsdp
        self.xsdt = xsdt
    }

    /// Physical address of the first valid table with this signature.
    public func table(_ signature: StaticString) -> UInt64? {
        let wanted = Self.signature(signature)
        guard let length = Self.validLength(xsdt) else { return nil }
        for i in 0..<(Int(length) - 36) / 8 {
            let address = Memory.withBytes(xsdt + 36 + UInt64(i) * 8, count: 8) {
                $0.load(fromByteOffset: 0, as: UInt64.self)
            }
            let found = Memory.withBytes(address, count: 4) { $0.load(fromByteOffset: 0, as: UInt32.self) }
            if found == wanted, Self.validLength(address) != nil {
                return address
            }
        }
        return nil
    }

    /// Runs `body` over the whole (validated) table at `address`.
    public func withTable<R>(_ address: UInt64, _ body: (RawSpan) -> R) -> R {
        let length = Self.validLength(address) ?? 36
        return Memory.withBytes(address, count: Int(length), body)
    }

    /// A table signature's four characters as the header holds them.
    public static func signature(_ text: StaticString) -> UInt32 {
        var value: UInt32 = 0
        text.withUTF8Buffer { bytes in
            for i in 0..<min(4, bytes.count) {
                value |= UInt32(unsafe bytes[i]) << (8 * i)
            }
        }
        return value
    }

    /// The table's length if its header is sane and its checksum is right.
    static func validLength(_ address: UInt64) -> UInt32? {
        let length = Memory.withBytes(address, count: 8) { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard length >= 36, length < 1 << 20 else { return nil }
        return Memory.withBytes(address, count: Int(length)) { checksum($0) } == 0 ? length : nil
    }

    static func checksum(_ bytes: RawSpan) -> UInt8 {
        var sum: UInt8 = 0
        for i in 0..<bytes.byteCount {
            sum &+= bytes.load(fromByteOffset: i, as: UInt8.self)
        }
        return sum
    }
}
