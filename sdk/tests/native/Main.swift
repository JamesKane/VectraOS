// SPDX-License-Identifier: BSD-3-Clause

// bin/sdk-test (boot-sdk): the SDK as an app sees it, on Radharc in QEMU.
// - The reference app, minimal, started beside it: its window opens, and
//   closes after its 120 frames.
// - The loop: timers never early, repeating without drift, posts and wakes
//   from another thread, a wait until a deadline.
// - A window: its first configure, frames before and after a present,
//   what it drew on the screen (Radharc's `pixel`), a key and the pointer
//   from QEMU's monitor (qemu.sh's `qemu: sendkey`, `qemu: mouse_move`).
// - Drag and drop: a press held on the window, a drag of text from it
//   (`Drag.start`), over a second window, which accepts it, and dropped
//   there: the text read, and no more after its next press.
// - Crash survival: Radharc killed through the launcher's ctl, and the
//   window back when it restarts.
// - Routing: a URL sent to the plumber comes back on the web port.
// - Idle: a loop with nothing due wakes once in a second, at its deadline.

import Node
import Sys
import VX

nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("sdk-test: FAILED: \(name)")
  }
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var c = try? ns.open(path) else { return nil }
  return try? c.readText()
}

/// Whether `text` holds `part` (bytes).
func holds(_ text: String, _ part: String) -> Bool {
  let t = Array(text.utf8), p = Array(part.utf8)
  guard p.count <= t.count else { return false }
  for i in 0...(t.count - p.count) where Array(t[i..<i + p.count]) == p { return true }
  return false
}

/// Takes events until `want` passes one or `seconds` go by.
func waitFor(_ loop: inout Loop, seconds: UInt64, _ want: (Event) -> Bool) -> Bool {
  let end = Deadline.now + .seconds(Int64(seconds))
  while Deadline.now < end {
    for e in loop.wait(until: end) where want(e) { return true }
  }
  return false
}

@main struct SDKTest {
  static func main() {
    guard let ns = processNamespace() else {
      print("sdk-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    reference(ns)
    guard var loop = try? Loop() else {
      print("sdk-test: FAILED: no loop")
      Process.exit(code: 1)
    }
    timers(&loop)
    window(&loop, ns)
    routing(&loop)
    idle(&loop)
    print("sdk-test: \(checks - failures)/\(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }

  /// minimal's window comes and, after its frames, goes.
  static func reference(_ ns: Namespace) {
    func listed() -> Bool { holds(readText(ns, "/svc/windows/list") ?? "", " minimal\n") }
    var seen = false, gone = false
    let end = Clock.monotonic() + 30_000_000_000
    while Clock.monotonic() < end && !gone {
      if listed() { seen = true } else if seen { gone = true }
      if !gone { sleep(until: Clock.monotonic() + 5_000_000) }
    }
    check(seen, "minimal opens its window")
    check(gone, "minimal closes it after its frames")
  }

  static func timers(_ loop: inout Loop) {
    let start = Deadline.now
    let once = loop.timer(at: start + .milliseconds(30))
    var firedAt: Deadline?
    check(waitFor(&loop, seconds: 2) { e in
      guard case .timer(let id, _) = e.payload, id == once else { return false }
      firedAt = e.time
      return true
    }, "a timer fires")
    check(firedAt.map { $0 >= start + .milliseconds(30) } ?? false, "never before its deadline")

    let first = Deadline.now + .milliseconds(10)
    let every = loop.timer(at: first, repeating: .milliseconds(10))
    var ticks: [Deadline] = []
    _ = waitFor(&loop, seconds: 2) { e in
      guard case .timer(let id, _) = e.payload, id == every else { return false }
      ticks.append(e.time)
      return ticks.count == 5
    }
    loop.cancel(every)
    check(ticks.count == 5, "a repeating timer repeats")
    check(ticks.enumerated().allSatisfy { $0.element >= first + .milliseconds(10 * Int64($0.offset)) },
          "each repeat at or after its own deadline, from the first (no drift)")

    let remote = loop.remote
    // All of it before the loop runs again: the thread joined first.
    if let t = try? Thread.spawn({
      remote.post(Message(1, 2))
      remote.post(Message(3))
      remote.wake()
      remote.wake()
    }) {
      try? Thread.join(t)
    }
    var messages: [Message] = [], wakes = 0
    let end = Deadline.now + .seconds(2)
    while Deadline.now < end && (messages.count < 2 || wakes == 0) {
      for e in loop.wait(until: end) {
        if case .message(let m) = e.payload { messages.append(m) }
        if case .wake = e.payload { wakes += 1 }
      }
    }
    check(messages == [Message(1, 2), Message(3)], "posts from another thread arrive in order")
    check(wakes == 1, "wakes are coalesced")

    let until = Deadline.now + .milliseconds(20)
    let events = loop.wait(until: until)
    check(events.isEmpty && Deadline.now >= until, "a wait with nothing to report returns at its deadline")
  }

  static func window(_ loop: inout Loop, _ ns: Namespace) {
    guard let win = try? loop.openWindow("sdk-test", width: 200, height: 120) else {
      return check(false, "a window opens")
    }
    var config: Configure?
    check(waitFor(&loop, seconds: 5) { e in
      guard case .configure(let c) = e.payload, e.window == win else { return false }
      config = c
      return true
    }, "its first configure comes as an event")
    check(config.map { $0.width == 200 && $0.height == 120 && $0.pixelWidth == 200 && $0.scale == 120 } ?? false,
          "its size, at 1x")
    check(config?.focused ?? false, "it has focus")
    // (Bytes compared: tier 0's strings have no Unicode tables.)
    let listed = (readText(ns, "/svc/windows/list") ?? "").utf8.split(separator: 0x0A)
      .first { $0.reversed().starts(with: " sdk-test".utf8.reversed()) }
    check(loop.listID(win).map { id in listed?.starts(with: "\(id) ".utf8) ?? false } ?? false, "its id is the window list's")
    loop.placeWindow(win, x: 100, y: 100)
    let seq = config?.configSeq ?? 0

    /// A frame for the window: the loop's own before a present is
    /// answered, Radharc's after.
    func frame() -> Frame? {
      loop.requestFrame(win)
      var got: Frame?
      _ = waitFor(&loop, seconds: 5) { e in
        guard case .frame(let f) = e.payload, e.window == win else { return false }
        got = f
        return true
      }
      return got
    }
    let first = frame()
    check(first?.estimated ?? false, "the first frame is the loop's own, at once")
    guard let px = loop.cpuSurface(win) else { return check(false, "a surface to draw in") }
    check(px.width == 200 && px.height == 120 && px.stride == 800 && px.age == 0, "the surface is the window's size")
    px.fill(0x0033_6699)
    check((try? loop.present(win, px, configSeq: seq)) != nil, "it presents")
    let second = frame()
    check(second.map { !$0.estimated && $0.presentedAt != nil && $0.refresh != nil } ?? false,
          "the next frame is Radharc's answer: when it was shown, and the refresh")
    check(second.map { $0.target > Deadline.now } ?? false, "aimed at a vblank to come")
    func pixel(_ x: Int, _ y: Int) -> String {
      guard var p = try? ns.open("/svc/windows/pixel"), (try? p.writeText("\(x) \(y)")) != nil,
        let text = try? p.readText()
      else { return "" }
      return String(decoding: text.utf8.filter { $0 != 0x0A }, as: UTF8.self)
    }
    check(pixel(150, 160).utf8.elementsEqual("336699".utf8), "what it drew is on the screen where it placed it")
    if let stale = loop.cpuSurface(win) {
      check((try? loop.present(win, stale, configSeq: seq + 1)) == nil, "a surface for another configure is refused")
    }

    print("qemu: sendkey a")
    var key: Key?
    check(waitFor(&loop, seconds: 20) { e in
      guard case .keyDown(let k) = e.payload, e.window == win else { return false }
      key = k
      return true
    }, "a key comes to the focused window")
    check(key.map { $0.usage == .a && $0.character == 0x61 && $0.modifiers.isEmpty } ?? false,
          "as its usage and its character")
    let pointer = Array((readText(ns, "/svc/windows/status") ?? "").utf8).split(separator: 0x0A)
      .first { $0.starts(with: Array("pointer ".utf8)) }
      .map { $0.split(separator: 0x20).dropFirst().map { $0.reduce(0) { $0 * 10 + Int($1) - 0x30 } } } ?? []
    if pointer.count == 2 { print("qemu: mouse_move \(150 - pointer[0]) \(160 - pointer[1])") }
    check(pointer.count == 2 && waitFor(&loop, seconds: 20) { e in
      guard case .pointer(let p) = e.payload, e.window == win else { return false }
      return p.action == .motion && p.x == 50 && p.y == 60
    }, "the pointer over it comes in its content's points")
    drag(&loop, from: win)
    // The file chooser isn't drawn yet: refused, as it says.
    var refused = false
    do throws(WindowError) { try loop.choose(win, types: ["text/plain"]) } catch {
      if case .unavailable = error { refused = true }
    }
    check(refused, "the file chooser is refused, not there yet")

    // Radharc ended as a crash would: the program carries on, frames from
    // the loop's own estimate, until the launcher has restarted it; then
    // the window is open again, its last present where it was placed.
    guard var ctl = try? ns.open("/svc/launcher/ctl"), (try? ctl.writeText("kill windows")) != nil else {
      return check(false, "Radharc is killed")
    }
    var reconfigured = false, framesMeanwhile = 0
    let end = Deadline.now + .seconds(30)
    loop.requestFrame(win)
    while Deadline.now < end && !reconfigured {
      for e in loop.wait(until: end) where e.window == win {
        if case .frame(let f) = e.payload, f.estimated {
          framesMeanwhile += 1
          loop.requestFrame(win)
        }
        if case .configure = e.payload { reconfigured = true }
      }
    }
    check(framesMeanwhile > 0, "frames come while Radharc is gone")
    check(reconfigured, "the window is opened again in Radharc restarted, with a configure")
    var shown = false
    for _ in 0..<100 where !shown {
      shown = pixel(150, 160).utf8.elementsEqual("336699".utf8)
      if !shown { _ = loop.wait(until: Deadline.now + .milliseconds(20)) }
    }
    check(shown, "its last present is shown again where it was placed")
    loop.closeWindow(win)
  }

  /// Whether `types` is just `type` (bytes: tier 0 has no Unicode tables).
  static func only(_ types: [String], _ type: String) -> Bool {
    types.count == 1 && types[0].utf8.elementsEqual(type.utf8)
  }

  /// A drag of text from `win`, under the pointer, dropped on a second window.
  static func drag(_ loop: inout Loop, from win: WindowID) {
    guard let target = try? loop.openWindow("drop target", width: 160, height: 100) else {
      return check(false, "a second window opens")
    }
    loop.placeWindow(target, x: 400, y: 100)
    _ = waitFor(&loop, seconds: 5) { e in
      if case .configure = e.payload { return e.window == target }
      return false
    }
    print("qemu: mouse_button 1")
    check(waitFor(&loop, seconds: 10) { e in
      guard case .pointer(let p) = e.payload, e.window == win else { return false }
      return p.action == .down(.left)
    }, "a press held on the window")
    check(Drag.start([(type: "text/plain", bytes: Array("dragged".utf8))]), "a drag of text starts from it")
    check(waitFor(&loop, seconds: 5) { e in
      guard case .dragOver(let types, _, _) = e.payload, e.window == win else { return false }
      return only(types, "text/plain")
    }, "the window under the pointer hears the drag")
    // Over the second window, at (480, 150): the first hears it left.
    print("qemu: mouse_move 330 -10")
    var left = false
    check(waitFor(&loop, seconds: 10) { e in
      if case .dragLeft = e.payload, e.window == win { left = true }
      guard case .dragOver(let types, let x, let y) = e.payload, e.window == target else { return false }
      return only(types, "text/plain") && x == 80 && y == 50
    }, "the second hears it, in its points")
    check(left, "and the first that it left")
    loop.acceptDrag(target, types: ["text/plain"])
    print("qemu: mouse_button 0")
    // (Both may come in one batch: waited for together.)
    var ended = false, dropped = false
    _ = waitFor(&loop, seconds: 10) { e in
      if case .dragEnded(let d) = e.payload, e.window == win { ended = d }
      if case .drop(let types, _, _) = e.payload, e.window == target { dropped = only(types, "text/plain") }
      return ended && dropped
    }
    check(dropped, "the release drops it on the window that accepted it")
    check(ended, "its source hears it was dropped")
    check(Drag.read(type: "text.plain").map { $0 == Array("dragged".utf8) } ?? false, "the dropped text is read")
    print("qemu: mouse_button 1")
    print("qemu: mouse_button 0")
    _ = waitFor(&loop, seconds: 5) { e in
      guard case .pointer(let p) = e.payload, e.window == target else { return false }
      return p.action == .down(.left)
    }
    check(Drag.read(type: "text.plain") == nil, "and not after the window's next press")
    loop.closeWindow(target)
  }

  static func routing(_ loop: inout Loop) {
    guard let web = try? loop.listen(port: "web") else { return check(false, "it listens on the web port") }
    check((try? loop.listen(port: "no-such-port")) == nil, "a port the plumber hasn't is refused")
    check((try? loop.route(RouteMessage(src: "sdk-test", data: "https://vectra-os.org"))) != nil, "a URL is sent")
    var got: RouteMessage?
    check(waitFor(&loop, seconds: 10) { e in
      guard case .routed(let id, let m) = e.payload, id == web else { return false }
      got = m
      return true
    }, "it comes back on the web port")
    check(got.map { $0.data.utf8.elementsEqual("https://vectra-os.org".utf8) && $0.src.utf8.elementsEqual("sdk-test".utf8) }
          ?? false, "as it was sent")
    check((try? loop.route(RouteMessage(src: "sdk-test", data: "nothing takes this"))) == nil,
          "a message no rule takes is refused")
  }

  /// With nothing due, a wait of a second is one wakeup: its deadline's.
  static func idle(_ loop: inout Loop) {
    _ = loop.poll()
    let before = loop.wakeups
    let events = loop.wait(until: Deadline.now + .seconds(1))
    check(events.isEmpty && loop.wakeups - before == 1, "an idle loop wakes only at its deadline")
  }
}
