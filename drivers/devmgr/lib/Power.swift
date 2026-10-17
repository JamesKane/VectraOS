// SPDX-License-Identifier: BSD-3-Clause

// \_S5 (ACPI 6.5 §7.4.2): the sleep types, SLP_TYPa and SLP_TYPb, that
// put the machine in S5, which amd64's kernel writes to the PM1 control
// registers to power it off. devmgr evaluates it as the namespace loads,
// for /dev/reboot's `poweroff`; userboot's byte scan of the DSDT is the
// fallback for a machine with no devmgr.

import TDACPI

extension Namespace {
  /// \_S5's first two values, if the machine has it.
  public mutating func sleepTypes<H: ACPIHost>(host: H) -> (UInt8, UInt8)? {
    guard let s5 = lookup("\\_S5"), case .package(let p)? = try? evaluate(s5, host: host), let first = p.elements.first,
      case .integer(let a) = first
    else { return nil }
    // A firmware that gives one value gives SLP_TYPa alone.
    var b = a
    if p.elements.count > 1, case .integer(let second) = p.elements[1] { b = second }
    return (UInt8(truncatingIfNeeded: a), UInt8(truncatingIfNeeded: b))
  }
}
