// SPDX-License-Identifier: BSD-3-Clause

// Tversion's negotiation, as version(5) has it: the server answers the
// dialect it speaks of the one asked, or `unknown`, and the smaller
// msize. A dialect is "9P2000" and what follows a period; we speak
// "9P2000.vx" (D78) and plain "9P2000", so "9P2000.u" or "9P2000.L" get
// "9P2000".

public enum Version {
  /// What a server speaking `ours` answers a Tversion's `version` and
  /// `msize` with: the dialect, or "unknown", and the msize; nil if the
  /// msize is too small to carry a message.
  public static func answer(_ version: String, msize: UInt32, ours: UInt32,
                            extended: Bool = true) -> (version: String, msize: UInt32)? {
    let size = min(msize, ours)
    guard size >= NineP.minMessage else { return nil }
    guard let dialect = dialect(version) else { return ("unknown", size) }
    // Bytes, not String's ==, which needs Unicode's tables in Embedded Swift.
    let vx = extended && dialect.utf8.elementsEqual(NineP.extendedVersion.utf8)
    return (vx ? dialect : NineP.version, size)
  }

  /// The dialect a version string names, if it's 9P2000's: "9P2000.vx"
  /// for ours, "9P2000" for the plain one or any other suffix.
  public static func dialect(_ version: String) -> String? {
    let base = Array(NineP.version.utf8)
    let v = Array(version.utf8)
    guard v.count >= base.count, v[0..<base.count].elementsEqual(base) else { return nil }
    if v.count == base.count { return NineP.version }
    guard v[base.count] == UInt8(ascii: ".") else { return nil }
    return v.elementsEqual(NineP.extendedVersion.utf8) ? NineP.extendedVersion : NineP.version
  }
}
