// SPDX-License-Identifier: BSD-3-Clause

// A frame's damage (M6m part m2: the text editor's frames on time): the
// pixels that differ from the last frame's, as the rectangle around every
// quad that's in one frame's display list and not the other's, under the
// same clip (matched whole: a glyph moved is two quads, where it was and
// where it is), each as far as its clip lets it draw. A clip's rectangle
// changed damages only what it holds, so a menu drawn over clipped
// content, which ends that clip, damages the menu, not the window. The
// platform renders, copies and presents only the damage. The tables that
// match them are the UI's, reused: a frame allocates nothing here.

extension UI {
  /// The damage between `painter.list` and `lastList`, in pixels; nil if
  /// they're the same.
  mutating func findDamage() -> Rect? {
    let new = painter.list, old = lastList
    if new.quads.isEmpty && old.quads.isEmpty { return nil }
    let all = Rect(x: 0, y: 0, width: width * painter.scale, height: height * painter.scale)
    // Old quads by hash, with the clip each was drawn under; each new one
    // takes an equal old one under an equal clip, or damages.
    var table = scratch.damageTable, taken = scratch.damageTaken, under = scratch.damageClips
    (scratch.damageTable, scratch.damageTaken, scratch.damageClips) = ([], [], [])
    defer { (scratch.damageTable, scratch.damageTaken, scratch.damageClips) = (table, taken, under) }
    var size = 64
    while size < old.quads.count * 2 { size <<= 1 }
    table.removeAll(keepingCapacity: true)
    table.append(contentsOf: repeatElement(-1, count: size))
    taken.removeAll(keepingCapacity: true)
    taken.append(contentsOf: repeatElement(false, count: old.quads.count))
    under.removeAll(keepingCapacity: true)
    let mask = size - 1
    // The clip quad `i` of `list` is drawn under, after `c` (-1: none yet).
    func clip(_ list: DisplayList, _ i: Int, after c: inout Int) {
      while c + 1 < list.clips.count && list.clips[c + 1].first <= i { c += 1 }
    }
    func rect(_ list: DisplayList, _ c: Int) -> (x0: Float, y0: Float, x1: Float, y1: Float) {
      guard c >= 0 else { return (-Float.infinity, -Float.infinity, Float.infinity, Float.infinity) }
      let r = list.clips[c]
      return (r.x0, r.y0, r.x1, r.y1)
    }
    var c = -1
    for (i, q) in old.quads.enumerated() {
      clip(old, i, after: &c)
      under.append(Int32(c))
      var h = Int(truncatingIfNeeded: UI.hash(q)) & mask
      while table[h] >= 0 { h = (h + 1) & mask }
      table[h] = Int32(i)
    }
    var box: (x0: Float, y0: Float, x1: Float, y1: Float)? = nil
    func add(_ q: UIQuad, _ clip: (x0: Float, y0: Float, x1: Float, y1: Float)) {
      let reach = max(q.glow, 0) + 1
      let r = (max(q.x - reach, clip.x0), max(q.y - reach, clip.y0), min(q.x + q.width + reach, clip.x1),
               min(q.y + q.height + reach, clip.y1))
      guard r.0 < r.2 && r.1 < r.3 else { return }
      box = box.map { (min($0.x0, r.0), min($0.y0, r.1), max($0.x1, r.2), max($0.y1, r.3)) } ?? r
    }
    c = -1
    for (n, q) in new.quads.enumerated() {
      clip(new, n, after: &c)
      let here = rect(new, c)
      var h = Int(truncatingIfNeeded: UI.hash(q)) & mask
      var found = false
      while table[h] >= 0 {
        let i = Int(table[h])
        if !taken[i] && old.quads[i] == q && rect(old, Int(under[i])) == here {
          taken[i] = true
          found = true
          break
        }
        h = (h + 1) & mask
      }
      if !found { add(q, here) }
    }
    for (i, q) in old.quads.enumerated() where !taken[i] { add(q, rect(old, Int(under[i]))) }
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
    // FNV's low bits hear only its inputs' low bits, and a whole number's
    // float has none set: mixed down (splitmix64's finish), or the table,
    // which takes the low bits, probes a chain of every quad.
    h ^= h >> 30
    h &*= 0xBF58_476D_1CE4_E5B9
    h ^= h >> 27
    h &*= 0x94D0_49BB_1331_11EB
    return h ^ (h >> 31)
  }
}
