// SPDX-License-Identifier: BSD-3-Clause

// A whole machine's description as devmgr takes it (D171): the devices its
// enumeration makes, ACPI's from a board's captured tables or a
// devicetree's from its compiled tree, and the IOMMU units and stream ids
// their masters reach. No second description format (principle 1): this
// is devmgr's own model, loaded by devmgr's own code (Enumeration.swift,
// DeviceTreeBus), and the checks (Checks.swift) read it.
//
// Host only: it reads files and runs the AML interpreter over the tables.

import DevMgr
import DeviceTreeBus
import Fdt
import PCI
import TDACPI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Configuration space nobody backs: AML that reads a PCI function's
/// registers from a captured table gets nothing.
final class NoConfig: ConfigSpace, @unchecked Sendable {
  func read(_ f: FunctionAddress, _ offset: Int, width: Int) -> UInt32 { UInt32.max }
  func write(_ f: FunctionAddress, _ offset: Int, width: Int, _ value: UInt32) {}
}

/// An IOMMU unit a master's stream ids reach.
public struct IOMMUNode: Equatable, Sendable {
  /// Its name: an SMMU's register base, or a tree node's path.
  public var name: String
  /// The device that is the unit in the list (its _CRS holds the register
  /// base, or its node is the one `iommus` names), by path.
  public var device: String?
  /// Its register base where the tables give one (an SMMU's), else 0.
  public var base: UInt64

  public init(name: String, device: String?, base: UInt64 = 0) {
    self.name = name
    self.device = device
    self.base = base
  }
}

/// A master's stream ids on one unit: `first` through `first + count`.
public struct StreamIDs: Equatable, Sendable {
  public var unit: String
  public var first: UInt32
  public var count: UInt32

  public init(unit: String, first: UInt32, count: UInt32) {
    self.unit = unit
    self.first = first
    self.count = count
  }
}

/// A DMA master and the units it is behind: a device's path, or a PCI root
/// complex.
public struct DMAMaster: Equatable, Sendable {
  public var name: String
  /// The device in the list, where the name is one's path.
  public var device: String?
  public var streams: [StreamIDs]

  public init(name: String, device: String?, streams: [StreamIDs]) {
    self.name = name
    self.device = device
    self.streams = streams
  }
}

/// Memory a board rule grants a device's host past its own ranges (the
/// Sky1's SCMI agent's TF-A shared memory, FirmwareCall.rule).
public struct FirmwareRange: Equatable, Sendable {
  public var device: String
  public var base: UInt64
  public var size: UInt64

  public init(device: String, base: UInt64, size: UInt64) {
    self.device = device
    self.base = base
    self.size = size
  }
}

public struct Board: Sendable {
  public var name: String
  public var devices: [Device]
  public var units: [IOMMUNode]
  public var masters: [DMAMaster]
  public var firmware: [FirmwareRange]
  /// Nodes that provide something and are no device: a tree's fixed clocks,
  /// where a chain of providers ends.
  public var roots: [String]

  public init(name: String, devices: [Device], units: [IOMMUNode] = [], masters: [DMAMaster] = [],
              firmware: [FirmwareRange] = [], roots: [String] = []) {
    self.roots = roots
    self.name = name
    self.devices = devices
    self.units = units
    self.masters = masters
    self.firmware = firmware
  }
}

public enum BoardError: Error, CustomStringConvertible {
  case unreadable(String)
  case noTables(String)
  case badTree(String)
  public var description: String {
    switch self {
    case .unreadable(let p): "can't read \(p)"
    case .noTables(let p): "no ACPI tables in \(p)"
    case .badTree: "not a flattened devicetree"
    }
  }
}

// MARK: Files

/// The names in a directory, sorted, without the dot entries.
public func directoryNames(_ path: String) -> [String] {
  guard let d = unsafe opendir(path) else { return [] }
  defer { unsafe closedir(d) }
  var out: [String] = []
  while let e = unsafe readdir(d) {
    let name = unsafe withUnsafePointer(to: &e.pointee.d_name) {
      unsafe $0.withMemoryRebound(to: CChar.self, capacity: 256) { unsafe String(cString: $0) }
    }
    if !name.hasPrefix(".") { out.append(name) }
  }
  return out.sorted()
}

public func isDirectory(_ path: String) -> Bool {
  var st = unsafe stat()
  return unsafe stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}

/// A file's bytes, nil where it can't be read.
public func fileBytes(_ path: String) -> [UInt8]? {
  guard let f = unsafe fopen(path, "rb") else { return nil }
  defer { unsafe fclose(f) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 1 << 16)
  while true {
    let n = unsafe chunk.withUnsafeMutableBytes { unsafe fread($0.baseAddress, 1, $0.count, f) }
    if n <= 0 { break }
    out += chunk[0..<n]
  }
  return out
}

/// Every file under `path` named `name`, by path.
public func findFiles(named name: String, under path: String) -> [String] {
  var out: [String] = []
  for entry in directoryNames(path) {
    let full = path + "/" + entry
    if isDirectory(full) {
      out += findFiles(named: name, under: full)
    } else if entry == name {
      out.append(full)
    }
  }
  return out
}

/// The repository's root, found from `file` (a path inside it): the
/// directory that holds Package.swift.
public func repositoryRoot(from file: String) -> String? {
  var parts = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  while !parts.isEmpty {
    parts.removeLast()
    let dir = parts.joined(separator: "/")
    if fileBytes(dir + "/Package.swift") != nil { return dir }
  }
  return nil
}

// MARK: The index

extension DriverIndex {
  /// Every `driver.manifest` under `root`/drivers, as devmgr's index reads
  /// them (bootfs's etc/drivers is the same files, one after another).
  public static func load(root: String) throws -> DriverIndex {
    var text = ""
    for file in findFiles(named: "driver.manifest", under: root + "/drivers").sorted() {
      guard let b = fileBytes(file) else { throw BoardError.unreadable(file) }
      text += String(decoding: b, as: UTF8.self)
      if !text.hasSuffix("\n") { text += "\n" }
    }
    do throws(IndexError) { return try DriverIndex(text: text, file: "etc/drivers") } catch { throw BoardError.badTree("\(error)") }
  }
}

// MARK: ACPI

extension Board {
  /// A board from its captured tables (`vx acpi`): `directory` holds a
  /// file a table, named by its signature (DSDT, SSDT1, IORT...).
  /// devmgr's enumeration runs over them; firmware's own memory isn't
  /// captured, so a region AML reads from it is unhandled, as `vx acpi`'s
  /// tests leave it.
  public static func acpi(name: String, directory: String) throws -> Board {
    var tables: [Table] = []
    for file in directoryNames(directory) where file != "PROVENANCE" && file != "memory" && !file.hasSuffix(".tsv") {
      guard let b = fileBytes(directory + "/" + file) else { throw BoardError.unreadable(file) }
      if let t = try? Table(b) { tables.append(t) }
    }
    let set = TableSet(tables)
    guard set.dsdt != nil else { throw BoardError.noTables(directory) }
    let host = MachineHost<NoConfig>(readMemory: { _, _ in nil }, writeMemory: { _, _, _ in false }, readPort: nil,
                                     writePort: nil, config: nil)
    let found = loadNamespace(set, host: host, unknownStatus: 0x0F)
    var board = Board(name: name, devices: found.devices.map { Device(acpi: $0) })
    let oemID = set.fadt?.table.oemID ?? [], oemTableID = set.fadt?.table.oemTableID ?? []
    for d in found.devices {
      if let call = FirmwareCall.rule(oemID: oemID, oemTableID: oemTableID, hid: d.hid) {
        board.firmware.append(FirmwareRange(device: d.path, base: call.memory, size: call.size))
      }
    }
    guard let iort = set.table(IORT.signature).flatMap({ try? IORT($0) }) else { return board }
    for s in iort.smmus where s.version == 3 {
      let unit = hex(s.registerBase)
      let holder = found.devices.first { d in
        d.resources.contains { r in
          if case .mmio(let base, let size) = r { return s.registerBase >= base && s.registerBase < base &+ size }
          return false
        }
      }
      board.units.append(IOMMUNode(name: unit, device: holder?.path, base: s.registerBase))
    }
    for m in iort.masters where !m.streams.isEmpty {
      let device = m.segment == nil ? found.devices.first { samePath($0.path, m.name) }?.path : nil
      let label = m.segment.map { "pci-segment-\($0)@\(m.offset)" } ?? m.name
      board.masters.append(DMAMaster(name: label, device: device, streams: m.streams.map {
        StreamIDs(unit: hex($0.smmu), first: $0.outputBase, count: $0.count)
      }))
    }
    return board
  }
}

public func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

/// Two ACPI paths name the same node: segment by segment, each padded to
/// four characters with `_`, the root's `\` and a leading `^` aside.
public func samePath(_ a: String, _ b: String) -> Bool { segments(a) == segments(b) }

func segments(_ path: String) -> [[UInt8]] {
  var bytes = Array(path.utf8)
  while bytes.first == UInt8(ascii: "\\") { bytes.removeFirst() }
  return bytes.split(separator: UInt8(ascii: ".")).map { s in
    var seg = Array(s)
    while seg.count < 4 { seg.append(UInt8(ascii: "_")) }
    return seg
  }
}

// MARK: Devicetree

extension Board {
  /// A board from its compiled devicetree. `coherentByDefault` is the
  /// arch's: RISC-V's.
  public static func tree(name: String, dtb: [UInt8], coherentByDefault: Bool) throws -> Board {
    let devices: [TreeDevice]? = dtb.span.bytes.withUnsafeBytes { raw in
      guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
      return DeviceTreeBus.devices(t, coherentByDefault: coherentByDefault)
    }
    guard let devices else { throw BoardError.badTree(name) }
    var board = Board(name: name, devices: devices.map { Device(dt: $0) })
    board.roots = dtb.span.bytes.withUnsafeBytes { raw in
      guard let t = Fdt(RawSpan(_unsafeBytes: raw)), let root = t.root else { return [] }
      var out: [String] = []
      collectRoots(t, root, path: "", &out, depth: 0)
      return out
    }
    for d in devices {
      var streams: [StreamIDs] = []
      for i in d.iommus {
        if !board.units.contains(where: { $0.name == i.unit }) {
          board.units.append(IOMMUNode(name: i.unit, device: devices.first { $0.path == i.unit }?.path))
        }
        streams.append(StreamIDs(unit: i.unit, first: i.id.first ?? 0, count: 0))
      }
      if !streams.isEmpty { board.masters.append(DMAMaster(name: d.path, device: d.path, streams: streams)) }
    }
    return board
  }
}

/// The paths of the nodes under `node` that are fixed clocks.
func collectRoots(_ t: borrowing Fdt, _ node: Int, path: String, _ out: inout [String], depth: Int) {
  guard depth < 32 else { return }
  var child = t.firstChild(of: node)
  while let c = child {
    child = t.nextSibling(of: c)
    var name: [UInt8] = []
    for i in t.name(of: c) { name.append(t.byte(i)) }
    let here = path + "/" + String(decoding: name, as: UTF8.self)
    if t.isEnabled(c), t.contains(c, "compatible", "fixed-clock") { out.append(here) }
    collectRoots(t, c, path: here, &out, depth: depth + 1)
  }
}
