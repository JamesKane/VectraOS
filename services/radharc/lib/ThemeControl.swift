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
  mutating func apply(_ theme: String, _ variant: String?, _ sets: [(role: String, value: String)]) -> String? {
    let layer = sets.map { "role=\($0.role) color=\($0.value)\n" }.joined()
    let stack = ThemeStack(theme: theme, variant: variant,
                           layers: sets.isEmpty ? [] : [ThemeLayer(label: "set", text: Array(layer.utf8))])
    let t: Theme
    do { t = try Theme.resolve(stack, installed: file) } catch { return error.text }
    if let finding = ThemeCheck.floor(t, setting: "").first { return finding }
    name = theme
    self.variant = variant
    self.sets = sets
    self.theme = t
    generation += 1
    return nil
  }

  /// A `ctl` command: `load NAME` (the theme, without a variant or roles
  /// set), `variant NAME` or `variant none`, `set ROLE COLOUR` (a role over
  /// the theme, until the next load). Whether it changed the theme; it
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
    } else {
      throw refuse("\(text.utf8.split(separator: 0x0A).first.map { String(decoding: $0, as: UTF8.self) } ?? ""): "
        + "not load NAME, variant NAME|none or set ROLE COLOUR")
    }
    if let refused { throw refuse(refused) }
    refusal = nil
    return true
  }

  /// `active`'s text: the theme, its variant and the generation, a line
  /// each, then each role set live.
  public var active: String {
    "theme \(name)\nvariant \(variant ?? "none")\ngeneration \(generation)\n"
      + sets.map { "set \($0.role) \($0.value)\n" }.joined()
  }
}

public struct ThemeCommandError: Error {
  public var reason: String
}

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
