// SPDX-License-Identifier: BSD-3-Clause

// bin/desktop-test (boot-desktop, D107): Radharc on the boot framebuffer,
// as its first clients see it. It opens a window, places it, presents a
// solid layer and an image over it, and looks at the screen through
// Radharc's `pixel`; types a key and moves the mouse through QEMU's monitor
// (qemu.sh's `qemu: sendkey` and `qemu: mouse_move`) and reads them from
// the window's ring; checks that the console moved into a window; and works
// the theme tree: Platinum Indigo in force and mapped, Neon Tab loaded
// through ctl, heard on events and drawn, a missing theme refused. The
// boot's screendump is checked after it (vx check-pixels): the window's
// layers where it placed them, on Platinum Indigo's desk.

import IPC
import Light
import Node
import Radharc
import Sys
import Themes

nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("desktop-test: FAILED: \(name)")
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

/// Whether the composed pixel at (x, y) is `rgb`, as Radharc's `pixel`
/// reads it (compared as bytes: String's == needs Unicode tables).
func pixel(_ ns: Namespace, _ x: Int, _ y: Int, is rgb: String) -> Bool {
  guard var p = try? ns.open("/svc/windows/pixel"), (try? p.writeText("\(x) \(y)")) != nil,
    let text = try? p.readText()
  else { return false }
  return text.utf8.filter { $0 != 0x0A }.elementsEqual(rgb.utf8)
}

/// Waits for `want` in the window's events, up to `seconds`.
func waitFor(_ client: inout RadharcIPC.WindowClient, seconds: Int64, _ want: (RadharcIPC.WindowEvent) -> Bool) -> Bool {
  let deadline = Clock.monotonic() + seconds * 1_000_000_000
  while let e = try? client.nextEvent(deadline: deadline) {
    if want(e) { return true }
  }
  return false
}

/// Takes events from the ring until `want` passes one, up to `seconds`.
func waitFor(_ ring: inout InputConsumer, _ doorbell: borrowing Handle, seconds: Int64,
           _ want: (InputEvent) -> Bool) -> Bool
{
  let deadline = Clock.monotonic() + seconds * 1_000_000_000
  while Clock.monotonic() < deadline {
    while let e = ring.pop() {
      if want(e) { return true }
    }
    let rung = (try? Counter.read(doorbell)) ?? 0
    if ring.prepareSleep() { _ = try? Counter.wait(doorbell, until: rung + 1, deadline: deadline) }
    ring.endSleep()
  }
  return false
}

@main struct DesktopTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("desktop-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let status = readText(ns, "/svc/windows/status") ?? ""
    print("desktop-test: radharc: \(status)")
    check(holds(status, "display framebuffer "), "Radharc is on the boot framebuffer")
    check(holds(status, "input keys /dev/kbd, pointer /dev/mouse"), "Radharc reads /dev/kbd and /dev/mouse")

    // The console in a window: Radharc's first client.
    var consoleWindow = false
    for _ in 0..<100 where !consoleWindow {
      consoleWindow = holds(readText(ns, "/svc/windows/list") ?? "", " console\n")
        && holds(readText(ns, "/mnt/console/status") ?? "", "window ")
      if !consoleWindow { sleep(until: Clock.monotonic() + 50_000_000) }
    }
    check(consoleWindow, "the console moved into a window")

    guard let channel = try? ns.connect("/svc/windows/compositor") else {
      check(false, "/svc/windows/compositor")
      Process.exit(code: 1)
    }
    var compositor = RadharcIPC.CompositorClient(channel: channel)
    let screen = try? compositor.screen()
    check(screen.map { $0.width >= 640 && $0.height >= 480 } == true, "the screen is the framebuffer's")
    let (w, h) = (200, 120)
    guard let opened = try? compositor.open(title: "desktop-test", width: UInt32(w), height: UInt32(h)),
      let input = try? opened.input.duplicate(), let doorbell = try? opened.doorbell.duplicate()
    else {
      check(false, "a window opens")
      Process.exit(code: 1)
    }
    let first = opened.first
    var window = RadharcIPC.WindowClient(channel: opened.takeWindow())
    check(first.width == UInt32(w) && first.height == UInt32(h) && first.focused, "its first configure: its size, focused")
    check((try? window.place(x: 100, y: 100)) != nil, "it places itself")
    // An image of 40 by 20, its first row red, the rest green.
    let bytes = 40 * 20 * 4
    guard let vmo = try? VMO.create(size: bytes), let pixels = try? VMO.map(vmo, length: 4096),
      let acquire = try? Counter.create(), let release = try? Counter.create(),
      let a = try? acquire.duplicate(), let r = try? release.duplicate(), let shared = try? vmo.duplicate()
    else {
      check(false, "its image")
      Process.exit(code: 1)
    }
    let p = unsafe pixels.address.assumingMemoryBound(to: UInt32.self)
    for i in 0..<(40 * 20) { unsafe p[i] = i < 40 ? 0x00FF_0000 : 0x0000_FF00 }
    check((try? window.addImage(id: 1, vmo: shared, width: 40, height: 20, stride: 40, acquire: a, release: r)) != nil,
          "it adds an image")
    try? Counter.add(acquire, 1)
    let all = RadharcIPC.Area(x: 0, y: 0, width: Int32(w), height: Int32(h))
    let presented = (try? window.present(
      seq: first.seq, width: UInt32(w), height: UInt32(h),
      layers: [RadharcIPC.Layer(image: 0, color: 0x0033_6699, area: all),
               RadharcIPC.Layer(image: 1, color: 0, area: RadharcIPC.Area(x: 10, y: 10, width: 40, height: 20))],
      damage: [], acquire: 1, number: 1)) != nil
    check(presented, "it presents")
    var credits: UInt32 = 0
    check(waitFor(&window, seconds: 10) { e in
      if case .frame(let f) = e, f.presented == 1 {
        credits = f.credits
        return true
      }
      return false
    }, "a frame for its present")
    check(credits == 1, "the frame gives its credit back")
    // Where it is now, from the list: its content at 100, 100.
    let list = readText(ns, "/svc/windows/list") ?? ""
    print("desktop-test: the list: \(list)")
    check(holds(list, " 100 100 200 120 focused desktop-test\n"), "the list has it where it placed itself, focused")
    check(pixel(ns, 150, 180, is: "336699"), "the solid layer is on the screen")
    check(pixel(ns, 110, 110, is: "ff0000") && pixel(ns, 149, 110, is: "ff0000"), "the image's first row")
    check(pixel(ns, 120, 125, is: "00ff00"), "the image's second color")

    // Colour: a second image, half-transparent white, tagged straight, is
    // blended over the solid layer in light; tags naming another transfer
    // or primaries are refused.
    guard let vmo2 = try? VMO.create(size: 10 * 10 * 4), let pixels2 = try? VMO.map(vmo2, length: 4096),
      let acquire2 = try? Counter.create(), let release2 = try? Counter.create(),
      let a2 = try? acquire2.duplicate(), let r2 = try? release2.duplicate(), let shared2 = try? vmo2.duplicate()
    else {
      check(false, "its second image")
      Process.exit(code: 1)
    }
    let p2 = unsafe pixels2.address.assumingMemoryBound(to: UInt32.self)
    for i in 0..<(10 * 10) { unsafe p2[i] = 0x80FF_FFFF }
    check((try? window.addImage(id: 2, vmo: shared2, width: 10, height: 10, stride: 10, acquire: a2, release: r2)) != nil,
          "it adds a second image")
    func refused(_ window: inout RadharcIPC.WindowClient, _ tag: RadharcIPC.PixelTag, id: UInt32 = 2,
                 _ want: RadharcIPC.WindowError) -> Bool
    {
      do throws(IPCError<RadharcIPC.WindowError>) {
        try window.tagImage(id: id, tag: tag)
        return false
      } catch {
        if case .remote(let e) = error { return e == want }
        return false
      }
    }
    check(refused(&window, RadharcIPC.PixelTag(transfer: .pq), .transfer), "a tag of PQ is refused as its transfer")
    check(refused(&window, RadharcIPC.PixelTag(primaries: .p3), .primaries), "a tag of P3 is refused as its primaries")
    check(refused(&window, RadharcIPC.PixelTag(alpha: .straight), id: 9, .noImage), "a tag of no image is refused")
    check((try? window.tagImage(id: 2, tag: RadharcIPC.PixelTag(alpha: .straight))) != nil, "it tags the image straight")
    try? Counter.add(acquire2, 1)
    let blended = (try? window.present(
      seq: first.seq, width: UInt32(w), height: UInt32(h),
      layers: [RadharcIPC.Layer(image: 0, color: 0x0033_6699, area: all),
               RadharcIPC.Layer(image: 1, color: 0, area: RadharcIPC.Area(x: 10, y: 10, width: 40, height: 20)),
               RadharcIPC.Layer(image: 2, color: 0, area: RadharcIPC.Area(x: 60, y: 10, width: 10, height: 10))],
      damage: [], acquire: 1, number: 2)) != nil
    check(blended && waitFor(&window, seconds: 10) { e in
      if case .frame(let f) = e { return f.presented == 2 }
      return false
    }, "it presents the second image")
    // Half white's light over 0x336699's: 0xbfc7d4, where the bytes' blend
    // would give 0x99b3cc.
    check(Light.over(straight: 0x80FF_FFFF, 0x33_6699) == 0xBF_C7D4 && pixel(ns, 165, 115, is: "bfc7d4"),
          "the image with alpha is blended over the layer beneath in light")
    _ = consume release2

    // Input: a key to the focused window, the pointer over it.
    guard let ringSize = try? VMO.size(input), let ringMapping = try? VMO.map(input, length: ringSize),
      var ring = unsafe InputConsumer(attaching: ringMapping.address, size: ringSize)
    else {
      check(false, "its input ring")
      Process.exit(code: 1)
    }
    print("qemu: sendkey a")
    var key: InputEvent? = nil
    let typed = waitFor(&ring, doorbell, seconds: 20) { e in
      if e.kind == .keyDown { key = e }
      return e.kind == .keyDown
    }
    if !typed { print("desktop-test: radharc after the key: \(readText(ns, "/svc/windows/status") ?? "")") }
    check(typed && key?.code == 0x04 && key?.character == 0x61, "a key typed comes to the focused window: a, usage 4")
    // The pointer from where Radharc has it to (150, 160): over the
    // window's content, at (50, 60) in it.
    let pointer = Array((readText(ns, "/svc/windows/status") ?? "").utf8).split(separator: 0x0A)
      .first { $0.starts(with: Array("pointer ".utf8)) }
      .map { $0.split(separator: 0x20).dropFirst().map { $0.reduce(0) { $0 * 10 + Int($1) - 0x30 } } } ?? []
    check(pointer.count == 2, "Radharc's status says where the pointer is")
    var over: InputEvent? = nil
    if pointer.count == 2 {
      print("qemu: mouse_move \(150 - pointer[0]) \(160 - pointer[1])")
      _ = waitFor(&ring, doorbell, seconds: 20) { e in
        guard e.kind == .pointerAbsolute else { return false }
        over = e
        return e.x == 50 && e.y == 60
      }
    }
    check(over.map { $0.x == 50 && $0.y == 60 } == true,
          "the pointer over the window comes to it, in its content's coordinates")
    let after = readText(ns, "/svc/windows/status") ?? ""
    check(holds(after, "\nkeys ") && !holds(after, "\nkeys 0 "), "Radharc counts the keys it routed")

    // The theme: Platinum Indigo in force, its resolved form mapped, the
    // desk in its colour; another loaded through ctl, heard on events and
    // drawn; one that isn't there refused.
    let active = readText(ns, "/svc/windows/theme/active") ?? ""
    check(holds(active, "theme platinum-indigo\nvariant none\n"), "Platinum Indigo is the theme in force")
    let listed = (try? ns.list("/svc/windows/theme/themes")) ?? []
    check(listed.contains { $0.name.utf8.elementsEqual("platinum-indigo".utf8) }
      && listed.contains { $0.name.utf8.elementsEqual("neon-tab".utf8) }, "the installed themes are listed")
    func resolved() -> Theme? {
      let memory: NodeIPC.Memory
      do throws(NamespaceError) { memory = try ns.memory("/svc/windows/theme/resolved", executable: false) } catch {
        print("desktop-test: theme/resolved: no memory: \(error)")
        return nil
      }
      // Read only, as every client has it.
      guard let m = try? VMO.map(memory.vmo, length: (Int(memory.size) + 4095) & ~4095, writable: false) else {
        print("desktop-test: theme/resolved: can't map \(memory.size) bytes")
        return nil
      }
      let bytes = (0..<Int(memory.size)).map { m.load(UInt8.self, at: $0) }
      guard let wire = RadharcIPC.ResolvedTheme(decoding: bytes) else {
        print("desktop-test: theme/resolved: \(bytes.count) bytes aren't a theme: \(bytes.prefix(16))")
        return nil
      }
      return Theme(wire)
    }
    let pi = resolved()
    check(pi.map { $0.color("desk") & 0xFF_FFFF == 0x3F_5868 && $0.title.utf8.elementsEqual("Platinum Indigo".utf8) }
      == true, "the resolved theme, mapped, is Platinum Indigo's")
    let (dx, dy) = (Int(screen?.width ?? 640) - 4, Int(screen?.height ?? 480) - 4)
    check(pixel(ns, dx, dy, is: "3f5868"), "the desk is Platinum Indigo's")
    var events = try? ns.open("/svc/windows/theme/events")
    check(events != nil, "theme/events opens")
    var ctl = try? ns.open("/svc/windows/theme/ctl")
    check((try? ctl?.writeText("load neon-tab\n")) != nil, "ctl loads Neon Tab")
    let heard = (try? events?.readText()) ?? ""
    check(holds(heard, "theme neon-tab variant none generation 2\n"), "events hears it")
    var redrawn = false
    for _ in 0..<100 where !redrawn {
      redrawn = pixel(ns, dx, dy, is: "0a0a12")
      if !redrawn { sleep(until: Clock.monotonic() + 20_000_000) }
    }
    check(redrawn, "the desk is redrawn in Neon Tab's")
    check(resolved().map { $0.name.utf8.elementsEqual("neon-tab".utf8) } == true, "resolved is Neon Tab's")
    check((try? ctl?.writeText("load nowhere\n")) == nil, "a theme that isn't there is refused")
    check(holds(readText(ns, "/svc/windows/theme/ctl") ?? "", "no theme nowhere"), "ctl says why")
    check(holds((try? events?.readText()) ?? "", "refused nowhere: no theme nowhere\n"), "events hears the refusal")
    check(holds(readText(ns, "/svc/windows/theme/active") ?? "", "theme neon-tab\n"), "the theme before stays")
    check((try? ctl?.writeText("load platinum-indigo\n")) != nil, "and Platinum Indigo again")
    // Drawn before the boot's screendump, which looks at the desk too.
    redrawn = false
    for _ in 0..<100 where !redrawn {
      redrawn = pixel(ns, dx, dy, is: "3f5868")
      if !redrawn { sleep(until: Clock.monotonic() + 20_000_000) }
    }
    check(redrawn, "the desk is Platinum Indigo's again")
    _ = consume ctl
    _ = consume events
    // The window and its connection live to here: a value's life ends at
    // its last use, and the window with its channel.
    withExtendedLifetime(pixels) {}
    withExtendedLifetime(pixels2) {}
    withExtendedLifetime(ringMapping) {}
    _ = consume doorbell
    _ = consume window
    _ = consume compositor
    print("desktop-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
