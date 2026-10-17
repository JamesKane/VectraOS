// SPDX-License-Identifier: BSD-3-Clause

// ucdgen's segmentation tables (M6h): every property UAX #29 (grapheme
// clusters, words) and UAX #14 (line breaking) consult, packed into one
// 32-bit value a range of code points, with the properties' value lists as
// Swift enumerations, so the library's names come from the data:
//
//   bits 0-3   Grapheme_Cluster_Break       bits 15-16 Indic_Conjunct_Break
//   bits 4-8   Word_Break                   bit 17     Extended_Pictographic
//   bits 9-14  Line_Break                   bit 18     East_Asian_Width F, W or H
//   bits 19-20 general category: Pi 1, Pf 2, Mn or Mc 3   bit 21  unassigned (Cn)
//   bits 22-26 General_Category, all of it (GeneralCategory's order), and
//   bit 27     Default_Ignorable_Code_Point: the shaper's (M6h)

public struct SegmentationData {
  /// General_Category's values, in the UCD's order (PropertyValueAliases).
  public static let generalCategories = [
    "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
    "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co", "Cn",
  ]

  public var graphemeNames: [String]
  public var wordNames: [String]
  public var lineNames: [String]
  /// The packed value of each code point (0x110000 of them).
  public var packed: [UInt32]

  static func ranges(_ text: String) -> [(first: UInt32, last: UInt32, value: String)] {
    var out: [(UInt32, UInt32, String)] = []
    for line in text.split(separator: "\n") {
      var body = line.prefix { $0 != "#" }
      // @missing lines give the defaults: "# @missing: 0000..10FFFF; XX".
      if line.hasPrefix("# @missing:") { body = line.dropFirst("# @missing:".count) }
      let f = body.split(separator: ";").map { $0.trimmingCharacters() }
      guard f.count >= 2 else { continue }
      let bounds = f[0].split(separator: ".").filter { !$0.isEmpty }
      guard let first = UInt32(bounds[0], radix: 16) else { continue }
      let last = bounds.count > 1 ? UInt32(bounds[1], radix: 16) ?? first : first
      out.append((first, last, f[1]))
    }
    return out
  }

  /// `text`'s ranges applied to a table: @missing defaults first (in file
  /// order, later ones narrower), then the assignments.
  static func apply(_ text: String, into table: inout [String], only: Set<String>? = nil) {
    let lines = text.split(separator: "\n")
    let missing = lines.filter { $0.hasPrefix("# @missing:") }.joined(separator: "\n")
    let assigned = lines.filter { !$0.hasPrefix("#") }.joined(separator: "\n")
    for pass in [missing, assigned] {
      for r in ranges(pass) where only == nil || only!.contains(r.value) {
        for cp in r.first...r.last { table[Int(cp)] = r.value }
      }
    }
  }

  public init(unicodeData: String, graphemeBreak: String, wordBreak: String, lineBreak: String,
              derivedCore: String, eastAsianWidth: String, emoji: String)
  {
    let count = 0x110000
    var gcb = [String](repeating: "Other", count: count)
    var wb = [String](repeating: "Other", count: count)
    var lb = [String](repeating: "XX", count: count)
    var incb = [String](repeating: "None", count: count)
    var extPict = [Bool](repeating: false, count: count)
    var eaw = [String](repeating: "N", count: count)
    var gc = [String](repeating: "Cn", count: count)
    Self.apply(graphemeBreak, into: &gcb)
    Self.apply(wordBreak, into: &wb)
    Self.apply(lineBreak, into: &lb)
    Self.apply(eastAsianWidth, into: &eaw)
    // InCB lines read "0915..0939 ; InCB; Consonant".
    for line in derivedCore.split(separator: "\n") where !line.hasPrefix("#") {
      let f = line.prefix { $0 != "#" }.split(separator: ";").map { $0.trimmingCharacters() }
      guard f.count >= 3, f[1] == "InCB" else { continue }
      let bounds = f[0].split(separator: ".").filter { !$0.isEmpty }
      guard let first = UInt32(bounds[0], radix: 16) else { continue }
      let last = bounds.count > 1 ? UInt32(bounds[1], radix: 16) ?? first : first
      for cp in first...last { incb[Int(cp)] = f[2] }
    }
    var ignorable = [Bool](repeating: false, count: count)
    for r in Self.ranges(derivedCore) where r.value == "Default_Ignorable_Code_Point" {
      for cp in r.first...r.last { ignorable[Int(cp)] = true }
    }
    for r in Self.ranges(emoji) where r.value == "Extended_Pictographic" {
      for cp in r.first...r.last { extPict[Int(cp)] = true }
    }
    // General categories, with UnicodeData's First/Last ranges.
    var rangeStart: (UInt32, String)?
    for line in unicodeData.split(separator: "\n") {
      let f = line.split(separator: ";", omittingEmptySubsequences: false)
      guard f.count >= 3, let cp = UInt32(f[0], radix: 16) else { continue }
      if f[1].hasSuffix(", First>") {
        rangeStart = (cp, String(f[2]))
      } else if f[1].hasSuffix(", Last>"), let (start, category) = rangeStart {
        for c in start...cp { gc[Int(c)] = category }
        rangeStart = nil
      } else {
        gc[Int(cp)] = String(f[2])
      }
    }
    func names(_ values: [String], first: String) -> [String] {
      [first] + Set(values).subtracting([first]).sorted()
    }
    graphemeNames = names(gcb, first: "Other")
    wordNames = names(wb, first: "Other")
    lineNames = names(lb, first: "XX")
    let gi = Dictionary(uniqueKeysWithValues: graphemeNames.enumerated().map { ($1, UInt32($0)) })
    let wi = Dictionary(uniqueKeysWithValues: wordNames.enumerated().map { ($1, UInt32($0)) })
    let li = Dictionary(uniqueKeysWithValues: lineNames.enumerated().map { ($1, UInt32($0)) })
    precondition(graphemeNames.count <= 16 && wordNames.count <= 32 && lineNames.count <= 64)
    let incbIndex: [String: UInt32] = ["None": 0, "Linker": 1, "Consonant": 2, "Extend": 3]
    packed = (0..<count).map { i in
      var v = gi[gcb[i]]! | wi[wb[i]]! << 4 | li[lb[i]]! << 9 | incbIndex[incb[i]]! << 15
      if extPict[i] { v |= 1 << 17 }
      if eaw[i] == "F" || eaw[i] == "W" || eaw[i] == "H" { v |= 1 << 18 }
      switch gc[i] {
      case "Pi": v |= 1 << 19
      case "Pf": v |= 2 << 19
      case "Mn", "Mc": v |= 3 << 19
      case "Cn": v |= 1 << 21
      default: break
      }
      v |= UInt32(SegmentationData.generalCategories.firstIndex(of: gc[i])!) << 22
      if ignorable[i] { v |= 1 << 27 }
      return v
    }
  }

  /// The generated Swift: the enumerations and the packed ranges.
  public func swift(version: String) -> String {
    var s = """
      // SPDX-License-Identifier: BSD-3-Clause
      // Generated by ucdgen from data/unicode (Unicode \(version)); don't edit.

      """
    func enumeration(_ name: String, _ doc: String, _ cases: [String]) -> String {
      var e = "/// \(doc)\npublic enum \(name): UInt8, Sendable {\n"
      for (i, c) in cases.enumerated() { e += "  case \(c) = \(i)\n" }
      return e + "}\n\n"
    }
    s += enumeration("GraphemeBreak", "Grapheme_Cluster_Break (UAX #29).", graphemeNames)
    s += enumeration("WordBreak", "Word_Break (UAX #29).", wordNames)
    s += enumeration("LineBreakClass", "Line_Break (UAX #14), before LB1's resolution.", lineNames)
    s += enumeration("GeneralCategory", "General_Category.", Self.generalCategories)
    var starts: [UInt32] = [], values: [UInt32] = []
    for (cp, v) in packed.enumerated() where values.last != v {
      starts.append(UInt32(cp))
      values.append(v)
    }
    s += "enum SegmentationTables {\n"
    s += UCD.table("starts", "UInt32", starts, "Where each run of one packed value starts, sorted (the first at 0).")
    s += UCD.table("values", "UInt32", values, "Each run's packed properties (Segmentation.swift in ucdgen).")
    return s + "}\n"
  }
}
