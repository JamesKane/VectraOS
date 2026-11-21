// SPDX-License-Identifier: BSD-3-Clause

// gpu-test's textured quad and alpha blending (gpu-test(8), D174 step 3): Loinnir's own textured.vert and textured.frag
// (graphics/loinnir/tests/shaders: a full-target quad of two triangles sampling a heap texture, indexed non-uniformly)
// compiled on the device, drawing into the 64 x 64 linear RGBA8 target with a 16 x 16 RGBA8 texture uploaded in the
// u-interleaved layout (MaliCore's ImageLayout) and a nearest sampler. Nearest filtering at pixel centres is exact, so
// the first pass is compared with the CPU's sampling of the same texture word for word, apart from the pixels on the
// quad's diagonal (the shared edge's tie-break is the rasteriser's, and is not judged).
//
// The second pass draws the quad twice in one tiler pass: the texture, then a second texture with alpha over it with
// MaliCore's fixed-function blend descriptor for straight alpha (SRC_ALPHA, ONE_MINUS_SRC_ALPHA). The reference is the
// equation on the CPU; each channel may differ by one.
//
// The heap (a resource-table table of 32-byte descriptors: two textures, a sampler), the planes and the texels live in a
// buffer of this program's, as do the parameter blocks the vertex shader's root pointer names (the texture index).

import GPUClient
import GPUDevice
import Sys

enum TexturedCheck {
  static let blockBytes = 32768
  static let arenaAddress: UInt64 = 0x10_0000
  static let steadyAddress: UInt64 = 0x10_8000
  static let colourAddress: UInt64 = 0x20_0000
  static let heapContextAddress: UInt64 = 0x30_0000
  static let chunkAddress: UInt64 = 0x40_0000
  static let geometryAddress: UInt64 = 0x50_0000
  static let imagesAddress: UInt64 = 0x60_0000
  /// The thread storage of the shaders' stacks (Loinnir's vertex shader keeps its corner table on the stack).
  static let threadStorageAddress: UInt64 = 0x1000_0000
  static let width = 64
  static let height = 64
  static let poison: UInt32 = 0xDEAD_BEEF

  // The images buffer: the heap, the planes, the texels and the parameter blocks, 64-byte aligned.
  static let heapOffset = 0
  static let planesAOffset = 256
  static let planesBOffset = 320
  static let texelsAOffset = 4096
  static let texelsBOffset = 8192
  static let paramsAOffset = 12288
  static let paramsBOffset = 12352
  static let imagesBytes = 16384
  /// The heap's entries: the textures at 0 and 1, the sampler at 2; the shaders' binding 0 starts at entry 0 and
  /// binding 1 (the sampler) at entry 2.
  static let samplerIndex = 2
  static let heapEntries = 3

  typealias Compiled = (vertex: VertexShader, fragment: FragmentShader)

  // MARK: the textures and their CPU reference

  /// Texture A (opaque, 2 x 2 texel cells in two colours with a gradient in the cell colour), texel (x, y).
  static func texelA(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    if ((x >> 1) + (y >> 1)) & 1 == 0 { return (255, 64 + x * 8, 32 + y, 255) }
    return (16 + x, y * 16, 200, 255)
  }

  /// Texture B (translucent: alpha grows with x), texel (x, y).
  static func texelB(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    (240 - y * 8, x * 16, y * 16, 32 + 14 * x)
  }

  static func word(_ t: (r: Int, g: Int, b: Int, a: Int)) -> UInt32 {
    UInt32(t.r) | UInt32(t.g) << 8 | UInt32(t.b) << 16 | UInt32(t.a) << 24
  }

  /// The pixel (x, y) of the target samples texel (x / 4, y / 4): u = (x + 0.5) / 64, the texel 16u floored.
  static func expectedA(_ x: Int, _ y: Int) -> UInt32 { word(texelA(x >> 2, y >> 2)) }

  /// Straight alpha of B over A, in 8 bits: the channel `s * a + d * (1 - a)` rounded, alpha `a + d_a * (1 - a)`.
  static func expectedBlend(_ x: Int, _ y: Int) -> [Int] {
    let s = texelB(x >> 2, y >> 2)
    let d = texelA(x >> 2, y >> 2)
    let a = Float(s.a) / 255
    func mix(_ sv: Int, _ dv: Int) -> Int {
      let v = (Float(sv) / 255 * a + Float(dv) / 255 * (1 - a)) * 255
      return Int(v + 0.5)
    }
    let alpha = Int((a + Float(d.a) / 255 * (1 - a)) * 255 + 0.5)
    return [mix(s.r, d.r), mix(s.g, d.g), mix(s.b, d.b), alpha]
  }

  /// Pixels on the quad's diagonal, where the two triangles meet (their centres lie on the shared edge).
  static func onDiagonal(_ x: Int, _ y: Int) -> Bool {
    let d = x + y - (width - 1)
    return d >= -1 && d <= 1
  }

  // MARK: the rig

  struct Rig {
    var context: CSFContext
    var arena: CSFBuffer
    var colour: CSFBuffer
    var heapContext: CSFBuffer
    var chunk: CSFBuffer
    var geometry: CSFBuffer
    var images: CSFBuffer
    var group: UInt32
    var sync: UInt32
    var registers: CSRegisterMap
    var scoreboards: CSScoreboards
    var arch: Int
    var limits: ComputeLimits
    var threadStorage: UInt64
  }

  static func makeRig(queues: Int, stackBytes: UInt32) -> Rig? {
    do throws(CSFClientError) {
      let c = try CSFContext()
      let vm = try c.createVM().id
      let arena = try c.createBuffer(size: 2 * blockBytes)
      try c.bind(vm: vm, buffer: arena, size: UInt64(arena.size), address: arenaAddress)
      let colour = try c.createBuffer(size: 16384)
      try c.bind(vm: vm, buffer: colour, size: UInt64(colour.size), address: colourAddress)
      let heapContext = try c.createBuffer(size: 4096)
      try c.bind(vm: vm, buffer: heapContext, size: UInt64(heapContext.size), address: heapContextAddress)
      let chunk = try c.createBuffer(size: Int(TilerHeapSizing.smallPassChunkBytes))
      try c.bind(vm: vm, buffer: chunk, size: UInt64(chunk.size), address: chunkAddress)
      let geometry = try c.createBuffer(size: 65536)
      try c.bind(vm: vm, buffer: geometry, size: UInt64(geometry.size), address: geometryAddress)
      let images = try c.createBuffer(size: imagesBytes)
      try c.bind(vm: vm, buffer: images, size: UInt64(images.size), address: imagesAddress)
      let info = c.info
      guard let thread = c.limits else {
        print("gpu-test: textured: the driver reports no thread limits")
        return nil
      }
      let limits = ComputeLimits(
        maxThreads: thread.maxThreads, maxWorkgroupSize: thread.maxWorkgroupSize, threadFeatures: thread.threadFeatures,
        shaderPresent: info.shaderPresent)
      guard limits.isUsable else {
        print("gpu-test: textured: the thread limits are unusable")
        return nil
      }
      var tls: UInt64 = 0
      if stackBytes != 0 {
        let bytes = ThreadStorageSizing.tlsTotal(stackBytes: stackBytes, limits: limits)
        let buffer = try c.createBuffer(size: Int((bytes + 4095) / 4096 * 4096))
        try c.bind(vm: vm, buffer: buffer, size: UInt64(buffer.size), address: threadStorageAddress)
        tls = threadStorageAddress
      }
      var rings: [UInt32] = []
      for _ in 0..<queues { rings.append(4096) }
      let group = try c.createGroup(vm: vm, ringSizes: rings)
      let sync = try c.createSync()
      return Rig(
        context: c, arena: arena, colour: colour, heapContext: heapContext, chunk: chunk, geometry: geometry, images: images,
        group: group, sync: sync,
        registers: CSRegisterMap(workRegisters: Int(info.workRegisters), unpreserved: Int(info.unpreservedRegisters)),
        scoreboards: CSScoreboards(count: Int(info.scoreboards)), arch: Int(info.gpuID >> 28), limits: limits,
        threadStorage: tls)
    } catch {
      print("gpu-test: textured: context: \(error)")
      return nil
    }
  }

  /// The heap, planes, texels and parameter blocks into the images buffer. nil, with the reason, when a descriptor
  /// is refused.
  static func upload(_ rig: Rig) -> String? {
    let layoutA = ImageLayout(format: .rgba8, kind: .uInterleaved, width: 16, height: 16)
    let layoutB = ImageLayout(format: .rgba8, kind: .uInterleaved, width: 16, height: 16)
    for y in 0..<16 {
      for x in 0..<16 {
        rig.images.store(word(texelA(x, y)), at: texelsAOffset + layoutA.texelOffset(x: x, y: y))
        rig.images.store(word(texelB(x, y)), at: texelsBOffset + layoutB.texelOffset(x: x, y: y))
      }
    }
    var heap = DescriptorHeap()
    do throws(DescriptorError) {
      for (n, (layout, planes, texels)) in [(layoutA, planesAOffset, texelsAOffset), (layoutB, planesBOffset, texelsBOffset)].enumerated() {
        let plane = layout.planes(base: imagesAddress + UInt64(texels))[0]
        let words = try plane.words()
        for (i, w) in words.enumerated() { rig.images.store(w, at: planes + 4 * i) }
        let texture = TextureDescriptor(image: layout, surfaces: imagesAddress + UInt64(planes))
        let index = heap.add(try texture.words())
        if index != n { return "the heap's entry \(index) is not \(n)" }
      }
      let index = heap.add(try SamplerDescriptor.nearest.words())
      if index != samplerIndex { return "the sampler's entry \(index) is not \(samplerIndex)" }
    } catch {
      return "a descriptor was refused: \(error)"
    }
    for (i, w) in heap.words.enumerated() { rig.images.store(w, at: heapOffset + 4 * i) }
    // The vertex shader's parameter blocks: a texture index each.
    for i in 0..<16 {
      rig.images.store(UInt32(0), at: paramsAOffset + 4 * i)
      rig.images.store(UInt32(0), at: paramsBOffset + 4 * i)
    }
    rig.images.store(UInt32(0), at: paramsAOffset)
    rig.images.store(UInt32(1), at: paramsBOffset)
    return nil
  }

  static func draw(_ shaders: Compiled, params: Int, blend: BlendDescriptor) -> PassDraw {
    let root = imagesAddress + UInt64(params)
    return PassDraw(
      vertexShader: shaders.vertex, fragmentShader: shaders.fragment, vertexCount: 6,
      push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)], blend: blend,
      images: [
        BindingHandle(set: 0, binding: 0, handle: DescriptorHeap.handle(index: 0)),
        BindingHandle(set: 0, binding: 1, handle: DescriptorHeap.handle(index: samplerIndex)),
      ])
  }

  static func request(_ layout: RenderQueueLayout, initialise: Bool, draws: [PassDraw], rig: Rig) -> DrawPassRequest {
    DrawPassRequest(
      width: width, height: height, format: .rgba8, colourAddress: colourAddress, clear: [0, 0, 0, 1], draws: draws,
      heapAddress: imagesAddress + UInt64(heapOffset), heapBytes: heapEntries * DescriptorHeap.descriptorBytes,
      heapContext: heapContextAddress, heapChunk: chunkAddress, heapChunkBytes: TilerHeapSizing.smallPassChunkBytes,
      geometryBuffer: geometryAddress, layout: layout, initialiseQueues: initialise, threadStorage: rig.threadStorage,
      limits: rig.limits)
  }

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

  // MARK: judging

  struct Verdict {
    var wrong = 0
    var judged = 0
    var first = ""
    var poisoned = 0
    var cleared = 0
  }

  /// `tolerance` 0 compares words; otherwise each channel within it.
  static func judge(_ rig: Rig, blend: Bool, tolerance: Int) -> Verdict {
    var v = Verdict()
    for y in 0..<height {
      for x in 0..<width {
        let w = rig.colour.load(UInt32.self, at: 4 * (width * y + x))
        if w == poison { v.poisoned += 1 }
        if w == 0xFF00_0000 { v.cleared += 1 }
        if onDiagonal(x, y) { continue }
        v.judged += 1
        var ok = true
        var want = ""
        if blend {
          let e = expectedBlend(x, y)
          for c in 0..<4 {
            let g = Int(w >> UInt32(8 * c) & 0xFF)
            let d = g - e[c]
            if d > tolerance || d < -tolerance { ok = false }
          }
          want = "(\(e[0]), \(e[1]), \(e[2]), \(e[3]))"
        } else {
          ok = w == expectedA(x, y)
          want = "0x" + String(expectedA(x, y), radix: 16)
        }
        if !ok {
          v.wrong += 1
          if v.first.isEmpty { v.first = "pixel (\(x), \(y)) reads 0x\(String(w, radix: 16)), expected \(want)" }
        }
      }
    }
    return v
  }

  struct Outcome {
    var drawn = false
    var micros: Int64 = 0
    var repeats: [Int64] = []
    var message = ""
  }

  static func attempt(_ layout: RenderQueueLayout, shaders: Compiled, blend: Bool) -> Outcome {
    var out = Outcome()
    let name = layout == .splitQueues ? "two queues" : "one queue"
    let stack = max(shaders.vertex.stackBytes, shaders.fragment.stackBytes)
    guard let rig = makeRig(queues: layout == .splitQueues ? 2 : 1, stackBytes: stack) else {
      out.message = "\(name): no context"
      return out
    }
    if let why = upload(rig) {
      out.message = "\(name): \(why)"
      return out
    }
    var draws = [draw(shaders, params: paramsAOffset, blend: BlendDescriptor(renderTarget: 0))]
    if blend {
      do throws(BlendRefusal) {
        draws.append(draw(shaders, params: paramsBOffset, blend: try BlendDescriptor(state: BlendState(enabled: true, equation: .alpha))))
      } catch {
        out.message = "\(name): the blend state needs a blend shader"
        return out
      }
    }
    let first: RenderPassImage
    let steady: RenderPassImage
    do throws(RenderError) {
      first = try RenderPass.build(
        at: arenaAddress, capacity: blockBytes, request: request(layout, initialise: true, draws: draws, rig: rig), registers: rig.registers,
        scoreboards: rig.scoreboards, arch: rig.arch).image
      steady = try RenderPass.build(
        at: steadyAddress, capacity: blockBytes, request: request(layout, initialise: false, draws: draws, rig: rig), registers: rig.registers,
        scoreboards: rig.scoreboards, arch: rig.arch).image
    } catch {
      out.message = "\(name): the recipe: \(error)"
      return out
    }
    prepare(rig)
    TriangleCheck.put(first, into: rig.arena, at: 0)
    TriangleCheck.put(steady, into: rig.arena, at: Int(steadyAddress - arenaAddress))
    let start = Clock.monotonic()
    do throws(CSFClientError) {
      try rig.context.submit(group: rig.group, jobs: TriangleCheck.jobs(first), signals: [(rig.sync, 1)])
    } catch {
      out.message = "\(name): submit: \(error)"
      return out
    }
    guard rig.context.wait(sync: rig.sync, value: 1, timeoutNanoseconds: 8_000_000_000) else {
      var why = "no sync within 8 s"
      if let s = try? rig.context.groupState(rig.group) { why += " (group state \(s.state), fatal queues \(s.fatalQueues))" }
      out.message = "\(name): \(why)"
      return out
    }
    out.micros = (Clock.monotonic() - start) / 1000
    guard let state = try? rig.context.groupState(rig.group), state.state == 0 else {
      out.message = "\(name): the group's state isn't clean after the pass"
      return out
    }
    let v = judge(rig, blend: blend, tolerance: blend ? 1 : 0)
    if v.wrong != 0 || v.judged < 3000 {
      var hint = ""
      if v.poisoned == width * height { hint = " (the colour buffer was never written)" }
      else if v.cleared == width * height { hint = " (cleared, but nothing was drawn)" }
      out.message = "\(name): \(v.wrong) of \(v.judged) judged pixels are wrong: \(v.first)\(hint)"
      return out
    }
    out.drawn = true
    out.message = "\(name): \(v.judged) pixels judged, \(width * height - v.judged) on the diagonal not judged"
    for i in 0..<8 {
      TriangleCheck.put(steady, into: rig.arena, at: Int(steadyAddress - arenaAddress))
      let t0 = Clock.monotonic()
      do throws(CSFClientError) {
        try rig.context.submit(group: rig.group, jobs: TriangleCheck.jobs(steady), signals: [(rig.sync, UInt64(i + 2))])
      } catch { break }
      guard rig.context.wait(sync: rig.sync, value: UInt64(i + 2), timeoutNanoseconds: 3_000_000_000) else { break }
      out.repeats.append((Clock.monotonic() - t0) / 1000)
    }
    return out
  }

  // MARK: the run

  /// Compile Loinnir's textured quad; nil, with the failure recorded, when the compiler refuses one.
  static func compileShaders() -> Compiled? {
    var vertex: VertexShader?
    var fragment: FragmentShader?
    for (name, words) in [("texturedVertex", TexturedShaders.texturedVertex), ("texturedFragment", TexturedShaders.texturedFragment)] {
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

  static func run(_ compiled: Compiled?, layout: RenderQueueLayout?) {
    guard let shaders = compiled, let layout = layout else {
      GPUTest.softFail("no textured quad: the compiler's shaders or the triangle's layout were not made")
      return
    }
    let order: [RenderQueueLayout] = layout == .splitQueues ? [.splitQueues, .singleQueue] : [.singleQueue, .splitQueues]
    var drawn: Outcome?
    var messages = ""
    for l in order {
      let o = attempt(l, shaders: shaders, blend: false)
      if o.drawn {
        drawn = o
        break
      }
      messages += (messages.isEmpty ? "" : "; ") + o.message
    }
    guard let o = drawn else {
      GPUTest.softFail("no textured quad: \(messages)")
      return
    }
    var micros = o.micros
    if o.repeats.count >= 3 {
      var sorted = o.repeats
      sorted.sort()
      micros = sorted[sorted.count / 2]
    }
    print("gpu-test: ok: a textured quad was drawn (\(o.message); first pass \(o.micros) us, timed \(micros) us)")
    print("budget name=gpu.mali.textured_quad_ms value=\((micros + 999) / 1000) unit=ms")

    let b = attempt(layout, shaders: shaders, blend: true)
    if b.drawn {
      print("gpu-test: ok: alpha blending (\(b.message); each channel within 1 of the equation)")
    } else {
      GPUTest.softFail("alpha blending: \(b.message)")
    }
  }
}
