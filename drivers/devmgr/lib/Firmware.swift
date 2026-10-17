// SPDX-License-Identifier: BSD-3-Clause

// The machine as devmgr's AML interpreter sees it (M3h): physical memory a
// page at a time (croi refuses a VMO only partly over firmware memory, and
// maps firmware memory cached and the rest as devices), I/O ports
// requested as AML first touches them, and PCI configuration space over
// ECAM. `MachineHost` is TDACPI's host over them: SystemMemory,
// SystemIO and PCI_Config regions, the timer, sleeps and _OSI. Memory is
// read and written through the runtime's accessors (croi/mmio.h, D74).

import PCI
import Sys
import TDACPI
import CroiMMIO

/// Physical memory through pages mapped as first touched, under devmgr's
/// MMIO ranged root (which stays its owner's), kept for the process's life.
public final class PhysicalMemory: @unchecked Sendable {
  final class Page {
    let base: UInt64
    let mapping: Mapping
    init(base: UInt64, mapping: consuming Mapping) {
      self.base = base
      self.mapping = mapping
    }
  }

  let root: UInt32
  let lock = Lock()
  /// By base, ascending.
  var pages: [Page] = []
  /// Pages croi refused, not asked again.
  var refused: [UInt64] = []

  public init(mmioRoot: UInt32) { root = mmioRoot }

  public var mappedPages: Int { lock.withLock { pages.count } }

  /// The page holding `address`, mapped; nil if croi refuses it (RAM).
  func page(_ address: UInt64) -> Page? {
    let base = address & ~4095
    return lock.withLock { () -> Page? in
      var lo = 0, hi = pages.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if pages[mid].base < base { lo = mid + 1 } else { hi = mid }
      }
      if lo < pages.count, pages[lo].base == base { return pages[lo] }
      if refused.contains(base) { return nil }
      guard let mapping = try? map(base) else {
        refused.append(base)
        return nil
      }
      let page = Page(base: base, mapping: mapping)
      pages.insert(page, at: lo)
      return page
    }
  }

  func map(_ base: UInt64) throws(Status) -> Mapping {
    let parent = Handle(raw: root)
    let resource: Handle
    do throws(Status) {
      resource = try Sys.Resource.create(parent: parent, kind: .mmio, base: base, size: 4096, name: "acpi")
    } catch {
      _ = parent.release()
      throw error
    }
    _ = parent.release()
    return try VMO.map(try VMO.physical(resource: resource, address: base, size: 4096), length: 4096)
  }

  /// `count` bytes from `address` (firmware tables), or nil if any page is refused.
  public func bytes(_ address: UInt64, _ count: Int) -> [UInt8]? {
    var out: [UInt8] = []
    out.reserveCapacity(count)
    var at = address
    while out.count < count {
      guard let p = page(at) else { return nil }
      let offset = Int(at - p.base), n = min(4096 - offset, count - out.count)
      for i in 0..<n { out.append(load(p, offset + i, 1).map { UInt8(truncatingIfNeeded: $0) } ?? 0xFF) }
      at += UInt64(n)
    }
    return out
  }

  /// A read of 1, 2, 4 or 8 bytes; one crossing a page is read a byte at a time.
  public func read(_ address: UInt64, width: Int) -> UInt64? {
    if Int(address & 4095) + width > 4096 {
      var v: UInt64 = 0
      for i in 0..<width {
        guard let b = read(address + UInt64(i), width: 1) else { return nil }
        v |= b << (8 * UInt64(i))
      }
      return v
    }
    guard let p = page(address) else { return nil }
    return load(p, Int(address - p.base), width)
  }

  public func write(_ address: UInt64, width: Int, _ value: UInt64) -> Bool {
    if Int(address & 4095) + width > 4096 {
      for i in 0..<width where !write(address + UInt64(i), width: 1, value >> (8 * UInt64(i))) { return false }
      return true
    }
    guard let p = page(address) else { return false }
    let at = unsafe UInt64(UInt(bitPattern: p.mapping.address)) + (address - p.base)
    switch width {
    case 1: croi_mmio_write8(at, UInt8(truncatingIfNeeded: value))
    case 2: croi_mmio_write16(at, UInt16(truncatingIfNeeded: value))
    case 4: croi_mmio_write32(at, UInt32(truncatingIfNeeded: value))
    case 8: croi_mmio_write64(at, value)
    default: return false
    }
    return true
  }

  func load(_ p: Page, _ offset: Int, _ width: Int) -> UInt64? {
    let at = unsafe UInt64(UInt(bitPattern: p.mapping.address)) + UInt64(offset)
    switch width {
    case 1: return UInt64(croi_mmio_read8(at))
    case 2: return UInt64(croi_mmio_read16(at))
    case 4: return UInt64(croi_mmio_read32(at))
    case 8: return croi_mmio_read64(at)
    default: return nil
    }
  }
}

/// I/O ports (amd64), each range requested under devmgr's IOPORT ranged
/// root the first time AML touches it. croi refuses some (the 8259s, its
/// console's UART): an access there fails, as an unhandled region does.
public final class PortSpace: @unchecked Sendable {
  let root: UInt32
  let lock = Lock()
  var granted: [(base: UInt16, count: UInt16, resource: UInt32)] = []

  public init(ioportRoot: UInt32) { root = ioportRoot }

  deinit { for g in granted { close(raw: g.resource) } }

  func open(_ port: UInt16, _ width: Int) -> Bool {
    lock.withLock { () -> Bool in
      if granted.contains(where: { port >= $0.base && Int(port) + width <= Int($0.base) + Int($0.count) }) { return true }
      let parent = Handle(raw: root)
      let made = try? Sys.Resource.create(parent: parent, kind: .ioport, base: UInt64(port), size: UInt64(width),
                                          name: "acpi")
      _ = parent.release()
      guard let made else { return false }
      guard (try? IOPorts.request(made, base: port, count: UInt16(width))) != nil else { return false }
      granted.append((port, UInt16(width), made.release()))
      return true
    }
  }

  public func read(_ port: UInt16, width: Int) -> UInt32? {
    guard open(port, width) else { return nil }
    return IOPorts.read(port, width: width)
  }

  public func write(_ port: UInt16, width: Int, _ value: UInt32) -> Bool {
    guard open(port, width) else { return false }
    IOPorts.write(port, width: width, value)
    return true
  }
}

/// TDACPI's host in devmgr: regions over the machine, the monotonic clock
/// as the Timer, _OSI as Windows claims it (OSInterfaces), and Debug,
/// Notify and Fatal kept as lines for devmgr's tree.
public final class MachineHost<Config: ConfigSpace>: ACPIHost, @unchecked Sendable {
  public typealias MemoryRead = (_ address: UInt64, _ width: Int) -> UInt64?
  public typealias MemoryWrite = (_ address: UInt64, _ width: Int, _ value: UInt64) -> Bool
  public typealias PortRead = (_ port: UInt16, _ width: Int) -> UInt32?
  public typealias PortWrite = (_ port: UInt16, _ width: Int, _ value: UInt32) -> Bool

  let readMemory: MemoryRead
  let writeMemory: MemoryWrite
  let readPort: PortRead?
  let writePort: PortWrite?
  let config: Config?
  let lock = Lock()
  var lines: [String] = []

  public init(readMemory: @escaping MemoryRead, writeMemory: @escaping MemoryWrite, readPort: PortRead?,
              writePort: PortWrite?, config: Config?)
  {
    self.readMemory = readMemory
    self.writeMemory = writeMemory
    self.readPort = readPort
    self.writePort = writePort
    self.config = config
  }

  /// Debug stores, notifications and fatal errors, in order.
  public var log: [String] { lock.withLock { lines } }

  func note(_ line: String) { lock.withLock { lines.append(line) } }

  public func supportsInterface(_ name: [UInt8]) -> Bool { OSInterfaces.claims(name) }
  public func sleep(milliseconds: UInt64) { Sys.sleep(until: Clock.monotonic() + Int64(milliseconds) * 1_000_000) }
  public func stall(microseconds: UInt64) {
    let end = Clock.monotonic() + Int64(microseconds) * 1000
    while Clock.monotonic() < end {}
  }
  public func notify(_ node: Int, _ value: UInt64) { note("notify \(node) \(value)") }
  public func timer() -> UInt64 { UInt64(Clock.monotonic() / 100) }
  public func debug(_ text: [UInt8]) { note("debug " + String(decoding: text, as: UTF8.self)) }
  public func fatal(type: UInt8, code: UInt32, argument: UInt64) { note("fatal \(type) \(code) \(argument)") }

  public func readRegion(_ access: RegionAccess) -> UInt64? {
    switch access.space {
    case 0: return readMemory(access.address, access.width)
    case 1:
      guard let readPort, access.address <= 0xFFFF, access.width <= 4 else { return nil }
      return readPort(UInt16(access.address), access.width).map { UInt64($0) }
    case 2:
      guard let config, let at = functionAddress(access), access.width <= 4 else { return nil }
      return UInt64(config.read(at, Int(access.address), width: access.width))
    default: return nil
    }
  }

  public func writeRegion(_ access: RegionAccess, _ value: UInt64) -> Bool {
    switch access.space {
    case 0: return writeMemory(access.address, access.width, value)
    case 1:
      guard let writePort, access.address <= 0xFFFF, access.width <= 4 else { return false }
      return writePort(UInt16(access.address), access.width, UInt32(truncatingIfNeeded: value))
    case 2:
      guard let config, let at = functionAddress(access), access.width <= 4 else { return false }
      config.write(at, Int(access.address), width: access.width, UInt32(truncatingIfNeeded: value))
      return true
    default: return false
    }
  }

  func functionAddress(_ access: RegionAccess) -> FunctionAddress? {
    guard let p = access.pci, access.address < 4096 else { return nil }
    return FunctionAddress(segment: p.segment, bus: p.bus, device: p.device, function: p.function)
  }
}

extension ACPIError {
  /// The case's name, for devmgr's tree (TDACPI keeps strings out; Embedded
  /// Swift can't print an enum).
  public var name: String {
    switch self {
    case .truncated: "truncated"
    case .badSignature: "bad signature"
    case .badChecksum: "bad checksum"
    case .missingTable: "missing table"
    case .malformed(let at): "malformed at \(at)"
    case .unknownOpcode(let op, let at): "unknown opcode \(op) at \(at)"
    case .tooDeep: "too deep"
    case .notFound: "not found"
    case .typeMismatch: "type mismatch"
    case .uninitialized: "uninitialized"
    case .divideByZero: "divide by zero"
    case .outOfBounds: "out of bounds"
    case .callTooDeep: "calls too deep"
    case .loopLimit: "loop limit"
    case .misplacedBreak: "misplaced break"
    case .unsupported: "unsupported (an unhandled region access)"
    case .mutexOrder: "mutex order"
    case .badResourceTemplate: "bad resource template"
    case .stepLimit: "step limit"
    case .tooLarge: "too large"
    case .tooManyObjects: "too many objects"
    case .recursive: "recursive"
    }
  }
}

/// The RSDP's physical address: the boot data's ACPI_RSDP item (zbi.h),
/// read through a mapping of the boot data VMO.
public func rsdpAddress(bootData: borrowing Handle) -> UInt64? {
  guard let size = try? VMO.size(bootData), let m = try? VMO.map(bootData, length: size, writable: false) else {
    return nil
  }
  let header = 32
  var at = header  // past the container's own
  while at + header <= size {
    let type = m.load(UInt32.self, at: at)
    let length = Int(m.load(UInt32.self, at: at + 4))
    if type == 0x5044_5352, length == 8, at + header + 8 <= size { return m.load(UInt64.self, at: at + header) }  // "RSDP"
    at += header + ((length + 7) & ~7)
  }
  return nil
}

/// A segment's ECAM, each bus's 1 MiB mapped (uncached, as device memory)
/// the first time it is touched, under devmgr's MMIO ranged root (which
/// stays its owner's): a 256-bus window mapped at once took 145 ms under
/// arm64's TCG (V2 7b). A bus that can't be mapped reads as all ones.
public final class ECAMWindows: ConfigSpace, @unchecked Sendable {
  final class Bus {
    let number: UInt8
    let mapping: Mapping
    let ecam: ECAM
    init(number: UInt8, mapping: consuming Mapping) {
      self.number = number
      ecam = unsafe ECAM(unsafe: mapping.address, segment: 0, startBus: number, endBus: number)
      self.mapping = mapping
    }
  }

  let root: UInt32
  /// Bus 0's physical address (the MCFG's base), and the buses decoded.
  public let base: UInt64
  public let startBus: UInt8
  public let endBus: UInt8
  let lock = Lock()
  var buses: [Bus] = []
  var refused: [UInt8] = []

  public init(mmioRoot: UInt32, base: UInt64, startBus: UInt8, endBus: UInt8) {
    root = mmioRoot
    self.base = base
    self.startBus = startBus
    self.endBus = endBus
  }

  /// How many buses have been mapped.
  public var mappedBuses: Int { lock.withLock { buses.count } }

  func bus(_ number: UInt8) -> ECAM? {
    guard number >= startBus, number <= endBus else { return nil }
    return lock.withLock { () -> ECAM? in
      if let b = buses.first(where: { $0.number == number }) { return b.ecam }
      if refused.contains(number) { return nil }
      guard let mapping = try? map(number) else {
        refused.append(number)
        return nil
      }
      let b = Bus(number: number, mapping: mapping)
      buses.append(b)
      return b.ecam
    }
  }

  func map(_ number: UInt8) throws(Status) -> Mapping {
    let address = base + UInt64(ECAM.offset(bus: Int(number), device: 0, function: 0))
    let size = ECAM.size(buses: 1)
    let parent = Handle(raw: root)  // the caller's
    let resource: Handle
    do throws(Status) {
      resource = try Sys.Resource.create(parent: parent, kind: .mmio, base: address, size: UInt64(size), name: "ecam")
    } catch {
      _ = parent.release()
      throw error
    }
    _ = parent.release()
    let vmo = try VMO.physical(resource: resource, address: address, size: size)
    try VMO.setCachePolicy(vmo, .uncachedDevice)
    return try VMO.map(vmo, length: size)
  }

  public func read(_ f: FunctionAddress, _ offset: Int, width: Int) -> UInt32 {
    guard f.segment == 0, let ecam = bus(f.bus) else { return UInt32.max >> (32 - 8 * min(max(width, 1), 4)) }
    return ecam.read(f, offset, width: width)
  }

  public func write(_ f: FunctionAddress, _ offset: Int, width: Int, _ value: UInt32) {
    guard f.segment == 0, let ecam = bus(f.bus) else { return }
    ecam.write(f, offset, width: width, value)
  }
}
