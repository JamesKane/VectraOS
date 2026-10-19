// SPDX-License-Identifier: BSD-3-Clause

// The kit frame (theming.md §7): the storyboard's component kit
// (docs/design/storyboard/Kit.dc.html, its 1× specimen) drawn from a
// theme's parts, one drawing at every scale. Windows focused and behind
// with their menu bars; buttons, the default and one disabled; checks and
// radios; a pop-up and a field; a slider; a progress bar; a group and an
// LCD; tabs, a scrollbar and a menu. What the pixel tests compare, and
// what `theme check` will draw. Every length is in logical pixels.

public enum KitFrame {
  public static let width: Float = 432
  public static let height: Float = 466

  /// The frame, from (0, 0), on the theme's chrome.
  public static func draw(_ p: inout Painter) {
    let t = p.theme
    p.fill(0, 0, width, height, t.color("chrome"))
    let x0: Float = 16
    var y: Float = 16

    // Two windows, each with a menu bar.
    for (i, focused) in [true, false].enumerated() {
      let x = x0 + Float(i) * 202
      let inside = Chrome.window(&p, x, y, 190, 70, title: focused ? "Focused" : "Behind", focused: focused)
      let body = t.style(focused ? "window.body.focused" : "window.body")
      let bar = t.style("menubar")
      let bx = inside.x + body.padding.left, by = inside.y + body.padding.top
      p.shape(bx, by, inside.width - body.padding.left - body.padding.right, 23, bar)
      var mx = bx + 10
      for title in ["File", "Edit"] {
        mx += p.text(title, mx, by + (23 - p.lineHeight(bar)) / 2, bar) + 10
      }
    }
    y += 86

    // Buttons: plain, the default, and disabled (the same part, its ink
    // `ink.disabled`).
    var x = x0
    for (label, name, enabled) in [("Cancel", "button", true), ("Open", "button.primary", true),
                                   ("Disabled", "button", false)] {
      var s = t.style(name)
      if !enabled { s.ink = t.color("ink.disabled") }
      let w = s.padding.left + p.measure(label, s) + s.padding.right
      control(&p, x, y, w, 26, s, label)
      x += w + 14
    }
    y += 42

    // Checks and radios, each with its label.
    x = x0
    let label = t.style("label")
    for (name, on, text) in [("check", true, "Checked"), ("check", false, "Off"), ("radio", true, "Radio"),
                             ("radio", false, "Radio")] {
      let s = t.style(on ? name + ".on" : name)
      p.shape(x, y, 14, 14, s)
      if on {
        // A check's mark is a square in its ink; a radio's a disc.
        var mark = Style(fill: s.ink, ink: s.ink)
        mark.radius = name == "radio" ? 4 : 0
        p.shape(x + 3, y + 3, 8, 8, mark)
      }
      x += 20
      x += p.text(text, x, y + (14 - p.lineHeight(label)) / 2, label) + 18
    }
    y += 30

    // A pop-up, its arrow a triangle of whole rows, and a field.
    let pop = t.style("popup")
    control(&p, x0, y, 120, 24, pop, "Media:Device", leading: true)
    for row in 0..<4 {
      let half = Float(4 - row)
      p.fill(x0 + 120 - pop.padding.right - 4 - half, y + 10 + Float(row), 2 * half, 1, pop.ink)
    }
    control(&p, x0 + 130, y, 160, 24, t.style("field"), "q8b/cam0", leading: true)
    y += 40

    // A slider at 60%: the track, what it has filled, the knob.
    let span: Float = 400
    p.shape(x0, y + 9, span, 8, t.style("slider"))
    p.shape(x0, y + 9, span * 0.6, 8, t.style("slider.fill"))
    p.shape(x0 + span * 0.6 - 12, y + 1, 24, 22, t.style("slider.knob"))
    y += 40

    // A progress bar at 62%.
    let progress = t.style("progress")
    p.shape(x0, y, span, 16, progress)
    let inset = progress.border
    p.shape(x0 + inset, y + inset, (span - 2 * inset) * 0.62, 16 - 2 * inset, t.style("progress.bar"))
    y += 32

    // A group, its legend over its top edge, and an LCD.
    let group = t.style("group"), legend = t.style("group.legend")
    let gw = span - 12 - 150
    p.shape(x0, y + 7, gw, 64 - 7, group)
    let lw = p.measure("Group", legend)
    p.fill(x0 + 10, y, lw + 12, p.lineHeight(legend), t.color("chrome"))
    p.text("Group", x0 + 16, y, legend)
    p.text("MUI groove frame", x0 + group.padding.left, y + 7 + group.padding.top + 6, label)
    let lcd = t.style("lcd")
    p.shape(x0 + gw + 12, y, 150, 64, lcd)
    let lh = p.lineHeight(lcd)
    p.text("FRAME 16.6 ms", x0 + gw + 20, y + 32 - lh, lcd)
    p.text("AUDIO 2.7 ms", x0 + gw + 20, y + 32, lcd)
    y += 80

    // Tabs, the first chosen and drawn last, over its neighbours' edges.
    let tab = t.style("tabs.tab"), chosen = t.style("tabs.tab.on")
    let th = tab.padding.top + p.lineHeight(tab) + tab.padding.bottom
    var tabs: [(x: Float, w: Float, title: String)] = []
    x = x0
    for title in ["Threads", "Rings", "Budgets"] {
      let w = tab.padding.left + p.measure(title, title == "Threads" ? chosen : tab) + tab.padding.right
      tabs.append((x, w, title))
      x += w - 1
    }
    for (i, e) in tabs.enumerated().reversed() {
      let s = i == 0 ? chosen : tab
      p.shape(e.x, y, e.w, th, s)
      p.text(e.title, e.x + s.padding.left, y + s.padding.top, s)
    }
    x += 1 + 14

    // A scrollbar: the track, an arrow at each end, the thumb.
    let track = t.style("scrollbar"), arrow = t.style("scrollbar.arrow"), thumb = t.style("scrollbar.thumb")
    p.shape(x, y, 15, 84, track)
    p.shape(x, y, 15, 15, arrow)
    p.shape(x, y + 69, 15, 15, arrow)
    p.shape(x + 1, y + 17, 13, 30, thumb)
    x += 15 + 14

    // A menu: one item hot, a rule, keys in the menu's key style (named:
    // the type has no ⌘ or ↵).
    let menu = t.style("menu"), item = t.style("menu.item"), hot = t.style("menu.item.hot")
    let key = t.style("menu.key"), rule = t.style("menu.rule")
    let ih = item.padding.top + p.lineHeight(item) + item.padding.bottom
    p.shape(x, y, 170, 3 * ih + 9, menu)
    var iy = y + menu.border
    for (i, entry) in [("Open", "Ctrl+O"), ("Get Info", "Ctrl+I"), ("", ""), ("Plumb", "Ctrl+Enter")].enumerated() {
      if entry.0.isEmpty {
        p.fill(x + menu.border, iy + 3, 170 - 2 * menu.border, 1, rule.fill)
        p.fill(x + menu.border, iy + 4, 170 - 2 * menu.border, 1, t.color("bevel.light"))
        iy += 7
        continue
      }
      let s = i == 0 ? hot : item
      if i == 0 { p.shape(x + menu.border, iy, 170 - 2 * menu.border, ih, s) }
      p.text(entry.0, x + s.padding.left, iy + s.padding.top, s)
      var k = key
      k.ink = s.ink
      let kw = p.measure(entry.1, k)
      p.text(entry.1, x + 170 - s.padding.right - kw, iy + s.padding.top + (p.lineHeight(s) - p.lineHeight(k)) / 2, k)
      iy += ih
    }
  }

  /// A control `width` by `height` with its label centred, or leading
  /// after its padding.
  static func control(_ p: inout Painter, _ x: Float, _ y: Float, _ width: Float, _ height: Float, _ s: Style,
                      _ label: String, leading: Bool = false)
  {
    p.shape(x, y, width, height, s)
    let tx = leading ? x + s.padding.left : x + (width - p.measure(label, s)) / 2
    p.text(label, tx, y + (height - p.lineHeight(s)) / 2, s)
  }
}
