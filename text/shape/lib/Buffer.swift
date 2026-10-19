// SPDX-License-Identifier: BSD-3-Clause

// The shaping buffer (M6h): one record a glyph, what the stages read and
// write: the character it came from and its Unicode properties, the glyph,
// its cluster, its layout properties (GDEF class, what substitution did to
// it, its ligature and component), and its position. Clusters are merged
// as HarfBuzz merges them at its default cluster level (monotone
// graphemes): a merge takes the smallest cluster of the range, and widens
// to the neighbours that shared the clusters it replaced.

import OpenType
import TDUnicode

struct Slot {
  // The character.
  var codepoint: UInt32 = 0
  var category: UInt8 = 0  // GeneralCategory's raw value
  var combiningClass: UInt8 = 0
  var ignorable = false  // Default_Ignorable_Code_Point, as shapers treat it
  var zwj = false
  var zwnj = false
  /// Never skipped as an ignorable by GSUB (CGJ, Mongolian FVS, tags).
  var hidden = false
  /// Continues the cluster before it (a mark, ZWJ, an emoji modifier...).
  var continuation = false
  /// A space the font lacks, drawn with its space glyph at this width.
  var spaceFallback: SpaceFallback = .none

  // The glyph.
  var glyph = 0
  var cluster = 0
  /// GDEF's class as a lookup flag tests it (base 2, ligature 4, mark 8),
  /// what substitution did (substituted 0x10, ligated 0x20, multiplied
  /// 0x40), and a mark's attachment class (<< 8).
  var props: UInt16 = 0
  var ligID: UInt8 = 0
  /// A mark's component of its ligature, or a component's place in what
  /// it was multiplied from; for a ligature, its component count.
  var ligComp: UInt8 = 0
  var ligBase = false

  // The position.
  var xAdvance = 0
  var yAdvance = 0
  var xOffset = 0
  var yOffset = 0
  var attachChain = 0
  var attachMark = false

  static let base: UInt16 = 0x02, ligature: UInt16 = 0x04, mark: UInt16 = 0x08
  static let substituted: UInt16 = 0x10, ligated: UInt16 = 0x20, multiplied: UInt16 = 0x40
  static let preserve: UInt16 = 0x70

  var isMark: Bool { props & Slot.mark != 0 }
  var isBase: Bool { props & Slot.base != 0 }
  var isLigature: Bool { props & Slot.ligature != 0 }
  var isMultiplied: Bool { props & Slot.multiplied != 0 }
  var isSubstituted: Bool { props & Slot.substituted != 0 }
  var isUnicodeMark: Bool { category >= GeneralCategory.Mn.rawValue && category <= GeneralCategory.Me.rawValue }
  /// A default ignorable still to be hidden: one GSUB hasn't replaced.
  var isDefaultIgnorable: Bool { ignorable && !isSubstituted }

  /// A mark's (or component's) ligature component: 0 for a ligature itself.
  var component: Int { ligBase ? 0 : Int(ligComp) }
  /// How many components a glyph stands for: a ligature's count, else 1.
  var componentCount: Int { isLigature && ligBase ? Int(ligComp) : 1 }

  mutating func setLigature(id: UInt8, components: Int) {
    ligID = id
    ligComp = UInt8(truncatingIfNeeded: components & 0x0F)
    ligBase = true
  }

  mutating func setMark(id: UInt8, component: Int) {
    ligID = id
    ligComp = UInt8(truncatingIfNeeded: component & 0x0F)
    ligBase = false
  }

  /// Its Unicode properties, from the character.
  mutating func setUnicodeProperties() {
    let p = SegmentationProperties(codepoint)
    category = p.generalCategory.rawValue
    combiningClass = Normalization.combiningClass(codepoint)
    ignorable = Slot.isDefaultIgnorable(codepoint, p)
    zwj = codepoint == 0x200D
    zwnj = codepoint == 0x200C
    hidden = codepoint == 0x34F || (codepoint >= 0x180B && codepoint <= 0x180D) || (codepoint >= 0xE0020 && codepoint <= 0xE007F)
    continuation = codepoint >= 0x80 && p.isMark
  }

  /// Default_Ignorable_Code_Point, but for the Hangul fillers and the
  /// shorthand format controls, which fonts draw as spacing glyphs
  /// (HarfBuzz's and Uniscribe's exception).
  static func isDefaultIgnorable(_ c: UInt32, _ p: SegmentationProperties) -> Bool {
    guard p.defaultIgnorable else { return false }
    return !(c == 0x115F || c == 0x1160 || c == 0x3164 || c == 0xFFA0 || (c >= 0x1BCA0 && c <= 0x1BCA3))
  }
}

/// How a space the font has no glyph for is drawn: its space glyph, at
/// this width.
enum SpaceFallback: UInt8 {
  case none = 0, space, em, em2, em3, em4, em5, em6, em16, fourEm18, figure, punctuation, narrow

  init(_ c: UInt32) {
    switch c {
    case 0x20, 0xA0: self = .space
    case 0x2000, 0x2002: self = .em2
    case 0x2001, 0x2003, 0x3000: self = .em
    case 0x2004: self = .em3
    case 0x2005: self = .em4
    case 0x2006: self = .em6
    case 0x2007: self = .figure
    case 0x2008: self = .punctuation
    case 0x2009: self = .em5
    case 0x200A: self = .em16
    case 0x202F: self = .narrow
    case 0x205F: self = .fourEm18
    default: self = .none
    }
  }

  /// The fraction of an em for the em-based ones.
  var divisor: Int? {
    switch self {
    case .em: 1
    case .em2: 2
    case .em3: 3
    case .em4: 4
    case .em5: 5
    case .em6: 6
    case .em16: 16
    default: nil
    }
  }
}

extension Array where Element == Slot {
  /// Gives [start, end) one cluster, the smallest among them, widening to
  /// the neighbours that shared the clusters at its ends.
  mutating func mergeClusters(_ start: Int, _ end: Int) {
    guard end - start >= 2 else { return }
    var cluster = self[start].cluster
    for i in start + 1..<end { cluster = Swift.min(cluster, self[i].cluster) }
    var e = end, s = start
    if cluster != self[e - 1].cluster {
      while e < count && self[e - 1].cluster == self[e].cluster { e += 1 }
    }
    if cluster != self[s].cluster {
      while s > 0 && self[s - 1].cluster == self[s].cluster { s -= 1 }
    }
    for i in s..<e { self[i].cluster = cluster }
  }

  /// Removes the glyph at `i`, its cluster going to a neighbour if no
  /// other glyph carries it.
  mutating func deleteGlyph(_ i: Int) {
    let cluster = self[i].cluster
    if (i + 1 < count && self[i + 1].cluster == cluster) || (i > 0 && self[i - 1].cluster == cluster) {
      remove(at: i)
      return
    }
    if i > 0 {
      if cluster < self[i - 1].cluster {
        let old = self[i - 1].cluster
        var k = i
        while k > 0 && self[k - 1].cluster == old {
          self[k - 1].cluster = cluster
          k -= 1
        }
      }
    } else if i + 1 < count {
      mergeClusters(i, i + 2)
    }
    remove(at: i)
  }
}
