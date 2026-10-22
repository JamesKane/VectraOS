// SPDX-License-Identifier: BSD-3-Clause

// Master-stack (dwm's tile), the first layout for Radharc's `tile`
// workspaces (D116): the first `masters` windows share a column on the
// left, `ratio` percent of the width, and the rest share the column on
// the right; with no masters or no others, one column has them all. It
// holds no state: Radharc keeps the order and the parameters and passes
// them in each call, so replacing or restarting it loses nothing.
//
// Verbs: `focus next`, `focus prev`; `swap` (the focused window and the
// first master trade places; the master with the next); `grow`, `shrink`
// (the master column by 5 points, from 10 to 90); `masters +1`, `masters
// -1` (0 to 9).

/// A frame, decorations included.
public struct Frame: Equatable, Sendable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int
  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public enum MasterStack {
  public static let name = "master-stack"

  /// The parameters: `ratio N masters M`, defaults for what's missing or
  /// out of range.
  public struct Params: Equatable, Sendable {
    public var ratio = 55
    public var masters = 1
    public init() {}
    public init(_ text: String) {
      let words = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A })
      var i = 0
      while i + 1 < words.count {
        let key = words[i], value = words[i + 1]
        i += 2
        guard !value.isEmpty, value.count <= 3, value.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { continue }
        let n = value.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        if key.elementsEqual("ratio".utf8), n >= 10, n <= 90 { ratio = n }
        if key.elementsEqual("masters".utf8), n <= 9 { masters = n }
      }
    }
    public var text: String { "ratio \(ratio) masters \(masters)" }
  }

  /// A frame for each of `count` windows in `area`, in order.
  public static func arrange(_ area: Frame, count: Int, _ p: Params) -> [Frame] {
    guard count > 0 else { return [] }
    let m = min(p.masters, count)
    if m == 0 || m == count { return column(area, count) }
    let w = area.width * p.ratio / 100
    return column(Frame(x: area.x, y: area.y, width: w, height: area.height), m)
      + column(Frame(x: area.x + w, y: area.y, width: area.width - w, height: area.height), count - m)
  }

  /// `n` frames stacked in `c`, the last taking what doesn't divide.
  static func column(_ c: Frame, _ n: Int) -> [Frame] {
    let h = c.height / n
    return (0..<n).map { i in
      Frame(x: c.x, y: c.y + i * h, width: c.width, height: i == n - 1 ? c.height - i * h : h)
    }
  }

  /// A verb: the order, the window focused and the parameters after it;
  /// nil if it isn't one.
  public static func act(_ verb: String, windows: [UInt32], focused: UInt32, _ p: Params)
    -> (order: [UInt32], focused: UInt32, params: Params)?
  {
    let words = verb.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    func say(_ i: Int, _ w: String) -> Bool { i < words.count && words[i].utf8.elementsEqual(w.utf8) }
    var order = windows, p = p, focus = focused
    let at = windows.firstIndex(of: focused)
    if words.count == 2 && say(0, "focus") && (say(1, "next") || say(1, "prev")) {
      guard !windows.isEmpty else { return (order, focus, p) }
      let i = at ?? 0
      let step = say(1, "next") ? 1 : windows.count - 1
      focus = windows[(i + step) % windows.count]
    } else if words.count == 1 && say(0, "swap") {
      guard let i = at, windows.count > 1 else { return (order, focus, p) }
      let j = i == 0 ? 1 : 0
      order.swapAt(i, j)
    } else if words.count == 1 && (say(0, "grow") || say(0, "shrink")) {
      p.ratio = min(90, max(10, p.ratio + (say(0, "grow") ? 5 : -5)))
    } else if words.count == 2 && say(0, "masters") && (say(1, "+1") || say(1, "-1")) {
      p.masters = min(9, max(0, p.masters + (say(1, "+1") ? 1 : -1)))
    } else {
      return nil
    }
    return (order, focus, p)
  }
}
