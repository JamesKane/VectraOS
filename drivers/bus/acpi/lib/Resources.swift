// SPDX-License-Identifier: BSD-3-Clause

// Resource templates (ACPI 6.5 §6.4): what _CRS, _PRS and the like return,
// a buffer of small and large descriptors ending in an end tag.

/// Where a descriptor's resource comes from: an index and the path of the
/// device that provides it (§6.4.3.5.1).
public struct ResourceSource: Equatable, Sendable {
  public var index: UInt8
  public var path: [UInt8]
}

/// Word, DWord, QWord and Extended Address Space descriptors, widened.
public struct AddressSpace: Equatable, Sendable {
  /// 0 memory, 1 I/O, 2 bus number range, 192-255 vendor-defined.
  public var kind: UInt8
  /// Bit 0 consumer (else producer), 1 decode subtractive, 2 minimum
  /// fixed, 3 maximum fixed.
  public var generalFlags: UInt8
  /// The kind's own flags (cacheability and writability for memory...).
  public var typeFlags: UInt8
  public var granularity: UInt64
  public var minimum: UInt64
  public var maximum: UInt64
  public var translation: UInt64
  public var length: UInt64
  public var source: ResourceSource?
}

/// A GPIO Connection descriptor (§6.4.3.8.1).
public struct GPIOConnection: Equatable, Sendable {
  /// 0 interrupt, 1 I/O.
  public var type: UInt8
  public var generalFlags: UInt16
  /// Interrupt: mode, polarity, sharing, wake; I/O: restriction, sharing.
  public var flags: UInt16
  public var pinConfig: UInt8
  public var outputDrive: UInt16
  public var debounce: UInt16
  public var pins: [UInt16]
  public var source: [UInt8]
  public var vendor: [UInt8]
}

/// A Generic Serial Bus Connection descriptor (§6.4.3.8.2): I²C, SPI,
/// UART or CSI-2, with its type's fields kept as they come.
public struct SerialBusConnection: Equatable, Sendable {
  /// 1 I²C, 2 SPI, 3 UART, 4 CSI-2.
  public var type: UInt8
  public var generalFlags: UInt8
  public var typeFlags: UInt16
  public var typeRevision: UInt8
  /// The type's data: I²C speed (4) and address (2); SPI speed (4), data
  /// bits, phase, polarity, device select (2); UART baud (4), FIFOs...
  public var typeData: [UInt8]
  public var source: [UInt8]
}

/// One resource descriptor.
public enum Resource: Equatable, Sendable {
  case irq(mask: UInt16, flags: UInt8)
  case dma(mask: UInt8, flags: UInt8)
  case startDependent(priority: UInt8?)
  case endDependent
  case io(decode16: Bool, minimum: UInt16, maximum: UInt16, alignment: UInt8, length: UInt8)
  case fixedIO(base: UInt16, length: UInt8)
  case fixedDMA(request: UInt16, channel: UInt16, width: UInt8)
  case memory24(writable: Bool, minimum: UInt32, maximum: UInt32, alignment: UInt32, length: UInt32)
  case memory32(writable: Bool, minimum: UInt32, maximum: UInt32, alignment: UInt32, length: UInt32)
  case memory32Fixed(writable: Bool, base: UInt32, length: UInt32)
  case genericRegister(space: UInt8, bitWidth: UInt8, bitOffset: UInt8, accessSize: UInt8, address: UInt64)
  case address(AddressSpace)
  case extendedIRQ(flags: UInt8, interrupts: [UInt32], source: ResourceSource?)
  case gpio(GPIOConnection)
  case serialBus(SerialBusConnection)
  case vendor([UInt8])
  /// Pin function, configuration and groups, clock input: kept whole,
  /// with the large type (0x8D-0x93).
  case other(type: UInt8, [UInt8])
}

public enum Resources {
  /// The descriptors in a resource template, up to its end tag, which
  /// must be there; a nonzero end-tag checksum must make the bytes sum to
  /// zero (§6.4.2.9).
  public static func decode(_ b: [UInt8]) throws(ACPIError) -> [Resource] {
    var out: [Resource] = []
    var at = 0
    func need(_ n: Int) throws(ACPIError) { guard at + n <= b.count else { throw ACPIError.badResourceTemplate } }
    while true {
      try need(1)
      let tag = b[at]
      if tag & 0x80 == 0 {
        let type = (tag >> 3) & 0x0F, length = Int(tag & 7)
        try need(1 + length)
        let d = Array(b[(at + 1)..<(at + 1 + length)])
        switch type {
        case 0x04:  // IRQ
          guard length >= 2 else { throw ACPIError.badResourceTemplate }
          out.append(.irq(mask: d.le16(0), flags: length >= 3 ? d[2] : 0x01))  // default: edge, high
        case 0x05:
          guard length >= 2 else { throw ACPIError.badResourceTemplate }
          out.append(.dma(mask: d[0], flags: d[1]))
        case 0x06: out.append(.startDependent(priority: length >= 1 ? d[0] : nil))
        case 0x07: out.append(.endDependent)
        case 0x08:
          guard length >= 7 else { throw ACPIError.badResourceTemplate }
          out.append(.io(decode16: d[0] & 1 != 0, minimum: d.le16(1), maximum: d.le16(3), alignment: d[5], length: d[6]))
        case 0x09:
          guard length >= 3 else { throw ACPIError.badResourceTemplate }
          out.append(.fixedIO(base: d.le16(0) & 0x3FF, length: d[2]))
        case 0x0A:
          guard length >= 5 else { throw ACPIError.badResourceTemplate }
          out.append(.fixedDMA(request: d.le16(0), channel: d.le16(2), width: d[4]))
        case 0x0E: out.append(.vendor(d))
        case 0x0F:  // End tag: its checksum, if any, covers everything
          if length >= 1, d[0] != 0 {
            guard sumsToZero(b[0..<(at + 2)]) else { throw ACPIError.badChecksum }
          }
          return out
        default: throw ACPIError.badResourceTemplate
        }
        at += 1 + length
      } else {
        try need(3)
        let type = tag & 0x7F, length = Int(b.le16(at + 1))
        try need(3 + length)
        let d = Array(b[(at + 3)..<(at + 3 + length)])
        func source(_ from: Int) -> ResourceSource? {
          guard from < d.count else { return nil }
          var path = Array(d[(from + 1)...])
          if let nul = path.firstIndex(of: 0) { path = Array(path[..<nul]) }
          return ResourceSource(index: d[from], path: path)
        }
        func string(_ offset: Int) -> [UInt8] {
          // An offset from the descriptor's start to a null-terminated string.
          let from = offset - 3
          guard from >= 0, from < d.count else { return [] }
          let s = d[from...]
          return Array(s.prefix { $0 != 0 })
        }
        switch type {
        case 0x01:
          guard length >= 9 else { throw ACPIError.badResourceTemplate }
          out.append(.memory24(writable: d[0] & 1 != 0, minimum: UInt32(d.le16(1)) << 8, maximum: UInt32(d.le16(3)) << 8,
                               alignment: UInt32(d.le16(5)), length: UInt32(d.le16(7)) << 8))
        case 0x02:
          guard length >= 12 else { throw ACPIError.badResourceTemplate }
          out.append(.genericRegister(space: d[0], bitWidth: d[1], bitOffset: d[2], accessSize: d[3], address: d.le64(4)))
        case 0x04: out.append(.vendor(d))
        case 0x05:
          guard length >= 17 else { throw ACPIError.badResourceTemplate }
          out.append(.memory32(writable: d[0] & 1 != 0, minimum: d.le32(1), maximum: d.le32(5), alignment: d.le32(9),
                               length: d.le32(13)))
        case 0x06:
          guard length >= 9 else { throw ACPIError.badResourceTemplate }
          out.append(.memory32Fixed(writable: d[0] & 1 != 0, base: d.le32(1), length: d.le32(5)))
        case 0x07, 0x08, 0x0A:  // DWord, Word, QWord Address Space
          let w = type == 0x08 ? 2 : type == 0x07 ? 4 : 8
          guard length >= 3 + 5 * w else { throw ACPIError.badResourceTemplate }
          func value(_ i: Int) -> UInt64 {
            let o = 3 + i * w
            return w == 2 ? UInt64(d.le16(o)) : w == 4 ? UInt64(d.le32(o)) : d.le64(o)
          }
          out.append(.address(AddressSpace(kind: d[0], generalFlags: d[1], typeFlags: d[2], granularity: value(0),
                                           minimum: value(1), maximum: value(2), translation: value(3), length: value(4),
                                           source: source(3 + 5 * w))))
        case 0x0B:  // Extended Address Space: type, flags, revision, reserved, then six qwords
          guard length >= 53 else { throw ACPIError.badResourceTemplate }
          out.append(.address(AddressSpace(kind: d[0], generalFlags: d[1], typeFlags: d[2], granularity: d.le64(5),
                                           minimum: d.le64(13), maximum: d.le64(21), translation: d.le64(29),
                                           length: d.le64(37), source: nil)))
        case 0x09:  // Extended Interrupt
          guard length >= 2, length >= 2 + 4 * Int(d[1]) else { throw ACPIError.badResourceTemplate }
          let count = Int(d[1])
          out.append(.extendedIRQ(flags: d[0], interrupts: (0..<count).map { d.le32(2 + 4 * $0) },
                                  source: source(2 + 4 * count)))
        case 0x0C:  // GPIO Connection
          guard length >= 20 else { throw ACPIError.badResourceTemplate }
          let pinTable = Int(d.le16(11)) - 3, sourceName = Int(d.le16(14)) - 3
          let vendorOffset = Int(d.le16(16)) - 3, vendorLength = Int(d.le16(18))
          guard pinTable >= 0, sourceName >= pinTable, sourceName <= d.count else { throw ACPIError.badResourceTemplate }
          let pins = stride(from: pinTable, to: sourceName - 1, by: 2).map { d.le16($0) }
          let vendor = vendorLength > 0 && vendorOffset >= 0 && vendorOffset + vendorLength <= d.count
            ? Array(d[vendorOffset..<(vendorOffset + vendorLength)]) : []
          out.append(.gpio(GPIOConnection(type: d[1], generalFlags: d.le16(2), flags: d.le16(4), pinConfig: d[6],
                                          outputDrive: d.le16(7), debounce: d.le16(9), pins: pins,
                                          source: string(sourceName + 3), vendor: vendor)))
        case 0x0E:  // Generic Serial Bus Connection
          guard length >= 9 else { throw ACPIError.badResourceTemplate }
          let dataLength = Int(d.le16(7))
          guard 9 + dataLength <= d.count else { throw ACPIError.badResourceTemplate }
          var name = Array(d[(9 + dataLength)...])
          if let nul = name.firstIndex(of: 0) { name = Array(name[..<nul]) }
          out.append(.serialBus(SerialBusConnection(type: d[2], generalFlags: d[3], typeFlags: d.le16(4),
                                                    typeRevision: d[6], typeData: Array(d[9..<(9 + dataLength)]),
                                                    source: name)))
        case 0x0D, 0x0F, 0x10, 0x11, 0x12, 0x13: out.append(.other(type: 0x80 | type, d))
        default: throw ACPIError.badResourceTemplate
        }
        at += 3 + length
      }
    }
  }
}
