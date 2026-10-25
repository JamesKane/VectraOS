// SPDX-License-Identifier: BSD-3-Clause

// compose-test (boot-venus, D121): Radharc's GPU renderer. Once
// loinnir-test is done, Radharc says it composes on the GPU and a pixel of
// its frame is the desk's colour; then a 4K scene of twelve windows in each
// shipped theme is composed on the GPU offscreen, its pixels checked, and
// its frame time reported as `theme.compose.4k` (theming.md §8: under 1.5
// ms of GPU time on the reference GPU; the bench's to judge). The time is
// submit to done, the frame's copy into host-visible memory included.

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

@main struct ComposeTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("compose-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    // After loinnir-test: one GPU user at a time keeps the timings apart.
    _ = within(120) { has(ns, "/svc/launcher/status", prefix: "loinnir-test exited") }
    // `renderer gpu frames N last T us`: frames the GPU drew, not the CPU.
    func gpuFrames() -> Int {
      guard let l = lines(ns, "/svc/windows/status").first(where: { $0.starts(with: Array("renderer gpu frames ".utf8)) })
      else { return 0 }
      let w = l.split(separator: 0x20)
      guard w.count > 3, w[3].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return 0 }
      return w[3].reduce(0) { $0 * 10 + Int($1) - 0x30 }
    }
    check(within(10) { gpuFrames() > 0 }, "Radharc composes on the GPU (\(gpuFrames()) frames)")
    var probe = (try? ns.open("/svc/windows/pixel"))
    _ = try? probe?.writeText("20 20")
    let desk = (try? probe?.readText()) ?? nil
    check(desk.map { $0.utf8.elementsEqual("3f5868\n".utf8) } ?? false,
          "a pixel of its frame is Platinum Indigo's desk (\(desk ?? "none"))")

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
    print(failures == 0 ? "compose-test: all passed" : "compose-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
