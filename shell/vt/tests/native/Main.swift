// SPDX-License-Identifier: BSD-3-Clause

// vt-test (boot-vt): vt taking over a rio window to run a program that
// wants xterm, which is vt-test itself, as `vt-test child`.
// - The driver types `vt vt-test child` into rio's first window, through
//   QEMU's keys; while vt runs, Radharc lists no new window (vt draws in
//   the window's surface), and the window's text is unchanged; it types
//   the Up arrow and `q`.
// - The child, in vt: `TERM` and the screen's size from its environment;
//   colours, cursor addressing, a move back over what it wrote; the
//   alternate screen and application cursor keys, where it reads its keys
//   until `q`; then the main screen again, where it writes what it read.
// - vt leaves the main screen in the window as text: the driver finds the
//   child's lines there, its keys as xterm sent them (Up as ESC O A), and
//   none of the alternate screen's; then rc has the window back, and
//   `echo back` works.

import Node
import Sys
import VX
import VectraOSLibc

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String) {
  print(ok ? "vt-test: ok: \(what)" : "vt-test: FAILED: \(what)")
  if !ok { failures += 1 }
}

func within(_ seconds: Int, _ ok: () -> Bool) -> Bool {
  let end = Clock.monotonic() + Int64(seconds) * 1_000_000_000
  while Clock.monotonic() < end {
    if ok() { return true }
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  return ok()
}

/// Keys, as QEMU's sendkey names them.
func type(_ text: String) {
  var keys: [String] = []
  for c in text {
    switch c {
    case " ": keys.append("spc")
    case "-": keys.append("minus")
    case "\n": keys.append("ret")
    default: keys.append(String(c))
    }
  }
  print("qemu: sendkey " + keys.joined(separator: " "))
}

/// Written to stdout, at once.
func out(_ s: String) {
  let b = Array(s.utf8)
  _ = b.withUnsafeBytes { write(1, $0.baseAddress, $0.count) }
}

/// The screen's size, COLUMNSxLINES, from where the cursor stops past its
/// corner: `ESC [ row ; column R`.
func measure() -> String {
  out("\u{1B}[999;999H\u{1B}[6n")
  var reply: [UInt8] = []
  var b: UInt8 = 0
  while reply.last != 0x52, withUnsafeMutableBytes(of: &b, { read(0, $0.baseAddress, 1) }) == 1 { reply.append(b) }
  let f = String(decoding: reply.drop { $0 != 0x5B }.dropFirst().dropLast(), as: UTF8.self).split(separator: ";")
  return f.count == 2 ? "\(f[1])x\(f[0])" : "?"
}

/// The program vt runs.
func child() -> Never {
  let ns = processNamespace()
  let term = ns?.getenv("TERM") ?? ""
  let columns = ns?.getenv("COLUMNS") ?? "", lines = ns?.getenv("LINES") ?? ""
  out("\u{1B}[2J\u{1B}[H\u{1B}[31mred\u{1B}[m plain\r\n")
  out("\u{1B}[3;5Hat three five\r\n")
  out("abcdef\u{1B}[3Dxy\r\n")
  out("term \(term) size \(columns)x\(lines)\r\n")
  // The alternate screen, application cursor keys: keys until q; at r,
  // the screen's size, measured as programs do: the cursor sent past the
  // corner, then asked where it is (DSR 6).
  out("\u{1B}[?1049h\u{1B}[?1h\u{1B}[Halternate\r\n")
  var keys: [UInt8] = []
  var measured: [String] = [measure()]
  var buffer = [UInt8](repeating: 0, count: 64)
  reading: while true {
    let n = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
    guard n > 0 else { break }
    for b in buffer[0..<n] {
      if b == 0x72 {
        measured.append(measure())
        continue
      }
      keys.append(b)
      if b == 0x71 { break reading }
    }
  }
  let shown = keys.map { $0 == 0x1B ? "ESC" : $0 < 0x20 ? "^" + String(UnicodeScalar($0 + 0x40)) : String(UnicodeScalar($0)) }
  out("\u{1B}[?1l\u{1B}[?1049l")
  out("keys \(shown.joined(separator: " "))\r\n")
  out("measured \(measured.joined(separator: " "))\r\n")
  exit(0)
}

@main struct VtTest {
  static func main() {
    if processArguments().dropFirst().first == "child" { child() }
    guard let ns = processNamespace() else {
      print("vt-test: FAILED: no namespace")
      exit(1)
    }
    let w1 = "/mnt/wsys/wsys/1"
    func text() -> String { ns.readText(w1 + "/text") ?? "" }
    func listed() -> Int { (ns.readText("/svc/windows/list") ?? "").split(separator: "\n").count }
    check(within(30) { text().hasSuffix("% ") }, "rc prompts in rio's window")
    let windows = listed()
    type("vt vt-test child\n")
    check(within(10) { text().hasSuffix("% vt vt-test child\n") }, "vt is run")
    // (The child is in its alternate screen, reading keys, once vt has
    // drawn: give it time.)
    sleep(until: Clock.monotonic() + 3_000_000_000)
    check(listed() == windows, "vt opens no window of its own")
    check(text().hasSuffix("% vt vt-test child\n"), "the window's text is untouched while vt has it")
    // The window resized while vt has it: the view takes the new size.
    check(ns.writeText(w1 + "/wctl", "resize -dx 400 -dy 260"), "the window is resized")
    sleep(until: Clock.monotonic() + 1_000_000_000)
    print("qemu: sendkey r")
    sleep(until: Clock.monotonic() + 500_000_000)
    print("qemu: sendkey up")
    sleep(until: Clock.monotonic() + 500_000_000)
    print("qemu: sendkey q")
    check(within(15) { text().hasSuffix("% ") }, "the program ends, and so does vt")
    let lines = text().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    func has(_ l: String) -> Bool {
      let ok = lines.contains(l)
      if !ok { print("vt-test: no line \(l.debugDescription) in \(lines.suffix(10))") }
      return ok
    }
    check(has("red plain"), "colours drawn, none of their sequences left")
    check(has("    at three five"), "cursor addressing")
    check(has("abcxyf"), "a move back over what was written")
    check(lines.contains { $0.hasPrefix("term xterm-256color size ") && !$0.hasSuffix(" size x") },
          "TERM and the screen's size in the program's environment")
    check(has("keys ESC O A q"), "Up as xterm sends it in application cursor mode, and q")
    // Its size as the environment said, then smaller with the window.
    let size = lines.first { $0.hasPrefix("term ") }.map { String($0.split(separator: " ").last ?? "") } ?? ""
    let measured = lines.first { $0.hasPrefix("measured ") }.map { $0.split(separator: " ").dropFirst().map(String.init) } ?? []
    print("vt-test: COLUMNSxLINES \(size), measured \(measured)")
    check(measured.count == 2 && measured[0] == size, "the screen is the size the environment says")
    let dims = measured.map { $0.split(separator: "x").compactMap { Int($0) } }
    check(dims.count == 2 && dims[1].count == 2 && dims[0].count == 2 && dims[1][0] < dims[0][0] && dims[1][1] < dims[0][1],
          "and follows the window when it is resized")
    check(!lines.contains("alternate"), "the alternate screen goes with the program")
    type("echo back\n")
    check(within(10) { text().hasSuffix("% echo back\nback\n% ") }, "rc has the window back")
    print(failures == 0 ? "vt-test: passed" : "vt-test: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
  }
}
