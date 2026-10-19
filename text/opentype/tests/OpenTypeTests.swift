// SPDX-License-Identifier: BSD-3-Clause

// OpenType against FreeType (M6h): the test fonts in data/fonts (Noto Sans,
// TrueType outlines; Source Code Pro, CFF), and, with
// TODHCHAI_FONT_CORPUS=1, every font in /usr/share/fonts (about a minute),
// read by both and compared: glyph count, units per em, the hhea metrics,
// the family name, every cmap mapping, every glyph's advance and outline.
// Outlines are compared in font units, unhinted and unscaled, within half a
// unit: FreeType rounds a TrueType implied point and CFF's fractions to
// integers, where the reader keeps them exact.

import CFreeType
import FoundationEssentials
import Glibc
import OpenType
import Testing

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // text/opentype/tests/OpenTypeTests.swift
  return dir
}()

let testFonts = ["\(repository)/data/fonts/noto-sans/NotoSans-Regular.ttf",
                 "\(repository)/data/fonts/source-code-pro/SourceCodePro-Regular.otf"]

let uiFonts = ["chakra-petch/ChakraPetch-Medium.ttf", "chakra-petch/ChakraPetch-Bold.ttf",
               "barlow-condensed/BarlowCondensed-Medium.ttf", "barlow-condensed/BarlowCondensed-SemiBold.ttf",
               "ibm-plex-mono/IBMPlexMono-Regular.ttf", "ibm-plex-mono/IBMPlexMono-Medium.ttf",
               "ibm-plex-sans/IBMPlexSans-Regular.ttf", "ibm-plex-sans/IBMPlexSans-Medium.ttf",
               "ibm-plex-sans/IBMPlexSans-SemiBold.ttf"].map { "\(repository)/data/fonts/\($0)" }

func readFile(_ path: String) -> [UInt8]? {
  guard let d = try? Data(contentsOf: URL(filePath: path)) else { return nil }
  return [UInt8](d)
}

/// An outline as a list of drawing commands: what both sides are reduced to.
enum Command: Equatable, CustomStringConvertible {
  case move(Double, Double)
  case line(Double, Double)
  case quad(Double, Double, Double, Double)
  case cubic(Double, Double, Double, Double, Double, Double)

  var values: [Double] {
    switch self {
    case .move(let a, let b), .line(let a, let b): [a, b]
    case .quad(let a, let b, let c, let d): [a, b, c, d]
    case .cubic(let a, let b, let c, let d, let e, let f): [a, b, c, d, e, f]
    }
  }

  func close(to other: Command, within tolerance: Double) -> Bool {
    switch (self, other) {
    case (.move, .move), (.line, .line), (.quad, .quad), (.cubic, .cubic):
      return zip(values, other.values).allSatisfy { abs($0 - $1) <= tolerance }
    default:
      return false
    }
  }

  var description: String {
    switch self {
    case .move: "M\(values)"
    case .line: "L\(values)"
    case .quad: "Q\(values)"
    case .cubic: "C\(values)"
    }
  }
}

func commands(_ o: Outline) -> [Command] {
  var out: [Command] = []
  for c in o.contours {
    out.append(.move(c.start.x, c.start.y))
    for s in c.segments {
      switch s {
      case .line(let p): out.append(.line(p.x, p.y))
      case .quad(let a, let p): out.append(.quad(a.x, a.y, p.x, p.y))
      case .cubic(let a, let b, let p): out.append(.cubic(a.x, a.y, b.x, b.y, p.x, p.y))
      }
    }
  }
  return out
}

/// FreeType's outline of the glyph loaded in `face`, its closing lines
/// back to each contour's start left out, as the reader leaves them out.
final class Decomposed {
  var out: [Command] = []
  var start: (Double, Double) = (0, 0)
}

func freetypeCommands(_ face: FT_Face) -> [Command] {
  let sink = Decomposed()
  var funcs = FT_Outline_Funcs()
  funcs.move_to = { to, user in
    let s = Unmanaged<Decomposed>.fromOpaque(user!).takeUnretainedValue()
    let p = (Double(to!.pointee.x), Double(to!.pointee.y))
    s.start = p
    s.out.append(.move(p.0, p.1))
    return 0
  }
  funcs.line_to = { to, user in
    let s = Unmanaged<Decomposed>.fromOpaque(user!).takeUnretainedValue()
    s.out.append(.line(Double(to!.pointee.x), Double(to!.pointee.y)))
    return 0
  }
  funcs.conic_to = { c, to, user in
    let s = Unmanaged<Decomposed>.fromOpaque(user!).takeUnretainedValue()
    s.out.append(.quad(Double(c!.pointee.x), Double(c!.pointee.y), Double(to!.pointee.x), Double(to!.pointee.y)))
    return 0
  }
  funcs.cubic_to = { c1, c2, to, user in
    let s = Unmanaged<Decomposed>.fromOpaque(user!).takeUnretainedValue()
    s.out.append(.cubic(Double(c1!.pointee.x), Double(c1!.pointee.y), Double(c2!.pointee.x), Double(c2!.pointee.y),
                        Double(to!.pointee.x), Double(to!.pointee.y)))
    return 0
  }
  var outline = face.pointee.glyph.pointee.outline
  _ = FT_Outline_Decompose(&outline, &funcs, Unmanaged.passUnretained(sink).toOpaque())
  // Drop each contour's closing line back to its start.
  var out: [Command] = []
  var start: Command?
  for c in sink.out {
    if case .move = c {
      if case .line? = out.last, let s = start, out.last!.values == s.values { out.removeLast() }
      start = c
    }
    out.append(c)
  }
  if case .line? = out.last, let s = start, out.last!.values == s.values { out.removeLast() }
  return out
}

/// What differs between the two readings of the font at `path`, at most a
/// few of each.
func compare(_ path: String) -> [String] {
  var compared = (glyphs: 0, commands: 0)
  return compare(path, &compared)
}

/// The same, counting what was compared: glyphs, and drawing commands.
func compare(_ path: String, _ compared: inout (glyphs: Int, commands: Int)) -> [String] {
  guard let bytes = readFile(path) else { return ["can't read \(path)"] }
  var problems: [String] = []
  let font: Font
  do {
    font = try Font(bytes)
  } catch FontError.unsupported {
    return []  // a stub (CFF2): nothing to compare
  } catch {
    return ["\(path): \(error)"]
  }
  var library: FT_Library?
  guard FT_Init_FreeType(&library) == 0 else { return ["FreeType won't start"] }
  defer { FT_Done_FreeType(library) }
  var face: FT_Face?
  guard FT_New_Face(library, path, 0, &face) == 0, let face else { return ["FreeType won't open \(path)"] }
  defer { FT_Done_Face(face) }
  let f = face.pointee
  if font.glyphCount != Int(f.num_glyphs) { problems.append("glyphs: \(font.glyphCount), FreeType \(f.num_glyphs)") }
  if font.metrics.unitsPerEm != Int(f.units_per_EM) { problems.append("unitsPerEm") }
  if font.metrics.ascender != Int(f.ascender) || font.metrics.descender != Int(f.descender) {
    problems.append("ascender/descender: \(font.metrics.ascender)/\(font.metrics.descender), FreeType \(f.ascender)/\(f.descender)")
  }
  if let family = f.family_name.map({ String(cString: $0) }), font.name(1) != family && font.familyName != family {
    problems.append("family: \(font.familyName ?? "nil"), FreeType \(family)")
  }
  // cmap: every mapping, both ways.
  var theirs: [UInt32: Int] = [:]
  var index: FT_UInt = 0
  var code = FT_Get_First_Char(face, &index)
  while index != 0 {
    theirs[UInt32(code)] = Int(index)
    code = FT_Get_Next_Char(face, code, &index)
  }
  let ours = font.mappings()
  if ours.count != theirs.count { problems.append("cmap: \(ours.count) mappings, FreeType \(theirs.count)") }
  for (c, g) in ours where theirs[c] != g {
    problems.append("cmap U+\(String(c, radix: 16)): \(g), FreeType \(theirs[c] ?? 0)")
    if problems.count > 20 { return problems }
  }
  // Every glyph: advance and outline.
  var outlineProblems = 0
  for g in 0..<font.glyphCount {
    guard FT_Load_Glyph(face, FT_UInt(g), Int32(FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING)) == 0 else {
      problems.append("glyph \(g): FreeType won't load it")
      continue
    }
    let advance = Int(face.pointee.glyph.pointee.advance.x)
    if (try? font.advance(g)) != advance { problems.append("glyph \(g) advance: \(String(describing: try? font.advance(g))), FreeType \(advance)") }
    let theirOutline = freetypeCommands(face)
    let ourOutline: [Command]
    do {
      ourOutline = commands(try font.outline(g))
    } catch {
      problems.append("glyph \(g): \(error)")
      continue
    }
    compared.glyphs += 1
    compared.commands += theirOutline.count
    let same = ourOutline.count == theirOutline.count
      && zip(ourOutline, theirOutline).allSatisfy { $0.close(to: $1, within: 0.5 + 1e-9) }
    if !same {
      outlineProblems += 1
      if outlineProblems <= 3 {
        problems.append("glyph \(g) outline:\n  ours     \(ourOutline.prefix(12))\n  FreeType \(theirOutline.prefix(12))")
      }
    }
    if problems.count > 20 { break }
  }
  if outlineProblems > 3 { problems.append("\(outlineProblems) glyphs' outlines differ") }
  return problems
}

@Test func testFontsMatchFreeType() {
  for path in testFonts + uiFonts {
    var compared = (glyphs: 0, commands: 0)
    let problems = compare(path, &compared)
    #expect(problems.isEmpty, "\(path):\n\(problems.joined(separator: "\n"))")
    // Not vacuous: every glyph was compared, and their outlines had substance.
    let glyphs = (try? Font(readFile(path)!).glyphCount) ?? 0
    #expect(compared.glyphs == glyphs && compared.commands > 10 * glyphs, "\(path): \(compared)")
    print("\(path.split(separator: "/").last!): \(compared.glyphs) glyphs, \(compared.commands) drawing commands, all as FreeType has them")
  }
}

@Test func theTestFontsAreWhatTheyShouldBe() throws {
  let noto = try Font(readFile(testFonts[0])!), source = try Font(readFile(testFonts[1])!)
  #expect(noto.familyName == "Noto Sans" && !noto.isCFF)
  #expect(source.familyName == "Source Code Pro" && source.isCFF)
  // English's letters all map.
  for c in UInt32(0x20)...0x7E {
    #expect(noto.glyph(for: c) != 0 && source.glyph(for: c) != 0, "U+\(String(c, radix: 16))")
  }
  #expect(source.metrics.isFixedPitch && !noto.metrics.isFixedPitch)
  // TrueType's outlines are quadratic, CFF's cubic.
  let a1 = try noto.outline(noto.glyph(for: 0x61)), a2 = try source.outline(source.glyph(for: 0x61))
  #expect(a1.contours.flatMap(\.segments).contains { if case .quad = $0 { true } else { false } })
  #expect(a2.contours.flatMap(\.segments).contains { if case .cubic = $0 { true } else { false } })
  #expect(a1.contours.count == 2 && a2.contours.count == 2, "a: two contours")
}

/// A face's width class, as a theme's typeface names a width.
@Test func aFontSaysItsWidth() throws {
  let archivo = "\(repository)/data/fonts/archivo/"
  let widths = try ["Archivo-Regular.ttf", "ArchivoSemiCondensed-Bold.ttf", "ArchivoExpanded-ExtraBold.ttf"].map {
    try Font(readFile(archivo + $0)!).metrics.width
  }
  #expect(widths == [100, 87, 125])
  let barlow = try Font(readFile("\(repository)/data/fonts/barlow-condensed/BarlowCondensed-Medium.ttf")!)
  #expect(barlow.metrics.width == 75 && barlow.metrics.weight == 500)
}

// The stub this pins: CFF2 (variable CFF) outlines aren't read
// (text/README.md). Pinned on the host's Cantarell VF when it's there.
@Test func cff2IsAStub() throws {
  guard let bytes = readFile("/usr/share/fonts/abattis-cantarell-vf-fonts/Cantarell-VF.otf") else { return }
  #expect(throws: FontError.unsupported("CFF2 outlines (variable CFF)")) { try Font(bytes) }
}

@Test func malformedFontsThrow() {
  #expect(throws: FontError.notAFont) { try Font([0, 1, 2, 3]) }
  var bytes = readFile(testFonts[0])!
  // Cut the file short: a table past the end.
  bytes.removeLast(bytes.count / 2)
  #expect(throws: (any Error).self) { try Font(bytes) }
}

/// Every font on the host (TODHCHAI_FONT_CORPUS=1): whole families of
/// TrueType and CFF fonts, Latin and not. On this machine's Fedora 44, all
/// 398 agree (CFF2's one skipped: a stub).
@Test func theHostsFontsMatchFreeType() throws {
  guard getenv("TODHCHAI_FONT_CORPUS").map({ String(cString: $0) }) == "1" else { return }
  var paths: [String] = []
  if let sub = try? FileManager.default.subpathsOfDirectory(atPath: "/usr/share/fonts") {
    for p in sub where p.hasSuffix(".ttf") || p.hasSuffix(".otf") { paths.append("/usr/share/fonts/" + p) }
  }
  var failed: [String] = []
  var read = 0
  for path in paths.sorted() {
    let problems = compare(path)
    read += 1
    if !problems.isEmpty { failed.append("\(path): \(problems.first!) (+\(problems.count - 1))") }
  }
  print("fonts: \(read) compared, \(failed.count) differ")
  #expect(failed.isEmpty, "\(failed.prefix(15).joined(separator: "\n"))")
}
