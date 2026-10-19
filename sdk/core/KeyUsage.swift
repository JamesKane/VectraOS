// SPDX-License-Identifier: BSD-3-Clause

// Keys by HID usage (sdk(2)): the keyboard page (0x07) of the USB-IF HID
// Usage Tables 1.5, §10, names the physical key whatever the layout, so
// `.w` is the same key on QWERTY and AZERTY. Radharc's input events carry
// it (`InputEvent.code`), as kbdfs has it from the keyboard.

public struct KeyUsage: RawRepresentable, Hashable, Sendable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let a = KeyUsage(rawValue: 0x04), b = KeyUsage(rawValue: 0x05), c = KeyUsage(rawValue: 0x06)
  public static let d = KeyUsage(rawValue: 0x07), e = KeyUsage(rawValue: 0x08), f = KeyUsage(rawValue: 0x09)
  public static let g = KeyUsage(rawValue: 0x0a), h = KeyUsage(rawValue: 0x0b), i = KeyUsage(rawValue: 0x0c)
  public static let j = KeyUsage(rawValue: 0x0d), k = KeyUsage(rawValue: 0x0e), l = KeyUsage(rawValue: 0x0f)
  public static let m = KeyUsage(rawValue: 0x10), n = KeyUsage(rawValue: 0x11), o = KeyUsage(rawValue: 0x12)
  public static let p = KeyUsage(rawValue: 0x13), q = KeyUsage(rawValue: 0x14), r = KeyUsage(rawValue: 0x15)
  public static let s = KeyUsage(rawValue: 0x16), t = KeyUsage(rawValue: 0x17), u = KeyUsage(rawValue: 0x18)
  public static let v = KeyUsage(rawValue: 0x19), w = KeyUsage(rawValue: 0x1a), x = KeyUsage(rawValue: 0x1b)
  public static let y = KeyUsage(rawValue: 0x1c), z = KeyUsage(rawValue: 0x1d)
  public static let digit1 = KeyUsage(rawValue: 0x1e), digit2 = KeyUsage(rawValue: 0x1f), digit3 = KeyUsage(rawValue: 0x20)
  public static let digit4 = KeyUsage(rawValue: 0x21), digit5 = KeyUsage(rawValue: 0x22), digit6 = KeyUsage(rawValue: 0x23)
  public static let digit7 = KeyUsage(rawValue: 0x24), digit8 = KeyUsage(rawValue: 0x25), digit9 = KeyUsage(rawValue: 0x26)
  public static let digit0 = KeyUsage(rawValue: 0x27)
  public static let enter = KeyUsage(rawValue: 0x28), escape = KeyUsage(rawValue: 0x29)
  public static let backspace = KeyUsage(rawValue: 0x2a), tab = KeyUsage(rawValue: 0x2b), space = KeyUsage(rawValue: 0x2c)
  public static let minus = KeyUsage(rawValue: 0x2d), equal = KeyUsage(rawValue: 0x2e)
  public static let leftBracket = KeyUsage(rawValue: 0x2f), rightBracket = KeyUsage(rawValue: 0x30)
  public static let backslash = KeyUsage(rawValue: 0x31), nonUSHash = KeyUsage(rawValue: 0x32)
  public static let semicolon = KeyUsage(rawValue: 0x33), apostrophe = KeyUsage(rawValue: 0x34)
  public static let grave = KeyUsage(rawValue: 0x35), comma = KeyUsage(rawValue: 0x36), period = KeyUsage(rawValue: 0x37)
  public static let slash = KeyUsage(rawValue: 0x38), capsLock = KeyUsage(rawValue: 0x39)
  public static let f1 = KeyUsage(rawValue: 0x3a), f2 = KeyUsage(rawValue: 0x3b), f3 = KeyUsage(rawValue: 0x3c)
  public static let f4 = KeyUsage(rawValue: 0x3d), f5 = KeyUsage(rawValue: 0x3e), f6 = KeyUsage(rawValue: 0x3f)
  public static let f7 = KeyUsage(rawValue: 0x40), f8 = KeyUsage(rawValue: 0x41), f9 = KeyUsage(rawValue: 0x42)
  public static let f10 = KeyUsage(rawValue: 0x43), f11 = KeyUsage(rawValue: 0x44), f12 = KeyUsage(rawValue: 0x45)
  public static let printScreen = KeyUsage(rawValue: 0x46), scrollLock = KeyUsage(rawValue: 0x47)
  public static let pause = KeyUsage(rawValue: 0x48), insert = KeyUsage(rawValue: 0x49), home = KeyUsage(rawValue: 0x4a)
  public static let pageUp = KeyUsage(rawValue: 0x4b), delete = KeyUsage(rawValue: 0x4c), end = KeyUsage(rawValue: 0x4d)
  public static let pageDown = KeyUsage(rawValue: 0x4e), right = KeyUsage(rawValue: 0x4f), left = KeyUsage(rawValue: 0x50)
  public static let down = KeyUsage(rawValue: 0x51), up = KeyUsage(rawValue: 0x52), numLock = KeyUsage(rawValue: 0x53)
  public static let keypadSlash = KeyUsage(rawValue: 0x54), keypadAsterisk = KeyUsage(rawValue: 0x55)
  public static let keypadMinus = KeyUsage(rawValue: 0x56), keypadPlus = KeyUsage(rawValue: 0x57)
  public static let keypadEnter = KeyUsage(rawValue: 0x58)
  public static let keypad1 = KeyUsage(rawValue: 0x59), keypad2 = KeyUsage(rawValue: 0x5a), keypad3 = KeyUsage(rawValue: 0x5b)
  public static let keypad4 = KeyUsage(rawValue: 0x5c), keypad5 = KeyUsage(rawValue: 0x5d), keypad6 = KeyUsage(rawValue: 0x5e)
  public static let keypad7 = KeyUsage(rawValue: 0x5f), keypad8 = KeyUsage(rawValue: 0x60), keypad9 = KeyUsage(rawValue: 0x61)
  public static let keypad0 = KeyUsage(rawValue: 0x62), keypadPeriod = KeyUsage(rawValue: 0x63)
  public static let nonUSBackslash = KeyUsage(rawValue: 0x64), application = KeyUsage(rawValue: 0x65)
  public static let power = KeyUsage(rawValue: 0x66), keypadEqual = KeyUsage(rawValue: 0x67)
  public static let f13 = KeyUsage(rawValue: 0x68), f14 = KeyUsage(rawValue: 0x69), f15 = KeyUsage(rawValue: 0x6a)
  public static let f16 = KeyUsage(rawValue: 0x6b), f17 = KeyUsage(rawValue: 0x6c), f18 = KeyUsage(rawValue: 0x6d)
  public static let f19 = KeyUsage(rawValue: 0x6e), f20 = KeyUsage(rawValue: 0x6f), f21 = KeyUsage(rawValue: 0x70)
  public static let f22 = KeyUsage(rawValue: 0x71), f23 = KeyUsage(rawValue: 0x72), f24 = KeyUsage(rawValue: 0x73)
  public static let mute = KeyUsage(rawValue: 0x7f), volumeUp = KeyUsage(rawValue: 0x80)
  public static let volumeDown = KeyUsage(rawValue: 0x81), keypadComma = KeyUsage(rawValue: 0x85)
  public static let leftControl = KeyUsage(rawValue: 0xe0), leftShift = KeyUsage(rawValue: 0xe1)
  public static let leftAlt = KeyUsage(rawValue: 0xe2), leftSuper = KeyUsage(rawValue: 0xe3)
  public static let rightControl = KeyUsage(rawValue: 0xe4), rightShift = KeyUsage(rawValue: 0xe5)
  public static let rightAlt = KeyUsage(rawValue: 0xe6), rightSuper = KeyUsage(rawValue: 0xe7)
  /// No key.
  public static let unknown = KeyUsage(rawValue: 0)

  /// Whether this is a modifier key (the keyboard page's 0xE0–0xE7).
  public var isModifier: Bool { rawValue >= 0xe0 && rawValue <= 0xe7 }
}
