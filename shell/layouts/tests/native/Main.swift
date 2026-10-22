// SPDX-License-Identifier: BSD-3-Clause

// bin/workspaces-test (boot-workspaces, D116): Radharc's workspaces with
// master-stack and chords. It opens 20 windows, answers the trusted
// prompt that asks whether chords may take keys (Always, recorded in
// Grants), and presses chords through QEMU (`qemu: sendkey`): Super-Shift-T
// tiles the workspace (timed: desktop.mode_switch), Super-J moves focus,
// Super-2 and Super-1 switch workspaces, and Super-Shift-T again puts every
// window back where it was. It kills master-stack and sees the frames
// stay and the layout come back; keeps an app's frame for its next
// window; and revokes the grant, after which a chord does nothing.

import IPC
import Node
import Radharc
import Settings
import Sys

nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: StaticString) {
  checks += 1
  if !ok {
    failures += 1
    print("workspaces-test: FAILED: \(what)")
  }
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var f = try? ns.open(path) else { return nil }
  return try? f.readText()
}

/// Lines of a file, as bytes.
func lines(_ ns: Namespace, _ path: String) -> [[UInt8]] {
  Array((readText(ns, path) ?? "").utf8).split(separator: 0x0A).map { Array($0) }
}

/// The numbers on `path`'s line starting `word `.
func numbers(_ ns: Namespace, _ path: String, _ word: String) -> [Int] {
  let line = lines(ns, path).first { $0.starts(with: Array((word + " ").utf8)) } ?? []
  return line.split(separator: 0x20).dropFirst().filter { $0.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
    .map { $0.reduce(0) { $0 * 10 + Int($1) - 0x30 } }
}

/// Whether `path` has a line starting `start`.
func says(_ ns: Namespace, _ path: String, _ start: String) -> Bool {
  lines(ns, path).contains { $0.starts(with: Array(start.utf8)) }
}

func within(_ seconds: Int64, _ ok: () -> Bool) -> Bool {
  let end = Clock.monotonic() + seconds * 1_000_000_000
  while Clock.monotonic() < end {
    if ok() { return true }
    sleep(until: Clock.monotonic() + 50_000_000)
  }
  return ok()
}

/// `list`'s windows: id and content frame.
func frames(_ ns: Namespace) -> [(id: Int, x: Int, y: Int, w: Int, h: Int)] {
  lines(ns, "/svc/windows/list").compactMap { line in
    let f = line.split(separator: 0x20).prefix(5).map { w -> Int? in
      guard !w.isEmpty, w.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
      return w.reduce(0) { $0 * 10 + Int($1) - 0x30 }
    }
    guard f.count == 5, let id = f[0], let x = f[1], let y = f[2], let w = f[3], let h = f[4] else { return nil }
    return (id, x, y, w, h)
  }
}

/// A window this test holds open.
final class Held {
  var client: RadharcIPC.WindowClient
  let id: UInt32
  init(_ client: consuming RadharcIPC.WindowClient, id: UInt32) {
    self.client = client
    self.id = id
  }
}

/// Opens a window of `w` by `h`, with its app's name if given.
func open(_ compositor: inout RadharcIPC.CompositorClient, _ title: String, _ w: Int, _ h: Int, app: String = "")
  -> Held?
{
  guard let opened = try? compositor.open(title: title, width: UInt32(w), height: UInt32(h)) else { return nil }
  var client = RadharcIPC.WindowClient(channel: opened.takeWindow())
  guard let id = try? client.listID() else { return nil }
  if !app.isEmpty { try? client.setApp(app) }
  return Held(client, id: id)
}

/// Clicks (x, y) once the question has been up long enough to take one.
func click(_ ns: Namespace, _ x: Int, _ y: Int) -> Bool {
  sleep(until: Clock.monotonic() + 700_000_000)
  let p = numbers(ns, "/svc/windows/status", "pointer")
  guard p.count == 2 else { return false }
  print("qemu: mouse_move \(x - p[0]) \(y - p[1])")
  guard within(10, { numbers(ns, "/svc/windows/status", "pointer") == [x, y] }) else { return false }
  print("qemu: mouse_button 1")
  sleep(until: Clock.monotonic() + 100_000_000)
  print("qemu: mouse_button 0")
  return true
}

@main struct WorkspacesTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("workspaces-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let status = "/svc/windows/status", spaces = "/svc/windows/workspaces"
    check(says(ns, status, "workspace 1 of 4"), "four workspaces, the first shown")
    check(within(30) { says(ns, status, "layouts master-stack") }, "master-stack registers")

    // Twenty windows, cascaded on workspace 1.
    guard let ch = try? ns.connect("/svc/windows/compositor") else {
      check(false, "/svc/windows/compositor")
      Process.exit(code: 1)
    }
    var compositor = RadharcIPC.CompositorClient(channel: ch)
    let screen = try? compositor.screen()
    let (sw, sh) = screen.map { (Int($0.width), Int($0.height)) } ?? (0, 0)
    var held: [Held] = []
    for i in 0..<20 {
      if let h = open(&compositor, "w\(i)", 160, 100) { held.append(h) }
    }
    check(held.count == 20, "twenty windows open")
    let spatial = frames(ns)

    // chords asks for `shortcuts`: Always.
    check(within(30) { numbers(ns, status, "prompts").first == 1 }, "chords' question is up")
    let q = try? PromptQuestion(parsing: Array("ask=confirm app=chords service=shortcuts answers=session,always\n".utf8),
                                id: 0, asker: "radharc")
    if let q {
      let layout = PromptLayout(q, screenWidth: sw, screenHeight: sh)
      // Deny, Always, This session: Always is the second.
      let b = layout.buttons[1]
      check(click(ns, b.x + b.width / 2, b.y + b.height / 2), "Always is clicked")
    }
    check(within(20) { numbers(ns, status, "shortcuts").first == 1 && numbers(ns, status, "shortcuts").count >= 2
      && numbers(ns, status, "shortcuts")[1] == 15 }, "chords holds its fifteen chords")
    check(Grants.recorded("chords", "shortcuts", ns) == true, "the answer is recorded in Grants")

    // Super-Shift-T tiles the workspace: master-stack's frames, in time.
    let switches = numbers(ns, status, "switch").last ?? 0
    print("qemu: sendkey meta_l-shift-t")
    check(within(10) { says(ns, spaces, "1 tile master-stack current") }, "Super-Shift-T tiles workspace 1")
    check(within(10) { (numbers(ns, status, "switch").last ?? 0) > switches }, "the switch is timed")
    // A budget, reported (timing is the bench's to judge, not the test's).
    let took = numbers(ns, status, "switch").first ?? 0
    print("workspaces-test: budget name=desktop.mode_switch value=\(took) unit=frames limit=2")
    let newest = held[19].id
    let tiled = frames(ns)
    // The frame's border is the theme's: the master's content starts that
    // far in from the screen's edge.
    let master = tiled.first { $0.id == Int(newest) }
    let b = master?.x ?? -1
    check(master.map { $0.x < 16 && $0.w + 2 * b == sw * 55 / 100 } == true, "the newest window is the master, 55% wide")
    check(tiled.filter { t in held.contains { Int($0.id) == t.id } }.allSatisfy { $0.x == b || $0.x == sw * 55 / 100 + b },
          "every window is in a column")

    // Super-J: focus to the next in the order.
    let focusedBefore = numbers(ns, status, "focused").first ?? 0
    print("qemu: sendkey meta_l-j")
    check(within(10) { (numbers(ns, status, "focused").first ?? 0) != focusedBefore }, "Super-J moves focus")

    // Super-2 shows workspace 2, empty; Super-1 back.
    print("qemu: sendkey meta_l-2")
    check(within(10) { says(ns, spaces, "2 space master-stack current 0") }, "Super-2 shows workspace 2")
    print("qemu: sendkey meta_l-1")
    check(within(10) { says(ns, spaces, "1 tile master-stack current") }, "Super-1 shows workspace 1 again")

    // master-stack killed: the frames stay; restarted, it registers again.
    let restarts = numbers(ns, "/svc/launcher/status", "master-stack").last ?? 0
    if var ctl = try? ns.open("/svc/launcher/ctl") { _ = try? ctl.writeText("kill master-stack\n") }
    check(within(20) { (numbers(ns, "/svc/launcher/status", "master-stack").last ?? 0) > restarts },
          "master-stack is restarted")
    check(within(20) { says(ns, status, "layouts master-stack") }, "and registers again")
    let after = frames(ns)
    check(tiled.allSatisfy { t in after.contains { $0.id == t.id && $0.x == t.x && $0.y == t.y && $0.w == t.w } },
          "the frames stayed")

    // Super-Shift-T again: every window back where it was.
    print("qemu: sendkey meta_l-shift-t")
    check(within(10) { says(ns, spaces, "1 space master-stack current") }, "Super-Shift-T puts it back in space")
    check(within(10) {
      let back = frames(ns)
      return spatial.allSatisfy { s in back.contains { $0.id == s.id && $0.x == s.x && $0.y == s.y && $0.w == s.w && $0.h == s.h } }
    }, "every window is back at its spatial frame")
    check(says(ns, "/svc/windows/status", "workspace 1 of 4"), "still on workspace 1")

    // Spatial memory: an app's window closed at a place opens there again.
    if let wch = try? ns.connect("/svc/windows/windows") {
      var windows = RadharcIPC.WindowsClient(channel: wch)
      // Closed after its last use here.
      if let memo = open(&compositor, "memo", 200, 120, app: "memo") {
        check((try? windows.move(id: memo.id, x: 300, y: 210)) != nil, "memo's window moves")
      }
      check(within(10) { Settings.read("Frames", ns).contains { $0.name.utf8.elementsEqual("Frames:memo".utf8) } },
            "its frame is kept")
      if let again = open(&compositor, "memo", 200, 120, app: "memo") {
        check(within(10) { frames(ns).contains { $0.id == Int(again.id) && $0.x == 300 && $0.y == 210 } },
              "the app's next window opens there")
      }
    }

    // Revoked: Radharc closes chords' channel, and a chord does nothing.
    check(Grants.revoke("chords", "shortcuts", ns), "the grant is revoked")
    check(within(10) { numbers(ns, status, "shortcuts").first == 0 }, "chords' channel is closed")
    check(within(10) { says(ns, "/svc/launcher/status", "chords exited 0") }, "chords ends")
    print("qemu: sendkey meta_l-2")
    sleep(until: Clock.monotonic() + 1_000_000_000)
    check(says(ns, status, "workspace 1 of 4"), "a chord revoked does nothing")

    _ = consume compositor
    print("workspaces-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
