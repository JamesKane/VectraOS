// SPDX-License-Identifier: BSD-3-Clause

// An SD host controller as bin/sdhci drives it: the SD Host Controller
// Simplified Specification's registers (version 2 and 3), the commands of
// the SD Physical Layer Simplified Specification it sends, and what it
// reads back: a card's CSD, and the bits of its status. Its DMA is ADMA2
// with 32-bit descriptors (the SpacemiT K1's only width), a table of
// pieces of one bounce buffer. The SpacemiT K1's own registers, past the
// standard ones, are Linux's sdhci-of-k1.c's. Host.swift drives the
// registers; this file is what tests can check without a controller.

/// The standard registers' offsets.
public enum Register {
  public static let adma32Address = 0x00  // SDMA system address / argument 2
  public static let blockSize = 0x04  // 16 bits
  public static let blockCount = 0x06  // 16 bits
  public static let argument = 0x08
  public static let transferMode = 0x0C  // 16 bits
  public static let command = 0x0E  // 16 bits
  public static let response = 0x10  // four 32-bit words
  public static let presentState = 0x24
  public static let hostControl = 0x28  // 8 bits
  public static let powerControl = 0x29  // 8 bits
  public static let clockControl = 0x2C  // 16 bits
  public static let timeoutControl = 0x2E  // 8 bits
  public static let softwareReset = 0x2F  // 8 bits
  public static let normalStatus = 0x30  // 16 bits
  public static let errorStatus = 0x32  // 16 bits
  public static let normalStatusEnable = 0x34
  public static let errorStatusEnable = 0x36
  public static let normalSignalEnable = 0x38
  public static let errorSignalEnable = 0x3A
  public static let hostControl2 = 0x3E  // 16 bits
  public static let capabilities = 0x40
  public static let capabilities1 = 0x44
  public static let admaAddress = 0x58  // and its high half, 0x5C
  public static let hostVersion = 0xFE  // 16 bits
  /// The standard registers' extent.
  public static let size = 0x100
}

/// The registers' bits bin/sdhci uses.
public enum Bits {
  // Present state.
  public static let commandInhibit: UInt32 = 1 << 0
  public static let dataInhibit: UInt32 = 1 << 1
  public static let cardInserted: UInt32 = 1 << 16
  /// DAT0's level: a card busy, or switching its signalling, holds it low.
  public static let dat0Level: UInt32 = 1 << 20
  // Host control.
  public static let fourBit: UInt8 = 1 << 1
  public static let eightBit: UInt8 = 1 << 5
  public static let highSpeed: UInt8 = 1 << 2
  public static let adma2: UInt8 = 2 << 3
  public static let dmaSelect: UInt8 = 3 << 3
  // Power control: 3.3 V, on.
  public static let power33: UInt8 = 7 << 1 | 1
  // Clock control.
  public static let internalClock: UInt16 = 1 << 0
  public static let internalStable: UInt16 = 1 << 1
  public static let cardClock: UInt16 = 1 << 2
  // Host control 2: the UHS mode (bits 2:0) and 1.8 V signalling.
  public static let uhsMode: UInt16 = 7
  public static let signalling18: UInt16 = 1 << 3
  // Software reset.
  public static let resetAll: UInt8 = 1 << 0
  public static let resetCommand: UInt8 = 1 << 1
  public static let resetData: UInt8 = 1 << 2
  // Normal status.
  public static let commandComplete: UInt16 = 1 << 0
  public static let transferComplete: UInt16 = 1 << 1
  public static let dmaInterrupt: UInt16 = 1 << 3
  public static let bufferReadReady: UInt16 = 1 << 5
  public static let errorInterrupt: UInt16 = 1 << 15
  // Error status: ADMA's error (bit 9), and what a timeout is.
  public static let admaError: UInt16 = 1 << 9
  public static let commandTimeout: UInt16 = 1 << 0
  // Transfer mode.
  public static let dmaEnable: UInt16 = 1 << 0
  public static let blockCountEnable: UInt16 = 1 << 1
  public static let autoCMD12: UInt16 = 1 << 2
  public static let readDirection: UInt16 = 1 << 4
  public static let multipleBlocks: UInt16 = 1 << 5
  // Capabilities.
  public static let adma2Support: UInt32 = 1 << 19
  public static let eightBitSupport: UInt32 = 1 << 18
  public static let voltage33: UInt32 = 1 << 24
}

/// A command's response, as the command register's low bits and the
/// checks the controller makes.
public enum Response: Sendable {
  case none
  /// R2: 136 bits (the CID, the CSD).
  case long
  /// R1, R6, R7: 48 bits, index and CRC checked.
  case short
  /// R1b: R1, then busy on DAT0.
  case busy
  /// R3: 48 bits, neither index nor CRC (the OCR).
  case ocr
}

public enum Sdhci {
  /// The command register's value: the index, the response's length and
  /// checks, and whether data follows.
  public static func command(_ index: UInt8, _ response: Response, data: Bool = false) -> UInt16 {
    var v = UInt16(index & 0x3F) << 8
    switch response {
    case .none: break
    case .long: v |= 1 | 1 << 3  // 136 bits, CRC
    case .short: v |= 2 | 1 << 3 | 1 << 4  // 48 bits, CRC, index
    case .busy: v |= 3 | 1 << 3 | 1 << 4
    case .ocr: v |= 2
    }
    if data { v |= 1 << 5 }
    return v
  }

  /// The transfer mode for `blocks` blocks by ADMA2: a count, and more
  /// than one ended by CMD12, which the controller sends.
  public static func transferMode(read: Bool, blocks: Int) -> UInt16 {
    var v = Bits.dmaEnable | Bits.blockCountEnable
    if read { v |= Bits.readDirection }
    if blocks > 1 { v |= Bits.multipleBlocks | Bits.autoCMD12 }
    return v
  }

  /// The clock control's divider field for the fastest card clock at most
  /// `target` from `base`, and that clock. Version 3 (`version` 2) divides
  /// by 2N for N up to 1023, earlier ones by a power of two up to 256; 0
  /// is the base undivided.
  public static func divider(base: UInt64, target: UInt64, version: UInt8) -> (field: UInt16, hz: UInt64) {
    guard base > target, target > 0 else { return (0, base) }
    if version >= 2 {
      var n = (base + 2 * target - 1) / (2 * target)
      n = min(n, 1023)
      let field = UInt16(n & 0xFF) << 8 | UInt16(n >> 8 & 3) << 6
      return (field, base / (2 * n))
    }
    var d: UInt64 = 2
    while d < 256, base / d > target { d *= 2 }
    return (UInt16(d / 2) << 8, base / d)
  }

  /// The base clock the capabilities give, in Hz (bits 15:8, 8 bits from
  /// version 3, 6 before); 0 where they don't say.
  public static func baseClock(_ capabilities: UInt32, version: UInt8) -> UInt64 {
    let mhz = (capabilities >> 8) & (version >= 2 ? 0xFF : 0x3F)
    return UInt64(mhz) * 1_000_000
  }

  /// The ADMA2 table for `bytes` at `bus`: a descriptor for each piece of
  /// at most `piece` bytes (valid, transfer), the last one marked the
  /// end. Each is 64 bits: attributes, length, a 32-bit address.
  public static func adma2(bus: UInt32, bytes: Int, piece: Int = 0x8000) -> [UInt64] {
    var table: [UInt64] = []
    var at = 0
    while at < bytes {
      let n = min(piece, bytes - at)
      let last = at + n >= bytes
      let attributes: UInt64 = 1 | (last ? 2 : 0) | 0x20  // valid, end, transfer
      table.append(attributes | UInt64(n & 0xFFFF) << 16 | UInt64(bus + UInt32(at)) << 32)
      at += n
    }
    return table
  }
}

extension Sdhci {
  /// Bits `high` to `low` of an R2 response from its four words (the
  /// controller keeps bits 127:8 of the 136, so bit n is word bit n - 8).
  static func bits(_ words: [UInt32], _ high: Int, _ low: Int) -> UInt64 {
    var v: UInt64 = 0
    for b in stride(from: high, through: low, by: -1) {
      let r = b - 8
      v = v << 1 | UInt64(words[r / 32] >> UInt32(r % 32) & 1)
    }
    return v
  }

  /// A CID's product name, printable characters only: an SD card's five
  /// (bits 103:64), an eMMC's six (103:56); empty for an R2 that isn't
  /// four words.
  public static func productName(_ cid: [UInt32], mmc: Bool = false) -> String {
    guard cid.count == 4 else { return "" }
    var name: [UInt8] = []
    for i in 0..<(mmc ? 6 : 5) {
      let c = UInt8(bits(cid, 103 - 8 * i, 96 - 8 * i))
      if c >= 0x20, c < 0x7F { name.append(c) }
    }
    return String(decoding: name, as: UTF8.self)
  }
}

/// A card's CSD, from the four response words of CMD9's R2 (the
/// controller keeps bits 127:8 of the 136, so CSD bit n is bit n - 8).
public struct CSD: Equatable, Sendable {
  /// 0: a standard capacity card's CSD, 1: a high capacity's; an eMMC's
  /// version, its size always as a standard card's.
  public let structure: Int
  public let sectors: UInt64

  public init?(_ words: [UInt32], mmc: Bool = false) {
    guard words.count == 4 else { return nil }
    let bits = { (high: Int, low: Int) in Sdhci.bits(words, high, low) }
    structure = Int(bits(127, 126))
    switch mmc ? 0 : structure {
    case 0:
      let size = bits(73, 62), multiplier = bits(49, 47), blockLength = bits(83, 80)
      sectors = ((size + 1) << (multiplier + 2 + blockLength)) / 512
    case 1:
      sectors = (bits(69, 48) + 1) * 1024
    default:
      return nil
    }
  }
}

/// The OCR, ACMD41's answer.
public enum OCR {
  public static let ready: UInt32 = 1 << 31
  public static let highCapacity: UInt32 = 1 << 30
  /// ACMD41's argument: high capacity supported, 3.2 to 3.4 V.
  public static let request: UInt32 = 1 << 30 | 0x30_0000
  /// CMD1's argument (an eMMC's): sector addressing, 2.7 to 3.6 V and
  /// 1.70 to 1.95 V.
  public static let mmcRequest: UInt32 = 0x40FF_8080
  /// ACMD41's S18R, asking to switch to 1.8 V, and the OCR's S18A, the
  /// card's yes.
  public static let switch18: UInt32 = 1 << 24
}

/// The EXT_CSD an eMMC sends for CMD8: its size and the speeds it has,
/// and the bytes CMD6 switches.
public struct ExtCSD: Sendable {
  /// BUS_WIDTH: 1 four bits, 2 eight.
  public static let busWidth = 183
  /// HS_TIMING: 1 high speed.
  public static let highSpeedTiming = 185
  /// SEC_COUNT (bytes 212-215): a sector-addressed device's size.
  public let sectors: UInt64
  /// DEVICE_TYPE's bit 1: high speed at 52 MHz.
  public let highSpeed52: Bool

  public init(_ bytes: [UInt8]) {
    guard bytes.count >= 512 else {
      sectors = 0
      highSpeed52 = false
      return
    }
    var count: UInt64 = 0
    for i in (212...215).reversed() { count = count << 8 | UInt64(bytes[i]) }
    sectors = count
    highSpeed52 = bytes[196] & 2 != 0
  }
}

/// The SpacemiT K1's registers past the standard ones.
public enum K1 {
  public static let mmcControl = 0x114
  public static let transmitConfig = 0x11C
  public static let phyControl = 0x160
  public static let phyPads = 0x178
  /// TX_INT_CLK_SEL: the transmit clock from inside, at SDR50 and below.
  public static let internalTransmitClock: UInt32 = 1 << 30
  /// The PHY on and its PLL locked (PHY_FUNC_EN, PHY_PLL_LOCK).
  public static let phyOn: UInt32 = 3
  /// MMC_CTRL's SDHC_MMC_CARD_MODE: the controller in its MMC mode.
  public static let cardMode: UInt32 = 1 << 12
  /// The pads' drive strength (bits 2:0) and RX bias (bit 5).
  public static let padsMask: UInt32 = 7 | 1 << 5
  public static let pads: UInt32 = 4 | 1 << 5
  /// The registers' extent: the node's `reg`.
  public static let size = 0x200
}

extension K1 {
  /// SDHC_OP_EXT_REG's clock output overridden and forced on: the
  /// controller otherwise gates the card's clock while no command runs,
  /// and a card switching to 1.8 V must see it for 1 ms before it lets
  /// DAT[3:0] go.
  public static let operationExtra = 0x108
  public static let forceClock: UInt32 = 0x0800 | 0x1000
  /// SDHC_LEGACY_CTRL_REG's GEN_PAD_CLK_ON: the pad's clock generated.
  public static let legacyControl = 0x10C
  public static let padClock: UInt32 = 1 << 6
  /// SDHC_RX_CFG_REG: bits 3:2 (RX_SDCLK_SEL1) 1, the receive clock
  /// through the delay line.
  public static let receiveConfig = 0x118
  public static let receiveThroughLine: UInt32 = 1 << 2
  public static let receiveSelectMask: UInt32 = 3 << 2
  /// TX_MUX_SEL: the transmit clock through its delay line.
  public static let transmitThroughLine: UInt32 = 1 << 31
  /// SDHC_DLINE_CTRL_REG: the lines powered (bit 0), the receive code
  /// (23:16) and the transmit code (31:24).
  public static let delayControl = 0x130
  public static let delayPower: UInt32 = 1
  /// SDHC_DLINE_CFG_REG: each line's range, receive (7:0) and transmit
  /// (23:16).
  public static let delayConfig = 0x134
  /// Linux's: the receive line's range 9, the transmit line's 0 at code
  /// 127, and any run of codes that reads right to choose from.
  public static let receiveRange: UInt32 = 9
  public static let transmitCode: UInt32 = 127
  public static let leastWindow = 1
}

extension Sdhci {
  /// The tuning block a 4-bit card sends for CMD19, as the buffer port's
  /// words read it.
  public static let tuningBlock: [UInt32] = [
    0x00ff_0fff, 0xccc3_ccff, 0xffcc_3cc3, 0xeffe_fffe, 0xddff_dfff, 0xfbff_fbff, 0xff7f_ffbf, 0xefbd_f777,
    0xf0ff_f0ff, 0x3ccc_fc0f, 0xcfcc_33cc, 0xeeff_efff, 0xfdff_fdff, 0xffbf_ffdf, 0xfff7_ffbb, 0xde7b_7ff7,
  ]

  /// Whether `bytes`, as `Host.read` gives them, are the tuning block.
  public static func isTuningBlock(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 4 * tuningBlock.count else { return false }
    for (i, w) in tuningBlock.enumerated() {
      let got = UInt32(bytes[4 * i]) | UInt32(bytes[4 * i + 1]) << 8 | UInt32(bytes[4 * i + 2]) << 16
        | UInt32(bytes[4 * i + 3]) << 24
      guard got == w else { return false }
    }
    return true
  }

  /// The receive delay code to use from a sweep, `passed[code]` whether
  /// the tuning block read right at it: the middle of the longest run of
  /// passes, if it is at least `least` long, as the vendor's driver
  /// chooses; and that run.
  public static func delay(_ passed: [Bool], least: Int) -> (code: Int, window: Range<Int>)? {
    var best = 0..<0, start: Int?
    for i in 0...passed.count {
      if i < passed.count, passed[i] {
        if start == nil { start = i }
      } else if let s = start {
        if i - s > best.count { best = s..<i }
        start = nil
      }
    }
    guard best.count >= least, best.count > 0 else { return nil }
    return ((best.lowerBound + best.upperBound - 1) / 2, best)
  }
}

/// SD's bus speed modes, function group 1 of CMD6: each one's function
/// number, its UHS mode in host control 2, and the clock it runs at.
public enum BusSpeed: Int, Sendable {
  case defaultSpeed = 0, highSpeed = 1, sdr50 = 2, sdr104 = 3

  public var name: String {
    switch self {
    case .defaultSpeed: "default speed"
    case .highSpeed: "high speed"
    case .sdr50: "SDR50"
    case .sdr104: "SDR104"
    }
  }

  /// At 1.8 V: SDR12, SDR25, SDR50 and SDR104 are modes 0 to 3, the
  /// functions' own numbers.
  public var uhsMode: UInt16 { UInt16(rawValue) }

  /// Its clock's ceiling, in Hz.
  public var hz: UInt64 {
    switch self {
    case .defaultSpeed: 25_000_000
    case .highSpeed: 50_000_000
    case .sdr50: 100_000_000
    case .sdr104: 208_000_000
    }
  }
}

/// CMD6's 512-bit status, as `Host.read` gives its 64 bytes (bit 511
/// first): function group 1's supported functions (bits 407:400) and the
/// one it switched to, or would (379:376).
public struct SwitchStatus: Sendable {
  public let supported: UInt8
  public let selected: Int

  public init?(_ bytes: [UInt8]) {
    guard bytes.count >= 64 else { return nil }
    supported = bytes[13]
    selected = Int(bytes[16] & 0xF)
  }

  public func supports(_ s: BusSpeed) -> Bool { supported & 1 << UInt8(s.rawValue) != 0 }

  /// Whether the card offers a mode only a 1.8 V card does: a card
  /// whose signalling a warm boot left at 1.8 V answers ACMD41 without
  /// S18A, and is known by this.
  public var at18: Bool { supported & (1 << 2 | 1 << 3 | 1 << 4) != 0 }
}
