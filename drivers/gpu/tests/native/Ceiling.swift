// SPDX-License-Identifier: BSD-3-Clause

// gpu-test's ceiling (gpu-test(8)): what a 4K frame can cost at best on this GPU, measured, so that a compose budget is
// set from the hardware and not guessed. Report only: every line is a `budget name=... value=... unit=...` with no
// limit, and a probe that cannot run says so and is skipped.
//
//   gpu.mali.clock_mhz      the GPU core clock as the SCMI agent reports it (CLOCK_RATE_GET through scmi(3)'s ctl)
//   gpu.mali.clear_4k_us    a 3840 x 2160 bgra8 pass, cleared, with a draw that covers no pixel: the tile write-back floor
//   gpu.mali.copy_4k_us     the same pass with one full-target quad sampling a 3840 x 2160 linear bgra8 texture, one
//                           nearest texel a pixel, no blend: the least a full-screen compose touches
//   gpu.mali.blend_4k_us    two such quads, the second alpha-blended over the first
//   gpu.mali.dram_gbps_x10  a compute shader copying 64 MiB to another buffer in vec4s, GB/s times 10, the bytes read
//                           and written together over the time from the submit to the counter's rise
//
// Each render probe has a context of its own (the 33 MB target and texture, the tiler heap's one 8 MiB chunk) and runs
// the pass once (the warm-up, which sets the queues up) and five more times with the steady stream: the budget is the
// median of those five, submit to done. The textured quad is Loinnir's own (TexturedShaders); the quad that covers
// nothing is the constant-varying probe's vertex shader over three equal positions; the copy is
// shaders/copy.comp, made on the host by vx shaders. Images are linear, and the texture is only written at the five
// pixels the check reads, so nothing here is slow on the CPU.

import GPUClient
import GPUDevice
import Node
import Sys

/// The shaders the ceiling compiles; nil where the compiler refused one (said, and the probes that need it skipped).
struct CeilingSet {
  var vertex: VertexShader?
  var fragment: FragmentShader?
  var copy: CompiledShader?
}

enum CeilingCheck {
  static let width = 3840
  static let height = 2160
  static let frameBytes = width * height * 4
  static let chunkBytes: UInt64 = 8 << 20

  // The VM: the render pass's records, the small buffers, the tiler's chunk, the target and the texture, apart.
  static let arenaAddress: UInt64 = 0x10_0000
  static let steadyAddress: UInt64 = 0x10_8000
  static let imageBytes = 32768
  static let heapContextAddress: UInt64 = 0x12_0000
  static let geometryAddress: UInt64 = 0x13_0000
  static let imagesAddress: UInt64 = 0x14_0000
  static let chunkAddress: UInt64 = 0x200_0000
  static let colourAddress: UInt64 = 0x400_0000
  static let textureAddress: UInt64 = 0x800_0000
  static let threadStorageAddress: UInt64 = 0x1000_0000
  static let poison: UInt32 = 0xDEAD_BEEF

  /// The target's clear: opaque red, so a pixel that reads it was written by the tile write-back.
  static let clearColour: [Float] = [1, 0, 0, 1]

  // MARK: shaders

  /// SPIR-V's words from the bytes vx shaders committed.
  static func words(_ bytes: [UInt8]) -> [UInt32] {
    var out: [UInt32] = []
    var i = 0
    while i + 3 < bytes.count {
      out.append(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
      i += 4
    }
    return out
  }

  /// Compile the three shaders. Needs no GPU; a refusal is said and the probes that need the shader are skipped.
  static func compileShaders() -> CeilingSet {
    var set = CeilingSet()
    do throws(BackendError) {
      let v = try ValhallBackend.compileGraphics(spirv: CompilerShaders.constVaryingVertex)
      let f = try ValhallBackend.compileGraphics(spirv: CompilerShaders.varyingFragment)
      set.vertex = v.vertex
      set.fragment = f.fragment
    } catch {
      print("gpu-test: ceiling: the compiler refused the clear's shaders: \(error)")
    }
    let start = Clock.monotonic()
    do throws(BackendError) {
      let c = try ValhallBackend.compile(spirv: words(CeilingShaders.copyComp))
      print("gpu-test: compiled copy: \(c.instructions.count) instructions, \(c.registersUsed) registers, \(c.spillSlots) spills,"
        + " \(GPUTest.micros(Clock.monotonic() - start)) us")
      set.copy = c
    } catch {
      print("gpu-test: ceiling: the compiler refused the copy shader: \(error)")
    }
    return set
  }

  // MARK: the clock

  /// The digits at the start of `text` from `from`, nil if none.
  static func number(_ text: [UInt8], from: Int) -> UInt64? {
    var i = from
    var value: UInt64 = 0
    var any = false
    while i < text.count, text[i] >= 0x30, text[i] <= 0x39 {
      value = value &* 10 &+ UInt64(text[i] - 0x30)
      any = true
      i += 1
    }
    return any ? value : nil
  }

  /// Whether `line` holds `needle` (lower case ASCII), ignoring case.
  static func has(_ line: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    if line.count < needle.count { return false }
    var i = 0
    while i + needle.count <= line.count {
      var same = true
      var k = 0
      while k < needle.count {
        var c = line[i + k]
        if c >= 0x41 && c <= 0x5A { c += 0x20 }
        if c != needle[k] {
          same = false
          break
        }
        k += 1
      }
      if same { return true }
      i += 1
    }
    return false
  }

  static func lines(_ text: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var line: [UInt8] = []
    for b in text.utf8 {
      if b == 0x0A {
        out.append(line)
        line = []
      } else {
        line.append(b)
      }
    }
    if !line.isEmpty { out.append(line) }
    return out
  }

  /// The GPU's clocks, `id name`, from devmgr's platform directories (the lines of a `clocks` file that name a GPU), or
  /// the two mali(3) says it turns on.
  static func gpuClocks(_ ns: Namespace) -> [(id: UInt64, name: String)] {
    var found: [(id: UInt64, name: String)] = []
    let entries = (try? ns.list("/svc/devmgr/platform")) ?? []
    for e in entries {
      guard let text = ns.readText("/svc/devmgr/platform/\(e.name)/clocks") else { continue }
      for line in lines(text) where has(line, Array("gpu".utf8)) {
        var space = 0
        while space < line.count && line[space] != 0x20 { space += 1 }
        guard let id = number(line, from: 0), space < line.count else { continue }
        found.append((id, String(decoding: line[(space + 1)...], as: UTF8.self)))
      }
    }
    if found.isEmpty { return [(31, "gpu_clk_core"), (32, "gpu_clk_stacks")] }
    return found
  }

  /// The rate the agent reports for clock `id` after a CLOCK_RATE_GET, in Hz; nil, with the reason, where it can't be read.
  static func rate(_ ns: Namespace, id: UInt64) -> (hertz: UInt64?, why: String) {
    guard ns.writeText("/dev/scmi/ctl", "clock \(id) rate\n") else {
      return (nil, "the SCMI agent at /dev/scmi/ctl refused `clock \(id) rate`")
    }
    guard let status = ns.readText("/dev/scmi/status") else { return (nil, "/dev/scmi/status can't be read") }
    let want = Array("clock \(id) rate ".utf8)
    for line in lines(status) where line.starts(with: want) {
      if let hz = number(line, from: want.count) { return (hz, "") }
    }
    return (nil, "the agent's status has no rate for clock \(id)")
  }

  static func reportClock(_ ns: Namespace) {
    var core: UInt64?
    for clock in gpuClocks(ns) {
      let r = rate(ns, id: clock.id)
      guard let hz = r.hertz else {
        print("gpu-test: ceiling: clock \(clock.id) \(clock.name): rate unknown: \(r.why)")
        continue
      }
      print("gpu-test: ceiling: clock \(clock.id) \(clock.name): \(hz) Hz")
      if core == nil && has(Array(clock.name.utf8), Array("core".utf8)) { core = hz }
    }
    reportPerformance(ns)
    guard let hz = core else {
      print("gpu-test: ceiling: the GPU core clock's rate can't be read through SCMI; gpu.mali.clock_mhz is not reported")
      return
    }
    print("budget name=gpu.mali.clock_mhz value=\(hz / 1_000_000) unit=MHz")
  }

  /// The GPU's SCMI performance domain (the Sky1's `gpu_core`, domain 0: its DVFS levels): its level as the agent reads it now,
  /// as `gpu.mali.perf_level` in the platform's units, and its limits where the agent may read them.
  static func reportPerformance(_ ns: Namespace) {
    let domain = 0
    func ask(_ command: String, _ prefix: String) -> String? {
      guard ns.writeText("/dev/scmi/ctl", command + "\n"), let status = ns.readText("/dev/scmi/status") else { return nil }
      let want = Array(prefix.utf8)
      for line in lines(status) where line.starts(with: want) { return String(decoding: line[want.count...], as: UTF8.self) }
      return nil
    }
    let limits = ask("perf \(domain) limits", "perf \(domain) limits ") ?? "refused"
    guard let level = ask("perf \(domain) level", "perf \(domain) level ") else {
      print("gpu-test: ceiling: performance domain \(domain): the agent gives no level (limits: \(limits))")
      return
    }
    print("gpu-test: ceiling: performance domain \(domain): level \(level), limits \(limits)")
    if let v = number(Array(level.utf8), from: 0) { print("budget name=gpu.mali.perf_level value=\(v) unit=level") }
  }

  // MARK: the render rig

  struct Rig {
    var context: CSFContext
    var arena: CSFBuffer
    var colour: CSFBuffer
    var heapContext: CSFBuffer
    var chunk: CSFBuffer
    var images: CSFBuffer
    var texture: CSFBuffer
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
      let arena = try c.createBuffer(size: 2 * imageBytes)
      try c.bind(vm: vm, buffer: arena, size: UInt64(arena.size), address: arenaAddress)
      let heapContext = try c.createBuffer(size: 4096)
      try c.bind(vm: vm, buffer: heapContext, size: UInt64(heapContext.size), address: heapContextAddress)
      let geometry = try c.createBuffer(size: 65536)
      try c.bind(vm: vm, buffer: geometry, size: UInt64(geometry.size), address: geometryAddress)
      let images = try c.createBuffer(size: TexturedCheck.imagesBytes)
      try c.bind(vm: vm, buffer: images, size: UInt64(images.size), address: imagesAddress)
      let chunk = try c.createBuffer(size: Int(chunkBytes))
      try c.bind(vm: vm, buffer: chunk, size: UInt64(chunk.size), address: chunkAddress)
      let colour = try c.createBuffer(size: frameBytes)
      try c.bind(vm: vm, buffer: colour, size: UInt64(colour.size), address: colourAddress)
      let texture = try c.createBuffer(size: frameBytes)
      try c.bind(vm: vm, buffer: texture, size: UInt64(texture.size), address: textureAddress)
      let info = c.info
      guard let thread = c.limits else {
        print("gpu-test: ceiling: the driver reports no thread limits")
        return nil
      }
      let limits = ComputeLimits(
        maxThreads: thread.maxThreads, maxWorkgroupSize: thread.maxWorkgroupSize, threadFeatures: thread.threadFeatures,
        shaderPresent: info.shaderPresent)
      guard limits.isUsable else {
        print("gpu-test: ceiling: the thread limits are unusable")
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
        context: c, arena: arena, colour: colour, heapContext: heapContext, chunk: chunk, images: images, texture: texture,
        group: group, sync: sync,
        registers: CSRegisterMap(workRegisters: Int(info.workRegisters), unpreserved: Int(info.unpreservedRegisters)),
        scoreboards: CSScoreboards(count: Int(info.scoreboards)), arch: Int(info.gpuID >> 28), limits: limits,
        threadStorage: tls)
    } catch {
      print("gpu-test: ceiling: context: \(error)")
      return nil
    }
  }

  /// The pixels the check reads: the corners and the middle.
  static let samples: [(x: Int, y: Int)] = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1), (width / 2, height / 2)]

  /// The opaque texel at sample `i`; a pass that copies the texture leaves it in the target.
  static func texel(_ i: Int) -> UInt32 { 0xFF00_0000 | UInt32(0x30 + 0x30 * i) << 16 | UInt32(0x90 - 0x10 * i) << 8 | UInt32(0x20 + 0x11 * i) }

  /// The heap (the texture twice and a nearest sampler), its plane and the parameter blocks, into the images buffer, and the
  /// samples' texels into the texture; the target's samples set to the poison word. nil, with the reason, when a descriptor is
  /// refused.
  static func upload(_ rig: Rig) -> String? {
    let layout = ImageLayout(format: .bgra8, kind: .linear, width: width, height: height)
    guard layout.size <= frameBytes else { return "the texture's layout is \(layout.size) bytes, not \(frameBytes)" }
    var heap = DescriptorHeap()
    do throws(DescriptorError) {
      let plane = layout.planes(base: textureAddress)[0]
      for (i, w) in try plane.words().enumerated() { rig.images.store(w, at: TexturedCheck.planesAOffset + 4 * i) }
      let texture = TextureDescriptor(image: layout, surfaces: imagesAddress + UInt64(TexturedCheck.planesAOffset))
      for _ in 0..<2 { heap.add(try texture.words()) }
      let index = heap.add(try SamplerWords.nearest.words())
      if index != TexturedCheck.samplerIndex { return "the sampler's entry \(index) is not \(TexturedCheck.samplerIndex)" }
    } catch {
      return "a descriptor was refused: \(error)"
    }
    for (i, w) in heap.words.enumerated() { rig.images.store(w, at: TexturedCheck.heapOffset + 4 * i) }
    // The vertex shader's parameter block: texture index 0.
    for i in 0..<16 { rig.images.store(UInt32(0), at: TexturedCheck.paramsAOffset + 4 * i) }
    // Three equal clip positions: a triangle with no area, which the tiler drops.
    let point: [Float] = [-1, -1, 0, 1]
    for k in 0..<3 {
      for (i, v) in point.enumerated() { rig.images.store(v.bitPattern, at: TexturedCheck.positionsOffset + 16 * k + 4 * i) }
    }
    for (n, p) in samples.enumerated() {
      rig.texture.store(texel(n), at: layout.texelOffset(x: p.x, y: p.y))
      rig.colour.store(poison, at: 4 * (width * p.y + p.x))
    }
    var i = 0
    while i < 64 {
      rig.heapContext.store(UInt64(0), at: i)
      rig.chunk.store(UInt64(0), at: i)
      i += 8
    }
    return nil
  }

  static func request(
    _ layout: RenderQueueLayout, initialise: Bool, draws: [PassDraw], sampled: Bool, rig: Rig
  ) -> DrawPassRequest {
    DrawPassRequest(
      width: width, height: height, format: .bgra8, colourAddress: colourAddress, clear: clearColour, draws: draws,
      heapAddress: sampled ? imagesAddress + UInt64(TexturedCheck.heapOffset) : nil,
      heapBytes: sampled ? TexturedCheck.heapEntries * DescriptorHeap.descriptorBytes : 0, heapContext: heapContextAddress,
      heapChunk: chunkAddress, heapChunkBytes: chunkBytes, geometryBuffer: geometryAddress, layout: layout,
      initialiseQueues: initialise, threadStorage: rig.threadStorage, limits: rig.limits)
  }

  static func median(_ times: [Int64]) -> Int64 {
    var t = times
    t.sort()
    return t[t.count / 2]
  }

  /// GB/s times 10 of `bytes` moved in `micros`.
  static func gbpsX10(_ bytes: Int, _ micros: Int64) -> Int64 { micros > 0 ? Int64(bytes) * 10 / (micros * 1000) : 0 }

  static func gbps(_ x10: Int64) -> String { "\(x10 / 10).\(x10 % 10)" }

  /// One render probe: `draws` over the target, in a context of its own. `bytes` is what the pass moves at least.
  /// `expect` says what a sample pixel should read, or nil where only a written pixel is judged.
  static func probe(
    _ name: String, budget: String, layout: RenderQueueLayout, set: CeilingSet, draws: (CeilingSet) -> [PassDraw], sampled: Bool,
    bytes: Int, what: String, expected: ((Int) -> UInt32)?
  ) {
    guard set.vertex != nil, set.fragment != nil else {
      print("gpu-test: ceiling: \(name): skipped, the shaders were not compiled")
      return
    }
    let list = draws(set)
    var stack: UInt32 = 0
    for d in list { stack = max(stack, d.vertexShader.stackBytes, d.fragmentShader.stackBytes) }
    guard let rig = makeRig(queues: layout == .splitQueues ? 2 : 1, stackBytes: stack) else {
      print("gpu-test: ceiling: \(name): skipped, no context")
      return
    }
    if let why = upload(rig) {
      print("gpu-test: ceiling: \(name): skipped, \(why)")
      return
    }
    let first: RenderPassImage
    let steady: RenderPassImage
    do throws(RenderError) {
      first = try RenderPass.build(
        at: arenaAddress, capacity: imageBytes, request: request(layout, initialise: true, draws: list, sampled: sampled, rig: rig),
        registers: rig.registers, scoreboards: rig.scoreboards, arch: rig.arch).image
      steady = try RenderPass.build(
        at: steadyAddress, capacity: imageBytes, request: request(layout, initialise: false, draws: list, sampled: sampled, rig: rig),
        registers: rig.registers, scoreboards: rig.scoreboards, arch: rig.arch).image
    } catch {
      print("gpu-test: ceiling: \(name): skipped, the recipe: \(error)")
      return
    }
    TriangleCheck.put(first, into: rig.arena, at: 0)
    TriangleCheck.put(steady, into: rig.arena, at: Int(steadyAddress - arenaAddress))
    var why = ""
    // The warm-up: the first stream, which also sets the queues up.
    guard let warm = timed(rig, first, value: 1, why: &why) else {
      print("gpu-test: ceiling: \(name): the pass didn't finish: \(why)")
      return
    }
    var written = 0
    var right = 0
    var firstWord: UInt32 = 0
    for (n, p) in samples.enumerated() {
      let w = rig.colour.load(UInt32.self, at: 4 * (width * p.y + p.x))
      if n == 0 { firstWord = w }
      if w != poison { written += 1 }
      if let expected, w == expected(n) { right += 1 }
    }
    var times: [Int64] = []
    for i in 0..<5 {
      TriangleCheck.put(steady, into: rig.arena, at: Int(steadyAddress - arenaAddress))
      guard let t = timed(rig, steady, value: UInt64(i + 2), why: &why) else {
        print("gpu-test: ceiling: \(name): repeat \(i + 1) didn't finish: \(why)")
        return
      }
      times.append(t)
    }
    let m = median(times)
    var sorted = times
    sorted.sort()
    let rate = gbpsX10(bytes, m)
    var judged = "\(written) of \(samples.count) sample pixels written"
    if expected != nil { judged += ", \(right) as the texture's" }
    print("gpu-test: ceiling: \(name): \(m) us (warm-up \(warm), timed \(sorted[0])...\(sorted[4])), \(what) \(bytes) bytes,"
      + " \(gbps(rate)) GB/s; \(judged); first sample reads 0x\(String(firstWord, radix: 16))")
    if written == 0 {
      print("gpu-test: ceiling: \(name): no pixel was written: the time is not the write-back's; \(budget) is not reported")
      return
    }
    print("budget name=\(budget) value=\(m) unit=us")
  }

  /// The time of a pass in microseconds, submit to the counter's rise; nil, with the reason, if it doesn't finish.
  static func timed(_ rig: Rig, _ image: RenderPassImage, value: UInt64, why: inout String) -> Int64? {
    let start = Clock.monotonic()
    do throws(CSFClientError) {
      try rig.context.submit(group: rig.group, jobs: TriangleCheck.jobs(image), signals: [(rig.sync, value)])
    } catch {
      why = "submit: \(error)"
      return nil
    }
    guard rig.context.wait(sync: rig.sync, value: value, timeoutNanoseconds: 8_000_000_000) else {
      why = "no sync within 8 s"
      if let s = try? rig.context.groupState(rig.group) { why += " (group state \(s.state), fatal queues \(s.fatalQueues))" }
      return nil
    }
    return (Clock.monotonic() - start) / 1000
  }

  // MARK: the passes

  static func clearDraw(_ set: CeilingSet) -> [PassDraw] {
    let table = imagesAddress + UInt64(TexturedCheck.positionsOffset)
    return [
      PassDraw(
        vertexShader: set.vertex!, fragmentShader: set.fragment!, vertexCount: 3,
        push: [UInt32(truncatingIfNeeded: table), UInt32(truncatingIfNeeded: table >> 32)],
        blend: BlendDescriptor(renderTarget: 0))
    ]
  }

  static func run(textured: TexturedCheck.Compiled?, layout: RenderQueueLayout?, set: CeilingSet, ns: Namespace) {
    reportClock(ns)
    guard let layout else {
      print("gpu-test: ceiling: no render layout drew a triangle: the render probes are skipped")
      return
    }
    probe(
      "clear 3840x2160 bgra8", budget: "gpu.mali.clear_4k_us", layout: layout, set: set, draws: clearDraw, sampled: false,
      bytes: frameBytes, what: "written", expected: nil)
    guard let shaders = textured else {
      print("gpu-test: ceiling: the textured quad's shaders were not compiled: the copy and blend probes are skipped")
      runCompute(set)
      return
    }
    let root = imagesAddress + UInt64(TexturedCheck.paramsAOffset)
    let push = [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)]
    func quad(_ blend: BlendDescriptor) -> PassDraw {
      PassDraw(
        vertexShader: shaders.vertex, fragmentShader: shaders.fragment, vertexCount: 6, push: push, blend: blend,
        images: [
          BindingHandle(set: 0, binding: 0, handle: DescriptorHeap.handle(index: 0)),
          BindingHandle(set: 0, binding: 1, handle: DescriptorHeap.handle(index: TexturedCheck.samplerIndex)),
        ])
    }
    let texturedSet = CeilingSet(vertex: shaders.vertex, fragment: shaders.fragment, copy: set.copy)
    probe(
      "copy 3840x2160 bgra8, one texel a pixel", budget: "gpu.mali.copy_4k_us", layout: layout, set: texturedSet,
      draws: { _ in [quad(BlendDescriptor(renderTarget: 0))] }, sampled: true, bytes: 2 * frameBytes, what: "read and written",
      expected: { texel($0) })
    do throws(BlendRefusal) {
      let alpha = try BlendDescriptor(state: BlendState(enabled: true, equation: .alpha))
      probe(
        "blend 3840x2160 bgra8, two layers", budget: "gpu.mali.blend_4k_us", layout: layout, set: texturedSet,
        draws: { _ in [quad(BlendDescriptor(renderTarget: 0)), quad(alpha)] }, sampled: true, bytes: 3 * frameBytes,
        what: "read twice and written", expected: { texel($0) })
    } catch {
      print("gpu-test: ceiling: blend: the blend state needs a blend shader: skipped")
    }
    runCompute(set)
  }

  // MARK: memory bandwidth

  static let copyBytes = 64 << 20
  static let copyWorkgroups: UInt32 = 1024
  static let sourceAddress: UInt64 = 0x400_0000
  static let destinationAddress: UInt64 = 0x800_0000

  /// A 64 MiB buffer copied to another, in vec4s, by `copyWorkgroups` workgroups of 64: the median of five dispatches after
  /// one more, the destination checked against the source at a few words.
  static func runCompute(_ set: CeilingSet) {
    guard let shader = set.copy else {
      print("gpu-test: ceiling: the copy shader was not compiled: gpu.mali.dram_gbps_x10 is not reported")
      return
    }
    let context: CSFContext
    let group: UInt32
    let sync: UInt32
    let arena: CSFBuffer
    let source: CSFBuffer
    let destination: CSFBuffer
    let limits: ComputeLimits
    do throws(CSFClientError) {
      context = try CSFContext()
      let info = context.info
      guard let thread = context.limits else {
        print("gpu-test: ceiling: the driver reports no thread limits: gpu.mali.dram_gbps_x10 is not reported")
        return
      }
      limits = ComputeLimits(
        maxThreads: thread.maxThreads, maxWorkgroupSize: thread.maxWorkgroupSize, threadFeatures: thread.threadFeatures,
        shaderPresent: info.shaderPresent)
      guard limits.isUsable else {
        print("gpu-test: ceiling: the thread limits are unusable: gpu.mali.dram_gbps_x10 is not reported")
        return
      }
      let vm = try context.createVM().id
      arena = try context.createBuffer(size: 16384)
      try context.bind(vm: vm, buffer: arena, size: UInt64(arena.size), address: GPUTest.blockAddress)
      source = try context.createBuffer(size: copyBytes)
      try context.bind(vm: vm, buffer: source, size: UInt64(source.size), address: sourceAddress)
      destination = try context.createBuffer(size: copyBytes)
      try context.bind(vm: vm, buffer: destination, size: UInt64(destination.size), address: destinationAddress)
      group = try context.createGroup(vm: vm, ringSizes: [4096])
      sync = try context.createSync()
    } catch {
      print("gpu-test: ceiling: copy context: \(error): gpu.mali.dram_gbps_x10 is not reported")
      return
    }
    // A few words of known content to carry across; the rest is whatever the pages hold.
    let probes = [0, 1, 4095, 65536, 1_000_003, copyBytes / 4 - 1]
    for (n, w) in probes.enumerated() {
      source.store(UInt32(0x1000_0000 + n * 0x0101_0101), at: 4 * w)
      destination.store(poison, at: 4 * w)
    }
    let info = context.info
    let registers = CSRegisterMap(workRegisters: Int(info.workRegisters), unpreserved: Int(info.unpreservedRegisters))
    let scoreboards = CSScoreboards(count: Int(info.scoreboards))
    let grid = Dim3(copyWorkgroups)
    let count = UInt32(copyBytes / 16)
    let stride = copyWorkgroups * 64
    let fau = shader.layout.block(
      address: { _, binding in binding == 0 ? sourceAddress : destinationAddress },
      size: { _, _ in UInt32(copyBytes) }, push: [count, stride], workgroups: (grid.x, grid.y, grid.z))
    let first = ComputeDispatchRequest(shader: shader.shader, grid: grid, fau: fau, limits: limits)
    let steady = ComputeDispatchRequest(
      shader: shader.shader, grid: grid, fau: fau, limits: limits, requestComputeResource: false, initialiseQueue: false)
    let firstImage: ComputeDispatchImage
    let steadyImage: ComputeDispatchImage
    do throws(DispatchError) {
      firstImage = try ComputeDispatch.build(
        at: GPUTest.blockAddress, capacity: 8192, request: first, registers: registers, scoreboards: scoreboards,
        arch: Int(info.gpuID >> 28))
      steadyImage = try ComputeDispatch.build(
        at: GPUTest.blockAddress + 8192, capacity: 8192, request: steady, registers: registers, scoreboards: scoreboards,
        arch: Int(info.gpuID >> 28))
    } catch {
      print("gpu-test: ceiling: copy dispatch: \(error): gpu.mali.dram_gbps_x10 is not reported")
      return
    }
    GPUTest.put(firstImage, into: arena, at: 0)
    GPUTest.put(steadyImage, into: arena, at: 8192)
    let rig = GPUTest.CSContextRig(context: context, arena: arena, output: destination, group: group, sync: sync)
    let warmStart = Clock.monotonic()
    GPUTest.submit(rig, firstImage, value: 1, what: "the copy")
    let warm = GPUTest.micros(Clock.monotonic() - warmStart)
    var right = 0
    for (n, w) in probes.enumerated() where destination.load(UInt32.self, at: 4 * w) == UInt32(0x1000_0000 + n * 0x0101_0101) {
      right += 1
    }
    var times: [Int64] = []
    for i in 0..<5 {
      let start = Clock.monotonic()
      GPUTest.submit(rig, steadyImage, value: UInt64(i + 2), what: "the copy")
      times.append(GPUTest.micros(Clock.monotonic() - start))
    }
    let m = median(times)
    var sorted = times
    sorted.sort()
    let moved = 2 * copyBytes
    let x10 = gbpsX10(moved, m)
    print("gpu-test: ceiling: copy of \(copyBytes) bytes in vec4s, \(copyWorkgroups) workgroups of 64: \(m) us (warm-up \(warm),"
      + " timed \(sorted[0])...\(sorted[4])), \(moved) bytes read and written, \(gbps(x10)) GB/s; \(right) of \(probes.count) probe words copied")
    if right != probes.count {
      print("gpu-test: ceiling: the copy is wrong: gpu.mali.dram_gbps_x10 is not reported")
      return
    }
    print("budget name=gpu.mali.dram_gbps_x10 value=\(x10) unit=GB/s_x10")
  }
}
