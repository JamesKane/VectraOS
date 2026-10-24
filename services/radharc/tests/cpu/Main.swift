// SPDX-License-Identifier: BSD-3-Clause

// compose-cpu (boot-rio, D129): Radharc's CPU renderer, the composer that
// draws wherever there is no GPU. A 1080p scene of twelve windows, each
// showing an 800x600 image (one they share), is composed offscreen in
// each shipped theme, its pixels checked, and the median of ten whole
// frames reported as `ui.compose_cpu.1080p` (the bench's to judge, under
// KVM in boot-rio-kvm and on the board). Its limit is the 4 ms of each
// frame Radharc's latch thread is given, which composes the frame it
// latches. rio-test starts it through the
// launcher once its own budgets are done, so the two don't share the
// CPUs while either is timed.

import Console
import Node
import Radharc
import Sys
import Themes

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String) {
  print(ok ? "compose-cpu: ok: \(what)" : "compose-cpu: FAILED: \(what)")
  if !ok { failures += 1 }
}

@main struct ComposeCPU {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("compose-cpu: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let width = 1920, height = 1080
    let shadow = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
    // The windows' image, which they share: a colour a row.
    let imageWidth = 800, imageHeight = 600
    let image = UnsafeMutablePointer<UInt32>.allocate(capacity: imageWidth * imageHeight)
    for y in 0..<imageHeight {
      let color = (UInt32(0x20_4060) &+ UInt32(y) &* 0x01_0305) & 0xFF_FFFF
      for x in 0..<imageWidth { unsafe image[y * imageWidth + x] = color }
    }
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
      var top = Rect(x: 0, y: 0, width: 0, height: 0)
      for i in 0..<12 {
        let (w, _) = scene.open(title: "window \(i)", width: imageWidth, height: imageHeight)
        unsafe w.images.append((1, Pixels(unsafe: image, width: imageWidth, height: imageHeight, stride: imageWidth)))
        scene.present(w.id, seq: 1, size: (imageWidth, imageHeight),
                      layers: [Layer(image: 1, rect: Rect(x: 0, y: 0, width: imageWidth, height: imageHeight))],
                      damage: nil)
        top = w.content
      }
      let font = Font.spleen8x16
      var times: [Int64] = []
      for _ in 0..<10 {
        scene.damageAll()
        let region = scene.takeDamage()
        let t0 = Clock.monotonic()
        unsafe scene.compose(region, into: shadow, stride: width) { c in
          var rows = InlineArray<16, UInt8>(repeating: 0)
          guard let g = font.glyph(c) else { return rows }
          for y in 0..<16 { rows[y] = UInt8(truncatingIfNeeded: font.row(g, y) >> 24) }
          return rows
        }
        times.append(Clock.monotonic() - t0)
      }
      // The topmost window's middle, where it is on the screen, is the
      // image's pixel there.
      let mx = top.x + top.width / 2, my = top.y + top.height / 2
      if mx >= 0, mx < width, my >= 0, my < height {
        let p = unsafe shadow[my * width + mx]
        let want = unsafe image[(top.height / 2) * imageWidth + top.width / 2]
        check(p == want, "\(name): a window's image composed (\(p), \(want))")
      } else {
        check(false, "\(name): the topmost window's middle is on the screen (\(mx), \(my))")
      }
      times.sort()
      print("compose-cpu: budget name=ui.compose_cpu.1080p.\(name) value=\(times[times.count / 2]) unit=ns limit=4000000")
    }
    unsafe image.deallocate()
    unsafe shadow.deallocate()
    print(failures == 0 ? "compose-cpu: all passed" : "compose-cpu: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
