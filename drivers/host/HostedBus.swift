// SPDX-License-Identifier: BSD-3-Clause

// A PCI bus a driver brings up (D154: a vendor's PCIe host, such as the
// SpacemiT K1's DesignWare, is a devmgr driver): what its host driver
// serves as `pci` once its link is up, for devmgr to bind the functions
// it found as it binds ECAM's. A line each:
//   segment N                      its PCI segment
//   memory MIN MAX                 a window of bus addresses it forwards,
//                                  the CPU's the same
//   dma-bits N                     the bus addresses its devices reach
//   msi dwc REGISTERS TARGET GSI   its MSI block: DesignWare's, the
//                                  physical address of its first register
//                                  (PCIE_MSI_ADDR_LO), the address devices
//                                  write, and the wired interrupt it
//                                  raises
//   function BB:DD.F PAGE          a function, and the physical address of
//                                  its 4 KiB of configuration space, which
//                                  the host has fixed there
// with numbers in 0x hexadecimal or decimal and the address as Linux
// writes one. Its BARs are placed in a window and its bus numbered; a
// line it can't read is left out.

public struct HostedBus: Equatable, Sendable {
  public struct Function: Equatable, Sendable {
    public var bus: UInt8
    public var device: UInt8
    public var function: UInt8
    /// Its configuration space's physical address.
    public var page: UInt64

    public init(bus: UInt8, device: UInt8, function: UInt8, page: UInt64) {
      self.bus = bus
      self.device = device
      self.function = function
      self.page = page
    }
  }

  public struct MSIBlock: Equatable, Sendable {
    public var registers: UInt64
    public var target: UInt64
    public var gsi: UInt32

    public init(registers: UInt64, target: UInt64, gsi: UInt32) {
      self.registers = registers
      self.target = target
      self.gsi = gsi
    }
  }

  public var segment: UInt16 = 0
  public var memory: [(minimum: UInt64, maximum: UInt64)] = []
  public var dmaBits: UInt32 = 64
  public var msi: MSIBlock?
  public var functions: [Function] = []

  public init() {}

  public static func == (a: Self, b: Self) -> Bool {
    a.segment == b.segment && a.dmaBits == b.dmaBits && a.msi == b.msi && a.functions == b.functions
      && a.memory.count == b.memory.count
      && zip(a.memory, b.memory).allSatisfy { $0.minimum == $1.minimum && $0.maximum == $1.maximum }
  }

  public init(text: String) {
    for line in text.utf8.split(separator: 0x0A) {
      let w = line.split(separator: 0x20).map { Array($0) }
      guard let key = w.first else { continue }
      let n = { (i: Int) -> UInt64? in i < w.count ? parseNumber(w[i]) : nil }
      if key.elementsEqual("segment".utf8), w.count == 2, let s = n(1), s <= 0xFFFF {
        segment = UInt16(s)
      } else if key.elementsEqual("memory".utf8), w.count == 3, let lo = n(1), let hi = n(2), hi >= lo {
        memory.append((lo, hi))
      } else if key.elementsEqual("dma-bits".utf8), w.count == 2, let b = n(1), b >= 12, b <= 64 {
        dmaBits = UInt32(b)
      } else if key.elementsEqual("msi".utf8), w.count == 5, w[1].elementsEqual("dwc".utf8), let r = n(2),
        let t = n(3), let g = n(4), g <= 0xFFFF_FFFF
      {
        msi = MSIBlock(registers: r, target: t, gsi: UInt32(g))
      } else if key.elementsEqual("function".utf8), w.count == 3, let a = parseAddress(w[1]), let page = n(2),
        page & 0xFFF == 0
      {
        functions.append(Function(bus: a.0, device: a.1, function: a.2, page: page))
      }
    }
  }

  public var text: String {
    var lines = ["segment \(segment)"]
    for m in memory { lines.append("memory 0x\(String(m.minimum, radix: 16)) 0x\(String(m.maximum, radix: 16))") }
    lines.append("dma-bits \(dmaBits)")
    if let m = msi {
      lines.append("msi dwc 0x\(String(m.registers, radix: 16)) 0x\(String(m.target, radix: 16)) \(m.gsi)")
    }
    for f in functions {
      lines.append("function \(hex2(f.bus)):\(hex2(f.device)).\(f.function & 7) 0x\(String(f.page, radix: 16))")
    }
    return lines.map { $0 + "\n" }.joined()
  }
}

func hex2(_ v: UInt8) -> String { (v < 16 ? "0" : "") + String(v, radix: 16) }

func parseNumber(_ w: [UInt8]) -> UInt64? {
  let s = String(decoding: w, as: UTF8.self)
  return s.utf8.starts(with: "0x".utf8) ? UInt64(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16) : UInt64(s)
}

/// `bb:dd.f`, hexadecimal.
func parseAddress(_ w: [UInt8]) -> (UInt8, UInt8, UInt8)? {
  let parts = w.split(whereSeparator: { $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") })
  guard parts.count == 3, let b = UInt8(String(decoding: parts[0], as: UTF8.self), radix: 16),
    let d = UInt8(String(decoding: parts[1], as: UTF8.self), radix: 16), d < 32,
    let f = UInt8(String(decoding: parts[2], as: UTF8.self), radix: 16), f < 8
  else { return nil }
  return (b, d, f)
}
