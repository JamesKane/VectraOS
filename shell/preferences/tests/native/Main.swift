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

/// What Radharc says of keys and focus, and its windows, for a failure.
func showInput(_ ns: Namespace, _ why: String) {
  let lines = (readText(ns, "/svc/windows/status") ?? "").split(separator: "\n")
  let wanted = lines.filter { $0.hasPrefix("keys ") || $0.hasPrefix("focused ") || $0.hasPrefix("lock ") || $0.hasPrefix("prompts ") }
  print("settings-test: \(why): " + wanted.joined(separator: "; "))
  if let ch = try? ns.connect("/svc/windows/windows") {
    var w = RadharcIPC.WindowsClient(channel: ch)
    for e in (try? w.entries()) ?? [] { print("settings-test:   window \(e.id) \(e.app) focused \(e.focused)") }
  }
}

/// Radharc's count of keys routed.
func keysRouted(_ ns: Namespace) -> Int {
  let lines = (readText(ns, "/svc/windows/status") ?? "").split(separator: "\n")
  guard let line = lines.first(where: { $0.hasPrefix("keys ") }) else { return 0 }
  return Int(line.split(separator: " ")[1]) ?? 0
}

/// Types `keys` through QEMU (qemu.sh's `qemu: sendkey`). Keys that never
/// reach Radharc were lost on the host's side, not the app's (QEMU now and
/// then gives a burst to its PS/2 keyboard, which nothing reads): said,
/// and sent again, three times at most.
func send(_ ns: Namespace, _ keys: String) {
  for attempt in 0..<3 {
    let before = keysRouted(ns)
    print("qemu: sendkey " + keys)
    if within(3, { keysRouted(ns) > before }) { return }
    showInput(ns, "keys \(keys) didn't reach Radharc (try \(attempt + 1))")
  }
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
    send(ns, "tab tab spc")
    let pressed = within(10) { Settings.value(Settings.repeatDelay, ns) == .int(550) }
    if !pressed { showInput(ns, "the keys reached Radharc, and the delay didn't change") }
    check(pressed, "its + writes the delay, 550, at once")
    check(within(10) { says(ns, "prefs-keyboard", "Keyboard:RepeatDelay 550") }, "and shows it")
    check(Settings.set(Settings.repeatRate, .int(40), ns), "Keyboard:RepeatRate set to 40 elsewhere")
    check(within(10) { says(ns, "prefs-keyboard", "Keyboard:RepeatRate 40") }, "the app reads another's change again")
    let before = number(ns, "prefs-keyboard", "wakeups")
    sleep(until: Clock.monotonic() + 3_000_000_000)
    let after = number(ns, "prefs-keyboard", "wakeups")
    check(before != nil && before == after, "unchanged, it doesn't wake (\(before ?? -1) then \(after ?? -1))")
    send(ns, "ctrl-w")
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
    send(ns, "tab spc")
    check(listed.count == 2 && within(10) { Grants.list(ns).map { $0.app } == [other] }, "Revoke removes the first, \(first)")
    check(within(10) { !status(ns, "prefs-grants").contains { $0.hasPrefix("grant \(first).") } }, "and it's gone from the list")
    send(ns, "ctrl-w")
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
    send(ns, "shift")
    check(within(15) { says(ns, "inspector", "desktop active") && (number(ns, "inspector", "reads") ?? 0) > (idleReads ?? 0) },
          "a key makes it read again")
    check(within(10) { focus(ns, "Inspector") }, "its window has the keyboard")
    send(ns, "ctrl-q")
    check(within(20) { exited(ns, "inspector") }, "Control-Q quits it")

    // Appearance is the theme in force (D119): the accent and high contrast
    // from Settings, a theme of workspace 2's own, shown with it.
    func active() -> [String] {
      guard var f = try? ns.open("/svc/windows/theme/active"), let t = try? f.readText() else { return [] }
      return t.split(separator: "\n").map(String.init)
    }
    check(Settings.set(Settings.accent, .string("warm"), ns), "Appearance:Accent set to warm")
    check(within(10) { active().contains("knob accent accent.warm") }, "Radharc turns the accent knob")
    check(Settings.set(Settings.highContrast, .bool(true), ns), "Appearance:HighContrast set on")
    check(within(10) { active().contains("contrast on") }, "Radharc switches high contrast on")
    _ = Settings.set(Settings.highContrast, .bool(false), ns)
    _ = Settings.set(Settings.accent, .string("theme"), ns)
    check(within(10) { active().contains("contrast off") && !active().contains { $0.hasPrefix("knob ") } },
          "and both off again")
    func ctl(_ text: String) -> Bool {
      guard var f = try? ns.open("/svc/windows/ctl") else { return false }
      return (try? f.writeText(text)) != nil
    }
    check(ctl("theme neon-tab 2"), "workspace 2 is given Neon Tab")
    check(!ctl("theme nowhere 2"), "a theme that isn't installed is refused")
    check(within(5) { Settings.read("Workspaces", ns).contains { $0.name == "Workspaces:2:Theme" } }, "kept in Settings")
    check(active().contains("theme platinum-indigo"), "workspace 1 stays in Platinum Indigo")
    check(ctl("workspace 2") && within(10) { active().contains("theme neon-tab") }, "showing workspace 2 shows Neon Tab")
    check(ctl("workspace 1") && within(10) { active().contains("theme platinum-indigo") }, "and workspace 1 its own again")
    check(ctl("theme none 2"), "workspace 2's theme is taken away")

    print(failures == 0 ? "settings-test: all passed" : "settings-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
