// SPDX-License-Identifier: BSD-3-Clause

// display-test (boot-display, D120): Radharc on a virtio GPU's outputs.
// devmgr binds virtio-gpu and mounts its tree at /dev/display0; Radharc
// composes onto the GPU's enabled output, not the boot framebuffer, its
// screen the output's size; a window's solid colour reaches the output
// through the driver's flushes, and boot-display's screendump of the GPU
// (check-pixels) sees it there.

import IPC
import Node
import Radharc
import Sys

/// `path`'s lines, as bytes.
func lines(_ ns: Namespace, _ path: String) -> [[UInt8]] {
  guard var f = try? ns.open(path), let b = try? f.readAll() else { return [] }
  return b.split(separator: 0x0A).map(Array.init)
}

func has(_ ns: Namespace, _ path: String, _ line: String) -> Bool {
  lines(ns, path).contains { $0.elementsEqual(line.utf8) }
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

@main struct DisplayTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("display-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let radharc = "/svc/windows/status", gpu = "/dev/display0/status"
    check(lines(ns, gpu).contains { $0.starts(with: Array("scanouts ".utf8)) }, "devmgr serves virtio-gpu's tree at /dev/display0")
    check(has(ns, radharc, "display display0 outputs 0 1024x768+0, resizes 0"), "Radharc composes onto the GPU's output")
    check(has(ns, radharc, "screen 1024x768"), "its screen is the output's size")
    check(within(10) { (numbers(ns, gpu, "images").first ?? 0) == 2 && (numbers(ns, gpu, "images").dropFirst().first ?? 0) > 0 },
          "it attached two images and presents them")

    // A window of a solid colour, placed.
    guard let channel = try? ns.connect("/svc/windows/compositor") else {
      check(false, "/svc/windows/compositor")
      Process.exit(code: 1)
    }
    var compositor = RadharcIPC.CompositorClient(channel: channel)
    let (w, h) = (200, 120)
    guard let opened = try? compositor.open(title: "display-test", width: UInt32(w), height: UInt32(h)) else {
      check(false, "a window opens")
      Process.exit(code: 1)
    }
    let first = opened.first
    var window = RadharcIPC.WindowClient(channel: opened.takeWindow())
    check((try? window.place(x: 100, y: 100)) != nil, "it places itself")
    let flushes = numbers(ns, gpu, "images").dropFirst().first ?? 0
    let all = RadharcIPC.Area(x: 0, y: 0, width: Int32(w), height: Int32(h))
    check((try? window.present(seq: first.seq, width: UInt32(w), height: UInt32(h),
                               layers: [RadharcIPC.Layer(image: 0, color: 0x00CC_3366, area: all)],
                               damage: [], acquire: 0, number: 1)) != nil, "it presents a solid colour")
    check(within(10) { (numbers(ns, gpu, "images").dropFirst().first ?? 0) > flushes }, "the driver flushes it to the output")
    check((numbers(ns, gpu, "images").dropFirst(2).first ?? 1) == 0, "with no request failed")
    sleep(until: Clock.monotonic() + 500_000_000)
    print(failures == 0 ? "display-test: all passed" : "display-test: \(failures) FAILED")
    _ = consume window
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
