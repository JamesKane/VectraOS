/// A flattened devicetree (the DTB format, devicetree specification §5),
/// read in place: nodes are offsets of their BEGIN_NODE tokens in the
/// structure block, properties are byte ranges of the blob. It allocates
/// nothing, for the loader, which has no heap.
public struct Fdt: ~Escapable {
    public let bytes: RawSpan
    let structStart: Int
    let structEnd: Int
    let stringsStart: Int
    let stringsEnd: Int

    static let beginNode: UInt32 = 1
    static let endNode: UInt32 = 2
    static let prop: UInt32 = 3
    static let nop: UInt32 = 4
    static let end: UInt32 = 9

    /// The blob's size from its header, or nil if `header` (its first 40
    /// bytes or more) isn't a version-17 compatible FDT header.
    public static func totalSize(_ header: RawSpan) -> Int? {
        guard header.byteCount >= 40, be32(header, 0) == 0xd00d_feed, be32(header, 24) <= 17 else { return nil }
        let size = Int(be32(header, 4))
        return size >= 40 ? size : nil
    }

    @_lifetime(copy bytes)
    public init?(_ bytes: RawSpan) {
        guard let size = Self.totalSize(bytes), size <= bytes.byteCount else { return nil }
        let structStart = Int(Self.be32(bytes, 8)), structSize = Int(Self.be32(bytes, 36))
        let stringsStart = Int(Self.be32(bytes, 12)), stringsSize = Int(Self.be32(bytes, 32))
        guard structStart % 4 == 0, structStart <= size, structSize <= size - structStart,
              stringsStart <= size, stringsSize <= size - stringsStart
        else { return nil }
        self.bytes = bytes
        self.structStart = structStart
        self.structEnd = structStart + structSize
        self.stringsStart = stringsStart
        self.stringsEnd = stringsStart + stringsSize
        guard root != nil else { return nil }
    }

    // MARK: Nodes

    /// The root node, after any NOPs.
    public var root: Int? {
        var at = structStart
        while at + 4 <= structEnd, token(at) == Self.nop { at += 4 }
        return at + 4 <= structEnd && token(at) == Self.beginNode ? at : nil
    }

    /// Calls `body` with each child of `node`, in order, until it returns false.
    public func forEachChild(of node: Int, _ body: (Int) -> Bool) {
        guard var at = afterName(node) else { return }
        while at + 4 <= structEnd {
            switch token(at) {
            case Self.prop:
                guard let next = afterProperty(at) else { return }
                at = next
            case Self.nop:
                at += 4
            case Self.beginNode:
                guard body(at), let next = afterNode(at) else { return }
                at = next
            default:
                return  // END_NODE, END or a bad token
            }
        }
    }

    /// The first child of `node` that `body` accepts.
    public func child(of node: Int, where body: (Int) -> Bool) -> Int? {
        var found: Int?
        forEachChild(of: node) { child in
            if body(child) { found = child }
            return found == nil
        }
        return found
    }

    /// The node at an absolute path ("/cpus", "/soc/uart@d4017000"). A
    /// component without a unit address matches a node whose name has one.
    public func node(_ path: StaticString) -> Int? {
        node(count: path.utf8CodeUnitCount) { unsafe path.utf8Start[$0] }
    }

    /// The node at the absolute path in `range` of the blob (a property's
    /// value, such as an alias), without its NUL.
    public func node(atPath range: Range<Int>) -> Int? {
        var end = range.lowerBound
        while end < range.upperBound, byte(end) != 0 { end += 1 }
        return node(count: end - range.lowerBound) { byte(range.lowerBound + $0) }
    }

    private func node(count: Int, _ at: (Int) -> UInt8) -> Int? {
        guard count > 0, at(0) == UInt8(ascii: "/"), var current = root else { return nil }
        var start = 1
        while start < count {
            var stop = start
            while stop < count, at(stop) != UInt8(ascii: "/") { stop += 1 }
            if stop > start {
                let first = start, length = stop - start
                guard let next = child(of: current, where: { nameMatches($0, length: length) { at(first + $0) } })
                else { return nil }
                current = next
            }
            start = stop + 1
        }
        return current
    }

    /// Whether `node`'s name is the `length` bytes `at` gives, or is them
    /// followed by a unit address ("cpu" matches "cpu@0").
    private func nameMatches(_ node: Int, length: Int, _ at: (Int) -> UInt8) -> Bool {
        let name = node + 4
        for i in 0..<length {
            guard name + i < structEnd, byte(name + i) == at(i) else { return false }
        }
        guard name + length < structEnd else { return false }
        let next = byte(name + length)
        return next == 0 || (next == UInt8(ascii: "@") && !hasUnitAddress(length, at))
    }

    private func hasUnitAddress(_ length: Int, _ at: (Int) -> UInt8) -> Bool {
        for i in 0..<length where at(i) == UInt8(ascii: "@") { return true }
        return false
    }

    /// Whether `node`'s name, up to any unit address, is `prefix`.
    public func nameIs(_ node: Int, _ prefix: StaticString) -> Bool {
        nameMatches(node, length: prefix.utf8CodeUnitCount) { unsafe prefix.utf8Start[$0] }
    }

    /// The node whose `phandle` property is `phandle`.
    public func node(phandle: UInt32) -> Int? {
        first { node in
            guard let p = property(node, "phandle") ?? property(node, "linux,phandle"), p.count == 4 else { return false }
            return be32(p.lowerBound) == phandle
        }
    }

    /// The first enabled node whose `compatible` holds `value`.
    public func first(compatible value: StaticString) -> Int? {
        first { contains($0, "compatible", value) && isEnabled($0) }
    }

    /// The first node, in document order, that `body` accepts.
    public func first(where body: (Int) -> Bool) -> Int? {
        var at = structStart
        while at + 4 <= structEnd {
            switch token(at) {
            case Self.beginNode:
                if body(at) { return at }
                guard let next = afterName(at) else { return nil }
                at = next
            case Self.prop:
                guard let next = afterProperty(at) else { return nil }
                at = next
            case Self.endNode, Self.nop:
                at += 4
            default:
                return nil
            }
        }
        return nil
    }

    /// `node`'s parent; nil for the root.
    public func parent(of node: Int) -> Int? {
        guard let root, node != root else { return nil }
        return parent(of: node, under: root, depth: 0)
    }

    private func parent(of node: Int, under candidate: Int, depth: Int) -> Int? {
        guard depth < 32 else { return nil }
        var found: Int?
        forEachChild(of: candidate) { child in
            if child == node {
                found = candidate
            } else if child < node, let end = afterNode(child), node < end {
                found = parent(of: node, under: child, depth: depth + 1)
            }
            return found == nil
        }
        return found
    }

    // MARK: Properties

    /// The value of `node`'s property `name`, as a range of the blob.
    public func property(_ node: Int, _ name: StaticString) -> Range<Int>? {
        guard var at = afterName(node) else { return nil }
        while at + 4 <= structEnd {
            switch token(at) {
            case Self.prop:
                guard at + 12 <= structEnd else { return nil }
                let length = Int(be32(at + 4)), nameOffset = Int(be32(at + 8))
                guard length <= structEnd - (at + 12) else { return nil }
                if stringEquals(stringsStart + nameOffset, name) { return (at + 12)..<(at + 12 + length) }
                at = Self.align4(at + 12 + length)
            case Self.nop:
                at += 4
            default:
                return nil  // properties come before children
            }
        }
        return nil
    }

    /// Calls `body` with each of `node`'s properties, the offset of its
    /// NUL-terminated name and its value's range, until it returns false.
    public func forEachProperty(of node: Int, _ body: (_ name: Int, _ value: Range<Int>) -> Bool) {
        guard var at = afterName(node) else { return }
        while at + 4 <= structEnd {
            switch token(at) {
            case Self.prop:
                guard at + 12 <= structEnd else { return }
                let length = Int(be32(at + 4)), name = stringsStart + Int(be32(at + 8))
                guard length <= structEnd - (at + 12), name < stringsEnd, body(name, (at + 12)..<(at + 12 + length))
                else { return }
                at = Self.align4(at + 12 + length)
            case Self.nop:
                at += 4
            default:
                return
            }
        }
    }

    /// Whether `node` has property `name`.
    public func has(_ node: Int, _ name: StaticString) -> Bool { property(node, name) != nil }

    /// A one-cell property's value.
    public func u32(_ node: Int, _ name: StaticString) -> UInt32? {
        guard let p = property(node, name), p.count == 4 else { return nil }
        return be32(p.lowerBound)
    }

    /// A one- or two-cell property's value.
    public func u64(_ node: Int, _ name: StaticString) -> UInt64? {
        guard let p = property(node, name), p.count == 4 || p.count == 8 else { return nil }
        return cells(p.lowerBound, count: p.count / 4)
    }

    /// `count` (1 or 2) big-endian cells at `at` as one number.
    public func cells(_ at: Int, count: Int) -> UInt64? {
        guard count >= 1, count <= 2, at + 4 * count <= bytes.byteCount else { return nil }
        return count == 1 ? UInt64(be32(at)) : UInt64(be32(at)) << 32 | UInt64(be32(at + 4))
    }

    /// The first (address, size) pair of `node`'s `reg`, in its parent's cells.
    public func reg(_ node: Int) -> (address: UInt64, size: UInt64)? {
        guard let p = property(node, "reg"), let parent = parent(of: node) else { return nil }
        let addressCells = Int(u32(parent, "#address-cells") ?? 2), sizeCells = Int(u32(parent, "#size-cells") ?? 1)
        guard addressCells >= 1, addressCells <= 2, sizeCells <= 2, p.count >= 4 * (addressCells + sizeCells),
              let address = cells(p.lowerBound, count: addressCells)
        else { return nil }
        let size = sizeCells == 0 ? 0 : cells(p.lowerBound + 4 * addressCells, count: sizeCells) ?? 0
        return (address, size)
    }

    /// Whether string property `name` (a list of NUL-terminated strings,
    /// such as `compatible`) holds `value`.
    public func contains(_ node: Int, _ name: StaticString, _ value: StaticString) -> Bool {
        guard let p = property(node, name) else { return false }
        var start = p.lowerBound
        while start < p.upperBound {
            var end = start
            while end < p.upperBound, byte(end) != 0 { end += 1 }
            if end - start == value.utf8CodeUnitCount, stringEquals(start, value) { return true }
            start = end + 1
        }
        return false
    }

    /// Whether `node` is usable: no `status`, or "okay" or "ok".
    public func isEnabled(_ node: Int) -> Bool {
        guard let p = property(node, "status") else { return true }
        return stringEquals(p.lowerBound, "okay") || stringEquals(p.lowerBound, "ok")
    }

    // MARK: Bytes

    public func byte(_ at: Int) -> UInt8 { bytes.load(fromByteOffset: at, as: UInt8.self) }

    public func be32(_ at: Int) -> UInt32 { Self.be32(bytes, at) }

    static func be32(_ bytes: RawSpan, _ at: Int) -> UInt32 {
        UInt32(bigEndian: bytes.load(fromByteOffset: at, as: UInt32.self))
    }

    static func align4(_ value: Int) -> Int { (value + 3) & ~3 }

    func token(_ at: Int) -> UInt32 { be32(at) }

    /// Whether the NUL-terminated string at `at` is `value`.
    func stringEquals(_ at: Int, _ value: StaticString) -> Bool {
        let count = value.utf8CodeUnitCount
        guard at >= 0, at + count < bytes.byteCount else { return false }
        for i in 0..<count {
            let wanted = unsafe value.utf8Start[i]
            if byte(at + i) != wanted { return false }
        }
        return byte(at + count) == 0
    }

    /// Where a BEGIN_NODE's properties start: past the token and its name.
    func afterName(_ node: Int) -> Int? {
        guard node + 4 <= structEnd, token(node) == Self.beginNode else { return nil }
        var at = node + 4
        while at < structEnd, byte(at) != 0 { at += 1 }
        return at < structEnd ? Self.align4(at + 1) : nil
    }

    func afterProperty(_ at: Int) -> Int? {
        guard at + 12 <= structEnd else { return nil }
        let length = Int(be32(at + 4))
        guard length <= structEnd - (at + 12) else { return nil }
        return Self.align4(at + 12 + length)
    }

    /// Just past `node`'s END_NODE.
    func afterNode(_ node: Int) -> Int? {
        var depth = 0
        var at = node
        while at + 4 <= structEnd {
            switch token(at) {
            case Self.beginNode:
                depth += 1
                guard let next = afterName(at) else { return nil }
                at = next
            case Self.endNode:
                depth -= 1
                at += 4
                if depth == 0 { return at }
            case Self.prop:
                guard let next = afterProperty(at) else { return nil }
                at = next
            case Self.nop:
                at += 4
            default:
                return nil
            }
        }
        return nil
    }
}
