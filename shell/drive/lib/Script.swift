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
  case mark(String)

  public static func == (a: Step, b: Step) -> Bool {
    switch (a, b) {
    case (.move(let x, let y), .move(let u, let v)): x == u && y == v
    case (.press(let p), .press(let q)), (.release(let p), .release(let q)): p == q
    case (.click(let p, let x, let y), .click(let q, let u, let v)): p == q && x == u && y == v
    case (.keys(let k), .keys(let l)): k.count == l.count && zip(k, l).allSatisfy { $0 == $1 }
    case (.type(let t), .type(let u)): t.count == u.count && zip(t, u).allSatisfy { $0.usage == $1.usage && $0.shift == $1.shift }
    case (.wait(let m), .wait(let n)): m == n
    case (.settle(let q, let l), .settle(let r, let m)): q == r && l == m
    case (.waitFor(let s, let l), .waitFor(let t, let m)): same(s, t) && l == m
    case (.mark(let s), .mark(let t)): same(s, t)
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
    case same(verb, "waitfor"):
      guard w.count >= 2 else { throw .usage("waitfor TITLE [MS]") }
      if w.count >= 3, let ms = Int(w[w.count - 1]) {
        return .waitFor(w[1..<(w.count - 1)].joined(separator: " "), limit: ms)
      }
      return .waitFor(rest(line, after: 1), limit: 10_000)
    case same(verb, "mark"): return .mark(rest(line, after: 1))
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

/// What settling saw: Radharc's frame count sampled over time.
public struct Settling: Sendable {
  public let start: Int64
  public let frames0: Int
  public private(set) var lastFrame: Int64
  public private(set) var frames: Int

  public init(start: Int64, frames: Int) {
    self.start = start
    frames0 = frames
    lastFrame = start
    self.frames = frames
  }

  /// A sample at `now` of Radharc's `frames`; whether the screen has been
  /// quiet for `quiet` ns since its last frame.
  public mutating func sample(now: Int64, frames f: Int, quiet: Int64) -> Bool {
    if f != frames {
      frames = f
      lastFrame = now
    }
    return now - lastFrame >= quiet
  }

  /// Frames composed since the start.
  public var composed: Int { frames - frames0 }
  /// From the start to the last frame, in ns.
  public var busy: Int64 { lastFrame - start }
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
