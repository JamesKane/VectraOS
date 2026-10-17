// SPDX-License-Identifier: BSD-3-Clause

// The properties the shaper reads (M6h) against the UCD: every code point's
// General_Category (UnicodeData.txt, its First/Last ranges included) and
// Default_Ignorable_Code_Point (DerivedCoreProperties.txt), and one level
// of canonical decomposition against NFD.

import FoundationEssentials
import TDUnicode
import Testing
import UCDGen

@Test func everyGeneralCategoryIsTheUCDs() {
  var expected = [String](repeating: "Cn", count: 0x110000)
  var rangeStart: (Int, String)?
  for line in ucdFile("UnicodeData.txt").split(separator: "\n") {
    let f = line.split(separator: ";", omittingEmptySubsequences: false)
    guard f.count >= 3, let cp = Int(f[0], radix: 16) else { continue }
    if f[1].hasSuffix(", First>") {
      rangeStart = (cp, String(f[2]))
    } else if f[1].hasSuffix(", Last>"), let (start, category) = rangeStart {
      for c in start...cp { expected[c] = category }
    } else {
      expected[cp] = String(f[2])
    }
  }
  var wrong = 0
  for cp in 0..<0x110000 {
    let gc = SegmentationData.generalCategories[Int(SegmentationProperties(UInt32(cp)).generalCategory.rawValue)]
    if gc != expected[cp] {
      wrong += 1
      if wrong <= 5 { Issue.record("U+\(String(cp, radix: 16)): \(gc), the UCD says \(expected[cp])") }
    }
  }
  #expect(wrong == 0)
  #expect(SegmentationProperties(0x301).isMark && SegmentationProperties(0x20DD).isMark)  // Mn, Me
  #expect(!SegmentationProperties(0x41).isMark)
}

@Test func defaultIgnorablesAreTheUCDs() {
  var expected = [Bool](repeating: false, count: 0x110000)
  for line in ucdFile("DerivedCoreProperties.txt").split(separator: "\n") where !line.hasPrefix("#") {
    let f = line.prefix { $0 != "#" }.split(separator: ";").map { String($0.filter { $0 != " " && $0 != "\t" }) }
    guard f.count >= 2, f[1] == "Default_Ignorable_Code_Point" else { continue }
    let bounds = f[0].split(separator: ".").filter { !$0.isEmpty }
    let first = Int(bounds[0], radix: 16)!, last = bounds.count > 1 ? Int(bounds[1], radix: 16)! : first
    for cp in first...last { expected[cp] = true }
  }
  var wrong = 0
  for cp in 0..<0x110000 where SegmentationProperties(UInt32(cp)).defaultIgnorable != expected[cp] { wrong += 1 }
  #expect(wrong == 0)
  // English's: the soft hyphen, ZWJ and ZWNJ, the word joiner.
  #expect([0xAD, 0x200C, 0x200D, 0x2060].allSatisfy { SegmentationProperties($0).defaultIgnorable })
}

@Test func decomposingOnceRepeatedlyIsNFD() {
  func full(_ c: UInt32) -> [UInt32] {
    guard let (a, b) = Normalization.decomposeOnce(c) else { return [c] }
    return full(a) + (b.map { full($0) } ?? [])
  }
  var checked = 0
  for cp in UInt32(0)..<0x110000 where !(0xD800...0xDFFF).contains(cp) {
    guard Normalization.decomposeOnce(cp) != nil else { continue }
    // NFD also reorders marks: compare with NFD of the recursive result.
    #expect(Normalization.nfd(full(cp)) == Normalization.nfd([cp]), "U+\(String(cp, radix: 16))")
    checked += 1
  }
  #expect(checked > 2000 + 11172)  // the UCD's mappings and Hangul's syllables
  #expect(Normalization.decomposeOnce(0x1D8)! == (0xFC, 0x301))  // ǘ: ü, then the acute
  #expect(Normalization.decomposeOnce(0x212B)! == (0xC5, nil))  // Ångström sign: a singleton
  #expect(Normalization.compose(0x65, 0x301) == 0xE9)
}

/// Uppercasing against Swift's own (`String.uppercased`, Unicode's default
/// full mapping with SpecialCasing's unconditional entries): every code
/// point, one at a time, but those whose uppercase Unicode 18 added (Swift
/// 6.4's data is older: U+0277's uppercase is U+A7DD, new in 18).
@Test func uppercasingIsUnicodes() {
  var wrong = 0, newer = 0
  for cp in UInt32(0)..<0x110000 {
    guard let scalar = Unicode.Scalar(cp) else { continue }
    let theirs = String(Character(scalar)).uppercased().unicodeScalars.map(\.value)
    let ours = CaseMapping.uppercase([cp])
    if ours != theirs && (scalar.properties.age == nil || ours.contains(where: { Unicode.Scalar($0)?.properties.age == nil })) {
      newer += 1
      continue
    }
    if ours != theirs {
      wrong += 1
      if wrong <= 5 { Issue.record("U+\(String(cp, radix: 16)): \(ours.map { String($0, radix: 16) }) not \(theirs.map { String($0, radix: 16) })") }
    }
  }
  #expect(wrong == 0)
  #expect(newer < 40, "\(newer) new in Unicode 18")
  #expect(CaseMapping.uppercase("Größe Straße naïve".unicodeScalars.map(\.value)) == "GRÖSSE STRASSE NAÏVE".unicodeScalars.map(\.value))
}
