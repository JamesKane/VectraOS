// SPDX-License-Identifier: BSD-3-Clause

// rio-test (boot-rio): rc in a rio window, typed into through QEMU's keys
// (qemu.sh's `qemu: sendkey`), and the window's files, at /mnt/wsys:
// - winid, and the window's text: rc's prompt, `echo hi` and its output;
// - wdir after a `cd`, which rc writes at its prompt;
// - label, the window's title in Radharc's list;
// - Delete interrupting `sleep 100`; Escape holding a line until released;
// - wctl: its state, `move` and `resize` seen in it and in Radharc's list;
// - kbd: while open, the keys as messages, and none in the text;
// - rio's wctl's `new`: a second window running a command in a
//   directory, gone when the command ends; `current` back to the first;
// - `exit`: rc ends and its window goes.

import Node
import Sys
import VX
import VectraOSLibc

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String) {
  print(ok ? "rio-test: ok: \(what)" : "rio-test: FAILED: \(what)")
  if !ok { failures += 1 }
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var f = try? ns.open(path) else { return nil }
  return try? f.readText()
}

func write(_ ns: Namespace, _ path: String, _ text: String) -> Bool {
  guard var f = try? ns.open(path) else { return false }
  return (try? f.writeText(text)) != nil
}

/// Until `ok`, or `seconds`.
func within(_ seconds: Int, _ ok: () -> Bool) -> Bool {
  let end = Clock.monotonic() + Int64(seconds) * 1_000_000_000
  while Clock.monotonic() < end {
    if ok() { return true }
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  return ok()
}

/// Keys, as QEMU's sendkey names them: a word's letters, `spc` between.
func type(_ text: String) {
  var keys: [String] = []
  for c in text {
    switch c {
    case " ": keys.append("spc")
    case "/": keys.append("slash")
    case "-": keys.append("minus")
    case ";": keys.append("semicolon")
    case "\n": keys.append("ret")
    default: keys.append(String(c))
    }
  }
  print("qemu: sendkey " + keys.joined(separator: " "))
}

/// The six fields of a wctl read: four numbers, the focus, the visibility.
func wctl(_ ns: Namespace, _ w: Int) -> [Substring] {
  guard var f = try? ns.open("/mnt/wsys/wsys/\(w)/wctl"), let b = try? f.read(offset: 0, max: 128) else { return [] }
  return String(decoding: b, as: UTF8.self).split(separator: " ")
}

@main struct RioTest {
  static func main() {
    guard let ns = processNamespace() else {
      print("rio-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let w1 = "/mnt/wsys/wsys/1"
    check(within(30) { readText(ns, w1 + "/winid") == "          1 " }, "rio's first window, winid 1")
    func text() -> String { readText(ns, w1 + "/text") ?? "" }
    /// A check on the window's text, which a failure shows the end of.
    func checkText(_ ok: Bool, _ what: String) {
      check(ok, what)
      if !ok { print("rio-test: the text ends: \(String(text().suffix(60)).debugDescription)") }
    }
    check(within(20) { text().hasSuffix("% ") }, "rc prompts in it")
    let state = wctl(ns, 1)
    check(state.count == 6 && state[4] == "current" && state[5] == "visible", "wctl: \(state.joined(separator: " "))")

    type("echo hi\n")
    check(within(10) { text().hasSuffix("% echo hi\nhi\n% ") }, "what's typed goes to rc, and its output comes back")
    type("cd /lib\n")
    check(within(10) { readText(ns, w1 + "/wdir") == "/lib" }, "rc tells wdir its directory")

    check(write(ns, w1 + "/label", "rio test"), "label is written")
    check(within(5) { (readText(ns, "/svc/windows/list") ?? "").split(separator: "\n").contains { $0.hasSuffix(" rio test") } },
          "and is the window's title")

    type("sleep 100\n")
    sleep(until: Clock.monotonic() + 1_000_000_000)
    print("qemu: sendkey delete")
    checkText(within(5) { text().hasSuffix("sleep 100\n% ") }, "Delete interrupts sleep")

    print("qemu: sendkey esc")
    type("echo held\n")
    _ = within(10) { text().hasSuffix("% echo held\n") }
    sleep(until: Clock.monotonic() + 500_000_000)
    checkText(text().hasSuffix("% echo held\n"), "Escape holds the line")
    print("qemu: sendkey esc")
    check(within(5) { text().hasSuffix("% echo held\nheld\n% ") }, "and Escape again sends it")

    check(write(ns, w1 + "/wctl", "move -minx 200 -miny 150"), "wctl takes move")
    check(within(5) {
      let s = wctl(ns, 1)
      return s.count == 6 && s[0] == "200" && s[1] == "150"
    }, "the window moves")
    check((readText(ns, "/svc/windows/list") ?? "").split(separator: "\n").contains { $0.contains(" 200 150 ") },
          "in Radharc's list too")
    check(write(ns, w1 + "/wctl", "resize -dx 500 -dy 300"), "wctl takes resize")
    check(within(5) {
      let s = wctl(ns, 1).compactMap { Int($0) }
      return s.count == 4 && s[2] - s[0] == 500 && s[3] - s[1] == 300
    }, "the window takes the size")
    check(!write(ns, w1 + "/wctl", "bottom"), "wctl refuses bottom")

    // kbd: the keys as messages, none in the text.
    if var kbd = try? ns.open(w1 + "/kbd") {
      let before = text()
      print("qemu: sendkey a")
      var got: [UInt8] = []
      let end = Clock.monotonic() + 5_000_000_000
      while Clock.monotonic() < end && !got.split(separator: 0).contains(where: { $0 == Array("K".utf8)[...] }) {
        guard let b = try? kbd.read(offset: 0, max: 256) else { break }
        got += b
      }
      let messages = got.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
      check(messages.contains("ka") && messages.contains("ca") && messages.contains("K"), "kbd: \(messages)")
      sleep(until: Clock.monotonic() + 300_000_000)
      check(text() == before, "and the text has none of it")
      _ = consume kbd
    } else {
      check(false, "kbd opens")
    }

    // A second window from rio's wctl.
    check(write(ns, "/mnt/wsys/wctl", "new -cd /bin -dx 400 -dy 200 pwd; sleep 2"), "rio's wctl takes new")
    var second: String? = nil
    check(within(10) {
      second = readText(ns, "/mnt/wsys/wsys/2/text") ?? second
      return second == "/bin\n"
    }, "its command runs in its directory")
    if second != "/bin\n" { print("rio-test: its text: \(second.debugDescription)") }
    check(within(10) { readText(ns, "/mnt/wsys/wsys/2/winid") == nil }, "and its window goes when it ends")
    check(write(ns, w1 + "/wctl", "current"), "wctl takes current")
    check(within(5) { wctl(ns, 1).count == 6 && wctl(ns, 1)[4] == "current" }, "the first window has the focus again")

    type("exit\n")
    check(within(10) { readText(ns, w1 + "/winid") == nil }, "exit ends rc, and its window goes")
    check(!(readText(ns, "/svc/windows/list") ?? "").contains(" rio test"), "from Radharc's list too")
    print(failures == 0 ? "rio-test: passed" : "rio-test: \(failures) failed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
