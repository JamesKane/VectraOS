// SPDX-License-Identifier: BSD-3-Clause

// The input class's pointers (D83): drivers write mouse(4)'s mousein
// records, as 9front's nusb/kb does. This gathers a device's evdev events
// (virtio-input's, as Linux's) up to its SYN_REPORT, after todhchai's
// Normalizer: relative motion and the wheel summed, an absolute position
// kept and scaled from the axis's range to mousein's 0 to 2^31, the
// buttons as Plan 9 numbers them (1 left, 2 middle, 4 right). Each notch
// of the wheel is a record of its own, with 8 or 16 (up, down) or 32 or
// 64 (left, right).

public struct PointerReport: Sendable {
  /// evdev's codes (input-event-codes.h).
  public static let syn: UInt16 = 0, key: UInt16 = 1, rel: UInt16 = 2, abs: UInt16 = 3
  static let relX: UInt16 = 0, relY: UInt16 = 1, relHWheel: UInt16 = 6, relWheel: UInt16 = 8
  static let absX: UInt16 = 0, absY: UInt16 = 1
  static let buttonLeft: UInt16 = 0x110, buttonRight: UInt16 = 0x111, buttonMiddle: UInt16 = 0x112

  /// The absolute axes' ranges, from the device (virtio's abs info).
  public var rangeX: ClosedRange<Int32>?, rangeY: ClosedRange<Int32>?
  public private(set) var buttons: Int32 = 0
  var dx: Int32 = 0, dy: Int32 = 0, wheel: Int32 = 0, hwheel: Int32 = 0
  /// The last absolute position, scaled; nil until the device gives one.
  var x: Int64?, y: Int64?
  var changed = false

  public init(rangeX: ClosedRange<Int32>? = nil, rangeY: ClosedRange<Int32>? = nil) {
    self.rangeX = rangeX
    self.rangeY = rangeY
  }

  /// Whether `code`, an EV_KEY's, is a pointer's button.
  public static func isButton(_ code: UInt16) -> Bool { code >= buttonLeft && code <= buttonMiddle }

  /// Takes an event; at a SYN_REPORT, the mousein records since the last
  /// (none if nothing changed).
  public mutating func take(type: UInt16, code: UInt16, value: Int32) -> [UInt8] {
    switch type {
    case Self.key where Self.isButton(code) && value != 2:
      let bit: Int32 = code == Self.buttonLeft ? 1 : code == Self.buttonMiddle ? 2 : 4
      let now = value != 0 ? buttons | bit : buttons & ~bit
      if now != buttons { (buttons, changed) = (now, true) }
    case Self.rel:
      switch code {
      case Self.relX: dx &+= value
      case Self.relY: dy &+= value
      case Self.relWheel: wheel &+= value
      case Self.relHWheel: hwheel &+= value
      default: return []
      }
      changed = true
    case Self.abs where code == Self.absX:
      x = Self.scaled(value, rangeX)
      changed = true
    case Self.abs where code == Self.absY:
      y = Self.scaled(value, rangeY)
      changed = true
    case Self.syn where code == 0:
      return report()
    default:
      break
    }
    return []
  }

  /// `value` from the axis's range to 0 to 2^31 (unknown: as it is).
  static func scaled(_ value: Int32, _ range: ClosedRange<Int32>?) -> Int64 {
    guard let range, range.upperBound > range.lowerBound else { return Int64(max(value, 0)) }
    let v = Int64(min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
    return v * (1 << 31) / (Int64(range.upperBound) - Int64(range.lowerBound) + 1)
  }

  mutating func report() -> [UInt8] {
    guard changed else { return [] }
    var out: [UInt8] = []
    func line(_ b: Int32, moving: Bool) {
      if let x, let y {
        out += Array("a\(x) \(y) \(b)\n".utf8)
      } else {
        out += Array("m\(moving ? dx : 0) \(moving ? dy : 0) \(b)\n".utf8)
      }
    }
    if dx != 0 || dy != 0 || wheel == 0 && hwheel == 0 { line(buttons, moving: true) }
    // Wheel up is evdev's positive; so is right.
    for _ in 0..<min(Swift.abs(wheel), 16) { line(buttons | (wheel > 0 ? 8 : 16), moving: false) }
    for _ in 0..<min(Swift.abs(hwheel), 16) { line(buttons | (hwheel > 0 ? 64 : 32), moving: false) }
    (dx, dy, wheel, hwheel, changed) = (0, 0, 0, 0, false)
    return out
  }
}
