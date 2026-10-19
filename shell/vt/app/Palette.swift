// SPDX-License-Identifier: BSD-3-Clause

// vt's colours (vt(1)) from the theme: the default ink and background the
// `terminal` part's, as rio's text is drawn; the sixteen ANSI colours the
// roles term.0 to term.15 (theme(6)); the 256-colour palette's cube and
// grey ramp xterm's.

import TerminalCore
import UICore

public struct TerminalPalette: Sendable {
  public var foreground: UInt32
  public var background: UInt32
  public var cursor: UInt32
  public var ansi: [UInt32]

  public init(theme: Theme) {
    let style = theme.style("terminal")
    foreground = style.ink & 0xFF_FFFF
    background = style.fill & 0xFF_FFFF
    cursor = foreground
    ansi = Roles.terminal.map { theme.color($0) & 0xFF_FFFF }
  }

  /// A colour's 0xRRGGBB.
  public func rgb(_ c: TerminalColor, foreground fg: Bool) -> UInt32 {
    switch c {
    case .standard: return fg ? foreground : background
    case .rgb(let v): return v
    case .indexed(let i):
      if i < 16 { return ansi[Int(i)] }
      if i < 232 {
        let n = Int(i) - 16
        func level(_ v: Int) -> UInt32 { v == 0 ? 0 : UInt32(55 + v * 40) }
        return level(n / 36) << 16 | level(n / 6 % 6) << 8 | level(n % 6)
      }
      let g = UInt32(8 + (Int(i) - 232) * 10)
      return g << 16 | g << 8 | g
    }
  }
}
