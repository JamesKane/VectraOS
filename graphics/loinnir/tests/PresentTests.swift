// SPDX-License-Identifier: BSD-3-Clause

// GPU frames in a real window, through dmabuf. Opens a window for about a
// second, so it runs only with TODHCHAI_LIVE_WINDOWS=1.

import Glibc
import Loinnir
import Testing
import Todhchai

@Test(.enabled(if: getenv("TODHCHAI_LIVE_WINDOWS") != nil))
func gpuFramesReachTheGlassThroughDmabuf() throws {
  var loop = try Loop()
  let win = try loop.openWindow("todhchai-gpu-test", width: 320, height: 200)
  let gpu = try Loinnir.open(window: win, loop: &loop)
  var config: Configure?
  var frames: [Frame] = []
  var drawn = 0
  let giveUp = Deadline.now + .seconds(5)
  loop.requestFrame(win)
  while frames.count < 60 && Deadline.now < giveUp {
    for e in loop.wait(until: giveUp) where e.window == win {
      switch e.payload {
      case .configure(let c): config = c
      case .frame(let f):
        frames.append(f)
        guard let c = config else { break }
        let t = Float(frames.count) / 60
        if try gpu.clear((t, 0.2, 1 - t, 1), loop: &loop, config: c) { drawn += 1 }
        loop.requestFrame(win)
      default: break
      }
    }
  }
  loop.closeWindow(win)
  #expect(frames.count == 60)
  #expect(drawn >= 55)
  #expect(frames.dropFirst(5).filter { $0.presentedAt != nil }.count >= 50)
}

@Test(.enabled(if: getenv("TODHCHAI_LIVE_WINDOWS") != nil))
func aTriangleIsDrawnIntoAWindow() throws {
  var loop = try Loop()
  let win = try loop.openWindow("todhchai-triangle-test", width: 320, height: 200)
  let gpu = try Loinnir.open(window: win, loop: &loop)
  let pso = try gpu.pipeline(vertex: spirv("triangle.vert"), fragment: spirv("triangle.frag"), target: .bgra8)
  let verts = try gpu.alloc(.upload, bytes: 3 * 32)
  let f = verts.pointer!.assumingMemoryBound(to: Float.self)
  for (i, (x, y, rgb)) in [(0.0, -0.8, (1, 0, 0)), (0.8, 0.8, (0, 1, 0)), (-0.8, 0.8, (0, 0, 1))].enumerated() {
    (f[i * 8], f[i * 8 + 1]) = (Float(x), Float(y))
    (f[i * 8 + 4], f[i * 8 + 5], f[i * 8 + 6], f[i * 8 + 7]) = (Float(rgb.0), Float(rgb.1), Float(rgb.2), 1)
  }
  var config: Configure?
  var frames: [Frame] = []
  var drawn = 0
  let giveUp = Deadline.now + .seconds(5)
  loop.requestFrame(win)
  while frames.count < 60 && Deadline.now < giveUp {
    for e in loop.wait(until: giveUp) where e.window == win {
      switch e.payload {
      case .configure(let c): config = c
      case .frame(let fr):
        frames.append(fr)
        guard let c = config, let target = try gpu.frame(&loop, c) else { break }
        var cmd = try gpu.commands()
        cmd.render(to: target, clear: (0.1, 0.1, 0.1, 1)) { r in r.draw(pso, root: verts.address, vertices: 3) }
        try gpu.present(&loop, c, after: try gpu.submit(cmd))
        drawn += 1
        loop.requestFrame(win)
      default: break
      }
    }
  }
  loop.closeWindow(win)
  #expect(frames.count == 60)
  #expect(drawn >= 55)
  #expect(frames.dropFirst(5).filter { $0.presentedAt != nil }.count >= 50)
}
