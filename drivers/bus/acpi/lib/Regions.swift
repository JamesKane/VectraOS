// SPDX-License-Identifier: BSD-3-Clause

// Operation regions and field units (ACPI 6.5 §5.5.2.4, §19.6.48 Field,
// §19.6.65 IndexField, §19.6.7 BankField). A field is read and written in
// access units of its access width, each unit through the host's handler
// for the region's space; bits of a unit outside the field are kept,
// written as ones or as zeros by its update rule.

/// One access a region makes of the system.
public struct RegionAccess: Equatable, Sendable {
  /// The region's address space (§19.6.98): 0 SystemMemory, 1 SystemIO,
  /// 2 PCI_Config, 3 EmbeddedControl, 5 SystemCMOS, 6 PciBarTarget...
  public var space: UInt8
  /// The region's base plus the unit's offset. For PCI_Config, the offset
  /// in the function's configuration space.
  public var address: UInt64
  /// Bytes: 1, 2, 4 or 8.
  public var width: Int
  /// For PCI_Config: segment, bus, device and function (§6.5.6, _ADR).
  public var pci: PCIAddress?
}

public struct PCIAddress: Equatable, Sendable {
  public var segment: UInt16
  public var bus: UInt8
  public var device: UInt8
  public var function: UInt8
}

/// By default a host handles no region: an access aborts the method.
extension ACPIHost {
  public func readRegion(_ access: RegionAccess) -> UInt64? { nil }
  public func writeRegion(_ access: RegionAccess, _ value: UInt64) -> Bool { false }
}

/// A region's evaluated place.
struct RegionBounds {
  var space: UInt8
  var base: UInt64
  var length: UInt64
  var pci: PCIAddress?
}

extension Machine {
  /// A region's space, base and length, evaluated the first time (§19.6.98:
  /// its offset and length are TermArgs), then kept in its data.
  mutating func bounds(_ node: Int, _ ns: inout Namespace) throws(ACPIError) -> RegionBounds {
    guard case .region(let space, let offset, let length) = ns.nodes[node].object else { throw ACPIError.typeMismatch }
    var base: UInt64, size: UInt64
    if case .package(let p)? = ns.data[node], p.elements.count == 2, let b = p.elements[0].integer,
      let s = p.elements[1].integer
    {
      (base, size) = (b, s)
    } else {
      guard !evaluating.contains(node) else { throw ACPIError.recursive }
      evaluating.append(node)
      defer { evaluating.removeLast() }
      base = try integerValue(try datum(offset, &ns), &ns)
      size = try integerValue(try datum(length, &ns), &ns)
      ns.data[node] = .package(PackageObject([.integer(base), .integer(size)]))
    }
    return RegionBounds(space: space, base: base, length: size, pci: space == 2 ? try pciAddress(node, &ns) : nil)
  }

  /// A PCI_Config region's function (§6.5.6): device and function from the
  /// enclosing device's _ADR; segment and bus from the root bridge's _SEG
  /// and _BBN (zero if absent). Bridges between are taken as the root's
  /// bus, as firmware regions in practice sit on the root's devices.
  mutating func pciAddress(_ region: Int, _ ns: inout Namespace) throws(ACPIError) -> PCIAddress {
    var device = ns.nodes[region].parent
    while device > 0, ns.nodes[device].object != .device { device = ns.nodes[device].parent }
    var address = PCIAddress(segment: 0, bus: 0, device: 0, function: 0)
    if device > 0, let adr = try optionalInteger("_ADR", under: device, &ns) {
      address.device = UInt8(truncatingIfNeeded: adr >> 16)
      address.function = UInt8(truncatingIfNeeded: adr)
    }
    var n = device
    while n > 0 {
      if let bbn = try optionalInteger("_BBN", under: n, &ns) {
        address.bus = UInt8(truncatingIfNeeded: bbn)
        address.segment = UInt16(truncatingIfNeeded: try optionalInteger("_SEG", under: n, &ns) ?? 0)
        break
      }
      n = ns.nodes[n].parent
    }
    return address
  }

  mutating func optionalInteger(_ name: StaticString, under node: Int, _ ns: inout Namespace) throws(ACPIError) -> UInt64? {
    guard let child = ns.child(node, NameSeg.make(name)) else { return nil }
    return try integerValue(try call(child, [], &ns), &ns)
  }

  /// The access width of a field, in bytes: its AccessType (§19.6.48),
  /// or, for AnyAcc, the smallest aligned unit that holds the whole field
  /// (bytes if none does).
  func accessWidth(_ f: Field) throws(ACPIError) -> Int {
    switch f.flags & 0x0F {
    case 1: return 1
    case 2: return 2
    case 3: return 4
    case 4: return 8
    case 0:
      let first = Int(f.bitOffset) / 8, last = (Int(f.bitOffset) + Int(f.bitLength) - 1) / 8
      for w in [1, 2, 4, 8] where first / w == last / w { return w }
      return 1
    default: throw ACPIError.unsupported  // BufferAcc: SMBus, GenericSerialBus, IPMI...
    }
  }

  /// One access unit of a field: the `unit`th of `width` bytes, counted
  /// from the start of what the field lies in.
  mutating func readUnit(_ f: Field, _ unit: Int, _ width: Int, _ ns: inout Namespace) throws(ACPIError) -> UInt64 {
    switch f.source {
    case .region(let path):
      return try regionRead(try regionNode(path, f.scope, ns), unit * width, width, &ns)
    case .bank(let region, let bank, let value):
      try storeNamed(try datum(value, &ns), try node(bank, f.scope, ns), &ns)
      return try regionRead(try regionNode(region, f.scope, ns), unit * width, width, &ns)
    case .index(let index, let data):
      // The index register takes the unit's byte offset; the data register
      // then holds the unit (§19.6.65).
      try storeNamed(.integer(UInt64(unit * width)), try node(index, f.scope, ns), &ns)
      return try integerValue(try readNamed(try node(data, f.scope, ns), &ns), &ns)
    }
  }

  mutating func writeUnit(_ f: Field, _ unit: Int, _ width: Int, _ value: UInt64, _ ns: inout Namespace)
    throws(ACPIError)
  {
    switch f.source {
    case .region(let path):
      try regionWrite(try regionNode(path, f.scope, ns), unit * width, width, value, &ns)
    case .bank(let region, let bank, let bankValue):
      try storeNamed(try datum(bankValue, &ns), try node(bank, f.scope, ns), &ns)
      try regionWrite(try regionNode(region, f.scope, ns), unit * width, width, value, &ns)
    case .index(let index, let data):
      try storeNamed(.integer(UInt64(unit * width)), try node(index, f.scope, ns), &ns)
      try storeNamed(.integer(value), try node(data, f.scope, ns), &ns)
    }
  }

  func node(_ path: NamePath, _ scope: Int, _ ns: Namespace) throws(ACPIError) -> Int {
    guard let n = ns.resolve(path, from: scope) else { throw ACPIError.notFound }
    return n
  }

  func regionNode(_ path: NamePath, _ scope: Int, _ ns: Namespace) throws(ACPIError) -> Int {
    let n = try node(path, scope, ns)
    guard case .region = ns.nodes[n].object else { throw ACPIError.typeMismatch }
    return n
  }

  mutating func regionRead(_ region: Int, _ offset: Int, _ width: Int, _ ns: inout Namespace) throws(ACPIError) -> UInt64 {
    let b = try bounds(region, &ns)
    guard UInt64(offset + width) <= b.length || b.length == 0 else { throw ACPIError.outOfBounds }
    let access = RegionAccess(space: b.space, address: b.base &+ UInt64(offset), width: width, pci: b.pci)
    guard let v = host.readRegion(access) else { throw ACPIError.unsupported }
    return width == 8 ? v : v & ((1 << UInt64(8 * width)) - 1)
  }

  mutating func regionWrite(_ region: Int, _ offset: Int, _ width: Int, _ value: UInt64, _ ns: inout Namespace)
    throws(ACPIError)
  {
    let b = try bounds(region, &ns)
    guard UInt64(offset + width) <= b.length || b.length == 0 else { throw ACPIError.outOfBounds }
    let access = RegionAccess(space: b.space, address: b.base &+ UInt64(offset), width: width, pci: b.pci)
    guard host.writeRegion(access, value) else { throw ACPIError.unsupported }
  }

  /// A field unit read: an integer if it fits one, else a buffer (§19.3.5.7).
  mutating func readField(_ node: Int, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    guard case .field(let f) = ns.nodes[node].object else { throw ACPIError.typeMismatch }
    guard f.bitLength > 0 else { return .integer(0) }
    guard f.bitLength <= 1 << 20 else { throw ACPIError.tooLarge }
    fieldDepth += 1
    defer { fieldDepth -= 1 }
    guard fieldDepth < 16 else { throw ACPIError.recursive }
    let width = try accessWidth(f)
    let unitBits = width * 8
    let start = Int(f.bitOffset), length = Int(f.bitLength)
    var out = [UInt8](repeating: 0, count: (length + 7) / 8)
    for unit in (start / unitBits)...((start + length - 1) / unitBits) {
      let v = try readUnit(f, unit, width, &ns)
      let unitStart = unit * unitBits
      for bit in max(start, unitStart)..<min(start + length, unitStart + unitBits)
      where (v >> UInt64(bit - unitStart)) & 1 != 0 {
        out[(bit - start) / 8] |= 1 << UInt8((bit - start) % 8)
      }
    }
    if length <= ns.integerBits {
      var v: UInt64 = 0
      for (i, byte) in out.enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
      return .integer(v)
    }
    return .buffer(BufferObject(out))
  }

  /// A field unit write: whole units written outright; a unit the field
  /// covers part of has its other bits kept (Preserve: read first),
  /// written as ones, or as zeros, by the update rule.
  mutating func writeField(_ node: Int, _ source: [UInt8], _ ns: inout Namespace) throws(ACPIError) {
    guard case .field(let f) = ns.nodes[node].object else { throw ACPIError.typeMismatch }
    guard f.bitLength > 0 else { return }
    guard f.bitLength <= 1 << 20 else { throw ACPIError.tooLarge }
    fieldDepth += 1
    defer { fieldDepth -= 1 }
    guard fieldDepth < 16 else { throw ACPIError.recursive }
    let width = try accessWidth(f)
    let unitBits = width * 8
    let start = Int(f.bitOffset), length = Int(f.bitLength)
    for unit in (start / unitBits)...((start + length - 1) / unitBits) {
      let unitStart = unit * unitBits
      let from = max(start, unitStart), to = min(start + length, unitStart + unitBits)
      var v: UInt64
      if to - from == unitBits {
        v = 0
      } else {
        switch (f.flags >> 5) & 3 {
        case 1: v = UInt64.max  // WriteAsOnes
        case 2: v = 0  // WriteAsZeros
        default: v = try readUnit(f, unit, width, &ns)  // Preserve
        }
      }
      for bit in from..<to {
        let k = bit - start
        let set = k / 8 < source.count && source[k / 8] & (1 << UInt8(k % 8)) != 0
        let mask: UInt64 = 1 << UInt64(bit - unitStart)
        if set { v |= mask } else { v &= ~mask }
      }
      try writeUnit(f, unit, width, width == 8 ? v : v & ((1 << UInt64(unitBits)) - 1), &ns)
    }
  }
}

extension Namespace {
  /// Every operation region, with its space, base and length evaluated
  /// (those that won't evaluate are left out): what `td acpi import`
  /// snapshots.
  public mutating func regions<H: ACPIHost>(host: H) -> [(node: Int, space: UInt8, base: UInt64, length: UInt64)] {
    var m = Machine(host: host, self)
    m.push(Self.root, nil, &self)
    var out: [(node: Int, space: UInt8, base: UInt64, length: UInt64)] = []
    for n in 0..<nodes.count where isLive(n) {
      guard case .region = nodes[n].object else { continue }
      m.frames[0].scope = nodes[n].parent
      if let b = try? m.bounds(n, &self) { out.append((n, b.space, b.base, b.length)) }
    }
    return out
  }
}
