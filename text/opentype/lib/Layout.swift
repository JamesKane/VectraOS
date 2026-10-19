// SPDX-License-Identifier: BSD-3-Clause

// OpenType Layout's common tables (OpenType 1.9, "OpenType Layout common
// table formats"), read in place: coverage and class definitions, a GSUB
// or GPOS table's scripts, language systems, features and lookups (an
// extension lookup's subtables resolved to what they extend), and GDEF's
// glyph classes, mark attachment classes and mark glyph sets. The legacy
// `kern` table's format 0 is here too. FeatureVariations (variable fonts)
// are ignored: a stub.

/// A coverage table: which glyphs, and each one's index.
public struct Coverage: Sendable {
  let b: Bytes
  public init(_ b: Bytes) { self.b = b }

  /// The glyph's coverage index, or nil if it isn't covered.
  public func index(_ glyph: Int) -> Int? {
    guard let format = try? b.u16(0), let count = try? Int(b.u16(2)) else { return nil }
    var lo = 0, hi = count
    switch format {
    case 1:
      while lo < hi {
        let mid = (lo + hi) / 2
        guard let g = try? Int(b.u16(4 + 2 * mid)) else { return nil }
        if g == glyph { return mid }
        if g < glyph { lo = mid + 1 } else { hi = mid }
      }
    case 2:
      while lo < hi {
        let mid = (lo + hi) / 2, at = 4 + 6 * mid
        guard let first = try? Int(b.u16(at)), let last = try? Int(b.u16(at + 2)) else { return nil }
        if glyph < first {
          hi = mid
        } else if glyph > last {
          lo = mid + 1
        } else {
          guard let start = try? Int(b.u16(at + 4)) else { return nil }
          return start + glyph - first
        }
      }
    default:
      break
    }
    return nil
  }
}

/// A class definition table: each glyph's class (0 if it has none).
public struct ClassDef: Sendable {
  let b: Bytes
  public init(_ b: Bytes) { self.b = b }

  public func callAsFunction(_ glyph: Int) -> Int {
    guard let format = try? b.u16(0) else { return 0 }
    switch format {
    case 1:
      guard let start = try? Int(b.u16(2)), let count = try? Int(b.u16(4)) else { return 0 }
      let i = glyph - start
      guard i >= 0, i < count, let c = try? Int(b.u16(6 + 2 * i)) else { return 0 }
      return c
    case 2:
      guard let count = try? Int(b.u16(2)) else { return 0 }
      var lo = 0, hi = count
      while lo < hi {
        let mid = (lo + hi) / 2, at = 4 + 6 * mid
        guard let first = try? Int(b.u16(at)), let last = try? Int(b.u16(at + 2)) else { return 0 }
        if glyph < first {
          hi = mid
        } else if glyph > last {
          lo = mid + 1
        } else {
          return (try? Int(b.u16(at + 4))) ?? 0
        }
      }
      return 0
    default:
      return 0
    }
  }
}

/// A lookup: its type (an extension's resolved), flags, mark filtering
/// set, and subtables.
public struct Lookup: Sendable {
  public let type: Int
  public let flag: UInt16
  public let markFilteringSet: Int?
  public let subtables: [Bytes]

  /// LookupFlag's bits.
  public static let rightToLeft: UInt16 = 1, ignoreBaseGlyphs: UInt16 = 2, ignoreLigatures: UInt16 = 4
  public static let ignoreMarks: UInt16 = 8, useMarkFilteringSet: UInt16 = 0x10
}

/// A GSUB or GPOS table.
public struct LayoutTable: Sendable {
  public let bytes: Bytes
  let scripts: Bytes
  let features: Bytes
  let lookups: Bytes
  /// The lookup type that is an extension: 7 in GSUB, 9 in GPOS.
  let extensionType: Int

  public init(_ b: Bytes, extensionType: Int) throws(FontError) {
    bytes = b
    self.extensionType = extensionType
    scripts = try b.from(Int(try b.u16(4)), "a layout table's scripts")
    features = try b.from(Int(try b.u16(6)), "a layout table's features")
    lookups = try b.from(Int(try b.u16(8)), "a layout table's lookups")
  }

  /// The first of `tags` the table has a script for, and that script.
  func script(_ tags: [String]) -> (tag: String, table: Bytes)? {
    guard let count = try? Int(scripts.u16(0)) else { return nil }
    for want in tags {
      for i in 0..<count {
        guard let tag = try? scripts.tag(2 + 6 * i), tag.utf8.elementsEqual(want.utf8),
          let offset = try? Int(scripts.u16(6 + 6 * i)), let table = try? scripts.from(offset, "a script")
        else { continue }
        return (tag, table)
      }
    }
    return nil
  }

  /// The language system for the first of `scriptTags` the table has (then
  /// DFLT, dflt and latn, as HarfBuzz falls back), and the first of
  /// `languageTags` it has there (then a `dflt` one, then the script's
  /// default): the chosen script's tag, the required feature's index, and
  /// the other features' indices. Nil if there's no such script.
  public func languageSystem(scripts scriptTags: [String], languages languageTags: [String])
    -> (script: String, required: Int?, features: [Int])?
  {
    guard let (tag, script) = script(scriptTags + ["DFLT", "dflt", "latn"]) else { return nil }
    var langSys: Bytes?
    if let count = try? Int(script.u16(2)) {
      search: for want in languageTags + ["dflt"] {
        for i in 0..<count {
          if let t = try? script.tag(4 + 6 * i), t.utf8.elementsEqual(want.utf8), let offset = try? Int(script.u16(8 + 6 * i)) {
            langSys = try? script.from(offset, "a language system")
            break search
          }
        }
      }
    }
    if langSys == nil, let offset = try? Int(script.u16(0)), offset != 0 {
      langSys = try? script.from(offset, "a default language system")
    }
    guard let ls = langSys, let required = try? Int(ls.u16(2)), let count = try? Int(ls.u16(4)) else {
      return (tag, nil, [])
    }
    var indices: [Int] = []
    for i in 0..<count {
      if let f = try? Int(ls.u16(6 + 2 * i)) { indices.append(f) }
    }
    return (tag, required == 0xFFFF ? nil : required, indices)
  }

  /// A feature's tag.
  public func featureTag(_ index: Int) -> String? { try? features.tag(2 + 6 * index) }

  /// A feature's lookups' indices.
  public func featureLookups(_ index: Int) -> [Int] {
    guard let offset = try? Int(features.u16(6 + 6 * index)), let f = try? features.from(offset, "a feature"),
      let count = try? Int(f.u16(2))
    else { return [] }
    var out: [Int] = []
    for i in 0..<count {
      if let l = try? Int(f.u16(4 + 2 * i)) { out.append(l) }
    }
    return out
  }

  public var lookupCount: Int { (try? Int(lookups.u16(0))) ?? 0 }

  /// The lookup at `index`, its extension subtables resolved.
  public func lookup(_ index: Int) -> Lookup? {
    guard index < lookupCount, let offset = try? Int(lookups.u16(2 + 2 * index)),
      let l = try? lookups.from(offset, "a lookup"), let type = try? Int(l.u16(0)), let flag = try? l.u16(2),
      let count = try? Int(l.u16(4))
    else { return nil }
    var resolved = type
    var subtables: [Bytes] = []
    for i in 0..<count {
      guard let o = try? Int(l.u16(6 + 2 * i)), var s = try? l.from(o, "a subtable") else { continue }
      if type == extensionType {
        guard let inner = try? Int(s.u16(2)), let o32 = try? Int(s.u32(4)), let t = try? s.from(o32, "an extension")
        else { continue }
        resolved = inner
        s = t
      }
      subtables.append(s)
    }
    var set: Int?
    if flag & Lookup.useMarkFilteringSet != 0 { set = try? Int(l.u16(6 + 2 * count)) }
    return Lookup(type: resolved, flag: flag, markFilteringSet: set, subtables: subtables)
  }
}

/// GDEF: glyph classes, mark attachment classes, mark glyph sets.
public struct GDEF: Sendable {
  let glyphClasses: ClassDef?
  let markAttachClasses: ClassDef?
  let markSets: Bytes?

  /// Glyph classes.
  public static let base = 1, ligature = 2, mark = 3, component = 4

  public init(_ b: Bytes?) {
    func sub(_ at: Int) -> Bytes? {
      guard let b, let o = try? Int(b.u16(at)), o != 0 else { return nil }
      return try? b.from(o, "GDEF")
    }
    glyphClasses = sub(4).map(ClassDef.init)
    markAttachClasses = sub(10).map(ClassDef.init)
    if let b, let minor = try? b.u16(2), minor >= 2 { markSets = sub(12) } else { markSets = nil }
  }

  public var hasGlyphClasses: Bool { glyphClasses != nil }
  public func glyphClass(_ glyph: Int) -> Int { glyphClasses?(glyph) ?? 0 }
  public func markAttachmentClass(_ glyph: Int) -> Int { markAttachClasses?(glyph) ?? 0 }

  /// Whether mark glyph set `set` has the glyph.
  public func inMarkSet(_ set: Int, _ glyph: Int) -> Bool {
    guard let s = markSets, let count = try? Int(s.u16(2)), set < count, let o = try? Int(s.u32(4 + 4 * set)),
      let coverage = try? s.from(o, "a mark glyph set")
    else { return false }
    return Coverage(coverage).index(glyph) != nil
  }
}

/// The legacy `kern` table's horizontal format 0 subtables (OpenType's
/// version 0; Apple's version 1 is a stub).
public struct KernTable: Sendable {
  let subtables: [Bytes]

  public init?(_ b: Bytes?) {
    guard let b, let version = try? b.u16(0), version == 0, let count = try? Int(b.u16(2)) else { return nil }
    var at = 4
    var subtables: [Bytes] = []
    for _ in 0..<count {
      guard let length = try? Int(b.u16(at + 2)), let coverage = try? b.u16(at + 4) else { break }
      // Format 0, horizontal, not cross-stream (shapers ignore the minimum
      // and override bits).
      // Sized by its pair count: big tables overflow the 16-bit length
      // (Open Sans's says 46,642 bytes of 112,178).
      if coverage >> 8 == 0 && coverage & 0x1 != 0 && coverage & 0x4 == 0, let pairs = try? Int(b.u16(at + 6)),
        let s = try? b.slice(at, min(14 + 6 * pairs, b.count - at), "kern")
      {
        subtables.append(s)
      }
      at += length
    }
    guard !subtables.isEmpty else { return nil }
    self.subtables = subtables
  }

  /// The kerning between two glyphs, summed over the subtables.
  public func value(_ left: Int, _ right: Int) -> Int {
    var total = 0
    let key = UInt32(left) << 16 | UInt32(right)
    for s in subtables {
      guard let pairs = try? Int(s.u16(6)) else { continue }
      var lo = 0, hi = pairs
      while lo < hi {
        let mid = (lo + hi) / 2
        guard let k = try? s.u32(14 + 6 * mid) else { break }
        if k == key {
          total += Int((try? s.i16(18 + 6 * mid)) ?? 0)
          break
        }
        if k < key { lo = mid + 1 } else { hi = mid }
      }
    }
    return total
  }
}
