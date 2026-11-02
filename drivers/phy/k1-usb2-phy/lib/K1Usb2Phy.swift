// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's USB 2 PHY (k1-usb2-phy(3)), as bin/k1-usb2-phy drives
// it: the UTMI PHY of the DWC3's high-speed port. With its clock on (the
// APMU's USB 3 clock, which the controller shares), its PLL locks by
// itself; then the PHY's own reset is released, its clock gating
// enabled, its high-speed transmitter's current raised a step, and the
// disconnect detector set not to clear itself. Registers, bits and
// values are the hardware's (chinese-wall's spacemit-k1 07).

public enum K1Usb2Phy {
  /// The registers' extent.
  public static let size = 0x200
  /// PHY_REG01, whose bit 0 says the PLL is locked.
  public static let pll = 0x04
  public static let pllReady: UInt32 = 1

  /// A read-modify-write: the bits of `register` under `mask` become
  /// `value`.
  public struct Update: Equatable, Sendable {
    public var register: Int
    public var mask: UInt32
    public var value: UInt32

    public init(_ register: Int, mask: UInt32, value: UInt32) {
      self.register = register
      self.mask = mask
      self.value = value
    }

    public func apply(_ old: UInt32) -> UInt32 { old & ~mask | value & mask }
  }

  /// The writes that turn it on once its PLL has locked, in order.
  public static let setup: [Update] = [
    // PHY_REG01: out of reset, clock gating on (§7.2).
    Update(0x04, mask: ~0, value: 0x60ef),
    // PHY_REG0D.
    Update(0x34, mask: ~0, value: 0x1c),
    // ANALOG_REG14_13: HSDAC_ISEL 15% up, and HSDAC_IREG_EN.
    Update(0xa4, mask: 0x1f, value: 0x1c),
    // PHY_REG04: AUTO_CLEAR_DIS.
    Update(0x10, mask: 1 << 2, value: 1 << 2),
  ]
}
