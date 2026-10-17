// SPDX-License-Identifier: BSD-3-Clause

// Segmentation against Unicode's conformance files (M6h): every case of
// GraphemeBreakTest.txt, WordBreakTest.txt (UAX #29) and LineBreakTest.txt
// (UAX #14), and the generated tables against the data.

import FoundationEssentials
import TDUnicode
import Testing
import UCDGen

/// A test file's cases: each string's scalars, and where it breaks (the
/// positions from 0 to its length marked ÷).
func breakCases(_ file: String) -> [(line: Int, scalars: [UInt32], breaks: [Int])] {
  var out: [(Int, [UInt32], [Int])] = []
  for (n, line) in ucdFile(file).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
    let body = line.prefix { $0 != "#" }
    var scalars: [UInt32] = [], breaks: [Int] = []
    for token in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
      if token == "÷" {
        breaks.append(scalars.count)
      } else if token == "×" {
        continue
      } else if let v = UInt32(token, radix: 16) {
        scalars.append(v)
      }
    }
    if !scalars.isEmpty { out.append((n + 1, scalars, breaks)) }
  }
  return out
}

func hex(_ s: [UInt32]) -> String { s.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ") }

@Test func graphemeBreakTestPasses() {
  let cases = breakCases("GraphemeBreakTest.txt")
  #expect(cases.count > 700)
  var failed = 0
  for c in cases where Segmentation.graphemeBoundaries(c.scalars) != c.breaks {
    failed += 1
    if failed <= 10 { Issue.record("line \(c.line): \(hex(c.scalars)): \(Segmentation.graphemeBoundaries(c.scalars)), expected \(c.breaks)") }
  }
  #expect(failed == 0, "\(failed) of \(cases.count) cases")
}

@Test func wordBreakTestPasses() {
  let cases = breakCases("WordBreakTest.txt")
  #expect(cases.count > 1_500)
  var failed = 0
  for c in cases where Segmentation.wordBoundaries(c.scalars) != c.breaks {
    failed += 1
    if failed <= 10 { Issue.record("line \(c.line): \(hex(c.scalars)): \(Segmentation.wordBoundaries(c.scalars)), expected \(c.breaks)") }
  }
  #expect(failed == 0, "\(failed) of \(cases.count) cases")
}

@Test func lineBreakTestPasses() {
  let cases = breakCases("LineBreakTest.txt")
  #expect(cases.count > 15_000)
  var failed = 0
  for c in cases {
    let got = Segmentation.lineBreaks(c.scalars).map(\.index)
    if got != c.breaks {
      failed += 1
      if failed <= 10 { Issue.record("line \(c.line): \(hex(c.scalars)): \(got), expected \(c.breaks)") }
    }
  }
  #expect(failed == 0, "\(failed) of \(cases.count) cases")
}

@Test func mandatoryBreaksAreMarked() {
  let text: [UInt32] = Array("one\ntwo\r\nthree".unicodeScalars.map(\.value))
  let breaks = Segmentation.lineBreaks(text)
  #expect(breaks.filter { $0.kind == .mandatory }.map(\.index) == [4, 9, 14])
  #expect(breaks.filter { $0.kind == .allowed }.isEmpty)
}

@Test func theCommittedSegmentationTablesAreCurrent() {
  let data = SegmentationData(
    unicodeData: ucdFile("UnicodeData.txt"), graphemeBreak: ucdFile("GraphemeBreakProperty.txt"),
    wordBreak: ucdFile("WordBreakProperty.txt"), lineBreak: ucdFile("LineBreak.txt"),
    derivedCore: ucdFile("DerivedCoreProperties.txt"), eastAsianWidth: ucdFile("EastAsianWidth.txt"),
    emoji: ucdFile("emoji-data.txt"))
  let committed = try? String(contentsOfFile: "\(dataDir)/../../text/unicode/lib/generated/SegmentationTables.swift", encoding: .utf8)
  #expect(committed == data.swift(version: "18.0.0"), "regenerate: .build/debug/ucdgen data/unicode text/unicode/lib/generated/Tables.swift")
}

// English, as prose has it: what the rules (which the conformance files
// check) do with the things English text is made of.

func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

/// The words of `s`: the segments between boundaries that hold a letter or
/// digit.
func words(_ s: String) -> [String] {
  let u = Array(s.unicodeScalars)
  let b = Segmentation.wordBoundaries(u.map(\.value))
  return zip(b, b.dropFirst()).map { String(String.UnicodeScalarView(u[$0..<$1])) }
    .filter { $0.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil } }
}

/// The lines `s` may break into: the text before each break.
func lineSegments(_ s: String) -> [String] {
  let u = Array(s.unicodeScalars)
  var start = 0
  return Segmentation.lineBreaks(u.map(\.value)).map { b in
    defer { start = b.index }
    return String(String.UnicodeScalarView(u[start..<b.index]))
  }
}

@Test func englishWords() {
  #expect(words("Don't stop: it's Kate's book.") == ["Don't", "stop", "it's", "Kate's", "book"])
  #expect(words("A well-known 3.14159 and 1,000,000 or $4.99, at 10:30.") ==
          ["A", "well", "known", "3.14159", "and", "1,000,000", "or", "4.99", "at", "10", "30"])
  #expect(words("e.g. U.S.A. state_of_the_art") == ["e.g", "U.S.A", "state_of_the_art"])
  #expect(words("naïve café façade") == ["naïve", "café", "façade"])
  // A decomposed é is one grapheme and stays in its word.
  #expect(words("cafe\u{301} au lait") == ["cafe\u{301}", "au", "lait"])
}

@Test func englishLines() {
  #expect(lineSegments("The quick brown fox.") == ["The ", "quick ", "brown ", "fox."])
  // A hyphen offers a break after it; an em dash on either side.
  #expect(lineSegments("well-known") == ["well-", "known"])
  #expect(lineSegments("this\u{2014}that") == ["this", "\u{2014}", "that"])
  // Closing punctuation and quotation marks stay with their word.
  #expect(lineSegments("\u{201C}Hello,\u{201D} she said\u{2026} (quietly).") ==
          ["\u{201C}Hello,\u{201D} ", "she ", "said\u{2026} ", "(quietly)."])
  // Numbers with their signs and separators hold together.
  #expect(lineSegments("costs $1,234.56 or 15% now") == ["costs ", "$1,234.56 ", "or ", "15% ", "now"])
  // A no-break space joins.
  #expect(lineSegments("10\u{A0}km away") == ["10\u{A0}km ", "away"])
}

@Test func englishGraphemes() {
  // Each letter one cluster; CR LF one; an emoji with its skin tone one.
  #expect(Segmentation.graphemeBoundaries(scalars("ab\r\nc")) == [0, 1, 2, 4, 5])
  #expect(Segmentation.graphemeBoundaries(scalars("👍🏽!")) == [0, 2, 3])
}

// The stub this pins: line breaking has no dictionary for SA scripts, so a
// run of Thai with no spaces breaks only at its end (text/README.md).
@Test func thaiBreaksOnlyAtSpacesForNow() {
  #expect(lineSegments("สวัสดีครับ") == ["สวัสดีครับ"])
  #expect(lineSegments("สวัสดี ครับ") == ["สวัสดี ", "ครับ"])
}
