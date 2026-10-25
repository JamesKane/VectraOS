// SPDX-License-Identifier: BSD-3-Clause

// lock-test (boot-lock): the lock screen (D118). factotum, with the
// image's login key, says it can unlock; `lock` locks, a wrong password
// typed on the lock is asked again, the right one unlocks. Control-Alt-
// Delete locks, and while locked empties what was typed. No input for
// Settings' `Lock:Minutes` locks. Radharc killed while locked comes back
// locked, and factotum unlocks it again.

import IPC
import Node
import Radharc
import Settings
import Sys

/// The lines of `path`, as bytes.
func lines(_ ns: Namespace, _ path: String) -> [[UInt8]] {
  guard var f = try? ns.open(path), let b = try? f.readAll() else { return [] }
  return b.split(separator: 0x0A).map(Array.init)
}

/// The numbers on `path`'s line beginning `word `.
func numbers(_ ns: Namespace, _ path: String, _ word: String) -> [Int] {
  let prefix = Array((word + " ").utf8)
  guard let l = lines(ns, path).first(where: { $0.starts(with: prefix) }) else { return [] }
  return l.split(separator: 0x20).compactMap { w -> Int? in
    guard !w.isEmpty, w.count <= 9, w.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return w.reduce(0) { $0 * 10 + Int($1) - 0x30 }
  }
}

/// Radharc's `lock` line has `word`.
func lockSays(_ ns: Namespace, _ word: String) -> Bool {
  let prefix = Array("lock ".utf8), w = Array(word.utf8)
  guard let l = lines(ns, "/svc/windows/status").first(where: { $0.starts(with: prefix) }) else { return false }
  return l.split(separator: 0x20).contains { $0.elementsEqual(w) }
}

/// The lock's counts: ready, locks, unlocks, attentions.
func counts(_ ns: Namespace) -> [Int] { numbers(ns, "/svc/windows/status", "lock") }

/// Questions asked on the prompt, ever.
func asked(_ ns: Namespace) -> Int {
  let n = numbers(ns, "/svc/windows/status", "prompts")
  return n.count >= 2 ? n[1] : -1
}

func ctl(_ ns: Namespace, _ text: String) -> Bool {
  guard var f = try? ns.open("/svc/windows/ctl") else { return false }
  return (try? f.writeText(text)) != nil
}

/// Types `text` (lower case letters and digits) and return, once the
/// question has been up long enough to take return.
func type(_ text: String) {
  sleep(until: Clock.monotonic() + 700_000_000)
  var keys = "qemu: sendkey"
  for c in text.unicodeScalars { keys += " \(c)" }
  print(keys + " ret")
}

/// Locked, the unlock question up (a new one after `before` were asked).
func questionUp(_ ns: Namespace, after before: Int) -> Bool {
  within(15) { asked(ns) > before && numbers(ns, "/svc/windows/status", "prompts").first == 1 }
}

@main struct LockTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("lock-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(within(60) { lockSays(ns, "unlocked") && counts(ns).first == 1 }, "factotum, with a login key, is ready to unlock")

    // `lock`, a wrong password, the right one.
    var a = asked(ns)
    check(ctl(ns, "lock"), "`lock` is taken")
    check(within(10) { lockSays(ns, "locked") }, "the screen is locked")
    check(questionUp(ns, after: a), "factotum asks for the password")
    a = asked(ns)
    type("nope")
    check(questionUp(ns, after: a) && lockSays(ns, "locked"), "a wrong password is asked again, still locked")
    type("hunter2")
    check(within(15) { lockSays(ns, "unlocked") && counts(ns).count >= 3 && counts(ns)[2] == 1 },
          "the right password unlocks")

    // Control-Alt-Delete: locks; locked, it empties the field.
    a = asked(ns)
    print("qemu: sendkey ctrl-alt-delete")
    check(within(10) { lockSays(ns, "locked") && counts(ns).count == 4 && counts(ns)[3] == 1 },
          "Control-Alt-Delete locks")
    check(questionUp(ns, after: a), "and the password is asked for")
    a = asked(ns)
    sleep(until: Clock.monotonic() + 700_000_000)
    print("qemu: sendkey z z z ctrl-alt-delete")
    check(within(10) { counts(ns).count == 4 && counts(ns)[3] == 2 } && lockSays(ns, "locked"),
          "locked, Control-Alt-Delete is taken again and the screen stays locked")
    type("hunter2")
    check(within(15) { lockSays(ns, "unlocked") } && asked(ns) == a, "what it emptied isn't part of the password")

    // No input for a minute locks.
    check(Settings.store("Lock", "Lock:Minutes", .int(1), ns), "Lock:Minutes set to 1")
    a = asked(ns)
    check(within(90) { lockSays(ns, "locked") }, "a minute without input locks")
    check(questionUp(ns, after: a), "and the password is asked for")

    // Killed while locked, Radharc comes back locked.
    _ = Settings.store("Lock", "Lock:Minutes", .int(0), ns)
    sleep(until: Clock.monotonic() + 1_000_000_000)
    let restarts = numbers(ns, "/svc/launcher/status", "windows").last ?? 0
    if var l = try? ns.open("/svc/launcher/ctl") { _ = try? l.writeText("kill windows\n") }
    check(within(30) { (numbers(ns, "/svc/launcher/status", "windows").last ?? 0) > restarts }, "Radharc is restarted")
    check(within(30) { lockSays(ns, "locked") && counts(ns).first == 1 }, "it comes back locked, factotum ready again")
    check(questionUp(ns, after: -1), "and factotum asks for the password again")
    type("hunter2")
    check(within(15) { lockSays(ns, "unlocked") }, "which unlocks it")

    print(failures == 0 ? "lock-test: all passed" : "lock-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
