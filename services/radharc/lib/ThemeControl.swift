// SPDX-License-Identifier: BSD-3-Clause

// The theme in force (theming.md §3, D108): which theme, its variant, and
// the roles set live over it (the Appearance editor's), resolved; and the
// commands of the theme tree's `ctl` that change them. A change resolves
// the whole stack again and checks its floor (theming.md §6): a theme
// that doesn't resolve, or fails the floor, is refused with the reason,
// and the one before stays. Its owner locks it.

import Themes

public struct ThemeControl {
  /// The installed themes, by name: their files' bytes.
  public let installed: [(name: String, text: [UInt8])]
  public private(set) var name: String
  public private(set) var variant: String?
  /// High contrast: one switch over every layer (theming.md §6).
  public private(set) var highContrast = false
  /// The user's knobs (D119), each a line of their layer; one the theme
  /// doesn't declare is left out.
  public private(set) var knobs: [(name: String, value: String)] = []
  /// The roles set live, in the order set: a layer over the theme.
  public private(set) var sets: [(role: String, value: String)] = []
  public private(set) var theme: Theme
  /// Raised by one at each change, from 1.
  public private(set) var generation: UInt64 = 1
  /// Why the last refused command was, if one was.
  public private(set) var refusal: String?

  /// `preferred` in force, or the base theme if it doesn't resolve or
  /// fails the floor (the reason is `refusal`).
  public init(preferred: String, installed: [(name: String, text: [UInt8])]) {
    self.installed = installed
    name = "base"
    theme = Theme.base
    variant = nil
    if let refused = apply(preferred, nil, []) { refusal = refused }
    generation = 1
  }

  func file(_ name: String) -> [UInt8]? {
    installed.first { $0.name.utf8.elementsEqual(name.utf8) }?.text
  }

  /// The names installed, the base among them.
  public var names: [String] { ["base"] + installed.map { $0.name } }

  /// Resolves and checks a stack; puts it in force if it passes, else the
  /// reason.
  mutating func apply(_ theme: String, _ variant: String?, _ sets: [(role: String, value: String)],
                      highContrast: Bool? = nil, knobs: [(name: String, value: String)]? = nil) -> String?
  {
    let contrast = highContrast ?? self.highContrast, knobs = knobs ?? self.knobs
    var layers: [ThemeLayer] = []
    if !sets.isEmpty {
      let layer = sets.map { "role=\($0.role) color=\($0.value)\n" }.joined()
      layers.append(ThemeLayer(label: "set", text: Array(layer.utf8)))
    }
    var t: Theme
    do { t = try Theme.resolve(ThemeStack(theme: theme, variant: variant, layers: layers, highContrast: contrast),
                               installed: file) } catch { return error.text }
    // The user's layer: the knobs the theme declares.
    let declared = knobs.filter { k in t.knobs.contains { same($0.name, k.name) } }
    if !declared.isEmpty {
      let layer = declared.map { "knob=\($0.name) value=\($0.value)\n" }.joined()
      do {
        t = try Theme.resolve(ThemeStack(theme: theme, variant: variant,
                                         layers: [ThemeLayer(label: "user", text: Array(layer.utf8))] + layers,
                                         highContrast: contrast), installed: file)
      } catch { return error.text }
    }
    if let finding = ThemeCheck.floor(t, setting: "").first { return finding }
    name = theme
    self.variant = variant
    self.sets = sets
    self.highContrast = contrast
    self.knobs = knobs
    self.theme = t
    generation += 1
    return nil
  }

  /// The theme, high contrast and knobs Settings hold (D119), in force if
  /// they resolve; the reason if not. Nothing changes if they're as they
  /// are: false then.
  public mutating func settle(theme: String, highContrast: Bool, knobs: [(name: String, value: String)])
    throws(ThemeCommandError) -> Bool
  {
    let sameKnobs = knobs.count == self.knobs.count
      && zip(knobs, self.knobs).allSatisfy { same($0.name, $1.name) && same($0.value, $1.value) }
    guard !same(theme, name) || highContrast != self.highContrast || !sameKnobs else { return false }
    // A new theme drops the variant and the roles set live, as `load` does.
    let keep = same(theme, name)
    if let refused = apply(theme, keep ? variant : nil, keep ? sets : [], highContrast: highContrast, knobs: knobs) {
      refusal = refused
      throw ThemeCommandError(reason: refused)
    }
    refusal = nil
    return true
  }

  /// A `ctl` command: `load NAME` (the theme, without a variant or roles
  /// set), `variant NAME` or `variant none`, `set ROLE COLOUR` (a role over
  /// the theme, until the next load), `contrast on|off`, `knob NAME VALUE`
  /// (or `default`). Whether it changed the theme; it
  /// throws the reason it was refused.
  public mutating func command(_ text: String) throws(ThemeCommandError) -> Bool {
    let words = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A })
      .map { String(decoding: $0, as: UTF8.self) }
    func refuse(_ why: String) -> ThemeCommandError {
      refusal = why
      return ThemeCommandError(reason: why)
    }
    guard let verb = words.first else { throw refuse("an empty command") }
    let refused: String?
    if same(verb, "load"), words.count == 2 {
      refused = apply(words[1], nil, [])
    } else if same(verb, "variant"), words.count == 2 {
      refused = apply(name, same(words[1], "none") ? nil : words[1], sets)
    } else if same(verb, "set"), words.count == 3 {
      var s = sets.filter { !same($0.role, words[1]) }
      s.append((words[1], words[2]))
      refused = apply(name, variant, s)
    } else if same(verb, "contrast"), words.count == 2, same(words[1], "on") || same(words[1], "off") {
      refused = apply(name, variant, sets, highContrast: same(words[1], "on"))
    } else if same(verb, "knob"), words.count == 3 {
      var k = knobs.filter { !same($0.name, words[1]) }
      if !same(words[2], "default") { k.append((words[1], words[2])) }
      guard theme.knobs.contains(where: { same($0.name, words[1]) }) else { throw refuse("no knob \(words[1])") }
      refused = apply(name, variant, sets, knobs: k)
    } else {
      throw refuse("\(text.utf8.split(separator: 0x0A).first.map { String(decoding: $0, as: UTF8.self) } ?? ""): "
        + "not load NAME, variant NAME|none, set ROLE COLOUR, contrast on|off or knob NAME VALUE|default")
    }
    if let refused { throw refuse(refused) }
    refusal = nil
    return true
  }

  /// `active`'s text: the theme, its variant, the generation and high
  /// contrast, a line each, then each knob set and each role set live.
  public var active: String {
    "theme \(name)\nvariant \(variant ?? "none")\ngeneration \(generation)\ncontrast \(highContrast ? "on" : "off")\n"
      + knobs.map { "knob \($0.name) \($0.value)\n" }.joined()
      + sets.map { "set \($0.role) \($0.value)\n" }.joined()
  }
}

public struct ThemeCommandError: Error {
  public var reason: String
}

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
