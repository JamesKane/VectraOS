// SPDX-License-Identifier: BSD-3-Clause

// crash-test's plan (crash-test(8)): what file n holds, and how a volume
// found after a power cut is judged. File `f<n>` is CrashPlan.size(n)
// bytes of a pattern seeded by n, written in pieces of at most 32 KiB; a
// group is committed after every eight files, and fs(4) commits on its
// own a second after a change. After a cut each file is whole (its bytes,
// all of them), partial (a correct start, its later pieces in groups that
// didn't commit), empty (made, nothing written yet) or wrong.
// Groups commit in order, so the whole files run unbroken from f0: one
// after a file that isn't whole means a later group landed without an
// earlier one.

public enum CrashPlan {
  /// Files a group: a commit after every this many.
  public static let perGroup = 8

  /// File n's size: 4 KiB to 256 KiB, in pages.
  public static func size(_ n: Int) -> Int { 4096 * (1 + (n &* 7919) % 64) }

  /// File n's bytes, `count` of them from `offset`: an xorshift stream
  /// seeded by n.
  public static func bytes(_ n: Int, offset: Int = 0, count: Int) -> [UInt8] {
    var s = UInt64(truncatingIfNeeded: n &+ 1) &* 0x9E37_79B9_7F4A_7C15 | 1
    var out = [UInt8](repeating: 0, count: count)
    var word: UInt64 = 0
    for i in 0..<(offset + count) {
      if i % 8 == 0 {
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        word = s
      }
      if i >= offset { out[i - offset] = UInt8(truncatingIfNeeded: word >> UInt64(8 * (i % 8))) }
    }
    return out
  }

  public enum Found: Equatable, Sendable {
    case whole, partial, empty, wrong
  }

  /// What was found, and whether it's a volume a crash may leave.
  public struct Verdict: Equatable, Sendable {
    /// Whole files in a row from f0.
    public var whole = 0
    /// Partial or empty: allowed past the whole ones.
    public var empty = 0
    public var wrong = 0
    /// Whole files after one that wasn't.
    public var wholeAfterGap = 0
    public var passed: Bool { wrong == 0 && wholeAfterGap == 0 }

    public init(whole: Int = 0, empty: Int = 0, wrong: Int = 0, wholeAfterGap: Int = 0) {
      self.whole = whole
      self.empty = empty
      self.wrong = wrong
      self.wholeAfterGap = wholeAfterGap
    }

    public var text: String {
      "\(whole) whole in a row from f0, \(empty) partial or empty, \(wrong) wrong, \(wholeAfterGap) whole after a gap: "
        + (passed ? "passed" : "FAILED")
    }
  }

  /// The files found, f0 on in order, up to the last there.
  public static func judge(_ found: [Found]) -> Verdict {
    var v = Verdict()
    var gap = false
    for f in found {
      switch f {
      case .whole:
        if gap { v.wholeAfterGap += 1 } else { v.whole += 1 }
      case .empty, .partial:
        v.empty += 1
        gap = true
      case .wrong:
        v.wrong += 1
        gap = true
      }
    }
    return v
  }
}
