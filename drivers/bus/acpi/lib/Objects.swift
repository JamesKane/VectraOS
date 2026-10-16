// SPDX-License-Identifier: BSD-3-Clause

// What AML code works with at run time (ACPI 6.5 §19.3.5): integers,
// strings, buffers, packages and references. Buffers and packages are
// shared objects: Index and RefOf hand out references into them, and a
// store through one changes the object every holder sees. Store copies
// them (§19.3.5.8); reading a name hands out the object itself.

/// A buffer's bytes, shared by everything that refers to it.
public final class BufferObject {
  public var bytes: [UInt8]
  public init(_ bytes: [UInt8]) { self.bytes = bytes }
}

/// A package's elements, shared likewise.
public final class PackageObject {
  public var elements: [Datum]
  public init(_ elements: [Datum]) { self.elements = elements }
}

/// Where a reference points (§19.6.112 RefOf, §19.6.62 Index).
public enum Reference {
  /// A named object.
  case node(Int)
  /// A method's LocalX or ArgX, in the call with this serial number.
  case local(Int, frame: Int)
  case arg(Int, frame: Int)
  /// An element of a package.
  case element(PackageObject, Int)
  /// A byte of a buffer (Index on a buffer: a one-byte buffer field).
  case byte(BufferObject, Int)
}

/// An AML object at run time.
public enum Datum {
  case uninitialized
  case integer(UInt64)
  case string([UInt8])
  case buffer(BufferObject)
  case package(PackageObject)
  case reference(Reference)
  /// A named object that isn't data (a device, mutex, region, method...),
  /// as an operand: Notify's target, ObjectType's subject, a package's name.
  case object(Int)
  /// Bits of a buffer, made by CreateField and its kin (§19.6.18).
  case bufferField(BufferObject, bitOffset: Int, bitLength: Int)

  /// ObjectType's code (§19.6.96, Table 19.36) for a datum.
  var typeCode: UInt64 {
    switch self {
    case .uninitialized: 0
    case .integer: 1
    case .string: 2
    case .buffer: 3
    case .package: 4
    case .bufferField: 14
    case .reference, .object: 0  // resolved by the caller
    }
  }
}

/// A copy, for Store (§19.3.5.8): new buffers and packages (elements
/// copied likewise), references and objects as they are.
func copied(_ d: Datum) -> Datum {
  switch d {
  case .buffer(let b): .buffer(BufferObject(b.bytes))
  case .package(let p): .package(PackageObject(p.elements.map { copied($0) }))
  default: d
  }
}

/// What the interpreter asks of the system it runs in: devmgr natively,
/// a fake in tests. Operation regions are `readRegion` and `writeRegion`
/// (Regions.swift), which a host gives for the spaces it handles.
public protocol ACPIHost: AnyObject {
  /// `_OSI (name)`: whether the OS claims this interface (§5.7.2).
  func supportsInterface(_ name: [UInt8]) -> Bool
  /// Sleep (milliseconds; may yield) and Stall (microseconds; busy).
  func sleep(milliseconds: UInt64)
  func stall(microseconds: UInt64)
  /// Notify (§5.6.6): the node and the notification value.
  func notify(_ node: Int, _ value: UInt64)
  /// The Timer opcode: a monotonic count of 100 ns units (§19.6.135).
  func timer() -> UInt64
  /// A store to Debug (§19.6.26), as text.
  func debug(_ text: [UInt8])
  /// Fatal (§19.6.46): the OS logs it and shuts down in good time.
  func fatal(type: UInt8, code: UInt32, argument: UInt64)
  /// An operation region access (Regions.swift): the value read, or nil
  /// if the host has no handler for it.
  func readRegion(_ access: RegionAccess) -> UInt64?
  /// Whether the write was handled.
  func writeRegion(_ access: RegionAccess, _ value: UInt64) -> Bool
}
