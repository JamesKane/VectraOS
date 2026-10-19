// SPDX-License-Identifier: BSD-3-Clause

// The resolver (D108, D109): a stack of theme files to one Theme. From the
// bottom: the base, the theme's chain (`inherits`), its variant, then the
// user's, the workspace's, the output's and an app rule's layers; high
// contrast on top. Everything is merged as names first (roles, knobs and
// parts stay symbolic), borrowed parts are taken from the lender's own
// chain, and only then is each part evaluated, against the borrower's
// roles. A part inherits its fields from its nearest defined dot-parent
// ("button" for "button.primary"), then "default".

import NdbFile

/// A layer over a theme: a file of the same format, and its label in
/// messages ("user", "workspace 2", "output HDMI-1", "app rule 3").
public struct ThemeLayer: Sendable {
  public var label: String
  public var text: [UInt8]

  public init(label: String, text: [UInt8]) {
    self.label = label
    self.text = text
  }
}

/// What to resolve: a theme, a variant of it, the layers over it, and
/// whether high contrast is on.
public struct ThemeStack: Sendable {
  public var theme: String
  public var variant: String?
  public var layers: [ThemeLayer]
  public var highContrast: Bool
  /// Knobs set over everything else, as `theme check` turns them.
  public var knobs: [(name: String, value: String)]

  public init(theme: String, variant: String? = nil, layers: [ThemeLayer] = [], highContrast: Bool = false,
              knobs: [(name: String, value: String)] = [])
  {
    self.theme = theme
    self.variant = variant
    self.layers = layers
    self.highContrast = highContrast
    self.knobs = knobs
  }
}

extension Theme {
  /// The stack resolved, the themes it names read through `installed`
  /// (a theme's name to its file; the base needs none). An error names
  /// the file and line that caused it.
  public static func resolve(_ stack: ThemeStack, installed: (String) -> [UInt8]?) throws(ThemeError) -> Theme {
    let chain = try loadChain(stack.theme, installed: installed)
    var layers: [ThemeFile] = []
    for l in stack.layers {
      let f = try ThemeFile(parsing: l.text, label: l.label)
      if let r = f.records.first(where: { $0.kind == .theme }) {
        throw ThemeError(l.label, r.line, "a layer has no theme= record: it changes the theme beneath it")
      }
      layers.append(f)
    }
    if let v = stack.variant, !chain.contains(where: { $0.variants.contains { same($0, v) } }) {
      throw ThemeError(stack.theme, 0, "no variant \(v)")
    }
    var m = Merge()
    m.collect(chain, variant: stack.variant, layers: layers, highContrast: stack.highContrast)
    for k in stack.knobs { m.setKnob(k.name, k.value, Site(file: "theme check", line: 0)) }
    try m.borrow(variant: stack.variant, installed: installed, depth: 0)
    var e = Evaluator(m)
    return try e.theme(name: stack.theme, variant: stack.variant, highContrast: stack.highContrast)
  }

  /// The system's base theme, which every chain ends in.
  public static let base: Theme = {
    do { return try Theme.resolve(ThemeStack(theme: "base"), installed: { _ in nil }) } catch {
      fatalError("the base theme doesn't resolve")
    }
  }()

  /// A theme's chain, the base first.
  static func loadChain(_ name: String, installed: (String) -> [UInt8]?) throws(ThemeError) -> [ThemeFile] {
    var files: [ThemeFile] = []
    var next = name
    var from = (file: name, line: 0)
    while true {
      if files.contains(where: { $0.name.map { same($0, next) } ?? false }) {
        throw ThemeError(from.file, from.line, "inherits=\(next) makes a cycle")
      }
      let file: ThemeFile
      if same(next, "base") {
        file = try ThemeFile(parsing: Array(baseTheme.utf8), label: "base")
      } else {
        guard let text = installed(next) else { throw ThemeError(from.file, from.line, "no theme \(next)") }
        file = try ThemeFile(parsing: text, label: next)
      }
      guard let own = file.name, same(own, next) else {
        throw ThemeError(next, 1, "the file's first record must be theme=\(next)")
      }
      files.append(file)
      if same(next, "base") { break }
      let r = file.records.first { $0.kind == .theme }!
      from = (next, r.line(of: "inherits"))
      next = file.inherits ?? "base"
    }
    return files.reversed()
  }
}

struct Site {
  var file: String
  var line: Int
}

struct PartPair {
  var attr: String
  var value: String
  var site: Site
}

/// The stack merged, still in names.
struct Merge {
  var title = ""
  var roles: [(name: String, value: String, site: Site)] = []
  var faces: [(role: FontRole, pairs: [PartPair])] = []
  var parts: [(name: String, pairs: [PartPair])] = []
  var knobs: [(record: Record, site: Site)] = []
  var knobValues: [(name: String, value: String, site: Site)] = []
  var borrows: [(pattern: String, from: String, site: Site)] = []
  var textScale: (value: String, site: Site)? = nil

  mutating func collect(_ chain: [ThemeFile], variant: String?, layers: [ThemeFile], highContrast: Bool) {
    func belongs(_ r: Record, _ v: String?) -> Bool {
      switch (r.variant, v) {
      case (nil, nil): true
      case (let a?, let b?): same(a, b)
      default: false
      }
    }
    for f in chain { for r in f.records where r.variant == nil { apply(r, f.label) } }
    if let v = variant { for f in chain { for r in f.records where belongs(r, v) { apply(r, f.label) } } }
    for f in layers { for r in f.records where r.variant == nil || belongs(r, variant) { apply(r, f.label) } }
    if highContrast, !(variant.map { same($0, "high-contrast") } ?? false) {
      for f in chain { for r in f.records where belongs(r, "high-contrast") { apply(r, f.label) } }
    }
  }

  mutating func apply(_ r: Record, _ file: String) {
    let site = Site(file: file, line: r.line)
    let pairs = r.pairs.map { PartPair(attr: $0.attr, value: $0.value, site: Site(file: file, line: $0.source)) }
    switch r.kind {
    case .theme:
      if let t = r.value("title") { title = t }
    case .variant:
      if let t = r.value("title") { title = t }
    case .role:
      let v = r.value("color")!
      if let i = roles.firstIndex(where: { same($0.name, r.name) }) { roles[i] = (r.name, v, site) } else {
        roles.append((r.name, v, site))
      }
    case .typeface:
      let role = fontRole(r.name)!
      if let i = faces.firstIndex(where: { $0.role == role }) { faces[i].pairs += pairs } else {
        faces.append((role, pairs))
      }
    case .part:
      if let i = parts.firstIndex(where: { same($0.name, r.name) }) { parts[i].pairs += pairs } else {
        parts.append((r.name, pairs))
      }
    case .knob:
      if let value = r.value("value") {
        setKnob(r.name, value, Site(file: file, line: r.line(of: "value")))
      }
      if r.value("type") != nil {
        if let i = knobs.firstIndex(where: { same($0.record.name, r.name) }) { knobs[i] = (r, site) } else {
          knobs.append((r, site))
        }
      }
    case .parts:
      borrows.append((r.name, r.value("from")!, site))
    case .textscale:
      textScale = (r.name, site)
    }
  }

  mutating func setKnob(_ name: String, _ value: String, _ site: Site) {
    if let i = knobValues.firstIndex(where: { same($0.name, name) }) { knobValues[i] = (name, value, site) } else {
      knobValues.append((name, value, site))
    }
  }

  /// Borrowed parts: each family taken from its lender's own chain,
  /// replacing the borrower's, with the roles and knobs it names that the
  /// borrower lacks.
  mutating func borrow(variant: String?, installed: (String) -> [UInt8]?, depth: Int) throws(ThemeError) {
    guard !borrows.isEmpty else { return }
    guard depth < 4 else {
      throw ThemeError(borrows[0].site.file, borrows[0].site.line, "parts borrowed through more than four themes")
    }
    for b in borrows {
      let chain: [ThemeFile]
      do { chain = try Theme.loadChain(b.from, installed: installed) } catch {
        throw ThemeError(b.site.file, b.site.line, "parts=\(b.pattern) from=\(b.from): " + error.message)
      }
      var lender = Merge()
      let v = variant.flatMap { v in chain.contains { $0.variants.contains { same($0, v) } } ? v : nil }
      lender.collect(chain, variant: v, layers: [], highContrast: false)
      try lender.borrow(variant: variant, installed: installed, depth: depth + 1)
      parts.removeAll { matches(b.pattern, $0.name) }
      parts += lender.parts.filter { matches(b.pattern, $0.name) }
      for r in lender.roles where !roles.contains(where: { same($0.name, r.name) }) { roles.append(r) }
      for k in lender.knobs where !knobs.contains(where: { same($0.record.name, k.record.name) }) { knobs.append(k) }
    }
    borrows = []
  }
}

/// Whether a part's name is in a family: `*`, `name.*` (the name and
/// what's under it), or the name.
func matches(_ pattern: String, _ name: String) -> Bool {
  if same(pattern, "*") { return true }
  let p = pattern.utf8
  if p.count > 2, p.suffix(2).elementsEqual(".*".utf8) {
    let stem = p.dropLast(2)
    let n = name.utf8
    return n.elementsEqual(stem) || (n.count > stem.count && n.prefix(stem.count).elementsEqual(stem)
      && n.dropFirst(stem.count).first == UInt8(ascii: "."))
  }
  return same(pattern, name)
}

/// A part's materials, as written, until they are built.
struct Slots {
  var gradient: PartPair? = nil
  var angle: PartPair? = nil
  var bevel: PartPair? = nil
  var bevelWidth: PartPair? = nil
  var pattern: PartPair? = nil
  var patternColors: PartPair? = nil
  var pitch: PartPair? = nil
  var shadow: PartPair? = nil
  var shadowOffset: PartPair? = nil
  var blur: PartPair? = nil
}

struct Evaluator {
  let m: Merge
  var knobs: [Knob] = []

  init(_ m: Merge) { self.m = m }

  mutating func theme(name: String, variant: String?, highContrast: Bool) throws(ThemeError) -> Theme {
    knobs = try resolveKnobs()
    var roles: [(String, UInt32)] = []
    for r in m.roles { roles.append((r.name, try color(r.value, r.site, visiting: [r.name]))) }

    // Parts, each over its parent: "default" first, then by name, so a
    // parent (a prefix) is always done before its children.
    let names = m.parts.map { $0.name }.sorted { before($0, $1) }
    var done: [(name: String, style: Style, slots: Slots)] = []
    let fixed = (Style(ink: try color("ink", Site(file: "base", line: 0), depth: 0)), Slots())
    for n in [["default"], names.filter { !same($0, "default") }].joined() {
      guard let own = m.parts.first(where: { same($0.name, n) }) else { continue }
      var parent = fixed
      if !same(n, "default") {
        var p = n[...]
        var found = false
        while let dot = p.utf8.lastIndex(of: UInt8(ascii: ".")) {
          p = p[..<dot]
          if let d = done.first(where: { $0.name.utf8.elementsEqual(p.utf8) }) {
            parent = (d.style, d.slots)
            found = true
            break
          }
        }
        if !found, let d = done.first(where: { same($0.name, "default") }) { parent = (d.style, d.slots) }
      }
      var style = parent.0, slots = parent.1
      for pr in own.pairs { try apply(pr, to: &style, &slots) }
      style.materials = try materials(slots)
      done.append((n, style, slots))
    }

    var scale: Float = 1
    if let t = m.textScale {
      guard let s = parseNumber(t.value[...]), s > 0 else {
        throw ThemeError(t.site.file, t.site.line, "textscale=\(t.value) isn't a number above 0")
      }
      scale = Float(s)
    }
    let styles = done.map { d -> (String, Style) in
      var s = d.style
      s.textSize *= scale
      if highContrast { s.glow = 0 }
      return (d.name, s)
    }

    var faces: [Typeface] = []
    for role in [FontRole.display, .body, .mono, .ui] {
      var face = Typeface(family: "")
      for pr in m.faces.first(where: { $0.role == role })?.pairs ?? [] {
        if same(pr.attr, "family") { face.family = pr.value }
        if same(pr.attr, "weight") { face.weight = try integer(pr) }
        if same(pr.attr, "width") { face.width = try integer(pr) }
      }
      faces.append(face)
    }
    return Theme(name: name, title: m.title, variant: variant, textScale: scale, knobs: knobs, roles: roles,
                 styles: styles, faces: faces)
  }

  func resolveKnobs() throws(ThemeError) -> [Knob] {
    var out: [Knob] = []
    for (r, site) in m.knobs {
      let typeText = r.value("type")!
      let kinds: [(String, Knob.Kind)] = [("role", .role), ("choice", .choice), ("length", .length), ("scale", .scale)]
      guard let kind = kinds.first(where: { same($0.0, typeText) })?.1 else {
        throw ThemeError(site.file, r.line(of: "type"), "knob=\(r.name): type is role, choice, length or scale")
      }
      guard let def = r.value("default") else { throw ThemeError(site.file, r.line, "knob=\(r.name) needs default=") }
      var k = Knob(name: r.name, kind: kind, label: r.value("label"), defaultValue: def, value: def, options: [],
                   min: 0, max: 0)
      switch kind {
      case .role:
        k.options = split(r.value("suggest") ?? "")
      case .choice:
        k.options = split(r.value("choices") ?? "")
        guard !k.options.isEmpty else { throw ThemeError(site.file, r.line, "knob=\(r.name) needs choices=") }
      case .length, .scale:
        guard let lo = r.value("min").flatMap({ parseNumber($0[...]) }),
              let hi = r.value("max").flatMap({ parseNumber($0[...]) }), lo <= hi
        else { throw ThemeError(site.file, r.line, "knob=\(r.name) needs min= and max=, numbers, min no more than max") }
        k.min = lo
        k.max = hi
      }
      try validate(k, def, Site(file: site.file, line: r.line(of: "default")))
      if let set = m.knobValues.first(where: { same($0.name, r.name) }) {
        try validate(k, set.value, set.site)
        k.value = set.value
      }
      out.append(k)
    }
    for set in m.knobValues where !out.contains(where: { same($0.name, set.name) }) {
      throw ThemeError(set.site.file, set.site.line, "no knob \(set.name)")
    }
    return out
  }

  func validate(_ k: Knob, _ value: String, _ site: Site) throws(ThemeError) {
    switch k.kind {
    case .role:
      _ = try color(value, site, depth: 1)
    case .choice:
      guard k.options.contains(where: { same($0, value) }) else {
        throw ThemeError(site.file, site.line, "knob=\(k.name): \(value) isn't one of its choices")
      }
    case .length, .scale:
      guard let v = parseNumber(value[...]), v >= k.min, v <= k.max else {
        throw ThemeError(site.file, site.line, "knob=\(k.name): \(value) isn't a number in its bounds")
      }
    }
  }

  func knobValue(_ ref: Substring, _ site: Site) throws(ThemeError) -> String {
    let name = String(decoding: ref.utf8.dropFirst(), as: UTF8.self)
    guard let k = knobs.first(where: { same($0.name, name) }) else {
      throw ThemeError(site.file, site.line, "no knob \(name)")
    }
    return k.value
  }

  /// A colour: `0xrrggbb[aa]`, `none`, a role, a role at a percentage of
  /// its alpha (`role@20`), or a knob. `visiting` holds the roles and
  /// knobs being resolved, so a cycle is named where it begins.
  func color(_ text: String, _ site: Site, depth: Int = 0, visiting: [String] = []) throws(ThemeError) -> UInt32 {
    let t = text[...]
    if same(text, "none") { return 0 }
    if isHex(t) {
      guard let v = parseHex(t) else { throw ThemeError(site.file, site.line, "\(text) isn't 0xrrggbb or 0xrrggbbaa") }
      return v
    }
    // The alpha first, so that `$accent@20` is a knob at 20%.
    if let at = t.utf8.firstIndex(of: UInt8(ascii: "@")) {
      guard let p = parseNumber(t[t.utf8.index(after: at)...]), p >= 0, p <= 100 else {
        throw ThemeError(site.file, site.line, "\(text): the alpha after @ is a percentage")
      }
      return withAlpha(try color(String(t[..<at]), site, visiting: visiting), percent: p)
    }
    if t.utf8.first == UInt8(ascii: "$") {
      guard !visiting.contains(where: { same($0, text) }) else {
        throw ThemeError(site.file, site.line, "knob \(String(decoding: t.utf8.dropFirst(), as: UTF8.self)) refers to itself")
      }
      return try color(try knobValue(t, site), site, visiting: visiting + [text])
    }
    guard let r = m.roles.last(where: { same($0.name, text) }) else {
      throw ThemeError(site.file, site.line, "no role \(text)")
    }
    if visiting.contains(where: { same($0, text) }) {
      throw ThemeError(r.site.file, r.site.line, "role \(text) refers to itself")
    }
    return try color(r.value, r.site, visiting: visiting + [text])
  }

  func number(_ pr: PartPair) throws(ThemeError) -> Double {
    let t = pr.value[...]
    let text = t.utf8.first == UInt8(ascii: "$") ? try knobValue(t, pr.site) : pr.value
    guard let v = parseNumber(text[...]) else {
      throw ThemeError(pr.site.file, pr.site.line, "\(pr.attr)=\(pr.value) isn't a number")
    }
    return v
  }

  func numbers(_ pr: PartPair) throws(ThemeError) -> [Float] {
    var out: [Float] = []
    for part in split(pr.value) {
      out.append(Float(try number(PartPair(attr: pr.attr, value: part, site: pr.site))))
    }
    return out
  }

  func integer(_ pr: PartPair) throws(ThemeError) -> Int {
    let v = try number(pr)
    guard v == Double(Int(v)) else { throw ThemeError(pr.site.file, pr.site.line, "\(pr.attr)= is a whole number") }
    return Int(v)
  }

  func apply(_ pr: PartPair, to s: inout Style, _ slots: inout Slots) throws(ThemeError) {
    let a = pr.attr
    func err(_ m: String) -> ThemeError { ThemeError(pr.site.file, pr.site.line, m) }
    if same(a, "fill") {
      s.fill = try color(pr.value, pr.site, depth: 0)
    } else if same(a, "stroke") {
      s.stroke = try color(pr.value, pr.site, depth: 0)
    } else if same(a, "ink") {
      s.ink = try color(pr.value, pr.site, depth: 0)
    } else if same(a, "glowcolor") {
      s.glowColor = try color(pr.value, pr.site, depth: 0)
    } else if same(a, "border") {
      s.border = Float(try number(pr))
    } else if same(a, "radius") {
      s.radius = Float(try number(pr))
    } else if same(a, "glow") {
      s.glow = Float(try number(pr))
    } else if same(a, "cuts") {
      let c = try numbers(pr)
      guard c.count == 4 else { throw err("cuts= is four lengths: top left, top right, bottom right, bottom left") }
      s.cuts = Style.cuts(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3])
    } else if same(a, "padding") {
      let p = try numbers(pr)
      switch p.count {
      case 1: s.padding = (p[0], p[0], p[0], p[0])
      case 4: s.padding = (p[0], p[1], p[2], p[3])
      default: throw err("padding= is one length, or four: top, right, bottom, left")
      }
    } else if same(a, "font") {
      guard let f = fontRole(pr.value) else { throw err("font=\(pr.value): the roles are display, body, mono and ui") }
      s.font = f
    } else if same(a, "weight") {
      s.weight = try integer(pr)
    } else if same(a, "size") {
      s.textSize = Float(try number(pr))
    } else if same(a, "lineheight") {
      s.lineHeight = Float(try number(pr))
    } else if same(a, "tracking") {
      s.tracking = Float(try number(pr))
    } else if same(a, "case") {
      if same(pr.value, "upper") { s.uppercase = true } else if same(pr.value, "as-is") { s.uppercase = false } else {
        throw err("case= is upper or as-is")
      }
    } else if same(a, "gradient") {
      slots.gradient = pr
    } else if same(a, "angle") {
      slots.angle = pr
    } else if same(a, "bevel") {
      slots.bevel = pr
    } else if same(a, "bevelwidth") {
      slots.bevelWidth = pr
    } else if same(a, "pattern") {
      slots.pattern = pr
    } else if same(a, "patterncolors") {
      slots.patternColors = pr
    } else if same(a, "pitch") {
      slots.pitch = pr
    } else if same(a, "shadow") {
      slots.shadow = pr
    } else if same(a, "shadowoffset") {
      slots.shadowOffset = pr
    } else if same(a, "blur") {
      slots.blur = pr
    }
  }

  /// The materials a part's slots say, the shadow first (beneath), then
  /// the gradient, the pattern and the bevel.
  func materials(_ s: Slots) throws(ThemeError) -> [Material] {
    var out: [Material] = []
    func on(_ p: PartPair?) -> PartPair? { p.flatMap { same($0.value, "none") ? nil : $0 } }
    if let sh = on(s.shadow) {
      let off = try s.shadowOffset.map { p throws(ThemeError) in try numbers(p) } ?? [0, 2]
      guard off.count == 2 else {
        throw ThemeError(s.shadowOffset!.site.file, s.shadowOffset!.site.line, "shadowoffset= is x,y")
      }
      out.append(.shadow(try color(sh.value, sh.site, depth: 0), x: off[0], y: off[1],
                         blur: Float(try s.blur.map { p throws(ThemeError) in try number(p) } ?? 4)))
    }
    if let g = on(s.gradient) {
      let c = split(g.value)
      guard c.count == 2 else { throw ThemeError(g.site.file, g.site.line, "gradient= is two colours, from,to") }
      out.append(.gradient(try color(c[0], g.site, depth: 0), try color(c[1], g.site, depth: 0),
                           angle: Float(try s.angle.map { p throws(ThemeError) in try number(p) } ?? 90)))
    }
    if let p = on(s.pattern) {
      let kinds: [(String, PatternKind)] = [("stripes", .stripes), ("checks", .checks), ("dots", .dots)]
      guard let k = kinds.first(where: { same($0.0, p.value) })?.1 else {
        throw ThemeError(p.site.file, p.site.line, "pattern= is stripes, checks or dots")
      }
      guard let pc = s.patternColors, split(pc.value).count == 2 else {
        throw ThemeError(p.site.file, p.site.line, "pattern= needs patterncolors=, two colours")
      }
      let c = split(pc.value)
      out.append(.pattern(k, try color(c[0], pc.site, depth: 0), try color(c[1], pc.site, depth: 0),
                          pitch: Float(try s.pitch.map { p throws(ThemeError) in try number(p) } ?? 4)))
    }
    if let b = on(s.bevel) {
      let kinds: [(String, BevelKind)] = [("raised", .raised), ("inset", .inset), ("groove", .groove)]
      guard let k = kinds.first(where: { same($0.0, b.value) })?.1 else {
        throw ThemeError(b.site.file, b.site.line, "bevel= is raised, inset or groove")
      }
      out.append(.bevel(k, width: Float(try s.bevelWidth.map { p throws(ThemeError) in try number(p) } ?? 1)))
    }
    return out
  }
}

/// A comma-separated list's items.
func split(_ s: String) -> [String] {
  s.utf8.split(separator: UInt8(ascii: ",")).map { String(decoding: $0, as: UTF8.self) }
}
