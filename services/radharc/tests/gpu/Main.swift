// SPDX-License-Identifier: BSD-3-Clause

// compose-test (boot-venus, D121; the board's, D174 section 6 step 4):
// Radharc's GPU renderer. Once loinnir-test is done, Radharc (where it runs
// beside this) says it composes on the GPU and a pixel of its frame is the
// desk's colour; then a 1080p scene of twelve windows in each shipped theme
// is composed by the GPU and by the CPU's renderer, and the two frames are
// compared (on the native Mali driver they must agree within 3 steps in every
// channel; under Venus the difference is reported); and a 4K scene of twelve
// windows is composed on the GPU offscreen, its pixels checked, and its
// frame time reported as `theme.compose.4k` (theming.md §8: under 1.5 ms of
// GPU time on the reference GPU; the bench's to judge; on the native Mali driver, which aims at 1080p, the 4K time is
// reported and `theme.compose.1080p` (under 2 ms, a 1080p frame drawn into a target shown as it is) is the budget). The time is submit
// to done, the frame's copy into host-visible memory included.

import Console
import IPC
import Node
import Radharc
import RadharcGPU
import Sys
import Themes

func lines(_ ns: Namespace, _ path: String) -> [[UInt8]] {
  guard var f = try? ns.open(path), let b = try? f.readAll() else { return [] }
  return b.split(separator: 0x0A).map(Array.init)
}

func has(_ ns: Namespace, _ path: String, prefix: String) -> Bool {
  lines(ns, path).contains { $0.starts(with: Array(prefix.utf8)) }
}

/// One theme's scene of twelve windows, each showing a gradient image (so each texel of a window is its own colour),
/// composed by the GPU's renderer and by the CPU's at 1080p, and compared channel by channel.
func matchTheCPU(_ ns: Namespace) {
  let width = 1920, height = 1080
  guard let gpu = GPURenderer.open(ns, width: width, height: height) else {
    check(false, "a GPU renderer at 1080p")
    return
  }
  print("compose-test: the renderer is on \(gpu.backend)")
  let imageWidth = 800, imageHeight = 600
  let image = UnsafeMutablePointer<UInt32>.allocate(capacity: imageWidth * imageHeight)
  for y in 0..<imageHeight {
    for x in 0..<imageWidth {
      unsafe image[y * imageWidth + x] = UInt32(x * 255 / imageWidth) << 16 | UInt32(y * 255 / imageHeight) << 8 | 0x60
    }
  }
  let fromGPU = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
  let fromCPU = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
  let font = Font.spleen8x16
  for name in ["platinum-indigo", "neon-tab"] {
    let theme: Theme
    do {
      theme = try Theme.resolve(ThemeStack(theme: name)) { n in
        guard var f = try? ns.open("/lib/theme/" + n) else { return nil }
        return try? f.readAll()
      }
    } catch {
      check(false, "\(name) resolves")
      continue
    }
    let scene = Scene(width: width, height: height)
    scene.decorations = Decorations(theme)
    for i in 0..<12 {
      let (w, _) = scene.open(title: "window \(i)", width: imageWidth, height: imageHeight)
      unsafe w.images.append((1, Pixels(unsafe: image, width: imageWidth, height: imageHeight, stride: imageWidth)))
      scene.present(w.id, seq: 1, size: (imageWidth, imageHeight),
                    layers: [Layer(image: 1, rect: Rect(x: 0, y: 0, width: imageWidth, height: imageHeight))], damage: nil)
    }
    scene.damageAll()
    guard unsafe gpu.render(scene, damage: scene.takeDamage(), into: fromGPU) else {
      check(false, "\(name): a 1080p frame composes on the GPU (\(gpu.failure ?? "?"))")
      continue
    }
    // The same scene again, its window images already in the GPU's memory: the pixels that differ from this frame's
    // are in memory the GPU read differently the second time (the images' uploads, or a race with them), not in the
    // shader.
    let again = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
    scene.damageAll()
    var changed = 0
    if unsafe gpu.render(scene, damage: scene.takeDamage(), into: again) {
      for k in 0..<width * height where unsafe again[k] != fromGPU[k] { changed += 1 }
    }
    unsafe again.deallocate()
    print("compose-test: \(name): a second GPU frame of the same scene differs from the first in \(changed) pixels")
    scene.damageAll()
    unsafe scene.compose(scene.takeDamage(), into: fromCPU, stride: width) { c in
      var rows = InlineArray<16, UInt8>(repeating: 0)
      guard let g = font.glyph(c) else { return rows }
      for y in 0..<16 { rows[y] = UInt8(truncatingIfNeeded: font.row(g, y) >> 24) }
      return rows
    }
    var most = 0, beyondOne = 0, beyondThree = 0, at = 0
    var box = (x0: width, y0: height, x1: -1, y1: -1)
    var samples = ""
    for k in 0..<width * height {
      let a = unsafe fromGPU[k] & 0xFF_FFFF, b = unsafe fromCPU[k] & 0xFF_FFFF
      var worst = 0
      for shift in [UInt32(0), 8, 16] {
        let d = Int(a >> shift & 0xFF) - Int(b >> shift & 0xFF)
        worst = max(worst, d < 0 ? -d : d)
      }
      if worst > 1 { beyondOne += 1 }
      if worst > 3 {
        beyondThree += 1
        box = (min(box.x0, k % width), min(box.y0, k / width), max(box.x1, k % width), max(box.y1, k / width))
        if beyondThree <= 12 { samples += " (\(k % width), \(k / width): \(unsafe fromGPU[k]) against \(unsafe fromCPU[k]))" }
      }
      if worst > most {
        most = worst
        at = k
      }
    }
    print("compose-test: \(name): the GPU's 1080p frame differs from the CPU's by at most \(most) steps (at \(at % width), "
      + "\(at / width): \(unsafe fromGPU[at]) against \(unsafe fromCPU[at])), \(beyondOne) pixels by more than 1, "
      + "\(beyondThree) by more than 3 of \(width * height)")
    if beyondThree > 0 {
      print("compose-test: \(name): the pixels that differ lie in x \(box.x0)...\(box.x1), y \(box.y0)...\(box.y1), the first:\(samples)")
      // What the display list draws over the first of them, in order: kind (0 fill, 1 image, 2 glyph, 3 cursor, 4 dim,
      // 5 seal), the rectangle, the source and the colour.
      var list = DrawList()
      scene.displayList(Rect(x: 0, y: 0, width: width, height: height), into: &list)
      for (n, q) in list.quads.enumerated()
      where Int(q.x) <= at % width && Int(q.x + q.width) > at % width && Int(q.y) <= at / width && Int(q.y + q.height) > at / width {
        print("compose-test: \(name): instance \(n) of \(list.quads.count): kind \(q.kind) at \(Int(q.x)), \(Int(q.y)) "
          + "\(Int(q.width)) x \(Int(q.height)) from \(q.sx), \(q.sy) texture \(q.texture) color \(q.color)")
      }
    }
    // The native driver's blender and sRGB conversion are the contract; Venus's host GPU rounds as it likes.
    if gpu.backend.utf8.elementsEqual("mali".utf8) {
      check(beyondThree == 0, "\(name): the GPU's frame matches the CPU's within 3 steps (\(beyondThree) pixels do not)")
    }
  }
  unsafe image.deallocate()
  unsafe fromGPU.deallocate()
  unsafe fromCPU.deallocate()
}

/// The native driver's budget: a 1080p scene of twelve windows in each shipped theme drawn into a target shown as it is
/// (nothing copied), the draw's submit to done, the median of five frames after a warm-up, `theme.compose.1080p`.
func compose1080(_ ns: Namespace) {
  let width = 1920, height = 1080
  var opened = GPURenderer.open(ns, width: width, height: height, direct: true)
  if let o = opened, o.exportTarget(0) == nil || o.exportTarget(1) == nil { opened = nil }
  guard let gpu = opened, gpu.backend.utf8.elementsEqual("mali".utf8) else { return }
  for name in ["platinum-indigo", "neon-tab"] {
    let theme: Theme
    do {
      theme = try Theme.resolve(ThemeStack(theme: name)) { n in
        guard var f = try? ns.open("/lib/theme/" + n) else { return nil }
        return try? f.readAll()
      }
    } catch {
      check(false, "\(name) resolves")
      continue
    }
    let scene = Scene(width: width, height: height)
    scene.decorations = Decorations(theme)
    for i in 0..<12 {
      let (w, _) = scene.open(title: "window \(i)", width: 800, height: 600)
      let color = UInt32(0x20_4060) &+ UInt32(i) &* 0x10_0B05
      scene.present(w.id, seq: 1, size: (800, 600),
                    layers: [Layer(image: 0, color: color, rect: Rect(x: 0, y: 0, width: 800, height: 600))], damage: nil)
    }
    var times: [Int64] = []
    for frame in 0..<6 {
      scene.damageAll()
      _ = scene.takeDamage()
      guard gpu.renderDirect(scene) != nil else {
        check(false, "\(name): a 1080p frame composes on the GPU (\(gpu.failure ?? "?"))")
        break
      }
      if frame > 0 { times.append(gpu.lastFrame) }
    }
    guard !times.isEmpty else { continue }
    times.sort()
    print("compose-test: budget name=theme.compose.1080p.\(name) value=\(times[times.count / 2]) unit=ns target=2000000")
  }
}

@main struct ComposeTest {
  static func main() {
    // The process's namespace, which the SDK (Loinnir's window) shares: a Startup's handles are taken once.
    guard let ns = Namespace.process else {
      print("compose-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    // After loinnir-test: one GPU user at a time keeps the timings apart.
    _ = within(120) { has(ns, "/svc/launcher/status", prefix: "loinnir-test exited") }
    // It must have exited 0: its draws, and the core's cases on the Vulkan backend, judged what they read back.
    check(lines(ns, "/svc/launcher/status").contains { $0.starts(with: Array("loinnir-test exited 0 ".utf8)) },
          "loinnir-test drew and judged what the core's backend did")
    // And after vulkan-test (tier 1's C test of the Vulkan layer, where tier 1 is built), which boot-venus runs beside
    // loinnir-test as a service: it must have exited 0, having printed `ok: vulkan compute` and `ok: vulkan triangle`.
    // Where the image has none (the board's has it as an app, which board-test starts and judges), nothing is judged.
    if has(ns, "/svc/launcher/status", prefix: "vulkan-test ") && !has(ns, "/svc/launcher/status", prefix: "vulkan-test not started") {
      _ = within(120) { has(ns, "/svc/launcher/status", prefix: "vulkan-test exited") }
      check(lines(ns, "/svc/launcher/status").contains { $0.starts(with: Array("vulkan-test exited 0 ".utf8)) },
            "vulkan-test ran a compute shader and a triangle through the Vulkan loader")
    }
    // And vulkan-present (the layer's swapchain, on a window of Radharc's), where the image has it: 120 frames, the window
    // fullscreen and back, and the pixels Radharc composed, each judged by the program, which must have exited 0 having
    // printed `ok: vulkan present frames`, `ok: vulkan present pixels`, `ok: vulkan present resize` and
    // `ok: vulkan present events`. Its window is closed when it exits, so what follows sees Radharc's desk.
    if has(ns, "/svc/launcher/status", prefix: "vulkan-present ") && !has(ns, "/svc/launcher/status", prefix: "vulkan-present not started") {
      _ = within(240) { has(ns, "/svc/launcher/status", prefix: "vulkan-present exited") }
      check(lines(ns, "/svc/launcher/status").contains { $0.starts(with: Array("vulkan-present exited 0 ".utf8)) },
            "vulkan-present presented 120 frames of a swapchain to a window of Radharc's and read what it composed")
    }
    // Radharc runs beside this test in boot-venus, and not in the board's test image.
    let radharcUp = (try? ns.open("/svc/windows/status")) != nil
    // `renderer gpu frames N last T us`: frames the GPU drew, not the CPU.
    func gpuFrames() -> Int {
      guard let l = lines(ns, "/svc/windows/status").first(where: { $0.starts(with: Array("renderer gpu frames ".utf8)) })
      else { return 0 }
      let w = l.split(separator: 0x20)
      guard w.count > 3, w[3].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return 0 }
      return w[3].reduce(0) { $0 * 10 + Int($1) - 0x30 }
    }
    if radharcUp {
      check(within(10) { gpuFrames() > 0 }, "Radharc composes on the GPU (\(gpuFrames()) frames)")
      var probe = (try? ns.open("/svc/windows/pixel"))
      _ = try? probe?.writeText("20 20")
      let desk = (try? probe?.readText()) ?? nil
      check(desk.map { $0.utf8.elementsEqual("3f5868\n".utf8) } ?? false,
            "a pixel of its frame is Platinum Indigo's desk (\(desk ?? "none"))")
      // Loinnir's window: a ring of GPU images given to it, presented with no CPU copy.
      loinnirPresentCheck(ns)
    }

    // The same 1080p scene composed by the GPU and by the CPU's renderer.
    matchTheCPU(ns)
    compose1080(ns)

    // A 4K scene in each shipped theme, composed offscreen on the GPU.
    let width = 3840, height = 2160
    // Where the driver shares the targets as a display reads them (the native one), the frame is drawn into one of two
    // targets that are shown as they are, and the budget is the draw's alone: nothing is copied for it. The CPU's
    // read of the frame, for the checks below, is a step of the test and is said apart.
    var opened = GPURenderer.open(ns, width: width, height: height, direct: true)
    if let o = opened, o.exportTarget(0) == nil || o.exportTarget(1) == nil { opened = nil }
    guard let gpu = opened ?? GPURenderer.open(ns, width: width, height: height) else {
      check(false, "a GPU renderer at 4K")
      Process.exit(code: 1)
    }
    if gpu.direct {
      // Each export is a new handle to the one VMO of the target, which the display can pin and read but not map.
      if let a = gpu.exportTarget(0), let b = gpu.exportTarget(1), let c = gpu.exportTarget(0),
        let ia = try? a.info(), let ib = try? b.info(), let ic = try? c.info()
      {
        check(ia.koid == ic.koid && ia.koid != ib.koid, "a target's exports are its own VMO, and the two targets differ")
        check((try? VMO.size(a)).map { $0 >= width * height * 4 } ?? false, "a target's VMO holds the 4K frame")
      } else {
        check(false, "the GPU's targets are exported")
      }
      print("compose-test: the 4K frames are drawn into targets shown as they are (scanout direct)")
    }
    let shadow = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
    for name in ["platinum-indigo", "neon-tab"] {
      let theme: Theme
      do {
        theme = try Theme.resolve(ThemeStack(theme: name)) { n in
          guard var f = try? ns.open("/lib/theme/" + n) else { return nil }
          return try? f.readAll()
        }
      } catch {
        check(false, "\(name) resolves")
        continue
      }
      let scene = Scene(width: width, height: height)
      scene.decorations = Decorations(theme)
      var colors: [(Rect, UInt32)] = []
      for i in 0..<12 {
        let (w, _) = scene.open(title: "window \(i)", width: 800, height: 600)
        let color = UInt32(0x20_4060) &+ UInt32(i) &* 0x10_0B05
        scene.present(w.id, seq: 1, size: (800, 600),
                      layers: [Layer(image: 0, color: color, rect: Rect(x: 0, y: 0, width: 800, height: 600))], damage: nil)
        colors.append((w.content, color))
      }
      var times: [Int64] = [], draws: [Int64] = [], reads: [Int64] = [], copies: [Int64] = []
      for _ in 0..<10 {
        scene.damageAll()
        if gpu.direct {
          scene.damageAll()
          _ = scene.takeDamage()
          guard gpu.renderDirect(scene) != nil else {
            check(false, "\(name): a 4K frame composes on the GPU (\(gpu.failure ?? "?"))")
            break
          }
        } else {
          guard unsafe gpu.render(scene, damage: scene.takeDamage(), into: shadow) else {
            check(false, "\(name): a 4K frame composes on the GPU (\(gpu.failure ?? "?"))")
            break
          }
        }
        times.append(gpu.lastFrame)
        draws.append(gpu.lastDraw)
        reads.append(gpu.lastReadback)
        copies.append(gpu.lastShadowCopy)
      }
      if gpu.direct && !times.isEmpty {
        // The last frame read back for the checks: the GPU's copy into memory the CPU reads, then the CPU's copy of it.
        try? unsafe gpu.readFront(Rect(x: 0, y: 0, width: width, height: height), into: shadow)
        print("compose-test: \(name): 4K frame read back, for the checks only (not in the budget): copy \(gpu.lastReadback) ns, "
          + "shadow \(gpu.lastShadowCopy) ns")
      }
      if !times.isEmpty {
        draws.sort()
        reads.sort()
        copies.sort()
        // Where the frame's time goes (medians, ns): the uploads and the draw, the copy into the buffer the CPU reads
        // (both in the budget below), and the CPU's copy of the frame from that buffer into the shadow (not in it).
        print("compose-test: \(name): 4K frame: draw \(draws[draws.count / 2]) ns, readback \(reads[reads.count / 2]) ns, "
          + "shadow copy \(copies[copies.count / 2]) ns")
      }
      // The topmost window's middle is its colour, exactly or within a step
      // of sRGB's rounding.
      if let (r, c) = colors.last {
        let p = unsafe shadow[(r.y + r.height / 2) * width + r.x + r.width / 2]
        func near(_ a: UInt32, _ b: UInt32) -> Bool { (a > b ? a - b : b - a) <= 1 }
        check(near(p >> 16 & 0xFF, c >> 16 & 0xFF) && near(p >> 8 & 0xFF, c >> 8 & 0xFF) && near(p & 0xFF, c & 0xFF),
              "\(name): a window's colour composed on the GPU (\(p), \(c))")
      }
      guard !times.isEmpty else { continue }
      times.sort()
      // (Submit to done of the draw. Without targets a display shows as they are, the copy into host-visible
      // memory is in it. The median of ten frames.)
      // Reported on the native driver, which aims at 1080p (the 1080p budget below judges it); judged under Venus.
      let native = gpu.backend.utf8.elementsEqual("mali".utf8)
      print("compose-test: budget name=theme.compose.4k.\(name) value=\(times[times.count / 2]) unit=ns"
        + (native ? "" : " target=1500000"))
    }
    unsafe shadow.deallocate()
    if failures == 0 { print("compose-test: ok: Radharc's GPU renderer composed on \(gpu.backend)") }
    print(failures == 0 ? "compose-test: all passed" : "compose-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
