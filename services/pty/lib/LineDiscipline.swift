// SPDX-License-Identifier: BSD-3-Clause

// A pty's line discipline (M6j part 2b; decided 2026-10-12: programs reach
// a terminal through a pty service, with termios's cooked and raw modes):
// what the terminal's keys become for the program, and what the program's
// output becomes for the terminal. A pure value, fed bytes, tested alone.
//
// Cooked (canonical) mode, POSIX's ICANON, ECHO, ISIG and ONLCR, with
// termios's default characters:
// - keys gather into a line, echoed; Enter (CR, turned into NL as ICRNL
//   does, or NL) sends the line with its newline;
// - Erase (DEL or ^H) takes back the last character of the line (a whole
//   UTF-8 sequence), echoed as "\b \b"; Kill (^U) the whole line; ^W the
//   last word;
// - ^C drops the line and is an interrupt for the program's controller
//   (echoed "^C"), ^\ a quit;
// - ^D sends the line as it is, without a newline; on an empty line it's
//   the end of input.
// Raw mode passes keys through as they come, unechoed. Output's newlines
// become CR NL either way, unless output processing is off.

public struct TerminalMode: Equatable, Sendable {
  /// Lines, edited (ICANON).
  public var canonical: Bool
  /// Keys echoed (ECHO).
  public var echo: Bool
  /// ^C and ^\ are signals for the controller (ISIG).
  public var signals: Bool
  /// Output's NL as CR NL (OPOST|ONLCR).
  public var outputCRLF: Bool

  public init(canonical: Bool = true, echo: Bool = true, signals: Bool = true, outputCRLF: Bool = true) {
    self.canonical = canonical
    self.echo = echo
    self.signals = signals
    self.outputCRLF = outputCRLF
  }

  /// cfmakeraw's: nothing processed.
  public static let raw = TerminalMode(canonical: false, echo: false, signals: false, outputCRLF: false)
}

/// What a key event means beyond its bytes.
public enum LineEvent: Equatable, Sendable {
  case interrupt
  case quit
  /// The end of input (^D on an empty line).
  case endOfInput
}

public struct LineDiscipline: Sendable {
  public var mode = TerminalMode()
  /// The line being edited (cooked mode).
  var line: [UInt8] = []

  public init(mode: TerminalMode = TerminalMode()) { self.mode = mode }

  static let erase: UInt8 = 0x7F, backspace: UInt8 = 0x08, kill: UInt8 = 0x15, werase: UInt8 = 0x17
  static let intr: UInt8 = 0x03, quit: UInt8 = 0x1C, eof: UInt8 = 0x04
  static let cr: UInt8 = 0x0D, nl: UInt8 = 0x0A

  /// Keys from the terminal: what goes to the program, what's echoed back
  /// to the terminal, and the events among them, in order.
  public mutating func input(_ keys: [UInt8]) -> (toProgram: [UInt8], echo: [UInt8], events: [LineEvent]) {
    var out: [UInt8] = [], echo: [UInt8] = [], events: [LineEvent] = []
    for k in keys {
      if mode.signals && (k == Self.intr || k == Self.quit) {
        line.removeAll()
        events.append(k == Self.intr ? .interrupt : .quit)
        if mode.echo { echo += k == Self.intr ? Array("^C\r\n".utf8) : Array("^\\\r\n".utf8) }
        continue
      }
      guard mode.canonical else {
        out.append(k)
        if mode.echo { echo.append(k) }
        continue
      }
      switch k {
      case Self.cr, Self.nl:
        line.append(Self.nl)
        out += line
        line.removeAll()
        if mode.echo { echo += [Self.cr, Self.nl] }
      case Self.erase, Self.backspace:
        guard !line.isEmpty else { continue }
        // A whole UTF-8 sequence: continuation bytes, then its lead.
        while let last = line.last, last & 0xC0 == 0x80 { line.removeLast() }
        line.removeLast()
        if mode.echo { echo += [Self.backspace, 0x20, Self.backspace] }
      case Self.kill:
        if mode.echo { for _ in 0..<characters(line) { echo += [Self.backspace, 0x20, Self.backspace] } }
        line.removeAll()
      case Self.werase:
        var n = 0
        while let last = line.last, last == 0x20 {
          line.removeLast()
          n += 1
        }
        while let last = line.last, last != 0x20 {
          line.removeLast()
          if last & 0xC0 != 0x80 { n += 1 }
        }
        if mode.echo { for _ in 0..<n { echo += [Self.backspace, 0x20, Self.backspace] } }
      case Self.eof:
        if line.isEmpty {
          events.append(.endOfInput)
        } else {
          out += line
          line.removeAll()
        }
      default:
        line.append(k)
        if mode.echo { echo.append(k) }
      }
    }
    return (out, echo, events)
  }

  /// The program's output, for the terminal.
  public func output(_ bytes: [UInt8]) -> [UInt8] {
    guard mode.outputCRLF, bytes.contains(Self.nl) else { return bytes }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count + 8)
    for b in bytes {
      if b == Self.nl { out.append(Self.cr) }
      out.append(b)
    }
    return out
  }

  /// Characters (UTF-8 lead bytes) in a line.
  func characters(_ line: [UInt8]) -> Int { line.reduce(0) { $1 & 0xC0 == 0x80 ? $0 : $0 + 1 } }

  /// Switching to raw mode hands over what was being edited.
  public mutating func setMode(_ m: TerminalMode) -> [UInt8] {
    mode = m
    guard !m.canonical, !line.isEmpty else { return [] }
    defer { line.removeAll() }
    return line
  }
}
