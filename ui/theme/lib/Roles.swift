// SPDX-License-Identifier: BSD-3-Clause

// The required roles (theming.md §2.1, D108's term.0 to term.15): every
// theme resolves each of them, its own or inherited, and the base theme
// gives them all. Version 1 of the set; a role is added only with a page
// and a default in the base, so older themes keep working.

public enum Roles {
  public static let version = 1

  public static let surfaces = ["desk", "chrome", "chrome.behind", "well", "menu", "panel"]
  public static let edges = ["outline", "bevel.light", "bevel.dark", "control"]
  public static let ink = ["ink", "ink.dim", "ink.disabled", "ink.on-select", "ink.on-focus"]
  public static let meanings = ["focus", "selection", "live", "alert", "warning", "realtime"]
  public static let readouts = ["lcd", "lcd.ink"]
  public static let lamps = ["lamp.local", "lamp.agent", "lamp.egress", "lamp.swarm"]
  public static let terminal = (0..<16).map { "term." + String($0) }

  public static var required: [String] { surfaces + edges + ink + meanings + readouts + lamps + terminal }
}
