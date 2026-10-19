// SPDX-License-Identifier: BSD-3-Clause

// The themes (D109): the base and every shipped theme resolve and pass
// theme check; Neon Tab's file resolves to the styles todhchai's code
// built (its two fixtures); and the resolver's layers, knobs, borrowed
// parts and errors behave as D108 says.

import FoundationEssentials
import NdbFile
import Testing
import Themes

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // ui/theme/tests/ThemesTests.swift
  return dir
}()

func read(_ path: String) -> [UInt8]? {
  (try? Data(contentsOf: URL(filePath: path))).map { [UInt8]($0) }
}

/// The tree's themes, by name.
func installed(_ name: String) -> [UInt8]? { read("\(repository)/ui/theme/themes/\(name)") }

let shipped = ["neon-tab"]

@Test func theBaseResolvesAndPasses() throws {
  let base = Theme.base
  for r in Roles.required { #expect(base.hasRole(r), "\(r)") }
  #expect(ThemeCheck.check("base", installed: installed) == [])
  #expect(base.typeface(.body).family == "IBM Plex Sans")
}

@Test(arguments: shipped) func shippedThemesPass(_ name: String) {
  #expect(ThemeCheck.check(name, installed: installed) == [])
}

/// A fixture's styles: name and style.
func fixture(_ file: String) throws -> [(String, Style)] {
  let text = String(decoding: try #require(read("\(repository)/ui/theme/tests/\(file)")), as: UTF8.self)
  var out: [(String, Style)] = []
  for line in text.split(separator: "\n") where !line.hasPrefix("#") {
    let f = line.split(separator: " ").map(String.init)
    func hex(_ s: String) -> UInt32 { UInt32(s.dropFirst(), radix: 16)! }
    func n(_ s: String) -> Float { Float(s)! }
    let font: FontRole = ["display": .display, "body": .body, "mono": .mono, "ui": .ui][f[9]]!
    out.append((f[0], Style(fill: hex(f[1]), stroke: hex(f[2]), ink: hex(f[3]), border: n(f[4]), radius: n(f[5]),
                            cuts: hex(f[6]), glow: n(f[7]), glowColor: hex(f[8]), font: font, weight: Int(f[10])!,
                            textSize: n(f[11]), lineHeight: n(f[12]), tracking: n(f[13]), uppercase: f[14] == "true",
                            padding: (n(f[15]), n(f[16]), n(f[17]), n(f[18])))))
  }
  return out
}

/// What differs between two styles, lengths within the file's four
/// places.
func differences(_ a: Style, _ b: Style) -> [String] {
  func close(_ x: Float, _ y: Float) -> Bool { abs(x - y) <= 1e-4 * max(1, abs(y)) }
  var d: [String] = []
  if a.fill != b.fill { d.append("fill") }
  if a.stroke != b.stroke { d.append("stroke") }
  if a.ink != b.ink { d.append("ink") }
  if !close(a.border, b.border) { d.append("border") }
  if !close(a.radius, b.radius) { d.append("radius") }
  if a.cuts != b.cuts { d.append("cuts") }
  if !close(a.glow, b.glow) { d.append("glow") }
  if a.glowColor != b.glowColor { d.append("glowColor") }
  if a.font != b.font { d.append("font") }
  if a.weight != b.weight { d.append("weight") }
  if !close(a.textSize, b.textSize) { d.append("textSize \(a.textSize) \(b.textSize)") }
  if !close(a.lineHeight, b.lineHeight) { d.append("lineHeight") }
  if !close(a.tracking, b.tracking) { d.append("tracking") }
  if a.uppercase != b.uppercase { d.append("uppercase") }
  if !close(a.padding.top, b.padding.top) || !close(a.padding.right, b.padding.right)
    || !close(a.padding.bottom, b.padding.bottom) || !close(a.padding.left, b.padding.left)
  {
    d.append("padding")
  }
  if !a.materials.isEmpty { d.append("materials") }
  return d
}

@Test(arguments: [(nil, "neon-tab.styles"), ("high-contrast", "neon-tab-high-contrast.styles")] as [(String?, String)])
func neonTabIsTodhchais(_ variant: String?, _ file: String) throws {
  let theme = try Theme.resolve(ThemeStack(theme: "neon-tab", variant: variant), installed: installed)
  let expected = try fixture(file)
  #expect(expected.count == 120)
  var wrong: [String] = []
  for (name, style) in expected {
    let d = differences(theme.style(name), style)
    if !d.isEmpty { wrong.append("\(name): \(d.joined(separator: ", "))") }
  }
  #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
  #expect(theme.textScale == (variant == nil ? 1 : 1.25))
}

@Test func valuesWithSpacesAreQuoted() throws {
  let f = try ThemeFile(parsing: Array("""
    theme=t title="A theme with spaces" inherits=base
    typeface=ui family="Barlow Condensed" weight=500
    """.utf8), label: "t")
  #expect(f.title == "A theme with spaces")
  let theme = try Theme.resolve(ThemeStack(theme: "t"), installed: { _ in Array("""
    theme=t title="A theme with spaces" inherits=base
    typeface=ui family="Barlow Condensed" weight=500
    """.utf8) })
  #expect(theme.title == "A theme with spaces")
  #expect(theme.typeface(.ui) == Typeface(family: "Barlow Condensed", weight: 500))
}

/// A theme of a few lines over the base, for the resolver's tests.
let small = """
  theme=small inherits=base
  role=chrome color=0x202020
  role=ink color=0xf0f0f0
  role=ink.dim color=0xc0c0c0
  role=accent.one color=0x40a0ff
  role=accent.two color=0xffa040
  knob=accent type=role default=accent.one suggest=accent.one,accent.two label="Accent colour"
  knob=edge type=length min=0 max=4 default=1
  knob=density type=choice choices=compact,regular default=regular
  part=button stroke=$accent border=$edge
  part=button.primary fill=$accent@20
  variant=dark title="Small, dark"
  	role=chrome color=0x000000
  """

let next = """
  theme=next inherits=base
  role=next.bar color=0x000000
  part=window.tab fill=next.bar ink=ink.on-select radius=0
  part=window.tab.focused fill=next.bar
  part=window.body radius=0 border=2
  """

func smallInstalled(_ name: String) -> [UInt8]? {
  same(name, "small") ? Array(small.utf8) : same(name, "next") ? Array(next.utf8) : installed(name)
}

func same(_ a: String, _ b: String) -> Bool { a == b }

@Test func partsInheritFromTheirDotParent() throws {
  let t = try Theme.resolve(ThemeStack(theme: "small"), installed: smallInstalled)
  // button.primary is the base's (stroke focus, border 2) over small's
  // button, with its own fill.
  #expect(t.style("button").stroke == 0xFF40_A0FF)
  #expect(t.style("button.primary").fill == 0x3340_A0FF)
  #expect(t.style("button.primary").border == 2)
  #expect(t.style("button.secondary") == t.style("button"))
  #expect(t.style("nothing.like.it") == t.style("default"))
  // Pressed, derived.
  #expect(t.style("button.held").fill == 0x33F0_F0F0)
}

@Test func layersStackInOrder() throws {
  let user = ThemeLayer(label: "user", text: Array("""
    knob=accent value=accent.two
    role=chrome color=0x303030
    """.utf8))
  let workspace = ThemeLayer(label: "workspace 2", text: Array("role=chrome color=0x404040\n".utf8))
  let t = try Theme.resolve(ThemeStack(theme: "small", variant: "dark", layers: [user, workspace]),
                            installed: smallInstalled)
  #expect(t.color("chrome") == 0xFF40_4040)
  #expect(t.knob("accent") == "accent.two")
  #expect(t.style("button").stroke == 0xFFFF_A040)
  #expect(t.title == "Small, dark")
  // Without the layers, the variant's chrome.
  let dark = try Theme.resolve(ThemeStack(theme: "small", variant: "dark"), installed: smallInstalled)
  #expect(dark.color("chrome") == 0xFF00_0000)
}

@Test func highContrastIsOneSwitch() throws {
  let t = try Theme.resolve(ThemeStack(theme: "neon-tab", highContrast: true), installed: installed)
  #expect(t.color("desk") == 0xFF00_0000)
  #expect(t.style("window.body.focused").glow == 0)
  #expect(t.textScale == 1.25)
  // A theme without its own takes the base's.
  let s = try Theme.resolve(ThemeStack(theme: "small", highContrast: true), installed: smallInstalled)
  #expect(s.color("focus") == 0xFFFF_FF00)
}

@Test func borrowedPartsTakeTheBorrowersRoles() throws {
  let layer = ThemeLayer(label: "workspace 1", text: Array("parts=window.* from=next\nrole=next.bar color=0x123456\n".utf8))
  let t = try Theme.resolve(ThemeStack(theme: "neon-tab", layers: [layer]), installed: smallInstalled)
  #expect(t.style("window.tab").fill == 0xFF12_3456)
  #expect(t.style("window.body").border == 2)
  // The borrower's own role: Neon Tab's desk as ink.on-select.
  #expect(t.style("window.tab").ink == 0xFF0A_0A12)
  // Neon Tab's other parts stand.
  #expect(t.style("button.primary").stroke == 0xFF00_E5FF)
  // Its window.tab.widget went with the family it belonged to.
  #expect(!t.defines("window.tab.widget"))
}

@Test func theCheckTurnsEveryKnob() {
  let bad = """
    theme=bad inherits=base
    knob=ink type=role default=dark suggest=dark,pale
    role=dark color=0x000000
    role=pale color=0xe0e0e0
    role=ink color=$ink
    """
  let findings = ThemeCheck.check("bad", installed: { same($0, "bad") ? Array(bad.utf8) : nil })
  #expect(findings.contains { $0.contains("knob ink=pale") && $0.contains("ink on chrome") })
  #expect(!findings.contains { $0.contains("bad: ink on chrome") })
}

@Test(arguments: [
  ("theme=e inherits=base\npart=button colour=0xffffff\n", "e:2: part=button has no attribute colour"),
  ("theme=e inherits=base\npart=button fill=nothing\n", "e:2: no role nothing"),
  ("theme=e inherits=base\nrole=a color=b\nrole=b color=a\npart=x fill=a\n", "e:2: role a refers to itself"),
  ("theme=e inherits=e\n", "e:1: inherits=e makes a cycle"),
  ("theme=e inherits=nowhere\n", "e:1: no theme nowhere"),
  ("theme=e inherits=base\nknob=r type=length min=0 max=4 default=9\n", "e:2: knob=r: 9 isn't a number in its bounds"),
  ("theme=e inherits=base\nrole=x\n", "e:2: role=x needs color="),
  ("role=x color=0x000000\ntheme=e\n", "e:2: theme= must be the file's first record"),
  ("theme=e inherits=base\nknob=nope value=1\n", "e:2: no knob nope"),
  ("theme=e inherits=base\npart=Button fill=none\n", "e:2: part= needs a name, dotted words: not \"Button\""),
] as [(String, String)])
func errorsNameTheLine(_ text: String, _ message: String) {
  do {
    _ = try Theme.resolve(ThemeStack(theme: "e"), installed: { same($0, "e") ? Array(text.utf8) : nil })
    Issue.record("resolved: \(text)")
  } catch {
    #expect(error.text == message)
  }
}

@Test func aLayerCantBeATheme() {
  let layer = ThemeLayer(label: "user", text: Array("theme=sneaky inherits=base\n".utf8))
  do {
    _ = try Theme.resolve(ThemeStack(theme: "neon-tab", layers: [layer]), installed: installed)
    Issue.record("resolved")
  } catch {
    #expect(error.text == "user:1: a layer has no theme= record: it changes the theme beneath it")
  }
}

@Test func contrastIsWCAGs() {
  #expect(abs(Contrast.ratio(0xFF00_0000, 0xFFFF_FFFF) - 21) < 1e-9)
  #expect(abs(Contrast.ratio(0xFF77_7777, 0xFFFF_FFFF) - 4.478) < 0.001)
}
