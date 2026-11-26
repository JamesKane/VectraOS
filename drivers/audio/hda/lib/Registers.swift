// SPDX-License-Identifier: BSD-3-Clause

// An HD Audio controller's registers (Intel High Definition Audio
// Specification rev. 1.0a, §3.3), each reached at its own width, as the
// specification lays them out (QEMU's ich9-intel-hda decodes nothing
// else: a word read across two registers gives only the first). The
// Sky1's controller decodes only aligned 32-bit accesses (sky1-audio 02
// §2.2.1): with `wordOnly`, a byte or 16-bit register is read from its
// word and written by a read-modify-write of the word, with the write-1-
// to-clear status bits that share the word written back as 0 unless they
// are the target. SDnCTL is three bytes and SDnSTS the fourth: a 16-bit
// and an 8-bit access, and an 8-bit one, or the word.

/// The controller's register window.
public protocol HDAWindow: AnyObject {
  func load32(_ offset: Int) -> UInt32
  func store32(_ offset: Int, _ value: UInt32)
  func load16(_ offset: Int) -> UInt16
  func store16(_ offset: Int, _ value: UInt16)
  func load8(_ offset: Int) -> UInt8
  func store8(_ offset: Int, _ value: UInt8)
}

public enum Reg {
  public static let gcap = 0x00
  public static let gctl = 0x08
  public static let statests = 0x0E
  public static let intctl = 0x20
  public static let intsts = 0x24
  public static let corbLower = 0x40
  public static let corbUpper = 0x44
  public static let corbWP = 0x48
  public static let corbRP = 0x4A
  public static let corbCtl = 0x4C
  public static let corbSize = 0x4E
  public static let rirbLower = 0x50
  public static let rirbUpper = 0x54
  public static let rirbWP = 0x58
  public static let rintCnt = 0x5A
  public static let rirbCtl = 0x5C
  public static let rirbSts = 0x5D
  public static let rirbSize = 0x5E
  /// Stream descriptor `n` (input streams first, then output), and its
  /// registers' offsets in it.
  public static func sd(_ n: Int) -> Int { 0x80 + 0x20 * n }
  public static let sdCtl = 0x00
  public static let sdSts = 0x03
  public static let sdLPIB = 0x04
  public static let sdCBL = 0x08
  public static let sdLVI = 0x0C
  public static let sdFormat = 0x12
  public static let sdBDLLower = 0x18
  public static let sdBDLUpper = 0x1C

  /// GCTL's bits.
  public static let crst: UInt32 = 1 << 0
  public static let unsol: UInt32 = 1 << 8
  /// INTCTL's: a stream's enable is its index's bit.
  public static let cie: UInt32 = 1 << 30
  public static let gie: UInt32 = 1 << 31
  /// SDnCTL's (its low 24 bits) and SDnSTS's.
  public static let srst: UInt32 = 1 << 0
  public static let run: UInt32 = 1 << 1
  public static let ioce: UInt32 = 1 << 2
  public static let bcis: UInt8 = 1 << 2
  public static let fifoe: UInt8 = 1 << 3
  public static let dese: UInt8 = 1 << 4
}

/// The registers, each at its width, or a word at a time (`wordOnly`).
public struct HDARegisters {
  public let window: HDAWindow
  public let wordOnly: Bool

  public init(_ window: HDAWindow, wordOnly: Bool = false) {
    self.window = window
    self.wordOnly = wordOnly
  }

  public func load32(_ o: Int) -> UInt32 {
    precondition(o & 3 == 0)
    return window.load32(o)
  }

  public func store32(_ o: Int, _ v: UInt32) {
    precondition(o & 3 == 0)
    window.store32(o, v)
  }

  public func load16(_ o: Int) -> UInt16 {
    precondition(o & 1 == 0)
    guard wordOnly else { return window.load16(o) }
    return UInt16(truncatingIfNeeded: load32(o & ~3) >> (8 * UInt32(o & 3)))
  }

  public func load8(_ o: Int) -> UInt8 {
    guard wordOnly else { return window.load8(o) }
    return UInt8(truncatingIfNeeded: load32(o & ~3) >> (8 * UInt32(o & 3)))
  }

  /// Writes `width` bytes at `o` as a read-modify-write of their word,
  /// the bits of `clearMask` (write-1-to-clear bits elsewhere in the
  /// word, as the word reads them) written as 0.
  public func store(_ o: Int, width: Int, _ v: UInt32, clearMask: UInt32 = 0) {
    precondition(o & (width - 1) == 0 && (o & 3) + width <= 4)
    let shift = 8 * UInt32(o & 3)
    let field: UInt32 = width == 4 ? 0xFFFF_FFFF : ((1 << (8 * UInt32(width))) - 1) << shift
    let old = load32(o & ~3)
    store32(o & ~3, (old & ~field & ~clearMask) | ((v << shift) & field))
  }

  public func store16(_ o: Int, _ v: UInt16, clearMask: UInt32 = 0) {
    guard wordOnly else { return window.store16(o, v) }
    store(o, width: 2, UInt32(v), clearMask: clearMask)
  }

  public func store8(_ o: Int, _ v: UInt8, clearMask: UInt32 = 0) {
    guard wordOnly else { return window.store8(o, v) }
    store(o, width: 1, UInt32(v), clearMask: clearMask)
  }

  // The write-1-to-clear bytes, as masks of their words.

  /// RIRBSTS in RIRBCTL's word (0x5C): its RINTFL and RIRBOIS.
  public static let rirbStsMask: UInt32 = 0x05 << 8
  /// SDnSTS in SDnCTL's word: BCIS, FIFOE, DESE.
  public static let sdStsMask: UInt32 = 0x1C << 24

  /// SDnCTL's 24 bits.
  public func sdCtl(_ n: Int) -> UInt32 {
    let o = Reg.sd(n)
    guard wordOnly else { return UInt32(window.load16(o)) | UInt32(window.load8(o + 2)) << 16 }
    return load32(o) & 0x00FF_FFFF
  }

  /// SDnCTL written, SDnSTS left as it is (not cleared).
  public func setSdCtl(_ n: Int, _ v: UInt32) {
    let o = Reg.sd(n)
    guard wordOnly else {
      window.store16(o, UInt16(truncatingIfNeeded: v))
      window.store8(o + 2, UInt8(truncatingIfNeeded: v >> 16))
      return
    }
    store32(o, (v & 0x00FF_FFFF) | (load32(o) & 0xFF00_0000 & ~Self.sdStsMask))
  }

  public func sdSts(_ n: Int) -> UInt8 { load8(Reg.sd(n) + Reg.sdSts) }

  /// Clears `bits` of SDnSTS, SDnCTL as it is.
  public func clearSdSts(_ n: Int, _ bits: UInt8) {
    let o = Reg.sd(n)
    guard wordOnly else { return window.store8(o + Reg.sdSts, bits) }
    store32(o, (load32(o) & 0x00FF_FFFF) | UInt32(bits) << 24)
  }
}
