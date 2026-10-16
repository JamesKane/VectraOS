/// A bootfs image (Zircon's format, vx mkbootfs): a header (magic,
/// directory size), directory entries (name length with its NUL, data
/// length, page-aligned data offset, name; each padded to 4 bytes), then
/// the files. Lookups read only through bounds-checked loads.
public enum Bootfs {
    static var magic: UInt32 { 0xA56D_3FF9 }
    static var pageSize: UInt64 { 4096 }

    public struct File {
        /// From the start of the image; page aligned.
        public let offset: UInt64
        public let length: UInt64

        public init(offset: UInt64, length: UInt64) {
            self.offset = offset
            self.length = length
        }
    }

    public enum Error: Swift.Error {
        case badHeader
        case badEntry
        case notFound
    }

    /// The file named `name` (UTF-8, no NUL) in `image`.
    public static func find(_ name: Span<UInt8>, in image: RawSpan) throws(Error) -> File {
        guard let magic = read(UInt32.self, image, 0), magic == Self.magic,
              let size = read(UInt32.self, image, 4), 16 + UInt64(size) <= UInt64(image.byteCount) else {
            throw .badHeader
        }
        var at: UInt64 = 16
        let end = 16 + UInt64(size)
        while at < end {
            guard at + 12 <= end,
                  let nameLength = read(UInt32.self, image, at),
                  let dataLength = read(UInt32.self, image, at + 4),
                  let dataOffset = read(UInt32.self, image, at + 8),
                  nameLength >= 1, nameLength <= 256, at + 12 + UInt64(nameLength) <= end else {
                throw .badEntry
            }
            if Int(nameLength) - 1 == name.count, matches(name, image, at: at + 12) {
                guard UInt64(dataOffset) % pageSize == 0,
                      UInt64(dataOffset) + UInt64(dataLength) <= UInt64(image.byteCount) else { throw .badEntry }
                return File(offset: UInt64(dataOffset), length: UInt64(dataLength))
            }
            at += (12 + UInt64(nameLength) + 3) & ~3
        }
        throw .notFound
    }

    /// Every file in `image`, its name (UTF-8, no NUL) and where it is: the
    /// launcher's programs and manifests.
    public static func entries(in image: RawSpan) throws(Error) -> [(name: [UInt8], file: File)] {
        guard let magic = read(UInt32.self, image, 0), magic == Self.magic,
              let size = read(UInt32.self, image, 4), 16 + UInt64(size) <= UInt64(image.byteCount) else {
            throw .badHeader
        }
        var out: [(name: [UInt8], file: File)] = []
        var at: UInt64 = 16
        let end = 16 + UInt64(size)
        while at < end {
            guard at + 12 <= end,
                  let nameLength = read(UInt32.self, image, at),
                  let dataLength = read(UInt32.self, image, at + 4),
                  let dataOffset = read(UInt32.self, image, at + 8),
                  nameLength >= 1, nameLength <= 256, at + 12 + UInt64(nameLength) <= end,
                  UInt64(dataOffset) % pageSize == 0,
                  UInt64(dataOffset) + UInt64(dataLength) <= UInt64(image.byteCount) else {
                throw .badEntry
            }
            var name: [UInt8] = []
            for i in 0..<Int(nameLength) - 1 { name.append(image.load(fromByteOffset: Int(at) + 12 + i, as: UInt8.self)) }
            out.append((name, File(offset: UInt64(dataOffset), length: UInt64(dataLength))))
            at += (12 + UInt64(nameLength) + 3) & ~3
        }
        return out
    }

    private static func matches(_ name: Span<UInt8>, _ image: RawSpan, at offset: UInt64) -> Bool {
        for i in name.indices where image.load(fromByteOffset: Int(offset) + i, as: UInt8.self) != name[i] {
            return false
        }
        return true
    }

    private static func read<T: FixedWidthInteger & ConvertibleFromBytes>(_: T.Type, _ image: RawSpan,
                                                                          _ offset: UInt64) -> T? {
        guard offset <= UInt64(image.byteCount), UInt64(image.byteCount) - offset >= UInt64(MemoryLayout<T>.size) else {
            return nil
        }
        return T(littleEndian: image.load(fromByteOffset: Int(offset), as: T.self))
    }
}
