// SPDX-License-Identifier: BSD-3-Clause

// The theme tree's ctl: load, variant and set change the theme in force
// and its generation; a theme that doesn't resolve or fails the floor is
// refused with its reason, and the one before stays.

import Radharc
import Testing
import Themes

let shipped: [(name: String, text: [UInt8])] = ["platinum-indigo", "neon-tab"].map { ($0, installed($0)!) }

@Test func thePreferredThemeIsInForce() {
  let c = ThemeControl(preferred: "platinum-indigo", installed: shipped)
  #expect(c.name == "platinum-indigo" && c.variant == nil && c.generation == 1 && c.refusal == nil)
  #expect(c.theme.color("desk") & 0xFF_FFFF == 0x3F_5868)
  #expect(c.active == "theme platinum-indigo\nvariant none\ngeneration 1\n")
  #expect(c.names == ["base", "platinum-indigo", "neon-tab"])
}

@Test func withoutItTheBase() {
  let c = ThemeControl(preferred: "platinum-indigo", installed: [])
  #expect(c.name == "base" && c.generation == 1)
  #expect(c.refusal == "platinum-indigo: no theme platinum-indigo")
}

@Test func commandsChangeTheThemeAndItsGeneration() throws {
  var c = ThemeControl(preferred: "platinum-indigo", installed: shipped)
  #expect(try c.command("load neon-tab\n"))
  #expect(c.name == "neon-tab" && c.generation == 2)
  #expect(c.theme.color("desk") & 0xFF_FFFF == 0x0A_0A12)
  #expect(try c.command("variant high-contrast"))
  #expect(c.variant == "high-contrast" && c.theme.color("desk") & 0xFF_FFFF == 0)
  #expect(try c.command("set selection 0x40c0ff"))
  #expect(c.theme.color("selection") & 0xFF_FFFF == 0x40_C0FF && c.generation == 4)
  #expect(c.active == "theme neon-tab\nvariant high-contrast\ngeneration 4\nset selection 0x40c0ff\n")
  #expect(try c.command("variant none"))
  #expect(c.variant == nil && c.theme.color("selection") & 0xFF_FFFF == 0x40_C0FF)
  #expect(try c.command("load platinum-indigo"))
  #expect(c.sets.isEmpty && c.variant == nil && c.generation == 6)
}

@Test(arguments: [
  ("load nowhere", "nowhere: no theme nowhere"),
  ("variant dusk", "platinum-indigo: no variant dusk"),
  ("set ink 0xc0c0c0", "platinum-indigo: ink on chrome is 1.2:1, under 4.5:1"),
  ("set ink nothing", "set:1: no role nothing"),
  ("reload", "reload: not load NAME, variant NAME|none or set ROLE COLOUR"),
] as [(String, String)])
func aRefusedCommandLeavesTheTheme(_ command: String, _ reason: String) {
  var c = ThemeControl(preferred: "platinum-indigo", installed: shipped)
  do {
    _ = try c.command(command)
    Issue.record("accepted: \(command)")
  } catch {
    #expect(error.reason == reason)
  }
  #expect(c.refusal == reason)
  #expect(c.name == "platinum-indigo" && c.generation == 1 && c.sets.isEmpty)
  #expect(c.theme.color("ink") & 0xFF_FFFF == 0x1D_1B17)
}
