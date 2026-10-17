// SPDX-License-Identifier: BSD-3-Clause

// What kbdfs does with keys (D83), after 9front's kbdfs.c: each usage a
// keyboard pushes to kbin becomes a key, its rune from the keymap's layer
// for the modifiers held (kbdputsc); the keys held go to kbd's readers as
// `k` and `K` messages (keyproc); a key's rune goes to kbd's readers as a
// `c` message while kbd is open, else to cons, raw or cooked (ctlproc);
// cooking erases a character (^H), a word (^W) or the line (^U), ends a
// line at a newline and the input at ^D (lineproc). Reads take queued
// messages as reqproc gives them: kbd's whole and NUL-terminated, as
// many as fit; cons's bytes, up to an end of input. Not yet: Alt's
// compose sequences (runeproc), the `c` repeat (USB keyboards repeat in
// software), Kdel's interrupt note (notes come in V3: Kdel flushes the
// line) and Ctl-Alt-Del's reboot (/dev/reboot, V3).

public final class Keyboard: @unchecked Sendable {
  struct Modifiers {
    var shift = false, ctl = false, alt = false, altgr = false, mod4 = false
    var caps = false, num = false
  }

  public var map = Keymap.us
  var mods = Modifiers()
  /// The keys held, unshifted, in the order pressed.
  var held: [UInt32] = []
  /// kbd's open channels: while any is, runes go to it, not cons.
  public var kbdOpen = 0
  /// consctl's open channels, and whether cons is raw (`rawon` lasts while
  /// one is open).
  public var consctlOpen = 0
  public private(set) var raw = false
  /// The line being cooked.
  var line: [UInt32] = []
  /// kbd's messages, each NUL-terminated.
  var kbdMessages: [[UInt8]] = []
  /// cons's input: chunks of bytes, an empty one the end of input.
  var consChunks: [[UInt8]] = []
  /// Bytes of the first chunk already read.
  var consTaken = 0
  /// What the console shows: cooking's echo.
  let echo: ([UInt8]) -> Void

  public init(echo: @escaping ([UInt8]) -> Void = { _ in }) { self.echo = echo }

  // MARK: Keys

  /// kbin's records: a usage, then 1 pressed or 0 released.
  public func kbin(_ records: [UInt8]) {
    var i = 0
    while i + 1 < records.count {
      usage(records[i], down: records[i + 1] != 0)
      i += 2
    }
  }

  /// One key, by its usage (kbdputsc).
  public func usage(_ usage: UInt8, down: Bool) {
    var rune: UInt32
    if !mods.num, let nav = Keymap.navigation(usage) {
      rune = nav
    } else if mods.altgr && mods.mod4 && map[.altgrmod4, usage] != 0 {
      rune = map[.altgrmod4, usage]
    } else if mods.mod4 && map[.mod4, usage] != 0 {
      rune = map[.mod4, usage]
    } else if mods.shift && mods.altgr && map[.shiftaltgr, usage] != 0 {
      rune = map[.shiftaltgr, usage]
    } else if mods.shift {
      rune = map[.shift, usage]
    } else if mods.altgr {
      rune = map[.altgr, usage]
    } else if mods.ctl {
      rune = map[.ctl, usage]
    } else {
      rune = map[.none, usage]
    }
    let button = map[.none, usage] != 0 && Keymap.navigation(usage) == nil ? map[.none, usage] : rune
    if mods.caps && rune >= 0x61 && rune <= 0x7A { rune -= 0x20 }
    if button != 0 { key(button: button, rune: rune, down: down) }
    switch rune {
    case KeyRune.shift: mods.shift = down
    case KeyRune.ctl: mods.ctl = down
    case KeyRune.altgr: mods.altgr = down
    case KeyRune.mod4: mods.mod4 = down
    case KeyRune.alt: mods.alt = down
    case KeyRune.num: if down { mods.num.toggle() }
    case KeyRune.caps: if down { mods.caps.toggle() }
    default: break
    }
  }

  /// A key pressed or released (keyproc): the keys held to kbd, and a
  /// press's rune on.
  func key(button: UInt32, rune: UInt32, down: Bool) {
    var kind: UInt8 = 0
    if down {
      if !held.contains(button) {
        held.append(button)
        kind = UInt8(ascii: "k")
      }
    } else if held.contains(button) {
      held.removeAll { $0 == button }
      kind = UInt8(ascii: "K")
    }
    if kind != 0, kbdOpen > 0 { kbdMessages.append([kind] + held.flatMap(UTF8Rune.encode) + [0]) }
    if down && rune != 0 { typed(rune) }
  }

  /// A rune typed (ctlproc): to kbd while it is open, else to cons. Shift,
  /// Ctl and the other modifiers are nobody's character.
  public func typed(_ rune: UInt32) {
    switch rune {
    case 0, KeyRune.caps, KeyRune.num, KeyRune.shift, KeyRune.altgr, KeyRune.mod4, KeyRune.ctl, KeyRune.alt: return
    default: break
    }
    if kbdOpen > 0 {
      kbdMessages.append([UInt8(ascii: "c")] + UTF8Rune.encode(rune) + [0])
    } else if raw {
      consChunks.append(UTF8Rune.encode(rune))
    } else {
      cook(rune)
    }
  }

  /// lineproc: the line being typed, edited, then given to cons whole.
  func cook(_ r: UInt32) {
    switch r {
    case KeyRune.del, 0:  // interrupt (no notes until V3) or flush
      line = []
    case KeyRune.bs, KeyRune.nack, KeyRune.etb:
      while let last = line.last {
        line.removeLast()
        echo([0x08])
        if r == KeyRune.bs { break }
        if r == KeyRune.etb && (last == 0x20 || last == 0x09) { break }
      }
    case KeyRune.eof:
      consChunks.append(line.flatMap(UTF8Rune.encode))
      line = []
    default:
      line.append(r)
      echo(UTF8Rune.encode(r))
      if r == 0x0A || line.count >= 256 {
        consChunks.append(line.flatMap(UTF8Rune.encode))
        line = []
      }
    }
  }

  /// consctl's writes.
  public func control(_ command: String) -> Bool {
    let c = Array(command.utf8)
    if c.starts(with: Array("rawon".utf8)) {
      raw = true
      if !line.isEmpty { consChunks.append(line.flatMap(UTF8Rune.encode)) }
      line = []
      return true
    }
    if c.starts(with: Array("rawoff".utf8)) {
      raw = false
      return true
    }
    return false
  }

  /// consctl's last channel closed: cooked again.
  public func consctlClosed() {
    consctlOpen -= 1
    if consctlOpen == 0 { raw = false }
  }

  /// kbdin's messages (kbdin in kbdfs.c): `k`, `K` and `c` given to kbd's
  /// readers or cons as they are, `r` and `R` a rune pressed or released,
  /// each NUL-terminated.
  public func kbdin(_ bytes: [UInt8]) {
    var i = 0
    while i < bytes.count {
      var end = i
      while end < bytes.count, bytes[end] != 0 { end += 1 }
      let message = Array(bytes[i..<end])
      i = end + 1
      guard message.count >= 2 else { continue }
      let rune = UTF8Rune.first(Array(message[1...])) ?? 0
      switch message[0] {
      case UInt8(ascii: "r"), UInt8(ascii: "R"):
        guard rune != 0 else { continue }
        let down = message[0] == UInt8(ascii: "r")
        var button = rune
        for u in 0..<Keymap.usages where map[.shift, UInt8(u)] == rune || map[.none, UInt8(u)] == rune {
          button = map[.none, UInt8(u)]
          break
        }
        key(button: button, rune: rune, down: down)
        switch rune {
        case KeyRune.shift: mods.shift = down
        case KeyRune.ctl: mods.ctl = down
        case KeyRune.altgr: mods.altgr = down
        case KeyRune.mod4: mods.mod4 = down
        default: break
        }
      case UInt8(ascii: "c"):
        typed(rune)
      default:
        if kbdOpen > 0 { kbdMessages.append(message + [0]) }
      }
    }
  }

  // MARK: Reads

  /// kbd's read: whole messages, as many as fit in `max` (the first cut
  /// short if it alone doesn't); nil if there are none.
  public func takeKbd(_ max: Int) -> [UInt8]? {
    guard !kbdMessages.isEmpty, max > 0 else { return nil }
    var out: [UInt8] = []
    while let m = kbdMessages.first, out.count + m.count <= max {
      out += m
      kbdMessages.removeFirst()
    }
    if out.isEmpty {
      out = Array(kbdMessages[0][..<max])
      kbdMessages[0].removeFirst(max)
    }
    return out
  }

  /// cons's read: up to `max` bytes of what was typed, stopping at an end
  /// of input, which a read finding first returns as nothing; nil if there
  /// is nothing yet.
  public func takeCons(_ max: Int) -> [UInt8]? {
    guard let first = consChunks.first else { return nil }
    if first.isEmpty {
      consChunks.removeFirst()
      return []
    }
    var out: [UInt8] = []
    while out.count < max, let chunk = consChunks.first, !chunk.isEmpty {
      let n = Swift.min(max - out.count, chunk.count - consTaken)
      out += chunk[consTaken..<consTaken + n]
      consTaken += n
      if consTaken == chunk.count {
        consChunks.removeFirst()
        consTaken = 0
      }
    }
    return out
  }
}
