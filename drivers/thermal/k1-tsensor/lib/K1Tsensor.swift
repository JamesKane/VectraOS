// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's thermal sensor (k1-tsensor(3)), as bin/k1-tsensor
// drives it: one block with five sensing points, the SoC's own, the
// package's, the GPU's and each CPU cluster's, converting continuously
// once powered and put in automatic mode, each reading a whole degree
// Celsius 278 below its raw value. Its threshold interrupts stay masked:
// the reading is polled (power(8) reads it through devmgr's `thermal`).
// Registers, bits and the enable sequence are the hardware's
// (chinese-wall's spacemit-k1 13 §13.3, §13.4, §13.8).

public enum Tsensor {
  /// The registers' extent, its node's `reg`.
  public static let size = 0x100
  public static let sensors = 5
  /// Each sensor's place, by its number (the cell of a zone's
  /// `thermal-sensors`).
  public static let names = ["soc", "package", "gpu", "cluster0", "cluster1"]

  public static let pctrl = 0x00
  public static let pctrl2 = 0x04
  public static let enable = 0x08
  public static let timeControl = 0x0C
  public static let interruptClear = 0x10
  public static let interruptMask = 0x14
  public static let interruptStatus = 0x18

  /// The data word sensor `n` is in, and the shift of its 16 bits there.
  public static func data(_ n: Int) -> (offset: Int, shift: UInt32) { (0x20 + 4 * (n / 2), UInt32(n % 2) * 16) }

  /// PCTRL powered, converting temperatures continuously by itself: bits
  /// 0, 3, 7 and 23 set, the trim ([11:8]) and software control ([21:18])
  /// fields cleared, the rest as they were.
  public static func powered(_ v: UInt32) -> UInt32 {
    v & ~(0xF << 18 | 0xF << 8) | 1 | 1 << 3 | 1 << 7 | 1 << 23
  }

  /// PCTRL2 with the modulator's clock 24 MHz ([15:14] = 0).
  public static func modulatorAt24MHz(_ v: UInt32) -> UInt32 { v & ~(3 << 14) }

  /// TIME_CTRL's sampling timing: [23:0] = 0x3000FF, [31:24] kept.
  public static func timing(_ v: UInt32) -> UInt32 { v & 0xFF00_0000 | 0x30_00FF }

  /// Every sensor's enable bit set.
  public static func allEnabled(_ v: UInt32) -> UInt32 { v | (1 << UInt32(sensors)) - 1 }

  /// Every interrupt masked: written whole, first.
  public static let everyInterruptMasked: UInt32 = 0xFFFF_FFFF

  /// A sensor's reading in whole degrees Celsius; nil for one no die
  /// could be at, as a data word holds before its first conversion (0
  /// would be -278 C): below -40 C or above 200 C.
  public static func celsius(raw: UInt32) -> Int? {
    let t = Int(raw & 0xFFFF) - 278
    return t >= -40 && t <= 200 ? t : nil
  }

  /// Sensor `n`'s reading from its data word.
  public static func celsius(_ n: Int, word: UInt32) -> Int? { celsius(raw: word >> data(n).shift & 0xFFFF) }

  /// `temperatures`: a line a sensor, `<n> <C|-> <name>`.
  public static func text(_ readings: [Int?]) -> String {
    readings.enumerated().map { n, t in
      "\(n) \(t.map { "\($0)" } ?? "-") \(n < names.count ? names[n] : "sensor\(n)")\n"
    }.joined()
  }
}
