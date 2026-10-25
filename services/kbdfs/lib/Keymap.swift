// SPDX-License-Identifier: BSD-3-Clause

// kbdfs's keymap (D83): a rune for each HID usage of the keyboard page in
// each of 9front's layers but the escaped ones (kbdfs(8): none, shift,
// altgr, ctl, shiftaltgr, mod4, altgrmod4), and the runes keyboard.h gives
// the keys that aren't characters. The built-in map is a US keyboard,
// written by usage; 9front's choices that matter carry over: Enter is
// '\n', Backspace '\b', the Delete key Kdel (the console's interrupt), and
// CapsLock is Ctl, as 9front's ascii map makes it.

import TDUnicode

/// Plan 9's runes for keys (keyboard.h): Unicode's private use area.
public enum KeyRune {
  public static let kf: UInt32 = 0xF000
  public static let spec: UInt32 = 0xF800
  public static func f(_ n: UInt32) -> UInt32 { kf | n }
  public static let home = kf | 0x0D, up = kf | 0x0E, pgup = kf | 0x0F, print = kf | 0x10
  public static let left = kf | 0x11, right = kf | 0x12, pgdown = kf | 0x13, ins = kf | 0x14
  public static let alt = kf | 0x15, shift = kf | 0x16, ctl = kf | 0x17, end = kf | 0x18, scroll = kf | 0x19
  public static let down = spec | 0x00
  public static let brk = spec | 0x61, caps = spec | 0x64, num = spec | 0x65, altgr = spec | 0x67, mod4 = spec | 0x68
  public static let mute = kf | 0x27, voldn = kf | 0x25, volup = kf | 0x26
  public static let eof: UInt32 = 0x04, bs: UInt32 = 0x08, nack: UInt32 = 0x15, etb: UInt32 = 0x17
  public static let esc: UInt32 = 0x1B, del: UInt32 = 0x7F
}

public struct Keymap: Equatable, Sendable {
  public enum Layer: Int, CaseIterable, Sendable {
    case none, shift, altgr, ctl, shiftaltgr, mod4, altgrmod4

    public var name: String {
      switch self {
      case .none: "none"
      case .shift: "shift"
      case .altgr: "altgr"
      case .ctl: "ctl"
      case .shiftaltgr: "shiftaltgr"
      case .mod4: "mod4"
      case .altgrmod4: "altgrmod4"
      }
    }
  }

  public static let usages = 256
  /// Layer by layer, usage by usage.
  var runes: [UInt32]

  public init() { runes = [UInt32](repeating: 0, count: Layer.allCases.count * Self.usages) }

  public subscript(layer: Layer, usage: UInt8) -> UInt32 {
    get { runes[layer.rawValue * Self.usages + Int(usage)] }
    set { runes[layer.rawValue * Self.usages + Int(usage)] = newValue }
  }

  /// A US keyboard.
  public static let us: Keymap = {
    var m = Keymap()
    func both(_ u: UInt8, _ plain: UInt32, _ shifted: UInt32, ctl: UInt32 = 0) {
      m[.none, u] = plain
      m[.shift, u] = shifted
      m[.ctl, u] = ctl
    }
    func every(_ u: UInt8, _ r: UInt32) {
      for l in [Layer.none, .shift, .altgr, .ctl] { m[l, u] = r }
    }
    // Letters, and their control characters.
    for i in 0..<26 {
      let lower = UInt32(0x61 + i)
      both(UInt8(0x04 + i), lower, lower - 0x20, ctl: lower & 0x1F)
    }
    // The digits row.
    let shifted: [UInt32] = [0x21, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28]  // ! @ # $ % ^ & * (
    for i in 0..<9 { both(UInt8(0x1E + i), UInt32(0x31 + i), shifted[i]) }
    both(0x27, 0x30, 0x29)  // 0 )
    both(0x23, 0x36, 0x5E, ctl: 0x1E)  // ^^
    every(0x28, 0x0A)  // Enter
    every(0x29, KeyRune.esc)
    every(0x2A, KeyRune.bs)
    every(0x2B, 0x09)  // Tab
    both(0x2C, 0x20, 0x20)
    both(0x2D, 0x2D, 0x5F, ctl: 0x1F)  // - _ ^_
    both(0x2E, 0x3D, 0x2B)  // = +
    both(0x2F, 0x5B, 0x7B, ctl: 0x1B)  // [ { ^[
    both(0x30, 0x5D, 0x7D, ctl: 0x1D)  // ] } ^]
    both(0x31, 0x5C, 0x7C, ctl: 0x1C)  // \ | ^\
    both(0x33, 0x3B, 0x3A)  // ; :
    both(0x34, 0x27, 0x22)  // ' "
    both(0x35, 0x60, 0x7E)  // ` ~
    both(0x36, 0x2C, 0x3C)  // , <
    both(0x37, 0x2E, 0x3E)  // . >
    both(0x38, 0x2F, 0x3F)  // / ?
    every(0x39, KeyRune.ctl)  // CapsLock, as 9front's ascii map has it
    for i in 0..<12 { every(UInt8(0x3A + i), KeyRune.f(UInt32(1 + i))) }  // F1-F12
    every(0x46, KeyRune.print)
    every(0x47, KeyRune.scroll)
    every(0x48, KeyRune.brk)  // Pause
    every(0x49, KeyRune.ins)
    every(0x4A, KeyRune.home)
    every(0x4B, KeyRune.pgup)
    every(0x4C, KeyRune.del)
    every(0x4D, KeyRune.end)
    every(0x4E, KeyRune.pgdown)
    every(0x4F, KeyRune.right)
    every(0x50, KeyRune.left)
    every(0x51, KeyRune.down)
    every(0x52, KeyRune.up)
    every(0x53, KeyRune.num)
    // The keypad: digits with NumLock on (Keyboard's `navigation` without).
    every(0x54, 0x2F)
    every(0x55, 0x2A)
    every(0x56, 0x2D)
    every(0x57, 0x2B)
    every(0x58, 0x0A)
    for i in 0..<9 { every(UInt8(0x59 + i), UInt32(0x31 + i)) }
    every(0x62, 0x30)
    every(0x63, 0x2E)
    every(0x7F, KeyRune.mute)
    every(0x80, KeyRune.volup)
    every(0x81, KeyRune.voldn)
    // Modifiers.
    every(0xE0, KeyRune.ctl)
    every(0xE1, KeyRune.shift)
    every(0xE2, KeyRune.alt)
    every(0xE3, KeyRune.mod4)
    every(0xE4, KeyRune.ctl)
    every(0xE5, KeyRune.shift)
    every(0xE6, KeyRune.altgr)
    every(0xE7, KeyRune.mod4)
    return m
  }()

  /// The keypad's keys without NumLock: where they move.
  public static func navigation(_ usage: UInt8) -> UInt32? {
    switch usage {
    case 0x59: KeyRune.end
    case 0x5A: KeyRune.down
    case 0x5B: KeyRune.pgdown
    case 0x5C: KeyRune.left
    case 0x5E: KeyRune.right
    case 0x5F: KeyRune.home
    case 0x60: KeyRune.up
    case 0x61: KeyRune.pgup
    case 0x62: KeyRune.ins
    case 0x63: KeyRune.del
    default: nil
    }
  }

  // MARK: kbmap's text

  /// kbmap's reads: a line an entry, `layer usage rune`, each field padded
  /// to 11 characters (kbdfs(8)).
  public var text: String {
    var out: [UInt8] = []
    func field(_ s: String) {
      let b = Array(s.utf8)
      out += [UInt8](repeating: 0x20, count: Swift.max(0, 11 - b.count)) + b
    }
    for layer in Layer.allCases {
      for u in 0..<Self.usages {
        field(layer.name)
        out.append(0x20)
        field(String(u))
        out.append(0x20)
        field(String(self[layer, UInt8(u)]))
        out.append(0x0A)
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Applies kbmap writes: lines `layer usage rune`, the layer by name or
  /// number, the rune a number (decimal, 0x hexadecimal, 0 octal), 'x (the
  /// character x) or ^X (a control character); blank lines and # comments
  /// skipped. False at the first bad line, those before it applied.
  public mutating func apply(_ text: String) -> Bool {
    var line: [UInt8] = []
    for b in Array(text.utf8) + [0x0A] {
      guard b == 0x0A else {
        line.append(b)
        continue
      }
      defer { line = [] }
      let fields = Self.words(line)
      if fields.isEmpty || fields[0].first == UInt8(ascii: "#") { continue }
      guard fields.count == 3, let layer = Self.layer(fields[0]), let usage = Self.number(fields[1]), usage < 256,
        let rune = Self.rune(fields[2])
      else { return false }
      self[layer, UInt8(usage)] = rune
    }
    return true
  }

  static func words(_ line: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = [], word: [UInt8] = []
    for b in line + [0x20] {
      if b == 0x20 || b == 0x09 {
        if !word.isEmpty { out.append(word) }
        word = []
      } else {
        word.append(b)
      }
    }
    return out
  }

  static func layer(_ w: [UInt8]) -> Layer? {
    if let l = Layer.allCases.first(where: { Array($0.name.utf8) == w }) { return l }
    guard let n = number(w) else { return nil }
    return Layer(rawValue: Int(n))
  }

  /// A number as strtoul reads it with base 0.
  static func number(_ w: [UInt8]) -> UInt32? {
    var digits = w[...], base: UInt32 = 10
    if digits.starts(with: Array("0x".utf8)) || digits.starts(with: Array("0X".utf8)) {
      digits = digits.dropFirst(2)
      base = 16
    } else if digits.count > 1, digits.first == UInt8(ascii: "0") {
      digits = digits.dropFirst()
      base = 8
    }
    guard !digits.isEmpty else { return nil }
    var v: UInt32 = 0
    for b in digits {
      let d: UInt32
      switch b {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(b - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(b - UInt8(ascii: "a")) + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(b - UInt8(ascii: "A")) + 10
      default: return nil
      }
      guard d < base else { return nil }
      let (m, o1) = v.multipliedReportingOverflow(by: base)
      let (s, o2) = m.addingReportingOverflow(d)
      guard !o1, !o2 else { return nil }
      v = s
    }
    return v
  }

  static func rune(_ w: [UInt8]) -> UInt32? {
    if w.first == UInt8(ascii: "'"), w.count > 1 { return UTF8Text.first(Array(w.dropFirst())[...])?.scalar }
    if w.first == UInt8(ascii: "^"), w.count == 2 {
      let c = UInt32(w[1])
      return c >= 0x40 && c < 0x60 ? c - 0x40 : nil
    }
    return number(w)
  }
}
