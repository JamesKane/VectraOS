// SPDX-License-Identifier: BSD-3-Clause

// An OpenType font (M6h), as OpenType 1.9 describes it, as far as Latin
// text needs (architecture §13): the table directory, `head`, `hhea`,
// `maxp`, `hmtx`, `cmap` (formats 0, 4, 6 and 12), `name`, `OS/2` and
// `post`, and the outlines (Glyf.swift: `loca` and `glyf`; CFF.swift:
// `CFF `). Collections, vertical metrics, variations and color are stubs
// (text/README.md). Everything is in font units.

public struct Metrics: Equatable, Sendable {
  public var unitsPerEm: Int
  /// `hhea`'s, or OS/2's where the font says to use them: what FreeType
  /// reports, and line spacing uses.
  public var ascender: Int
  public var descender: Int
  public var lineGap: Int
  /// `OS/2`'s, where it has them (0 otherwise).
  public var xHeight: Int
  public var capHeight: Int
  /// `post`'s.
  public var underlinePosition: Int
  public var underlineThickness: Int
  public var italicAngle: Double
  public var isFixedPitch: Bool
  public var weight: Int
}

public struct Font: Sendable {
  public let bytes: Bytes
  /// The tables, as the directory lists them: tag, offset, length.
  let tables: [(tag: String, offset: Int, length: Int)]
  public let glyphCount: Int
  public let metrics: Metrics
  let longMetrics: Int
  let hmtx: Bytes
  let cmap: CharacterMap?
  let outlines: Outlines

  /// The font in `data` (one font: a TrueType or CFF-outlined OpenType file).
  public init(_ data: [UInt8]) throws(FontError) {
    let b = Bytes(data)
    let version = try b.u32(0)
    // 1.0 or 'true' (TrueType), 'OTTO' (CFF); 'ttcf' is a collection.
    guard version == 0x0001_0000 || version == 0x7472_7565 || version == 0x4F54_544F else { throw .notAFont }
    let count = Int(try b.u16(4))
    var tables: [(tag: String, offset: Int, length: Int)] = []
    for i in 0..<count {
      let record = 12 + 16 * i
      let tag = try b.tag(record)
      let offset = Int(try b.u32(record + 8)), length = Int(try b.u32(record + 12))
      guard offset <= b.count, length <= b.count - offset else { throw .malformed("table \(tag) past the file's end") }
      tables.append((tag, offset, length))
    }
    self.bytes = b
    self.tables = tables
    func table(_ tag: String) throws(FontError) -> Bytes {
      guard let t = tables.first(where: { $0.tag == tag }) else { throw .missingTable(tag) }
      return try b.slice(t.offset, t.length, tag)
    }
    func optional(_ tag: String) -> Bytes? { try? table(tag) }

    let head = try table("head")
    guard try head.u32(12) == 0x5F0F_3CF5 else { throw .malformed("head's magic number") }
    let unitsPerEm = Int(try head.u16(18))
    guard (16...16384).contains(unitsPerEm) else { throw .malformed("head's unitsPerEm") }
    let hhea = try table("hhea")
    let maxp = try table("maxp")
    glyphCount = Int(try maxp.u16(4))
    longMetrics = Int(try hhea.u16(34))
    guard longMetrics >= 1, longMetrics <= glyphCount else { throw .malformed("hhea's numberOfHMetrics") }
    hmtx = try table("hmtx")
    guard hmtx.count >= 4 * longMetrics else { throw .malformed("hmtx is short") }

    var metrics = Metrics(
      unitsPerEm: unitsPerEm, ascender: Int(try hhea.i16(4)), descender: Int(try hhea.i16(6)),
      lineGap: Int(try hhea.i16(8)), xHeight: 0, capHeight: 0, underlinePosition: 0, underlineThickness: 0,
      italicAngle: 0, isFixedPitch: false, weight: 400)
    if let os2 = optional("OS/2") {
      metrics.weight = Int(try os2.u16(4))
      // FreeType's line metrics: OS/2's typographic ones when the font says
      // to use them (fsSelection's USE_TYPO_METRICS), or when hhea's are
      // zero; then the Windows ones if those are zero too.
      if os2.count >= 78 {
        let typo = (Int(try os2.i16(68)), Int(try os2.i16(70)), Int(try os2.i16(72)))
        let useTypo = try os2.u16(62) & 0x80 != 0
        if useTypo || (metrics.ascender == 0 && metrics.descender == 0) {
          (metrics.ascender, metrics.descender, metrics.lineGap) = typo
          if metrics.ascender == 0 && metrics.descender == 0 {
            metrics.ascender = Int(try os2.u16(74))
            metrics.descender = -Int(try os2.u16(76))
            metrics.lineGap = 0
          }
        }
      }
      if try os2.u16(0) >= 2, os2.count >= 90 {
        metrics.xHeight = Int(try os2.i16(86))
        metrics.capHeight = Int(try os2.i16(88))
      }
    }
    if let post = optional("post") {
      metrics.italicAngle = Double(try post.i32(4)) / 65536
      metrics.underlinePosition = Int(try post.i16(8))
      metrics.underlineThickness = Int(try post.i16(10))
      metrics.isFixedPitch = try post.u32(12) != 0
    }
    self.metrics = metrics
    cmap = try optional("cmap").flatMap { (c: Bytes) throws(FontError) -> CharacterMap? in try CharacterMap(c) }

    if optional("CFF2") != nil && optional("CFF ") == nil { throw .unsupported("CFF2 outlines (variable CFF)") }
    if let cff = optional("CFF ") {
      outlines = .cff(try CFF(cff, glyphCount: glyphCount))
    } else {
      let loca = try table("loca"), glyf = try table("glyf")
      outlines = .glyf(try Glyf(loca: loca, glyf: glyf, longOffsets: try head.i16(50) != 0, glyphCount: glyphCount))
    }
  }

  /// Whether the font has `tag`.
  public func has(_ tag: String) -> Bool { tables.contains { $0.tag == tag } }

  /// A table's bytes (GSUB, GPOS, kern... for the shaper).
  public func table(_ tag: String) -> Bytes? {
    guard let t = tables.first(where: { $0.tag == tag }) else { return nil }
    return try? bytes.slice(t.offset, t.length, tag)
  }

  /// The glyph `cmap` maps `scalar` to: 0 (.notdef) if none.
  public func glyph(for scalar: UInt32) -> Int { cmap?.glyph(for: scalar) ?? 0 }

  /// Every code point `cmap` maps to a glyph, in order.
  public func mappings() -> [(scalar: UInt32, glyph: Int)] { cmap?.mappings() ?? [] }

  /// A glyph's advance and left side bearing: `hmtx`'s, or, for a
  /// TrueType composite that says so (USE_MY_METRICS), its component's.
  public func horizontalMetrics(_ glyph: Int) throws(FontError) -> (advance: Int, leftSideBearing: Int) {
    guard glyph >= 0, glyph < glyphCount else { throw .noGlyph(glyph) }
    if case .glyf(let g) = outlines, let own = try g.metricsGlyph(glyph) { return try hmtxEntry(own) }
    return try hmtxEntry(glyph)
  }

  func hmtxEntry(_ glyph: Int) throws(FontError) -> (advance: Int, leftSideBearing: Int) {
    if glyph < longMetrics {
      return (Int(try hmtx.u16(4 * glyph)), Int(try hmtx.i16(4 * glyph + 2)))
    }
    let advance = Int(try hmtx.u16(4 * (longMetrics - 1)))
    let lsb = 4 * longMetrics + 2 * (glyph - longMetrics)
    return (advance, lsb + 2 <= hmtx.count ? Int(try hmtx.i16(lsb)) : 0)
  }

  public func advance(_ glyph: Int) throws(FontError) -> Int { try horizontalMetrics(glyph).advance }

  /// A glyph's outline.
  public func outline(_ glyph: Int) throws(FontError) -> Outline {
    guard glyph >= 0, glyph < glyphCount else { throw .noGlyph(glyph) }
    switch outlines {
    case .glyf(let g):
      // Placed so that the glyph's own hmtx left side bearing holds (its
      // phantom point at xMin - lsb is the origin), as FreeType places it:
      // its own entry, even where USE_MY_METRICS gives it a component's
      // advance.
      var o = try g.outline(glyph)
      if let xMin = try g.xMin(glyph) {
        let shift = Double(try hmtxEntry(glyph).leftSideBearing - xMin)
        if shift != 0 { o = o.transformed(a: 1, b: 0, c: 0, d: 1, dx: shift, dy: 0) }
      }
      return o
    case .cff(let c): return try c.outline(glyph)
    }
  }

  /// A glyph's ink box, y up, as shapers measure it (HarfBuzz's extents):
  /// a TrueType glyph's from its glyf header, its left edge at its hmtx
  /// side bearing; a CFF glyph's its outline's control box, rounded. The
  /// height is negative (top to bottom); an empty glyph's box is zeros.
  public func extents(_ glyph: Int) throws(FontError) -> (xBearing: Int, yBearing: Int, width: Int, height: Int) {
    guard glyph >= 0, glyph < glyphCount else { throw .noGlyph(glyph) }
    switch outlines {
    case .glyf(let g):
      let d = try g.data(glyph)
      guard d.count >= 10 else { return (0, 0, 0, 0) }
      let xMin = Int(try d.i16(2)), yMin = Int(try d.i16(4)), xMax = Int(try d.i16(6)), yMax = Int(try d.i16(8))
      return (try hmtxEntry(glyph).leftSideBearing, max(yMin, yMax), abs(xMax - xMin), min(yMin, yMax) - max(yMin, yMax))
    case .cff(let c):
      let drawn = Outline(contours: try c.outline(glyph).contours.filter { !$0.segments.isEmpty })
      guard let box = drawn.controlBox else { return (0, 0, 0, 0) }
      func round(_ v: Double) -> Int { v >= 0 ? Int(v + 0.5) : -Int(-v + 0.5) }
      var x = 0, w = 0, y = 0, h = 0
      if box.xMin < box.xMax {
        x = round(box.xMin)
        w = round(box.xMax) - x
      }
      if box.yMin < box.yMax {
        y = round(box.yMax)
        h = round(box.yMin) - y
      }
      return (x, y, w, h)
    }
  }

  /// Whether the outlines are CFF's (cubic) rather than TrueType's.
  public var isCFF: Bool {
    if case .cff = outlines { return true }
    return false
  }

  // MARK: name

  /// A `name` record's string: the Windows English one, else Unicode's,
  /// else the Macintosh Roman one; nil if there's none.
  public func name(_ id: Int) -> String? {
    guard let name = table("name") else { return nil }
    do throws(FontError) {
      let count = Int(try name.u16(2)), storage = Int(try name.u16(4))
      var best: (rank: Int, bytes: Bytes, utf16: Bool)?
      for i in 0..<count {
        let r = 6 + 12 * i
        guard Int(try name.u16(r + 6)) == id else { continue }
        let platform = try name.u16(r), encoding = try name.u16(r + 2), language = try name.u16(r + 4)
        let length = Int(try name.u16(r + 8)), offset = Int(try name.u16(r + 10))
        let rank: Int
        switch (platform, encoding) {
        case (3, 1) where language == 0x409: rank = 0
        case (3, 1), (3, 10): rank = 1
        case (0, _): rank = 2
        case (1, 0): rank = 3
        default: continue
        }
        if best == nil || rank < best!.rank {
          best = (rank, try name.slice(storage + offset, length, "name"), platform != 1)
        }
      }
      guard let best else { return nil }
      if best.utf16 {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < best.bytes.count {
          units.append(try best.bytes.u16(i))
          i += 2
        }
        return String(decoding: units, as: UTF16.self)
      }
      // Macintosh Roman: its ASCII half (the rest is rare in names).
      return String(decoding: (0..<best.bytes.count).map { (try? best.bytes.u8($0)) ?? 0x3F }.map { $0 < 0x80 ? $0 : 0x3F },
                    as: UTF8.self)
    } catch {
      return nil
    }
  }

  /// The family name: the typographic one (16) if there is one, else 1.
  public var familyName: String? { name(16) ?? name(1) }
  public var styleName: String? { name(17) ?? name(2) }
}

enum Outlines: Sendable {
  case glyf(Glyf)
  case cff(CFF)
}

/// `cmap`'s Unicode subtable, chosen as FreeType chooses: the whole
/// repertoire (3,10 or 0,4/0,6, format 12) over the BMP's (3,1 or 0,x,
/// format 4), over a symbol font's (3,0).
struct CharacterMap: Sendable {
  let table: Bytes
  let format: UInt16

  init?(_ cmap: Bytes) throws(FontError) {
    let count = Int(try cmap.u16(2))
    var best: (rank: Int, offset: Int)?
    for i in 0..<count {
      let r = 4 + 8 * i
      let platform = try cmap.u16(r), encoding = try cmap.u16(r + 2), offset = Int(try cmap.u32(r + 4))
      guard offset < cmap.count else { continue }
      let format = try cmap.u16(offset)
      guard [0, 4, 6, 12].contains(format) else { continue }
      let rank: Int
      switch (platform, encoding) {
      case (3, 10), (0, 4), (0, 6): rank = format == 12 ? 0 : 3
      case (3, 1), (0, _): rank = 1 + (format == 4 ? 0 : 1)
      case (3, 0): rank = 4
      default: continue
      }
      if best == nil || rank < best!.rank { best = (rank, offset) }
    }
    guard let best else { return nil }
    table = try cmap.from(best.offset, "cmap")
    format = try table.u16(0)
  }

  func glyph(for c: UInt32) -> Int { (try? lookup(c)) ?? 0 }

  func lookup(_ c: UInt32) throws(FontError) -> Int {
    switch format {
    case 0:
      return c < 256 ? Int(try table.u8(6 + Int(c))) : 0
    case 6:
      let first = UInt32(try table.u16(6)), count = UInt32(try table.u16(8))
      return c >= first && c - first < count ? Int(try table.u16(10 + 2 * Int(c - first))) : 0
    case 4:
      guard c <= 0xFFFF else { return 0 }
      let segments = Int(try table.u16(6)) / 2
      let ends = 14, starts = 16 + 2 * segments, deltas = starts + 2 * segments, ranges = deltas + 2 * segments
      // The first segment whose end is at or past c.
      var lo = 0, hi = segments
      while lo < hi {
        let mid = (lo + hi) / 2
        if UInt32(try table.u16(ends + 2 * mid)) < c { lo = mid + 1 } else { hi = mid }
      }
      guard lo < segments else { return 0 }
      let start = UInt32(try table.u16(starts + 2 * lo))
      guard c >= start else { return 0 }
      let delta = try table.u16(deltas + 2 * lo)
      let rangeOffset = Int(try table.u16(ranges + 2 * lo))
      if rangeOffset == 0 { return Int(UInt16(truncatingIfNeeded: c) &+ delta) }
      let at = ranges + 2 * lo + rangeOffset + 2 * Int(c - start)
      let g = try table.u16(at)
      return g == 0 ? 0 : Int(g &+ delta)
    case 12:
      let groups = Int(try table.u32(12))
      var lo = 0, hi = groups
      while lo < hi {
        let mid = (lo + hi) / 2
        let r = 16 + 12 * mid
        if try table.u32(r + 4) < c { lo = mid + 1 } else { hi = mid }
      }
      guard lo < groups else { return 0 }
      let r = 16 + 12 * lo
      let first = try table.u32(r), glyph = try table.u32(r + 8)
      return c >= first ? Int(glyph + (c - first)) : 0
    default:
      return 0
    }
  }

  /// Every mapped code point and its glyph (glyph 0 left out).
  func mappings() -> [(scalar: UInt32, glyph: Int)] {
    var out: [(scalar: UInt32, glyph: Int)] = []
    func add(_ first: UInt32, _ last: UInt32) {
      guard first <= last else { return }
      for c in first...last {
        let g = glyph(for: c)
        if g != 0 { out.append((c, g)) }
      }
    }
    do throws(FontError) {
      switch format {
      case 0: add(0, 255)
      case 6:
        let first = UInt32(try table.u16(6)), count = UInt32(try table.u16(8))
        if count > 0 { add(first, first + count - 1) }
      case 4:
        let segments = Int(try table.u16(6)) / 2
        for s in 0..<segments {
          add(UInt32(try table.u16(16 + 2 * segments + 2 * s)), UInt32(try table.u16(14 + 2 * s)))
        }
      case 12:
        for g in 0..<Int(try table.u32(12)) {
          let r = 16 + 12 * g
          add(try table.u32(r), min(try table.u32(r + 4), 0x10FFFF))
        }
      default: break
      }
    } catch {}
    return out
  }
}
