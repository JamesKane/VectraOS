// SPDX-License-Identifier: BSD-3-Clause

// What a PCI root bridge decodes (ACPI 6.5 §6.4.3.5, its _CRS's address
// space descriptors): the buses below it, and the memory windows it
// forwards, each with its translation offset, which added to an address
// on the bus gives the CPU's (§6.4.3.5.1, _TRA). A BAR holds a bus
// address: on a PC the two are the same, but the CIX Sky1's root
// complexes each put the same bus addresses at a window of their own, so
// a BAR's resource must be made at the CPU's address.

import TDACPI

public struct RootBridge: Equatable, Sendable {
  public struct Window: Equatable, Sendable {
    /// Bus addresses, inclusive.
    public var minimum: UInt64
    public var maximum: UInt64
    public var translation: UInt64
  }

  public var firstBus: UInt8
  public var lastBus: UInt8
  public var windows: [Window]

  /// The bridge a _CRS describes: its bus number range (all 256 buses
  /// if it names none) and its memory windows. I/O windows are left out.
  public init(resources: [Resource]) {
    var first: UInt8 = 0, last: UInt8 = 255
    var windows: [Window] = []
    for r in resources {
      guard case .address(let a) = r else { continue }
      switch a.kind {
      case 0 where a.maximum >= a.minimum:
        windows.append(Window(minimum: a.minimum, maximum: a.maximum, translation: a.translation))
      case 2:
        first = UInt8(truncatingIfNeeded: a.minimum)
        last = UInt8(truncatingIfNeeded: min(a.maximum, 255))
      default:
        continue
      }
    }
    firstBus = first
    lastBus = last
    self.windows = windows
  }

  public func covers(bus: UInt8) -> Bool { bus >= firstBus && bus <= lastBus }

  /// The CPU's address for `size` bytes at bus address `address`; nil if
  /// no window holds them all.
  public func cpuAddress(_ address: UInt64, size: UInt64) -> UInt64? {
    guard size > 0, address <= UInt64.max - (size - 1) else { return nil }
    let w = windows.first { address >= $0.minimum && address + (size - 1) <= $0.maximum }
    return w.map { address &+ $0.translation }
  }

  /// `buses 96-127 0x40000000-0x7fffffff +0x...`, for devmgr's findings.
  public var summary: String {
    "buses \(firstBus)-\(lastBus)" + windows.map {
      " 0x\(String($0.minimum, radix: 16))-0x\(String($0.maximum, radix: 16))"
        + ($0.translation == 0 ? "" : " +0x\(String($0.translation, radix: 16))")
    }.joined()
  }
}
