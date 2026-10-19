// SPDX-License-Identifier: BSD-3-Clause

// What Radharc draws its decorations in, from the theme (D107, D91): the
// desk, each window's body (its edge and the ground under its layers),
// its tab and the tab's ink, focused and not, and the cursor. Scene draws
// with these and knows nothing of themes; the service builds them from the
// resolved theme's parts and roles, and builds them again when the theme
// changes.

import Themes

public struct Decorations: Equatable, Sendable {
  public var desk: UInt32
  public var body: UInt32
  public var edge: UInt32
  public var edgeFocused: UInt32
  public var tab: UInt32
  public var tabFocused: UInt32
  public var tabInk: UInt32
  public var tabInkFocused: UInt32
  public var cursorOutline: UInt32
  public var cursorFill: UInt32

  public init(desk: UInt32, body: UInt32, edge: UInt32, edgeFocused: UInt32, tab: UInt32, tabFocused: UInt32,
              tabInk: UInt32, tabInkFocused: UInt32, cursorOutline: UInt32, cursorFill: UInt32)
  {
    self.desk = desk
    self.body = body
    self.edge = edge
    self.edgeFocused = edgeFocused
    self.tab = tab
    self.tabFocused = tabFocused
    self.tabInk = tabInk
    self.tabInkFocused = tabInkFocused
    self.cursorOutline = cursorOutline
    self.cursorFill = cursorFill
  }

  /// The theme's: `desktop`'s fill, `window.body` and `window.tab` with
  /// their `.focused` states, and the cursor in `desk` and `ink`. Colours
  /// are opaque (the scene composes no alpha yet, D110).
  public init(_ theme: Theme) {
    func rgb(_ c: UInt32) -> UInt32 { c & 0xFF_FFFF }
    let body = theme.style("window.body"), bodyFocused = theme.style("window.body.focused")
    let tab = theme.style("window.tab"), tabFocused = theme.style("window.tab.focused")
    self.init(desk: rgb(theme.style("desktop").fill), body: rgb(body.fill), edge: rgb(body.stroke),
              edgeFocused: rgb(bodyFocused.stroke), tab: rgb(tab.fill), tabFocused: rgb(tabFocused.fill),
              tabInk: rgb(tab.ink), tabInkFocused: rgb(tabFocused.ink), cursorOutline: rgb(theme.color("desk")),
              cursorFill: rgb(theme.color("ink")))
  }

  /// The base theme's, until a service gives the scene its own.
  public static let base = Decorations(Theme.base)
}
