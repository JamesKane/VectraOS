// SPDX-License-Identifier: BSD-3-Clause

// The resolved theme on the wire: every shipped theme, in each variant,
// comes back from its message as it went in, and fits in one.

import IPC
import Radharc
import Testing
import Themes

@Test(arguments: [("platinum-indigo", nil), ("platinum-indigo", "high-contrast"), ("neon-tab", nil),
                  ("neon-tab", "high-contrast"), ("base", nil)] as [(String, String?)])
func aResolvedThemeComesBackFromItsMessage(_ name: String, _ variant: String?) throws {
  let theme = try Theme.resolve(ThemeStack(theme: name, variant: variant), installed: installed)
  let bytes = try #require(RadharcIPC.ResolvedTheme(theme, generation: 7).encoded())
  #expect(bytes.count <= maxMessageBytes)
  let wire = try #require(RadharcIPC.ResolvedTheme(decoding: bytes))
  #expect(wire.generation == 7)
  let back = try #require(Theme(wire))
  #expect(back.name == theme.name && back.title == theme.title && back.variant == theme.variant)
  #expect(back.textScale == theme.textScale)
  #expect(back.roles == theme.roles)
  for r in theme.roles { #expect(back.color(r) == theme.color(r), "\(r)") }
  #expect(back.classes == theme.classes)
  for c in theme.classes { #expect(back.style(c) == theme.style(c), "\(c)") }
  for f in [FontRole.display, .body, .mono, .ui] { #expect(back.typeface(f) == theme.typeface(f)) }
  #expect(back.knobs.map { $0.name } == theme.knobs.map { $0.name })
}

@Test func otherBytesArentATheme() {
  #expect(RadharcIPC.ResolvedTheme(decoding: []) == nil)
  #expect(RadharcIPC.ResolvedTheme(decoding: [UInt8](repeating: 0, count: 64)) == nil)
}
