// SPDX-License-Identifier: BSD-3-Clause

// A frame's damage (M6m part m2: the text editor's frames on time): the
// pixels that differ from the last frame's, as the rectangle around every
// quad that's in one frame's display list and not the other's (matched
// whole: a glyph moved is two quads, where it was and where it is). A
// change of the clips' rectangles damages everything. The platform
// renders, copies and presents only the damage. The table that matches
// them is the UI's, reused: a frame allocates nothing here.

extension UI {
  /// The damage between `painter.list` and `lastList`, in pixels; nil if
  /// they're the same.
  mutating func findDamage() -> Rect? {
    let new = painter.list, old = lastList
    if new.quads.isEmpty && old.quads.isEmpty { return nil }
    let all = Rect(x: 0, y: 0, width: width * painter.scale, height: height * painter.scale)
    // The clips' rectangles, in order (not where they start: a glyph typed
    // moves every later quad's index).
    if new.clips.count != old.clips.count { return all }
    for i in new.clips.indices {
      let a = new.clips[i], b = old.clips[i]
      if a.x0 != b.x0 || a.y0 != b.y0 || a.x1 != b.x1 || a.y1 != b.y1 { return all }
    }
    // Old quads by hash; each new one takes an equal old one, or damages.
    var table = scratch.damageTable, taken = scratch.damageTaken
    (scratch.damageTable, scratch.damageTaken) = ([], [])
    defer { (scratch.damageTable, scratch.damageTaken) = (table, taken) }
    var size = 64
    while size < old.quads.count * 2 { size <<= 1 }
    table.removeAll(keepingCapacity: true)
    table.append(contentsOf: repeatElement(-1, count: size))
    taken.removeAll(keepingCapacity: true)
    taken.append(contentsOf: repeatElement(false, count: old.quads.count))
    let mask = size - 1
    for (i, q) in old.quads.enumerated() {
      var h = Int(truncatingIfNeeded: UI.hash(q)) & mask
      while table[h] >= 0 { h = (h + 1) & mask }
      table[h] = Int32(i)
    }
    var box: (x0: Float, y0: Float, x1: Float, y1: Float)? = nil
    func add(_ q: UIQuad) {
      let reach = max(q.glow, 0) + 1
      let r = (q.x - reach, q.y - reach, q.x + q.width + reach, q.y + q.height + reach)
      box = box.map { (min($0.x0, r.0), min($0.y0, r.1), max($0.x1, r.2), max($0.y1, r.3)) } ?? r
    }
    for q in new.quads {
      var h = Int(truncatingIfNeeded: UI.hash(q)) & mask
      var found = false
      while table[h] >= 0 {
        let i = Int(table[h])
        if !taken[i] && old.quads[i] == q {
          taken[i] = true
          found = true
          break
        }
        h = (h + 1) & mask
      }
      if !found { add(q) }
    }
    for (i, q) in old.quads.enumerated() where !taken[i] { add(q) }
    guard let b = box else { return nil }
    let x0 = max(b.x0, 0), y0 = max(b.y0, 0), x1 = min(b.x1, all.width), y1 = min(b.y1, all.height)
    guard x0 < x1, y0 < y1 else { return nil }
    return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  static func hash(_ q: UIQuad) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    func mix(_ v: UInt64) {
      h ^= v
      h &*= 0x100_0000_01B3
    }
    mix(UInt64(q.x.bitPattern) | UInt64(q.y.bitPattern) << 32)
    mix(UInt64(q.width.bitPattern) | UInt64(q.height.bitPattern) << 32)
    mix(UInt64(q.kind) | UInt64(q.fill) << 32)
    mix(UInt64(q.atlasX) | UInt64(q.atlasY) << 16 | UInt64(q.atlasWidth) << 32 | UInt64(q.atlasHeight) << 48)
    mix(UInt64(q.stroke) | UInt64(q.cuts) << 32)
    return h
  }
}
