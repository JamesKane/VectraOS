// SPDX-License-Identifier: BSD-3-Clause

// wctl's verbs (rio(4)), parsed as 9front's rio parses them (wctl.c's
// parsewctl): a verb, then parameters, each a name and maybe a number,
// `+n` and `-n` relative to the window's rectangle. `new` takes a command
// after them, run by `rc -c` (or `rc -i` if there is none). Rectangles
// are the window's content on the screen, kept on it. `bottom` is
// refused: Radharc never lowers a window beneath another.

public struct WctlRect: Equatable, Sendable {
  public var minX: Int
  public var minY: Int
  public var maxX: Int
  public var maxY: Int
  public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
    (self.minX, self.minY, self.maxX, self.maxY) = (minX, minY, maxX, maxY)
  }
  public var width: Int { maxX - minX }
  public var height: Int { maxY - minY }
}

public enum WctlVerb: String, CaseIterable, Sendable {
  case new, resize, move, scroll, noscroll, set, top, bottom, current, hide, unhide, delete
}

public struct WctlCommand: Equatable, Sendable {
  public var verb: WctlVerb
  /// The rectangle it asks for (the window's own if it names none).
  public var rect: WctlRect
  /// `-id`: another window of rio's.
  public var id: Int?
  /// `new`: opened hidden (`-hide`), scrolling or not, in `-cd`'s
  /// directory, running `command` (empty: an interactive rc).
  public var hidden = false
  public var scrolling: Bool?
  public var directory: String?
  public var command = ""
}

public struct WctlError: Error, Equatable, Sendable {
  public var message: String
  init(_ m: String) { message = m }
}

public enum Wctl {
  static let parameters = ["-cd", "-dx", "-dy", "-hide", "-id", "-maxx", "-maxy", "-minx", "-miny", "-pid", "-r",
                           "-scroll", "-noscroll"]

  /// A new window's place: 600 by 400 or what fits, cascading 16 points
  /// for each of ten (`cascade`), as rio's newrect.
  public static func newRect(screen: WctlRect, cascade: Int) -> WctlRect {
    let dx = min(600, screen.width - 8), dy = min(400, screen.height - 8)
    let at = 32 + 16 * (cascade % 10)
    return WctlRect(minX: screen.minX + at, minY: screen.minY + at, maxX: screen.minX + at + dx, maxY: screen.minY + at + dy)
  }

  /// `text`, written to the wctl of a window at `rect` (nil: rio's own
  /// wctl, which only takes `new`) on `screen`.
  public static func parse(_ text: String, rect: WctlRect?, screen: WctlRect, cascade: Int = 0) throws(WctlError)
    -> WctlCommand
  {
    var s = Substring(text)
    func skipSpace() { s = s.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" } }
    /// The next word, if it begins with one of `table`'s.
    func word(_ table: [String]) -> String? {
      skipSpace()
      let token = s.prefix { $0 != " " && $0 != "\t" && $0 != "\n" && $0 != "\r" }
      guard let w = table.first(where: { token.hasPrefix($0) }) else { return nil }
      s = s.dropFirst(token.count)
      return w
    }
    /// A number, with rio's square brackets allowed around it.
    func number() -> Int? {
      s = s.drop { $0 == " " || $0 == "\t" || $0 == "[" }
      let digits = s.prefix { $0 == "-" || ($0 >= "0" && $0 <= "9") }
      guard let n = Int(digits) else { return nil }
      s = s.dropFirst(digits.count).drop { $0 == "]" }
      return n
    }
    guard let v = word(WctlVerb.allCases.map { $0.rawValue }), let verb = WctlVerb(rawValue: v) else {
      throw WctlError("unrecognized wctl command")
    }
    var r = verb == .new ? newRect(screen: screen, cascade: cascade) : rect ?? WctlRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
    var c = WctlCommand(verb: verb, rect: r)
    let bad = WctlError("missing or bad wctl parameter")
    while let p = word(parameters) {
      switch p {
      case "-hide":
        c.hidden = true
        continue
      case "-scroll":
        c.scrolling = true
        continue
      case "-noscroll":
        c.scrolling = false
        continue
      case "-r":
        guard let x0 = number(), let y0 = number(), let x1 = number(), let y1 = number() else { throw bad }
        r = WctlRect(minX: x0, minY: y0, maxX: x1, maxY: y1)
        continue
      default: break
      }
      skipSpace()
      if p == "-cd" {
        var d = s.prefix { $0 != " " && $0 != "\t" && $0 != "\n" }
        guard !d.isEmpty else { throw bad }
        s = s.dropFirst(d.count)
        if d.count >= 2 && d.first == "'" && d.last == "'" { d = d.dropFirst().dropLast() }
        c.directory = String(d)
        continue
      }
      var sign = 0
      if s.first == "-" {
        sign = -1
        s = s.dropFirst()
      } else if s.first == "+" {
        sign = 1
        s = s.dropFirst()
      }
      guard let f = s.first, f >= "0" && f <= "9", let n = number() else { throw bad }
      func set(_ old: Int, _ abs: Int) -> Int { sign < 0 ? old - n : sign > 0 ? old + n : abs }
      switch p {
      case "-minx": r.minX = set(r.minX, n)
      case "-miny": r.minY = set(r.minY, n)
      case "-maxx": r.maxX = set(r.maxX, n)
      case "-maxy": r.maxY = set(r.maxY, n)
      case "-dx": r.maxX = sign < 0 ? r.maxX - n : sign > 0 ? r.maxX + n : r.minX + n
      case "-dy": r.maxY = sign < 0 ? r.maxY - n : sign > 0 ? r.maxY + n : r.minY + n
      case "-id": c.id = n
      default: break  // -pid: rio's `set`, for notes; this rio knows its programs
      }
    }
    skipSpace()
    if verb != .new && !s.isEmpty { throw WctlError("extraneous text in wctl message") }
    if verb == .new { c.command = String(s) }
    if rect == nil && verb != .new { throw WctlError("command needs to be run within a window") }
    if verb == .move, let old = rect {
      r = WctlRect(minX: r.minX, minY: r.minY, maxX: r.minX + old.width, maxY: r.minY + old.height)
    }
    r = onScreen(r, screen)
    if [.new, .move, .resize].contains(verb) && !good(r, screen) { throw WctlError("bad rectangle in wctl request") }
    if verb == .bottom { throw WctlError("bottom: a window can't be lowered beneath another") }
    c.rect = r
    return c
  }

  /// `r` moved onto the screen, as rio's rectonscreen (shrunk if it must).
  static func onScreen(_ r: WctlRect, _ screen: WctlRect) -> WctlRect {
    func shift(_ lo: Int, _ hi: Int, _ min: Int, _ max: Int) -> (Int, Int) {
      var (lo, hi) = (lo, hi)
      if hi > max {
        lo += max - hi
        hi = max
      }
      if lo < min {
        hi += min - lo
        if hi > max { hi = max }
        lo = min
      }
      return (lo, hi)
    }
    let (x0, x1) = shift(r.minX, r.maxX, screen.minX, screen.maxX)
    let (y0, y1) = shift(r.minY, r.maxY, screen.minY, screen.maxY)
    return WctlRect(minX: x0, minY: y0, maxX: x1, maxY: y1)
  }

  /// A size a window can have, as rio's goodrect: at least 100 wide and a
  /// line high, at most three screens, on the screen.
  static func good(_ r: WctlRect, _ screen: WctlRect) -> Bool {
    r.width >= 100 && r.height >= 24 && r.width <= 3 * screen.width && r.height <= 3 * screen.height
      && r.minX < screen.maxX && r.maxX > screen.minX && r.minY < screen.maxY && r.maxY > screen.minY
  }
}
