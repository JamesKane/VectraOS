// SPDX-License-Identifier: BSD-3-Clause

// The input class's USB devices in HID's boot protocol (Device Class
// Definition for HID 1.11, appendix B), as 9front's nusb/kb reads them. A
// keyboard's report is its modifiers' bits (usages 0xE0-0xE7, bit 0
// first), a reserved byte, then up to six keys held, each a usage; kbin
// wants changes, so each report is compared with the last. A mouse's
// boot report is one layout HIDMouse reads (HIDReports.swift).

/// A boot keyboard: its reports as kbin's records.
public struct BootKeyboard: Sendable {
  var modifiers: UInt8 = 0
  var keys: [UInt8] = []

  public init() {}

  /// The records for the changes since the last report (none for a
  /// report of rolled-over keys, usage 1: the keys held are unknown).
  public mutating func take(_ report: [UInt8]) -> [UInt8] {
    guard report.count >= 3 else { return [] }
    let held = report[2...].filter { $0 > 3 }
    guard !report[2...].contains(1) else { return [] }
    var out: [UInt8] = []
    let changed = modifiers ^ report[0]
    for bit in 0..<8 where changed & (1 << bit) != 0 {
      out += KeyboardUsage.record(0xE0 + UInt8(bit), down: report[0] & (1 << bit) != 0)
    }
    for k in keys where !held.contains(k) { out += KeyboardUsage.record(k, down: false) }
    for k in held where !keys.contains(k) { out += KeyboardUsage.record(k, down: true) }
    modifiers = report[0]
    keys = Array(held)
    return out
  }
}
