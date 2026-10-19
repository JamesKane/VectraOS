// SPDX-License-Identifier: BSD-3-Clause

// kit-test (boot-kit): Kit on the device, in full Swift over tier 1's
// builds of the text stack, UICore and the SDK.
// - The faces in /lib/fonts, and those Platinum Indigo's typefaces name.
// - The sample drawn as the host draws it (ui/kit/tests/kit-sample.tsv,
//   at /lib/kit), in the theme in force.
// - A form in a window of Radharc's, placed at 100, 100: its background
//   on the screen; Tab to its field, "Hi" typed (Shift from kbdfs's
//   keymap), Enter submitting it, Control-S running an async action; a
//   click on a button (qemu.sh's `qemu: sendkey`, `qemu: mouse_move`,
//   `qemu: mouse_button`).
// - Neon Tab loaded through theme/ctl: the window redrawn in it, the
//   sample drawn as recorded in it and its own faces; then Platinum Indigo.
// - An idle Kit window: its loop wakes only for a wake.

import Kit
import KitPlatform
import KitSample
import Node
import Sys
import VX
import VectraOSLibc

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String) {
  print(ok ? "kit-test: ok: \(what)" : "kit-test: FAILED: \(what)")
  if !ok { failures += 1 }
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var f = try? ns.open(path) else { return nil }
  return try? f.readText()
}

/// The screen's pixel at x, y (Radharc's `pixel`), as six hex digits.
func pixel(_ ns: Namespace, _ x: Int, _ y: Int) -> String {
  guard var p = try? ns.open("/svc/windows/pixel"), (try? p.writeText("\(x) \(y)")) != nil,
    let text = try? p.readText()
  else { return "" }
  return String(text.filter { $0 != "\n" })
}

func hex(_ c: UInt32) -> String {
  let s = String(c & 0xFF_FFFF, radix: 16)
  return String(repeating: "0", count: 6 - s.count) + s
}

/// Until the screen's pixel at x, y is `want`, or 2 s.
func shows(_ ns: Namespace, _ x: Int, _ y: Int, _ want: String) -> Bool {
  for _ in 0..<100 {
    if pixel(ns, x, y) == want { return true }
    sleep(until: .now + .milliseconds(20))
  }
  print("kit-test: pixel \(x),\(y) is \(pixel(ns, x, y)), not \(want)")
  return false
}

@MainActor final class Form: App {
  var name = ""
  var submitted: String?
  var sent: String?
  var counted = 0
  var title: String { "Form" }
  var actions: [ActionHandler] {
    [ActionHandler(Action("form.send", label: "Send", key: KeyPress(.character(0x73), control: true))) { [self] _ in
       // As a handler awaiting work would.
       for _ in 0..<3 { await Task.yield() }
       sent = name
     }]
  }
  var body: Group {
    VStack {
      Text("Name")
      TextField("Name", text: Binding(self, \.name), width: .pixels(200)) { [self] in submitted = $0 }
      HStack {
        Button(action: "form.send")
        Button("Count") { [self] in counted += 1 }
      }
    }
  }
}

/// The steps after the window's frames, each waiting for what the last
/// asked for.
enum Step { case shown, focused, typed, submitted, sent, clicked, neon, platinum, settle, idle, done }

@main struct KitTest {
  @MainActor static func main() async {
    guard let ns = processNamespace() else {
      print("kit-test: FAILED: no namespace")
      exit(1)
    }
    let installed = Session.installedFonts()
    check(installed.count == 16, "the faces in /lib/fonts are read (\(installed.count))")
    let session: Session
    do { session = try Session() } catch {
      print("kit-test: FAILED: a session: \(error)")
      exit(1)
    }
    check(session.theme.name == "platinum-indigo", "the session is in the theme in force, Platinum Indigo")
    check([FontRole.display, .body, .mono, .ui].allSatisfy { session.fonts.has($0) },
          "its typefaces name a face for each role")

    var recorded: [String: String] = [:]
    for line in (readText(ns, "/lib/kit/kit-sample.tsv") ?? "").split(separator: "\n") where !line.hasPrefix("#") {
      let f = line.split(separator: "\t").map(String.init)
      if f.count == 3 { recorded[f[0] + " " + f[1]] = f[2] }
    }
    func sampleAsRecorded() -> Bool {
      let d = KitSample.digest(KitSample.render(width: 640, height: 400, theme: session.theme, fonts: session.fonts))
      let want = recorded[session.theme.name + " 640x400"] ?? "nothing"
      if d != want { print("kit-test: the sample in \(session.theme.name) is \(d), recorded \(want)") }
      return d == want
    }
    check(sampleAsRecorded(), "the sample is drawn as the host draws it")

    let form = Form()
    let window: KitWindow
    do { window = try session.open(form, width: 320, height: 160, at: (100, 100)) } catch {
      print("kit-test: FAILED: a window: \(error)")
      exit(1)
    }
    // A point of the window's background, on the screen.
    let (bx, by) = (100 + 316, 100 + 156)
    var step = Step.shown
    var idleFrom: UInt64 = 0
    var wakes = 0
    session.onWake = { wakes += 1 }
    let waker = session.waker
    func later(_ ms: Int64) {
      _ = try? Sys.Thread.spawn {
        sleep(until: .now + .milliseconds(ms))
        waker()
      }
    }
    func click(_ label: String, in w: KitWindow) -> Bool {
      guard let b = w.runner.ui.access.first(where: { $0.label == label }) else { return false }
      let pointer = (readText(ns, "/svc/windows/status") ?? "").split(separator: "\n")
        .first { $0.hasPrefix("pointer ") }.map { $0.split(separator: " ").dropFirst().compactMap { Int($0) } } ?? []
      guard pointer.count == 2 else { return false }
      let x = 100 + Int(b.x + b.width / 2), y = 100 + Int(b.y + b.height / 2)
      print("qemu: mouse_move \(x - pointer[0]) \(y - pointer[1])")
      print("qemu: mouse_button 1")
      print("qemu: mouse_button 0")
      return true
    }
    session.afterFrame = { w in
      switch step {
      case .shown:
        check(shows(ns, bx, by, hex(session.theme.color("chrome"))), "the window is drawn on the screen in the theme")
        print("qemu: sendkey tab")
        step = .focused
      case .focused where w.runner.ui.editingText:
        check(true, "Tab reaches the field")
        print("qemu: sendkey shift-h i")
        step = .typed
      case .typed where form.name == "Hi":
        check(true, "the keys type Hi")
        print("qemu: sendkey ret")
        step = .submitted
      case .submitted where form.submitted != nil:
        check(form.submitted == "Hi", "Enter submits it")
        print("qemu: sendkey ctrl-s")
        step = .sent
      case .sent where form.sent != nil && w.runner.running.isEmpty:
        check(form.sent == "Hi", "Control-S runs the async action")
        check(click("Count", in: w), "the pointer is sent to Count")
        step = .clicked
      case .clicked where form.counted > 0:
        check(form.counted == 1, "a click presses a button")
        guard var ctl = try? ns.open("/svc/windows/theme/ctl"), (try? ctl.writeText("load neon-tab\n")) != nil else {
          check(false, "Neon Tab is loaded")
          return true
        }
        step = .neon
      case .neon where session.theme.name == "neon-tab":
        check(true, "the session follows the theme to Neon Tab")
        check(shows(ns, bx, by, hex(session.theme.color("chrome"))), "the window is redrawn in it")
        check(session.fonts.has(.display) && sampleAsRecorded(), "the sample is drawn as recorded in it, in its faces")
        guard var ctl = try? ns.open("/svc/windows/theme/ctl"), (try? ctl.writeText("load platinum-indigo\n")) != nil
        else {
          check(false, "Platinum Indigo is loaded again")
          return true
        }
        step = .platinum
      case .platinum where session.theme.name == "platinum-indigo":
        check(shows(ns, bx, by, hex(session.theme.color("chrome"))), "and back to Platinum Indigo")
        // What the change left to do (a catch-up present) done first.
        later(500)
        step = .settle
      case .settle where wakes == 1:
        idleFrom = session.wakeups
        later(1000)
        step = .idle
      case .idle where wakes == 2:
        // The wake, and the frame it asks for.
        let woke = session.wakeups - idleFrom
        check(woke <= 2, "an idle window's loop wakes only for a wake (\(woke) in a second)")
        step = .done
        return true
      default: break
      }
      return false
    }
    await session.run()
    _ = window
    check(step == .done, "every step is taken")
    print(failures == 0 ? "kit-test: passed" : "kit-test: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
  }
}
