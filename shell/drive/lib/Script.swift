// SPDX-License-Identifier: BSD-3-Clause

// drive(1)'s scripts: a step a line, as a user's hands would do it at the
// input class's boundary (the pointer to the mouse service's mousein, keys
// to kbdfs's kbin), and the measures between them (Radharc's frames and
// the processes' CPU time). Parsed here, run by bin/drive.

/// A pointer button, as mousein's bits have it (Plan 9's: 1 left, 2
/// middle, 4 right).
public enum Button: Int32, Equatable, Sendable {
  case left = 1, middle = 2, right = 4

  init?(_ word: String) {
    switch true {
    case same(word, "left"): self = .left
    case same(word, "middle"): self = .middle
    case same(word, "right"): self = .right
    default: return nil
    }
  }
}

/// One line of a script.
public enum Step: Equatable, Sendable {
  /// The pointer to (x, y), in the screen's pixels, the buttons as held.
  case move(Int32, Int32)
  case press(Button)
  case release(Button)
  /// A press and release, after moving there if a place is given.
  case click(Button, Int32?, Int32?)
  /// Each key pressed and released in turn: HID usages, or a chord's
  /// (`ctrl+w`), held in order and released in reverse.
  case keys([[UInt8]])
  /// Text typed: each character's usage and whether it needs shift.
  case type([(usage: UInt8, shift: Bool)])
  case wait(Int)
  /// Until Radharc composes no frame for `quiet` ms (at most `limit`):
  /// the time from the last input to its last frame, and what it cost.
  case settle(quiet: Int, limit: Int)
  /// Until a window with this title is on the screen (at most `limit` ms).
  case waitFor(String, limit: Int)
  /// Until no window with this title is (at most `limit` ms).
  case waitGone(String, limit: Int)
  case mark(String)
  /// Keys typed into the focused window, `count`, each timed by Radharc
  /// until drawn and until shown (its status's `key draw`): the
  /// terminal.key_draw and key_glass budgets, named with `theme` if given.
  case keyDraw(count: Int, theme: String?)
  /// `app` started through the launcher until Radharc shows its first
  /// frame (its status's `first frame at`): desktop.cold_start.
  case coldStart(app: String, theme: String?)
  /// Super-Shift-T pressed `count` times, each switch of the shown
  /// workspace between tile and space timed by Radharc until its frames
  /// are on the glass (its status's `switch`): desktop.mode_switch.
  case modeSwitch(count: Int)

  public static func == (a: Step, b: Step) -> Bool {
    switch (a, b) {
    case (.move(let x, let y), .move(let u, let v)): x == u && y == v
    case (.press(let p), .press(let q)), (.release(let p), .release(let q)): p == q
    case (.click(let p, let x, let y), .click(let q, let u, let v)): p == q && x == u && y == v
    case (.keys(let k), .keys(let l)): k.count == l.count && zip(k, l).allSatisfy { $0 == $1 }
    case (.type(let t), .type(let u)): t.count == u.count && zip(t, u).allSatisfy { $0.usage == $1.usage && $0.shift == $1.shift }
    case (.wait(let m), .wait(let n)): m == n
    case (.settle(let q, let l), .settle(let r, let m)): q == r && l == m
    case (.waitFor(let s, let l), .waitFor(let t, let m)), (.waitGone(let s, let l), .waitGone(let t, let m)):
      same(s, t) && l == m
    case (.mark(let s), .mark(let t)): same(s, t)
    case (.keyDraw(let n, let s), .keyDraw(let m, let t)): n == m && same(s ?? "", t ?? "") && (s == nil) == (t == nil)
    case (.coldStart(let a, let s), .coldStart(let b, let t)): same(a, b) && same(s ?? "", t ?? "") && (s == nil) == (t == nil)
    case (.modeSwitch(let n), .modeSwitch(let m)): n == m
    default: false
    }
  }

  /// A script line's step: nil for a blank line or a comment (`#`).
  /// Throws the line's fault.
  public static func parse(_ line: String) throws(ScriptError) -> Step? {
    let w = words(line)
    guard let verb = w.first, verb.utf8.first != 0x23 else { return nil }
    func int(_ i: Int) throws(ScriptError) -> Int32 {
      guard i < w.count, let v = Int32(w[i]), v >= 0 else { throw .badNumber(i < w.count ? w[i] : "") }
      return v
    }
    func button(_ i: Int) throws(ScriptError) -> Button {
      guard i < w.count else { return .left }
      guard let b = Button(w[i]) else { throw .badButton(w[i]) }
      return b
    }
    switch true {
    case same(verb, "move"):
      guard w.count == 3 else { throw .usage("move X Y") }
      return .move(try int(1), try int(2))
    case same(verb, "press"): return .press(try button(1))
    case same(verb, "release"): return .release(try button(1))
    case same(verb, "click"), same(verb, "rightclick"):
      var b = Button.left
      if same(verb, "rightclick") { b = .right } else if w.count == 2 || w.count == 4 { b = try button(1) }
      let at = w.count == 4 ? 2 : (w.count == 3 ? 1 : -1)
      if at < 0 { return .click(b, nil, nil) }
      return .click(b, try int(at), try int(at + 1))
    case same(verb, "key"):
      guard w.count > 1 else { throw .usage("key NAME ...") }
      var chords: [[UInt8]] = []
      for word in w.dropFirst() {
        var chord: [UInt8] = []
        for part in word.utf8.split(separator: 0x2B, omittingEmptySubsequences: false) {  // +
          let name = String(decoding: part, as: UTF8.self)
          guard let u = Keys.usage(name) else { throw .badKey(name.isEmpty ? word : name) }
          chord.append(u)
        }
        guard !chord.isEmpty else { throw .badKey(word) }
        chords.append(chord)
      }
      return .keys(chords)
    case same(verb, "type"):
      let text = rest(line, after: 1)
      var out: [(usage: UInt8, shift: Bool)] = []
      for c in text.utf8 {
        guard let k = Keys.character(c) else { throw .badKey(String(decoding: [c], as: UTF8.self)) }
        out.append(k)
      }
      return .type(out)
    case same(verb, "wait"):
      guard w.count == 2 else { throw .usage("wait MS") }
      return .wait(Int(try int(1)))
    case same(verb, "settle"):
      return .settle(quiet: w.count > 1 ? Int(try int(1)) : 300, limit: w.count > 2 ? Int(try int(2)) : 10_000)
    case same(verb, "waitfor"), same(verb, "waitgone"):
      guard w.count >= 2 else { throw .usage("\(verb) TITLE [MS]") }
      var title = rest(line, after: 1), limit = 10_000
      if w.count >= 3, let ms = Int(w[w.count - 1]) {
        title = w[1..<(w.count - 1)].joined(separator: " ")
        limit = ms
      }
      return same(verb, "waitfor") ? .waitFor(title, limit: limit) : .waitGone(title, limit: limit)
    case same(verb, "mark"): return .mark(rest(line, after: 1))
    case same(verb, "keydraw"):
      guard w.count == 2 || w.count == 3 else { throw .usage("keydraw COUNT [THEME]") }
      return .keyDraw(count: Int(try int(1)), theme: w.count == 3 ? w[2] : nil)
    case same(verb, "coldstart"):
      guard w.count == 2 || w.count == 3 else { throw .usage("coldstart APP [THEME]") }
      return .coldStart(app: w[1], theme: w.count == 3 ? w[2] : nil)
    case same(verb, "modeswitch"):
      guard w.count == 2 else { throw .usage("modeswitch COUNT") }
      return .modeSwitch(count: Int(try int(1)))
    default: throw .unknown(verb)
    }
  }
}

public enum ScriptError: Error, Equatable {
  case unknown(String)
  case usage(String)
  case badNumber(String)
  case badButton(String)
  case badKey(String)

  public var text: String {
    switch self {
    case .unknown(let v): "no step '\(v)'"
    case .usage(let u): "usage: \(u)"
    case .badNumber(let n): "'\(n)' isn't a number of pixels or milliseconds"
    case .badButton(let b): "no button '\(b)' (left, middle, right)"
    case .badKey(let k): "no key '\(k)'"
    }
  }
}

/// Keys by name, as HID's usages (page 7).
public enum Keys {
  static let named: [(String, UInt8)] = [
    ("enter", 0x28), ("return", 0x28), ("esc", 0x29), ("escape", 0x29), ("backspace", 0x2A), ("tab", 0x2B),
    ("space", 0x2C), ("right", 0x4F), ("left", 0x50), ("down", 0x51), ("up", 0x52), ("home", 0x4A), ("end", 0x4D),
    ("pageup", 0x4B), ("pagedown", 0x4E), ("delete", 0x4C), ("ctrl", 0xE0), ("shift", 0xE1), ("alt", 0xE2),
    ("super", 0xE3),
  ]

  /// `a`-`z`, `0`-`9`, `f1`-`f12`, or a name above.
  public static func usage(_ name: String) -> UInt8? {
    let b = Array(name.utf8)
    if b.count == 1, let k = character(b[0]), !k.shift { return k.usage }
    if b.count >= 2, b.count <= 3, b[0] == 0x66, let n = Int(String(decoding: b[1...], as: UTF8.self)), n >= 1, n <= 12 {
      return 0x3A + UInt8(n - 1)
    }
    return named.first { same($0.0, name) }?.1
  }

  /// A character's key on a US keyboard, and whether it needs shift.
  public static func character(_ c: UInt8) -> (usage: UInt8, shift: Bool)? {
    switch c {
    case 0x61...0x7A: (0x04 + c - 0x61, false)
    case 0x41...0x5A: (0x04 + c - 0x41, true)
    case 0x31...0x39: (0x1E + c - 0x31, false)
    case 0x30: (0x27, false)
    case 0x20: (0x2C, false)
    case 0x2D: (0x2D, false)  // -
    case 0x2E: (0x37, false)  // .
    case 0x2F: (0x38, false)  // /
    case 0x2C: (0x36, false)  // ,
    case 0x5F: (0x2D, true)  // _
    default: nil
    }
  }
}

/// Radharc's status, as the budgets read it.
public enum RadharcStatus {
  /// `key draw <us> us most <us> us shown <n> frames most <n> timed <n>`:
  /// the last key's draw in µs, the frames until it was shown, and how
  /// many keys have been timed.
  public static func keyDraw(_ status: String) -> (micros: Int64, frames: Int, timed: Int)? {
    for line in status.utf8.split(separator: 0x0A) {
      let w = words(String(decoding: line, as: UTF8.self))
      guard w.count >= 14, same(w[0], "key"), same(w[1], "draw"), same(w[7], "shown"), same(w[12], "timed"),
        let us = Int64(w[2]), let frames = Int(w[8]), let timed = Int(w[13])
      else { continue }
      return (us, frames, timed)
    }
    return nil
  }

  /// `theme <name> variant <variant>`: the theme in force.
  public static func theme(_ status: String) -> String? {
    for line in status.utf8.split(separator: 0x0A) {
      let w = words(String(decoding: line, as: UTF8.self))
      if w.count >= 2, same(w[0], "theme") { return w[1] }
    }
    return nil
  }

  /// `switch <n> frames switches <n>`: the frames the last mode switch of
  /// the shown workspace took to be on the glass, and how many were timed.
  /// (`theme switch ...` is the theme's.)
  public static func modeSwitch(_ status: String) -> (frames: Int, switches: Int)? {
    for line in status.utf8.split(separator: 0x0A) {
      let w = words(String(decoding: line, as: UTF8.self))
      guard w.count >= 5, same(w[0], "switch"), same(w[2], "frames"), same(w[3], "switches"),
        let frames = Int(w[1]), let switches = Int(w[4])
      else { continue }
      return (frames, switches)
    }
    return nil
  }

  /// `first frame at <ns> <title>`: when the window last shown for the
  /// first time was, and its title.
  public static func firstFrame(_ status: String) -> (at: Int64, title: String)? {
    for line in status.utf8.split(separator: 0x0A) {
      let w = words(String(decoding: line, as: UTF8.self))
      guard w.count >= 5, same(w[0], "first"), same(w[1], "frame"), same(w[2], "at"), let at = Int64(w[3]) else {
        continue
      }
      return (at, w[4...].joined(separator: " "))
    }
    return nil
  }
}

/// A budget line as the boot tests print them and vx bench reads them.
public func budgetLine(_ name: String, theme: String?, value: Int64, unit: String, limit: Int64?) -> String {
  "budget name=\(name)\(theme.map { "." + $0 } ?? "") value=\(value) unit=\(unit)"
    + (limit.map { " limit=\($0)" } ?? "")
}

/// What settling saw: Radharc's frame count sampled over time.
public struct Settling: Sendable {
  public let start: Int64
  public let frames0: Int
  public private(set) var lastFrame: Int64
  /// When the first frame after the start came (the start, if none has).
  public private(set) var firstFrame: Int64
  public private(set) var frames: Int

  public init(start: Int64, frames: Int) {
    self.start = start
    frames0 = frames
    lastFrame = start
    firstFrame = start
    self.frames = frames
  }

  /// How long the input's first frame is waited for, in ns: an app slower
  /// to answer than the quiet time would otherwise read as no frame.
  public static let firstFrame: Int64 = 2_000_000_000

  /// A sample at `now` of Radharc's `frames`; whether the screen has
  /// settled: quiet for `quiet` ns since its last frame, once a first frame
  /// has come, or no frame at all within `firstFrame`.
  public mutating func sample(now: Int64, frames f: Int, quiet: Int64) -> Bool {
    if f != frames {
      if frames == frames0 { firstFrame = now }
      frames = f
      lastFrame = now
    }
    if composed == 0 { return now - start >= max(quiet, Self.firstFrame) }
    return now - lastFrame >= quiet
  }

  /// Frames composed since the start.
  public var composed: Int { frames - frames0 }
  /// From the start to the last frame, in ns.
  public var busy: Int64 { lastFrame - start }
  /// From the start to the first frame, in ns (0 if none came).
  public var answered: Int64 { firstFrame - start }
}

/// `line`'s words: bytes split at spaces and tabs (never Characters, whose
/// rules would bring in the Unicode tables).
public func words(_ line: String) -> [String] {
  line.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 }).map { String(decoding: $0, as: UTF8.self) }
}

/// What follows the first `n` words of `line`, its spaces kept.
func rest(_ line: String, after n: Int) -> String {
  var b = Array(line.utf8)[...]
  for _ in 0..<n {
    while let f = b.first, f == 0x20 || f == 0x09 { b = b.dropFirst() }
    while let f = b.first, f != 0x20 && f != 0x09 { b = b.dropFirst() }
  }
  while let f = b.first, f == 0x20 || f == 0x09 { b = b.dropFirst() }
  return String(decoding: b, as: UTF8.self)
}

/// Whether two strings' bytes are the same.
public func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
