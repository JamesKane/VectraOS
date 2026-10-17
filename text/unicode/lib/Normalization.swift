// SPDX-License-Identifier: BSD-3-Clause

// Unicode normalization and case folding (UAX #15; UCD CaseFolding.txt),
// from the tables ucdgen writes. Tier 0: plain arrays and binary search,
// no hashing, no Foundation.

/// UTF-8 in and out, strictly: no overlong forms, no surrogates, nothing
/// past U+10FFFF (RFC 3629).
public enum UTF8Text {
  /// The scalars of `bytes`, or nil if it isn't valid UTF-8.
  public static func decode(_ bytes: [UInt8]) -> [UInt32]? {
    var out: [UInt32] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
      let b0 = UInt32(bytes[i])
      let (count, minimum): (Int, UInt32)
      var cp: UInt32
      switch b0 {
      case 0..<0x80:
        out.append(b0)
        i += 1
        continue
      case 0xC2..<0xE0: (count, minimum, cp) = (2, 0x80, b0 & 0x1F)
      case 0xE0..<0xF0: (count, minimum, cp) = (3, 0x800, b0 & 0x0F)
      case 0xF0..<0xF5: (count, minimum, cp) = (4, 0x10000, b0 & 0x07)
      default: return nil
      }
      guard i + count <= bytes.count else { return nil }
      for k in 1..<count {
        let b = UInt32(bytes[i + k])
        guard b & 0xC0 == 0x80 else { return nil }
        cp = cp << 6 | (b & 0x3F)
      }
      guard cp >= minimum, cp <= 0x10FFFF, !(0xD800...0xDFFF).contains(cp) else { return nil }
      out.append(cp)
      i += count
    }
    return out
  }

  public static func encode(_ scalars: [UInt32]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(scalars.count)
    for c in scalars {
      switch c {
      case 0..<0x80: out.append(UInt8(c))
      case 0x80..<0x800: out += [UInt8(0xC0 | c >> 6), UInt8(0x80 | c & 0x3F)]
      case 0x800..<0x10000: out += [UInt8(0xE0 | c >> 12), UInt8(0x80 | c >> 6 & 0x3F), UInt8(0x80 | c & 0x3F)]
      default:
        out += [UInt8(0xF0 | c >> 18), UInt8(0x80 | c >> 12 & 0x3F), UInt8(0x80 | c >> 6 & 0x3F), UInt8(0x80 | c & 0x3F)]
      }
    }
    return out
  }
}

public enum Normalization {
  // Hangul syllables are composed and decomposed by formula (Unicode §3.12).
  static let sBase: UInt32 = 0xAC00, lBase: UInt32 = 0x1100, vBase: UInt32 = 0x1161, tBase: UInt32 = 0x11A7
  static let lCount: UInt32 = 19, vCount: UInt32 = 21, tCount: UInt32 = 28
  static let nCount = vCount * tCount, sCount = lCount * vCount * tCount

  /// A code point's canonical combining class.
  public static func combiningClass(_ c: UInt32) -> UInt8 {
    let t = Tables.combiningClass
    var lo = 0, hi = t.count / 3
    while lo < hi {
      let mid = (lo + hi) / 2
      if t[mid * 3 + 1] < c { lo = mid + 1 } else { hi = mid }
    }
    return lo < t.count / 3 && t[lo * 3] <= c ? UInt8(t[lo * 3 + 2]) : 0
  }

  /// The index of `c` in a sorted table, if it's there.
  static func find(_ c: UInt32, in keys: [UInt32]) -> Int? {
    var lo = 0, hi = keys.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if keys[mid] < c { lo = mid + 1 } else { hi = mid }
    }
    return lo < keys.count && keys[lo] == c ? lo : nil
  }

  /// Normalization Form D: canonical decomposition, then canonical order.
  public static func nfd(_ scalars: [UInt32]) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(scalars.count)
    for c in scalars {
      if c >= sBase && c < sBase + sCount {
        let s = c - sBase
        out.append(lBase + s / nCount)
        out.append(vBase + (s % nCount) / tCount)
        if s % tCount != 0 { out.append(tBase + s % tCount) }
      } else if let i = find(c, in: Tables.decompositionKeys) {
        let starts = Tables.decompositionStarts
        for k in Int(starts[i])..<Int(starts[i + 1]) { out.append(Tables.decompositionData[k]) }
      } else {
        out.append(c)
      }
    }
    // Canonical ordering: within each run of nonzero classes, a stable sort
    // by class (insertion sort: runs are short).
    var i = 1
    while i < out.count {
      let cc = combiningClass(out[i])
      if cc != 0 {
        var j = i
        while j > 0 {
          let prev = combiningClass(out[j - 1])
          guard prev > cc else { break }
          out.swapAt(j, j - 1)
          j -= 1
        }
      }
      i += 1
    }
    return out
  }

  /// One level of a code point's canonical decomposition: its mapping's
  /// two code points (or one, for a singleton), Hangul's by formula (LV to
  /// L V, LVT to LV T); nil if it has none.
  public static func decomposeOnce(_ c: UInt32) -> (UInt32, UInt32?)? {
    if c >= sBase && c < sBase + sCount {
      let s = c - sBase
      if s % tCount != 0 { return (c - s % tCount, tBase + s % tCount) }
      return (lBase + s / nCount, vBase + (s % nCount) / tCount)
    }
    guard let i = find(c, in: Tables.decomposeOnceKeys) else { return nil }
    let second = Tables.decomposeOnceSecond[i]
    return (Tables.decomposeOnceFirst[i], second == 0 ? nil : second)
  }

  /// The primary composite of `a` and `b`, if there is one.
  public static func compose(_ a: UInt32, _ b: UInt32) -> UInt32? {
    // L + V, and LV + T, by formula.
    if a >= lBase && a < lBase + lCount && b >= vBase && b < vBase + vCount {
      return sBase + ((a - lBase) * vCount + (b - vBase)) * tCount
    }
    if a >= sBase && a < sBase + sCount && (a - sBase) % tCount == 0 && b > tBase && b < tBase + tCount {
      return a + (b - tBase)
    }
    let key = UInt64(a) << 21 | UInt64(b)
    let pairs = Tables.compositionPairs
    var lo = 0, hi = pairs.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if pairs[mid] < key { lo = mid + 1 } else { hi = mid }
    }
    return lo < pairs.count && pairs[lo] == key ? Tables.compositionResults[lo] : nil
  }

  /// Normalization Form C: NFD, then canonical composition (UAX #15 §3,
  /// D117): each character joins the last starter unless something between
  /// them blocks it (a class of 0, or one at least its own).
  public static func nfc(_ scalars: [UInt32]) -> [UInt32] {
    let d = nfd(scalars)
    var out: [UInt32] = []
    out.reserveCapacity(d.count)
    var starter: Int? = nil
    var lastClass: UInt8 = 0  // of the last character appended
    for c in d {
      let cc = combiningClass(c)
      if let s = starter {
        let adjacent = out.count - 1 == s
        if adjacent || (lastClass != 0 && lastClass < cc), let composite = compose(out[s], c) {
          out[s] = composite
          continue
        }
      }
      if cc == 0 { starter = out.count }
      lastClass = cc
      out.append(c)
    }
    return out
  }
}

public enum CaseFolding {
  /// Full case folding (statuses C and F of CaseFolding.txt): "ß" to "ss",
  /// "Σ", "σ" and "ς" all to "σ".
  public static func fold(_ scalars: [UInt32]) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(scalars.count)
    for c in scalars {
      if let i = Normalization.find(c, in: Tables.foldKeys) {
        let starts = Tables.foldStarts
        for k in Int(starts[i])..<Int(starts[i + 1]) { out.append(Tables.foldData[k]) }
      } else {
        out.append(c)
      }
    }
    return out
  }
}

/// What Taisce stores and compares strings as.
public enum CaseMapping {
  /// Full uppercasing (Unicode's default, without a language's tailoring):
  /// ß is SS, ŉ is ʼN.
  public static func uppercase(_ scalars: [UInt32]) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(scalars.count)
    for c in scalars {
      if let i = Normalization.find(c, in: Tables.upperKeys) {
        let starts = Tables.upperStarts
        for k in Int(starts[i])..<Int(starts[i + 1]) { out.append(Tables.upperData[k]) }
      } else {
        out.append(c)
      }
    }
    return out
  }
}

public enum Text {
  /// `utf8` in NFC, or nil if it isn't valid UTF-8 (filesystem.md §6:
  /// string attributes are normalized).
  public static func normalized(_ utf8: [UInt8]) -> [UInt8]? {
    guard let s = UTF8Text.decode(utf8) else { return nil }
    return UTF8Text.encode(Normalization.nfc(s))
  }

  /// The key for caseless matching (the `~=` operator, case-folded
  /// indices): canonical caseless matching, D145, NFD(fold(NFD(x))), here
  /// in NFC.
  public static func caselessKey(_ utf8: [UInt8]) -> [UInt8]? {
    guard let s = UTF8Text.decode(utf8) else { return nil }
    return UTF8Text.encode(Normalization.nfc(CaseFolding.fold(Normalization.nfd(s))))
  }
}
