// SPDX-License-Identifier: BSD-3-Clause

// Normalizing for the font (M6h), as shapers do it (HarfBuzz's default:
// "composed diacritics"): not to a normalization form, but to the glyphs
// the font has. Three rounds:
//
//   1. Decompose. A character outside a cluster of marks keeps its own
//      glyph if the font has one; else it's canonically decomposed, one
//      level at a time, as far as the font has the pieces; else a space
//      the font lacks is drawn with its space glyph (at its own width,
//      later), and U+2011 with U+2010's. A cluster of marks is decomposed
//      as far as the font allows, so that round 3 can compose it again
//      with what the font has. Variation selectors are passed on as they
//      are (their sequences in cmap format 14 are a stub).
//   2. Reorder marks by canonical combining class (a stable sort of each
//      run of marks; HarfBuzz's modified classes for Hebrew, Arabic, Thai
//      and Tibetan are a stub: the plain classes).
//   3. Recompose: a mark joins the starter before it, if nothing between
//      blocks it, the pair has a primary composite, and the font has that
//      composite's glyph.
//
// Each character's glyph is chosen here; clusters merge where characters
// compose.

import OpenType
import TDUnicode

struct Normalizer {
  let font: Font

  func glyph(_ c: UInt32) -> Int? {
    let g = font.glyph(for: c)
    return g == 0 ? nil : g
  }

  static func isVariationSelector(_ c: UInt32) -> Bool {
    (c >= 0xFE00 && c <= 0xFE0F) || (c >= 0xE0100 && c <= 0xE01EF) || (c >= 0x180B && c <= 0x180D) || c == 0x180F
  }

  /// The three rounds over `input`, its glyphs chosen.
  func normalize(_ input: [Slot]) -> [Slot] {
    var out: [Slot] = []
    out.reserveCapacity(input.count)
    var allSimple = true
    var i = 0
    let count = input.count
    while i < count {
      // A run of characters with no marks after them: each on its own.
      var end = i + 1
      while end < count && !input[end].isUnicodeMark { end += 1 }
      if end < count { end -= 1 }  // leave the base to the marks after it
      while i < end {
        decomposeCharacter(input[i], shortest: true, into: &out)
        i += 1
      }
      if i == count { break }
      allSimple = false
      // A base and its marks.
      end = i + 1
      while end < count && input[end].isUnicodeMark { end += 1 }
      if end - i == 1 {
        decomposeCharacter(input[i], shortest: true, into: &out)
      } else if input[i..<end].contains(where: { Normalizer.isVariationSelector($0.codepoint) }) {
        for k in i..<end {
          var s = input[k]
          s.glyph = glyph(s.codepoint) ?? 0
          out.append(s)
        }
      } else {
        for k in i..<end { decomposeCharacter(input[k], shortest: false, into: &out) }
      }
      i = end
    }
    if allSimple { return out }

    // Round 2: reorder marks by combining class.
    var start = 0
    while start < out.count {
      guard out[start].combiningClass != 0 else {
        start += 1
        continue
      }
      var end = start + 1
      while end < out.count && out[end].combiningClass != 0 { end += 1 }
      if end - start <= 32 {
        for k in start + 1..<end {
          var j = k
          while j > start && out[j - 1].combiningClass > out[k].combiningClass { j -= 1 }
          if j == k { continue }
          out.mergeClusters(j, k + 1)
          let moved = out.remove(at: k)
          out.insert(moved, at: j)
        }
      }
      start = end
    }

    // Round 3: recompose what the font has.
    var composed: [Slot] = []
    composed.reserveCapacity(out.count)
    var starter = 0
    for s in out {
      if composed.isEmpty {
        composed.append(s)
        continue
      }
      if s.isUnicodeMark,
        starter == composed.count - 1 || composed[composed.count - 1].combiningClass < s.combiningClass,
        let c = Normalization.compose(composed[starter].codepoint, s.codepoint), let g = glyph(c)
      {
        composed.append(s)
        composed.mergeClusters(starter, composed.count)
        composed.removeLast()
        composed[starter].codepoint = c
        composed[starter].glyph = g
        composed[starter].setUnicodeProperties()
        continue
      }
      composed.append(s)
      if s.combiningClass == 0 { starter = composed.count - 1 }
    }
    return composed
  }

  /// One character: its own glyph, or its decomposition's, or a fallback.
  func decomposeCharacter(_ s: Slot, shortest: Bool, into out: inout [Slot]) {
    if shortest, let g = glyph(s.codepoint) {
      var t = s
      t.glyph = g
      out.append(t)
      return
    }
    var pieces: [UInt32] = []
    if decompose(s.codepoint, shortest: shortest, into: &pieces) {
      for c in pieces {
        var t = s
        t.codepoint = c
        t.setUnicodeProperties()
        t.glyph = glyph(c) ?? 0
        out.append(t)
      }
      return
    }
    var t = s
    if !shortest, let g = glyph(s.codepoint) {
      t.glyph = g
    } else if SegmentationProperties(s.codepoint).generalCategory == .Zs, SpaceFallback(s.codepoint) != .none,
      let space = glyph(0x20)
    {
      t.glyph = space
      t.spaceFallback = SpaceFallback(s.codepoint)
    } else if s.codepoint == 0x2011, let hyphen = glyph(0x2010) {
      t.glyph = hyphen
    } else {
      t.glyph = 0
    }
    out.append(t)
  }

  /// `ab`'s canonical decomposition, a level at a time, as far as the font
  /// has the pieces: false if it has none, or the font lacks them.
  func decompose(_ ab: UInt32, shortest: Bool, into pieces: inout [UInt32]) -> Bool {
    guard let (a, b) = Normalization.decomposeOnce(ab) else { return false }
    if let b, glyph(b) == nil { return false }
    let hasA = glyph(a) != nil
    if shortest && hasA {
      pieces.append(a)
      if let b { pieces.append(b) }
      return true
    }
    var inner: [UInt32] = []
    if decompose(a, shortest: shortest, into: &inner) {
      pieces += inner
      if let b { pieces.append(b) }
      return true
    }
    if hasA {
      pieces.append(a)
      if let b { pieces.append(b) }
      return true
    }
    return false
  }
}
