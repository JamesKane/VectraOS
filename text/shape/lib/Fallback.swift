// SPDX-License-Identifier: BSD-3-Clause

// Marks in a font with no GPOS (M6h): placed around their base by their
// combining class and the glyphs' ink boxes, as shapers do for such fonts
// (HarfBuzz's fallback, which Uniscribe's resembles). Each run of marks
// after a base is placed in order: above or below the base's box, centred
// on its advance (or left or right aligned, by class), a sixteenth of an
// em clear of it; each further mark of the same class stacks on the last.
// Over a ligature, a mark goes over its own component's share of the
// advance. The classes the complex scripts reassign first (Hebrew,
// Arabic, Thai, Lao, Tibetan) are a stub: their marks keep Unicode's.

import OpenType

extension Shaper {
  /// Combining classes (Unicode's names).
  static let attachedBelowLeft = 200, attachedBelow = 202, attachedAbove = 214, attachedAboveRight = 216
  static let belowLeft = 218, below = 220, belowRight = 222, aboveLeft = 228, above = 230, aboveRight = 232
  static let doubleBelow = 233, doubleAbove = 234

  typealias Box = (xBearing: Int, yBearing: Int, width: Int, height: Int)

  func fallbackMarks(_ b: inout [Slot]) {
    var start = 0
    for i in 1..<max(1, b.count + 1) where i == b.count || !b[i].isUnicodeMark {
      positionCluster(&b, start, i)
      start = i
    }
  }

  func positionCluster(_ b: inout [Slot], _ start: Int, _ end: Int) {
    guard end - start >= 2 else { return }
    var i = start
    while i < end {
      if !b[i].isUnicodeMark {
        var j = i + 1
        while j < end && b[j].isUnicodeMark { j += 1 }
        positionAroundBase(&b, i, j)
        i = j
      } else {
        i += 1
      }
    }
  }

  func positionAroundBase(_ b: inout [Slot], _ base: Int, _ end: Int) {
    guard var baseBox = try? font.extents(b[base].glyph) else {
      for i in base + 1..<end where b[i].category == GeneralCategoryMn {
        b[i].xOffset -= b[i].xAdvance
        b[i].yOffset -= b[i].yAdvance
        b[i].xAdvance = 0
        b[i].yAdvance = 0
      }
      return
    }
    baseBox.yBearing += b[base].yOffset
    // Horizontally, the base's advance: better for most fonts, and for
    // glyphs with no ink.
    baseBox.xBearing = 0
    baseBox.width = (try? font.advance(b[base].glyph)) ?? 0
    let ligID = b[base].ligID
    let components = b[base].componentCount
    var xOffset = -b[base].xAdvance, yOffset = -b[base].yAdvance
    var componentBox = baseBox
    var lastComponent = -1
    var lastClass = 255
    var clusterBox = baseBox
    for i in base + 1..<end {
      let klass = Int(b[i].combiningClass)
      guard klass != 0 else {
        xOffset -= b[i].xAdvance
        yOffset -= b[i].yAdvance
        continue
      }
      if components > 1 {
        var component = Int(b[i].component) - 1
        if ligID == 0 || ligID != b[i].ligID || component < 0 || component >= components { component = components - 1 }
        if lastComponent != component {
          lastComponent = component
          lastClass = 255
          componentBox = baseBox
          componentBox.xBearing += component * componentBox.width / components
          componentBox.width /= components
        }
      }
      if lastClass != klass {
        lastClass = klass
        clusterBox = componentBox
      }
      positionMark(&b, &clusterBox, i, klass)
      b[i].xAdvance = 0
      b[i].yAdvance = 0
      b[i].xOffset += xOffset
      b[i].yOffset += yOffset
    }
  }

  /// One mark against the box of what's under (or over) it so far, which
  /// it then joins.
  func positionMark(_ b: inout [Slot], _ base: inout Box, _ i: Int, _ klass: Int) {
    guard let mark = try? font.extents(b[i].glyph) else { return }
    let gap = font.metrics.unitsPerEm / 16
    var x = 0, y = 0
    switch klass {
    case Shaper.doubleBelow, Shaper.doubleAbove:
      x = base.xBearing + base.width - mark.width / 2 - mark.xBearing
    case Shaper.attachedBelowLeft, Shaper.belowLeft, Shaper.aboveLeft:
      x = base.xBearing - mark.xBearing
    case Shaper.attachedAboveRight, Shaper.belowRight, Shaper.aboveRight:
      x = base.xBearing + base.width - mark.width - mark.xBearing
    default:
      x = base.xBearing + (base.width - mark.width) / 2 - mark.xBearing
    }
    switch klass {
    case Shaper.doubleBelow, Shaper.belowLeft, Shaper.below, Shaper.belowRight, Shaper.attachedBelowLeft,
      Shaper.attachedBelow:
      if klass != Shaper.attachedBelowLeft && klass != Shaper.attachedBelow { base.height -= gap }
      y = base.yBearing + base.height - mark.yBearing
      // Never shift a mark below up.
      if (gap > 0) == (y > 0) {
        base.height -= y
        y = 0
      }
      base.height += mark.height
    case Shaper.doubleAbove, Shaper.aboveLeft, Shaper.above, Shaper.aboveRight, Shaper.attachedAbove,
      Shaper.attachedAboveRight:
      if klass != Shaper.attachedAbove && klass != Shaper.attachedAboveRight {
        base.yBearing += gap
        base.height -= gap
      }
      y = base.yBearing - (mark.yBearing + mark.height)
      // Nor one above down too far.
      if (gap > 0) != (y > 0) {
        let correction = -y / 2
        base.yBearing += correction
        base.height -= correction
        y += correction
      }
      base.yBearing -= mark.height
      base.height += mark.height
    default:
      break
    }
    b[i].xOffset = x
    b[i].yOffset = y
  }
}
