// SPDX-License-Identifier: BSD-3-Clause

// Finding a segment's functions (PCI Local Bus 3.0 §6.1-6.2; PCI-to-PCI
// Bridge 1.2 §3.2): every device on a bus, every function of a
// multi-function one, and the buses behind bridges, numbered as firmware
// left them. Each function's identity, its BARs sized (§6.2.5.1: write all
// ones, read back the mask, restore, with decoding off meanwhile) and its
// capability list (§6.7).

/// A base address register's window.
public struct BAR: Equatable, Sendable {
  public enum Space: Equatable, Sendable { case memory, io }
  /// Its register: 0-5 (a 64-bit BAR takes the next one too).
  public var index: Int
  public var space: Space
  public var address: UInt64
  public var size: UInt64
  public var is64: Bool
  public var prefetchable: Bool

  public init(index: Int, space: Space, address: UInt64, size: UInt64, is64: Bool = false, prefetchable: Bool = false) {
    self.index = index
    self.space = space
    self.address = address
    self.size = size
    self.is64 = is64
    self.prefetchable = prefetchable
  }
}

/// A capability: its id (§6.7, Appendix H: 0x05 MSI, 0x09 vendor, 0x10 PCI
/// Express, 0x11 MSI-X) and where it is in configuration space.
public struct Capability: Equatable, Sendable {
  public var id: UInt8
  public var offset: Int
  public init(id: UInt8, offset: Int) {
    self.id = id
    self.offset = offset
  }
}

/// A function as enumeration found it.
public struct Function: Equatable, Sendable {
  public var address: FunctionAddress
  public var vendor: UInt16
  public var device: UInt16
  public var classCode: UInt8
  public var subclass: UInt8
  public var progIF: UInt8
  public var revision: UInt8
  /// Without the multi-function bit: 0 a device, 1 a PCI-to-PCI bridge.
  public var headerType: UInt8
  public var subsystemVendor: UInt16
  public var subsystem: UInt16
  /// 0 none, 1-4 INTA#-INTD#.
  public var interruptPin: UInt8
  public var bars: [BAR]
  public var capabilities: [Capability]
  /// A bridge's secondary bus.
  public var secondaryBus: UInt8?

  public init(address: FunctionAddress, vendor: UInt16, device: UInt16, classCode: UInt8, subclass: UInt8,
              progIF: UInt8, revision: UInt8, headerType: UInt8, subsystemVendor: UInt16, subsystem: UInt16,
              interruptPin: UInt8, bars: [BAR], capabilities: [Capability], secondaryBus: UInt8?)
  {
    self.address = address
    self.vendor = vendor
    self.device = device
    self.classCode = classCode
    self.subclass = subclass
    self.progIF = progIF
    self.revision = revision
    self.headerType = headerType
    self.subsystemVendor = subsystemVendor
    self.subsystem = subsystem
    self.interruptPin = interruptPin
    self.bars = bars
    self.capabilities = capabilities
    self.secondaryBus = secondaryBus
  }

  /// `bb:dd.f vvvv:dddd class cc.ss.pp`.
  public var description: String {
    address.description + " " + hex(UInt32(vendor), digits: 4) + ":" + hex(UInt32(device), digits: 4) + " class "
      + hex(UInt32(classCode), digits: 2) + "." + hex(UInt32(subclass), digits: 2) + "." + hex(UInt32(progIF), digits: 2)
  }

  public func capability(_ id: UInt8) -> Capability? { capabilities.first { $0.id == id } }
}

/// Every function in `config`'s segment reachable from `bus` (a root
/// bus), in address order. Bridges' secondary buses are followed once
/// each, so a firmware loop can't hang it.
public func enumerate<C: ConfigSpace>(_ config: C, segment: UInt16 = 0, bus: UInt8 = 0) -> [Function] {
  var found: [Function] = []
  var visited: [UInt8] = []
  var pending: [UInt8] = [bus]
  while let b = pending.popLast() {
    if visited.contains(b) { continue }
    visited.append(b)
    for device in UInt8(0)..<32 {
      let first = FunctionAddress(segment: segment, bus: b, device: device, function: 0)
      guard config.read16(first, Register.vendor) != 0xFFFF else { continue }
      let multi = config.read8(first, Register.headerType) & 0x80 != 0
      for function in UInt8(0)..<(multi ? 8 : 1) {
        let at = FunctionAddress(segment: segment, bus: b, device: device, function: function)
        guard let f = probe(config, at) else { continue }
        found.append(f)
        if let secondary = f.secondaryBus, secondary > b { pending.append(secondary) }
      }
    }
  }
  found.sort { $0.address < $1.address }
  return found
}

/// The function at `at`, or nil if there is none.
public func probe<C: ConfigSpace>(_ config: C, _ at: FunctionAddress) -> Function? {
  let vendor = config.read16(at, Register.vendor)
  guard vendor != 0xFFFF else { return nil }
  let header = config.read8(at, Register.headerType) & 0x7F
  let isDevice = header == 0
  var f = Function(
    address: at, vendor: vendor, device: config.read16(at, Register.device),
    classCode: config.read8(at, Register.classCode), subclass: config.read8(at, Register.subclass),
    progIF: config.read8(at, Register.progIF), revision: config.read8(at, Register.revision), headerType: header,
    subsystemVendor: isDevice ? config.read16(at, Register.subsystemVendor) : 0,
    subsystem: isDevice ? config.read16(at, Register.subsystem) : 0,
    interruptPin: header <= 1 ? config.read8(at, Register.interruptPin) : 0, bars: [], capabilities: [],
    secondaryBus: header == 1 ? config.read8(at, Register.secondaryBus) : nil)
  if header <= 1 { f.bars = sizeBARs(config, at, count: isDevice ? 6 : 2) }
  f.capabilities = capabilities(config, at)
  return f
}

/// The function's BARs, sized with decoding off so that no window moves
/// under a live device meanwhile; the command register is restored.
public func sizeBARs<C: ConfigSpace>(_ config: C, _ at: FunctionAddress, count: Int) -> [BAR] {
  let command = config.read16(at, Register.command)
  config.write16(at, Register.command, command & ~(Command.io | Command.memory))
  defer { config.write16(at, Register.command, command) }
  var bars: [BAR] = []
  var i = 0
  while i < count {
    let offset = Register.bar0 + 4 * i
    let original = config.read32(at, offset)
    config.write32(at, offset, 0xFFFF_FFFF)
    let mask = config.read32(at, offset)
    config.write32(at, offset, original)
    if original & 1 == 1 {
      // I/O space: bits 2-31 (the top 16 may read as zero).
      let size = UInt64((~(mask & 0xFFFF_FFFC) &+ 1) & 0xFFFF)
      if mask != 0 && size != 0 {
        bars.append(BAR(index: i, space: .io, address: UInt64(original & 0xFFFF_FFFC), size: size))
      }
      i += 1
      continue
    }
    let is64 = (original >> 1) & 3 == 2
    var address = UInt64(original & 0xFFFF_FFF0)
    var fullMask = UInt64(mask & 0xFFFF_FFF0) | (is64 ? 0 : 0xFFFF_FFFF_0000_0000)
    if is64, i + 1 < count {
      let high = config.read32(at, offset + 4)
      config.write32(at, offset + 4, 0xFFFF_FFFF)
      let highMask = config.read32(at, offset + 4)
      config.write32(at, offset + 4, high)
      address |= UInt64(high) << 32
      fullMask |= UInt64(highMask) << 32
    }
    if mask & 0xFFFF_FFF0 != 0 || (is64 && fullMask >> 32 != 0) {
      let size = ~fullMask &+ 1
      bars.append(BAR(index: i, space: .memory, address: address, size: size, is64: is64,
                      prefetchable: original & 8 != 0))
    }
    i += is64 ? 2 : 1
  }
  return bars
}

/// The capability list, if the status register says there is one; at most
/// 48 entries (the space holds no more), so a looped list ends.
public func capabilities<C: ConfigSpace>(_ config: C, _ at: FunctionAddress) -> [Capability] {
  guard config.read16(at, Register.status) & 0x10 != 0 else { return [] }
  var list: [Capability] = []
  var next = Int(config.read8(at, Register.capabilities) & 0xFC)
  while next >= 0x40, list.count < 48 {
    list.append(Capability(id: config.read8(at, next), offset: next))
    next = Int(config.read8(at, next + 1) & 0xFC)
  }
  return list
}
