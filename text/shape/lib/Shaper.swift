// SPDX-License-Identifier: BSD-3-Clause

// The default shaper (M6h): text to positioned glyphs, for scripts that
// need no reordering or joining (Latin, Greek, Cyrillic, and anything else
// left to it), left to right and horizontal. In order:
//
//   1. Each character's Unicode properties; clusters, one a grapheme
//      (a base and its marks, emoji sequences joined by ZWJ, modifiers,
//      regional indicator pairs), numbered by the first character's index.
//   2. Normalizing for the font, which chooses the glyphs (Normalize.swift).
//   3. Glyph classes: GDEF's, or a non-spacing mark's from Unicode.
//   4. GSUB, then GPOS (Apply.swift), with the features HarfBuzz enables
//      for horizontal text: ccmp, locl, rlig, calt, clig, liga, rclt; kern,
//      mark, mkmk, dist, abvm, blwm, curs (rvrn first, its own stage), and
//      the caller's, from the script's language system (the language's, or
//      the default). Without GPOS kerning, the `kern` table's.
//   5. Advances from hmtx (a fallback space at its own width), marks'
//      zeroed after positioning, offsets made relative.
//   6. Default ignorables (soft hyphen, ZWJ, ZWNJ...) hidden: the space
//      glyph at no width.
//
// Positions are in font units. Stubs (text/README.md): the complex
// scripts' shapers, right-to-left and vertical text, automatic fractions
// (U+2044), `rand`, cursive attachment, variation sequences (cmap 14),
// feature ranges. In a font without GPOS, marks are placed by
// Fallback.swift.

import OpenType
import TDUnicode

/// A glyph, positioned: in font units, its advance and its offset from
/// where the advances put it.
public struct ShapedGlyph: Equatable, Sendable {
  public var glyph: Int
  /// The index of the first character of its cluster.
  public var cluster: Int
  public var xAdvance: Int
  public var yAdvance: Int
  public var xOffset: Int
  public var yOffset: Int

  public init(glyph: Int, cluster: Int, xAdvance: Int, yAdvance: Int, xOffset: Int, yOffset: Int) {
    self.glyph = glyph
    self.cluster = cluster
    self.xAdvance = xAdvance
    self.yAdvance = yAdvance
    self.xOffset = xOffset
    self.yOffset = yOffset
  }
}

/// A feature, on (1), off (0), or an alternate's number, for all the text.
public struct Feature: Equatable, Sendable {
  public var tag: String
  public var value: Int

  public init(_ tag: String, _ value: Int = 1) {
    self.tag = tag
    self.value = value
  }
}

public struct Shaper: Sendable {
  public let font: Font
  let gdef: GDEF
  let gsub: LayoutTable?
  let gpos: LayoutTable?
  let kern: KernTable?

  /// The features enabled by default, in HarfBuzz's order; mark and mkmk
  /// take joiners as they come (ZWJ isn't skipped).
  static let defaults = ["rvrn", "ltra", "ltrm", "abvm", "blwm", "ccmp", "locl", "mark", "mkmk", "rlig",
                         "calt", "clig", "curs", "dist", "kern", "liga", "rclt"]
  static let manualJoiners = ["mark", "mkmk"]

  public init(_ font: Font) {
    self.font = font
    gdef = GDEF(font.table("GDEF"))
    gsub = font.table("GSUB").flatMap { try? LayoutTable($0, extensionType: 7) }
    gpos = font.table("GPOS").flatMap { try? LayoutTable($0, extensionType: 9) }
    kern = KernTable(font.table("kern"))
  }

  /// A lookup to run: its index, its feature's value, and whether ZWJ and
  /// ZWNJ are skipped as they come.
  struct Planned {
    var lookup: Int
    var value: Int
    var autoZWJ: Bool
    var autoZWNJ: Bool
  }

  /// Each table's lookups for these features, in stages (GSUB's rvrn
  /// first), each stage in lookup order; and whether GPOS kerns.
  func plan(script: String, language: String?, features: [Feature]) -> (gsub: [[Planned]], gpos: [[Planned]], gposKern: Bool, kern: Bool) {
    var wanted: [(tag: String, value: Int)] = Shaper.defaults.map { ($0, 1) }
    for f in features {
      if let i = wanted.firstIndex(where: { $0.tag == f.tag }) { wanted[i].value = f.value } else { wanted.append((f.tag, f.value)) }
    }
    func lookups(_ table: LayoutTable?, stages: Int, stage: (String) -> Int) -> ([[Planned]], [String]) {
      var out = [[Planned]](repeating: [], count: stages)
      guard let t = table,
        let system = t.languageSystem(scripts: [script], languages: language.map { [$0] } ?? [])
      else { return (out, []) }
      var found: [String] = []
      func add(_ feature: Int, _ s: Int, _ value: Int, _ manual: Bool) {
        for l in t.featureLookups(feature) {
          if let i = out[s].firstIndex(where: { $0.lookup == l }) {
            out[s][i].autoZWJ = out[s][i].autoZWJ && !manual
            out[s][i].autoZWNJ = out[s][i].autoZWNJ && !manual
          } else {
            out[s].append(Planned(lookup: l, value: value, autoZWJ: !manual, autoZWNJ: !manual))
          }
        }
      }
      for (tag, value) in wanted where value > 0 {
        guard let f = system.features.first(where: { t.featureTag($0) == tag }) else { continue }
        found.append(tag)
        add(f, stage(tag), value, Shaper.manualJoiners.contains(tag))
      }
      if let r = system.required, let tag = t.featureTag(r) {
        let s = wanted.contains { $0.tag == tag && $0.value > 0 } ? stage(tag) : 0
        add(r, s, 1, false)
      }
      for s in 0..<stages { out[s].sort { $0.lookup < $1.lookup } }
      return (out, found)
    }
    let (sub, _) = lookups(gsub, stages: 2) { $0 == "rvrn" ? 0 : 1 }
    let (pos, posFeatures) = lookups(gpos, stages: 1) { _ in 0 }
    let kernOn = wanted.contains { $0.tag == "kern" && $0.value > 0 }
    return (sub, pos, posFeatures.contains("kern"), kernOn)
  }

  /// Shapes `text` (Unicode scalars) in `script` (an OpenType script tag)
  /// and `language` (an OpenType language system tag, or the default).
  public func shape(_ text: [UInt32], script: String = "latn", language: String? = nil, features: [Feature] = [])
    -> [ShapedGlyph]
  {
    var out: [ShapedGlyph] = []
    shape(text, script: script, language: language, features: features, into: &out)
    return out
  }

  /// The same into `glyphs`, whose storage is kept: reuse it.
  public func shape(_ text: [UInt32], script: String = "latn", language: String? = nil, features: [Feature] = [],
                    into glyphs: inout [ShapedGlyph])
  {
    // 1. Properties and clusters.
    var slots = [Slot](repeating: Slot(), count: text.count)
    for (i, c) in text.enumerated() {
      slots[i].codepoint = c
      slots[i].cluster = i
      slots[i].setUnicodeProperties()
    }
    var i = 0
    while i < slots.count {
      let c = slots[i].codepoint
      if c >= 0x1F3FB && c <= 0x1F3FF {
        slots[i].continuation = true
      } else if c >= 0x1F1E6 && c <= 0x1F1FF {
        if i > 0, slots[i - 1].codepoint >= 0x1F1E6, slots[i - 1].codepoint <= 0x1F1FF, !slots[i - 1].continuation {
          slots[i].continuation = true
        }
      } else if slots[i].zwj {
        slots[i].continuation = true
        if i + 1 < slots.count && SegmentationProperties(slots[i + 1].codepoint).extendedPictographic {
          i += 1
          slots[i].continuation = true
        }
      } else if (c >= 0xFF9E && c <= 0xFF9F) || (c >= 0xE0020 && c <= 0xE007F) {
        slots[i].continuation = true
      }
      i += 1
    }
    if !slots.isEmpty && text.contains(where: { $0 >= 0x80 }) {
      var start = 0
      for k in 1...slots.count where k == slots.count || !slots[k].continuation {
        slots.mergeClusters(start, k)
        start = k
      }
    }

    // 2. Glyphs, normalizing for the font.
    slots = Normalizer(font: font).normalize(slots)

    // 3. Glyph classes.
    var engine = Engine(slots, gdef: gdef, gsub: gsub, gpos: gpos)
    for k in 0..<engine.buffer.count {
      var props = engine.glyphProps(engine.buffer[k].glyph)
      if !gdef.hasGlyphClasses {
        let s = engine.buffer[k]
        props = s.category == GeneralCategoryMn && !s.isDefaultIgnorable ? Slot.mark : Slot.base
      }
      engine.buffer[k].props = props
    }

    // 4. Substitution.
    let p = plan(script: script, language: language, features: features)
    for stage in p.gsub {
      for l in stage { engine.run(l.lookup, table: 0, value: l.value, autoZWJ: l.autoZWJ, autoZWNJ: l.autoZWNJ) }
    }

    // 5. Positions: advances, fallback spaces, GPOS or kern, marks.
    let upem = font.metrics.unitsPerEm
    for k in 0..<engine.buffer.count {
      engine.buffer[k].xAdvance = (try? font.advance(engine.buffer[k].glyph)) ?? 0
      let fallback = engine.buffer[k].spaceFallback
      if fallback == .none { continue }
      if let n = fallback.divisor {
        engine.buffer[k].xAdvance = (upem + n / 2) / n
      } else if fallback == .fourEm18 {
        engine.buffer[k].xAdvance = upem * 4 / 18
      } else if fallback == .figure {
        for digit in UInt32(0x30)...0x39 {
          let g = font.glyph(for: digit)
          if g != 0 {
            engine.buffer[k].xAdvance = (try? font.advance(g)) ?? 0
            break
          }
        }
      } else if fallback == .punctuation {
        var g = font.glyph(for: 0x2E)
        if g == 0 { g = font.glyph(for: 0x2C) }
        if g != 0 { engine.buffer[k].xAdvance = (try? font.advance(g)) ?? 0 }
      } else if fallback == .narrow {
        engine.buffer[k].xAdvance /= 2
      }
    }
    if gpos != nil {
      for stage in p.gpos {
        for l in stage { engine.run(l.lookup, table: 1, value: l.value, autoZWJ: l.autoZWJ, autoZWNJ: l.autoZWNJ) }
      }
    }
    if p.kern && (gpos == nil || !p.gposKern), let kern {
      applyKern(kern, &engine)
    }
    // Marks have no width after positioning (without GPOS, their offsets
    // keep them where their width put them, until the fallback places them).
    for k in 0..<engine.buffer.count where engine.buffer[k].isMark {
      if gpos == nil { engine.buffer[k].xOffset -= engine.buffer[k].xAdvance }
      engine.buffer[k].xAdvance = 0
      engine.buffer[k].yAdvance = 0
    }
    for k in 0..<engine.buffer.count where engine.buffer[k].isDefaultIgnorable {
      engine.buffer[k].xAdvance = 0
      engine.buffer[k].yAdvance = 0
      engine.buffer[k].xOffset = 0
      engine.buffer[k].yOffset = 0
    }
    // Attached marks' offsets, from the glyph they attach to: add its
    // offset, and take away the advances between.
    for k in 0..<engine.buffer.count { propagate(&engine.buffer, k, depth: 64) }
    if gpos == nil { fallbackMarks(&engine.buffer) }

    // 6. Default ignorables hidden.
    var out = engine.buffer
    if out.contains(where: { $0.isDefaultIgnorable }) {
      let space = font.glyph(for: 0x20)
      if space != 0 {
        for k in 0..<out.count where out[k].isDefaultIgnorable { out[k].glyph = space }
      } else {
        var k = 0
        while k < out.count {
          if out[k].isDefaultIgnorable { out.deleteGlyph(k) } else { k += 1 }
        }
      }
    }
    glyphs.removeAll(keepingCapacity: true)
    for s in out {
      glyphs.append(ShapedGlyph(glyph: s.glyph, cluster: s.cluster, xAdvance: s.xAdvance, yAdvance: s.yAdvance,
                                xOffset: s.xOffset, yOffset: s.yOffset))
    }
  }

  /// A mark's offset made relative to its own place, after the glyph it
  /// attaches to has had the same done.
  func propagate(_ b: inout [Slot], _ i: Int, depth: Int) {
    let chain = b[i].attachChain
    guard chain != 0 else { return }
    b[i].attachChain = 0
    let j = i + chain
    guard j >= 0, j < b.count, depth > 0 else { return }
    propagate(&b, j, depth: depth - 1)
    b[i].xOffset += b[j].xOffset
    b[i].yOffset += b[j].yOffset
    if j < i {
      for k in j..<i {
        b[i].xOffset -= b[k].xAdvance
        b[i].yOffset -= b[k].yAdvance
      }
    }
  }

  /// The `kern` table's pairs, between glyphs that aren't marks: half the
  /// value (rounded down) to the first's advance, the rest to the second's
  /// advance and offset, as HarfBuzz splits it.
  func applyKern(_ kern: KernTable, _ engine: inout Engine) {
    engine.table = 1
    engine.props = UInt32(Lookup.ignoreMarks)
    engine.autoZWJ = true
    engine.autoZWNJ = true
    var i = 0
    while i < engine.buffer.count {
      guard let j = engine.next(i, engine.input) else {
        i += 1
        continue
      }
      let v = kern.value(engine.buffer[i].glyph, engine.buffer[j].glyph)
      if v != 0 {
        let first = v >> 1, second = v - first
        engine.buffer[i].xAdvance += first
        engine.buffer[j].xAdvance += second
        engine.buffer[j].xOffset += second
      }
      i = j
    }
  }
}
