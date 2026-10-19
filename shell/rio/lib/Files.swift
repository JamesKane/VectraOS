// SPDX-License-Identifier: BSD-3-Clause

// A rio window's files (rio(4), D107), as Plan 9's rio serves them,
// without /dev/draw's: what the dispatcher's thread, answering the
// window's programs, shares with the window's frames on the main actor.
//   cons     reads take what was sent (a line, a raw key, ^D's end), and
//            wait for it; writes are output, shown at the output point
//   consctl  rawon, rawoff, holdon, holdoff; reset when the last closes
//   kbd      while open, the keys as kbdfs's messages, and cons hears none
//   label    the window's title
//   text     the window's text; a write is output, as cons's
//   wctl     its place, size, focus and visibility, a read waiting on a
//            change after the first; writes are rio's verbs (Wctl)
//   wdir     its directory: rc writes it at a prompt, a route goes from it
//   winid    its id in rio
// Nothing here waits: a read with nothing for it returns nil (the tree
// holds it), and `ready` says which file to try again.

import Synchronization
import UICore

public final class WindowFiles: Sendable {
  public enum File: Sendable { case cons, kbd, wctl }

  struct State {
    /// Sent and not yet read: a line or a key's bytes, or nil for an end.
    var input: [[UInt8]?] = []
    var kbd: [[UInt8]] = []
    var kbdOpen = 0
    var consctlOpen = 0
    var rawing = 0
    var holding = 0
    /// Output written and not yet shown, and the start of a character a
    /// write ended in.
    var output: [UInt32] = []
    var partial: [UInt8] = []
    var label: String
    var wdir: String
    var text: [UInt8] = []
    var wctl = ""
    var wctlGeneration = 0
    /// The window's place and the screen, for wctl's verbs.
    var rect = WctlRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
    var screen: WctlRect
    var commands: [WctlCommand] = []
    /// Raw or hold mode changed, for the window's next frame.
    var modes: (raw: Bool, holding: Bool)?
    var deleted = false
    /// The surface: a view's token lent and not yet shown (raw), and
    /// whether a view has it.
    var lentToken: UInt32?
    var lent = false
    /// The window has had a key or a press since it was focused: the
    /// clipboard may be read through its files (D112's rule).
    var given = false
  }

  let state: Mutex<State>
  public let id: Int
  /// Where `new` puts the next window (rio's, shared by its windows).
  let cascade: Cascade
  /// A file may have bytes for a waiting reader.
  let ready: @Sendable (File) -> Void
  /// Something for the window's next frame (output, a mode, a verb).
  let changed: @Sendable () -> Void

  public init(id: Int, label: String, wdir: String, screen: WctlRect = WctlRect(minX: 0, minY: 0, maxX: 1280, maxY: 800),
              cascade: Cascade = Cascade(), ready: @escaping @Sendable (File) -> Void = { _ in },
              changed: @escaping @Sendable () -> Void = {}) {
    self.id = id
    self.cascade = cascade
    self.ready = ready
    self.changed = changed
    state = Mutex(State(label: label, wdir: wdir, screen: screen))
  }

  // MARK: The programs' side (the dispatcher's thread)

  /// A read of cons: the next thing sent, up to `max` bytes of it; nil to
  /// wait; empty for an end, or once the window is gone.
  public func readCons(_ max: Int) -> [UInt8]? {
    state.withLock { s -> [UInt8]? in
      if s.deleted { return [] }
      guard s.kbdOpen == 0, !s.input.isEmpty else { return nil }
      guard let first = s.input[0] else {
        s.input.removeFirst()
        return []
      }
      if first.count <= max {
        s.input.removeFirst()
        return first
      }
      s.input[0] = Array(first[max...])
      return Array(first[..<max])
    }
  }

  /// A write of cons or text: output, shown at the window's next frame.
  public func write(_ bytes: [UInt8]) {
    state.withLock { s in
      var all = s.partial + bytes
      // The start of a character the write ended in waits for its rest.
      var keep = 0
      for back in 1...min(3, all.count) {
        let b = all[all.count - back]
        if b & 0xC0 == 0x80 { continue }
        let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
        if need > back { keep = back }
        break
      }
      s.partial = Array(all.suffix(keep))
      all.removeLast(keep)
      s.output += String(decoding: all, as: UTF8.self).unicodeScalars.map { $0.value }
    }
    changed()
  }

  /// A read of kbd: as many whole messages as fit, or nil to wait.
  public func readKbd(_ max: Int) -> [UInt8]? {
    state.withLock { s -> [UInt8]? in
      if s.deleted { return [] }
      guard !s.kbd.isEmpty else { return nil }
      var out: [UInt8] = []
      while let m = s.kbd.first, out.isEmpty || out.count + m.count <= max {
        out += m
        s.kbd.removeFirst()
      }
      return out
    }
  }

  public func kbdOpened() { state.withLock { $0.kbdOpen += 1 } }

  public func kbdClosed() {
    let reopen = state.withLock { s -> Bool in
      s.kbdOpen -= 1
      if s.kbdOpen == 0 { s.kbd = [] }
      return s.kbdOpen == 0 && !s.input.isEmpty
    }
    // cons hears again.
    if reopen { ready(.cons) }
  }

  public func consctlOpened() { state.withLock { $0.consctlOpen += 1 } }

  /// The last consctl closed: raw and hold mode end, as rio's do.
  public func consctlClosed() {
    let reset = state.withLock { s -> Bool in
      s.consctlOpen -= 1
      guard s.consctlOpen == 0, s.rawing > 0 || s.holding > 0 else { return false }
      (s.rawing, s.holding) = (0, 0)
      s.modes = (false, false)
      return true
    }
    if reset { changed() }
  }

  /// A write of consctl, as rio's: `holdon` and `holdoff` counted, `rawon`
  /// and `rawoff` counted, rawon ending hold. False for anything else.
  public func control(_ text: String) -> Bool {
    let t = Array(text.utf8)
    func starts(_ word: String) -> Bool { t.starts(with: Array(word.utf8)) }
    let ok = state.withLock { s -> Bool in
      let was = (s.rawing > 0, s.holding > 0)
      if starts("holdon") {
        s.holding += 1
      } else if starts("holdoff") {
        if s.holding > 0 { s.holding -= 1 }
      } else if starts("rawon") {
        s.holding = 0
        s.rawing += 1
      } else if starts("rawoff") {
        if s.rawing > 0 { s.rawing -= 1 }
      } else {
        return false
      }
      let now = (s.rawing > 0, s.holding > 0)
      if now != was { s.modes = now }
      return true
    }
    if ok { changed() }
    return ok
  }

  public var label: String {
    get { state.withLock { $0.label } }
    set {
      state.withLock { $0.label = newValue }
      changed()
    }
  }

  /// wdir's text.
  public var wdir: String { state.withLock { $0.wdir } }

  /// A write of wdir, as rio's: a newline dropped, a relative path taken
  /// from the directory there was, the name cleaned.
  public func setWdir(_ text: String) {
    var t = Array(text.utf8)
    if t.last == 0x0A { t.removeLast() }
    guard !t.isEmpty else { return }
    state.withLock { s in
      let p = t.first == 0x2F ? String(decoding: t, as: UTF8.self) : s.wdir + "/" + String(decoding: t, as: UTF8.self)
      s.wdir = cleanName(p)
    }
  }

  /// winid's text: the id, as rio has it, in 11 columns and a space.
  public var winid: String { padded(id) }

  /// text's bytes, as the window last showed them.
  public var text: [UInt8] { state.withLock { $0.text } }

  /// wctl's reader: its first read returns the window's state at once,
  /// each later one when it has changed (nil to wait).
  public func wctlReader() -> (Int) -> [UInt8]? {
    let seen = Mutex(-1)
    return { [self] _ in
      state.withLock { s -> [UInt8]? in
        if s.deleted { return [] }
        return seen.withLock { n -> [UInt8]? in
          guard n != s.wctlGeneration else { return nil }
          n = s.wctlGeneration
          return Array(s.wctl.utf8)
        }
      }
    }
  }

  /// A write of wctl: a verb for the window's next frame, or why not.
  public func command(_ text: String) -> String? {
    let error = state.withLock { s -> String? in
      do throws(WctlError) {
        let c = try Wctl.parse(text, rect: rect(s), screen: s.screen, cascade: cascade.current)
        if c.verb == .new { cascade.advance() }
        s.commands.append(c)
        return nil
      } catch {
        return error.message
      }
    }
    if error == nil { changed() }
    return error
  }

  /// The surface, lent: a view's token (raw, given), for the window's next
  /// wake to show. False if another view has it already.
  public func lend(_ token: UInt32) -> Bool {
    let ok = state.withLock { s -> Bool in
      guard !s.lent, !s.deleted else { return false }
      s.lent = true
      s.lentToken = token
      return true
    }
    if ok { changed() }
    return ok
  }

  /// A token lent since the last wake, to show.
  public func takeLent() -> UInt32? {
    state.withLock { s in
      defer { s.lentToken = nil }
      return s.lentToken
    }
  }

  /// The view closed: the surface may be lent again.
  public func returned() { state.withLock { $0.lent = false } }

  /// The window was given a key or a press.
  public func gave() { state.withLock { $0.given = true } }

  /// Whether the clipboard may be read through the window's files: it is
  /// focused, and has had input since.
  public var mayRead: Bool { state.withLock { $0.given } }

  /// The rectangle wctl's verbs start from: none for rio's own wctl.
  func rect(_ s: State) -> WctlRect? { id == 0 ? nil : s.rect }

  // MARK: The window's side (its frames)

  /// What came for the window since its last frame: output to show, and
  /// raw and hold mode if they changed.
  public func take() -> (output: [UInt32], modes: (raw: Bool, holding: Bool)?) {
    state.withLock { s in
      defer {
        s.output = []
        s.modes = nil
      }
      return (s.output, s.modes)
    }
  }

  /// wctl's verbs written since the last frame.
  public func takeCommands() -> [WctlCommand] {
    state.withLock { s in
      defer { s.commands = [] }
      return s.commands
    }
  }

  /// What the window's keys sent, for cons's readers.
  public func send(_ sent: [Sent]) {
    var any = false
    state.withLock { s in
      for x in sent {
        switch x {
        case .input(let b):
          s.input.append(b)
          any = true
        case .end:
          s.input.append(nil)
          any = true
        case .interrupt: break
        }
      }
    }
    if any { ready(.cons) }
  }

  /// Whether kbd is open: keys go there, as messages, not to cons.
  public var kbdOpen: Bool { state.withLock { $0.kbdOpen > 0 } }

  /// A kbd message (kbdfs's form: `k`, `K` or `c`, then runes), sent to
  /// kbd's readers with its NUL.
  public func key(_ message: String) {
    let sent = state.withLock { s -> Bool in
      guard s.kbdOpen > 0 else { return false }
      s.kbd.append(Array(message.utf8) + [0])
      return true
    }
    if sent { ready(.kbd) }
  }

  /// The text shown, for text's readers.
  public func show(_ text: [UInt8]) { state.withLock { $0.text = text } }

  /// The window's state for wctl: its place on the screen, whether it has
  /// the focus, whether it is shown.
  public func place(_ r: WctlRect, screen: WctlRect, current: Bool, visible: Bool) {
    let line = padded(r.minX) + padded(r.minY) + padded(r.maxX) + padded(r.maxY)
      + padded(current ? "current" : "notcurrent") + padded(visible ? "visible" : "hidden")
    let changedState = state.withLock { s -> Bool in
      s.rect = r
      s.screen = screen
      if !current { s.given = false }
      guard s.wctl != line else { return false }
      s.wctl = line
      s.wctlGeneration += 1
      return true
    }
    if changedState { ready(.wctl) }
  }

  /// The window is gone: reads end, as rio's fail.
  public func delete() {
    state.withLock { $0.deleted = true }
    ready(.cons)
    ready(.kbd)
    ready(.wctl)
  }
}

/// The place of the next new window: each `new` the next of ten.
public final class Cascade: Sendable {
  let n = Mutex(0)
  public init() {}
  public var current: Int { n.withLock { $0 } }
  public func advance() { n.withLock { $0 += 1 } }
}

/// A field as rio's files give it: right aligned in 11 columns, a space.
func padded(_ s: String) -> String { String(repeating: " ", count: max(0, 11 - s.utf8.count)) + s + " " }

func padded(_ n: Int) -> String { padded(String(n)) }

/// A path cleaned as Plan 9's cleanname: no `.`, `..` taken back, no
/// doubled slashes.
public func cleanName(_ path: String) -> String {
  let rooted = path.utf8.first == 0x2F
  var out: [Substring] = []
  for part in path.split(separator: "/") {
    if part == "." { continue }
    if part == ".." {
      if let last = out.last, last != ".." { out.removeLast() } else if !rooted { out.append(part) }
      continue
    }
    out.append(part)
  }
  let joined = out.joined(separator: "/")
  return rooted ? "/" + joined : (joined.isEmpty ? "." : joined)
}
