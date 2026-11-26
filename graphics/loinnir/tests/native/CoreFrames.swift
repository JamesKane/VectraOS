// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's frame budgets on the Mali backend (D183; gpucore(2), "The Mali backend"): what one frame of a GL
// program costs when every frame ends in a wait, as glmark2's off-screen run does (glFinish). Each is the median of
// many round trips, from the call to `submit` to the waiting thread running again once the timeline has reached the
// frame's value, at 800 x 600 (glmark2's size):
//
//   gpu.mali.frame_empty_us       a list with no command
//   gpu.mali.frame_clear_draw_us  a pass cleared and one draw over the whole target
//   gpu.mali.frame_100_draws_us   a pass cleared and 100 draws of small quads
//   gpu.mali.frame_two_passes_us  two passes, the second into another target (render to texture, then the frame)
//   gpu.mali.frame_small_pass_us  a pass cleared and one draw at 64 x 64: what a pass costs but for its pixels
//
// The first pass is also placed on the CPU's clock by two timestamps around it (the GPU's counter is the CPU's
// architected counter): from the submit's return to the GPU's start, the GPU's own time, and from its end to the
// waiting thread running again.
//
// Each also says where the CPU's part went (MaliDevice.lastProfile): planning the steps, laying them out, the driver's
// submit, and waits inside the submission; the rest of the round trip is the GPU's work and the way back (the
// interrupt, the driver, the counter, the wake). Nothing is judged but that each frame draws what it should.

import GPUCore
import GPUCoreMali
import Loinnir
import Sys

final class FrameBudgets {
  let gpu: any GPUDevice
  let mali: MaliDevice?
  var signalled: UInt64 = 0
  let width = 800, height = 600
  let target: GPUImage
  let second: GPUImage
  let readback: GPUMemory
  let pipeline: GPUPipeline
  let quads: GPUMemory
  let small: GPUImage
  let stamps: GPUQuerySet?
  static let rounds = 41

  init(_ gpu: any GPUDevice, signalled: UInt64) throws(GPUError) {
    self.gpu = gpu
    self.signalled = signalled
    mali = gpu as? MaliDevice
    mali?.profiling = true
    target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: Int32(width), height: Int32(height),
                                               usage: .renderTarget | .copySource | .sampled))
    second = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: Int32(width), height: Int32(height),
                                               usage: .renderTarget | .copySource | .sampled))
    small = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    stamps = gpu.limits.features.timestampQueries ? try gpu.makeQuerySet(.timestamp, count: 2) : nil
    readback = try gpu.allocate(.readback, bytes: 4 * 4)
    pipeline = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: LoinnirShaders.triangleVert, fragment: LoinnirShaders.triangleFrag, colorFormats: [.rgba8], blend: .opaque))
    // 101 quads of six vertices (triangle.vert's: position at 0, colour at 16; 32 bytes): the whole target first, then a
    // grid of 10 x 10 small ones.
    quads = try gpu.allocate(.upload, bytes: 101 * 6 * 32)
    var k = 0
    func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: [Float]) {
      for (x, y) in [(x0, y0), (x1, y0), (x0, y1), (x1, y0), (x1, y1), (x0, y1)] {
        let f = unsafe quads.pointer!.advanced(by: k * 32).assumingMemoryBound(to: Float.self)
        unsafe f[0] = x
        unsafe f[1] = y
        unsafe f[2] = 0
        unsafe f[3] = 1
        for i in 0..<4 { unsafe f[4 + i] = c[i] }
        k += 1
      }
    }
    quad(-1, -1, 1, 1, [1, 0, 0, 1])
    for i in 0..<100 {
      let x = Float(i % 10) * 0.2 - 1, y = Float(i / 10) * 0.2 - 1
      quad(x + 0.02, y + 0.02, x + 0.18, y + 0.18, [0, Float(i) / 100, 1, 1])
    }
  }

  func pass(_ image: GPUImage) -> RenderingInfo { RenderingInfo(colors: [Attachment(image: image, load: .clear(0, 0, 0, 1))]) }

  /// The median round trip of `list` in microseconds, and the profile of the median one.
  func measure(_ name: String, _ budget: String, _ list: GPUCommandList) throws(GPUError) -> Int64 {
    var samples: [(total: Int64, submit: Int64, profile: SubmitProfile)] = []
    for _ in 0..<Self.rounds {
      signalled += 1
      let start = Clock.monotonic()
      try gpu.graphicsQueue.submit(list, wait: 0, signal: signalled)
      let submitted = Clock.monotonic()
      try gpu.wait(signalled)
      let done = Clock.monotonic()
      samples.append(((done - start) / 1000, (submitted - start) / 1000, mali?.lastProfile ?? SubmitProfile()))
    }
    samples.sort { $0.total < $1.total }
    let m = samples[samples.count / 2]
    let p = m.profile
    func us(_ ns: UInt64) -> String { "\(ns / 1000).\(ns / 100 % 10)" }
    print("loinnir-test: frame \(name): \(m.total) us a round trip (fastest \(samples[0].total), slowest \(samples[samples.count - 1].total));"
      + " submit returned after \(m.submit) us: plan \(us(p.planNanoseconds)), layout \(us(p.buildNanoseconds)), driver"
      + " \(us(p.submitNanoseconds)), waits inside \(us(p.waitNanoseconds)) us; \(p.steps) steps, \(p.submits) submits,"
      + " \(p.buffers) buffers made")
    // A line of its own: the console cuts long ones.
    print("loinnir-test: frame \(name): of the plan the draws took \(us(p.drawNanoseconds)) us; of the layout the pass recipe"
      + " \(us(p.recipeNanoseconds)) us and its copy into the GPU's memory \(us(p.copyNanoseconds)) us")
    print("budget name=\(budget) value=\(m.total) unit=us")
    return m.total
  }

  /// `body` between two timestamps, placed on the CPU's clock: the medians of the submit's return to the GPU's first
  /// timestamp, the GPU's time between them, and its last to the waiting thread's running again, in microseconds.
  func place(_ name: String, _ body: (inout GPUCommandList) -> Void) throws(GPUError) {
    guard let set = stamps, let mali, mali.counterTicks != 0, mali.counterFrequencyHertz == 1_000_000_000 else {
      print("loinnir-test: frame \(name): not placed (no timestamps, or a counter not at 1 GHz)")
      return
    }
    var list = GPUCommandList()
    list.writeTimestamp(set, index: 0)
    body(&list)
    list.writeTimestamp(set, index: 1)
    var toGPU: [Int64] = [], onGPU: [Int64] = [], back: [Int64] = []
    for _ in 0..<Self.rounds {
      // The counter in nanoseconds (1 GHz) and the monotonic clock differ by the boot's base.
      let base = Int64(bitPattern: mali.counterTicks) - Clock.monotonic()
      signalled += 1
      try gpu.graphicsQueue.submit(list, wait: 0, signal: signalled)
      let submitted = Clock.monotonic()
      try gpu.wait(signalled)
      let woke = Clock.monotonic()
      let t = try gpu.results(set, first: 0, count: 2)
      let start = Int64(bitPattern: t[0]) - base, end = Int64(bitPattern: t[1]) - base
      toGPU.append((start - submitted) / 1000)
      onGPU.append((end - start) / 1000)
      back.append((woke - end) / 1000)
    }
    toGPU.sort()
    onGPU.sort()
    back.sort()
    let m = Self.rounds / 2
    print("loinnir-test: frame \(name), placed: the GPU starts \(toGPU[m]) us after the submit returns, takes \(onGPU[m]) us,"
      + " and the waiting thread runs \(back[m]) us after it ends (medians)")
  }

  /// The pixel at (x, y) of `image` after the list that drew it.
  func pixel(_ image: GPUImage, _ x: Int, _ y: Int) throws(GPUError) -> [UInt8] {
    var list = GPUCommandList()
    list.copy(image, to: readback, regions: [BufferImageRegion(
      imageOffset: Offset3D(x: Int32(x), y: Int32(y)), imageExtent: Extent3D(width: 1, height: 1))])
    signalled += 1
    try gpu.run(list, signal: signalled)
    let p = unsafe readback.pointer!.assumingMemoryBound(to: UInt8.self)
    return [unsafe p[0], unsafe p[1], unsafe p[2], unsafe p[3]]
  }

  func all() -> Int {
    var failed = 0
    func attempt(_ name: String, _ body: () throws(GPUError) -> Void) {
      do throws(GPUError) { try body() } catch {
        failed += 1
        var why = ""
        switch error {
        case .unsupported(let w): why = "unsupported: " + w
        case .invalid(let w): why = w
        case .outOfMemory(let w): why = "out of memory: " + w
        case .failed(let call, let code): why = "\(call) failed with \(code)"
        case .noDevice(let w): why = "no device: " + w
        case .lost: why = "the GPU was lost"
        }
        print("loinnir-test: FAILED: frame \(name): " + why)
      }
    }
    attempt("empty") { () throws(GPUError) in _ = try measure("empty", "gpu.mali.frame_empty_us", GPUCommandList()) }
    attempt("clear and draw") { () throws(GPUError) in
      var list = GPUCommandList()
      list.render(pass(target)) { l in l.draw(pipeline, root: quads.address, vertices: 6) }
      _ = try measure("clear and one draw", "gpu.mali.frame_clear_draw_us", list)
      try place("clear and one draw") { l in l.render(pass(target)) { r in r.draw(pipeline, root: quads.address, vertices: 6) } }
      let p = try pixel(target, 400, 300)
      if p != [255, 0, 0, 255] { throw GPUError.invalid("the whole-target draw left \(p) at the centre") }
    }
    attempt("100 draws") { () throws(GPUError) in
      var list = GPUCommandList()
      list.render(pass(target)) { l in
        for i in 1...100 { l.draw(pipeline, root: quads.address, vertices: 6, firstVertex: UInt32(i * 6)) }
      }
      _ = try measure("clear and 100 draws", "gpu.mali.frame_100_draws_us", list)
      // Quad 99 (the last row's last) covers (720 + 8 .. 792 - 8, 540 + 6 .. 594 - 6); outside every quad is the clear.
      let inside = try pixel(target, 760, 570)
      let outside = try pixel(target, 1, 1)
      if inside != [0, 252, 255, 255] && inside != [0, 253, 255, 255] { throw GPUError.invalid("quad 99 is \(inside)") }
      if outside != [0, 0, 0, 255] { throw GPUError.invalid("outside the quads is \(outside)") }
    }
    attempt("two passes") { () throws(GPUError) in
      var list = GPUCommandList()
      list.render(pass(second)) { l in l.draw(pipeline, root: quads.address, vertices: 6) }
      list.render(pass(target)) { l in l.draw(pipeline, root: quads.address, vertices: 6, firstVertex: 6) }
      _ = try measure("two passes", "gpu.mali.frame_two_passes_us", list)
      if try pixel(second, 400, 300) != [255, 0, 0, 255] { throw GPUError.invalid("the first pass's target is wrong") }
    }
    attempt("small pass") { () throws(GPUError) in
      var list = GPUCommandList()
      list.render(pass(small)) { l in l.draw(pipeline, root: quads.address, vertices: 6) }
      _ = try measure("a 64 x 64 pass", "gpu.mali.frame_small_pass_us", list)
      try place("a 64 x 64 pass") { l in l.render(pass(small)) { r in r.draw(pipeline, root: quads.address, vertices: 6) } }
      // Two timestamps with nothing between, on the one queue: what the placing costs by itself.
      try place("nothing") { _ in }
    }
    // A device whose first work is a transfer on the compute queue, and whose first pass then waits for it: the queues'
    // first streams (the Vulkan layer's order, a staging copy before the first pass).
    attempt("a new device's first pass after a transfer") { () throws(GPUError) in
      let fresh = try MaliDevice()
      let m = try fresh.allocate(.device, bytes: 4096)
      var first = GPUCommandList()
      first.fill(m, bytes: 4096, value: 1)
      try fresh.run(first, signal: 1)
      let image = try fresh.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
      let back = try fresh.allocate(.readback, bytes: 64 * 64 * 4)
      let p = try fresh.makeGraphicsPipeline(GraphicsPipelineDescriptor(
        vertex: LoinnirShaders.triangleVert, fragment: LoinnirShaders.triangleFrag, colorFormats: [.rgba8], blend: .opaque))
      let v = try fresh.allocate(.upload, bytes: 6 * 32)
      unsafe v.pointer!.copyMemory(from: quads.pointer!, byteCount: 6 * 32)
      var list = GPUCommandList()
      list.fill(m, bytes: 4096, value: 2)
      list.render(RenderingInfo(colors: [Attachment(image: image, load: .clear(0, 0, 0, 1))])) { l in l.draw(p, root: v.address, vertices: 6) }
      list.copy(image, to: back)
      try fresh.run(list, signal: 2)
      let px = unsafe back.pointer!.assumingMemoryBound(to: UInt8.self)
      let centre = (32 * 64 + 32) * 4
      let got = [unsafe px[centre], unsafe px[centre + 1], unsafe px[centre + 2], unsafe px[centre + 3]]
      if got != [255, 0, 0, 255] { throw GPUError.invalid("a new device's first pass after a transfer drew \(got)") }
      print("loinnir-test: ok: frame: a new device's first pass, after a transfer on the compute queue, drew")
    }
    print("loinnir-test: frame budgets: \(failed == 0 ? "done" : "\(failed) FAILED")")
    return failed
  }
}
