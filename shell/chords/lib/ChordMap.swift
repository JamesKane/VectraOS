// SPDX-License-Identifier: BSD-3-Clause

// The chord map (D116): what each chord does, as a line for Radharc's
// /svc/windows/ctl. It is kept in Settings' `Chords` area, one string
// attribute a chord, `Chords:super-1` = `workspace 1`; with none there,
// the defaults below. A chord's name is its modifiers and its key joined
// by `-`: `super`, `shift`, `ctrl`, `alt`, then a letter, a digit,
// `return`, `tab`, `space`, `esc` or `f1` to `f12`.

/// A key by HID usage and the modifiers held with it (Radharc's
/// InputEvent bits: shift 1, control 2, alt 4, super 8).
public struct ChordKey: Equatable, Sendable {
  public var code: UInt16
  public var modifiers: UInt16
  public init(code: UInt16, modifiers: UInt16) {
    self.code = code
    self.modifiers = modifiers
  }

  /// A chord's name parsed; nil if it isn't one, or has no modifier.
  public init?(_ name: String) {
    let parts = name.utf8.split(separator: UInt8(ascii: "-")).map { String(decoding: $0, as: UTF8.self) }
    guard parts.count >= 2, let key = parts.last else { return nil }
    var m: UInt16 = 0
    for p in parts.dropLast() {
      let bit: UInt16
      if same(p, "shift") {
        bit = 1
      } else if same(p, "ctrl") {
        bit = 2
      } else if same(p, "alt") {
        bit = 4
      } else if same(p, "super") {
        bit = 8
      } else {
        return nil
      }
      guard m & bit == 0 else { return nil }
      m |= bit
    }
    // A chord with only shift would take a typed capital.
    guard m & ~1 != 0, let code = Self.usage(key) else { return nil }
    self.init(code: code, modifiers: m)
  }

  /// A key's HID usage by name.
  static func usage(_ k: String) -> UInt16? {
    let b = Array(k.utf8)
    if b.count == 1 {
      if b[0] >= 0x61 && b[0] <= 0x7A { return 0x04 + UInt16(b[0] - 0x61) }
      if b[0] >= 0x31 && b[0] <= 0x39 { return 0x1E + UInt16(b[0] - 0x31) }
      if b[0] == 0x30 { return 0x27 }
      return nil
    }
    for (name, code) in [("return", 0x28), ("esc", 0x29), ("tab", 0x2B), ("space", 0x2C)] as [(String, UInt16)]
    where same(k, name) {
      return code
    }
    if b.first == UInt8(ascii: "f"), b.count <= 3, b.dropFirst().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
      let n = b.dropFirst().reduce(0) { $0 * 10 + Int($1 - 0x30) }
      if n >= 1 && n <= 12 { return 0x3A + UInt16(n - 1) }
    }
    return nil
  }
}

public enum ChordMap {
  public static let area = "Chords"

  /// The map when Settings has none.
  public static let defaults: [(chord: String, action: String)] = [
    ("super-1", "workspace 1"), ("super-2", "workspace 2"), ("super-3", "workspace 3"), ("super-4", "workspace 4"),
    ("super-shift-1", "send 1"), ("super-shift-2", "send 2"), ("super-shift-3", "send 3"), ("super-shift-4", "send 4"),
    ("super-shift-t", "mode toggle"),
    ("super-j", "act focus next"), ("super-k", "act focus prev"), ("super-return", "act swap"),
    ("super-h", "act shrink"), ("super-l", "act grow"),
  ]

  /// The map from the area's attributes (`Chords:NAME` = ACTION): the
  /// defaults if there are none; chords that don't parse, and empty
  /// actions, left out, and each chord once.
  public static func map(_ attributes: [(name: String, action: String)]) -> [(key: ChordKey, chord: String, action: String)] {
    let prefix = Array((area + ":").utf8)
    let kept: [(chord: String, action: String)] = attributes.filter { Array($0.name.utf8).starts(with: prefix) }
      .map { (chord: String(decoding: Array($0.name.utf8).dropFirst(prefix.count), as: UTF8.self), action: $0.action) }
    var out: [(key: ChordKey, chord: String, action: String)] = []
    for (chord, action) in kept.isEmpty ? defaults : kept {
      guard let key = ChordKey(chord), !action.utf8.isEmpty, !out.contains(where: { $0.key == key }) else { continue }
      out.append((key, chord, action))
    }
    return out
  }
}

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
