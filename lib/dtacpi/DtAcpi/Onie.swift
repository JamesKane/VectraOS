/// A board's network addresses as an ONIE TlvInfo EEPROM holds them
/// (D154: what only firmware knows): the Orange Pi RV2's U-Boot reads them
/// from one and puts them in no tree, so the loader reads it itself. The
/// block is `TlvInfo\0`, a version, a big-endian length, then that many
/// bytes of type-length-value entries ending with a CRC-32 (type 0xFE)
/// over everything before its value; type 0x24 is the base MAC address
/// and 0x2A how many consecutive addresses the board has.
public enum Onie {
    /// The base address and the count (1 where the block gives none),
    /// from a block whose header and CRC check; nil otherwise, or for a
    /// zero or multicast base.
    public static func addresses(_ block: Span<UInt8>) -> NetworkAddresses? {
        let magic: StaticString = "TlvInfo"
        guard block.count >= 11 else { return nil }
        for i in 0..<7 {
            let expected = unsafe magic.utf8Start[i]
            if block[i] != expected { return nil }
        }
        guard block[7] == 0, block[8] == 1 else { return nil }
        let length = Int(block[9]) << 8 | Int(block[10])
        guard 11 + length <= block.count else { return nil }
        var base: InlineArray<6, UInt8>? = nil
        var count = 1
        var checked = false
        var at = 11
        while at + 2 <= 11 + length {
            let type = block[at], size = Int(block[at + 1])
            let value = at + 2
            guard value + size <= 11 + length else { return nil }
            switch type {
            case 0x24 where size == 6:
                var b = InlineArray<6, UInt8>(repeating: 0)
                for i in 0..<6 { b[i] = block[value + i] }
                base = b
            case 0x2A where size == 2:
                count = Int(block[value]) << 8 | Int(block[value + 1])
            case 0xFE where size == 4:
                let stored = UInt32(block[value]) << 24 | UInt32(block[value + 1]) << 16
                    | UInt32(block[value + 2]) << 8 | UInt32(block[value + 3])
                checked = crc32(block, count: value) == stored
            default: ()
            }
            at = value + size
        }
        guard checked, let base, count > 0 else { return nil }
        var any = false
        for i in 0..<6 where base[i] != 0 { any = true }
        guard any, base[0] & 1 == 0 else { return nil }
        return NetworkAddresses(base: base, count: count)
    }

    /// CRC-32 (IEEE 802.3, reflected) of the first `count` bytes.
    static func crc32(_ bytes: Span<UInt8>, count: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for i in 0..<count {
            crc ^= UInt32(bytes[i])
            for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// A board's consecutive network addresses: `ethernet<N>` takes the
/// base plus N, for N below the count.
public struct NetworkAddresses: Sendable {
    public var base: InlineArray<6, UInt8>
    public var count: Int

    public init(base: InlineArray<6, UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    /// The base plus `n`, as a 48-bit number.
    public func address(_ n: Int) -> InlineArray<6, UInt8> {
        var value: UInt64 = 0
        for i in 0..<6 { value = value << 8 | UInt64(base[i]) }
        value &+= UInt64(n)
        var out = InlineArray<6, UInt8>(repeating: 0)
        for i in 0..<6 { out[i] = UInt8(truncatingIfNeeded: value >> UInt64(40 - 8 * i)) }
        return out
    }
}
