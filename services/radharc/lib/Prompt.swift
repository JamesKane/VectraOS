// SPDX-License-Identifier: BSD-3-Clause

// The trusted prompt (D111, after NeoVectra's winsrv): a question one
// asker writes, which Radharc draws over every window and only the
// user's own keys and pointer answer. Pure: Main reads the devices and
// serves `prompt`; the scene draws what is here.
//
// A question is one ndb(6) entry: `ask=confirm` (allow it or not) or
// `ask=key` (type a key's fields: `user?`, and `!password?`, a secret,
// drawn as bullets), `app=` the app it asks for, `answers=` the answers
// it offers besides deny (once, session, always; once if it says none),
// and what it asks about, shown as written. Questions queue, the oldest
// on screen. A click lands only half a second after its question shows,
// as a key that answers does (so neither aimed at what was there before
// answers it); escape is deny, and in a key's question return is once
// and tab the next field.
//
// It is drawn in no theme's colours: a black strip, a gunmetal seal, a
// panel of its own, the rest of the screen dimmed around it.

import Kbdfs
import Light
import NdbFile

public enum PromptAnswer: Equatable, Sendable {
  case once, session, always, deny

  public var word: String {
    switch self {
    case .once: "once"
    case .session: "session"
    case .always: "always"
    case .deny: "deny"
    }
  }

  /// Its button's label.
  public var label: String {
    switch self {
    case .once: "Once"
    case .session: "This session"
    case .always: "Always"
    case .deny: "Deny"
    }
  }

  init?(word: String) {
    guard let a = [PromptAnswer.once, .session, .always, .deny].first(where: { same($0.word, word) }) else {
      return nil
    }
    self = a
  }
}

/// A field of a key's question, as the user types it.
public struct PromptField: Equatable, Sendable {
  public let name: String
  public let secret: Bool
  public var value: [UInt32] = []

  public init(name: String, secret: Bool, value: [UInt32] = []) {
    self.name = name
    self.secret = secret
    self.value = value
  }
}

/// Why a question was refused.
public struct PromptRefusal: Error, Equatable {
  public let reason: String
}

public struct PromptQuestion: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case confirm
    case key
    case choose(save: Bool)
    /// The lock screen's (D118): a password to type, Unlock its one
    /// answer, asked only by the lock's holder.
    case unlock
  }

  public let id: UInt64
  /// The client that asked, as the launcher names it.
  public let asker: String
  /// The app it asks for (`app=`), or the asker.
  public let app: String
  public let kind: Kind
  /// What it asks about, as written.
  public let shown: String
  /// Its buttons, left to right: deny first, once last.
  public let answers: [PromptAnswer]
  public var fields: [PromptField]
  /// For a `.choose` question, the scene id of Tracker's chooser view.
  public let view: UInt32

  /// The longest `shown` taken, in bytes.
  public static let maxShown = 256

  /// The question in `text`, an ndb entry, asked by `asker`.
  public init(parsing text: [UInt8], id: UInt64, asker: String) throws(PromptRefusal) {
    var pairs: [NdbPair] = []
    for line in text.split(separator: 0x0A) { pairs += parseLine(Array(line)) }
    var kind: Kind?
    var app = asker
    var offered: [PromptAnswer] = [.once]
    var shown: [String] = []
    var fields: [PromptField] = []
    for p in pairs {
      if same(p.attr, "ask") {
        guard kind == nil else { throw PromptRefusal(reason: "one ask= a question") }
        if same(p.value, "confirm") {
          kind = .confirm
        } else if same(p.value, "key") {
          kind = .key
        } else if same(p.value, "unlock") {
          kind = .unlock
        } else {
          throw PromptRefusal(reason: "ask= is confirm, key or unlock")
        }
      } else if same(p.attr, "app") {
        guard !p.value.isEmpty else { throw PromptRefusal(reason: "app= names an app") }
        app = p.value
      } else if same(p.attr, "answers") {
        offered = []
        for w in p.value.utf8.split(separator: UInt8(ascii: ",")) {
          guard let a = PromptAnswer(word: String(decoding: w, as: UTF8.self)) else {
            throw PromptRefusal(reason: "answers= are once, session and always")
          }
          if a != .deny && !offered.contains(a) { offered.append(a) }
        }
        guard !offered.isEmpty else { throw PromptRefusal(reason: "answers= offers none") }
      } else if p.attr.utf8.last == UInt8(ascii: "?") && p.value.isEmpty {
        // A field to type: `user?`, `!password?`.
        var name = Array(p.attr.utf8.dropLast())
        let secret = name.first == UInt8(ascii: "!")
        if secret { name.removeFirst() }
        guard !name.isEmpty else { throw PromptRefusal(reason: "a field without a name") }
        fields.append(PromptField(name: String(decoding: name, as: UTF8.self), secret: secret))
      } else {
        guard p.attr.utf8.first != UInt8(ascii: "!") else { throw PromptRefusal(reason: "a question holds no secret") }
        shown.append(p.value.isEmpty ? p.attr : p.attr + "=" + ndbQuoted(p.value))
      }
    }
    guard let kind else { throw PromptRefusal(reason: "no ask=") }
    if (kind == .key || kind == .unlock) && fields.isEmpty {
      throw PromptRefusal(reason: "a key's question has a field to type")
    }
    if kind == .confirm && !fields.isEmpty { throw PromptRefusal(reason: "a confirm has nothing to type") }
    let text = shown.joined(separator: " ")
    guard text.utf8.count <= Self.maxShown else { throw PromptRefusal(reason: "longer than \(Self.maxShown) bytes") }
    self.id = id
    self.asker = asker
    self.app = app
    self.kind = kind
    self.shown = text
    // Left to right: deny, then always, session, once; Unlock alone.
    answers = kind == .unlock ? [.once] : [.deny] + [PromptAnswer.always, .session, .once].filter { offered.contains($0) }
    self.fields = fields
    self.view = 0
  }

  /// A file chooser question (D111), embedding Tracker's `view`.
  public init(choosing save: Bool, id: UInt64, asker: String, app: String, types: [String], view: UInt32) {
    self.id = id
    self.asker = asker
    self.app = app.isEmpty ? asker : app
    self.kind = .choose(save: save)
    let joined = types.joined(separator: ", ")
    self.shown = String(decoding: joined.utf8.prefix(Self.maxShown), as: UTF8.self)
    self.answers = [.deny, .once]
    self.fields = []
    self.view = view
  }

  /// The label on button `a` for this question.
  public func label(_ a: PromptAnswer) -> String {
    if case .choose(let save) = kind {
      if a == .once { return save ? "Save" : "Open" }
      if a == .deny { return "Cancel" }
    }
    if kind == .unlock { return "Unlock" }
    return a.label
  }

  /// What its asker reads: the answer, and a key's fields with it.
  public func reply(_ answer: PromptAnswer) -> [UInt8] {
    var line = answer.word
    if answer != .deny {
      for f in fields {
        var value: [UInt8] = []
        for r in f.value { value += UTF8Rune.encode(r) }
        line += " " + (f.secret ? "!" : "") + f.name + "=" + ndbQuoted(String(decoding: value, as: UTF8.self))
      }
    }
    return Array((line + "\n").utf8)
  }
}

/// Where a question's parts are on a screen of a size.
public struct PromptLayout: Equatable, Sendable {
  public static let width = 448, strip = 24, margin = 16, line = 18, fieldHeight = 22, fieldGap = 6
  public static let buttonHeight = 28, buttonGap = 8, sealRadius = 30, chooserHeight = 200
  /// The text column: right of the seal.
  public static let textX = 88

  public let panel: Rect
  /// Each answer's button, left to right as the question's `answers`.
  public let buttons: [Rect]
  /// Each field's box, and where its label starts.
  public let fields: [(box: Rect, label: Int)]
  /// Where Tracker's chooser view is drawn, for a `.choose` question.
  public let chooser: Rect?
  /// The text's lines: the app, then what it asks about, wrapped.
  public let lines: [String]
  public let seal: (x: Int, y: Int)

  public static func == (a: PromptLayout, b: PromptLayout) -> Bool {
    a.panel == b.panel && a.buttons == b.buttons && a.lines == b.lines && a.chooser == b.chooser
  }

  public init(_ q: PromptQuestion, screenWidth: Int, screenHeight: Int) {
    let columns = (Self.width - Self.textX - Self.margin) / 8
    var lines = [same(q.app, q.asker) ? q.app : q.app + ", through " + q.asker]
    let askText: String
    switch q.kind {
    case .confirm: askText = "asks to use " + q.shown
    case .key: askText = "needs a key: " + q.shown
    case .unlock: askText = "The screen is locked. Type the password of " + q.shown
    case .choose(let save):
      askText = (save ? "asks to save a file" : "asks to open a file") + (q.shown.isEmpty ? "" : " (" + q.shown + ")")
    }
    lines += Self.wrap(askText, columns, at: 5)
    let text = lines.count * Self.line + q.fields.count * (Self.fieldHeight + Self.fieldGap)
    let header = max(2 * Self.sealRadius + 8, text)
    let hasChooser: Bool
    if case .choose = q.kind { hasChooser = true } else { hasChooser = false }
    let body = hasChooser ? header + 8 + Self.chooserHeight : header
    let height = Self.strip + 12 + body + 12 + Self.buttonHeight + Self.margin
    let w = min(Self.width, screenWidth), h = min(height, screenHeight)
    let p = Rect(x: (screenWidth - w) / 2, y: (screenHeight - h) / 2, width: w, height: h)
    panel = p
    self.lines = lines
    seal = (p.x + 44, p.y + Self.strip + 12 + Self.sealRadius + 4)
    var y = p.y + Self.strip + 12 + lines.count * Self.line + Self.fieldGap
    var fields: [(box: Rect, label: Int)] = []
    for _ in q.fields {
      fields.append((Rect(x: p.x + Self.textX + 88, y: y, width: p.width - Self.textX - 88 - Self.margin,
                          height: Self.fieldHeight), p.x + Self.textX))
      y += Self.fieldHeight + Self.fieldGap
    }
    self.fields = fields
    if hasChooser {
      chooser = Rect(x: p.x + Self.margin, y: p.y + Self.strip + 12 + header + 8,
                     width: max(1, p.width - 2 * Self.margin), height: Self.chooserHeight)
    } else {
      chooser = nil
    }
    // Right aligned, once rightmost.
    var x = p.maxX - Self.margin
    var buttons: [Rect] = []
    for a in q.answers.reversed() {
      let bw = max(72, q.label(a).utf8.count * 8 + 24)
      x -= bw
      buttons.insert(Rect(x: x, y: p.maxY - Self.margin - Self.buttonHeight, width: bw, height: Self.buttonHeight), at: 0)
      x -= Self.buttonGap
    }
    self.buttons = buttons
  }

  /// `text` in lines of `columns`, broken at spaces where it can be, at
  /// most `limit` of them, the last ending in an ellipsis if cut.
  static func wrap(_ text: String, _ columns: Int, at limit: Int) -> [String] {
    var out: [String] = []
    var rest = Array(text.unicodeScalars)
    while !rest.isEmpty {
      if out.count == limit - 1 && rest.count > columns {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: rest[..<(columns - 1)])
        s.append(Unicode.Scalar(0x2026)!)
        out.append(String(s))
        break
      }
      var n = min(columns, rest.count)
      if n < rest.count, let space = rest[..<n].lastIndex(of: " "), space > 0 { n = space }
      var s = String.UnicodeScalarView()
      s.append(contentsOf: rest[..<n])
      out.append(String(s))
      rest.removeFirst(n)
      while rest.first == " " { rest.removeFirst() }
    }
    return out
  }
}

/// The questions asked, the oldest on screen, and the user working it.
public struct Prompts: Sendable {
  /// How long a question is on screen before a click or a key answers it.
  public static let arming: Int64 = 500_000_000

  public private(set) var queue: [PromptQuestion] = []
  /// When the one on screen showed.
  public private(set) var since: Int64 = 0
  /// The button pressed and not yet let go.
  public private(set) var pressed: Int?
  /// The field typed into.
  public private(set) var field = 0
  /// Clicks and keys that came before the question was armed.
  public private(set) var ignored = 0
  var nextID: UInt64 = 1

  public init() {}

  /// The screen is locked (D118): only an unlock question shows.
  public var locked = false

  public var showing: PromptQuestion? {
    guard let q = queue.first else { return nil }
    return !locked || q.kind == .unlock ? q : nil
  }

  public mutating func newID() -> UInt64 {
    defer { nextID += 1 }
    return nextID
  }

  /// Queues `q`; true if it is now on screen.
  /// An unlock question goes before every other.
  public mutating func ask(_ q: PromptQuestion, now: Int64) -> Bool {
    if q.kind == .unlock {
      queue.insert(q, at: 0)
    } else {
      queue.append(q)
      guard queue.count == 1 else { return false }
    }
    shown(now)
    return true
  }

  /// The screen was locked or unlocked: what shows may change.
  public mutating func setLocked(_ on: Bool, now: Int64) {
    guard locked != on else { return }
    locked = on
    shown(now)
  }

  /// The secure attention key, locked: the field emptied.
  public mutating func clearFields() -> Outcome {
    guard var q = showing, q.kind == .unlock else { return .none }
    for i in q.fields.indices { q.fields[i].value = [] }
    queue[0] = q
    field = 0
    return .redraw
  }

  /// Takes question `id` away, answered or not; true if the one on screen
  /// changed.
  public mutating func withdraw(_ id: UInt64, now: Int64) -> Bool {
    guard let i = queue.firstIndex(where: { $0.id == id }) else { return false }
    queue.remove(at: i)
    guard i == 0 else { return false }
    shown(now)
    return true
  }

  mutating func shown(_ now: Int64) {
    since = now
    pressed = nil
    field = 0
  }

  func armed(_ now: Int64) -> Bool { now - since >= Self.arming }

  /// What the user did came to this.
  public enum Outcome: Equatable, Sendable {
    /// Nothing that shows.
    case none
    /// The prompt looks different.
    case redraw
    /// Question `id` is answered: its asker reads `reply`.
    case answered(id: UInt64, reply: [UInt8])
  }

  /// The pointer's button went down at (x, y).
  public mutating func press(_ x: Int, _ y: Int, now: Int64, _ layout: PromptLayout) -> Outcome {
    guard showing != nil else { return .none }
    guard armed(now) else {
      ignored += 1
      return .none
    }
    if let i = layout.buttons.firstIndex(where: { $0.contains(x, y) }) {
      pressed = i
      return .redraw
    }
    if let i = layout.fields.firstIndex(where: { $0.box.contains(x, y) }), i != field {
      field = i
      return .redraw
    }
    return .none
  }

  /// It came up at (x, y): over the button it went down on, that answer.
  public mutating func release(_ x: Int, _ y: Int, _ layout: PromptLayout) -> Outcome {
    guard let q = showing, let i = pressed else { return .none }
    pressed = nil
    guard layout.buttons[i].contains(x, y) else { return .redraw }
    return .answered(id: q.id, reply: q.reply(q.answers[i]))
  }

  /// A rune typed (kbdfs's `c`): escape denies; in a key's question, the
  /// field's text, backspace, tab to the next field and return for once.
  public mutating func typed(_ rune: UInt32, now: Int64) -> Outcome {
    guard var q = showing else { return .none }
    let typing = q.kind == .key || q.kind == .unlock
    // (Escape clears an unlock's field: there is nothing to deny.)
    if rune == 0x1B && q.kind == .unlock { return clearFields() }
    let answering = rune == 0x1B || (rune == 0x0A || rune == 0x0D) && typing
    if answering && !armed(now) {
      ignored += 1
      return .none
    }
    if rune == 0x1B { return .answered(id: q.id, reply: q.reply(.deny)) }
    guard typing else { return .none }
    switch rune {
    case 0x0A, 0x0D: return .answered(id: q.id, reply: q.reply(.once))
    case 0x09: field = (field + 1) % q.fields.count
    case 0x08, 0x7F:
      guard !q.fields[field].value.isEmpty else { return .none }
      q.fields[field].value.removeLast()
    default:
      guard rune >= 0x20, q.fields[field].value.count < 128 else { return .none }
      q.fields[field].value.append(rune)
    }
    queue[0] = q
    return .redraw
  }
}

/// The prompt's own colours: no theme's.
enum Trusted {
  static let edge: UInt32 = 0x00_0000, face: UInt32 = 0xC8_CCD0, light: UInt32 = 0xF4_F6F8, shade: UInt32 = 0x70_767E
  static let ink: UInt32 = 0x16_1616, dim: UInt32 = 0x4A_5058, strip: UInt32 = 0x00_0000, stripLine: UInt32 = 0x3C_3C3C
  static let heading: UInt32 = 0xFF_FFFF, well: UInt32 = 0xFF_FFFF
  /// What the screen beneath is dimmed to: a quarter of its light.
  static let dimming: [UInt8] = (0..<256).map { UInt8(Light.encode(Light.decode(UInt32($0)) / 4)) }

  /// The seal's pixel at (dx, dy) from its centre, if it has one: a
  /// gunmetal disc lit from the top left, in a dark ring with teeth.
  static func seal(_ dx: Int, _ dy: Int) -> UInt32? {
    let r2 = dx * dx + dy * dy
    guard r2 <= 30 * 30 else { return nil }
    let tooth = dx * dy == 0 || dx == dy || dx == -dy || 2 * dx == dy || dx == 2 * dy || 2 * dx == -dy || dx == -2 * dy
    if r2 > 27 * 27 { return tooth || r2 <= 28 * 28 ? 0x2A_2E33 : nil }
    if r2 > 24 * 24 { return 0x3A_3F44 }
    var lit = min(0x90, max(0x40, 0x68 - (dx + dy) * 2))
    if r2 < 9 * 9 { lit -= 0x14 }
    return UInt32(lit) << 16 | UInt32(lit + 6) << 8 | UInt32(lit + 12)
  }
}


extension PromptLayout {
  /// What drawing `q` adds to `list` within `clip`, over a screen it dims
  /// first; `pressed` and `field` as `Prompts` keeps them.
  func draw(_ q: PromptQuestion, pressed: Int?, field: Int, screen: Rect, clip r: Rect, into list: inout DrawList) {
    func fill(_ rect: Rect, _ color: UInt32) {
      let c = rect.intersection(r)
      if !c.isEmpty { list.quads.append(Quad(c, kind: Quad.fill, color: color)) }
    }
    func text(_ s: String, _ x: Int, _ y: Int, _ color: UInt32, until end: Int) {
      var tx = x
      for scalar in s.unicodeScalars where tx + 8 <= end {
        let cell = Rect(x: tx, y: y, width: 8, height: 16)
        let c = cell.intersection(r)
        if !c.isEmpty {
          list.quads.append(Quad(c, sx: c.x - cell.x, sy: c.y - cell.y, texture: scalar.value, kind: Quad.glyph,
                                 color: color))
        }
        tx += 8
      }
    }
    func bevel(_ b: Rect, sunk: Bool) {
      fill(b, Trusted.edge)
      fill(Rect(x: b.x + 1, y: b.y + 1, width: b.width - 2, height: b.height - 2), sunk ? Trusted.light : Trusted.shade)
      fill(Rect(x: b.x + 1, y: b.y + 1, width: b.width - 3, height: b.height - 3), sunk ? Trusted.shade : Trusted.light)
      fill(Rect(x: b.x + 2, y: b.y + 2, width: b.width - 4, height: b.height - 4), Trusted.face)
    }
    // The screen beneath, dimmed but for the panel; locked, black.
    let s = screen.intersection(r)
    if !s.isEmpty { list.quads.append(q.kind == .unlock ? Quad(s, kind: Quad.fill, color: 0) : Quad(s, kind: Quad.dim)) }
    let p = panel
    bevel(p, sunk: false)
    // The strip: black, its heading in white.
    fill(Rect(x: p.x + 1, y: p.y + 1, width: p.width - 2, height: Self.strip - 1), Trusted.strip)
    fill(Rect(x: p.x + 1, y: p.y + 1, width: p.width - 2, height: 1), Trusted.stripLine)
    let heading: String = switch q.kind {
    case .confirm: "Approval"
    case .key: "Key"
    case .choose(let save): save ? "Save file" : "Open file"
    case .unlock: "Locked"
    }
    text(heading, p.x + 12, p.y + 4, Trusted.heading, until: p.maxX - 12)
    // The seal.
    let sr = Self.sealRadius
    let sealBox = Rect(x: seal.x - sr, y: seal.y - sr, width: 2 * sr + 1, height: 2 * sr + 1).intersection(r)
    if !sealBox.isEmpty {
      list.quads.append(Quad(sealBox, sx: sealBox.x - seal.x, sy: sealBox.y - seal.y, kind: Quad.seal))
    }
    // The app, then what it asks.
    let end = p.maxX - Self.margin
    for (i, line) in lines.enumerated() {
      text(line, p.x + Self.textX, p.y + Self.strip + 12 + i * Self.line, i == 0 ? Trusted.ink : Trusted.dim, until: end)
    }
    // The fields: a label, a well, the text (a secret's as bullets).
    for (i, f) in fields.enumerated() where i < q.fields.count {
      let qf = q.fields[i]
      text(qf.name, f.label, f.box.y + 3, Trusted.ink, until: f.box.x - 8)
      fill(f.box, i == field ? Trusted.edge : Trusted.shade)
      fill(Rect(x: f.box.x + 1, y: f.box.y + 1, width: f.box.width - 2, height: f.box.height - 2), Trusted.well)
      var shown = String.UnicodeScalarView()
      for r in qf.value { shown.append(qf.secret ? Unicode.Scalar(0x2022)! : Unicode.Scalar(r) ?? "?") }
      // The end of a long one shows.
      let room = (f.box.width - 8) / 8 - 1
      let tail = String(String.UnicodeScalarView(shown.suffix(room)))
      text(tail, f.box.x + 4, f.box.y + 3, Trusted.ink, until: f.box.maxX - 4)
      if i == field {
        fill(Rect(x: f.box.x + 4 + tail.unicodeScalars.count * 8, y: f.box.y + 3, width: 2, height: 16), Trusted.ink)
      }
    }
    if let c = chooser {
      fill(Rect(x: c.x - 1, y: c.y - 1, width: c.width + 2, height: c.height + 2), Trusted.edge)
      fill(c, Trusted.well)
    }
    // The buttons.
    for (i, b) in buttons.enumerated() where i < q.answers.count {
      bevel(b, sunk: pressed == i)
      let label = q.label(q.answers[i])
      let shift = pressed == i ? 1 : 0
      text(label, b.x + (b.width - label.utf8.count * 8) / 2 + shift, b.y + (b.height - 16) / 2 + shift,
           Trusted.ink, until: b.maxX - 2)
    }
  }
}
