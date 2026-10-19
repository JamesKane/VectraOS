// SPDX-License-Identifier: BSD-3-Clause

// Drawing the storyboard's pieces (M6i): a Painter puts text and shapes in
// a display list in logical pixels at a display scale, text in CSS's line
// box (half the leading above the font's ascent), uppercased and spaced as
// its style says; Chrome draws the shell storyboard's elements with it
// (docs/design/shell-storyboard.html): a window (the neon tab with Be's
// close box at its left and zoom box at its right, over a framed body,
// the bottom right cut, glowing when focused), the Deskbar, tables,
// status lines, buttons and chips.

import GlyphAtlas
import Light
import OpenType
import Shape
import TDUnicode
import TextLayout

/// A typeface: a font at a weight, and the number the glyph cache knows
/// it by.
public struct Face: Sendable {
  public let font: Font
  public let id: UInt32
  public let weight: Int
  let setter: Typesetter

  public init(_ font: Font, id: UInt32, weight: Int) {
    self.font = font
    self.id = id
    self.weight = weight
    setter = Typesetter(font)
  }
}

/// An icon of the sheet, in its kind's colour and its emblem's (0: none).
public struct IconRef: Sendable {
  public var name: String
  public var color: UInt32
  public var emblem: UInt32
  public init(_ name: String, color: UInt32, emblem: UInt32 = 0) {
    self.name = name
    self.color = color
    self.emblem = emblem
  }
}

/// The typefaces a theme's roles are set in.
public struct Fonts: Sendable {
  var faces: [(role: FontRole, face: Face)] = []

  public init() {}

  public mutating func add(_ font: Font, role: FontRole, weight: Int) {
    faces.append((role, Face(font, id: UInt32(faces.count + 1), weight: weight)))
  }

  /// The role's face at the weight, or its nearest weight (or any face).
  public func face(_ role: FontRole, _ weight: Int) -> Face? {
    // (A loop, no arrays: drawn for every glyph of a terminal's grid, M6m.)
    var best: Face? = nil
    for f in faces where f.role == role {
      if best.map({ abs(f.face.weight - weight) < abs($0.weight - weight) }) ?? true { best = f.face }
    }
    if best != nil { return best }
    for f in faces where best.map({ abs(f.face.weight - weight) < abs($0.weight - weight) }) ?? true { best = f.face }
    return best
  }

  /// The faces a character missing from the role's face is looked for in,
  /// in order: the storyboard's font stacks (display falls back to ui),
  /// then the body face where they say system-ui, then the rest.
  func stack(_ role: FontRole, _ weight: Int) -> [Face] {
    var roles: [FontRole] = [role]
    if role == .display { roles.append(.ui) }
    for r in [FontRole.body, .ui, .display, .mono] where !roles.contains(r) { roles.append(r) }
    var out: [Face] = []
    for r in roles where faces.contains(where: { $0.role == r }) {
      if let f = face(r, weight) { out.append(f) }
    }
    return out
  }
}

public struct Painter: Sendable {
  public var list = DisplayList()
  public var cache: GlyphCache
  /// Pictures and icons, drawn at the sizes shown.
  public var images = ImageCache()
  /// Lines shaped before (M6m): drawn again without shaping.
  let textBox = TextCacheBox()
  var texts: TextCache {
    get { textBox.cache }
    nonmutating _modify { yield &textBox.cache }
  }
  public let theme: Theme
  public let fonts: Fonts
  /// Pixels a logical pixel.
  public var scale: Float

  public init(theme: Theme, fonts: Fonts, scale: Float = 1, cache: GlyphCache = GlyphCache()) {
    self.theme = theme
    self.fonts = fonts
    self.scale = scale
    self.cache = cache
  }

  /// A box in logical pixels, in device pixels, its edges on whole
  /// pixels (theming.md §5.2); a box with any size keeps at least one.
  public func snapped(_ x: Float, _ y: Float, _ width: Float, _ height: Float)
    -> (x: Float, y: Float, width: Float, height: Float)
  {
    func whole(_ v: Float) -> Float { ImageCache.floor(v * scale + 0.5) }
    let x0 = whole(x), y0 = whole(y)
    var x1 = whole(x + width), y1 = whole(y + height)
    if width > 0 && x1 <= x0 { x1 = x0 + 1 }
    if height > 0 && y1 <= y0 { y1 = y0 + 1 }
    return (x0, y0, x1 - x0, y1 - y0)
  }

  /// A border's or a bevel's width in whole device pixels, at least one:
  /// one crisp pixel at 100%, two at 200%, never a blurred 1.5.
  public func hairline(_ width: Float) -> Float { width > 0 ? max(1, ImageCache.floor(width * scale + 0.5)) : 0 }

  /// A shape, in logical pixels, snapped to device pixels: its shadows,
  /// its fill and glow, its gradients and patterns, its border over them,
  /// then its bevels inside the border, in `bevel.light` and `bevel.dark`.
  public mutating func shape(_ x: Float, _ y: Float, _ width: Float, _ height: Float, _ style: Style) {
    let box = snapped(x, y, width, height)
    var s = style
    s.border = hairline(style.border)
    s.radius *= scale
    s.glow *= scale
    if s.cuts != 0 {
      let q = UIQuad(x: 0, y: 0, width: 0, height: 0, kind: 0, fill: 0, cuts: s.cuts)
      s.cuts = UIQuad.cuts(topLeft: q.cut(0) * scale, topRight: q.cut(1) * scale, bottomRight: q.cut(2) * scale,
                           bottomLeft: q.cut(3) * scale)
    }
    guard !style.materials.isEmpty else {
      list.append(shape: box.x, box.y, box.width, box.height, style: s)
      return
    }
    func area(_ kind: UInt32, _ b: (x: Float, y: Float, width: Float, height: Float), fill: UInt32, stroke: UInt32,
              border: Float = 0, angle: Float = 0, inset: Float = 0)
    {
      list.append(UIQuad(x: b.x + inset, y: b.y + inset, width: b.width - 2 * inset, height: b.height - 2 * inset,
                         kind: kind, fill: fill, corner: max(0, s.radius - inset), cuts: s.cuts, border: border,
                         stroke: stroke, scale: angle))
    }
    var gradient = false
    for m in style.materials {
      if case .gradient = m { gradient = true }
      // A shadow: the shape offset, solid, or blurred as a glow.
      guard case .shadow(let color, let dx, let dy, let blur) = m else { continue }
      var shade = Style(ink: 0)
      shade.radius = s.radius
      shade.cuts = s.cuts
      if blur > 0 {
        shade.glow = blur * scale
        shade.glowColor = color
      } else {
        shade.fill = color
      }
      let o = snapped(x + dx, y + dy, width, height)
      list.append(shape: o.x, o.y, o.width, o.height, style: shade)
    }
    var ground = s
    ground.border = 0
    if gradient { ground.fill = 0 }
    if ground.fill >> 24 != 0 || (ground.glow > 0 && ground.glowColor >> 24 != 0) {
      list.append(shape: box.x, box.y, box.width, box.height, style: ground)
    }
    for m in style.materials {
      switch m {
      case .gradient(let from, let to, let angle):
        area(UIQuad.gradient, box, fill: from, stroke: to, angle: angle)
      case .pattern(let kind, let a, let b, let pitch):
        let k = kind == .stripes ? UIQuad.stripes : kind == .checks ? UIQuad.checks : UIQuad.dots
        // A period of whole pixels, even, so each half is whole too.
        area(k, box, fill: a, stroke: b, border: 2 * max(1, ImageCache.floor(pitch * scale / 2 + 0.5)))
      default: break
      }
    }
    // The border alone: its colour, clear inside.
    if s.border > 0 && s.stroke >> 24 != 0 {
      var edge = s
      edge.fill = s.stroke & 0xFF_FFFF
      edge.glow = 0
      list.append(shape: box.x, box.y, box.width, box.height, style: edge)
    }
    var inset = s.border
    let light = theme.color("bevel.light"), dark = theme.color("bevel.dark")
    for case .bevel(let kind, let w) in style.materials {
      let band = hairline(w)
      // Raised is lit where it faces the light; inset the other way; a
      // groove is inset outside and raised within.
      for lit in kind == .raised ? [true] : kind == .inset ? [false] : [false, true] {
        area(UIQuad.bevel, box, fill: lit ? light : dark, stroke: lit ? dark : light, border: band, inset: inset)
        inset += band
      }
    }
  }

  /// A filled rectangle (a rule, a bar), in logical pixels, snapped to
  /// device pixels.
  public mutating func fill(_ x: Float, _ y: Float, _ width: Float, _ height: Float, _ color: UInt32) {
    guard color >> 24 != 0 else { return }
    let b = snapped(x, y, width, height)
    list.append(UIQuad(x: b.x, y: b.y, width: b.width, height: b.height, kind: UIQuad.shape, fill: color))
  }

  func scalars(_ s: String, _ style: Style) -> [UInt32] {
    let v = s.unicodeScalars.map { $0.value }
    return style.uppercase ? CaseMapping.uppercase(v) : v
  }

  /// Runs of text by the face that has their characters: the style's
  /// role's, and for a grapheme cluster it lacks, the first face of its
  /// stack that has it (as a browser falls back through a font stack).
  func runs(_ text: [UInt32], _ style: Style) -> [(range: Range<Int>, face: Face)] {
    let faces = fonts.stack(style.font, style.weight)
    guard let primary = faces.first else { return [] }
    // Characters no face draws a glyph for: controls, joiners, selectors.
    func has(_ f: Face, _ c: UInt32) -> Bool {
      c < 0x20 || (c >= 0x200B && c <= 0x200F) || (c >= 0xFE00 && c <= 0xFE0F) || f.font.glyph(for: c) != 0
    }
    if text.allSatisfy({ has(primary, $0) }) { return [(0..<text.count, primary)] }
    var out: [(range: Range<Int>, face: Face)] = []
    var start = 0
    for b in Segmentation.graphemeBoundaries(text) where b > start {
      let cluster = start..<b
      let face = faces.first { f in cluster.allSatisfy { has(f, text[$0]) } } ?? primary
      if let last = out.last, last.face.id == face.id {
        out[out.count - 1].range = last.range.lowerBound..<b
      } else {
        out.append((cluster, face))
      }
      start = b
    }
    return out
  }

  /// A line of text's width, in logical pixels.
  public func measure(_ s: String, _ style: Style) -> Float {
    let text = scalars(s, style)
    return measure(scalars: text, style)
  }

  /// A line of scalars' width, in logical pixels (already in the style's
  /// case).
  func measure(scalars text: [UInt32], _ style: Style) -> Float {
    // Kept (M6m): measured once.
    let k = textKey(1, style), h = TextCache.hash(text, k)
    if let e = texts.lookup(text, k, h) { return texts.entries[e].width }
    let w = measured(text, style)
    let e = texts.insert(text, k, h)
    texts.entries[e].width = w
    return w
  }

  func measured(_ text: [UInt32], _ style: Style) -> Float {
    let size = Double(style.textSize)
    var width: Float = 0
    let runs = runs(text, style)
    for (n, r) in runs.enumerated() {
      let p = r.face.setter.set(Array(text[r.range]), size: size, width: .infinity,
                                tracking: Double(style.tracking) * size)
      // A run's trailing spaces count where another run follows.
      width += Float(n + 1 < runs.count ? p.advance : p.lines.first?.width ?? 0)
    }
    return width + (text.isEmpty ? 0 : style.tracking * style.textSize)
  }

  /// A line of text in its style, its line box's top left at (x, y) in
  /// logical pixels, in `color` (the style's ink if 0); its width. A
  /// fallback face's run sits on the style's face's baseline.
  @discardableResult
  public mutating func text(_ s: String, _ x: Float, _ y: Float, _ style: Style, color: UInt32 = 0) -> Float {
    guard !s.isEmpty else { return 0 }
    return cachedText(s.unicodeScalars.lazy.map { $0.value }, x, y, style, color: color) {
      let v = s.unicodeScalars.map { $0.value }
      return style.uppercase ? CaseMapping.uppercase(v) : v
    }
  }

  /// A line of scalars, as `text` draws a string (M6m: the editor's lines,
  /// no String made).
  @discardableResult
  public mutating func text(scalars: [UInt32], _ x: Float, _ y: Float, _ style: Style, color: UInt32 = 0) -> Float {
    guard !scalars.isEmpty else { return 0 }
    return cachedText(scalars, x, y, style, color: color) {
      style.uppercase ? CaseMapping.uppercase(scalars) : scalars
    }
  }

  /// One character's glyph, its line box's top left at (x, y) (logical
  /// pixels), from the glyph cache with no shaping (M6m: a terminal's
  /// cells, each in its own place): the style's face, or the first of its
  /// stack that has it. Nothing is allocated once the glyph is cached.
  public mutating func glyph(_ scalar: UInt32, _ x: Float, _ y: Float, _ style: Style, color: UInt32 = 0) {
    guard let primary = fonts.face(style.font, style.weight) else { return }
    var face = primary
    if primary.font.glyph(for: scalar) == 0 {
      for f in fonts.stack(style.font, style.weight) where f.font.glyph(for: scalar) != 0 {
        face = f
        break
      }
    }
    let g = face.font.glyph(for: scalar)
    guard g != 0 else { return }
    let m = primary.font.metrics
    let size = Double(style.textSize * scale)
    let content = Double(m.ascender - m.descender) * size / Double(m.unitsPerEm)
    let halfLeading = (Double(style.lineHeight) * size - content) / 2
    let baseline = Double(y * scale) + halfLeading + Double(m.ascender) * size / Double(m.unitsPerEm)
    list.append(glyph: Int(g), x: Double(x * scale), y: baseline, size: size,
                color: color != 0 ? color : style.ink, font: face.font, fontID: face.id, cache: &cache)
  }

  /// A style's face, metrics and size resolved once for a grid's many
  /// glyphs (M6m: a terminal draws each cell's).
  public struct GridFace: Sendable {
    let face: Face
    let size: Double
    /// From a line box's top to its baseline, in pixels.
    let baseline: Double
    let ink: UInt32
  }

  public func gridFace(_ style: Style) -> GridFace? {
    guard let primary = fonts.face(style.font, style.weight) else { return nil }
    let m = primary.font.metrics
    let size = Double(style.textSize * scale)
    let content = Double(m.ascender - m.descender) * size / Double(m.unitsPerEm)
    let halfLeading = (Double(style.lineHeight) * size - content) / 2
    return GridFace(face: primary, size: size, baseline: halfLeading + Double(m.ascender) * size / Double(m.unitsPerEm),
                    ink: style.ink)
  }

  /// One character's glyph in a resolved face (gridFace), its line box's
  /// top left at (x, y) in logical pixels; one the face lacks is drawn by
  /// `glyph(_:_:_:_:color:)`, through the style's stack.
  public mutating func glyph(_ scalar: UInt32, _ x: Float, _ y: Float, _ g: borrowing GridFace, _ style: Style,
                             color: UInt32 = 0)
  {
    let id = g.face.font.glyph(for: scalar)
    guard id != 0 else {
      glyph(scalar, x, y, style, color: color)
      return
    }
    list.append(glyph: id, x: Double(x * scale), y: Double(y * scale) + g.baseline, size: g.size,
                color: color != 0 ? color : g.ink, font: g.face.font, fontID: g.face.id, cache: &cache)
  }

  /// Drawn from the text cache (TextCache.swift), or shaped and kept.
  mutating func cachedText<C: Collection<UInt32>>(_ key: C, _ x: Float, _ y: Float, _ style: Style, color: UInt32,
                                                  _ make: () -> [UInt32]) -> Float
  {
    let px = x * scale, py = y * scale
    let k = textKey(0, style, x: px, y: py), h = TextCache.hash(key, k)
    let ox = wholeBelow(px), oy = wholeBelow(py)
    let ink = color != 0 ? color : style.ink
    if let e = texts.lookup(key, k, h), texts.entries[e].generation == generation {
      for var q in texts.entries[e].quads {
        q.x += ox
        q.y += oy
        q.fill = ink
        list.append(q)
      }
      return texts.entries[e].width
    }
    let start = list.quads.count
    let width = shaped(make(), x, y, style, color: color)
    let e = texts.insert(key, k, h)
    for i in start..<list.quads.count {
      var q = list.quads[i]
      q.x -= ox
      q.y -= oy
      texts.entries[e].quads.append(q)
    }
    texts.entries[e].width = width
    texts.entries[e].generation = generation
    return width
  }

  /// Shapes and draws a line (in the style's case already).
  mutating func shaped(_ text: [UInt32], _ x: Float, _ y: Float, _ style: Style, color: UInt32) -> Float {
    guard let face = fonts.face(style.font, style.weight), !text.isEmpty else { return 0 }
    let m = face.font.metrics
    let size = Double(style.textSize * scale)
    let content = Double(m.ascender - m.descender) * size / Double(m.unitsPerEm)
    let halfLeading = (Double(style.lineHeight) * size - content) / 2
    let baseline = Double(y * scale) + halfLeading + Double(m.ascender) * size / Double(m.unitsPerEm)
    var pen = Double(x * scale)
    let runs = runs(text, style)
    for (n, r) in runs.enumerated() {
      let fm = r.face.font.metrics
      let p = r.face.setter.set(Array(text[r.range]), size: size, width: .infinity, x: pen,
                                y: baseline - Double(fm.ascender) * size / Double(fm.unitsPerEm),
                                tracking: Double(style.tracking) * size)
      list.append(p, size: size, color: color != 0 ? color : style.ink, font: r.face.font, fontID: r.face.id,
                  cache: &cache)
      pen += n + 1 < runs.count ? p.advance : p.lines.first?.width ?? 0
    }
    return Float(pen) / scale - x + style.tracking * style.textSize
  }

  /// The quads from here on clipped to a rectangle (logical pixels), or
  /// not (nil).
  public mutating func clip(_ r: Rect?) {
    list.clip(r.map { ($0.x * scale, $0.y * scale, ($0.x + $0.width) * scale, ($0.y + $0.height) * scale) })
  }

  /// Where a caret goes before each grapheme cluster of `text` and after
  /// the last, in logical pixels from the text's start: (scalar index,
  /// x) pairs.
  public func carets(_ text: [UInt32], _ style: Style) -> [(index: Int, x: Float)] {
    // Kept (M6m): a line's carets found once.
    let k = textKey(2, style), h = TextCache.hash(text, k)
    if let e = texts.lookup(text, k, h) { return texts.entries[e].carets }
    let out = caretsShaped(text, style)
    let e = texts.insert(text, k, h)
    texts.entries[e].carets.append(contentsOf: out)
    return out
  }

  func caretsShaped(_ text: [UInt32], _ style: Style) -> [(index: Int, x: Float)] {
    let bounds = Segmentation.graphemeBoundaries(text)
    guard !text.isEmpty else { return [(0, 0)] }
    let size = Double(style.textSize)
    // Each run's glyphs, placed after the runs before it.
    var glyphs: [(cluster: Int, x: Float)] = []
    var width: Float = 0
    let runs = runs(text, style)
    for (n, r) in runs.enumerated() {
      let p = r.face.setter.set(Array(text[r.range]), size: size, width: .infinity,
                                tracking: Double(style.tracking) * size)
      for g in p.glyphs { glyphs.append((r.range.lowerBound + g.cluster, width + Float(g.x))) }
      width += Float(n + 1 < runs.count ? p.advance : p.lines.first?.width ?? 0)
    }
    var out: [(index: Int, x: Float)] = [(0, 0)]
    for b in bounds where b > 0 {
      if b >= text.count {
        out.append((text.count, width))
      } else if let g = glyphs.first(where: { $0.cluster >= b }) {
        out.append((b, g.x))
      } else {
        out.append((b, width))
      }
    }
    return out
  }

  /// A line box's height in a style, in logical pixels.
  public func lineHeight(_ style: Style) -> Float { style.textSize * style.lineHeight }

  /// From a line box's top to its baseline, in logical pixels.
  public func baseline(_ style: Style) -> Float {
    guard let face = fonts.face(style.font, style.weight) else { return lineHeight(style) }
    let m = face.font.metrics
    let em = style.textSize / Float(m.unitsPerEm)
    return (lineHeight(style) - Float(m.ascender - m.descender) * em) / 2 + Float(m.ascender) * em
  }

  /// An icon inline with a line of text (the storyboard's `.mi`: 1.35cqw,
  /// its bottom .3cqw below the baseline), at `x`, on the line whose box's
  /// top is `top`; the room it takes with its gap (.4cqw).
  @discardableResult
  public mutating func inlineIcon(_ icon: IconRef, _ x: Float, _ top: Float, _ style: Style) -> Float {
    let size = Theme.cqw(1.35)
    self.icon(icon.name, x, top + baseline(style) + Theme.cqw(0.3) - size, size: size, color: icon.color,
              emblem: icon.emblem)
    return size + Theme.cqw(0.4)
  }

  /// The theme's `text.contrast`: the curve its text's coverage takes.
  public var contrast: TextContrast {
    theme.number(knob: "text.contrast").map { TextContrast(Float($0)) } ?? .standard
  }

  /// The list drawn onto a canvas, its text at the theme's contrast.
  public func render(into canvas: inout Canvas) {
    canvas.contrast = contrast
    CPURenderer().render(list, cache: cache, images: images, into: &canvas)
  }

  /// Renders only `region` (pixels: the frame's damage, M6m).
  public func render(into canvas: inout Canvas, region: Rect) {
    let r = (x0: Int(region.x), y0: Int(region.y), x1: Int(region.x + region.width) + 1, y1: Int(region.y + region.height) + 1)
    canvas.contrast = contrast
    CPURenderer().render(list, cache: cache, images: images, into: &canvas, region: r)
  }
}

public enum Chrome {
  /// Be's close box (`left`) or zoom box, a `size`-pixel square, in strokes
  /// a tenth of it wide (the storyboard's 10-unit drawings).
  static func beBox(_ p: inout Painter, _ x: Float, _ y: Float, _ size: Float, zoom: Bool, _ color: UInt32) {
    let u = size / 10
    func hLine(_ x0: Float, _ x1: Float, _ yy: Float) { p.fill(x + x0 * u, y + yy * u - u / 2, (x1 - x0) * u, u, color) }
    func vLine(_ xx: Float, _ y0: Float, _ y1: Float) { p.fill(x + xx * u - u / 2, y + y0 * u, u, (y1 - y0) * u, color) }
    if !zoom {
      // M.5 .5h9v9h-9z M2.5 7V2.5H7
      hLine(0, 10, 0.5)
      hLine(0, 10, 9.5)
      vLine(0.5, 0.5, 9.5)
      vLine(9.5, 0.5, 9.5)
      vLine(2.5, 2.5, 7)
      hLine(2.5, 7, 2.5)
    } else {
      // M.5 .5h5v5h-5z M5.5 3.5H9.5V9.5H3.5V5.5
      hLine(0, 6, 0.5)
      hLine(0, 6, 5.5)
      vLine(0.5, 0.5, 5.5)
      vLine(5.5, 0.5, 5.5)
      hLine(5.5, 10, 3.5)
      vLine(9.5, 3.5, 10)
      hLine(3.5, 10, 9.5)
      vLine(3.5, 5.5, 9.5)
    }
  }

  /// A window at (x, y), `width` by `height` (tab and body), titled; its
  /// body's inside (the content's frame), in logical pixels.
  @discardableResult
  public static func window(_ p: inout Painter, _ x: Float, _ y: Float, _ width: Float, _ height: Float,
                            title: String, focused: Bool) -> (x: Float, y: Float, width: Float, height: Float)
  {
    let t = p.theme
    let tab = t.style(focused ? "window.tab.focused" : "window.tab")
    let widget = t.style(focused ? "window.tab.widget.focused" : "window.tab.widget")
    let body = t.style(focused ? "window.body.focused" : "window.body")
    let box = widget.textSize
    let gap = Theme.cqw(0.55), after = Theme.cqw(0.7)
    let titleWidth = p.measure(title, tab)
    let tabWidth = tab.padding.left + box + gap + titleWidth + after + box + tab.padding.right
    let tabHeight = tab.padding.top + p.lineHeight(tab) + tab.padding.bottom + tab.border
    // The glow under the tab (the body glows on its own), then the body,
    // then the tab over the body's top edge.
    if body.glow > 0 {
      var halo = Style(ink: 0)
      halo.cuts = tab.cuts
      halo.glow = body.glow
      halo.glowColor = body.glowColor
      p.shape(x, y, tabWidth, tabHeight + 1, halo)
    }
    p.shape(x, y + tabHeight, width, height - tabHeight, body)
    p.shape(x, y, tabWidth, tabHeight + 1, tab)
    // The body's top edge runs under the tab: the tab has no bottom border.
    p.fill(x + tab.border, y + tabHeight, tabWidth - 2 * tab.border, 1, tab.fill)
    let lineY = y + tab.border + tab.padding.top
    let boxY = lineY + (p.lineHeight(tab) - box) / 2
    var cx = x + tab.padding.left
    beBox(&p, cx, boxY, box, zoom: false, widget.ink)
    cx += box + gap
    cx += p.text(title, cx, lineY, tab)
    cx += after
    beBox(&p, cx, boxY, box, zoom: true, widget.ink)
    return (x + body.border, y + tabHeight + body.border, width - 2 * body.border, height - tabHeight - 2 * body.border)
  }

  /// A table: headers, then rows (each cell's text, with a row's state:
  /// "", "selected" or "new"), columns `widths` wide; its height.
  @discardableResult
  public static func table(_ p: inout Painter, _ x: Float, _ y: Float, width: Float, columns: [String],
                           widths: [Float], numeric: [Bool] = [], rows: [(cells: [String], state: String)],
                           icons: [IconRef?] = []) -> Float
  {
    let t = p.theme
    let header = t.style("table.header")
    var yy = y
    let headerHeight = header.padding.top + p.lineHeight(header) + header.padding.bottom
    var cx = x
    for (i, name) in columns.enumerated() {
      p.text(name, cx + header.padding.left, yy + header.padding.top, header)
      cx += i < widths.count ? widths[i] : 0
    }
    yy += headerHeight
    p.fill(x, yy, width, header.border, header.stroke)
    yy += header.border
    for (r, row) in rows.enumerated() {
      let cell = t.style(row.state.isEmpty ? "table.cell" : "table.cell." + row.state)
      let h = cell.padding.top + p.lineHeight(cell) + cell.padding.bottom
      p.fill(x, yy, width, h, cell.fill)
      cx = x
      for (i, text) in row.cells.enumerated() {
        let w = i < widths.count ? widths[i] : 0
        // A numeric column right-aligns its numbers (the storyboard's
        // `td.num`), not a dash standing for none.
        if i < numeric.count && numeric[i], let first = text.unicodeScalars.first, first.properties.numericType != nil {
          let tw = p.measure(text, cell)
          p.text(text, cx + w - cell.padding.right - tw, yy + cell.padding.top, cell)
        } else {
          // The first cell leads with the row's icon, if it has one.
          var tx = cx + cell.padding.left
          if i == 0, r < icons.count, let icon = icons[r] { tx += p.inlineIcon(icon, tx, yy + cell.padding.top, cell) }
          p.text(text, tx, yy + cell.padding.top, cell)
        }
        cx += w
      }
      yy += h
      p.fill(x, yy, width, cell.border, cell.stroke)
      yy += cell.border
    }
    return yy - y
  }

  /// An icon on the desktop (the storyboard's `.icon`): 3.8cqw, centred
  /// over its label in a column 7cqw wide whose top left is (x, y).
  public static func desktopIcon(_ p: inout Painter, _ x: Float, _ y: Float, _ icon: IconRef, label: String,
                                 selected: Bool = false)
  {
    let s = p.theme.style("desktop.icon")
    let size = Theme.cqw(3.8), column = Theme.cqw(7)
    p.icon(icon.name, x + (column - size) / 2, y, size: size, color: icon.color, emblem: icon.emblem,
           selected: selected)
    let lw = p.measure(label, s)
    p.text(label, x + (column - lw) / 2, y + size + Theme.cqw(0.3), s)
  }

  /// A status line along a frame's bottom: text at its left and right.
  public static func status(_ p: inout Painter, _ frame: (x: Float, y: Float, width: Float, height: Float), left: String,
                            right: String, live: Bool = false)
  {
    let s = p.theme.style("status")
    let h = s.padding.top + p.lineHeight(s) + s.padding.bottom
    let y = frame.y + frame.height - h
    p.fill(frame.x, y, frame.width, h, s.fill)
    p.fill(frame.x, y, frame.width, s.border, s.stroke)
    p.text(left, frame.x + s.padding.left, y + s.padding.top, live ? p.theme.style("status.live") : s)
    let w = p.measure(right, s)
    p.text(right, frame.x + frame.width - s.padding.right - w, y + s.padding.top, s)
  }

  /// A button in its class ("button", "button.primary"); its width.
  @discardableResult
  public static func button(_ p: inout Painter, _ x: Float, _ y: Float, _ label: String, style name: String = "button")
    -> Float
  {
    let s = p.theme.style(name)
    let w = s.padding.left + p.measure(label, s) + s.padding.right
    let h = s.padding.top + p.lineHeight(s) + s.padding.bottom
    p.shape(x, y, w, h, s)
    p.text(label, x + s.padding.left, y + s.padding.top, s)
    return w
  }

  /// The Deskbar at its top right: the menu, the tray with its clock, the
  /// gauges (name, a fraction, its reading), and the running apps (name,
  /// windows, whether it's in front); its height.
  @discardableResult
  public static func deskbar(_ p: inout Painter, right: Float, top: Float, clock: String,
                             gauges: [(String, Float, String)], apps: [(String, Int, Bool)], tray replicants: [IconRef] = [],
                             appIcons: [IconRef] = []) -> Float
  {
    let t = p.theme
    let bar = t.style("deskbar")
    let width = bar.padding.right
    let x = right - width
    var parts: [(Float, (inout Painter, Float) -> Void)] = []
    let menu = t.style("deskbar.menu")
    let menuH = menu.padding.top + p.lineHeight(menu) + menu.padding.bottom
    let icon = Theme.cqw(1.6)
    parts.append((menuH, { p, y in
      p.icon("cube", x + menu.padding.left, y + (menuH - icon) / 2, size: icon, color: menu.ink)
      p.text("TODHCHAI", x + menu.padding.left + icon + Theme.cqw(0.6), y + menu.padding.top, menu)
    }))
    let tray = t.style("deskbar.tray")
    let trayH = tray.padding.top + Theme.cqw(1.6) + tray.padding.bottom
    parts.append((trayH, { p, y in
      let clockStyle = t.style("deskbar.clock")
      let w = p.measure(clock, clockStyle)
      p.text(clock, x + width - tray.padding.right - w, y + (trayH - p.lineHeight(clockStyle)) / 2, clockStyle)
      // The replicants, .5cqw apart.
      var ix = x + tray.padding.left
      for r in replicants {
        p.icon(r.name, ix, y + tray.padding.top, size: icon, color: r.color, emblem: r.emblem)
        ix += icon + Theme.cqw(0.5)
      }
    }))
    if !gauges.isEmpty {
      let g = t.style("gauge"), barStyle = t.style("gauge.bar"), value = t.style("gauge.value")
      let rowH = p.lineHeight(g), gapH = Theme.cqw(0.35)
      let h = g.padding.top + Float(gauges.count) * rowH + Float(gauges.count - 1) * gapH + g.padding.bottom
      parts.append((h, { p, y in
        var yy = y + g.padding.top
        for (name, fraction, reading) in gauges {
          p.text(name, x + g.padding.left, yy, g)
          let w = p.measure(reading, value)
          p.text(reading, x + width - g.padding.right - w, yy, value)
          let bx = x + g.padding.left + barStyle.padding.left + Theme.cqw(0.4)
          let bw = x + width - g.padding.right - w - Theme.cqw(0.4) - bx
          let by = yy + (rowH - barStyle.padding.top) / 2
          p.fill(bx, by, bw, barStyle.padding.top, barStyle.fill)
          p.fill(bx, by, bw * min(max(fraction, 0), 1), barStyle.padding.top, barStyle.ink)
          yy += rowH + gapH
        }
      }))
    }
    if !apps.isEmpty {
      let a = t.style("deskbar.app"), count = t.style("deskbar.app.count")
      let rowH = a.padding.top + p.lineHeight(a) + a.padding.bottom
      parts.append((Float(apps.count) * rowH + 2 * Theme.cqw(0.3), { p, y in
        var yy = y + Theme.cqw(0.3)
        for (k, (name, windows, on)) in apps.enumerated() {
          let style = on ? t.style("deskbar.app.on") : a
          if k < appIcons.count { p.inlineIcon(appIcons[k], x + style.padding.left, yy + style.padding.top, style) }
          p.text(name, x + style.padding.left + Theme.cqw(1.35) + Theme.cqw(0.4), yy + style.padding.top, style)
          let n = "\(windows)"
          let w = p.measure(n, count)
          p.text(n, x + width - style.padding.right - w, yy + style.padding.top + (p.lineHeight(style) - p.lineHeight(count)) / 2,
                 count)
          yy += rowH
        }
      }))
    }
    let total = parts.reduce(Float(2 * bar.border)) { $0 + $1.0 } + Float(max(parts.count - 1, 0))
    p.shape(x, top, width, total, bar)
    var y = top + bar.border
    for (i, part) in parts.enumerated() {
      part.1(&p, y)
      y += part.0
      if i + 1 < parts.count {
        p.fill(x + bar.border, y, width - 2 * bar.border, 1, bar.stroke)
        y += 1
      }
    }
    return total
  }
}
