// SPDX-License-Identifier: BSD-3-Clause

// notices-test (boot-notices): notices on the desktop (D117). A notice
// posted shows a slip named for this test's app, in a panel that goes
// when its slips do; a bad line is refused; a slip that stays is
// dismissed by a click. What is copied is kept as a file in /data/Clips
// with its Clip: attributes, a secret entry and the newest again are
// not; a clip is put back on the clipboard and forgotten; the drawer
// opens and closes. notices killed comes back with its clips, within the
// limit Settings gives it, and with no slips its loop doesn't wake.

import Fs
import IPC
import Node
import Radharc
import Settings
import Sys
import VX
import VectraOSLibc

func lines(_ ns: Namespace, _ path: String) -> [String] {
  (ns.readText(path) ?? "").split(separator: "\n").map(String.init)
}

func status(_ ns: Namespace) -> [String] { lines(ns, "/svc/notices/status") }
func says(_ ns: Namespace, _ line: String) -> Bool { status(ns).contains(line) }

/// The words after `word` on its line of `path`, as numbers.
func numbers(_ ns: Namespace, _ path: String, _ word: String) -> [Int] {
  guard let l = lines(ns, path).first(where: { $0.hasPrefix(word + " ") }) else { return [] }
  return l.split(separator: " ").compactMap { Int($0) }
}

/// Radharc's window titled `title`: its id and content frame.
func window(_ ns: Namespace, _ title: String) -> [Int]? {
  for l in lines(ns, "/svc/windows/list") {
    let f = l.split(separator: " ", maxSplits: 6).map(String.init)
    if f.count == 7, f[6] == title { return f.prefix(5).compactMap { Int($0) } }
  }
  return nil
}

/// Clicks (x, y).
func click(_ ns: Namespace, _ x: Int, _ y: Int) -> Bool {
  let p = numbers(ns, "/svc/windows/status", "pointer")
  guard p.count == 2 else { return false }
  print("qemu: mouse_move \(x - p[0]) \(y - p[1])")
  guard within(10, { numbers(ns, "/svc/windows/status", "pointer") == [x, y] }) else { return false }
  print("qemu: mouse_button 1")
  sleep(until: Clock.monotonic() + 100_000_000)
  print("qemu: mouse_button 0")
  return true
}

/// Radharc's clipboard commits, and the entries it fed.
func commits(_ ns: Namespace) -> (Int, Int) {
  let n = numbers(ns, "/svc/windows/status", "clip")
  return n.count == 3 ? (n[0], n[2]) : (-1, -1)
}

/// A clip file's attributes.
func attributes(_ ns: Namespace, _ name: String) -> [NodeIPC.Attribute] {
  guard var n = try? ns.open("/data/Clips/" + name), let st = try? n.stat(fields: NodeIPC.Fields.attributes) else {
    return []
  }
  return st.attributes
}

@main struct NoticesTest {
  static func main() {
    guard let ns = processNamespace() else {
      print("notices-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(within(60) { says(ns, "ready") && says(ns, "clipboard open") },
          "notices is ready and reads Radharc's clipboard")
    check((try? ns.open("/svc/windows/clipboard")) == nil, "a client not granted `windows clipboard` has no clipboard")
    check(says(ns, "slips 0") && window(ns, "Notices") == nil, "with no slips, notices has no panel")

    // A notice: its slip, named for this app, in a panel.
    check(ns.writeText("/svc/notices/post", "title=Hello body=\"from the test\" lamp=info\n"), "a notice is posted")
    check(within(10) { says(ns, "slip 1 notices-test info Hello") }, "its slip names this test's app")
    check(within(10) { window(ns, "Notices") != nil }, "the slips' panel is open")
    check(!ns.writeText("/svc/notices/post", "title=x lamp=red\n"), "a lamp that isn't one is refused")
    check(!ns.writeText("/svc/notices/post", "body=nothing\n"), "a notice without a title is refused")
    check(within(15) { says(ns, "slips 0") } && within(10) { window(ns, "Notices") == nil },
          "the slip goes after its life, and the panel with it")

    // One that stays, clicked away.
    check(ns.writeText("/svc/notices/post", "title=Failed lamp=fail\n"), "a failure is posted")
    check(within(10) { says(ns, "slip 2 notices-test fail Failed") }, "its slip shows")
    sleep(until: Clock.monotonic() + 8_000_000_000)
    check(says(ns, "slips 1"), "a failure's slip stays past a slip's life")
    if let w = window(ns, "Notices"), w.count == 5 {
      check(click(ns, w[1] + w[3] / 2, w[2] + w[4] / 2), "the slip is clicked")
      check(within(10) { says(ns, "slips 0") }, "a click dismisses it")
    } else {
      check(false, "the slips' panel to click")
    }
    check(says(ns, "history 2"), "the history holds both notices")

    // The clipboard's history.
    let (c0, f0) = commits(ns)
    check(ns.writeText("/svc/windows/snarf", "copied once"), "text is copied")
    check(within(10) { says(ns, "clips 1") && says(ns, "clip 1 notices-test text/plain;charset=utf-8") },
          "notices keeps it as clip 1, from this test")
    let a = attributes(ns, "1")
    func string(_ n: String) -> String? { a.first { $0.name == n }.map { String(decoding: $0.value, as: UTF8.self) } }
    let time = a.first { $0.name == "Clip:Time" }.map { $0.value.reversed().reduce(0) { $0 << 8 | Int64($1) } } ?? 0
    check(string("Clip:Source") == "notices-test" && string("Clip:Types") == "text/plain;charset=utf-8",
          "its file has Clip:Source and Clip:Types")
    check(time > 0, "and Clip:Time")
    check(ns.writeText("/svc/windows/clip/new", "secret=1 type=text/plain length=6\nhunter"), "a secret entry is copied")
    check(within(10) { commits(ns).0 == c0 + 2 }, "Radharc commits it")
    check(commits(ns).1 == f0 + 1, "but doesn't feed it to the history")
    check(ns.writeText("/svc/windows/snarf", "copied once"), "the first text is copied again")
    check(within(10) { commits(ns).1 == f0 + 2 }, "Radharc feeds it")
    check(ns.writeText("/svc/windows/snarf", "copied twice"), "other text is copied")
    check(within(10) { says(ns, "clips 2") && says(ns, "clip 2 notices-test text/plain;charset=utf-8") },
          "the newest again isn't kept twice, the other is clip 2")

    // A clip put back, and forgotten.
    let (c1, _) = commits(ns)
    check(ns.writeText("/svc/notices/ctl", "paste 1"), "clip 1 is put back")
    check(within(10) { commits(ns).0 == c1 + 1 }, "on the clipboard, a commit of its own")
    check(within(10) { says(ns, "clips 3") }, "and kept again as the newest")
    check(ns.writeText("/svc/notices/ctl", "forget 3"), "clip 3 is forgotten")
    check(within(10) { says(ns, "clips 2") } && (try? ns.open("/data/Clips/3")) == nil, "and its file is gone")
    check(!ns.writeText("/svc/notices/ctl", "forget 3"), "it can't be forgotten twice")

    // The drawer.
    check(ns.writeText("/svc/notices/ctl", "drawer"), "the drawer is asked for")
    check(within(10) { says(ns, "drawer open") && window(ns, "Drawer") != nil }, "it opens")
    check(ns.writeText("/svc/notices/ctl", "drawer"), "and asked again")
    check(within(10) { says(ns, "drawer closed") && window(ns, "Drawer") == nil }, "it closes")

    // Killed, it comes back with its clips, within the limit.
    check(Settings.store("Drawer", "Drawer:Clips", .int(1), ns), "Drawer:Clips set to 1")
    let restarts = numbers(ns, "/svc/launcher/status", "notices").last ?? 0
    check(ns.writeText("/svc/launcher/ctl", "kill notices\n"), "notices is killed")
    check(within(20) { (numbers(ns, "/svc/launcher/status", "notices").last ?? 0) > restarts }, "and restarted")
    check(within(60) { says(ns, "ready") && says(ns, "clips 1") && says(ns, "clip 2 notices-test text/plain;charset=utf-8") },
          "it keeps the newest clip only, as the limit says")
    check((try? ns.open("/data/Clips/1")) == nil, "the older clip's file is removed")

    // With no slips, nothing wakes it.
    sleep(until: Clock.monotonic() + 1_000_000_000)
    let before = numbers(ns, "/svc/notices/status", "wakeups")
    sleep(until: Clock.monotonic() + 10_000_000_000)
    let after = numbers(ns, "/svc/notices/status", "wakeups")
    check(!before.isEmpty && before == after, "with no slips, its loop wakes 0 times in 10 s")

    check(ns.writeText("/svc/notices/ctl", "clear"), "the clips are cleared")
    check(within(10) { says(ns, "clips 0") } && (try? ns.list("/data/Clips"))?.isEmpty == true,
          "every clip and its file goes")
    print(failures == 0 ? "notices-test: all passed" : "notices-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
