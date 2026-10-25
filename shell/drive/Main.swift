// SPDX-License-Identifier: BSD-3-Clause

// bin/drive (drive(1)): runs a script of a user's input against the
// desktop and says what each step cost. The pointer goes to the mouse
// service's mousein as absolute records (`A x y buttons`) and keys to
// kbdfs's kbin as HID usages, where xhci's and virtio-input's go, so
// everything above them sees a hand's input. `settle` waits until Radharc
// composes no frame for a while and prints the time from the last input
// to the last frame, the frames composed, and the processes that used
// CPU meanwhile (/proc); `waitfor` waits for a window's title in
// Radharc's list. Script(lib) parses the lines.

import IPC
import Node
import Sys

func fail(_ what: String) -> Never {
  print("drive: \(what)")
  Process.exit(code: 1)
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var f = try? ns.open(path) else { return nil }
  return try? f.readText()
}

/// Radharc's `frames` count, from its status.
func frames(_ ns: Namespace) -> Int? {
  for line in lines(readText(ns, "/svc/windows/status") ?? "") {
    let w = words(line)
    if w.count == 2, same(w[0], "frames") { return Int(w[1]) }
  }
  return nil
}

/// Whether a window titled `title` is in Radharc's list (`id x y w h
/// focused title`).
func showing(_ ns: Namespace, _ title: String) -> Bool {
  lines(readText(ns, "/svc/windows/list") ?? "").contains { line in
    let w = words(line)
    return w.count >= 7 && same(w[6...].joined(separator: " "), title)
  }
}

func lines(_ text: String) -> [String] { text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) } }

/// Each process's name and CPU milliseconds (user and system), by pid,
/// from /proc's `status` lines (proc(4): name, user and state padded to
/// 27, 27 and 11 columns, then numbers of 11).
func cpuTimes(_ ns: Namespace) -> [(pid: String, name: String, ms: Int)] {
  var out: [(pid: String, name: String, ms: Int)] = []
  for e in (try? ns.list("/proc")) ?? [] {
    guard e.name.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let line = readText(ns, "/proc/\(e.name)/status") else {
      continue
    }
    let b = Array(line.utf8)
    guard b.count >= 87 else { continue }
    func number(_ at: Int) -> Int { Int(String(decoding: b[at..<at + 11], as: UTF8.self).utf8.split(separator: 0x20).first.map { String(decoding: $0, as: UTF8.self) } ?? "") ?? 0 }
    let name = String(decoding: b[0..<27], as: UTF8.self).utf8.split(separator: 0x20).first.map { String(decoding: $0, as: UTF8.self) } ?? "?"
    out.append((e.name, name, number(65) + number(76)))
  }
  return out
}

/// What used CPU between two snapshots, the most first.
func spent(_ before: [(pid: String, name: String, ms: Int)], _ after: [(pid: String, name: String, ms: Int)]) -> String {
  var used: [(name: String, ms: Int)] = []
  // (Not drive's own, nor proc's, which serves its reads of /proc.)
  for a in after where !same(a.name, "drive") && !same(a.name, "proc") {
    let was = before.first { same($0.pid, a.pid) }?.ms ?? 0
    if a.ms > was { used.append((a.name, a.ms - was)) }
  }
  used.sort { $0.ms > $1.ms }
  let top = used.prefix(4).map { "\($0.name) \($0.ms) ms" }
  return top.isEmpty ? "no CPU" : "cpu " + top.joined(separator: ", ")
}

@main struct Drive {
  static func main() {
    let start = Startup.current
    let args = Array(start.args.dropFirst())
    guard args.count == 1 else { fail("usage: drive SCRIPT") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    guard let text = readText(ns, args[0]) else { fail("can't read \(args[0])") }
    var steps: [(line: String, step: Step)] = []
    for (i, line) in lines(text).enumerated() {
      do throws(ScriptError) {
        if let s = try Step.parse(line) { steps.append((line, s)) }
      } catch {
        fail("\(args[0]):\(i + 1): \(error.text)")
      }
    }
    guard var mouse = try? ns.open("/svc/mouse/mousein") else { fail("no /svc/mouse/mousein (its namespace's `use mouse`)") }
    guard var keys = try? ns.open("/svc/kbdfs/kbin") else { fail("no /svc/kbdfs/kbin (its namespace's `use kbdfs`)") }

    var x: Int32 = 0, y: Int32 = 0, buttons: Int32 = 0
    var lastInput = Clock.monotonic()
    var before = cpuTimes(ns)
    func pointer() {
      _ = try? mouse.writeText("A \(x) \(y) \(buttons)\n")
      lastInput = Clock.monotonic()
    }
    func key(_ usage: UInt8, _ down: Bool) {
      _ = try? keys.write(offset: 0, [usage, down ? 1 : 0])
      lastInput = Clock.monotonic()
    }
    func pause(_ ms: Int) { Sys.sleep(until: Clock.monotonic() + Int64(ms) * 1_000_000) }
    let began = Clock.monotonic()

    for (line, step) in steps {
      switch step {
      case .move(let px, let py):
        (x, y) = (px, py)
        pointer()
      case .press(let b):
        buttons |= b.rawValue
        pointer()
      case .release(let b):
        buttons &= ~b.rawValue
        pointer()
      case .click(let b, let px, let py):
        if let px, let py {
          (x, y) = (px, py)
          pointer()
          pause(30)
        }
        buttons |= b.rawValue
        pointer()
        pause(60)
        buttons &= ~b.rawValue
        pointer()
      case .keys(let chords):
        for chord in chords {
          for u in chord { key(u, true) }
          pause(30)
          for u in chord.reversed() { key(u, false) }
          pause(30)
        }
      case .type(let chars):
        for c in chars {
          if c.shift { key(0xE1, true) }
          key(c.usage, true)
          pause(20)
          key(c.usage, false)
          if c.shift { key(0xE1, false) }
          pause(20)
        }
      case .wait(let ms):
        pause(ms)
      case .settle(let quiet, let limit):
        guard let f0 = frames(ns) else { fail("no /svc/windows/status (its namespace's `use windows`)") }
        var s = Settling(start: lastInput, frames: f0)
        let until = lastInput + Int64(limit) * 1_000_000
        var settled = false
        while Clock.monotonic() < until {
          if s.sample(now: Clock.monotonic(), frames: frames(ns) ?? s.frames, quiet: Int64(quiet) * 1_000_000) {
            settled = true
            break
          }
          pause(10)
        }
        let after = cpuTimes(ns)
        print("drive: \(line): \(s.busy / 1_000_000) ms to the last frame, \(s.composed) frames"
          + (settled ? "" : ", not settled in \(limit) ms") + "; \(spent(before, after))")
        before = after
      case .waitFor(let title, let limit):
        let from = lastInput
        let until = Clock.monotonic() + Int64(limit) * 1_000_000
        while !showing(ns, title) && Clock.monotonic() < until { pause(10) }
        let found = showing(ns, title)
        print("drive: \(line): " + (found ? "\((Clock.monotonic() - from) / 1_000_000) ms" : "not in \(limit) ms"))
      case .mark(let label):
        print("drive: \(label)")
      }
    }
    print("drive: done, \(steps.count) steps in \((Clock.monotonic() - began) / 1_000_000) ms")
    _ = consume mouse
    _ = consume keys
  }
}
