// SPDX-License-Identifier: BSD-3-Clause

// theme check (theming.md §6 and §7, D108, D109): a theme resolves, every
// required role with it, and the floor holds, in every variant and at
// each knob's extremes (the others at their defaults):
// - ink, ink.dim and lcd.ink 4.5:1 against their surfaces, ink.on-select
//   on selection and ink.on-focus on focus, and each part's ink on its
//   own opaque fill (a part whose ink is its fill draws no text: a rule);
// - control, the meanings and the lamps 3:1 against the surfaces they
//   sit on, the desk aside; the lamps distinct from each other.

public enum ThemeCheck {
  /// The findings for a theme and the layers over it, as `file:line:
  /// message` lines; none if it passes.
  public static func check(_ theme: String, layers: [ThemeLayer] = [], installed: (String) -> [UInt8]?)
    -> [String]
  {
    let chain: [ThemeFile]
    do { chain = try Theme.loadChain(theme, installed: installed) } catch { return [error.text] }
    var variants: [String?] = [nil]
    for f in chain { for v in f.variants where !variants.contains(where: { $0.map { same($0, v) } ?? false }) {
      variants.append(v)
    } }
    var findings: [String] = []
    for v in variants {
      let stack = ThemeStack(theme: theme, variant: v, layers: layers)
      let t: Theme
      do { t = try Theme.resolve(stack, installed: installed) } catch {
        findings.append(error.text)
        continue
      }
      findings += floor(t, setting: "")
      // Each knob at its extremes, the others at their defaults.
      for k in t.knobs {
        for value in extremes(k) where !same(value, k.value) {
          var s = stack
          s.knobs = [(k.name, value)]
          do { findings += floor(try Theme.resolve(s, installed: installed), setting: "knob \(k.name)=\(value)") } catch {
            findings.append(error.text)
          }
        }
      }
    }
    var unique: [String] = []
    for f in findings where !unique.contains(where: { same($0, f) }) { unique.append(f) }
    return unique
  }

  static func extremes(_ k: Knob) -> [String] {
    switch k.kind {
    case .role, .choice: k.options
    case .length, .scale: [number(k.min), number(k.max)]
    }
  }

  /// The floor's findings for one resolved theme.
  public static func floor(_ t: Theme, setting: String) -> [String] {
    var out: [String] = []
    var place = t.name
    if let v = t.variant { place += " (variant \(v))" }
    if !setting.isEmpty { place += " with " + setting }
    for r in Roles.required where !t.hasRole(r) { out.append(place + ": no role \(r)") }
    func need(_ a: String, on b: String, _ floor: Double) {
      guard t.hasRole(a), t.hasRole(b) else { return }
      let r = Contrast.ratio(t.color(a), t.color(b))
      if r < floor { out.append(place + ": \(a) on \(b) is \(ratioText(r)), under \(ratioText(floor))") }
    }
    for s in Roles.surfaces {
      need("ink", on: s, 4.5)
      need("ink.dim", on: s, 4.5)
    }
    need("ink.on-select", on: "selection", 4.5)
    need("ink.on-focus", on: "focus", 4.5)
    need("lcd.ink", on: "lcd", 4.5)
    for s in Roles.surfaces where !same(s, "desk") {
      need("control", on: s, 3)
      for m in Roles.meanings { need(m, on: s, 3) }
    }
    for l in Roles.lamps { need(l, on: "chrome", 3) }
    for (i, a) in Roles.lamps.enumerated() {
      for b in Roles.lamps[(i + 1)...] where t.hasRole(a) && t.hasRole(b) && t.color(a) & 0xFF_FFFF == t.color(b) & 0xFF_FFFF {
        out.append(place + ": \(a) and \(b) are the same colour")
      }
    }
    for c in t.classes {
      let s = t.style(c)
      guard s.fill >> 24 == 0xFF, s.ink >> 24 != 0, s.ink != s.fill else { continue }
      let r = Contrast.ratio(s.ink, s.fill)
      if r < 4.5 { out.append(place + ": part \(c)'s ink on its fill is \(ratioText(r)), under 4.5:1") }
    }
    return out
  }

  /// A bound as a theme file writes it: to four places, no trailing zeros.
  static func number(_ v: Double) -> String {
    let negative = v < 0
    var n = Int((negative ? -v : v) * 10000 + 0.5)
    var frac: [UInt8] = []
    for _ in 0..<4 {
      frac.insert(UInt8(ascii: "0") + UInt8(n % 10), at: 0)
      n /= 10
    }
    while frac.last == UInt8(ascii: "0") { frac.removeLast() }
    let tail = frac.isEmpty ? "" : "." + String(decoding: frac, as: UTF8.self)
    return (negative ? "-" : "") + String(n) + tail
  }
}
