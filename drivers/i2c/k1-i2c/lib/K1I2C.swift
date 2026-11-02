// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's I2C controller (k1-i2c(3)), a PXA-style "TWSI", as
// bin/k1-i2c drives it: one byte at a time, polled. Each byte is put in
// DBR, then CR's transfer-byte bit set with START for an address byte and
// STOP for the transfer's last, and the controller says it is done with
// tx-empty (ITE) for a byte sent and rx-full (IRF) for one received; a
// received byte that is the last is answered with a NAK. A bus error
// (BED) on an address byte is nothing answering it, on a data byte a
// NAK. Registers and bits are the hardware's (chinese-wall's spacemit-k1
// 04).

public enum K1I2C {
  public static let cr = 0x00, sr = 0x04, dbr = 0x0C, bmr = 0x1C
  /// The registers' extent.
  public static let size = 0x38

  public enum Control {
    public static let start: UInt32 = 1 << 0, stop: UInt32 = 1 << 1, nak: UInt32 = 1 << 2, transferByte: UInt32 = 1 << 3
    public static let fast: UInt32 = 1 << 8, unitReset: UInt32 = 1 << 10, sclEnable: UInt32 = 1 << 13
    public static let unitEnable: UInt32 = 1 << 14, noGeneralCall: UInt32 = 1 << 21, stopDetect: UInt32 = 1 << 26
  }

  public enum Status {
    public static let nakReceived: UInt32 = 1 << 14, unitBusy: UInt32 = 1 << 15, busBusy: UInt32 = 1 << 16
    public static let arbitrationLost: UInt32 = 1 << 18, txEmpty: UInt32 = 1 << 19, rxFull: UInt32 = 1 << 20
    public static let busError: UInt32 = 1 << 22, stopDetected: UInt32 = 1 << 26
    /// The bits written 1 to clear.
    public static let clear: UInt32 = 0xFFFC_0000 | 1 << 14
  }

  /// The control word a transfer runs with: the unit on, SCL driven, no
  /// general call, a STOP detected, and fast mode (400 kHz) above 100 kHz.
  public static func base(frequency: UInt32) -> UInt32 {
    Control.unitEnable | Control.sclEnable | Control.noGeneralCall | Control.stopDetect
      | (frequency > 100_000 ? Control.fast : 0)
  }

  /// One byte on the bus.
  public enum Step: Equatable, Sendable {
    /// An address byte (the address, and bit 0 for a read), after a START.
    case address(UInt8, stop: Bool)
    case send(UInt8, stop: Bool)
    /// A byte read; the last NAKed and STOPped.
    case receive(last: Bool)

    /// CR's bits for it, over `base`.
    public func control(_ base: UInt32) -> UInt32 {
      switch self {
      case .address(_, let stop): base | Control.start | Control.transferByte | (stop ? Control.stop : 0)
      case .send(_, let stop): base | Control.transferByte | (stop ? Control.stop : 0)
      case .receive(let last): base | Control.transferByte | (last ? Control.stop | Control.nak : 0)
      }
    }

    /// The byte put in DBR first, if any.
    public var byte: UInt8? {
      switch self {
      case .address(let b, _), .send(let b, _): b
      case .receive: nil
      }
    }

    /// SR's bit that says it is done.
    public var done: UInt32 { if case .receive = self { Status.rxFull } else { Status.txEmpty } }
  }

  /// The steps of a transfer to `address`: `write` sent, then after a
  /// repeated start `read` bytes received; an address alone (a probe)
  /// where both are empty.
  public static func steps(address: UInt8, write: [UInt8], read: Int) -> [Step] {
    let a = (address & 0x7F) << 1
    guard !write.isEmpty || read > 0 else { return [.address(a, stop: true)] }
    var out: [Step] = []
    if !write.isEmpty {
      out.append(.address(a, stop: false))
      for (i, b) in write.enumerated() { out.append(.send(b, stop: i == write.count - 1 && read == 0)) }
    }
    if read > 0 {
      out.append(.address(a | 1, stop: false))
      for i in 0..<read { out.append(.receive(last: i == read - 1)) }
    }
    return out
  }
}
