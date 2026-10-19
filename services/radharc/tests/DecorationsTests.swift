// SPDX-License-Identifier: BSD-3-Clause

// The decorations come from the theme: the base theme's by default, and
// Neon Tab's are the focused colours todhchai's Radharc hardcoded (the
// desk, the cyan edge, the amber tab and its dark title).

import FoundationEssentials
import Radharc
import Testing
import Themes

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // services/radharc/tests/DecorationsTests.swift
  return dir
}()

func installed(_ name: String) -> [UInt8]? {
  (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(name)"))).map { [UInt8]($0) }
}

@Test func neonTabsDecorationsAreTodhchais() throws {
  let d = Decorations(try Theme.resolve(ThemeStack(theme: "neon-tab"), installed: installed))
  #expect(d.desk == 0x0A0A12)
  #expect(d.edgeFocused == 0x00E5FF)
  #expect(d.tabFocused == 0xFFB000)
  #expect(d.tabInkFocused == 0x0A0A12)
}

@Test func aNewThemeDamagesTheScreen() throws {
  let s = Scene(width: 320, height: 240)
  _ = s.takeDamage()
  #expect(s.decorations == Decorations.base)
  s.decorations = Decorations(try Theme.resolve(ThemeStack(theme: "neon-tab"), installed: installed))
  #expect(s.takeDamage() == Rect(x: 0, y: 0, width: 320, height: 240))
  let same = s.decorations
  s.decorations = same
  #expect(s.takeDamage().isEmpty)
}
