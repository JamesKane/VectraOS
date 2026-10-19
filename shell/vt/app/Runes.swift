// SPDX-License-Identifier: BSD-3-Clause

// Keys as rio's raw cons gives them (rio(1)), in UTF-8, made what xterm
// sends: a key that isn't a character is its rune (kbdfs's, Plan 9's
// keyboard.h), sent as its escape sequence by KeyEncoder; Enter's newline
// is a carriage return, Backspace's ^H xterm's DEL, and Delete's DEL the
// delete key's sequence. Other characters go as they are.

import Kbdfs
import TerminalCore

public enum RuneKeys {
  public static func xterm(_ bytes: [UInt8], applicationCursor: Bool = false) -> [UInt8] {
    var out: [UInt8] = []
    for u in String(decoding: bytes, as: UTF8.self).unicodeScalars {
      let r = u.value
      switch r {
      case 0x0A: out += KeyEncoder.encode(.enter)
      case 0x08: out += KeyEncoder.encode(.backspace)
      case 0x7F: out += KeyEncoder.encode(.delete)
      case KeyRune.up: out += KeyEncoder.encode(.up, applicationCursor: applicationCursor)
      case KeyRune.down: out += KeyEncoder.encode(.down, applicationCursor: applicationCursor)
      case KeyRune.left: out += KeyEncoder.encode(.left, applicationCursor: applicationCursor)
      case KeyRune.right: out += KeyEncoder.encode(.right, applicationCursor: applicationCursor)
      case KeyRune.home: out += KeyEncoder.encode(.home, applicationCursor: applicationCursor)
      case KeyRune.end: out += KeyEncoder.encode(.end, applicationCursor: applicationCursor)
      case KeyRune.pgup: out += KeyEncoder.encode(.pageUp)
      case KeyRune.pgdown: out += KeyEncoder.encode(.pageDown)
      case KeyRune.ins: out += KeyEncoder.encode(.insert)
      case KeyRune.f(1)...KeyRune.f(12): out += KeyEncoder.encode(.function(Int(r - KeyRune.kf)))
      case KeyRune.kf..<(KeyRune.spec + 0x100): break  // a key xterm has no sequence for
      default: out += Array(String(Character(u)).utf8)
      }
    }
    return out
  }
}
