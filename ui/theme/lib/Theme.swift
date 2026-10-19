// SPDX-License-Identifier: BSD-3-Clause

// A resolved theme (D109): what the stack of theme files comes to, as
// UICore, Radharc and the apps read it. Styles by class with dot fallback
// ("button.primary" is its own style if the theme has one, else
// "button"'s, else "default"'s), roles by name; both kept in sorted
// arrays, since tier 0 has no Dictionary, and compared by their bytes.

/// A parameter a theme's author means people to turn (D108).
public struct Knob: Sendable {
  public enum Kind: UInt8, Sendable { case role, choice, length, scale }

  public var name: String
  public var kind: Kind
  public var label: String?
  public var defaultValue: String
  /// What it is set to, by a layer or by its default.
  public var value: String
  /// A role knob's suggestions; a choice knob's choices.
  public var options: [String]
  /// A length or scale knob's bounds.
  public var min: Double
  public var max: Double

  public init(name: String, kind: Kind, label: String?, defaultValue: String, value: String, options: [String],
              min: Double, max: Double)
  {
    self.name = name
    self.kind = kind
    self.label = label
    self.defaultValue = defaultValue
    self.value = value
    self.options = options
    self.min = min
    self.max = max
  }
}

public struct Theme: Sendable {
  public let name: String
  public let title: String
  public let variant: String?
  /// How much larger than its theme's the type is (high contrast's
  /// larger type, a layer's `textscale`).
  public let textScale: Float
  public let knobs: [Knob]
  let roleNames: [String]
  let roleColors: [UInt32]
  let styleNames: [String]
  let styleValues: [Style]
  let faces: [Typeface]  // by FontRole's raw value

  public init(name: String, title: String, variant: String?, textScale: Float, knobs: [Knob],
       roles: [(String, UInt32)], styles: [(String, Style)], faces: [Typeface])
  {
    self.name = name
    self.title = title
    self.variant = variant
    self.textScale = textScale
    self.knobs = knobs
    let r = roles.sorted { before($0.0, $1.0) }
    roleNames = r.map { $0.0 }
    roleColors = r.map { $0.1 }
    let s = styles.sorted { before($0.0, $1.0) }
    styleNames = s.map { $0.0 }
    styleValues = s.map { $0.1 }
    self.faces = faces
  }

  static func index(_ name: Substring, in names: [String]) -> Int? {
    var lo = 0, hi = names.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if names[mid].utf8.lexicographicallyPrecedes(name.utf8) { lo = mid + 1 } else { hi = mid }
    }
    return lo < names.count && names[lo].utf8.elementsEqual(name.utf8) ? lo : nil
  }

  /// A role's colour, or magenta for a role the theme hasn't: impossible
  /// to miss.
  public func color(_ role: String) -> UInt32 {
    Theme.index(role[...], in: roleNames).map { roleColors[$0] } ?? 0xFFFF_00FF
  }

  public func hasRole(_ role: String) -> Bool { Theme.index(role[...], in: roleNames) != nil }

  /// Every role it resolves, sorted.
  public var roles: [String] { roleNames }

  /// Every class it defines, sorted.
  public var classes: [String] { styleNames }

  /// The style for a class: its own, or by dot fallback to "default".
  /// A pressed class (`X.held`) the theme doesn't define is derived from
  /// X's style (`Style.held`).
  public func style(_ name: String) -> Style {
    if Theme.index(name[...], in: styleNames) == nil, name.utf8.count > 5,
       name.utf8.suffix(5).elementsEqual(".held".utf8)
    {
      return style(String(decoding: name.utf8.dropLast(5), as: UTF8.self)).held
    }
    var n = name[...]
    while true {
      if let i = Theme.index(n, in: styleNames) { return styleValues[i] }
      guard let dot = n.utf8.lastIndex(of: UInt8(ascii: ".")) else { break }
      n = n[..<dot]
    }
    return Theme.index("default", in: styleNames).map { styleValues[$0] } ?? Style(ink: color("ink"))
  }

  /// Whether the theme defines the class itself (no fallback).
  public func defines(_ name: String) -> Bool { Theme.index(name[...], in: styleNames) != nil }

  /// The typeface for a font role.
  public func typeface(_ role: FontRole) -> Typeface { faces[Int(role.rawValue)] }

  /// A knob's value, if the theme has the knob.
  public func knob(_ name: String) -> String? { knobs.first { same($0.name, name) }?.value }

  /// cqw, the unit todhchai's storyboard was drawn in: a hundredth of a
  /// 1280-pixel logical screen, in logical pixels.
  public static func cqw(_ v: Float) -> Float { v * 12.8 }
}

func before(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
