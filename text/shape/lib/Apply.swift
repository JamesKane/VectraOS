// SPDX-License-Identifier: BSD-3-Clause

// GSUB and GPOS lookups applied to the buffer (M6h), from OpenType 1.9 and
// the behaviour shapers agree on (HarfBuzz's, which the tests compare with):
//
// - A lookup runs over the buffer from the start (a reverse chaining one
//   from the end); at each glyph its flags allow, its subtables are tried
//   in order until one applies, and that one says where to go next.
// - Matching skips what the lookup's flags ignore (base glyphs,
//   ligatures, marks, marks outside its filtering set or of another
//   attachment class) and, unless they match, default ignorables. ZWNJ is
//   not skipped in a substitution's input (it stops a ligature), nor ZWJ
//   where a feature takes joiners manually (mark, mkmk).
// - A ligature remembers its components, and the marks between them which
//   component they followed (an id and a number), so that mark-to-ligature
//   positioning puts each over its own; a multiple substitution numbers
//   the glyphs it makes, and marks attach to the first of them.
// - A contextual lookup's nested lookups apply at their sequence indices,
//   which move as nested substitutions change the buffer's length.
// - Marks are positioned by anchors, as offsets from the glyph they attach
//   to; the offsets are made relative to the mark's own place at the end.
//
// Cursive attachment (GPOS 3) is a stub: Arabic's and Nastaliq's, not
// Latin's.

import OpenType

struct Engine {
  var buffer: [Slot]
  let gdef: GDEF
  let hasGlyphClasses: Bool
  let gsub: LayoutTable?
  let gpos: LayoutTable?
  /// 0 while substituting, 1 while positioning.
  var table = 0
  /// The lookup's flags, and its mark filtering set << 16.
  var props: UInt32 = 0
  var autoZWJ = true
  var autoZWNJ = true
  /// The feature's value: an alternate substitution's choice.
  var value = 1
  var idx = 0
  var nesting = 64
  var ligSerial = 0
  /// No substitution grows the buffer past this.
  let maxLength: Int

  init(_ buffer: [Slot], gdef: GDEF, gsub: LayoutTable?, gpos: LayoutTable?) {
    self.buffer = buffer
    self.gdef = gdef
    hasGlyphClasses = gdef.hasGlyphClasses
    self.gsub = gsub
    self.gpos = gpos
    maxLength = max(16384, 64 * buffer.count)
  }

  // MARK: Glyph properties

  /// GDEF's properties for a glyph: its class as lookup flags test it,
  /// and a mark's attachment class.
  func glyphProps(_ glyph: Int) -> UInt16 {
    switch gdef.glyphClass(glyph) {
    case GDEF.base: Slot.base
    case GDEF.ligature: Slot.ligature
    case GDEF.mark: Slot.mark | UInt16(gdef.markAttachmentClass(glyph) & 0xFF) << 8
    default: 0
    }
  }

  /// A glyph substituted at `i`, its class from GDEF (or `guess`).
  mutating func setGlyph(_ i: Int, _ glyph: Int, guess: UInt16 = 0, ligature: Bool = false, component: Bool = false) {
    var p = buffer[i].props | Slot.substituted
    if ligature {
      p |= Slot.ligated
      p &= ~Slot.multiplied
    }
    if component { p |= Slot.multiplied }
    if hasGlyphClasses {
      p = p & Slot.preserve | glyphProps(glyph)
    } else if guess != 0 {
      p = p & Slot.preserve | guess
    }
    buffer[i].props = p
    buffer[i].glyph = glyph
  }

  /// Whether a lookup with `props` sees the glyph at all.
  func covers(_ s: Slot, _ props: UInt32) -> Bool {
    let gp = UInt32(s.props)
    if gp & props & 0x0E != 0 { return false }
    if gp & UInt32(Slot.mark) != 0 {
      if props & UInt32(Lookup.useMarkFilteringSet) != 0 { return gdef.inMarkSet(Int(props >> 16), s.glyph) }
      if props & 0xFF00 != 0 { return props & 0xFF00 == gp & 0xFF00 }
    }
    return true
  }

  // MARK: Matching

  struct Matcher {
    var props: UInt32
    var ignoreZWNJ: Bool
    var ignoreZWJ: Bool
    var ignoreHidden: Bool
  }

  enum Skip { case no, yes, maybe }

  /// The matcher for a lookup's input.
  var input: Matcher { Matcher(props: props, ignoreZWNJ: table == 1, ignoreZWJ: autoZWJ, ignoreHidden: table == 1) }
  /// The matcher for a context's backtrack and lookahead.
  var context: Matcher {
    Matcher(props: props, ignoreZWNJ: table == 1 || autoZWNJ, ignoreZWJ: true, ignoreHidden: table == 1)
  }

  func maySkip(_ s: Slot, _ m: Matcher) -> Skip {
    if !covers(s, m.props) { return .yes }
    if s.isDefaultIgnorable && (m.ignoreZWNJ || !s.zwnj) && (m.ignoreZWJ || !s.zwj) && (m.ignoreHidden || !s.hidden) {
      return .maybe
    }
    return .no
  }

  /// Whether the glyph matches (true), is skipped (nil), or stops the
  /// search (false); a pattern that says nil matches any glyph not skipped.
  func step(_ s: Slot, _ m: Matcher, _ pattern: (Slot) -> Bool?) -> Bool? {
    let skip = maySkip(s, m)
    if skip == .yes { return nil }
    let matches = pattern(s)
    if matches == true || (matches == nil && skip == .no) { return true }
    if skip == .no { return false }
    return nil
  }

  /// The next glyph after `i` that matches, if one does before a glyph
  /// that doesn't.
  func next(_ i: Int, _ m: Matcher, _ pattern: (Slot) -> Bool? = { _ in nil }) -> Int? {
    var j = i + 1
    while j < buffer.count {
      if let r = step(buffer[j], m, pattern) { return r ? j : nil }
      j += 1
    }
    return nil
  }

  func prev(_ i: Int, _ m: Matcher, _ pattern: (Slot) -> Bool? = { _ in nil }) -> Int? {
    var j = i - 1
    while j >= 0 {
      if let r = step(buffer[j], m, pattern) { return r ? j : nil }
      j -= 1
    }
    return nil
  }

  // MARK: Running lookups

  func layout(_ t: Int) -> LayoutTable? { t == 0 ? gsub : gpos }

  static func props(_ l: Lookup) -> UInt32 {
    var p = UInt32(l.flag)
    if l.flag & Lookup.useMarkFilteringSet != 0, let set = l.markFilteringSet { p |= UInt32(set) << 16 }
    return p
  }

  /// Runs a lookup over the buffer.
  mutating func run(_ index: Int, table t: Int, value v: Int, autoZWJ zwj: Bool, autoZWNJ zwnj: Bool) {
    guard let lookup = layout(t)?.lookup(index), !buffer.isEmpty else { return }
    table = t
    value = v
    autoZWJ = zwj
    autoZWNJ = zwnj
    props = Engine.props(lookup)
    if t == 0 && lookup.type == 8 {
      idx = buffer.count - 1
      while idx >= 0 {
        if covers(buffer[idx], props) { _ = applySubtables(lookup) }
        idx -= 1
      }
      return
    }
    idx = 0
    // A budget against lookups that never move on (a malformed context's
    // nested deletions), as HarfBuzz keeps one.
    var budget = 64 * buffer.count + 1024
    while idx < buffer.count && budget > 0 {
      budget -= 1
      if covers(buffer[idx], props) && applySubtables(lookup) { continue }
      idx += 1
    }
  }

  mutating func applySubtables(_ lookup: Lookup) -> Bool {
    for s in lookup.subtables {
      let applied = table == 0 ? substitute(lookup.type, s) : position(lookup.type, s)
      if applied { return true }
    }
    return false
  }

  /// A nested lookup at `idx`, under its own flags.
  mutating func recurse(_ index: Int) -> Bool {
    guard nesting > 0, let lookup = layout(table)?.lookup(index) else { return false }
    if table == 0 && lookup.type == 8 { return false }
    let saved = props
    props = Engine.props(lookup)
    nesting -= 1
    let applied = applySubtables(lookup)
    nesting += 1
    props = saved
    return applied
  }

  // MARK: GSUB

  mutating func substitute(_ type: Int, _ s: Bytes) -> Bool {
    guard let format = try? s.u16(0) else { return false }
    let glyph = buffer[idx].glyph
    func coverage(_ at: Int) -> Int? {
      guard let o = try? Int(s.u16(at)), let c = try? s.from(o, "coverage") else { return nil }
      return Coverage(c).index(glyph)
    }
    switch type {
    case 1:
      guard let ci = coverage(2) else { return false }
      if format == 1 {
        guard let delta = try? Int(s.i16(4)) else { return false }
        setGlyph(idx, (glyph + delta) & 0xFFFF)
      } else if format == 2 {
        guard let count = try? Int(s.u16(4)), ci < count, let g = try? Int(s.u16(6 + 2 * ci)) else { return false }
        setGlyph(idx, g)
      } else {
        return false
      }
      idx += 1
      return true
    case 2:
      guard format == 1, let ci = coverage(2), let count = try? Int(s.u16(4)), ci < count,
        let o = try? Int(s.u16(6 + 2 * ci)), let seq = try? s.from(o, "a sequence"), let n = try? Int(seq.u16(0))
      else { return false }
      var glyphs: [Int] = []
      for k in 0..<n {
        guard let g = try? Int(seq.u16(2 + 2 * k)) else { return false }
        glyphs.append(g)
      }
      if n == 1 {
        setGlyph(idx, glyphs[0])
        idx += 1
      } else if n == 0 {
        buffer.deleteGlyph(idx)
      } else {
        guard buffer.count + n - 1 <= maxLength else { return false }
        let klass = buffer[idx].isLigature ? Slot.base : 0
        let ligID = buffer[idx].ligID
        let original = buffer[idx]
        buffer.replaceSubrange(idx...idx, with: [Slot](repeating: original, count: n))
        for k in 0..<n {
          if ligID == 0 { buffer[idx + k].setMark(id: 0, component: k) }
          setGlyph(idx + k, glyphs[k], guess: klass, component: true)
        }
        idx += n
      }
      return true
    case 3:
      guard format == 1, let ci = coverage(2), let count = try? Int(s.u16(4)), ci < count,
        let o = try? Int(s.u16(6 + 2 * ci)), let set = try? s.from(o, "an alternate set"), let n = try? Int(set.u16(0)),
        value >= 1, value <= n, let g = try? Int(set.u16(2 + 2 * (value - 1)))
      else { return false }
      setGlyph(idx, g)
      idx += 1
      return true
    case 4:
      guard format == 1, let ci = coverage(2), let count = try? Int(s.u16(4)), ci < count,
        let o = try? Int(s.u16(6 + 2 * ci)), let set = try? s.from(o, "a ligature set"), let n = try? Int(set.u16(0))
      else { return false }
      for k in 0..<n {
        guard let lo = try? Int(set.u16(2 + 2 * k)), let lig = try? set.from(lo, "a ligature"),
          let ligGlyph = try? Int(lig.u16(0)), let components = try? Int(lig.u16(2)), components >= 1
        else { continue }
        if components == 1 {
          setGlyph(idx, ligGlyph)
          idx += 1
          return true
        }
        guard let match = matchInput(components, { c, slot in ((try? Int(lig.u16(4 + 2 * (c - 1)))) ?? -1) == slot.glyph })
        else { continue }
        ligate(match.positions, match.end, ligGlyph, match.components)
        return true
      }
      return false
    case 5, 6:
      return contextual(s, chained: type == 6)
    case 8:
      guard format == 1, let ci = coverage(2), let nb = try? Int(s.u16(4)) else { return false }
      guard let nl = try? Int(s.u16(6 + 2 * nb)), let ng = try? Int(s.u16(8 + 2 * nb + 2 * nl)), ci < ng,
        let g = try? Int(s.u16(10 + 2 * nb + 2 * nl + 2 * ci))
      else { return false }
      func covered(_ at: Int, _ slot: Slot) -> Bool {
        guard let o = try? Int(s.u16(at)), let c = try? s.from(o, "coverage") else { return false }
        return Coverage(c).index(slot.glyph) != nil
      }
      var i = idx
      for k in 0..<nb {
        guard let j = prev(i, context, { covered(6 + 2 * k, $0) }) else { return false }
        i = j
      }
      i = idx
      for k in 0..<nl {
        guard let j = next(i, context, { covered(8 + 2 * nb + 2 * k, $0) }) else { return false }
        i = j
      }
      setGlyph(idx, g)
      return true
    default:
      return false
    }
  }

  /// The input of a rule matched from `idx`: `count` glyphs (the first
  /// being the current one, already matched), each the next not skipped,
  /// within one ligature component's marks: their positions, the end of
  /// the match, and how many components they stand for.
  func matchInput(_ count: Int, _ matches: (Int, Slot) -> Bool) -> (positions: [Int], end: Int, components: Int)? {
    var positions = [idx]
    var i = idx
    let firstID = buffer[idx].ligID, firstComp = buffer[idx].component
    var ligBase = 0  // 0 unchecked, 1 may not skip, 2 may skip
    var total = 0
    let m = input
    for k in 1..<max(1, count) {
      guard let j = next(i, m, { matches(k, $0) }) else { return nil }
      positions.append(j)
      i = j
      let thisID = buffer[j].ligID, thisComp = buffer[j].component
      if firstID != 0 && firstComp != 0 {
        if firstID != thisID || firstComp != thisComp {
          if ligBase == 0 {
            var found = false
            var b = idx
            while b > 0 && buffer[b - 1].ligID == firstID {
              b -= 1
              if buffer[b].component == 0 {
                found = true
                break
              }
            }
            ligBase = found && maySkip(buffer[b], m) == .yes ? 2 : 1
          }
          if ligBase == 1 { return nil }
        }
      } else if thisID != 0 && thisComp != 0 && thisID != firstID {
        return nil
      }
      total += buffer[j].componentCount
    }
    total += buffer[idx].componentCount
    return (positions, i + 1, total)
  }

  mutating func allocateLigatureID() -> UInt8 {
    while true {
      ligSerial += 1
      let id = UInt8(ligSerial & 7)
      if id != 0 { return id }
    }
  }

  /// The glyphs at `positions` become `ligGlyph` at the first; the marks
  /// between them stay, each remembering which component it followed.
  mutating func ligate(_ positions: [Int], _ end: Int, _ ligGlyph: Int, _ total: Int) {
    let count = positions.count
    buffer.mergeClusters(idx, end)
    var isBaseLigature = buffer[positions[0]].isBase
    var isMarkLigature = buffer[positions[0]].isMark
    for k in 1..<count where !buffer[positions[k]].isMark {
      isBaseLigature = false
      isMarkLigature = false
      break
    }
    let isLigature = !isBaseLigature && !isMarkLigature
    let klass: UInt16 = isLigature ? Slot.ligature : 0
    let ligID: UInt8 = isLigature ? allocateLigatureID() : 0
    var lastLigID = buffer[idx].ligID
    var lastCount = buffer[idx].componentCount
    var soFar = lastCount
    if isLigature {
      buffer[idx].setLigature(id: ligID, components: total)
      if buffer[idx].category == GeneralCategoryMn { buffer[idx].category = GeneralCategoryLo }
    }
    setGlyph(idx, ligGlyph, guess: klass, ligature: true)
    var removed = 0
    for k in 1..<count {
      if isLigature {
        for t in (positions[k - 1] + 1 - removed)..<(positions[k] - removed) {
          var thisComp = buffer[t].component
          if thisComp == 0 { thisComp = lastCount }
          buffer[t].setMark(id: ligID, component: soFar - lastCount + min(thisComp, lastCount))
        }
      }
      let c = positions[k] - removed
      lastLigID = buffer[c].ligID
      lastCount = buffer[c].componentCount
      soFar += lastCount
      buffer.remove(at: c)
      removed += 1
    }
    let after = positions[count - 1] + 1 - removed
    if !isMarkLigature && lastLigID != 0 {
      var t = after
      while t < buffer.count && buffer[t].ligID == lastLigID {
        let thisComp = buffer[t].component
        if thisComp == 0 { break }
        buffer[t].setMark(id: ligID, component: soFar - lastCount + min(thisComp, lastCount))
        t += 1
      }
    }
    idx = after
  }

  // MARK: Context

  /// A contextual (GSUB 5, GPOS 7) or chained contextual (GSUB 6, GPOS 8)
  /// subtable, any of its three formats.
  mutating func contextual(_ s: Bytes, chained: Bool) -> Bool {
    guard let format = try? s.u16(0) else { return false }
    let glyph = buffer[idx].glyph
    func sub(_ at: Int) -> Bytes? {
      guard let o = try? Int(s.u16(at)), o != 0 else { return nil }
      return try? s.from(o, "a context subtable's part")
    }
    func covers(_ c: Bytes?, _ g: Int) -> Bool { c.map { Coverage($0).index(g) != nil } ?? false }
    switch format {
    case 1, 2:
      guard let cov = sub(2), Coverage(cov).index(glyph) != nil else { return false }
      // Format 1 matches glyphs; format 2 classes.
      var backtrackClasses: ClassDef?, inputClasses: ClassDef?, lookaheadClasses: ClassDef?
      let setIndex: Int
      let setsAt: Int
      if format == 1 {
        guard let ci = Coverage(cov).index(glyph) else { return false }
        setIndex = ci
        setsAt = 4
      } else if chained {
        backtrackClasses = sub(4).map(ClassDef.init)
        inputClasses = sub(6).map(ClassDef.init)
        lookaheadClasses = sub(8).map(ClassDef.init)
        setIndex = inputClasses?(glyph) ?? 0
        setsAt = 10
      } else {
        inputClasses = sub(4).map(ClassDef.init)
        backtrackClasses = inputClasses
        lookaheadClasses = inputClasses
        setIndex = inputClasses?(glyph) ?? 0
        setsAt = 6
      }
      guard let setCount = try? Int(s.u16(setsAt)), setIndex < setCount,
        let so = try? Int(s.u16(setsAt + 2 + 2 * setIndex)), so != 0, let set = try? s.from(so, "a rule set"),
        let rules = try? Int(set.u16(0))
      else { return false }
      for r in 0..<rules {
        guard let ro = try? Int(set.u16(2 + 2 * r)), let rule = try? set.from(ro, "a rule") else { continue }
        func value(_ at: Int) -> Int { (try? Int(rule.u16(at))) ?? -1 }
        func matcher(_ classes: ClassDef?) -> (Int, Slot) -> Bool {
          if format == 1 { return { v, slot in slot.glyph == v } }
          return { v, slot in (classes?(slot.glyph) ?? 0) == v }
        }
        var at = 0
        var backtrack: [Int] = [], input: [Int] = [], lookahead: [Int] = []
        if chained {
          let nb = value(at)
          guard nb >= 0 else { continue }
          backtrack = (0..<nb).map { value(at + 2 + 2 * $0) }
          at += 2 + 2 * nb
        }
        let ni = value(at)
        guard ni >= 1 else { continue }
        if chained {
          input = (0..<ni - 1).map { value(at + 2 + 2 * $0) }
          at += 2 + 2 * (ni - 1)
          let nl = value(at)
          guard nl >= 0 else { continue }
          lookahead = (0..<nl).map { value(at + 2 + 2 * $0) }
          at += 2 + 2 * nl
          let nr = value(at)
          guard nr >= 0 else { continue }
          let records = (0..<nr).map { (value(at + 2 + 4 * $0), value(at + 4 + 4 * $0)) }
          let (bm, im, lm) = (matcher(backtrackClasses), matcher(inputClasses), matcher(lookaheadClasses))
          if applyRule(ni, { im(input[$0 - 1], $1) }, backtrack.count, { bm(backtrack[$0], $1) }, lookahead.count,
                       { lm(lookahead[$0], $1) }, records) { return true }
        } else {
          let nr = value(at + 2)
          guard nr >= 0 else { continue }
          input = (0..<ni - 1).map { value(at + 4 + 2 * $0) }
          let base = at + 4 + 2 * (ni - 1)
          let records = (0..<nr).map { (value(base + 4 * $0), value(base + 2 + 4 * $0)) }
          let im = matcher(inputClasses)
          if applyRule(ni, { im(input[$0 - 1], $1) }, 0, { _, _ in false }, 0, { _, _ in false }, records) { return true }
        }
      }
      return false
    case 3:
      func value(_ at: Int) -> Int { (try? Int(s.u16(at))) ?? -1 }
      func coverageAt(_ at: Int) -> Bytes? {
        let o = value(at)
        return o > 0 ? try? s.from(o, "coverage") : nil
      }
      if chained {
        let nb = value(2)
        guard nb >= 0 else { return false }
        let ni = value(4 + 2 * nb)
        guard ni >= 1 else { return false }
        let nl = value(6 + 2 * nb + 2 * ni)
        guard nl >= 0 else { return false }
        let nr = value(8 + 2 * nb + 2 * ni + 2 * nl)
        guard nr >= 0, covers(coverageAt(6 + 2 * nb), glyph) else { return false }
        let backtrack = (0..<nb).map { coverageAt(4 + 2 * $0) }
        let input = (0..<ni).map { coverageAt(6 + 2 * nb + 2 * $0) }
        let lookahead = (0..<nl).map { coverageAt(8 + 2 * nb + 2 * ni + 2 * $0) }
        let r = 10 + 2 * nb + 2 * ni + 2 * nl
        let records = (0..<nr).map { (value(r + 4 * $0), value(r + 2 + 4 * $0)) }
        return applyRule(ni, { covers(input[$0], $1.glyph) }, nb, { covers(backtrack[$0], $1.glyph) }, nl,
                         { covers(lookahead[$0], $1.glyph) }, records)
      } else {
        let ni = value(2), nr = value(4)
        guard ni >= 1, nr >= 0, covers(coverageAt(6), glyph) else { return false }
        let input = (0..<ni).map { coverageAt(6 + 2 * $0) }
        let r = 6 + 2 * ni
        let records = (0..<nr).map { (value(r + 4 * $0), value(r + 2 + 4 * $0)) }
        return applyRule(ni, { covers(input[$0], $1.glyph) }, 0, { _, _ in false }, 0, { _, _ in false }, records)
      }
    default:
      return false
    }
  }

  /// A rule: its input from `idx` (item 0 is the current glyph, already
  /// matched), its backtrack before it and lookahead after, then its
  /// nested lookups.
  mutating func applyRule(_ inputCount: Int, _ input: (Int, Slot) -> Bool, _ backtrackCount: Int,
                          _ backtrack: (Int, Slot) -> Bool, _ lookaheadCount: Int, _ lookahead: (Int, Slot) -> Bool,
                          _ records: [(Int, Int)]) -> Bool
  {
    guard let match = matchInput(inputCount, input) else { return false }
    var i = idx
    for k in 0..<backtrackCount {
      guard let j = prev(i, context, { backtrack(k, $0) }) else { return false }
      i = j
    }
    i = match.end - 1
    for k in 0..<lookaheadCount {
      guard let j = next(i, context, { lookahead(k, $0) }) else { return false }
      i = j
    }
    applyRecords(match.positions, match.end, records)
    return true
  }

  /// A rule's nested lookups, each at its sequence index; the indices
  /// after one move as it changes the buffer's length.
  mutating func applyRecords(_ matched: [Int], _ matchEnd: Int, _ records: [(Int, Int)]) {
    var positions = matched
    var count = positions.count
    var end = matchEnd
    for (sequence, lookup) in records {
      guard sequence >= 0, sequence < count, lookup >= 0 else { continue }
      let before = buffer.count
      guard positions[sequence] < before else { continue }
      idx = positions[sequence]
      guard recurse(lookup) else { continue }
      var delta = buffer.count - before
      if delta == 0 { continue }
      end += delta
      if end < positions[sequence] {
        delta += positions[sequence] - end
        end = positions[sequence]
      }
      var next = sequence + 1
      if delta > 0 {
        guard delta + count <= 64 else { break }
      } else {
        delta = max(delta, next - count)
        next -= delta
      }
      var moved = positions + [Int](repeating: 0, count: max(0, delta))
      if delta > 0 {
        var k = count - 1
        while k >= next {
          moved[k + delta] = moved[k]
          k -= 1
        }
      } else if delta < 0 {
        for k in next..<count { moved[k + delta] = moved[k] }
      }
      next += delta
      count += delta
      positions = Array(moved[0..<count])
      if next > sequence + 1 {
        for j in (sequence + 1)..<next { positions[j] = positions[j - 1] + 1 }
      }
      for k in next..<count { positions[k] += delta }
    }
    idx = end
  }

  // MARK: GPOS

  /// A value record's size for a value format.
  static func size(_ format: UInt16) -> Int { (format & 0xFF).nonzeroBitCount * 2 }

  /// A value record applied to the glyph at `i` (horizontal: Y advance
  /// is vertical text's; device tables need hinting: both ignored).
  mutating func apply(_ format: UInt16, _ b: Bytes, _ at: Int, to i: Int) {
    var o = at
    func next() -> Int {
      let v = (try? Int(b.i16(o))) ?? 0
      o += 2
      return v
    }
    if format & 1 != 0 { buffer[i].xOffset += next() }
    if format & 2 != 0 { buffer[i].yOffset += next() }
    if format & 4 != 0 { buffer[i].xAdvance += next() }
  }

  mutating func position(_ type: Int, _ s: Bytes) -> Bool {
    guard let format = try? s.u16(0) else { return false }
    let glyph = buffer[idx].glyph
    func sub(_ at: Int) -> Bytes? {
      guard let o = try? Int(s.u16(at)), o != 0 else { return nil }
      return try? s.from(o, "a GPOS subtable's part")
    }
    func coverage(_ at: Int, _ g: Int) -> Int? { sub(at).flatMap { Coverage($0).index(g) } }
    switch type {
    case 1:
      guard let ci = coverage(2, glyph), let vf = try? s.u16(4) else { return false }
      if format == 1 {
        apply(vf, s, 6, to: idx)
      } else if format == 2 {
        guard let count = try? Int(s.u16(6)), ci < count else { return false }
        apply(vf, s, 8 + ci * Engine.size(vf), to: idx)
      } else {
        return false
      }
      idx += 1
      return true
    case 2:
      guard let _ = coverage(2, glyph), let vf1 = try? s.u16(4), let vf2 = try? s.u16(6) else { return false }
      guard let j = next(idx, input) else { return false }
      let len1 = Engine.size(vf1), len2 = Engine.size(vf2)
      if format == 1 {
        guard let ci = coverage(2, glyph), let count = try? Int(s.u16(8)), ci < count, let set = sub(10 + 2 * ci),
          let n = try? Int(set.u16(0))
        else { return false }
        let second = buffer[j].glyph
        let record = 2 + len1 + len2
        var lo = 0, hi = n
        var found: Int?
        while lo < hi {
          let mid = (lo + hi) / 2
          guard let g = try? Int(set.u16(2 + record * mid)) else { return false }
          if g == second {
            found = mid
            break
          }
          if g < second { lo = mid + 1 } else { hi = mid }
        }
        guard let f = found else { return false }
        apply(vf1, set, 4 + record * f, to: idx)
        apply(vf2, set, 4 + record * f + len1, to: j)
      } else if format == 2 {
        guard let c1 = sub(8).map(ClassDef.init), let c2 = sub(10).map(ClassDef.init),
          let n1 = try? Int(s.u16(12)), let n2 = try? Int(s.u16(14))
        else { return false }
        let k1 = c1(glyph), k2 = c2(buffer[j].glyph)
        guard k1 < n1, k2 < n2 else { return false }
        let at = 16 + (len1 + len2) * (k1 * n2 + k2)
        apply(vf1, s, at, to: idx)
        apply(vf2, s, at + len1, to: j)
      } else {
        return false
      }
      idx = len2 > 0 ? j + 1 : j
      return true
    case 4, 5:
      // Mark to base, mark to ligature.
      guard format == 1, let mi = coverage(2, glyph), let classes = try? Int(s.u16(6)), let marks = sub(8),
        let attach = sub(10)
      else { return false }
      let m = Matcher(props: UInt32(Lookup.ignoreMarks), ignoreZWNJ: true, ignoreZWJ: autoZWJ, ignoreHidden: true)
      var j = idx
      var base: Int?
      while j > 0 {
        j -= 1
        guard let r = step(buffer[j], m, { _ in nil }) else { continue }
        if !r { break }
        if type == 4 && !acceptsMark(j) && coverage(4, buffer[j].glyph) == nil { continue }
        base = j
        break
      }
      guard let b = base, let bi = coverage(4, buffer[b].glyph) else { return false }
      if type == 4 {
        return attachMark(marks, mi, matrix: attach, row: bi, rowsAt: 0, classes: classes, to: b)
      }
      guard let lo = try? Int(attach.u16(2 + 2 * bi)), lo != 0, let lig = try? attach.from(lo, "a ligature attach"),
        let components = try? Int(lig.u16(0)), components > 0
      else { return false }
      let ligID = buffer[b].ligID, markID = buffer[idx].ligID, markComp = buffer[idx].component
      let component = ligID != 0 && ligID == markID && markComp > 0 ? min(components, markComp) - 1 : components - 1
      return attachMark(marks, mi, matrix: lig, row: component, rowsAt: 0, classes: classes, to: b)
    case 6:
      guard format == 1, let mi = coverage(2, glyph), let classes = try? Int(s.u16(6)), let marks = sub(8),
        let marks2 = sub(10)
      else { return false }
      let m = Matcher(props: props & ~0x0E, ignoreZWNJ: true, ignoreZWJ: autoZWJ, ignoreHidden: true)
      guard let j = prev(idx, m), buffer[j].isMark else { return false }
      let id1 = buffer[idx].ligID, id2 = buffer[j].ligID
      let comp1 = buffer[idx].component, comp2 = buffer[j].component
      let good =
        id1 == id2 ? (id1 == 0 || comp1 == comp2) : ((id1 > 0 && comp1 == 0) || (id2 > 0 && comp2 == 0))
      guard good, let m2 = coverage(4, buffer[j].glyph) else { return false }
      return attachMark(marks, mi, matrix: marks2, row: m2, rowsAt: 0, classes: classes, to: j)
    case 7, 8:
      return contextual(s, chained: type == 8)
    default:
      return false
    }
  }

  /// Whether a mark may attach to the glyph at `i`: not to the second or
  /// later glyph a multiple substitution made, unless a mark came between.
  func acceptsMark(_ i: Int) -> Bool {
    let s = buffer[i]
    guard s.isMultiplied, s.component != 0, i > 0 else { return true }
    let p = buffer[i - 1]
    return p.isMark || !p.isMultiplied || s.ligID != p.ligID || s.component != p.component + 1
  }

  /// The mark at `idx` attached to the glyph at `target` by the anchors of
  /// its class: the mark's in `marks` (a MarkArray), the target's in row
  /// `row` of `matrix` (its count first, then rows of `classes` offsets).
  mutating func attachMark(_ marks: Bytes, _ mi: Int, matrix: Bytes, row: Int, rowsAt: Int, classes: Int,
                           to target: Int) -> Bool
  {
    guard let markCount = try? Int(marks.u16(0)), mi < markCount, let klass = try? Int(marks.u16(2 + 4 * mi)),
      let mo = try? Int(marks.u16(4 + 4 * mi)), klass < classes, let rows = try? Int(matrix.u16(rowsAt)), row < rows,
      let to = try? Int(matrix.u16(rowsAt + 2 + 2 * (row * classes + klass))), to != 0,
      let markAnchor = try? marks.from(mo, "an anchor"), let targetAnchor = try? matrix.from(to, "an anchor"),
      let mx = try? Int(markAnchor.i16(2)), let my = try? Int(markAnchor.i16(4)),
      let tx = try? Int(targetAnchor.i16(2)), let ty = try? Int(targetAnchor.i16(4))
    else { return false }
    buffer[idx].xOffset = tx - mx
    buffer[idx].yOffset = ty - my
    buffer[idx].attachMark = true
    buffer[idx].attachChain = target - idx
    idx += 1
    return true
  }
}

// GeneralCategory's raw values the ligature code reads.
let GeneralCategoryMn: UInt8 = 5
let GeneralCategoryLo: UInt8 = 4
