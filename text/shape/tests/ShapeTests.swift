// SPDX-License-Identifier: BSD-3-Clause

// The default shaper against HarfBuzz (M6h): English text in every shape
// it takes (prose, punctuation, ligatures, kerning pairs, numbers and
// currency, soft hyphens and joiners, every space, accents precomposed and
// combining), the European alphabets, Vietnamese's stacked marks, Greek
// and Cyrillic, and every Latin character with every combining mark,
// shaped with the test fonts (Noto Sans: TrueType, GSUB and GPOS with mark
// filtering; Source Code Pro: CFF) with the default features and with
// each of their optional ones, by both, and compared: glyphs, clusters,
// advances and offsets, exactly. With TODHCHAI_FONT_CORPUS=1, the same
// text in every font of the host (about a minute).

import CHarfBuzz
import FoundationEssentials
import Glibc
import OpenType
import Shape
import Testing

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // text/shape/tests/ShapeTests.swift
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

/// English, as it's written.
let english = [
  "The quick brown fox jumps over the lazy dog.",
  "Sphinx of black quartz, judge my vow! PACK MY BOX WITH FIVE DOZEN LIQUOR JUGS.",
  "office waffle fluffy affinity fjord ffi ffl ff fi fl ft fb fh fk",
  "AVATAR Tolkien WAVE Yes. Type: VAT, To, Wa, Ye, LT, P., F., T, Ty Yo Av",
  "“Quoted,” he said — ‘single’ quotes, it’s O’Neill’s; an ellipsis… and \"straight\" 'ones'.",
  "1st 2nd 3rd 4th: £3.50, €4, $5.99, ¥6, ¢7, 10% off; 3–4 p.m.; 1,234,567.89; #1 & @2 * ~3 ^4",
  "naïve café résumé coöperate façade Zoë Brontë déjà vu",
  "e\u{301} a\u{308}\u{301} o\u{302}\u{303} i\u{307}\u{301} q\u{303} x\u{331} n\u{303} c\u{327}",
  "co\u{AD}op\u{AD}er\u{AD}ate hy\u{AD}phen\u{AD}ation",
  "of\u{200C}fice f\u{200D}i a\u{200B}b word\u{2060}joiner \u{FEFF}bom",
  "non\u{A0}breaking\u{2009}thin\u{202F}narrow\u{2002}en\u{2003}em\u{200A}hair\u{2007}figure\u{2008}punct\u{205F}math\u{2004}three\u{2005}four\u{2006}six\u{3000}ideo",
  "non\u{2011}breaking hyphen ‐ ‒ – — ― −",
  "Email: someone@example.com, see https://example.org/path?q=1&r=2#frag",
  "(brackets) [square] {curly} <angle> «guillemets» ‹single› /slash\\ |bar|",
  "x² + y³ = z¹ ½ ¼ ¾ ° ± × ÷ µ § ¶ © ® ™ † ‡ • · ′ ″",
  "👍🏽 👨‍👩‍👧 🇮🇪🇬🇧 ❤\u{FE0F}",
  "tab\tand newline\n and\r\n",
  "",
  "a",
  "\u{301}\u{302} marks with no base",
]

/// The European alphabets, and Vietnamese.
let european = [
  "Größe Straße Äpfel Öl Übel ẞ",
  "Zażółć gęślą jaźń",
  "Příliš žluťoučký kůň úpěl ďábelské ódy",
  "Árvíztűrő tükörfúrógép",
  "Fiță, ș ț Ș Ț ş ţ",
  "İstanbul ılık ığdır",
  "IJsland ijs Ĳ ĳ",
  "Þór og ðæ Ærøskøbing Å œuvre Œdipe Æsop",
  "Tiếng Việt có dấu: ằ ẵ ặ ể ỡ ự Ầ Ẫ Ậ",
  "L·l col·lecció Ŀ ŀ ĸ ŉ ſ",
  "a\u{328}\u{301} e\u{328}\u{301} i\u{328}\u{307}\u{301} u\u{328}\u{303}",  // Lithuanian
]

let greek = ["Λόγος Ελληνικά: ξεσκεπάζω την ψυχοφθόρα βδελυγμία", "ΐ ΰ ᾶ ἄ ὕ"]
let cyrillic = ["Съешь же ещё этих мягких французских булок, да выпей чаю", "Ї ї Ґ ґ Ў ў Ђ ђ"]

/// Every Latin character the test fonts cover, together, and each
/// combining mark after the bases that most often carry marks.
let latin: [String] = {
  var all = ""
  for c in UInt32(0x21)...0x17F where !(0x7F...0xA0).contains(c) { all.unicodeScalars.append(Unicode.Scalar(c)!) }
  var marks = ""
  for base in ["a", "i", "j", "A", "f", "o\u{31B}", "ı"] {
    for m in UInt32(0x300)...0x36F {
      marks += base
      marks.unicodeScalars.append(Unicode.Scalar(m)!)
      marks += " "
    }
  }
  return [all, marks]
}()

/// Optional features, one set at a time.
let featureSets: [[String]] = [
  [], ["-liga"], ["-kern"], ["smcp"], ["c2sc", "smcp"], ["onum", "pnum"], ["tnum", "lnum"], ["salt"], ["salt=2"],
  ["ss01"], ["ss03"], ["case"], ["frac"], ["sups"], ["subs"], ["zero"], ["aalt=3"], ["cv01=2"], ["-ccmp", "-mark"],
]

/// HarfBuzz, for one font.
final class Oracle {
  let blob: OpaquePointer?
  let face: OpaquePointer?
  let font: OpaquePointer?

  init(_ path: String) {
    blob = hb_blob_create_from_file(path)
    face = hb_face_create(blob, 0)
    font = hb_font_create(face)
  }

  deinit {
    hb_font_destroy(font)
    hb_face_destroy(face)
    hb_blob_destroy(blob)
  }

  func shape(_ text: [UInt32], script: hb_script_t, language: String, features: [String]) -> [ShapedGlyph] {
    let buffer = hb_buffer_create()
    defer { hb_buffer_destroy(buffer) }
    hb_buffer_add_utf32(buffer, text, Int32(text.count), 0, Int32(text.count))
    hb_buffer_set_direction(buffer, HB_DIRECTION_LTR)
    hb_buffer_set_script(buffer, script)
    hb_buffer_set_language(buffer, hb_language_from_string(language, -1))
    var fs: [hb_feature_t] = features.map { f in
      var feature = hb_feature_t()
      _ = hb_feature_from_string(f, -1, &feature)
      return feature
    }
    // HarfBuzz's OpenType shaper, never Graphite's (the host's HarfBuzz
    // has Graphite2, which a font with a Silf table would get).
    var shapers: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("ot")), nil]
    defer { free(UnsafeMutablePointer(mutating: shapers[0])) }
    _ = hb_shape_full(font, buffer, &fs, UInt32(fs.count), &shapers)
    var count: UInt32 = 0
    let infos = hb_buffer_get_glyph_infos(buffer, &count)
    let positions = hb_buffer_get_glyph_positions(buffer, &count)
    return (0..<Int(count)).map { i in
      ShapedGlyph(glyph: Int(infos![i].codepoint), cluster: Int(infos![i].cluster),
                  xAdvance: Int(positions![i].x_advance), yAdvance: Int(positions![i].y_advance),
                  xOffset: Int(positions![i].x_offset), yOffset: Int(positions![i].y_offset))
    }
  }
}

/// "liga", "-liga", "salt=2" as our features.
func feature(_ s: String) -> Feature {
  if s.hasPrefix("-") { return Feature(String(s.dropFirst()), 0) }
  if let eq = s.firstIndex(of: "=") { return Feature(String(s[..<eq]), Int(s[s.index(after: eq)...])!) }
  return Feature(s)
}

func describe(_ g: [ShapedGlyph]) -> String {
  g.map { "\($0.glyph)@\($0.cluster)+\($0.xAdvance)" + ($0.xOffset != 0 || $0.yOffset != 0 ? "(\($0.xOffset),\($0.yOffset))" : "") }
    .joined(separator: " ")
}

/// What differs between the two shapers on a font: the first few cases,
/// and how many were compared.
func compare(_ path: String, featureSets: [[String]]) throws -> (problems: [String], cases: Int) {
  let font = try Font(try #require(readFile(path)))
  let shaper = Shaper(font)
  let oracle = Oracle(path)
  var problems: [String] = []
  var cases = 0
  let texts: [(String, hb_script_t, String)] =
    english.map { ($0, HB_SCRIPT_LATIN, "latn") } + european.map { ($0, HB_SCRIPT_LATIN, "latn") }
    + latin.map { ($0, HB_SCRIPT_LATIN, "latn") } + greek.map { ($0, HB_SCRIPT_GREEK, "grek") }
    + cyrillic.map { ($0, HB_SCRIPT_CYRILLIC, "cyrl") }
  let languages: [(bcp47: String, ot: String?)] = [("und", nil), ("en", "ENG "), ("nl", "NLD "), ("pl", "PLK "),
                                                    ("ro", "ROM "), ("ca", "CAT "), ("tr", "TRK "), ("de", "DEU ")]
  for (text, hbScript, script) in texts {
    let scalars = text.unicodeScalars.map(\.value)
    for features in featureSets {
      for (bcp47, ot) in features.isEmpty ? languages : [languages[0]] {
        cases += 1
        let theirs = oracle.shape(scalars, script: hbScript, language: bcp47, features: features)
        let ours = shaper.shape(scalars, script: script, language: ot, features: features.map(feature))
        if ours != theirs && problems.count < 6 {
          var first = 0
          while first < min(ours.count, theirs.count) && ours[first] == theirs[first] { first += 1 }
          let from = max(0, first - 2)
          problems.append(
            "\(path.split(separator: "/").last!) \(script) \(bcp47) \(features) \"\(text.prefix(60))\" at glyph \(first):\n"
              + "  ours     \(describe(Array(ours[from..<min(ours.count, from + 8)])))\n"
              + "  HarfBuzz \(describe(Array(theirs[from..<min(theirs.count, from + 8)]))) (\(ours.count) vs \(theirs.count) glyphs)")
        }
      }
    }
  }
  return (problems, cases)
}

@Test(arguments: testFonts + uiFonts) func shapesAsHarfBuzz(_ path: String) throws {
  let (problems, cases) = try compare(path, featureSets: featureSets)
  print("\(path.split(separator: "/").last!): \(cases) cases, \(problems.isEmpty ? "all as HarfBuzz shapes them" : "\(problems.count)+ differ")")
  #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
}

/// Every font on the host (TODHCHAI_FONT_CORPUS=1), with the default
/// features; color fonts skipped (a stub: their glyphs' extents, which
/// place marks where there's no GPOS, come from COLR, CBDT or sbix).
@Test func theHostsFontsShapeAsHarfBuzz() throws {
  guard getenv("TODHCHAI_FONT_CORPUS").map({ String(cString: $0) }) == "1" else { return }
  let paths = (try FileManager.default.subpathsOfDirectory(atPath: "/usr/share/fonts")).filter {
    $0.hasSuffix(".ttf") || $0.hasSuffix(".otf")
  }.sorted()
  var failed: [String] = []
  var compared = 0
  for p in paths {
    let path = "/usr/share/fonts/" + p
    guard let bytes = readFile(path), let font = try? Font(bytes),
      !["COLR", "CBDT", "sbix"].contains(where: { font.has($0) })
    else { continue }
    compared += 1
    let (problems, _) = try compare(path, featureSets: [[]])
    if let first = problems.first {
      failed.append(first)
      if getenv("TODHCHAI_SHAPE_VERBOSE") != nil { print("DIFFERS " + first.split(separator: "\n").joined(separator: " | ")) }
    }
  }
  print("fonts: \(compared) shaped, \(failed.count) differ")
  #expect(failed.isEmpty, "\(failed.prefix(12).joined(separator: "\n"))")
}

/// The comparison is only as good as what it exercises: pinned here, the
/// things it must have seen in Noto Sans (a ligature, kerning, a mark on a
/// base by its anchors, a soft hyphen hidden).
@Test func theComparisonExercisesTheShaper() throws {
  let font = try Font(try #require(readFile(testFonts[0])))
  let shaper = Shaper(font)
  func shape(_ s: String, _ features: [Feature] = []) -> [ShapedGlyph] { shaper.shape(s.unicodeScalars.map(\.value), features: features) }
  // "fi": one glyph, a ligature, one cluster.
  let fi = shape("fi")
  #expect(fi.count == 1 && fi[0].glyph != font.glyph(for: 0x66) && fi[0].cluster == 0)
  #expect(shape("fi", [Feature("liga", 0)]).count == 2)
  // "AV" kerns: A's advance is less than hmtx's.
  let av = shape("AV")
  #expect(av[0].xAdvance < (try font.advance(font.glyph(for: 0x41))))
  // Q + combining tilde (no precomposed glyph): the mark is attached by
  // its anchor, raised over the capital, with no advance, in Q's cluster.
  let q = shape("Q\u{303}")
  #expect(q.count == 2 && q[1].xAdvance == 0 && q[1].yOffset > 100 && q[1].cluster == 0)
  // i, dot below, circumflex: ccmp's context makes the i dotless under
  // the circumflex.
  let i = shape("i\u{323}\u{302}")
  #expect(i.count == 3 && i[0].glyph != font.glyph(for: 0x69))
  // e + combining acute composes to é's glyph.
  let e = shape("e\u{301}")
  #expect(e.count == 1 && e[0].glyph == font.glyph(for: 0xE9))
  // A soft hyphen is the space glyph at no width.
  let shy = shape("a\u{AD}b")
  #expect(shy.count == 3 && shy[1].glyph == font.glyph(for: 0x20) && shy[1].xAdvance == 0)
}
