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
// GPU time on the reference GPU; the bench's to judge). The time is submit
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
        if beyondThree <= 4 { samples += " (\(k % width), \(k / width): \(unsafe fromGPU[k]) against \(unsafe fromCPU[k]))" }
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

@main struct ComposeTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("compose-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    // After loinnir-test: one GPU user at a time keeps the timings apart.
    _ = within(120) { has(ns, "/svc/launcher/status", prefix: "loinnir-test exited") }
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
    }

    // The same 1080p scene composed by the GPU and by the CPU's renderer.
    matchTheCPU(ns)

    // A 4K scene in each shipped theme, composed offscreen on the GPU.
    let width = 3840, height = 2160
    guard let gpu = GPURenderer.open(ns, width: width, height: height) else {
      check(false, "a GPU renderer at 4K")
      Process.exit(code: 1)
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
      var times: [Int64] = []
      for _ in 0..<10 {
        scene.damageAll()
        guard unsafe gpu.render(scene, damage: scene.takeDamage(), into: shadow) else {
          check(false, "\(name): a 4K frame composes on the GPU (\(gpu.failure ?? "?"))")
          break
        }
        times.append(gpu.lastFrame)
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
      // (Submit to done, the copy into host-visible memory included: the
      // GPU's own time is less. The median of ten frames.)
      print("compose-test: budget name=theme.compose.4k.\(name) value=\(times[times.count / 2]) unit=ns target=1500000")
    }
    unsafe shadow.deallocate()
    if failures == 0 { print("compose-test: ok: Radharc's GPU renderer composed on \(gpu.backend)") }
    print(failures == 0 ? "compose-test: all passed" : "compose-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
