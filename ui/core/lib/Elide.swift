// SPDX-License-Identifier: BSD-3-Clause

// Elision (M6i part 3, sdk.md §10, decided 2026-10-10): a label that
// doesn't fit loses its middle by default, so both ends stay readable,
// and a file name keeps its extension ("virtio-v1.3…csd01.pdf", as the
// storyboard shows); end elision is an option, for prose. Text is cut
// only between grapheme clusters (UAX #29), and the result, ellipsis
// included, is never wider than asked.

import TDUnicode

public enum Elision: Sendable {
  case middle
  case end
}

extension Painter {
  /// `text` in `style`, elided to fit `width` logical pixels.
  public func elide(_ text: String, _ style: Style, width: Float, _ mode: Elision = .middle) -> String {
    if measure(text, style) <= width { return text }
    let scalars = text.unicodeScalars.map { $0.value }
    // Grapheme clusters, as ranges of scalars.
    let bounds = Segmentation.graphemeBoundaries(scalars)
    var clusters: [Range<Int>] = []
    var start = 0
    for b in bounds where b > start {
      clusters.append(start..<b)
      start = b
    }
    let n = clusters.count
    func string(_ r: Range<Int>) -> String {
      var s = ""
      s.unicodeScalars.append(contentsOf: scalars[r].compactMap { Unicode.Scalar($0) })
      return s
    }
    func head(_ k: Int) -> String { k == 0 ? "" : string(0..<clusters[k - 1].upperBound) }
    func tail(_ k: Int) -> String { k == 0 ? "" : string(clusters[n - k].lowerBound..<scalars.count) }
    // The extension's clusters, kept whole where they fit: from the last
    // dot, if it's near the end and not the first character.
    var ext = 0
    if mode == .middle, let dot = scalars.lastIndex(of: 0x2E), dot > 0, scalars.count - dot <= 8 {
      ext = clusters.count - (clusters.firstIndex { $0.contains(dot) } ?? n)
    }
    func candidate(_ k: Int) -> String {
      switch mode {
      case .end: return head(k) + "…"
      case .middle:
        // The tail takes the extension and its share of the rest.
        let t = min(k, max(ext, k / 2)), h = k - t
        return head(h) + "…" + tail(t)
      }
    }
    // The most clusters that fit (a binary search: widths grow with k).
    var lo = 0, hi = n - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if measure(candidate(mid), style) <= width { lo = mid } else { hi = mid - 1 }
    }
    let result = candidate(lo)
    return measure(result, style) <= width ? result : ""
  }
}
