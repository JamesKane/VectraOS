// SPDX-License-Identifier: BSD-3-Clause

// Shaped text, kept (M6m part m2: the text editor's criterion, no
// allocations in layout and paint). Shaping a line (its runs by face, the
// typesetter, the glyph cache) allocates and takes time; a frame draws the
// same lines as the last, so each is shaped once. A line's glyph quads
// are kept by its scalars, its style and where it falls within a pixel
// (so a cached line lands on the same pixels as a fresh one), with the
// glyph atlases' generations (cleared atlases: shaped again); drawn
// again, they're moved by whole pixels and coloured. Widths (`measure`)
// and caret positions (`carets`) are kept likewise. A full table keeps
// what this frame and the last used (UI.begin counts frames) and lets the
// rest go, their storage kept for new ones; if what's kept fills half of
// it, it grows (rarely): past the first frames, a frame allocates nothing
// here.

/// One kept line.
struct TextEntry: Sendable {
  var hash: UInt64 = 0
  var scalars: [UInt32] = []
  var key: TextKey = TextKey()
  var generation = 0
  /// Its quads from (whole x, whole y) of where it was drawn, and its width
  /// (logical pixels); or, for carets, the positions.
  var quads: [UIQuad] = []
  var width: Float = 0
  var carets: [(index: Int, x: Float)] = []
  var live = false
  /// The frame it was last used in.
  var used: UInt64 = 0
}

/// What else a line's look depends on.
struct TextKey: Equatable, Sendable {
  var kind: UInt8 = 0  // 0 drawn, 1 measured, 2 carets
  var font: UInt8 = 0
  var weight: Int32 = 0
  var size: Float = 0
  var lineHeight: Float = 0
  var tracking: Float = 0
  var uppercase = false
  /// Where it starts within a pixel (drawn only).
  var fractionX: Float = 0
  var fractionY: Float = 0
}

struct TextCache: Sendable {
  var capacity = 1024
  var entries: [TextEntry] = []
  /// Open addressing: an entry's index, or -1.
  var table = [Int32](repeating: -1, count: 1024 * 2)
  var used = 0
  /// The frame now (UI.begin moves it on).
  var frame: UInt64 = 0
  /// Lines shaped (entries made) since start: a frame that makes none drew
  /// no new text.
  var inserted: UInt64 = 0

  static func hash(_ scalars: some Sequence<UInt32>, _ key: TextKey) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    func mix(_ v: UInt64) {
      h ^= v
      h &*= 0x100_0000_01B3
    }
    for s in scalars { mix(UInt64(s)) }
    mix(UInt64(key.kind) | UInt64(key.font) << 8 | UInt64(UInt32(bitPattern: key.weight)) << 16)
    mix(UInt64(key.size.bitPattern) | UInt64(key.lineHeight.bitPattern) << 32)
    mix(UInt64(key.tracking.bitPattern) | (key.uppercase ? 1 << 32 : 0))
    mix(UInt64(key.fractionX.bitPattern) | UInt64(key.fractionY.bitPattern) << 32)
    return h
  }

  /// The entry for these scalars and key, if kept.
  func find(_ scalars: some Collection<UInt32>, _ key: TextKey, _ hash: UInt64) -> Int? {
    let mask = table.count - 1
    var i = Int(truncatingIfNeeded: hash) & mask
    while table[i] >= 0 {
      let e = Int(table[i])
      if entries[e].hash == hash && entries[e].key == key
        && entries[e].scalars.count == scalars.count && entries[e].scalars.elementsEqual(scalars)
      {
        return e
      }
      i = (i + 1) & mask
    }
    return nil
  }

  /// The entry for these, marked used this frame, if kept.
  mutating func lookup(_ scalars: some Collection<UInt32>, _ key: TextKey, _ hash: UInt64) -> Int? {
    guard let e = find(scalars, key, hash) else { return nil }
    entries[e].used = frame
    return e
  }

  /// When full: what this frame and the last used is kept (moved to the
  /// front, the table made again), the rest let go; grown if that's half.
  mutating func evict() {
    var k = 0
    for i in 0..<used where entries[i].used + 1 >= frame {
      if i != k { entries.swapAt(i, k) }
      k += 1
    }
    for i in k..<used { entries[i].live = false }
    used = k
    if used * 2 >= capacity {
      capacity *= 2
      table = [Int32](repeating: -1, count: capacity * 2)
    } else {
      for i in table.indices { table[i] = -1 }
    }
    let mask = table.count - 1
    for e in 0..<used {
      var i = Int(truncatingIfNeeded: entries[e].hash) & mask
      while table[i] >= 0 { i = (i + 1) & mask }
      table[i] = Int32(e)
    }
  }

  /// A slot for a new entry (the table made room first if it's full); its
  /// storage reused.
  mutating func insert(_ scalars: some Collection<UInt32>, _ key: TextKey, _ hash: UInt64) -> Int {
    if used >= capacity { evict() }
    let e: Int
    if used < entries.count {
      e = used
    } else {
      entries.append(TextEntry())
      e = entries.count - 1
    }
    used += 1
    inserted &+= 1
    entries[e].hash = hash
    entries[e].key = key
    entries[e].scalars.removeAll(keepingCapacity: true)
    entries[e].scalars.append(contentsOf: scalars)
    entries[e].quads.removeAll(keepingCapacity: true)
    entries[e].carets.removeAll(keepingCapacity: true)
    entries[e].live = true
    entries[e].used = frame
    let mask = table.count - 1
    var i = Int(truncatingIfNeeded: hash) & mask
    while table[i] >= 0 { i = (i + 1) & mask }
    table[i] = Int32(e)
    return e
  }
}

/// The cache, shared by a Painter's copies (they have the same fonts),
/// so measuring (not mutating) keeps what it shapes too.
final class TextCacheBox: @unchecked Sendable {
  var cache = TextCache()
}

extension Painter {
  func textKey(_ kind: UInt8, _ style: Style, x: Float = 0, y: Float = 0) -> TextKey {
    TextKey(kind: kind, font: style.font.rawValue, weight: Int32(style.weight), size: style.textSize * (kind == 0 ? scale : 1),
            lineHeight: style.lineHeight, tracking: style.tracking, uppercase: style.uppercase,
            fractionX: x - wholeBelow(x), fractionY: y - wholeBelow(y))
  }

  var generation: Int { cache.coverage.generation &* 65536 &+ cache.fields.generation }
}

/// The whole number at or below `x` (floor; tier 0 links no libm).
func wholeBelow(_ x: Float) -> Float {
  let t = Float(Int(x))
  return t > x ? t - 1 : t
}
