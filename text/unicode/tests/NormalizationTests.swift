// SPDX-License-Identifier: BSD-3-Clause

// TDUnicode against the UCD: all of NormalizationTest.txt (UAX #15's
// conformance test), the generated tables against the data, case folding,
// and strict UTF-8.

import FoundationEssentials
import TDUnicode
import Testing
import UCDGen

let dataDir: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // text/unicode/tests/NormalizationTests.swift
  return dir + "/data/unicode"
}()

func ucdFile(_ name: String) -> String { (try? String(contentsOfFile: "\(dataDir)/\(name)", encoding: .utf8)) ?? "" }

func scalars(_ field: Substring) -> [UInt32] { field.split(separator: " ").compactMap { UInt32($0, radix: 16) } }

@Test func normalizationTestPasses() {
  let lines = ucdFile("NormalizationTest.txt").split(separator: "\n")
  #expect(lines.count > 19_000)
  var part1: Set<UInt32> = []
  var part = ""
  var cases = 0
  for line in lines {
    if line.hasPrefix("@") {
      part = String(line.prefix { $0 != " " })
      continue
    }
    if line.hasPrefix("#") { continue }
    let f = line.split(separator: ";", omittingEmptySubsequences: false)
    guard f.count >= 5 else { continue }
    let c = (1...5).map { scalars(f[$0 - 1]) }
    if part == "@Part1" { part1.insert(c[0][0]) }
    cases += 1
    let nfc = Normalization.nfc, nfd = Normalization.nfd
    // UAX #15's conditions, for NFC and NFD (the K forms aren't ours).
    #expect(c[1] == nfc(c[0]) && c[1] == nfc(c[1]) && c[1] == nfc(c[2]), "NFC, line \(line)")
    #expect(c[3] == nfc(c[3]) && c[3] == nfc(c[4]), "NFC of the K forms, line \(line)")
    #expect(c[2] == nfd(c[0]) && c[2] == nfd(c[1]) && c[2] == nfd(c[2]), "NFD, line \(line)")
    #expect(c[4] == nfd(c[3]) && c[4] == nfd(c[4]), "NFD of the K forms, line \(line)")
  }
  #expect(cases > 19_000)
  // Every code point Part 1 doesn't list is unchanged by both.
  var unchanged = 0
  for cp in UInt32(0)...0x10FFFF where !(0xD800...0xDFFF).contains(cp) && !part1.contains(cp) {
    if Normalization.nfc([cp]) != [cp] || Normalization.nfd([cp]) != [cp] {
      Issue.record("U+\(String(cp, radix: 16)) changed, but NormalizationTest's Part 1 doesn't list it")
    }
    unchanged += 1
  }
  #expect(unchanged > 1_000_000)
}

@Test func theCommittedTablesAreCurrent() {
  let ucd = UCD(unicodeData: ucdFile("UnicodeData.txt"), compositionExclusions: ucdFile("CompositionExclusions.txt"),
                caseFolding: ucdFile("CaseFolding.txt"), specialCasing: ucdFile("SpecialCasing.txt"))
  #expect(ucd.version == "18.0.0")
  let committed = (try? String(contentsOfFile: "\(dataDir)/../../text/unicode/lib/generated/Tables.swift", encoding: .utf8))
  #expect(committed == ucd.swift(), "regenerate: .build/debug/ucdgen data/unicode text/unicode/lib/generated/Tables.swift")
}

@Test func caseFoldingFoldsFully() {
  func fold(_ s: String) -> String {
    String(decoding: UTF8Text.encode(CaseFolding.fold(UTF8Text.decode(Array(s.utf8))!)), as: UTF8.self)
  }
  #expect(fold("Straße") == "strasse")
  #expect(fold("ẞ") == "ss")
  #expect(fold("ΣΑΣ") == "σασ" && fold("ς") == "σ")
  #expect(fold("İ") == "i\u{307}")  // status F, not T: no Turkic special case
  #expect(fold("ﬁ") == "fi")
  // Every folding is stable: folding twice changes nothing.
  for cp in UInt32(0)...0x10FFFF where !(0xD800...0xDFFF).contains(cp) {
    let once = CaseFolding.fold([cp])
    if CaseFolding.fold(once) != once { Issue.record("folding U+\(String(cp, radix: 16)) isn't stable") }
  }
  // Caseless keys: canonically equivalent and case-different strings match.
  #expect(Text.caselessKey(Array("CAFE\u{301}".utf8)) == Text.caselessKey(Array("café".utf8)))
  #expect(Text.caselessKey(Array("Ǆ".utf8)) == Text.caselessKey(Array("ǆ".utf8)))
}

@Test func utf8IsStrict() {
  #expect(UTF8Text.decode([0x61, 0xC3, 0xA9]) == [0x61, 0xE9])
  #expect(UTF8Text.decode([0xF0, 0x9F, 0x98, 0x80]) == [0x1F600])
  #expect(UTF8Text.decode([0xC0, 0xAF]) == nil)  // overlong
  #expect(UTF8Text.decode([0xE0, 0x80, 0xAF]) == nil)  // overlong
  #expect(UTF8Text.decode([0xED, 0xA0, 0x80]) == nil)  // a surrogate
  #expect(UTF8Text.decode([0xF4, 0x90, 0x80, 0x80]) == nil)  // past U+10FFFF
  #expect(UTF8Text.decode([0xC3]) == nil)  // cut short
  #expect(UTF8Text.decode([0x80]) == nil)  // a lone continuation
  for cp in [UInt32(0), 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF] {
    #expect(UTF8Text.decode(UTF8Text.encode([cp])) == [cp])
  }
  #expect(Text.normalized(Array("e\u{301}".utf8)) == Array("é".utf8))
  #expect(Text.normalized([0xFF]) == nil)
}
