// SPDX-License-Identifier: BSD-3-Clause

// Radharc's input devices (D107): kbdfs's /dev/kbd and the mouse's
// /dev/mouse, as 9front's rio reads them, turned into the InputEvents a
// window's ring carries.
//
// /dev/kbd says which keys are held, as runes without their modifiers,
// after each press (`k`) and release (`K`), and what each press typed
// (`c`). A key's event is the difference from the keys held before; its
// usage is the keymap's way back from the rune (the first usage whose
// unshifted rune it is, then the keypad's navigation), and its character
// the rune itself when it is one. The modifiers are those held after it.
// `c` gives what was typed, shifted: the trusted prompt reads it (Prompt).
//
// /dev/mouse says where the pointer is, in the screen's pixels, and which
// buttons are held; the wheel's are pressed and released a notch at a time
// (mouse(4)), so a notch is a wheel event on its press.

import Kbdfs
import TDUnicode

public struct KeyboardDecoder: Sendable {
  /// Each usage's unshifted rune, by usage.
  var runes: [UInt32]
  public private(set) var held: [UInt32] = []

  public init(map: Keymap = .us) {
    runes = (0..<Keymap.usages).map { map[.none, UInt8($0)] }
  }

  /// The usage a held rune comes from (0: none known).
  public func usage(of rune: UInt32) -> UInt16 {
    if let u = runes.firstIndex(of: rune) { return UInt16(u) }
    for u in 0..<Keymap.usages where Keymap.navigation(UInt8(u)) == rune { return UInt16(u) }
    return 0
  }

  /// Modifier bits for the keys held.
  public static func modifiers(_ held: [UInt32]) -> UInt16 {
    var m: UInt16 = 0
    for r in held {
      switch r {
      case KeyRune.shift: m |= InputEvent.Modifier.shift
      case KeyRune.ctl: m |= InputEvent.Modifier.control
      case KeyRune.alt, KeyRune.altgr: m |= InputEvent.Modifier.alt
      case KeyRune.mod4: m |= InputEvent.Modifier.superKey
      default: break
      }
    }
    return m
  }

  /// A rune as a character, if it is one (the keyboard's own runes, in
  /// Kf's and Spec's ranges, and control characters aren't).
  static func character(_ r: UInt32) -> UInt32 {
    r < 0x20 || r == 0x7F || (r >= KeyRune.kf && r < 0xF900) ? 0 : r
  }

  /// The events in a read of /dev/kbd (whole messages, each ending in a
  /// NUL), at `time`.
  public mutating func decode(_ bytes: [UInt8], time: Int64) -> [InputEvent] {
    var out: [InputEvent] = []
    var start = 0
    while start < bytes.count {
      var end = start
      while end < bytes.count && bytes[end] != 0 { end += 1 }
      let message = bytes[start..<end]
      start = end + 1
      guard let kind = message.first, kind == UInt8(ascii: "k") || kind == UInt8(ascii: "K") else { continue }
      var now: [UInt32] = []
      var rest = message.dropFirst()
      while let (rune, length) = UTF8Text.first(rest) {
        now.append(rune)
        rest = rest.dropFirst(length)
      }
      let mods = Self.modifiers(now)
      for r in held where !now.contains(r) {
        out.append(InputEvent(kind: .keyUp, code: usage(of: r), modifiers: mods, character: Self.character(r), time: time))
      }
      for r in now where !held.contains(r) {
        out.append(InputEvent(kind: .keyDown, code: usage(of: r), modifiers: mods, character: Self.character(r), time: time))
      }
      held = now
    }
    return out
  }

  /// What a read of /dev/kbd typed, in order: its `c` messages' runes,
  /// shifted, with return, tab, backspace and escape as their controls.
  /// The trusted prompt's text.
  public static func typed(_ bytes: [UInt8]) -> [UInt32] {
    var out: [UInt32] = []
    for message in bytes.split(separator: 0) where message.first == UInt8(ascii: "c") {
      if let (rune, _) = UTF8Text.first(message.dropFirst()) { out.append(rune) }
    }
    return out
  }
}

public struct MouseDecoder: Sendable {
  public private(set) var x = -1
  public private(set) var y = -1
  public private(set) var buttons = 0

  public init() {}

  /// A message's x, y, buttons and milliseconds: `m` and four numbers.
  public static func parse(_ bytes: ArraySlice<UInt8>) -> (x: Int, y: Int, buttons: Int, msec: Int64)? {
    guard bytes.first == UInt8(ascii: "m") else { return nil }
    var numbers: [Int64] = []
    var value: Int64 = 0, negative = false, digits = false
    for b in bytes.dropFirst() {
      if b >= 0x30 && b <= 0x39 {
        value = value * 10 + Int64(b - 0x30)
        digits = true
      } else if b == UInt8(ascii: "-") && !digits {
        negative = true
      } else if b == UInt8(ascii: " ") {
        if digits { numbers.append(negative ? -value : value) }
        value = 0
        negative = false
        digits = false
      } else {
        return nil
      }
    }
    if digits { numbers.append(negative ? -value : value) }
    guard numbers.count == 4 else { return nil }
    return (Int(numbers[0]), Int(numbers[1]), Int(numbers[2]), numbers[3])
  }

  /// The events in one 49-byte message: the pointer where it moved to, each
  /// button that changed (1 left, 3 middle, 2 right, as the events number
  /// them), and a wheel notch for each wheel button pressed.
  public mutating func decode(_ bytes: [UInt8]) -> [InputEvent] {
    guard let m = Self.parse(bytes[...]) else { return [] }
    let time = m.msec * 1_000_000
    var out: [InputEvent] = []
    if m.x != x || m.y != y {
      x = m.x
      y = m.y
      out.append(InputEvent(kind: .pointerAbsolute, x: Int32(x), y: Int32(y), time: time))
    }
    for (bit, code) in [(1, 1), (2, 3), (4, 2)] as [(Int, UInt16)] where (m.buttons ^ buttons) & bit != 0 {
      out.append(InputEvent(kind: m.buttons & bit != 0 ? .buttonDown : .buttonUp, code: code, x: Int32(x),
                            y: Int32(y), time: time))
    }
    for (bit, dx, dy) in [(8, 0, 1), (16, 0, -1), (32, -1, 0), (64, 1, 0)] as [(Int, Int32, Int32)]
    where m.buttons & bit != 0 && buttons & bit == 0 {
      out.append(InputEvent(kind: .wheel, x: dx, y: dy, time: time))
    }
    buttons = m.buttons
    return out
  }
}
