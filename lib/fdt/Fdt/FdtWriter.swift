/// Writes a flattened devicetree (the DTB format, devicetree specification
/// §5, version 17) into a buffer the caller gives each call: the header, an
/// empty memory reservation block, then the structure block front to back.
/// Property names collect at the buffer's end, each once, and `finish`
/// moves them in after the structure block. It allocates nothing, for the
/// loader (D154) as well as `vx dtc`.
///
/// A call that doesn't fit, or out of order (a property after a child, an
/// END_NODE with no node open), sets `failed`, and every call after it does
/// nothing; `finish` then returns nil.
public struct FdtWriter {
    static let headerSize = 40
    let capacity: Int
    /// The structure block's end so far.
    var at = FdtWriter.headerSize + 16
    /// The names' start: they grow down from `capacity`.
    var names: Int
    var depth = 0
    /// Whether the open node has had a child (no property may follow).
    var hadChild = false
    public private(set) var failed = false

    public init(capacity: Int) {
        self.capacity = capacity
        names = capacity
        failed = capacity < at + 4
    }

    /// Opens a node; the root's name is empty.
    public mutating func beginNode(_ name: RawSpan, into out: inout MutableRawSpan) {
        guard !failed, depth > 0 || at == Self.headerSize + 16 else { return fail() }
        let size = Self.align4(4 + name.byteCount + 1)
        guard room(size, out) else { return fail() }
        put32(&out, at, Fdt.beginNode)
        for i in 0..<name.byteCount { out.storeBytes(of: name.load(fromByteOffset: i, as: UInt8.self), toByteOffset: at + 4 + i, as: UInt8.self) }
        for i in (4 + name.byteCount)..<size { out.storeBytes(of: 0, toByteOffset: at + i, as: UInt8.self) }
        at += size
        depth += 1
        hadChild = false
    }

    /// A property of the open node: `value` as given (cells big-endian, as
    /// the caller wrote them).
    public mutating func property(_ name: RawSpan, _ value: RawSpan, into out: inout MutableRawSpan) {
        guard !failed, depth > 0, !hadChild else { return fail() }
        guard let offset = nameOffset(name, &out) else { return fail() }
        let size = 12 + Self.align4(value.byteCount)
        guard room(size, out) else { return fail() }
        put32(&out, at, Fdt.prop)
        put32(&out, at + 4, UInt32(value.byteCount))
        put32(&out, at + 8, UInt32(offset))  // from the buffer's end until `finish`
        for i in 0..<value.byteCount { out.storeBytes(of: value.load(fromByteOffset: i, as: UInt8.self), toByteOffset: at + 12 + i, as: UInt8.self) }
        for i in (12 + value.byteCount)..<size { out.storeBytes(of: 0, toByteOffset: at + i, as: UInt8.self) }
        at += size
    }

    /// Closes the open node.
    public mutating func endNode(into out: inout MutableRawSpan) {
        guard !failed, depth > 0, room(4, out) else { return fail() }
        put32(&out, at, Fdt.endNode)
        at += 4
        depth -= 1
        hadChild = true
    }

    /// Ends the tree: the END token, the names moved after it, the header.
    /// Returns the blob's size (from the buffer's start), or nil.
    public mutating func finish(bootCpu: UInt32 = 0, into out: inout MutableRawSpan) -> Int? {
        guard !failed, depth == 0, at > Self.headerSize + 16, room(4, out) else {
            fail()
            return nil
        }
        put32(&out, at, Fdt.end)
        at += 4
        let structStart = Self.headerSize + 16, structSize = at - structStart
        // Each property's name offset, from the buffer's end, becomes one
        // from the strings block's start.
        var cursor = structStart
        while cursor < at - 4 {
            switch get32(out, cursor) {
            case Fdt.beginNode:
                cursor += 4
                while get8(out, cursor) != 0 { cursor += 1 }
                cursor = Self.align4(cursor + 1)
            case Fdt.prop:
                let length = Int(get32(out, cursor + 4)), fromEnd = Int(get32(out, cursor + 8))
                put32(&out, cursor + 8, UInt32(capacity - fromEnd - names))
                cursor += 12 + Self.align4(length)
            default:
                cursor += 4
            }
        }
        let stringsSize = capacity - names
        for i in 0..<stringsSize { out.storeBytes(of: get8(out, names + i), toByteOffset: at + i, as: UInt8.self) }
        let total = at + stringsSize
        for i in 0..<16 { out.storeBytes(of: 0, toByteOffset: Self.headerSize + i, as: UInt8.self) }  // no reservations
        put32(&out, 0, 0xd00d_feed)
        put32(&out, 4, UInt32(total))
        put32(&out, 8, UInt32(structStart))
        put32(&out, 12, UInt32(at))
        put32(&out, 16, UInt32(Self.headerSize))
        put32(&out, 20, 17)
        put32(&out, 24, 16)
        put32(&out, 28, bootCpu)
        put32(&out, 32, UInt32(stringsSize))
        put32(&out, 36, UInt32(structSize))
        return total
    }

    // MARK: Names

    /// `name`'s offset from the buffer's end, written below the names
    /// already there unless one of them is it.
    private mutating func nameOffset(_ name: RawSpan, _ out: inout MutableRawSpan) -> Int? {
        var start = names
        while start < capacity {
            var end = start
            while end < capacity, get8(out, end) != 0 { end += 1 }
            if end - start == name.byteCount {
                var same = true
                for i in 0..<name.byteCount where get8(out, start + i) != name.load(fromByteOffset: i, as: UInt8.self) { same = false }
                if same { return capacity - start }
            }
            start = end + 1
        }
        guard names - (name.byteCount + 1) >= at + 16 else { return nil }  // room for an END and more
        names -= name.byteCount + 1
        for i in 0..<name.byteCount { out.storeBytes(of: name.load(fromByteOffset: i, as: UInt8.self), toByteOffset: names + i, as: UInt8.self) }
        out.storeBytes(of: 0, toByteOffset: names + name.byteCount, as: UInt8.self)
        return capacity - names
    }

    // MARK: Bytes

    private func room(_ size: Int, _ out: borrowing MutableRawSpan) -> Bool {
        at + size + 4 <= names && names <= out.byteCount
    }

    private mutating func fail() { failed = true }

    static func align4(_ value: Int) -> Int { (value + 3) & ~3 }

    private func put32(_ out: inout MutableRawSpan, _ at: Int, _ value: UInt32) {
        out.storeBytes(of: value.bigEndian, toByteOffset: at, as: UInt32.self)
    }

    private func get32(_ out: borrowing MutableRawSpan, _ at: Int) -> UInt32 {
        UInt32(bigEndian: out.bytes.load(fromByteOffset: at, as: UInt32.self))
    }

    private func get8(_ out: borrowing MutableRawSpan, _ at: Int) -> UInt8 {
        out.bytes.load(fromByteOffset: at, as: UInt8.self)
    }
}
