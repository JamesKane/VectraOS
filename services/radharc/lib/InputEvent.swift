// SPDX-License-Identifier: BSD-3-Clause

// What Radharc hands a window (architecture §13): keys by HID usage with
// the modifiers after the event and the key's unmodified character for the
// layout; the pointer in the window's content; buttons and wheels. Each 40
// bytes in the window's ring (WindowInput.swift). Radharc makes them from
// kbdfs's /dev/kbd and the mouse's /dev/mouse (Devices.swift), which give
// no repeat and no relative motion: `isRepeat` is never set, and the
// pointer comes as `pointerAbsolute` in pixels.

public struct InputEvent: Equatable, Sendable {
  public enum Kind: UInt8, Sendable {
    case keyDown = 1, keyUp
    /// Relative motion: `x`, `y` unaccelerated, `ax`, `ay` accelerated.
    case pointerMotion
    /// An absolute position (a tablet): `x`, `y` from 0 to 32767.
    case pointerAbsolute
    case buttonDown, buttonUp
    /// `x` horizontal, `y` vertical notches.
    case wheel
  }

  /// Modifier bits, after the event.
  public enum Modifier {
    public static let shift: UInt16 = 1 << 0
    public static let control: UInt16 = 1 << 1
    public static let alt: UInt16 = 1 << 2
    public static let superKey: UInt16 = 1 << 3
    public static let capsLock: UInt16 = 1 << 4
  }

  /// `flags` bits.
  public static let isRepeat: UInt8 = 1 << 0
  /// Synthetic (M6k k6b: Radharc's `inject`): an app may ignore it; a
  /// secure surface never gets it.
  public static let isInjected: UInt8 = 1 << 1

  public var kind: Kind
  public var flags: UInt8 = 0
  /// Keys: the HID usage. Buttons: 1 left, 2 right, 3 middle.
  public var code: UInt16 = 0
  public var modifiers: UInt16 = 0
  /// Which device: the input service's index.
  public var device: UInt16 = 0
  /// Keys: the unmodified character for the layout (0 for none).
  public var character: UInt32 = 0
  public var x: Int32 = 0
  public var y: Int32 = 0
  public var ax: Int32 = 0
  public var ay: Int32 = 0
  /// Monotonic nanoseconds, from the device where it gives a time.
  public var time: Int64 = 0

  public init(kind: Kind, flags: UInt8 = 0, code: UInt16 = 0, modifiers: UInt16 = 0, device: UInt16 = 0,
              character: UInt32 = 0, x: Int32 = 0, y: Int32 = 0, ax: Int32 = 0, ay: Int32 = 0, time: Int64 = 0)
  {
    self.kind = kind
    self.flags = flags
    self.code = code
    self.modifiers = modifiers
    self.device = device
    self.character = character
    self.x = x
    self.y = y
    self.ax = ax
    self.ay = ay
    self.time = time
  }

  public static let size = 40

  /// Its 40 bytes, little-endian.
  public func encode(into p: UnsafeMutableRawPointer) {
    unsafe p.storeBytes(of: kind.rawValue, toByteOffset: 0, as: UInt8.self)
    unsafe p.storeBytes(of: flags, toByteOffset: 1, as: UInt8.self)
    unsafe p.storeBytes(of: code.littleEndian, toByteOffset: 2, as: UInt16.self)
    unsafe p.storeBytes(of: modifiers.littleEndian, toByteOffset: 4, as: UInt16.self)
    unsafe p.storeBytes(of: device.littleEndian, toByteOffset: 6, as: UInt16.self)
    unsafe p.storeBytes(of: character.littleEndian, toByteOffset: 8, as: UInt32.self)
    unsafe p.storeBytes(of: x.littleEndian, toByteOffset: 12, as: Int32.self)
    unsafe p.storeBytes(of: y.littleEndian, toByteOffset: 16, as: Int32.self)
    unsafe p.storeBytes(of: ax.littleEndian, toByteOffset: 20, as: Int32.self)
    unsafe p.storeBytes(of: ay.littleEndian, toByteOffset: 24, as: Int32.self)
    unsafe p.storeBytes(of: UInt32(0), toByteOffset: 28, as: UInt32.self)
    unsafe p.storeBytes(of: time.littleEndian, toByteOffset: 32, as: Int64.self)
  }

  /// The event in 40 bytes at `p`, or nil if its kind is unknown.
  public init?(decoding p: UnsafeRawPointer) {
    guard let kind = Kind(rawValue: unsafe p.load(fromByteOffset: 0, as: UInt8.self)) else { return nil }
    func i32(_ o: Int) -> Int32 { Int32(littleEndian: unsafe p.loadUnaligned(fromByteOffset: o, as: Int32.self)) }
    self.kind = kind
    flags = unsafe p.load(fromByteOffset: 1, as: UInt8.self)
    code = UInt16(littleEndian: unsafe p.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
    modifiers = UInt16(littleEndian: unsafe p.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
    device = UInt16(littleEndian: unsafe p.loadUnaligned(fromByteOffset: 6, as: UInt16.self))
    character = UInt32(littleEndian: unsafe p.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
    x = i32(12)
    y = i32(16)
    ax = i32(20)
    ay = i32(24)
    time = Int64(littleEndian: unsafe p.loadUnaligned(fromByteOffset: 32, as: Int64.self))
  }
}
