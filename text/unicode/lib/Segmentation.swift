// SPDX-License-Identifier: BSD-3-Clause

// Text segmentation (M6h): grapheme clusters and words (UAX #29) and line
// breaking (UAX #14), as Unicode 18 states them, over the properties ucdgen
// packs from the UCD (generated/SegmentationTables.swift). Each boundary is
// decided by the rules in their order; the line breaking rules are those
// the conformance file is generated from (LineBreakTest.html's, numbered
// as there), with LB1's default resolution: AI, SG and XX are AL; SA is CM
// if a mark, else AL (no dictionary breaking for Thai and its neighbours:
// a stub, text/README.md); CJ is NS.

/// A code point's segmentation properties.
public struct SegmentationProperties: Sendable {
  let bits: UInt32

  public init(_ scalar: UInt32) {
    let starts = SegmentationTables.starts
    var lo = 0, hi = starts.count
    while hi - lo > 1 {
      let mid = (lo + hi) / 2
      if starts[mid] <= scalar { lo = mid } else { hi = mid }
    }
    bits = SegmentationTables.values[lo]
  }

  public var grapheme: GraphemeBreak { GraphemeBreak(rawValue: UInt8(bits & 0xF))! }
  public var word: WordBreak { WordBreak(rawValue: UInt8(bits >> 4 & 0x1F))! }
  public var lineClass: LineBreakClass { LineBreakClass(rawValue: UInt8(bits >> 9 & 0x3F))! }
  /// Indic_Conjunct_Break: 0 None, 1 Linker, 2 Consonant, 3 Extend.
  var conjunct: UInt32 { bits >> 15 & 3 }
  public var extendedPictographic: Bool { bits & 1 << 17 != 0 }
  /// East_Asian_Width F, W or H.
  public var eastAsian: Bool { bits & 1 << 18 != 0 }
  /// General_Category: initial or final quotation, or a combining mark.
  var initialQuote: Bool { bits >> 19 & 3 == 1 }
  var finalQuote: Bool { bits >> 19 & 3 == 2 }
  var mark: Bool { bits >> 19 & 3 == 3 }
  var unassigned: Bool { bits & 1 << 21 != 0 }
  /// General_Category (the shaper's).
  public var generalCategory: GeneralCategory { GeneralCategory(rawValue: UInt8(bits >> 22 & 0x1F))! }
  /// A mark: Mn, Mc or Me.
  public var isMark: Bool {
    let gc = bits >> 22 & 0x1F
    return gc >= 5 && gc <= 7
  }
  /// Default_Ignorable_Code_Point.
  public var defaultIgnorable: Bool { bits & 1 << 27 != 0 }
}

public enum Segmentation {
  // MARK: Grapheme clusters (UAX #29 §3)

  /// The grapheme cluster boundaries of `s`: 0, each boundary, and
  /// s.count (none for an empty string).
  public static func graphemeBoundaries(_ s: [UInt32]) -> [Int] {
    guard !s.isEmpty else { return [] }
    let p = s.map { SegmentationProperties($0) }
    var out = [0]
    for i in 1..<s.count where graphemeBreak(p, i) { out.append(i) }
    out.append(s.count)
    return out
  }

  /// Whether there's a boundary between p[i - 1] and p[i].
  static func graphemeBreak(_ p: [SegmentationProperties], _ i: Int) -> Bool {
    let a = p[i - 1].grapheme, b = p[i].grapheme
    if a == .CR && b == .LF { return false }  // GB3
    if a == .Control || a == .CR || a == .LF { return true }  // GB4
    if b == .Control || b == .CR || b == .LF { return true }  // GB5
    if a == .L && (b == .L || b == .V || b == .LV || b == .LVT) { return false }  // GB6
    if (a == .LV || a == .V) && (b == .V || b == .T) { return false }  // GB7
    if (a == .LVT || a == .T) && b == .T { return false }  // GB8
    if b == .Extend || b == .ZWJ { return false }  // GB9
    if b == .SpacingMark { return false }  // GB9a
    if a == .Prepend { return false }  // GB9b
    // GB9c, as Unicode 18 has it: Linker Extend* × Consonant (the linker
    // needn't follow a consonant).
    if p[i].conjunct == 2 {
      var j = i - 1
      while j >= 0 && p[j].conjunct == 3 { j -= 1 }
      if j >= 0 && p[j].conjunct == 1 { return false }
    }
    // GB11: ExtPict Extend* ZWJ × ExtPict.
    if a == .ZWJ && p[i].extendedPictographic {
      var j = i - 2
      while j >= 0 && p[j].grapheme == .Extend { j -= 1 }
      if j >= 0 && p[j].extendedPictographic { return false }
    }
    // GB12, GB13: regional indicators in pairs.
    if a == .Regional_Indicator && b == .Regional_Indicator {
      var n = 0, j = i - 1
      while j >= 0 && p[j].grapheme == .Regional_Indicator {
        n += 1
        j -= 1
      }
      return n % 2 == 0
    }
    return true  // GB999
  }

  // MARK: Words (UAX #29 §4)

  /// The word boundaries of `s`: 0, each boundary, and s.count.
  public static func wordBoundaries(_ s: [UInt32]) -> [Int] {
    guard !s.isEmpty else { return [] }
    let p = s.map { SegmentationProperties($0) }
    var out = [0]
    for i in 1..<s.count where wordBreak(p, i) { out.append(i) }
    out.append(s.count)
    return out
  }

  static func ignorable(_ w: WordBreak) -> Bool { w == .Extend || w == .Format || w == .ZWJ }
  static func letter(_ w: WordBreak) -> Bool { w == .ALetter || w == .Hebrew_Letter }
  static func midLetterQ(_ w: WordBreak) -> Bool { w == .MidLetter || w == .MidNumLet || w == .Single_Quote }
  static func midNumQ(_ w: WordBreak) -> Bool { w == .MidNum || w == .MidNumLet || w == .Single_Quote }

  static func wordBreak(_ p: [SegmentationProperties], _ i: Int) -> Bool {
    let ra = p[i - 1].word, rb = p[i].word
    if ra == .CR && rb == .LF { return false }  // WB3
    if ra == .Newline || ra == .CR || ra == .LF { return true }  // WB3a
    if rb == .Newline || rb == .CR || rb == .LF { return true }  // WB3b
    if ra == .ZWJ && p[i].extendedPictographic { return false }  // WB3c
    if ra == .WSegSpace && rb == .WSegSpace { return false }  // WB3d
    if ignorable(rb) { return false }  // WB4: X (Extend | Format | ZWJ)* → X
    // From here, characters skipping the ignorable ones after them.
    func before(_ j: Int) -> Int? {
      var k = j
      while k >= 0 && ignorable(p[k].word) { k -= 1 }
      return k >= 0 ? k : nil
    }
    func after(_ j: Int) -> Int? {
      var k = j + 1
      while k < p.count && ignorable(p[k].word) { k += 1 }
      return k < p.count ? k : nil
    }
    guard let ai = before(i - 1) else { return true }
    let a = p[ai].word, b = rb
    let a2 = before(ai - 1).map { p[$0].word }
    let b2 = after(i).map { p[$0].word }
    if letter(a) && letter(b) { return false }  // WB5
    if letter(a) && midLetterQ(b) && b2.map(letter) == true { return false }  // WB6
    if let a2, letter(a2) && midLetterQ(a) && letter(b) { return false }  // WB7
    if a == .Hebrew_Letter && b == .Single_Quote { return false }  // WB7a
    if a == .Hebrew_Letter && b == .Double_Quote && b2 == .Hebrew_Letter { return false }  // WB7b
    if a2 == .Hebrew_Letter && a == .Double_Quote && b == .Hebrew_Letter { return false }  // WB7c
    if a == .Numeric && b == .Numeric { return false }  // WB8
    if letter(a) && b == .Numeric { return false }  // WB9
    if a == .Numeric && letter(b) { return false }  // WB10
    if a2 == .Numeric && midNumQ(a) && b == .Numeric { return false }  // WB11
    if a == .Numeric && midNumQ(b) && b2 == .Numeric { return false }  // WB12
    if a == .Katakana && b == .Katakana { return false }  // WB13
    if (letter(a) || a == .Numeric || a == .Katakana || a == .ExtendNumLet) && b == .ExtendNumLet { return false }  // WB13a
    if a == .ExtendNumLet && (letter(b) || b == .Numeric || b == .Katakana) { return false }  // WB13b
    // WB15, WB16: regional indicators in pairs (ignorables skipped).
    if a == .Regional_Indicator && b == .Regional_Indicator {
      var n = 0
      var j: Int? = ai
      while let k = j, p[k].word == .Regional_Indicator {
        n += 1
        j = before(k - 1)
      }
      return n % 2 == 0
    }
    return true  // WB999
  }

  // MARK: Line breaking (UAX #14)

  public enum LineBreak: Sendable, Equatable {
    /// A line must end here (after BK, CR, LF, NL; and at the text's end).
    case mandatory
    /// A line may end here.
    case allowed
  }

  /// Where lines may or must break in `s`: each position from 1 to s.count
  /// that is a break (the end is always mandatory).
  public static func lineBreaks(_ s: [UInt32]) -> [(index: Int, kind: LineBreak)] {
    guard !s.isEmpty else { return [] }
    let lines = LineContext(s)
    var out: [(index: Int, kind: LineBreak)] = []
    for i in 1..<s.count {
      if let kind = lines.breakBefore(i) { out.append((i, kind)) }
    }
    out.append((s.count, .mandatory))
    return out
  }
}

/// Line breaking's view of a string: each character's class after LB1,
/// and where LB9 and LB10 put combining marks.
struct LineContext {
  typealias C = LineBreakClass
  let s: [UInt32]
  let p: [SegmentationProperties]
  /// After LB1.
  let raw: [C]
  /// After LB9 and LB10: an attached mark takes its base's class (and the
  /// base's other properties, through `base`); a lone one is AL.
  let cls: [C]
  let base: [Int]
  let attached: [Bool]

  init(_ s: [UInt32]) {
    self.s = s
    p = s.map { SegmentationProperties($0) }
    var raw: [C] = []
    for q in p {
      switch q.lineClass {
      case .AI, .SG, .XX: raw.append(.AL)
      case .SA: raw.append(q.mark ? .CM : .AL)
      case .CJ: raw.append(.NS)
      default: raw.append(q.lineClass)
      }
    }
    self.raw = raw
    var cls = raw, base = Array(0..<s.count), attached = [Bool](repeating: false, count: s.count)
    for i in 0..<s.count where raw[i] == .CM || raw[i] == .ZWJ {
      let b = i > 0 ? base[i - 1] : -1
      let x = b >= 0 ? raw[b] : .BK
      if i > 0 && x != .BK && x != .CR && x != .LF && x != .NL && x != .SP && x != .ZW {
        cls[i] = cls[b]
        base[i] = b
        attached[i] = true  // LB9
      } else {
        cls[i] = .AL  // LB10
      }
    }
    self.cls = cls
    self.base = base
    self.attached = attached
  }

  /// The unit (a character with its attached marks) before the one whose
  /// first character is at `j`, as the index of its base; nil at the start.
  func unit(before j: Int) -> Int? {
    var k = j - 1
    while k >= 0 && attached[k] { k -= 1 }
    return k >= 0 ? k : nil
  }

  /// The unit after the one at `j`, nil at the end.
  func unit(after j: Int) -> Int? {
    var k = j + 1
    while k < s.count && attached[k] { k += 1 }
    return k < s.count ? k : nil
  }

  func eastAsian(_ j: Int) -> Bool { p[base[j]].eastAsian }
  func akLike(_ j: Int) -> Bool { cls[j] == .AK || cls[j] == .AS || s[base[j]] == 0x25CC }

  /// The break before s[i] (between i - 1 and i), or nil where there's none.
  func breakBefore(_ i: Int) -> Segmentation.LineBreak? {
    let ra = raw[i - 1], rb = raw[i]
    if ra == .BK { return .mandatory }  // 4.0
    if ra == .CR && rb == .LF { return nil }  // 5.01
    if ra == .CR || ra == .LF || ra == .NL { return .mandatory }  // 5.02-5.04
    if rb == .BK || rb == .CR || rb == .LF || rb == .NL { return nil }  // 6.0
    if rb == .SP || rb == .ZW { return nil }  // 7.01, 7.02
    // 8.0: ZW SP* ÷
    var k = i - 1
    while k > 0 && raw[k] == .SP { k -= 1 }
    if raw[k] == .ZW { return .allowed }
    if ra == .ZWJ { return nil }  // 8.1
    if attached[i] { return nil }  // 9.0

    // From here, units: A is the one ending at i - 1, B the one at i.
    let ai = base[i - 1]
    let a = cls[i - 1], b = cls[i]
    let before = unit(before: ai)  // the unit before A
    let next = unit(after: i)  // the unit after B
    func previousSkipping(_ classes: [C], from j: Int?) -> Int? {
      var k = j
      while let x = k, classes.contains(cls[x]) { k = unit(before: x) }
      return k
    }

    if b == .WJ || a == .WJ { return nil }  // 11.01, 11.02
    if a == .GL { return nil }  // 12.0
    if b == .GL && a != .SP && a != .HY && a != .HH { return nil }  // 12.1
    if b == .EX || b == .CL || b == .CP || b == .SY { return nil }  // 13.01-13.04
    // 14.0: OP SP* ×
    if let o = previousSkipping([.SP], from: ai), cls[o] == .OP { return nil }
    // 15.11: (BK | CR | LF | NL | OP | QU | GL | SP | ZW | sot) QU_Pi SP* ×
    if let q = previousSkipping([.SP], from: ai), cls[q] == .QU, p[base[q]].initialQuote {
      let x = unit(before: q).map { cls[$0] }
      if x == nil || [C.BK, .CR, .LF, .NL, .OP, .QU, .GL, .SP, .ZW].contains(x!) { return nil }
    }
    // 15.21: × QU_Pf ( SP | GL | WJ | CL | QU | CP | EX | IS | SY | BK | CR | LF | NL | ZW | eot )
    if b == .QU && p[i].finalQuote {
      let y = next.map { cls[$0] }
      if y == nil || [C.SP, .GL, .WJ, .CL, .QU, .CP, .EX, .IS, .SY, .BK, .CR, .LF, .NL, .ZW].contains(y!) { return nil }
    }
    if a == .SP && b == .IS && next.map({ cls[$0] }) == .NU { return .allowed }  // 15.3
    if b == .IS { return nil }  // 15.4
    // 16.0: (CL | CP) SP* × NS
    if b == .NS, let c = previousSkipping([.SP], from: ai), cls[c] == .CL || cls[c] == .CP { return nil }
    // 17.0: B2 SP* × B2
    if b == .B2, let c = previousSkipping([.SP], from: ai), cls[c] == .B2 { return nil }
    if a == .SP { return .allowed }  // 18.0
    if b == .QU && !p[i].initialQuote { return nil }  // 19.01
    if a == .QU && !p[ai].finalQuote { return nil }  // 19.02
    if b == .QU && !eastAsian(ai) { return nil }  // 19.1
    if b == .QU && (next == nil || !eastAsian(next!)) { return nil }  // 19.11
    if a == .QU && !eastAsian(i) { return nil }  // 19.12
    if a == .QU && (before == nil || !eastAsian(before!)) { return nil }  // 19.13
    if b == .CB || a == .CB { return .allowed }  // 20.01, 20.02
    // 20.1: (BK | CR | LF | NL | SP | ZW | CB | GL | sot) (HY | HH) × (AL | HL)
    if (a == .HY || a == .HH) && (b == .AL || b == .HL) {
      let x = before.map { cls[$0] }
      if x == nil || [C.BK, .CR, .LF, .NL, .SP, .ZW, .CB, .GL].contains(x!) { return nil }
    }
    if b == .BA || b == .HH || b == .HY || b == .NS { return nil }  // 21.01-21.04
    if a == .BB { return nil }  // 21.05
    if (a == .HY || a == .HH) && b != .HL && before.map({ cls[$0] }) == .HL { return nil }  // 21.1
    if a == .SY && b == .HL { return nil }  // 21.2
    if b == .IN { return nil }  // 22.0
    if (a == .AL || a == .HL) && b == .NU { return nil }  // 23.02
    if a == .NU && (b == .AL || b == .HL) { return nil }  // 23.03
    if a == .PR && (b == .ID || b == .EB || b == .EM) { return nil }  // 23.12
    if (a == .ID || a == .EB || a == .EM) && b == .PO { return nil }  // 23.13
    if (a == .PR || a == .PO) && (b == .AL || b == .HL) { return nil }  // 24.02
    if (a == .AL || a == .HL) && (b == .PR || b == .PO) { return nil }  // 24.03
    // 25.01-25.06: NU (SY | IS)* (CL | CP)? × (PO | PR)
    if b == .PO || b == .PR {
      let from = (a == .CL || a == .CP) ? before : ai
      if let n = previousSkipping([.SY, .IS], from: from), cls[n] == .NU { return nil }
    }
    let y = next.map { cls[$0] }
    let y2 = next.flatMap { unit(after: $0) }.map { cls[$0] }
    if (a == .PO || a == .PR) && b == .OP && (y == .NU || (y == .IS && y2 == .NU)) { return nil }  // 25.07, 25.08, 25.1, 25.11
    if (a == .PO || a == .PR || a == .HY || a == .IS) && b == .NU { return nil }  // 25.09, 25.12-25.14
    // 25.15: NU (SY | IS)* × NU
    if b == .NU, let n = previousSkipping([.SY, .IS], from: ai), cls[n] == .NU { return nil }
    if a == .JL && (b == .JL || b == .JV || b == .H2 || b == .H3) { return nil }  // 26.01
    if (a == .JV || a == .H2) && (b == .JV || b == .JT) { return nil }  // 26.02
    if (a == .JT || a == .H3) && b == .JT { return nil }  // 26.03
    let hangul: [C] = [.JL, .JV, .JT, .H2, .H3]
    if hangul.contains(a) && b == .PO { return nil }  // 27.01
    if a == .PR && hangul.contains(b) { return nil }  // 27.02
    if (a == .AL || a == .HL) && (b == .AL || b == .HL) { return nil }  // 28.0
    if a == .AP && akLike(i) { return nil }  // 28.11
    if akLike(ai) && (b == .VF || b == .VI) { return nil }  // 28.12
    if a == .VI && before.map(akLike) == true && (b == .AK || s[i] == 0x25CC) { return nil }  // 28.13
    if akLike(ai) && akLike(i) && y == .VF { return nil }  // 28.14
    if a == .IS && (b == .AL || b == .HL) { return nil }  // 29.0
    if (a == .AL || a == .HL || a == .NU) && b == .OP && !eastAsian(i) { return nil }  // 30.01
    if a == .CP && !eastAsian(ai) && (b == .AL || b == .HL || b == .NU) { return nil }  // 30.02
    // 30.11-30.13: regional indicators in pairs.
    if a == .RI && b == .RI {
      var n = 0
      var j: Int? = ai
      while let k = j, cls[k] == .RI {
        n += 1
        j = unit(before: k)
      }
      return n % 2 == 1 ? nil : .allowed
    }
    if a == .EB && b == .EM { return nil }  // 30.21
    if p[base[ai]].extendedPictographic && p[base[ai]].unassigned && b == .EM { return nil }  // 30.22
    return .allowed  // 31
  }
}
