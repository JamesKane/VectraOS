// SPDX-License-Identifier: BSD-3-Clause

// gpu-test's triangle (gpu-test(8), D174 step 2): one triangle drawn into a 64 x 64
// linear RGBA8 target cleared to black, by MaliCore's render pass recipe over its
// two hand-assembled shaders (graphics/mali: RenderPass, RenderShaders), read
// back and compared with the CPU's rasterisation of the same triangle. The
// valhall spec says nothing of the rasteriser's fill rule beyond a tie-break
// number, so a pixel whose centre is within one pixel of an edge is not judged;
// every other pixel must be exactly the triangle's colour or exactly the clear.
//
// Memory here is the client's own: the tiler heap's context (the kernel creates
// it for its own heaps, panthor 08, but the csf capset has no heap call yet; the
// firmware is told the address by HEAP_SET), its one chunk and the geometry buffer
// are buffers of this program. The heap is a megabyte for one triangle, so no
// TILER_OOM can be raised (TilerHeapSizing.smallPassChunkBytes says why).
//
// Two stream layouts are tried in order, each in a context of its own: valhall 02's
// vertex/tiler queue and fragment queue joined by a sync object, then a single
// stream that does both. The first that draws is the one reported.
//
// Then the same triangle again with the compiler's shaders (graphics/compiler: a vertex shader that reads clip
// positions through the root pointer and transforms them, a fragment shader of one constant colour), compiled
// from SPIR-V on the device, in the layout that drew, and judged by the same pixel comparison.

import GPUClient
import GPUDevice
import Sys

enum TriangleCheck {
  static let arenaAddress: UInt64 = 0x10_0000
  static let steadyAddress: UInt64 = 0x10_4000
  static let imageBytes = 16384
  static let colourAddress: UInt64 = 0x20_0000
  static let heapContextAddress: UInt64 = 0x30_0000
  static let chunkAddress: UInt64 = 0x40_0000
  static let geometryAddress: UInt64 = 0x50_0000
  static let width = 64
  static let height = 64
  static let poison: UInt32 = 0xDEAD_BEEF
  /// The triangle, in window coordinates (integers, so the reference's arithmetic is exact), and its colour.
  static func corner(_ i: Int) -> (x: Int, y: Int) {
    switch i {
    case 0: return (8, 6)
    case 1: return (58, 20)
    default: return (20, 56)
    }
  }
  static let red: UInt32 = 255
  static let greenLow: UInt32 = 127
  static let greenHigh: UInt32 = 128
  static let clear: UInt32 = 0xFF00_0000

  struct Rig {
    var context: CSFContext
    var arena: CSFBuffer
    var colour: CSFBuffer
    var heapContext: CSFBuffer
    var chunk: CSFBuffer
    var geometry: CSFBuffer
    var group: UInt32
    var sync: UInt32
    var registers: CSRegisterMap
    var scoreboards: CSScoreboards
    var arch: Int
  }

  /// A context with every buffer bound and a group of one queue per stream.
  static func makeRig(queues: Int) -> Rig? {
    do throws(CSFClientError) {
      let c = try CSFContext()
      let vm = try c.createVM().id
      let arena = try c.createBuffer(size: 2 * imageBytes)
      try c.bind(vm: vm, buffer: arena, size: UInt64(arena.size), address: arenaAddress)
      let colour = try c.createBuffer(size: 16384)
      try c.bind(vm: vm, buffer: colour, size: UInt64(colour.size), address: colourAddress)
      let heapContext = try c.createBuffer(size: 4096)
      try c.bind(vm: vm, buffer: heapContext, size: UInt64(heapContext.size), address: heapContextAddress)
      let chunk = try c.createBuffer(size: Int(TilerHeapSizing.smallPassChunkBytes))
      try c.bind(vm: vm, buffer: chunk, size: UInt64(chunk.size), address: chunkAddress)
      let geometry = try c.createBuffer(size: 65536)
      try c.bind(vm: vm, buffer: geometry, size: UInt64(geometry.size), address: geometryAddress)
      var rings: [UInt32] = []
      for _ in 0..<queues { rings.append(4096) }
      let group = try c.createGroup(vm: vm, ringSizes: rings)
      let sync = try c.createSync()
      let info = c.info
      return Rig(
        context: c, arena: arena, colour: colour, heapContext: heapContext, chunk: chunk, geometry: geometry, group: group,
        sync: sync, registers: CSRegisterMap(workRegisters: Int(info.workRegisters), unpreserved: Int(info.unpreservedRegisters)),
        scoreboards: CSScoreboards(count: Int(info.scoreboards)), arch: Int(info.gpuID >> 28))
    } catch {
      print("gpu-test: triangle: context: \(error)")
      return nil
    }
  }

  /// The compiler's shaders for the triangle.
  typealias Compiled = (vertex: VertexShader, fragment: FragmentShader)

  static func request(_ layout: RenderQueueLayout, initialise: Bool, shaders: Compiled? = nil) -> RenderPassRequest {
    var vertices: [WindowVertex] = []
    for i in 0..<3 {
      let c = corner(i)
      vertices.append(WindowVertex(x: Float(c.x), y: Float(c.y)))
    }
    return RenderPassRequest(
      width: width, height: height, format: .rgba8, colourAddress: colourAddress, clear: [0, 0, 0, 1], vertices: vertices,
      colour: [1, 0.5, 0, 1], heapContext: heapContextAddress, heapChunk: chunkAddress,
      heapChunkBytes: TilerHeapSizing.smallPassChunkBytes, geometryBuffer: geometryAddress, layout: layout,
      initialiseQueues: initialise, vertexShader: shaders?.vertex, fragmentShader: shaders?.fragment)
  }

  /// Store the image's bytes into the arena at `offset`.
  static func put(_ image: RenderPassImage, into buffer: CSFBuffer, at offset: Int) {
    var i = 0
    while i < image.memory.count {
      buffer.store(image.memory.load64(at: i), at: offset + i)
      i += 8
    }
  }

  static func jobs(_ image: RenderPassImage) -> [GPUCSFIPC.Job] {
    var list: [GPUCSFIPC.Job] = []
    for (queue, s) in image.streams.enumerated() {
      list.append(GPUCSFIPC.Job(queue: UInt32(queue), stream: s.address, size: UInt32(s.size), flush: 0))
    }
    return list
  }

  /// Fill the colour buffer with the poison word, and zero what the firmware expects zero: the heap context (32
  /// bytes on a 64-byte stride, panthor 08 section 8.2.2) and the chunk's 64-byte header.
  static func prepare(_ rig: Rig) {
    var i = 0
    while i < rig.colour.size {
      rig.colour.store(poison, at: i)
      i += 4
    }
    i = 0
    while i < 64 {
      rig.heapContext.store(UInt64(0), at: i)
      rig.chunk.store(UInt64(0), at: i)
      i += 8
    }
  }

  /// The pass, submitted and waited for, in microseconds; nil on a timeout, with the group's state in `why`.
  static func submitAndWait(_ rig: Rig, _ image: RenderPassImage, value: UInt64, timeoutSeconds: UInt64, why: inout String)
    -> Int64?
  {
    let start = Clock.monotonic()
    do throws(CSFClientError) {
      try rig.context.submit(group: rig.group, jobs: jobs(image), signals: [(rig.sync, value)])
    } catch {
      why = "submit: \(error)"
      return nil
    }
    guard rig.context.wait(sync: rig.sync, value: value, timeoutNanoseconds: timeoutSeconds * 1_000_000_000) else {
      why = "no sync within \(timeoutSeconds) s"
      if let s = try? rig.context.groupState(rig.group) { why += " (group state \(s.state), fatal queues \(s.fatalQueues))" }
      return nil
    }
    return (Clock.monotonic() - start) / 1000
  }

  // MARK: The reference

  /// 0 inside, 1 outside, 2 within a pixel of an edge (not judged). Doubled coordinates make every product an
  /// integer: the pixel centre is (2x + 1, 2y + 1) against corners at twice their position, and a distance of one
  /// pixel is two units: |e| < 2 |edge| is e * e < 4 (dx * dx + dy * dy).
  static func classify(_ x: Int, _ y: Int, flipY: Bool = false) -> Int {
    let cx = 2 * x + 1
    let cy = 2 * (flipY ? height - 1 - y : y) + 1
    var signs = 0
    var near = false
    var area = 0
    for i in 0..<3 {
      let p = corner(i)
      let q = corner((i + 1) % 3)
      let r = corner((i + 2) % 3)
      let dx = 2 * (q.x - p.x)
      let dy = 2 * (q.y - p.y)
      let e = dx * (cy - 2 * p.y) - dy * (cx - 2 * p.x)
      if e * e < 4 * (dx * dx + dy * dy) { near = true }
      // The triangle's own orientation: the third corner against the edge.
      area = dx * (2 * r.y - 2 * p.y) - dy * (2 * r.x - 2 * p.x)
      if (e > 0) == (area > 0) && e != 0 { signs += 1 }
    }
    if near { return 2 }
    return signs == 3 ? 0 : 1
  }

  /// Whether the word is the triangle's colour (red 255, green 127 or 128 for the 0.5 the shader gives, blue 0, alpha
  /// 255) or, outside it, the clear.
  static func matches(_ w: UInt32, inside: Bool) -> Bool {
    if !inside { return w == clear }
    let green = w >> 8 & 0xFF
    return w & 0xFF == red && (green == greenLow || green == greenHigh) && w >> 16 & 0xFF == 0 && w >> 24 == 0xFF
  }

  static func expectedWord(inside: Bool) -> UInt32 { inside ? 0xFF00_80FF : clear }

  struct Verdict {
    var wrong = 0
    var judged = 0
    var inside = 0
    var edge = 0
    var first = ""
    var poisoned = 0
    var cleared = 0
    var coloured = 0
    var flippedWrong = 0
  }

  static func judge(_ rig: Rig) -> Verdict {
    var v = Verdict()
    for y in 0..<height {
      for x in 0..<width {
        let w = rig.colour.load(UInt32.self, at: 4 * (width * y + x))
        if w == poison { v.poisoned += 1 }
        if w == clear { v.cleared += 1 }
        if w & 0xFF == red && w >> 24 == 0xFF { v.coloured += 1 }
        let flipped = classify(x, y, flipY: true)
        let k = classify(x, y)
        if flipped != 2 && !matches(w, inside: flipped == 0) { v.flippedWrong += 1 }
        if k == 2 {
          v.edge += 1
          continue
        }
        v.judged += 1
        if k == 0 { v.inside += 1 }
        if !matches(w, inside: k == 0) {
          v.wrong += 1
          if v.first.isEmpty {
            v.first = "pixel (\(x), \(y)) reads 0x\(String(w, radix: 16)), expected 0x\(String(expectedWord(inside: k == 0), radix: 16))"
          }
        }
      }
    }
    return v
  }

  // MARK: One attempt

  struct Outcome {
    var drawn = false
    var micros: Int64 = 0
    var repeats: [Int64] = []
    var message = ""
  }

  static func attempt(_ layout: RenderQueueLayout, shaders: Compiled? = nil) -> Outcome {
    var out = Outcome()
    let name = layout == .splitQueues ? "two queues" : "one queue"
    guard let rig = makeRig(queues: layout == .splitQueues ? 2 : 1) else {
      out.message = "\(name): no context"
      return out
    }
    let first: RenderPassImage
    let steady: RenderPassImage
    do throws(RenderError) {
      first = try RenderPass.build(at: arenaAddress, capacity: imageBytes, request: request(layout, initialise: true, shaders: shaders),
                                   registers: rig.registers, scoreboards: rig.scoreboards, arch: rig.arch)
      steady = try RenderPass.build(at: steadyAddress, capacity: imageBytes, request: request(layout, initialise: false, shaders: shaders),
                                    registers: rig.registers, scoreboards: rig.scoreboards, arch: rig.arch)
    } catch {
      out.message = "\(name): the recipe: \(error)"
      return out
    }
    prepare(rig)
    put(first, into: rig.arena, at: 0)
    put(steady, into: rig.arena, at: Int(steadyAddress - arenaAddress))
    var why = ""
    guard let micros = submitAndWait(rig, first, value: 1, timeoutSeconds: 8, why: &why) else {
      out.message = "\(name): \(why)"
      return out
    }
    out.micros = micros
    guard let state = try? rig.context.groupState(rig.group), state.state == 0 else {
      out.message = "\(name): the group's state isn't clean after the pass"
      return out
    }
    let v = judge(rig)
    if v.wrong != 0 || v.inside < 200 {
      var hint = ""
      if v.poisoned == width * height { hint = " (the colour buffer was never written)" }
      else if v.cleared + v.poisoned == width * height && v.coloured == 0 { hint = " (cleared, but nothing was drawn)" }
      else if v.flippedWrong == 0 { hint = " (it matches the image turned upside down)" }
      out.message = "\(name): \(v.wrong) of \(v.judged) judged pixels are wrong, \(v.inside) should be inside: \(v.first)\(hint)"
      return out
    }
    out.drawn = true
    out.message = "\(name): \(v.inside) pixels inside the triangle, \(v.judged - v.inside) outside, \(v.edge) at an edge not judged"
    // Repeat passes for the budget: the queues' state is the first pass's, so the steady image leaves it out. The
    // image is rewritten each time, which resets the tiler context and the heap descriptor.
    for i in 0..<8 {
      put(steady, into: rig.arena, at: Int(steadyAddress - arenaAddress))
      var again = ""
      guard let t = submitAndWait(rig, steady, value: UInt64(i + 2), timeoutSeconds: 3, why: &again) else {
        print("gpu-test: triangle: repeat \(i + 1) didn't finish (\(again)); the budget is the first pass's")
        break
      }
      out.repeats.append(t)
    }
    return out
  }

  /// Compile the triangle's two shaders from the committed SPIR-V (the compile's time is printed, as the compute
  /// shaders' are); nil, with the failure recorded, when the compiler refuses one.
  static func compileShaders() -> Compiled? {
    var vertex: VertexShader?
    var fragment: FragmentShader?
    for (name, words) in [("triangleVertex", CompilerShaders.triangleVertex), ("triangleFragment", CompilerShaders.triangleFragment)] {
      let start = Clock.monotonic()
      let c: CompiledGraphicsShader
      do throws(BackendError) { c = try ValhallBackend.compileGraphics(spirv: words) } catch {
        GPUTest.softFail("the compiler refused \(name): \(error)")
        return nil
      }
      let took = GPUTest.micros(Clock.monotonic() - start)
      print("gpu-test: compiled \(name): \(c.instructions.count) instructions, \(c.registersUsed) registers, \(c.spillSlots) spills, \(took) us")
      if let v = c.vertex { vertex = v }
      if let f = c.fragment { fragment = f }
    }
    guard let v = vertex, let f = fragment else { return nil }
    return (v, f)
  }

  static func run(_ compiled: Compiled?) {
    var messages: [String] = []
    var layoutThatDrew: RenderQueueLayout?
    for layout in [RenderQueueLayout.splitQueues, RenderQueueLayout.singleQueue] {
      let o = attempt(layout)
      if o.drawn {
        var micros = o.micros
        if o.repeats.count >= 3 {
          var sorted = o.repeats
          sorted.sort()
          micros = sorted[sorted.count / 2]
        }
        print("gpu-test: ok: a triangle was drawn (\(o.message); first pass \(o.micros) us, timed \(micros) us)")
        print("budget name=gpu.mali.triangle_ms value=\((micros + 999) / 1000) unit=ms")
        layoutThatDrew = layout
        break
      }
      print("gpu-test: triangle: \(o.message)")
      messages.append(o.message)
    }
    guard let layout = layoutThatDrew else {
      var all = ""
      for m in messages { all += (all.isEmpty ? "" : "; ") + m }
      GPUTest.fail("no triangle: \(all)")
    }
    guard let shaders = compiled else {
      GPUTest.softFail("no compiled triangle: the compiler's shaders were not made")
      return
    }
    // The same draw with the compiled shaders, in the layout that drew.
    let o = attempt(layout, shaders: shaders)
    if o.drawn {
      print("gpu-test: ok: a compiled triangle was drawn (\(o.message); first pass \(o.micros) us)")
    } else {
      GPUTest.softFail("the compiled triangle: \(o.message)")
    }
  }
}
