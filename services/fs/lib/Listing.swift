// SPDX-License-Identifier: BSD-3-Clause

// A directory's whole listing in a VMO (Directory.wholeListing, M6m part m4:
// a 100k-entry folder listed and sorted warm in under 100 ms). Batched
// listings are 256 entries a call, each encoded and decoded; the whole
// listing, built once by the service while the directory is unchanged and
// read by the client in one copy, is packed records in the reader's
// layout (little-endian):
//
//     0   magic     UInt32  "TDLS"
//     4   count     UInt32  entries
//     8   names     UInt32  attribute names (those asked for, in order)
//     12  bytes     UInt32  where the byte area starts
//     16  length    UInt64  bytes used in all
//     24  entries   count × 40:  node u64, size u64, modified i64,
//                   name (offset u32, length u32 into the byte area),
//                   first attribute u32, attributes u16, kind u8, 0
//     ... attributes   12 each: name's index u16, kind u8, 0,
//                   value (offset u32, length u32)
//     ... names    names × 8: offset u32, length u32
//     bytes ...
//
// Each attribute is in the fs IPC's encoding (FsService.encode's kind and
// value). Building and reading allocate a few arrays, not one per entry.

public enum ListingVMO {
  public static let magic: UInt32 = 0x534C_4454  // "TDLS"
  static let headerSize = 24
  static let entrySize = 40
  static let attributeSize = 12

  /// Builds a listing's bytes.
  public struct Builder {
    var entries: [UInt8] = []
    var attributes: [UInt8] = []
    var bytes: [UInt8] = []
    var count = 0
    var attributeCount = 0
    let names: [String]

    public init(names: [String], capacity: Int = 0) {
      self.names = names
      entries.reserveCapacity(capacity * ListingVMO.entrySize)
      bytes.reserveCapacity(capacity * 16)
    }

    static func put<T: FixedWidthInteger>(_ v: T, _ out: inout [UInt8]) {
      var x = v.littleEndian
      for _ in 0..<MemoryLayout<T>.size {
        out.append(UInt8(truncatingIfNeeded: x))
        x >>= 8
      }
    }

    mutating func text(_ s: some Collection<UInt8>) -> (UInt32, UInt32) {
      let at = UInt32(bytes.count)
      bytes.append(contentsOf: s)
      return (at, UInt32(s.count))
    }

    /// One entry; its attributes those of `names` it has, as (index into
    /// `names`, kind, value).
    public mutating func add(name: some Collection<UInt8>, node: UInt64, kind: UInt8, size: UInt64, modified: Int64,
                             attributes: [(name: Int, kind: UInt8, value: [UInt8])])
    {
      let (at, length) = text(name)
      Self.put(node, &entries)
      Self.put(size, &entries)
      Self.put(modified, &entries)
      Self.put(at, &entries)
      Self.put(length, &entries)
      Self.put(UInt32(attributeCount), &entries)
      Self.put(UInt16(attributes.count), &entries)
      entries.append(kind)
      entries.append(0)
      for a in attributes {
        let (vat, vlength) = text(a.value)
        Self.put(UInt16(a.name), &self.attributes)
        self.attributes.append(a.kind)
        self.attributes.append(0)
        Self.put(vat, &self.attributes)
        Self.put(vlength, &self.attributes)
      }
      attributeCount += attributes.count
      count += 1
    }

    /// The listing's bytes, whole.
    public mutating func finish() -> [UInt8] {
      var nameTable: [UInt8] = []
      for n in names {
        let (at, length) = text(Array(n.utf8))
        Self.put(at, &nameTable)
        Self.put(length, &nameTable)
      }
      let start = ListingVMO.headerSize + entries.count + attributes.count + nameTable.count
      let byteStart = (start + 7) & ~7
      var out: [UInt8] = []
      out.reserveCapacity(byteStart + bytes.count)
      Self.put(ListingVMO.magic, &out)
      Self.put(UInt32(count), &out)
      Self.put(UInt32(names.count), &out)
      Self.put(UInt32(byteStart), &out)
      Self.put(UInt64(byteStart + bytes.count), &out)
      out += entries
      out += attributes
      out += nameTable
      out.append(contentsOf: repeatElement(0, count: byteStart - start))
      out += bytes
      return out
    }
  }

  /// A listing's bytes, read: checked once, then each entry's fields at
  /// their offsets.
  public struct Reader {
    public let bytes: [UInt8]
    public let count: Int
    let nameCount: Int
    let byteStart: Int
    let attributeStart: Int
    let nameStart: Int

    public init?(_ bytes: [UInt8]) {
      guard bytes.count >= ListingVMO.headerSize, Self.get(bytes, 0, UInt32.self) == ListingVMO.magic else { return nil }
      count = Int(Self.get(bytes, 4, UInt32.self))
      nameCount = Int(Self.get(bytes, 8, UInt32.self))
      byteStart = Int(Self.get(bytes, 12, UInt32.self))
      attributeStart = ListingVMO.headerSize + count * ListingVMO.entrySize
      guard Int(Self.get(bytes, 16, UInt64.self)) <= bytes.count, attributeStart <= byteStart, byteStart <= bytes.count
      else { return nil }
      // The attributes' count: the last entry's first and count.
      var attributes = 0
      if count > 0 {
        let last = ListingVMO.headerSize + (count - 1) * ListingVMO.entrySize
        attributes = Int(Self.get(bytes, last + 32, UInt32.self)) + Int(Self.get(bytes, last + 36, UInt16.self))
      }
      nameStart = attributeStart + attributes * ListingVMO.attributeSize
      guard nameStart + nameCount * 8 <= byteStart else { return nil }
      self.bytes = bytes
      // Every entry's ranges inside the byte area, and its attributes
      // inside theirs.
      for i in 0..<count {
        let e = ListingVMO.headerSize + i * ListingVMO.entrySize
        guard inBytes(e + 24), Int(Self.get(bytes, e + 32, UInt32.self)) + Int(Self.get(bytes, e + 36, UInt16.self)) <= attributes
        else { return nil }
      }
      for a in 0..<attributes {
        let r = attributeStart + a * ListingVMO.attributeSize
        guard Int(Self.get(bytes, r, UInt16.self)) < nameCount, inBytes(r + 4) else { return nil }
      }
      for n in 0..<nameCount where !inBytes(nameStart + n * 8) { return nil }
    }

    static func get<T: FixedWidthInteger>(_ b: [UInt8], _ at: Int, _: T.Type) -> T {
      var v: T = 0
      for i in 0..<MemoryLayout<T>.size { v |= T(truncatingIfNeeded: b[at + i]) << (8 * i) }
      return v
    }

    /// Whether the (offset, length) at `at` lies in the byte area.
    func inBytes(_ at: Int) -> Bool {
      let o = Int(Self.get(bytes, at, UInt32.self)), n = Int(Self.get(bytes, at + 4, UInt32.self))
      return byteStart + o + n <= bytes.count
    }

    func range(_ at: Int) -> Range<Int> {
      let o = byteStart + Int(Self.get(bytes, at, UInt32.self))
      return o..<(o + Int(Self.get(bytes, at + 4, UInt32.self)))
    }

    public struct Entry {
      public var name: Range<Int>
      public var node: UInt64
      public var kind: UInt8
      public var size: UInt64
      public var modified: Int64
      public var attributes: Range<Int>
    }

    public func entry(_ i: Int) -> Entry {
      let e = ListingVMO.headerSize + i * ListingVMO.entrySize
      let first = Int(Self.get(bytes, e + 32, UInt32.self))
      return Entry(name: range(e + 24), node: Self.get(bytes, e, UInt64.self), kind: bytes[e + 38],
                   size: Self.get(bytes, e + 8, UInt64.self), modified: Self.get(bytes, e + 16, Int64.self),
                   attributes: first..<(first + Int(Self.get(bytes, e + 36, UInt16.self))))
    }

    /// Attribute `a`: its name's index, kind and value.
    public func attribute(_ a: Int) -> (name: Int, kind: UInt8, value: Range<Int>) {
      let r = attributeStart + a * ListingVMO.attributeSize
      return (Int(Self.get(bytes, r, UInt16.self)), bytes[r + 2], range(r + 4))
    }

    /// The attribute names, as asked for.
    public var names: [String] {
      (0..<nameCount).map { n in String(decoding: bytes[range(nameStart + n * 8)], as: UTF8.self) }
    }
  }
}
