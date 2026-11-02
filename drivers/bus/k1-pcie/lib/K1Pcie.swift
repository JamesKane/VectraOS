// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's PCIe hosts (k1-pcie(3)), as bin/k1-pcie drives them:
// Synopsys DesignWare root complexes, each with its registers in four
// places: DBI, the root port's configuration space followed by the
// core's port logic; the iATU, the windows that turn the CPU's accesses
// into the bus's (unrolled, 0x200 a region); the configuration window,
// where an outbound region sends config requests; and the K1's own link
// registers. What it computes without the hardware is here: the iATU's
// writes, where each BAR of a function goes in the host's window, and the
// root port's bridge registers. Offsets and bits are the hardware's
// (chinese-wall's spacemit-k1 09).

/// The DBI's registers past the root port's header.
public enum DBI {
  /// Port logic.
  public static let linkDebug0 = 0x728
  public static let portLinkControl = 0x710
  public static let linkWidthSpeedControl = 0x80C
  public static let msiAddressLow = 0x820
  public static let msiAddressHigh = 0x824
  /// Each of 8 controllers' enable, mask and status, 12 bytes apart.
  public static let msiEnable = 0x828
  public static let msiMask = 0x82C
  public static let msiStatus = 0x830
  public static let miscControl1 = 0x8BC
  public static let version = 0x8F8

  /// PORT_LINK_CTRL's DLL link enable and fast link mode.
  public static let dllLinkEnable: UInt32 = 1 << 5
  public static let fastLinkMode: UInt32 = 1 << 7
  /// LINK_WIDTH_SPEED_CTRL's directed speed change.
  public static let speedChange: UInt32 = 1 << 17
  /// MISC_CONTROL_1's: read-only registers writable.
  public static let readOnlyWritable: UInt32 = 1
  public static let size = 0x1000
}

/// The K1's link registers.
public enum Link {
  public static let interruptEnable = 0x00
  public static let status = 0x04
  public static let intrEnable = 0x14
  /// K1_PHY_AHB_IRQ_EN's PCIE_INTERRUPT_EN; INTR_ENABLE's MSI_CTRL_INT.
  public static let pcieInterrupt: UInt32 = 1
  public static let msiInterrupt: UInt32 = 1 << 11
  /// The link is up when both layers say so.
  public static let up: UInt32 = 1 << 1 | 1 << 12
}

/// An outbound iATU region's registers and what goes in them.
public enum ATU {
  public static let region = 0x200
  public static let control1 = 0x00
  public static let control2 = 0x04
  public static let lowerBase = 0x08
  public static let upperBase = 0x0C
  public static let limit = 0x10
  public static let lowerTarget = 0x14
  public static let upperTarget = 0x18
  public static let upperLimit = 0x20

  public enum Kind: UInt32, Sendable { case memory = 0, config0 = 4, config1 = 5 }

  public static let enable: UInt32 = 1 << 31
  public static let dmaBypass: UInt32 = 1 << 27
  public static let digest: UInt32 = 1 << 8

  /// A config request's target: bus, device and function.
  public static func target(bus: UInt8, device: UInt8, function: UInt8) -> UInt64 {
    UInt64(bus) << 24 | UInt64(device & 0x1F) << 19 | UInt64(function & 7) << 16
  }

  /// The writes, each an offset in the iATU's registers and its value,
  /// that make outbound region `index` send `size` bytes of the CPU's at
  /// `cpu` to the bus's `target`, as `kind` requests; for core `version`
  /// (DBI's 0x8F8: 4.60a and up have an upper limit and DMA bypass, and
  /// before 5.10a the TLP digest bit is set; §9.6). Enabled last.
  public static func outbound(index: Int, _ kind: Kind, cpu: UInt64, size: UInt64, target: UInt64,
                              version: UInt32) -> [(offset: Int, value: UInt32)] {
    let base = index * region, limit = cpu + size - 1
    let v460 = version >= 0x3436_302A, v510 = version >= 0x3531_302A
    var out: [(offset: Int, value: UInt32)] = [
      (base + lowerBase, UInt32(truncatingIfNeeded: cpu)), (base + upperBase, UInt32(truncatingIfNeeded: cpu >> 32)),
      (base + Self.limit, UInt32(truncatingIfNeeded: limit)),
    ]
    if v460 { out.append((base + upperLimit, UInt32(truncatingIfNeeded: limit >> 32))) }
    out.append((base + lowerTarget, UInt32(truncatingIfNeeded: target)))
    out.append((base + upperTarget, UInt32(truncatingIfNeeded: target >> 32)))
    out.append((base + control1, kind.rawValue | (v510 ? 0 : digest)))
    out.append((base + control2, enable | (v460 ? dmaBypass : 0)))
    return out
  }
}

/// A function's BAR as sized: its index, bytes, and whether it takes two
/// registers (64-bit).
public struct SizedBAR: Equatable, Sendable {
  public var index: Int
  public var size: UInt64
  public var wide: Bool

  public init(index: Int, size: UInt64, wide: Bool) {
    self.index = index
    self.size = size
    self.wide = wide
  }

  /// The BAR at `index` from its value as read (`original`) and with all
  /// ones written (`mask`, and `upperMask` for a 64-bit one's next
  /// register): nil for an I/O BAR or one that decodes nothing.
  public init?(index: Int, original: UInt32, mask: UInt32, upperMask: UInt32 = 0xFFFF_FFFF) {
    guard original & 1 == 0 else { return nil }
    let wide = original & 0x6 == 0x4
    let full = (wide ? UInt64(upperMask) << 32 : 0xFFFF_FFFF_0000_0000) | UInt64(mask & ~0xF)
    let size = ~full &+ 1
    guard full & 0xFFFF_FFF0 != 0 || wide, size != 0 else { return nil }
    self.init(index: index, size: size, wide: wide)
  }
}

public enum Placement {
  /// Where each BAR goes in `window` (bus addresses, inclusive): the
  /// largest first, each aligned to its size; nil if they don't all fit.
  public static func place(_ bars: [SizedBAR], in window: (minimum: UInt64, maximum: UInt64)) -> [(index: Int, address: UInt64)]? {
    var next = window.minimum
    var out: [(index: Int, address: UInt64)] = []
    for b in bars.sorted(by: { $0.size > $1.size || $0.size == $1.size && $0.index < $1.index }) {
      let at = (next + b.size - 1) & ~(b.size - 1)
      guard at >= next, at + b.size - 1 <= window.maximum else { return nil }
      out.append((b.index, at))
      next = at + b.size
    }
    return out.sorted { $0.index < $1.index }
  }

  /// A root port's memory base and limit register (0x20) for the bus
  /// addresses `minimum` to `maximum`, in 1 MiB units; an empty one
  /// (base above limit) for none.
  public static func bridgeWindow(_ range: (minimum: UInt64, maximum: UInt64)?) -> UInt32 {
    guard let r = range else { return 0x0000_FFF0 }
    let base = UInt32(truncatingIfNeeded: r.minimum >> 16) & 0xFFF0
    let limit = UInt32(truncatingIfNeeded: r.maximum >> 16) & 0xFFF0
    return limit << 16 | base
  }
}

/// The link's speed and width, from the root port's Link Status.
public func linkText(_ status: UInt16) -> String {
  let speed = ["", "2.5", "5", "8", "16", "32"]
  let s = Int(status & 0xF), w = Int(status >> 4 & 0x3F)
  return "\(s < speed.count && s > 0 ? speed[s] : "?") GT/s x\(w)"
}

/// What a host's node says (devmgr's /dev/dt/node): its PCI domain, and
/// its `ranges`' first non-prefetchable 32-bit memory window, each entry
/// three cells of PCI address (its space in the first cell's bits 24-25,
/// prefetchable bit 30), two of the CPU's and two of size.
public struct HostNode: Equatable, Sendable {
  public var domain: UInt16 = 0
  public var memory: (cpu: UInt64, pci: UInt64, size: UInt64)?

  public static func == (a: Self, b: Self) -> Bool {
    a.domain == b.domain && a.memory?.cpu == b.memory?.cpu && a.memory?.pci == b.memory?.pci
      && a.memory?.size == b.memory?.size
  }

  public init(node: String) {
    for line in node.utf8.split(separator: 0x0A) {
      let words = line.split(separator: 0x20, maxSplits: 1)
      guard words.count == 2 else { continue }
      let cells = words[1].split(whereSeparator: { $0 == 0x20 || $0 == UInt8(ascii: "<") || $0 == UInt8(ascii: ">") })
        .compactMap { w -> UInt64? in
          let s = String(decoding: w, as: UTF8.self)
          return s.utf8.starts(with: "0x".utf8) ? UInt64(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16) : UInt64(s)
        }
      if words[0].elementsEqual("linux,pci-domain".utf8), let d = cells.first, d <= 0xFFFF {
        domain = UInt16(d)
      } else if words[0].elementsEqual("ranges".utf8), memory == nil {
        var i = 0
        while i + 7 <= cells.count {
          let space = cells[i] >> 24 & 3, prefetchable = cells[i] >> 30 & 1 == 1
          if space == 2, !prefetchable {
            memory = (cells[i + 3] << 32 | cells[i + 4], cells[i + 1] << 32 | cells[i + 2], cells[i + 5] << 32 | cells[i + 6])
            break
          }
          i += 7
        }
      }
    }
  }
}
