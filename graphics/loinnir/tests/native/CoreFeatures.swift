// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's checks of the core's features on the Mali backend (D174 section 5; gpucore(2)): indexed draws, indirect
// draws and dispatches, and queries, each judged exactly against what the CPU says the image or the memory holds. They
// are the core's own commands (graphics/core), not Loinnir's, on the device of the GPU offered; on another backend
// (Venus's Vulkan) they are not run: boot-venus has its own judges. A feature the device does not report is said to be
// skipped, never counted as passed.
//
// Every shape here is axis-aligned on pixel boundaries over a 64 x 64 target, so a rectangle covers exactly the pixels
// inside it (a pixel whose centre lies on a shared diagonal belongs to one of the two triangles by the top-left rule) and
// a draw's samples are exactly its pixels.

import GPUCore
import GPUCoreMali
import Loinnir
import Sys

final class CoreChecks {
  let gpu: any GPUDevice
  var signalled: UInt64 = 0
  var failed = 0
  let target: GPUImage
  let readback: GPUMemory
  let pipeline: GPUPipeline
  let fill: GPUPipeline?
  let arguments: GPUPipeline?
  let storeShader: GPUPipeline?
  let invertShader: GPUPipeline?
  static let size = 64
  static let clear: [UInt8] = [0, 0, 255, 255]
  static let red: [UInt8] = [255, 0, 0, 255]
  static let green: [UInt8] = [0, 255, 0, 255]

  /// A rectangle of the target, in pixels, and the colour it is drawn in.
  struct Rect {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var colour: [UInt8]
    var pixels: Int { (x1 - x0) * (y1 - y0) }
  }

  func failure(_ what: String) -> GPUError { .invalid("check failed: " + what) }

  init(_ gpu: any GPUDevice) throws(GPUError) {
    self.gpu = gpu
    target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: Int32(Self.size), height: Int32(Self.size),
                                               usage: .renderTarget | .copySource))
    readback = try gpu.allocate(.readback, bytes: Self.size * Self.size * 4)
    pipeline = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: LoinnirShaders.triangleVert, fragment: LoinnirShaders.triangleFrag, colorFormats: [.rgba8], blend: .opaque))
    let features = gpu.limits.features
    var fill: GPUPipeline?
    var arguments: GPUPipeline?
    if features.indirectDispatch { fill = try gpu.makeComputePipeline(spirv: LoinnirShaders.fillComp) }
    if features.indirectDispatch || features.indirectDraw {
      arguments = try gpu.makeComputePipeline(spirv: LoinnirShaders.argsComp)
    }
    self.fill = fill
    self.arguments = arguments
    var store: GPUPipeline?
    var invert: GPUPipeline?
    if features.storageImages {
      store = try gpu.makeComputePipeline(spirv: LoinnirShaders.storeComp)
      invert = try gpu.makeComputePipeline(spirv: LoinnirShaders.invertComp)
    }
    storeShader = store
    invertShader = invert
  }

  func run(_ list: GPUCommandList) throws(GPUError) {
    signalled += 1
    try gpu.run(list, signal: signalled)
  }

  // MARK: Memory

  func upload(_ bytes: Int) throws(GPUError) -> GPUMemory {
    let m = try gpu.allocate(.upload, bytes: bytes)
    unsafe m.pointer!.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    return m
  }

  func put32(_ m: GPUMemory, _ words: [UInt32], at offset: Int = 0) {
    for (i, w) in words.enumerated() { unsafe m.pointer!.storeBytes(of: w, toByteOffset: offset + i * 4, as: UInt32.self) }
  }

  func put16(_ m: GPUMemory, _ values: [UInt16], at offset: Int = 0) {
    for (i, v) in values.enumerated() { unsafe m.pointer!.storeBytes(of: v, toByteOffset: offset + i * 2, as: UInt16.self) }
  }

  func word(_ m: GPUMemory, _ i: Int) -> UInt32 { unsafe m.pointer!.load(fromByteOffset: i * 4, as: UInt32.self) }

  /// A vertex of triangle.vert: position at 0, colour at 16; 32 bytes.
  func vertices(_ list: [(x: Float, y: Float, colour: [Float])]) throws(GPUError) -> GPUMemory {
    let m = try upload(max(list.count, 1) * 32)
    for (i, v) in list.enumerated() {
      let f = unsafe m.pointer!.advanced(by: i * 32).assumingMemoryBound(to: Float.self)
      unsafe f[0] = v.x
      unsafe f[1] = v.y
      for c in 0..<4 { unsafe f[4 + c] = v.colour[c] }
    }
    return m
  }

  /// The four corners of `r` (top left, top right, bottom left, bottom right) as vertices of one colour.
  func corners(_ r: Rect) -> [(x: Float, y: Float, colour: [Float])] {
    let c = r.colour.map { Float($0) / 255 }
    func ndc(_ p: Int) -> Float { Float(p) / 32 - 1 }
    return [(ndc(r.x0), ndc(r.y0), c), (ndc(r.x1), ndc(r.y0), c), (ndc(r.x0), ndc(r.y1), c), (ndc(r.x1), ndc(r.y1), c)]
  }

  static let quadIndices: [UInt32] = [0, 1, 2, 1, 3, 2]

  // MARK: Passes and judging

  func info() -> RenderingInfo { RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))]) }

  /// The pixels the rectangles say, in order (a later one over an earlier), over the clear colour.
  func reference(_ rects: [Rect]) -> [UInt8] {
    var out: [UInt8] = []
    for y in 0..<Self.size {
      for x in 0..<Self.size {
        var p = Self.clear
        for r in rects where x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1 { p = r.colour }
        out += p
      }
    }
    return out
  }

  /// The target's pixels as read back after the list that ended in a copy to `readback`.
  func pixels() -> [UInt8] {
    let p = unsafe readback.pointer!.assumingMemoryBound(to: UInt8.self)
    var out: [UInt8] = []
    out.reserveCapacity(Self.size * Self.size * 4)
    for i in 0..<(Self.size * Self.size * 4) { out.append(unsafe p[i]) }
    return out
  }

  /// A failure message when `got` differs from `want`: how many pixels, and the first.
  func difference(_ got: [UInt8], _ want: [UInt8]) -> String? {
    var wrong = 0
    var first = ""
    for i in 0..<(Self.size * Self.size) where Array(got[i * 4..<i * 4 + 4]) != Array(want[i * 4..<i * 4 + 4]) {
      wrong += 1
      if first.isEmpty {
        first = "(\(i % Self.size), \(i / Self.size)) is \(got[i * 4]),\(got[i * 4 + 1]),\(got[i * 4 + 2]),\(got[i * 4 + 3])"
          + " and should be \(want[i * 4]),\(want[i * 4 + 1]),\(want[i * 4 + 2]),\(want[i * 4 + 3])"
      }
    }
    return wrong == 0 ? nil : "\(wrong) pixels differ, the first \(first)"
  }

  /// Runs `body` as one pass, copies the target out and judges it against `want`.
  func judge(_ name: String, _ want: [Rect], _ body: (inout GPUCommandList) -> Void) throws(GPUError) {
    var list = GPUCommandList()
    list.render(info(), body)
    list.copy(target, to: readback)
    try run(list)
    if let d = difference(pixels(), reference(want)) { throw failure("\(name): \(d)") }
  }

  /// The pass alone, `count` times: the median of the submit-to-done times in microseconds.
  func time(_ body: (inout GPUCommandList) -> Void, setup: GPUCommandList? = nil, count: Int = 7) throws(GPUError) -> Int64 {
    var times: [Int64] = []
    for _ in 0..<count {
      var list = setup ?? GPUCommandList()
      list.render(info(), body)
      let start = Clock.monotonic()
      try run(list)
      times.append((Clock.monotonic() - start) / 1000)
    }
    times.sort()
    return times[times.count / 2]
  }

  // MARK: The checks

  /// Runs one feature's checks: a failure is said and counted, and the others still run, so one run of the board judges
  /// them all; the program fails if any did.
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
      print("loinnir-test: FEATURE FAILED: \(name): \(why)")
    }
  }

  func all() throws(GPUError) {
    let f = gpu.limits.features
    print("loinnir-test: core features: indexed \(f.indexedDraw), indirect draw \(f.indirectDraw), indirect dispatch"
      + " \(f.indirectDispatch), occlusion \(f.occlusionQueries), timestamps \(f.timestampQueries), loads \(f.loadAttachments)")
    if f.multipleDrawsPerPass {
      attempt("first vertex") { () throws(GPUError) in try firstVertex() }
    } else {
      print("loinnir-test: skipped: first vertex (one draw a pass)")
    }
    if f.indexedDraw && f.multipleDrawsPerPass {
      attempt("indexed draws") { () throws(GPUError) in try indexed() }
    } else {
      print("loinnir-test: skipped: indexed draws")
    }
    if f.loadAttachments && f.indexedDraw {
      attempt("loaded attachments") { () throws(GPUError) in try loads() }
    } else {
      print("loinnir-test: skipped: loaded attachments")
    }
    if f.multipleDrawsPerPass && f.indexedDraw {
      attempt("occlusion predicate probe") { () throws(GPUError) in try occlusion() }
    }
    if !f.occlusionQueries { print("loinnir-test: skipped: occlusion count checks (the core doesn't report occlusion queries)") }
    if f.indirectDraw && f.multipleDrawsPerPass {
      attempt("indirect draws") { () throws(GPUError) in try indirectDraws() }
    } else {
      print("loinnir-test: skipped: indirect draws")
    }
    if f.indirectDispatch {
      attempt("indirect dispatch") { () throws(GPUError) in try indirectDispatch() }
    } else {
      print("loinnir-test: skipped: indirect dispatch")
    }
    if f.storageImages {
      attempt("storage images") { () throws(GPUError) in try storage() }
    } else {
      print("loinnir-test: skipped: storage images")
    }
    attempt("atomics on a storage buffer") { () throws(GPUError) in try bufferAtomics() }
    // Texel buffers, where the device has them.
    let tb = gpu.limits.features
    if tb.uniformTexelBuffers && tb.storageTexelBuffers {
      attempt("texel buffers") { () throws(GPUError) in try texelBuffers() }
      attempt("texel buffer order") { () throws(GPUError) in try texelOrder() }
    } else {
      print("loinnir-test: skipped: texel buffers")
    }
    if f.timestampQueries {
      attempt("timestamp queries") { () throws(GPUError) in try timestamps() }
    } else {
      print("loinnir-test: skipped: timestamp queries")
    }
    if failed != 0 { throw .invalid("\(failed) of the core's features failed") }
  }

  /// Atomics on ordinary memory (allocate(.device), which the GPU maps cacheable): 16384 invocations each add 1 to a counter, add
  /// their index to a sum and take the maximum of their index, exactly.
  func bufferAtomics() throws(GPUError) {
    // Atomics need memory the GPU maps cacheable: all memory made from here is. The two ways the stream's end maintains the GPU's
    // caches are tried, each reported: cleaning only, and cleaning and invalidating (which the next stream reading what the CPU
    // wrote in between needs).
    let mali = gpu as? MaliDevice
    defer { mali?.probeCacheMaintenance(false) }
    let shader = try gpu.makeComputePipeline(spirv: LoinnirShaders.atomicsComp)
    let n: UInt32 = 256 * 64
    let want = [n, n * (n - 1) / 2, n - 1]
    var worked = 0
    for invalidating in [true, false] {
      mali?.probeCacheMaintenance(true, invalidating: invalidating)
      let target = try upload(4096)
      let root = try upload(16)
      put32(root, [UInt32(truncatingIfNeeded: target.address), UInt32(truncatingIfNeeded: target.address >> 32)])
      var list = GPUCommandList()
      list.dispatch(shader, root: root.address, x: 256)
      try run(list)
      let got = [word(target, 0), word(target, 1), word(target, 2)]
      let name = invalidating ? "clean and invalidate" : "clean"
      if got != want {
        print("loinnir-test: atomics with \(name): read \(got[0]), \(got[1]), \(got[2]), expected \(want[0]), \(want[1]), \(want[2])")
        continue
      }
      // And again, onto what the CPU has just written over the GPU's result: nothing stale is read from the GPU's caches.
      put32(target, [100, 0, 0])
      try run(list)
      let again = [word(target, 0), word(target, 1), word(target, 2)]
      if again != [100 + n, n * (n - 1) / 2, n - 1] {
        print("loinnir-test: atomics with \(name), after a CPU write: read \(again[0]), \(again[1]), \(again[2])")
        continue
      }
      print("loinnir-test: core feature ok: atomics on an ordinary storage buffer with \(name): \(n) invocations twice, counter, sum and maximum exact")
      worked += 1
      if gpu.limits.features.fillBuffer {
        // Device memory the CPU never maps: filled, added to, and copied out by the GPU's own passes.
        let device = try gpu.allocate(.device, bytes: 4096)
        let out = try gpu.allocate(.readback, bytes: 4096)
        put32(root, [UInt32(truncatingIfNeeded: device.address), UInt32(truncatingIfNeeded: device.address >> 32)])
        var l = GPUCommandList()
        l.fill(device, bytes: 16, value: 0)
        l.barrier(from: .transfer, to: .compute)
        l.dispatch(shader, root: root.address, x: 256)
        l.barrier(from: .compute, to: .transfer)
        l.copy(device, to: out, bytes: 16)
        try run(l)
        let g = [word(out, 0), word(out, 1), word(out, 2)]
        if g != want {
          throw failure("atomics on device memory read \(g[0]), \(g[1]), \(g[2]), expected \(want[0]), \(want[1]), \(want[2])")
        }
        print("loinnir-test: core feature ok: atomics on device memory with \(name) (filled, added to and copied out by the GPU), exact")
      }
    }
    if worked == 0 { throw failure("atomics on a storage buffer: neither way of maintaining the caches gave the sums") }
  }

  /// A pass that keeps the target: what an earlier pass drew is under what this one draws, the tile loaded from memory.
  func loads() throws(GPUError) {
    let a = Rect(x0: 16, y0: 16, x1: 48, y1: 40, colour: Self.red)
    let b = Rect(x0: 4, y0: 44, x1: 60, y1: 60, colour: Self.green)
    let overlap = Rect(x0: 40, y0: 30, x1: 62, y1: 50, colour: [255, 255, 0, 255])
    let va = try vertices(corners(a)), vb = try vertices(corners(b)), vo = try vertices(corners(overlap))
    func keep() -> RenderingInfo { RenderingInfo(colors: [Attachment(image: target, load: .load)]) }
    // The first list clears and draws a; the second keeps it and draws b and then, over both, the overlap.
    let idx = try upload(64)
    put16(idx, Self.quadIndices.map { UInt16($0) })
    var first = GPUCommandList()
    first.render(info()) { l in l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6) }
    var second = GPUCommandList()
    second.render(keep()) { l in l.drawIndexed(pipeline, root: vb.address, indices: idx, indexType: .uint16, count: 6) }
    second.render(keep()) { l in l.drawIndexed(pipeline, root: vo.address, indices: idx, indexType: .uint16, count: 6) }
    second.render(keep()) { _ in }  // draws nothing and keeps everything
    second.copy(target, to: readback)
    try run(first)
    try run(second)
    if let d = difference(pixels(), reference([a, b, overlap])) { throw failure("passes that keep the target's contents: \(d)") }
    // The same in one list, passes of one list seeing each other's pixels.
    var one = GPUCommandList()
    one.append(contentsOf: first)
    one.append(contentsOf: second)
    try run(one)
    if let d = difference(pixels(), reference([a, b, overlap])) { throw failure("passes that keep the target's contents, in one list: \(d)") }
    // A pass that clears does not keep them.
    var cleared = GPUCommandList()
    cleared.render(info()) { l in l.drawIndexed(pipeline, root: vb.address, indices: idx, indexType: .uint16, count: 6) }
    cleared.copy(target, to: readback)
    try run(cleared)
    if let d = difference(pixels(), reference([b])) { throw failure("a pass that clears after passes that keep: \(d)") }
    print("loinnir-test: ok: a pass that keeps the target's contents loads them into each tile (three passes draw over what the last left)")
    var times: [Int64] = []
    for _ in 0..<7 {
      var l = GPUCommandList()
      l.render(keep()) { l in l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6) }
      let start = Clock.monotonic()
      try run(l)
      times.append((Clock.monotonic() - start) / 1000)
    }
    times.sort()
    print("budget name=gpu.mali.core_load_pass_us value=\(times[times.count / 2]) unit=us")
  }

  /// Storage images of the heap: a compute shader writes one, then reads it and writes another; the texels are the CPU's.
  func storage() throws(GPUError) {
    guard let store = storeShader, let invert = invertShader else { return }
    let a = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .storage | .copySource))
    let b = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .storage | .copySource))
    try gpu.writeStorageImage(5, a)
    try gpu.writeStorageImage(9, b)
    let p1 = try upload(64)
    put32(p1, [5])
    let p2 = try upload(64)
    put32(p2, [5, 9])
    var list = GPUCommandList()
    list.dispatch(store, root: p1.address, x: 8, y: 8)
    list.barrier()
    list.copy(a, to: readback)
    try run(list)
    var want: [UInt8] = []
    for y in 0..<Self.size { for x in 0..<Self.size { want += [UInt8(x), UInt8(y), 128, 255] } }
    if let d = difference(pixels(), want) { throw failure("a compute shader's stores to a storage image: \(d)") }
    list = GPUCommandList()
    list.dispatch(invert, root: p2.address, x: 8, y: 8)
    list.barrier()
    list.copy(b, to: readback)
    try run(list)
    want = []
    for y in 0..<Self.size { for x in 0..<Self.size { want += [UInt8(255 - x), UInt8(y), 128, 255] } }
    if let d = difference(pixels(), want) { throw failure("a compute shader's loads and stores of storage images: \(d)") }
    print("loinnir-test: ok: storage images (a compute shader wrote 64 x 64 texels, and read them to write another: exact)")
    var times: [Int64] = []
    for _ in 0..<7 {
      var l = GPUCommandList()
      l.dispatch(store, root: p1.address, x: 8, y: 8)
      let start = Clock.monotonic()
      try run(l)
      times.append((Clock.monotonic() - start) / 1000)
    }
    times.sort()
    print("budget name=gpu.mali.core_storage_dispatch_us value=\(times[times.count / 2]) unit=us")
  }

  /// A draw from a first vertex: the quad's six vertices after two the shader must not read.
  func firstVertex() throws(GPUError) {
    let a = Rect(x0: 16, y0: 16, x1: 48, y1: 40, colour: Self.red)
    let junk: (x: Float, y: Float, colour: [Float]) = (0.9, 0.9, [0, 1, 0, 1])
    let c = corners(a)
    let verts = try vertices([junk, junk] + Self.quadIndices.map { c[Int($0)] })
    try judge("a draw from a first vertex", [a]) { l in
      l.draw(pipeline, root: verts.address, vertices: 6, firstVertex: 2)
    }
    print("loinnir-test: ok: a draw from a first vertex is the same quad")
  }

  func indexed() throws(GPUError) {
    let a = Rect(x0: 16, y0: 16, x1: 48, y1: 40, colour: Self.red)
    let b = Rect(x0: 4, y0: 44, x1: 60, y1: 60, colour: Self.green)
    let va = try vertices(corners(a))
    let idx32 = try upload(256)
    put32(idx32, Self.quadIndices)
    let idx16 = try upload(256)
    put16(idx16, Self.quadIndices.map { UInt16($0) })

    try judge("16-bit indices", [a]) { l in
      l.drawIndexed(pipeline, root: va.address, indices: idx16, indexType: .uint16, count: 6)
    }
    try judge("32-bit indices", [a]) { l in
      l.drawIndexed(pipeline, root: va.address, indices: idx32, indexType: .uint32, count: 6)
    }
    // The first index: indices before it are not drawn (they name a vertex that would paint the wrong colour).
    let withJunk16 = try upload(256)
    put16(withJunk16, [3, 3, 3, 3] + Self.quadIndices.map { UInt16($0) })
    try judge("a first index", [a]) { l in
      l.drawIndexed(pipeline, root: va.address, indices: withJunk16, indexType: .uint16, count: 6, firstIndex: 4)
    }
    let withJunk32 = try upload(256)
    put32(withJunk32, [3, 3, 3] + Self.quadIndices)
    try judge("a first index of 32-bit indices", [a]) { l in
      l.drawIndexed(pipeline, root: va.address, indices: withJunk32, indexType: .uint32, count: 6, firstIndex: 3)
    }
    // The index data's offset in its memory, in bytes.
    let offset = try upload(256)
    put16(offset, [0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF] + Self.quadIndices.map { UInt16($0) })
    try judge("an offset in the index memory", [a]) { l in
      l.drawIndexed(pipeline, root: va.address, indices: offset, indexOffset: 8, indexType: .uint16, count: 6)
    }
    // The vertex offset: the vertices follow five the shader must not read; the indices are relative to the quad's.
    let junk: (x: Float, y: Float, colour: [Float]) = (-0.9, 0.9, [0, 1, 0, 1])
    let shifted = try vertices([junk, junk, junk, junk, junk] + corners(a))
    try judge("a vertex offset", [a]) { l in
      l.drawIndexed(pipeline, root: shifted.address, indices: idx16, indexType: .uint16, count: 6, vertexOffset: 5)
    }
    // A negative one: the indices name vertices 5 to 8 and the offset brings them to 0 to 3.
    let high = try upload(256)
    put16(high, Self.quadIndices.map { UInt16($0 + 5) })
    try judge("a negative vertex offset", [a]) { l in
      l.drawIndexed(pipeline, root: va.address, indices: high, indexType: .uint16, count: 6, vertexOffset: -5)
    }
    // Two draws in a pass, the second from other vertices and a first index and a vertex offset together.
    let vb = try vertices([junk] + corners(b))
    let two = try upload(256)
    put16(two, [0, 0] + Self.quadIndices.map { UInt16($0) })
    try judge("two indexed draws in a pass", [a, b]) { l in
      l.drawIndexed(pipeline, root: va.address, indices: idx32, indexType: .uint32, count: 6)
      l.drawIndexed(pipeline, root: vb.address, indices: two, indexType: .uint16, count: 6, firstIndex: 2, vertexOffset: 1)
    }
    // Indexed is the same image as the non-indexed draw, with a colour of its own at each corner (interpolated).
    let colours: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 0, 1]]
    let c = corners(a)
    var shaded: [(x: Float, y: Float, colour: [Float])] = []
    for i in 0..<4 { shaded.append((c[i].x, c[i].y, colours[i])) }
    let vs = try vertices(shaded)
    let flat = try vertices(Self.quadIndices.map { shaded[Int($0)] })
    var list = GPUCommandList()
    list.render(info()) { l in l.draw(pipeline, root: flat.address, vertices: 6) }
    list.copy(target, to: readback)
    try run(list)
    let direct = pixels()
    var indexed = GPUCommandList()
    indexed.render(info()) { l in l.drawIndexed(pipeline, root: vs.address, indices: idx16, indexType: .uint16, count: 6) }
    indexed.copy(target, to: readback)
    try run(indexed)
    if let d = difference(pixels(), direct) { throw failure("an interpolated quad, indexed against not: \(d)") }
    print("loinnir-test: ok: indexed draws (16 and 32-bit indices, first index, vertex offset, two in a pass) are the quads' pixels")
    let micros = try time({ l in l.drawIndexed(pipeline, root: va.address, indices: idx16, indexType: .uint16, count: 6) })
    print("budget name=gpu.mali.core_indexed_draw_us value=\(micros) unit=us")
  }

  /// The arguments of draws and dispatches, written by the CPU and by the GPU.
  func indirectDraws() throws(GPUError) {
    let a = Rect(x0: 16, y0: 16, x1: 48, y1: 40, colour: Self.red)
    let b = Rect(x0: 4, y0: 44, x1: 60, y1: 60, colour: Self.green)
    let ca = corners(a), cb = corners(b)
    // Twelve vertices: the quad of a then the quad of b, each as six.
    let verts = try vertices(Self.quadIndices.map { ca[Int($0)] } + Self.quadIndices.map { cb[Int($0)] })
    // Two draws, 32 bytes apart (the arguments' own four words, then the gap).
    let args = try upload(256)
    put32(args, [6, 1, 0, 0, 0, 0, 0, 0, 6, 1, 6, 0])
    try judge("two indirect draws", [a, b]) { l in
      l.drawIndirect(pipeline, root: verts.address, arguments: args, drawCount: 2, stride: 32)
    }
    // One of them, from an offset in the memory.
    try judge("an indirect draw from an offset", [b]) { l in
      l.drawIndirect(pipeline, root: verts.address, arguments: args, offset: 32)
    }

    // Indexed, with a first index and a vertex offset in the arguments: the vertices of `b` follow three the shader must
    // not read, and the indices follow four that are not drawn.
    let junk: (x: Float, y: Float, colour: [Float]) = (-0.9, 0.9, [0, 1, 0, 1])
    let shifted = try vertices([junk, junk, junk] + ca + cb)
    let idx = try upload(256)
    put16(idx, [0, 0, 0, 0] + Self.quadIndices.map { UInt16($0) })
    let iargs = try upload(256)
    // indexCount, instanceCount, firstIndex, vertexOffset, firstInstance: the first draw is a, the second is b by +4.
    put32(iargs, [6, 1, 4, 3, 0, 6, 1, 4, 7, 0])
    try judge("two indexed indirect draws", [a, b]) { l in
      l.drawIndexedIndirect(pipeline, root: shifted.address, indices: idx, indexType: .uint16, arguments: iargs, drawCount: 2,
                            stride: 20)
    }

    // Arguments the GPU wrote: a compute dispatch adds one to each word of its parameters (wrapping), and the draw reads
    // what it made. The parameters are (5, 0, 0xFFFFFFFF, 0xFFFFFFFF, ...), the draw's (6, 1, 0, 0).
    guard let writer = arguments else { return }
    let made = try gpu.allocate(.device, bytes: 4096)
    let params = try upload(64)
    unsafe params.pointer!.storeBytes(of: made.address, as: UInt64.self)
    put32(params, [5, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0, 0, 0], at: 8)
    var list = GPUCommandList()
    list.dispatch(writer, root: params.address, x: 1)
    list.barrier()
    list.render(info()) { l in l.drawIndirect(pipeline, root: verts.address, arguments: made) }
    list.copy(target, to: readback)
    try run(list)
    if let d = difference(pixels(), reference([a])) { throw failure("an indirect draw of arguments the GPU wrote: \(d)") }
    print("loinnir-test: ok: indirect draws (two from memory, indexed with a first index and vertex offset, and from arguments"
      + " the GPU wrote) are the quads' pixels")
    // Zero counts the GPU wrote (06 section 6.4.7: the stream branches over the run): parameters of 0xFFFFFFFF come out as
    // 0. A draw of no vertices, one of no instances, and an indexed one of each, between draws that must still be drawn.
    let cb2 = corners(b)
    let zeroVerts = try vertices(Self.quadIndices.map { ca[Int($0)] } + Self.quadIndices.map { cb2[Int($0)] })
    let zeroParams: [(String, [UInt32])] = [
      ("no vertices", [0xFFFF_FFFF, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0, 0, 0]),
      ("no instances", [5, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0, 0, 0]),
    ]
    var made2: [GPUMemory] = []
    var zeroList = GPUCommandList()
    for (_, words) in zeroParams {
      let m = try gpu.allocate(.device, bytes: 4096)
      let p = try upload(64)
      unsafe p.pointer!.storeBytes(of: m.address, as: UInt64.self)
      put32(p, words, at: 8)
      zeroList.dispatch(writer, root: p.address, x: 1)
      made2.append(m)
    }
    zeroList.barrier()
    let firstArgs = try upload(64)
    put32(firstArgs, [6, 1, 0, 0])
    let secondArgs = try upload(64)
    put32(secondArgs, [6, 1, 6, 0])
    zeroList.render(info()) { l in
      l.drawIndirect(pipeline, root: zeroVerts.address, arguments: made2[0])
      l.drawIndirect(pipeline, root: zeroVerts.address, arguments: firstArgs)
      l.drawIndirect(pipeline, root: zeroVerts.address, arguments: made2[1])
      l.drawIndirect(pipeline, root: zeroVerts.address, arguments: secondArgs)
    }
    zeroList.copy(target, to: readback)
    try run(zeroList)
    if let d = difference(pixels(), reference([a, b])) { throw failure("indirect draws of zero counts between two that draw: \(d)") }
    print("loinnir-test: ok: indirect draws of no vertices and of no instances (written by the GPU) draw nothing and the draws"
      + " around them are the quads' pixels")
    let micros = try time({ l in l.drawIndirect(pipeline, root: verts.address, arguments: args) })
    print("budget name=gpu.mali.core_indirect_draw_us value=\(micros) unit=us")
  }

  /// A grid from memory: the workgroups that ran, and the grid the shader saw.
  func indirectDispatch() throws(GPUError) {
    guard let fill = fill else { return }
    func check(_ name: String, _ out: GPUMemory, _ grid: (UInt32, UInt32, UInt32)) throws(GPUError) {
      let groups = Int(grid.0 * grid.1 * grid.2)
      let seen = [word(out, 0), word(out, 1), word(out, 2), word(out, 3)]
      if seen != [grid.0, grid.1, grid.2, 7] { throw failure("\(name): the shader saw the grid \(seen)") }
      for i in 0..<(groups * 4) where word(out, 4 + i) != UInt32(i / 4 + 1) {
        throw failure("\(name): word \(i) is \(word(out, 4 + i)), not \(i / 4 + 1)")
      }
      for i in (groups * 4)..<(groups * 4 + 64) where word(out, 4 + i) != 0 {
        throw failure("\(name): word \(i), past the grid, is \(word(out, 4 + i))")
      }
    }
    // The CPU's arguments, two words in at an offset.
    let out1 = try upload(8192)
    let args = try upload(64)
    put32(args, [99, 99, 3, 2, 2])
    var list = GPUCommandList()
    list.dispatchIndirect(fill, root: out1.address, arguments: args, offset: 8)
    try run(list)
    try check("an indirect dispatch of 3 x 2 x 2", out1, (3, 2, 2))
    // A grid of one workgroup, and a long one.
    let out2 = try upload(8192)
    put32(args, [1, 1, 1, 200, 1, 1])
    list = GPUCommandList()
    list.dispatchIndirect(fill, root: out2.address, arguments: args, offset: 0)
    try run(list)
    try check("an indirect dispatch of one workgroup", out2, (1, 1, 1))
    let out3 = try upload(8192)
    list = GPUCommandList()
    list.dispatchIndirect(fill, root: out3.address, arguments: args, offset: 12)
    try run(list)
    try check("an indirect dispatch of 200 x 1 x 1", out3, (200, 1, 1))

    // Arguments the GPU wrote: the parameters (4, 1, 0xFFFFFFFF + ...) come out as (5, 2, 1).
    guard let writer = arguments else { return }
    let made = try gpu.allocate(.device, bytes: 4096)
    let params = try upload(64)
    unsafe params.pointer!.storeBytes(of: made.address, as: UInt64.self)
    put32(params, [4, 1, 0, 0, 0, 0, 0, 0], at: 8)
    let out4 = try upload(8192)
    list = GPUCommandList()
    list.dispatch(writer, root: params.address, x: 1)
    list.barrier()
    list.dispatchIndirect(fill, root: out4.address, arguments: made)
    try run(list)
    try check("an indirect dispatch of arguments the GPU wrote", out4, (5, 2, 1))
    // A grid with a zero dimension, written by the GPU (06 section 6.4.7): the stream issues no run, the shader never runs, and
    // the dispatch after it does. The parameters come out as (0, 2, 1), (3, 0, 1) and (3, 2, 0).
    let zeroGrids: [[UInt32]] = [[0xFFFF_FFFF, 1, 0, 0, 0, 0, 0, 0], [2, 0xFFFF_FFFF, 0, 0, 0, 0, 0, 0], [2, 1, 0xFFFF_FFFF, 0, 0, 0, 0, 0]]
    var outs: [GPUMemory] = []
    list = GPUCommandList()
    for words in zeroGrids {
      let m = try gpu.allocate(.device, bytes: 4096)
      let p = try upload(64)
      unsafe p.pointer!.storeBytes(of: m.address, as: UInt64.self)
      put32(p, words, at: 8)
      list.dispatch(writer, root: p.address, x: 1)
      list.barrier()
      let out = try upload(8192)
      list.dispatchIndirect(fill, root: out.address, arguments: m)
      outs.append(out)
    }
    let after = try upload(8192)
    put32(args, [1, 1, 1], at: 0)
    list.dispatchIndirect(fill, root: after.address, arguments: args, offset: 0)
    try run(list)
    for (i, out) in outs.enumerated() {
      for w in 0..<2048 where word(out, w) != 0 { throw failure("a dispatch with a zero dimension (grid \(i)): word \(w) is \(word(out, w))") }
    }
    try check("an indirect dispatch after the zero grids", after, (1, 1, 1))
    print("loinnir-test: ok: indirect dispatches with a zero dimension (written by the GPU, each of three axes) ran nothing, and the"
      + " dispatch after them ran its grid")
    print("loinnir-test: ok: indirect dispatch (from memory at an offset, one workgroup, a long grid, and arguments the GPU wrote)"
      + " ran exactly the grid and the shader saw it")
    var times: [Int64] = []
    for _ in 0..<7 {
      list = GPUCommandList()
      list.dispatchIndirect(fill, root: out1.address, arguments: args, offset: 8)
      let start = Clock.monotonic()
      try run(list)
      times.append((Clock.monotonic() - start) / 1000)
    }
    times.sort()
    print("budget name=gpu.mali.core_indirect_dispatch_us value=\(times[times.count / 2]) unit=us")
  }

  /// Occlusion queries (06 section 6.11.1): the counter mode's counts are the samples that passed, judged exactly where the core
  /// reports the queries; then what other choices give (memory the GPU doesn't cache, a different pixel-kill mode, the GPU's own
  /// load of the report), reported; then the predicate mode, judged.
  func occlusion() throws(GPUError) {
    guard let mali = gpu as? MaliDevice else { return }
    let reported = gpu.limits.features.occlusionQueries
    let a = Rect(x0: 16, y0: 16, x1: 48, y1: 40, colour: Self.red)
    let b = Rect(x0: 4, y0: 44, x1: 60, y1: 60, colour: [255, 255, 0, 255])
    let c = Rect(x0: 0, y0: 0, x1: 64, y1: 64, colour: Self.green)
    let outside = Rect(x0: 70, y0: 70, x1: 90, y1: 90, colour: Self.red)
    let va = try vertices(corners(a)), vb = try vertices(corners(b)), vc = try vertices(corners(c))
    let vo = try vertices(corners(outside))
    let idx = try upload(64)
    put16(idx, Self.quadIndices.map { UInt16($0) })
    func sixQueries(_ set: GPUQuerySet) -> GPUCommandList {
      var list = GPUCommandList()
      list.render(info()) { l in
        l.beginQuery(set, index: 4)  // a triangle: half of the target
        l.draw(pipeline, root: vc.address, vertices: 3)
        l.endQuery(set, index: 4)
        l.drawIndexed(pipeline, root: vc.address, indices: idx, indexType: .uint16, count: 6)  // not counted
        l.beginQuery(set, index: 0)
        l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6)
        l.endQuery(set, index: 0)
        l.beginQuery(set, index: 1)
        l.drawIndexed(pipeline, root: vo.address, indices: idx, indexType: .uint16, count: 6)  // off the target: no samples
        l.endQuery(set, index: 1)
        l.beginQuery(set, index: 2)  // two draws
        l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6)
        l.drawIndexed(pipeline, root: vb.address, indices: idx, indexType: .uint16, count: 6)
        l.endQuery(set, index: 2)
        l.beginQuery(set, index: 3)  // none
        l.endQuery(set, index: 3)
      }
      list.copy(target, to: readback)
      return list
    }
    // The counter mode.
    do {
      let set = try gpu.makeQuerySet(.occlusion, count: 6)
      defer { gpu.destroy(set) }
      try run(sixQueries(set))
      let counts = try gpu.results(set, first: 0, count: 6)
      print("loinnir-test: occlusion counter: \(counts[0]), \(counts[1]), \(counts[2]), \(counts[3]), \(counts[4]), \(counts[5]) for a"
        + " rectangle of \(a.pixels) pixels, none, two rectangles of \(a.pixels + b.pixels), an empty query, a triangle and a query never used")
      if reported {
        if counts[0] != UInt64(a.pixels) { throw failure("an occlusion count over a rectangle of \(a.pixels) pixels reads \(counts[0])") }
        if counts[1] != 0 { throw failure("an occlusion count over a draw off the target reads \(counts[1])") }
        if counts[2] != UInt64(a.pixels + b.pixels) { throw failure("an occlusion count over two rectangles reads \(counts[2])") }
        if counts[3] != 0 { throw failure("an occlusion count that enclosed no draw reads \(counts[3])") }
        // The triangle covers half the target; the pixels on its diagonal belong to one of its edges by the top-left rule.
        if counts[4] < 2000 || counts[4] > 2100 { throw failure("an occlusion count over half the target reads \(counts[4])") }
        if counts[5] != 0 { throw failure("a query that was never used reads \(counts[5])") }
        if let d = difference(pixels(), reference([c, a, a, b])) { throw failure("the pixels of a pass with occlusion queries: \(d)") }
        // A second pass counts from zero again, and one query used in two passes counts the last pass's samples.
        try run(sixQueries(set))
        let again = try gpu.results(set, first: 0, count: 6)
        if again[0] != UInt64(a.pixels) || again[2] != UInt64(a.pixels + b.pixels) {
          throw failure("a second pass over the same queries reads \(again[0]) and \(again[2])")
        }
        print("loinnir-test: ok: occlusion queries count the samples that passed (\(counts[0]) of a rectangle of \(a.pixels) pixels, \(counts[2])"
          + " of two, none off the target, \(counts[4]) of half the target), and again in a second pass")
      }
    }
    // What the hardware does with other choices: the counts a rectangle of the same pixels gives, immediately and a while later,
    // and what the GPU itself reads from the report after its flush. Reported, not judged; each list is its own try.
    do {
      let variants: [(name: String, or: UInt32, clear: UInt32)] = [
        ("as made", 0, 0), ("predicate", 0, 1 << 15), ("late kill and update", 0x3C, 0), ("no forward pixel kill", 0, 3),
        ("mode 2", 0, 1 << 14),
      ]
      for v in variants {
        for mode in 0..<3 {
          mali.probeFlags0 = (v.or, v.clear)
          mali.probeQueryReadback = mode == 2
          mali.probeQueryCacheable = mode != 1
          let probe = try gpu.makeQuerySet(.occlusion, count: 2)
          var l = GPUCommandList()
          l.render(info()) { l in
            l.beginQuery(probe, index: 0)
            l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6)
            l.endQuery(probe, index: 0)
          }
          var how = ""
          if mode == 1 { how = ", memory the GPU doesn't cache" }
          if mode == 2 { how = ", with the GPU's own load of the report" }
          do throws(GPUError) {
            try run(l)
            let now = try gpu.results(probe, first: 0, count: 2)
            sleep(until: Clock.monotonic() + 20_000_000)
            let later = try gpu.results(probe, first: 0, count: 2)[0]
            let gpuRead = mode == 2 ? ", the GPU read \(mali.probeReadbackReport ?? 0)" : ""
            print("loinnir-test: occlusion probe: \(v.name)\(how): \(now[0]), \(later) later\(gpuRead), of \(a.pixels) pixels")
          } catch {
            print("loinnir-test: occlusion probe: \(v.name)\(how): the pass failed")
          }
          gpu.destroy(probe)
        }
      }
      mali.probeFlags0 = (0, 0)
      mali.probeQueryReadback = false
      mali.probeQueryCacheable = true
    }
    // The predicate mode (draw flags 0 `[15:14]` 1): any sample passed (non-zero), or none (zero).
    mali.probeFlags0 = (0, 1 << 15)
    defer { mali.probeFlags0 = (0, 0) }
    let set = try gpu.makeQuerySet(.occlusion, count: 6)
    defer { gpu.destroy(set) }
    try run(sixQueries(set))
    let counts = try gpu.results(set, first: 0, count: 6)
    if counts[0] == 0 { throw failure("a predicate query over a rectangle of pixels answered 0") }
    if counts[1] != 0 { throw failure("a predicate query over a draw off the target answered \(counts[1])") }
    if counts[2] == 0 { throw failure("a predicate query over two rectangles answered 0") }
    if counts[3] != 0 { throw failure("a predicate query that enclosed no draw answered \(counts[3])") }
    if counts[4] == 0 { throw failure("a predicate query over a triangle answered 0") }
    if counts[5] != 0 { throw failure("a query that was never used reads \(counts[5])") }
    if let d = difference(pixels(), reference([c, a, a, b])) { throw failure("the pixels of a pass with occlusion queries: \(d)") }
    print("loinnir-test: ok: occlusion predicate queries answer whether any sample passed (\(counts[0]), \(counts[1]), \(counts[2]),"
      + " \(counts[3]), \(counts[4]) for a rectangle, none, two, an empty query and a triangle)")
  }

  /// Timestamps: the period against the CPU's clock, ordering, and what is between them.
  func timestamps() throws(GPUError) {
    let limits = gpu.limits
    let period = limits.timestampPeriodPicoseconds
    if period == 0 { throw failure("timestamp queries are on and the period is 0") }
    print("budget name=gpu.mali.core_timestamp_period_ps value=\(period) unit=ps")
    if let mali = gpu as? MaliDevice {
      // The GPU's counter runs at the CPU's architected counter's frequency (valhall 16 section 16.8.5): the period the device
      // took from CNTFRQ_EL0, against the one measured with the CPU's clock over 40 ms.
      let hertz = mali.counterFrequencyHertz
      let measured = mali.measuredTimestampPeriodPicoseconds() ?? 0
      print("loinnir-test: timestamp period: CNTFRQ_EL0 reads \(hertz) Hz (the device uses \(period) ps), measured against the CPU's"
        + " clock \(measured) ps")
      if hertz == 0 {
        print("loinnir-test: timestamp period: CNTFRQ_EL0 reads 0, so the device measured the period")
      } else if measured == 0 || (measured > period ? measured - period : period - measured) * 100 > period {
        throw failure("the GPU's timestamp counter is not at CNTFRQ_EL0's frequency: \(hertz) Hz is \(period) ps, measured \(measured) ps")
      } else {
        print("loinnir-test: ok: the GPU's timestamp counter runs at CNTFRQ_EL0's frequency (\(hertz) Hz, \(period) ps; measured \(measured) ps)")
      }
    }
    let set = try gpu.makeQuerySet(.timestamp, count: 4)
    defer { gpu.destroy(set) }
    let a = Rect(x0: 16, y0: 16, x1: 48, y1: 40, colour: Self.red)
    let va = try vertices(corners(a))
    let idx = try upload(64)
    put16(idx, Self.quadIndices.map { UInt16($0) })
    // Where the time between two timestamps goes: what is between them, the GPU's microseconds and the CPU's for the list.
    func between(_ what: String, _ body: (inout GPUCommandList) -> Void) throws(GPUError) {
      var l = GPUCommandList()
      l.writeTimestamp(set, index: 0)
      body(&l)
      l.writeTimestamp(set, index: 1)
      let start = Clock.monotonic()
      try run(l)
      let cpu = (Clock.monotonic() - start) / 1000
      let t = try gpu.results(set, first: 0, count: 2)
      print("loinnir-test: timestamps around \(what): \((t[1] &- t[0]) &* period / 1_000_000) us on the GPU, \(cpu) us for the list")
    }
    for _ in 0..<2 {
      try between("nothing") { _ in }
      try between("a barrier") { l in l.barrier() }
      try between("a pass") { l in
        l.render(info()) { l in l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6) }
      }
      try between("a pass and a copy") { l in
        l.render(info()) { l in l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6) }
        l.copy(target, to: readback)
      }
    }
    var list = GPUCommandList()
    list.writeTimestamp(set, index: 0)
    list.render(info()) { l in l.drawIndexed(pipeline, root: va.address, indices: idx, indexType: .uint16, count: 6) }
    list.writeTimestamp(set, index: 1, after: .fragment)
    try run(list)
    // A pause the CPU times, between two lists.
    let before = Clock.monotonic()
    sleep(until: before + 20_000_000)
    list = GPUCommandList()
    list.writeTimestamp(set, index: 2)
    try run(list)
    let after = Clock.monotonic()
    let t = try gpu.results(set, first: 0, count: 4)
    if t[0] == 0 || t[1] <= t[0] || t[2] <= t[1] { throw failure("timestamps are not increasing: \(t[0]), \(t[1]), \(t[2])") }
    if t[3] != 0 { throw failure("a timestamp that was never written reads \(t[3])") }
    // The pass took no more than the CPU saw it take, and the wait is the wait (the period is measured, so a percent or
    // two of it is the measurement's, and the clock's resolution and the submit's latency are the rest).
    let pass = Int64((t[1] - t[0]) * period / 1_000_000)  // microseconds
    let waited = Int64((t[2] - t[1]) * period / 1_000)  // nanoseconds
    let cpu = after - before
    if pass <= 0 || pass > 100_000 { throw failure("a pass between two timestamps is \(pass) us") }
    if waited < 19_000_000 || waited > cpu + 2_000_000 {
      throw failure("20 ms of the CPU's sleep is \(waited / 1000) us between timestamps (the CPU saw \(cpu / 1000) us), period \(period) ps")
    }
    print("loinnir-test: ok: timestamps (period \(period) ps): a pass \(pass) us, a 20 ms sleep \(waited / 1000) us (CPU \(cpu / 1000) us)")
    print("budget name=gpu.mali.core_timestamp_pass_us value=\(pass) unit=us")
  }
}
