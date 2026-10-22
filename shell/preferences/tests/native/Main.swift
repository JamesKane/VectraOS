// SPDX-License-Identifier: BSD-3-Clause

// settings-test (boot-settings): the Settings app on the desktop (D115).
// Keyboard's preference app shows the area's settings; with its window
// focused, Tab and Space press its + and the volume has the change;
// another's change (written here, as rc's `attr` would) is read again,
// and nothing else wakes it; Control-W ends it. Grants' lists the recorded
// grants, and Space on its first Revoke removes one. The Inspector lists
// /proc's processes once a second, stops reading while nobody is at the
// desktop, and reads again after a key. They are plain services in this
// image, so this test can use their trees; boot-deskbar starts an app.

import IPC
import Node
import Radharc
import Settings
import Sys
import VX
import VectraOSLibc

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String) {
  print(ok ? "settings-test: ok: \(what)" : "settings-test: FAILED: \(what)")
  if !ok { failures += 1 }
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var f = try? ns.open(path) else { return nil }
  return try? f.readText()
}

func within(_ seconds: Int, _ ok: () -> Bool) -> Bool {
  let end = Clock.monotonic() + Int64(seconds) * 1_000_000_000
  while Clock.monotonic() < end {
    if ok() { return true }
    sleep(until: Clock.monotonic() + 50_000_000)
  }
  return ok()
}

func status(_ ns: Namespace, _ service: String) -> [String] {
  (readText(ns, "/svc/\(service)/status") ?? "").split(separator: "\n").map(String.init)
}

func says(_ ns: Namespace, _ service: String, _ line: String) -> Bool { status(ns, service).contains(line) }

func number(_ ns: Namespace, _ service: String, _ word: String) -> Int? {
  status(ns, service).first { $0.hasPrefix(word + " ") }.flatMap { Int($0.split(separator: " ").last ?? "") }
}

/// The launcher says the service ended with 0.
func exited(_ ns: Namespace, _ service: String) -> Bool {
  (readText(ns, "/svc/launcher/status") ?? "").split(separator: "\n").contains { $0.hasPrefix(service + " exited 0 ") }
}

/// Raises and focuses the app's window; whether it holds the keyboard.
func focus(_ ns: Namespace, _ app: String) -> Bool {
  guard let ch = try? ns.connect("/svc/windows/windows") else { return false }
  var w = RadharcIPC.WindowsClient(channel: ch)
  guard let e = ((try? w.entries()) ?? []).first(where: { $0.app == app }) else { return false }
  if e.focused { return true }
  _ = try? w.top(id: e.id)
  return false
}

@main struct SettingsTest {
  static func main() {
    guard let ns = processNamespace() else {
      print("settings-test: FAILED: no namespace")
      Process.exit(code: 1)
    }

    // Keyboard's: its settings, a press, another's change, ended.
    check(within(60) { says(ns, "prefs-keyboard", "ready") && says(ns, "prefs-keyboard", "Keyboard:RepeatDelay 500") },
          "Keyboard's preferences show its settings")
    check(within(10) { focus(ns, "Keyboard") }, "its window has the keyboard")
    // Tab to the delay's −, again to its +, and Space presses it.
    print("qemu: sendkey tab tab spc")
    check(within(10) { Settings.value(Settings.repeatDelay, ns) == .int(550) }, "its + writes the delay, 550, at once")
    check(within(10) { says(ns, "prefs-keyboard", "Keyboard:RepeatDelay 550") }, "and shows it")
    check(Settings.set(Settings.repeatRate, .int(40), ns), "Keyboard:RepeatRate set to 40 elsewhere")
    check(within(10) { says(ns, "prefs-keyboard", "Keyboard:RepeatRate 40") }, "the app reads another's change again")
    let before = number(ns, "prefs-keyboard", "wakeups")
    sleep(until: Clock.monotonic() + 3_000_000_000)
    let after = number(ns, "prefs-keyboard", "wakeups")
    check(before != nil && before == after, "unchanged, it doesn't wake (\(before ?? -1) then \(after ?? -1))")
    print("qemu: sendkey ctrl-w")
    check(within(20) { exited(ns, "prefs-keyboard") }, "Control-W ends it")

    // Grants': the recorded grants, one revoked.
    check(Grants.record("recorder", "capture", true, ns) && Grants.record("editor", "clipboard", false, ns),
          "two grants recorded")
    check(within(20) {
      says(ns, "prefs-grants", "ready") && says(ns, "prefs-grants", "grant recorder.capture allowed")
        && says(ns, "prefs-grants", "grant editor.clipboard refused")
    }, "Grants lists the recorded grants")
    check(within(10) { focus(ns, "Grants") }, "its window has the keyboard")
    // The list is in the file's attribute order: the first row is the
    // first listed.
    let listed = Grants.list(ns).map { $0.app }
    let first = listed.first ?? "", other = listed.last ?? ""
    print("qemu: sendkey tab spc")
    check(listed.count == 2 && within(10) { Grants.list(ns).map { $0.app } == [other] }, "Revoke removes the first, \(first)")
    check(within(10) { !status(ns, "prefs-grants").contains { $0.hasPrefix("grant \(first).") } }, "and it's gone from the list")
    print("qemu: sendkey ctrl-w")
    check(within(20) { exited(ns, "prefs-grants") }, "Control-W ends Grants")

    // The Inspector: /proc's processes, read while someone is at the desktop.
    check(within(30) { says(ns, "inspector", "ready") && (number(ns, "inspector", "processes") ?? 0) >= 5 },
          "the Inspector lists /proc's processes")
    let names = status(ns, "inspector").filter { $0.hasPrefix("process ") }.compactMap { $0.split(separator: " ").last }
    check(names.contains("inspector") && names.contains("proc") && names.contains("settings-test"),
          "among them the Inspector, proc and this test (\(names.joined(separator: " ")))")
    let r0 = number(ns, "inspector", "reads") ?? 0
    check(within(10) { (number(ns, "inspector", "reads") ?? 0) >= r0 + 2 }, "it reads again each second")
    check(within(40) { says(ns, "inspector", "desktop idle") }, "with no input the desktop goes idle")
    sleep(until: Clock.monotonic() + 1_000_000_000)
    let idleReads = number(ns, "inspector", "reads")
    sleep(until: Clock.monotonic() + 5_000_000_000)
    check(idleReads != nil && idleReads == number(ns, "inspector", "reads"),
          "while nobody is at the desktop it doesn't read /proc")
    print("qemu: sendkey shift")
    check(within(15) { says(ns, "inspector", "desktop active") && (number(ns, "inspector", "reads") ?? 0) > (idleReads ?? 0) },
          "a key makes it read again")
    check(within(10) { focus(ns, "Inspector") }, "its window has the keyboard")
    print("qemu: sendkey ctrl-q")
    check(within(20) { exited(ns, "inspector") }, "Control-Q quits it")

    print(failures == 0 ? "settings-test: all passed" : "settings-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
