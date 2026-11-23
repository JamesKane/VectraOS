// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's cases for the core's full feature set (D174's amendment; gpucore(2)): each draws or copies through
// the device Loinnir opened and judges what it reads back against a CPU reference, exactly where the work is exact
// (pixel-aligned rectangles, nearest sampling, clears, copies) and within a stated tolerance where the hardware rounds
// (blending, an MSAA edge, a linear mip blend). A case needs the features the device reports; one the device lacks is
// skipped, with the reason, and a case that fails ends the run. Where the device refuses a command its flags
// promised, the case is skipped with the device's words, which the log shows.

import GPUCore
import Sys

final class CoreCases {
  let d: any GPUDevice
  let f: DeviceFeatures
  var timeline: UInt64 = 0
  var passed = 0
  var skipped = 0
  /// Checks of the resource cases that failed: they go on, so one run shows every failure (`bad`), and the run ends in one.
  var softFailures = 0
  /// Checks of features the device does not claim yet (separate filters, import): their failures are said, not counted.
  var probing = false
  /// Lines printed again at the end of the resource cases (the serial console of the board drops some).
  var notes: [String] = []
  /// What a probe found, for one line at the end.
  var probeSummary = ""
  var softKeys: [[UInt8]] = []
  var softCounts: [Int] = []
  /// The heap slots the cases use, from here up (Loinnir's own table uses the first of the sampler slots and none of these).
  let textureBase: UInt32 = 100

  init(_ device: any GPUDevice) {
    d = device
    f = device.limits.features
  }

  // MARK: Reporting

  func fail(_ what: String) -> Never {
    print("loinnir-test: FAILED: core: \(what)")
    Process.exit(code: 1)
  }

  func ok(_ what: String) {
    passed += 1
    print("loinnir-test: ok: core: \(what)")
    if reprinted(what) { notes.append("loinnir-test: ok: core: \(what)") }
  }

  func skip(_ what: String, _ why: String) {
    skipped += 1
    print("loinnir-test: skip: core: \(what): \(why)")
    notes.append("loinnir-test: skip: core: \(what): \(why)")
  }

  /// The cases whose lines are printed again at the end (the board's serial console drops lines): multisampling, the clears and
  /// the kept depth and stencil.
  func reprinted(_ what: String) -> Bool {
    for prefix in ["msaa", "clears", "transfers", "blit", "copy region", "depth kept", "stencil kept", "layers", "heap return", "multiview"] where what.utf8.starts(with: prefix.utf8) { return true }
    return false
  }

  func caught(_ name: String, _ e: GPUError) {
    switch e {
    case .unsupported(let why): skip(name, "the device refuses: \(why)")
    case .invalid(let why): fail("\(name): invalid: \(why)")
    case .outOfMemory(let what): fail("\(name): out of memory: \(what)")
    case .failed(let call, let code): fail("\(name): \(call) failed with \(code)")
    case .noDevice(let why): fail("\(name): no device: \(why)")
    case .lost: fail("\(name): the GPU was lost")
    }
  }

  /// A depth or stencil format's name (Embedded Swift can't print an enum's value).
  func name(_ format: PixelFormat) -> String {
    switch format {
    case .depth16: return "depth16"
    case .depth32f: return "depth32f"
    case .depth24stencil8: return "depth24stencil8"
    case .depth32fstencil8: return "depth32fstencil8"
    case .stencil8: return "stencil8"
    default: return "another format"
    }
  }

  func hex(_ p: [UInt8]) -> String {
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    var out = "0x"
    for b in p {
      out.append(digits[Int(b >> 4)])
      out.append(digits[Int(b & 15)])
    }
    return out
  }

  /// Which flags are set, as the names of the true ones and, after a slash, of the false ones.
  func line(_ group: String, _ flags: [(String, Bool)]) {
    var have = ""
    var lack = ""
    for (name, on) in flags {
      if on { have += " " + name } else { lack += " " + name }
    }
    print("loinnir-test: features \(group): \(have) /\(lack)")
  }

  /// The feature groups the device behind the core reports, once.
  func describe() {
    let l = d.limits
    print("loinnir-test: device \(d.name) (\(d.backend)): textures \(l.heapTextures), samplers \(l.heapSamplers), storage images \(l.heapStorageImages)")
    print("loinnir-test: limits: image \(l.maxImageDimension), 3d \(l.maxImageDimension3D), layers \(l.maxImageArrayLayers), samples \(l.maxSamples), colour attachments \(l.maxColorAttachments), views \(l.maxMultiviewViews), subgroup \(l.subgroupSize), formats \(l.formatTable.count)")
    line("queues and draws", [
      ("computeQueue", f.computeQueue), ("indirectDispatch", f.indirectDispatch), ("indirectDraw", f.indirectDraw),
      ("indexedDraw", f.indexedDraw), ("drawIndirectCount", f.drawIndirectCount), ("multipleDrawsPerPass", f.multipleDrawsPerPass),
      ("multipleColorAttachments", f.multipleColorAttachments), ("loadAttachments", f.loadAttachments),
      ("dynamicState", f.dynamicState), ("multiview", f.multiview), ("timestampQueries", f.timestampQueries),
      ("occlusionQueries", f.occlusionQueries), ("pipelineStatisticsQueries", f.pipelineStatisticsQueries)])
    line("images", [
      ("sampledImages", f.sampledImages), ("storageImages", f.storageImages), ("depth", f.depth), ("stencil", f.stencil),
      ("mipmaps", f.mipmaps), ("arrayImages", f.arrayImages), ("cubeImages", f.cubeImages), ("volumeImages", f.volumeImages),
      ("multisample", f.multisample), ("imageViews", f.imageViews), ("compressedASTC", f.compressedASTC),
      ("compressedETC2", f.compressedETC2), ("compressedBC", f.compressedBC), ("importHandle", f.importHandle),
      ("images1D", f.images1D), ("imageSwizzle", f.imageSwizzle), ("uniformTexelBuffers", f.uniformTexelBuffers),
      ("storageTexelBuffers", f.storageTexelBuffers)])
    line("samplers", [
      ("anisotropy", f.samplerAnisotropy), ("compare", f.samplerCompare), ("border", f.samplerBorder),
      ("unnormalized", f.unnormalizedCoordinates), ("minMagFilters", f.samplerMinMagFilters),
      ("axisAddressModes", f.samplerAxisAddressModes), ("mirrorClampToEdge", f.samplerMirrorClampToEdge),
      ("customBorderColor", f.customBorderColor)])
    line("pipeline state", [
      ("cullModes", f.cullModes), ("rasterizerDiscard", f.rasterizerDiscard), ("generalBlend", f.generalBlend),
      ("independentBlend", f.independentBlend), ("dualSourceBlend", f.dualSourceBlend), ("logicOps", f.logicOps),
      ("fillModeNonSolid", f.fillModeNonSolid), ("wideLines", f.wideLines), ("depthClamp", f.depthClamp),
      ("depthBias", f.depthBias), ("depthBounds", f.depthBounds), ("geometryShader", f.geometryShader),
      ("tessellation", f.tessellation), ("extendedTopologies", f.extendedTopologies), ("primitiveRestart", f.primitiveRestart),
      ("sampleShading", f.sampleShading), ("alphaToCoverage", f.alphaToCoverage), ("alphaToOne", f.alphaToOne),
      ("specializationConstants", f.specializationConstants)])
    line("commands", [
      ("copyImage", f.copyImage), ("blitImage", f.blitImage), ("resolveImage", f.resolveImage),
      ("resolveAttachments", f.resolveAttachments), ("depthStencilResolve", f.depthStencilResolve),
      ("imageRegionCopies", f.imageRegionCopies), ("fillBuffer", f.fillBuffer), ("updateBuffer", f.updateBuffer),
      ("clearImage", f.clearImage), ("clearAttachments", f.clearAttachments)])
    line("shaders", [
      ("float16", f.shaderFloat16), ("int8", f.shaderInt8), ("int16", f.shaderInt16), ("int64", f.shaderInt64),
      ("float64", f.shaderFloat64), ("subgroupOperations", f.subgroupOperations), ("atomic32", f.shaderAtomic32),
      ("atomic64", f.shaderAtomic64), ("imageAtomics", f.shaderImageAtomics), ("derivatives", f.shaderDerivatives),
      ("storageImageExtendedFormats", f.shaderStorageImageExtendedFormats), ("clipDistance", f.shaderClipDistance),
      ("cullDistance", f.shaderCullDistance), ("imageGatherExtended", f.shaderImageGatherExtended),
      ("minLod", f.shaderMinLod), ("drawParameters", f.shaderDrawParameters),
      ("demoteToHelperInvocation", f.shaderDemoteToHelperInvocation), ("viewportIndexLayer", f.shaderViewportIndexLayer),
      ("stencilExport", f.shaderStencilExport), ("sampleRateShading", f.shaderSampleRateShading),
      ("floatControls", f.shaderFloatControls)])
  }

  // MARK: Memory, images and passes

  func run(_ list: GPUCommandList) throws(GPUError) {
    timeline += 1
    try d.run(list, signal: timeline)
  }

  func store(_ m: GPUMemory, floats: [Float]) {
    let p = unsafe m.pointer!.assumingMemoryBound(to: Float.self)
    for i in 0..<floats.count { unsafe p[i] = floats[i] }
  }

  func store(_ m: GPUMemory, bytes: [UInt8]) {
    let p = unsafe m.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<bytes.count { unsafe p[i] = bytes[i] }
  }

  func read(_ m: GPUMemory, _ count: Int) -> [UInt8] {
    let p = unsafe m.pointer!.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count { out[i] = unsafe p[i] }
    return out
  }

  func image(_ format: PixelFormat, _ width: Int32, _ height: Int32, depth: Int32 = 1, mips: UInt32 = 1, layers: UInt32 = 1,
             samples: UInt32 = 1, dimension: ImageDimension = .d2, usage: ImageUsage) throws(GPUError) -> GPUImage {
    try d.makeImage(ImageDescriptor(format: format, width: width, height: height, depth: depth, mipLevels: mips, layers: layers,
                                    samples: samples, dimension: dimension, usage: usage))
  }

  func bytes(_ c: [Float]) -> [UInt8] {
    [UInt8(c[0] * 255 + 0.5), UInt8(c[1] * 255 + 0.5), UInt8(c[2] * 255 + 0.5), UInt8(c[3] * 255 + 0.5)]
  }

  func pixel(_ px: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
    let o = (y * width + x) * 4
    return [px[o], px[o + 1], px[o + 2], px[o + 3]]
  }

  func near(_ a: [UInt8], _ b: [UInt8], _ tolerance: Int) -> Bool {
    for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > tolerance { return false }
    return true
  }

  /// Judges every pixel of `px` (`width` by `height`, rgba8) against `want`, which is nil for a pixel not judged (one on an
  /// edge the rasterizer's rules decide). Ends the run at the first disagreement past `tolerance`; the count judged otherwise.
  func judge(_ name: String, _ px: [UInt8], _ width: Int, _ height: Int, tolerance: Int = 0, _ want: (Int, Int) -> [UInt8]?) -> Int {
    var judged = 0
    for y in 0..<height {
      for x in 0..<width {
        guard let w = want(x, y) else { continue }
        judged += 1
        let p = pixel(px, width, x, y)
        if !near(p, w, tolerance) { fail("\(name): (\(x), \(y)) reads \(hex(p)), expected \(hex(w)) within \(tolerance)") }
      }
    }
    return judged
  }

  func colorTarget(_ width: Int32, _ height: Int32, samples: UInt32 = 1) throws(GPUError) -> GPUImage {
    try image(.rgba8, width, height, samples: samples, usage: .renderTarget | .copySource | .copyDestination)
  }

  /// Copies `target` to readback memory after `list`, runs it, and gives the bytes.
  func readBack(_ list: GPUCommandList, _ target: GPUImage) throws(GPUError) -> [UInt8] {
    var l = list
    let size = Int(target.width) * Int(target.height) * 4
    let readback = try d.allocate(.readback, bytes: size)
    l.copy(target, to: readback)
    try run(l)
    return read(readback, size)
  }

  // MARK: Rectangles

  /// A rectangle in pixels of a `width` by `height` target, drawn as two triangles (the pair every case draws): its depth
  /// goes from `zLeft` at its left edge to `zRight` at its right, and `flip` reverses the triangles' winding.
  struct Rect {
    var x0: Float
    var y0: Float
    var x1: Float
    var y1: Float
    var zLeft: Float = 0.5
    var zRight: Float = 0.5
    var color: [Float]
    var flip = false

    func contains(_ x: Int, _ y: Int) -> Bool { Float(x) >= x0 && Float(x) < x1 && Float(y) >= y0 && Float(y) < y1 }
    func depth(at x: Int) -> Float { zLeft + (zRight - zLeft) * ((Float(x) + 0.5 - x0) / (x1 - x0)) }
  }

  /// The vertices of `rects`: six each, a position (x, y, z, 1) and a colour, 32 bytes.
  func vertices(_ rects: [Rect], width: Float, height: Float) -> [Float] {
    var out: [Float] = []
    for r in rects {
      let a = (r.x0, r.y0, r.zLeft), b = (r.x1, r.y0, r.zRight), c = (r.x0, r.y1, r.zLeft), e = (r.x1, r.y1, r.zRight)
      let order = r.flip ? [a, c, b, b, c, e] : [a, b, c, b, e, c]
      for v in order {
        out.append(v.0 / width * 2 - 1)
        out.append(v.1 / height * 2 - 1)
        out.append(v.2)
        out.append(1)
        out.append(contentsOf: r.color)
      }
    }
    return out
  }

  func meshBuffer(_ rects: [Rect], width: Float, height: Float) throws(GPUError) -> GPUMemory {
    let v = vertices(rects, width: width, height: height)
    let m = try d.allocate(.upload, bytes: v.count * 4)
    store(m, floats: v)
    return m
  }

  func meshPipeline(colors: [PixelFormat] = [.rgba8], depthFormat: PixelFormat? = nil, depthStencil: DepthStencilState = DepthStencilState(),
                    rasterization: RasterizationState = RasterizationState(), multisample: MultisampleState = MultisampleState(),
                    attachmentBlends: [ColorBlendAttachment]? = nil, logicOp: LogicOp? = nil,
                    blendConstants: BlendConstants = BlendConstants(), dynamic: DynamicStates = DynamicStates(),
                    fragment: [UInt8] = LoinnirShaders.meshFrag, vertex: [UInt8] = LoinnirShaders.meshVert,
                    viewMask: UInt32 = 0) throws(GPUError) -> GPUPipeline {
    try d.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: vertex, fragment: fragment, colorFormats: colors, blend: .opaque,
      depthStencilFormat: depthFormat, depthStencil: depthStencil, rasterization: rasterization, multisample: multisample,
      attachmentBlends: attachmentBlends, logicOp: logicOp, blendConstants: blendConstants, dynamic: dynamic, viewMask: viewMask))
  }

  var rgbaTarget: Bool {
    let c = d.limits.formats(.rgba8)
    return c.renderTarget && c.blitSource
  }

  // MARK: Depth

  func depthFormat() -> PixelFormat? {
    for format in [PixelFormat.depth32f, .depth16] {
      if d.limits.formats(format).depthTarget { return format }
    }
    return nil
  }

  /// Four rectangles drawn out of order with depth testing: the nearest wins wherever they overlap, whichever was drawn first, and
  /// one has a depth that crosses another's, so the test is per pixel.
  /// With `kept`, the first two rectangles are drawn in one pass that stores the depth, and the others in a second that keeps the
  /// colour and the depth (the depth loaded into the tile again), with the same reference.
  func depth(kept: Bool = false) throws(GPUError) {
    guard f.depth, rgbaTarget else { return skip("depth", "no depth attachments") }
    guard let format = depthFormat() else { return skip("depth", "no depth-only format that is a depth target") }
    guard !kept || f.loadAttachments else { return skip("depth kept", "no kept attachments") }
    let w = 32, h = 32
    let clear: [Float] = [0.2, 0.2, 0.2, 1]
    let rects = [
      Rect(x0: 4, y0: 4, x1: 20, y1: 20, zLeft: 0.5, zRight: 0.5, color: [1, 0, 0, 1]),
      Rect(x0: 8, y0: 0, x1: 24, y1: 32, zLeft: 0.7, zRight: 0.7, color: [0, 0, 1, 1]),
      Rect(x0: 12, y0: 12, x1: 28, y1: 28, zLeft: 0.3, zRight: 0.3, color: [0, 1, 0, 1]),
      Rect(x0: 0, y0: 28, x1: 32, y1: 32, zLeft: 0.1, zRight: 0.9, color: [1, 0, 1, 1]),
    ]
    let mesh = try meshBuffer(rects, width: Float(w), height: Float(h))
    let pso = try meshPipeline(depthFormat: format, depthStencil: DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .less))
    let target = try colorTarget(Int32(w), Int32(h))
    let depthImage = try image(format, Int32(w), Int32(h), usage: .depthStencilTarget)
    var list = GPUCommandList()
    let info = RenderingInfo(colors: [Attachment(image: target, load: .clear(clear[0], clear[1], clear[2], clear[3]))],
                             depthStencil: DepthStencilAttachment(image: depthImage, clearDepth: 1))
    if kept {
      list.render(info) { r in
        for i in 0..<2 { r.draw(pso, root: mesh.address, vertices: 6, firstVertex: UInt32(6 * i)) }
      }
      let again = RenderingInfo(colors: [Attachment(image: target, load: .load)],
                                depthStencil: DepthStencilAttachment(image: depthImage, depthLoad: .load, stencilLoad: .load))
      list.render(again) { r in
        for i in 2..<rects.count { r.draw(pso, root: mesh.address, vertices: 6, firstVertex: UInt32(6 * i)) }
      }
    } else {
      list.render(info) { r in
        for i in 0..<rects.count { r.draw(pso, root: mesh.address, vertices: 6, firstVertex: UInt32(6 * i)) }
      }
    }
    let px = try readBack(list, target)
    // The reference: each rectangle in order, kept where its depth at the pixel's centre is less than what is there. A pixel
    // where two depths are within 0.005 is not judged (a crossing).
    var color = [[UInt8]](repeating: bytes(clear), count: w * h)
    var best = [Float](repeating: 1, count: w * h)
    var unjudged = [Bool](repeating: false, count: w * h)
    for r in rects {
      for y in 0..<h {
        for x in 0..<w where r.contains(x, y) {
          let z = r.depth(at: x)
          let i = y * w + x
          if abs(z - best[i]) < 0.005 { unjudged[i] = true }
          if z < best[i] {
            best[i] = z
            color[i] = bytes(r.color)
          }
        }
      }
    }
    let judged = judge("depth", px, w, h) { x, y in unjudged[y * w + x] ? nil : color[y * w + x] }
    ok("depth\(kept ? " kept" : ""): four overlapping rectangles out of order on \(name(format))\(kept ? ", two in a pass that stores the depth and two in one that loads it" : ""), \(judged) of \(w * h) pixels exact")
  }

  // MARK: Stencil

  func stencilFormat() -> PixelFormat? {
    for format in [PixelFormat.stencil8, .depth24stencil8, .depth32fstencil8] {
      let c = d.limits.formats(format)
      if c.depthTarget && (!format.hasDepth || f.depth) { return format }
    }
    return nil
  }

  /// A mask built in the stencil buffer (one rectangle replaces, a second increments), then two draws that pass where the
  /// stencil equals a reference: one pipeline with a static reference and one that takes it from the pass.
  /// With `kept`, the mask is built in one pass that stores the stencil, and tested in a second that keeps the colour and the
  /// stencil (loaded into the tile again).
  func stencil(kept: Bool = false) throws(GPUError) {
    guard f.stencil, rgbaTarget else { return skip("stencil", "no stencil attachments") }
    guard let format = stencilFormat() else { return skip("stencil", "no stencil format that is a depth target") }
    guard !kept || f.loadAttachments else { return skip("stencil kept", "no kept attachments") }
    let w = 32, h = 32
    let a = Rect(x0: 4, y0: 4, x1: 20, y1: 20, color: [1, 1, 1, 1])
    let b = Rect(x0: 12, y0: 12, x1: 28, y1: 28, color: [1, 1, 1, 1])
    let all = [a, b,
               Rect(x0: 0, y0: 0, x1: 32, y1: 32, color: [0, 1, 0, 1]),
               Rect(x0: 0, y0: 0, x1: 32, y1: 32, color: [1, 0, 0, 1])]
    let mesh = try meshBuffer(all, width: Float(w), height: Float(h))
    func face(_ compare: CompareOp, _ pass: StencilOp, reference: UInt32) -> DepthStencilState {
      let s = StencilFaceState(failOp: .keep, passOp: pass, depthFailOp: .keep, compare: compare, compareMask: 0xFF, writeMask: 0xFF,
                               reference: reference)
      return DepthStencilState(stencilTest: true, front: s, back: s)
    }
    let none = [ColorBlendAttachment(writeMask: ColorMask(rawValue: 0))]
    let replace = try meshPipeline(depthFormat: format, depthStencil: face(.always, .replace, reference: 1), attachmentBlends: none)
    let increment = try meshPipeline(depthFormat: format, depthStencil: face(.always, .incrementClamp, reference: 0), attachmentBlends: none)
    let equalsTwo = try meshPipeline(depthFormat: format, depthStencil: face(.equal, .keep, reference: 2))
    let dynamicState: DynamicStates = f.dynamicState ? .stencilReference : DynamicStates()
    let equalsOne = try meshPipeline(depthFormat: format, depthStencil: face(.equal, .keep, reference: 1), dynamic: dynamicState)
    let useDynamic = f.dynamicState
    let target = try colorTarget(Int32(w), Int32(h))
    let stencilImage = try image(format, Int32(w), Int32(h), usage: .depthStencilTarget)
    var list = GPUCommandList()
    let info = RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))],
                             depthStencil: DepthStencilAttachment(image: stencilImage, clearDepth: 1, clearStencil: 0))
    if kept {
      list.render(info) { r in
        r.draw(replace, root: mesh.address, vertices: 6, firstVertex: 0)
        r.draw(increment, root: mesh.address, vertices: 6, firstVertex: 6)
      }
      let again = RenderingInfo(colors: [Attachment(image: target, load: .load)],
                                depthStencil: DepthStencilAttachment(image: stencilImage, depthLoad: .load, stencilLoad: .load))
      list.render(again) { r in
        r.draw(equalsTwo, root: mesh.address, vertices: 6, firstVertex: 12)
        if useDynamic { r.setStencilReference(.both, 1) }
        r.draw(equalsOne, root: mesh.address, vertices: 6, firstVertex: 18)
      }
    } else {
      list.render(info) { r in
        r.draw(replace, root: mesh.address, vertices: 6, firstVertex: 0)
        r.draw(increment, root: mesh.address, vertices: 6, firstVertex: 6)
        r.draw(equalsTwo, root: mesh.address, vertices: 6, firstVertex: 12)
        if useDynamic { r.setStencilReference(.both, 1) }
        r.draw(equalsOne, root: mesh.address, vertices: 6, firstVertex: 18)
      }
    }
    let px = try readBack(list, target)
    let judged = judge("stencil", px, w, h) { x, y in
      let inA = a.contains(x, y), inB = b.contains(x, y)
      if inA && inB { return [0, 255, 0, 255] }
      if inA || inB { return [255, 0, 0, 255] }
      return [0, 0, 255, 255]
    }
    ok("stencil\(kept ? " kept" : ""): mask by replace and increment, tested equal to 2 and to 1\(useDynamic ? " (dynamic reference)" : "") on \(name(format))\(kept ? ", the test in a second pass that loads the stencil" : ""), \(judged) pixels exact")
  }

  // MARK: Multisampling

  /// A rectangle whose right edge is half way through a pixel, drawn with 4 samples and resolved: the pixels it covers entirely are
  /// the colour, those it doesn't touch are the clear, and the edge pixel is the mean of both (two of four samples, on every standard
  /// sample pattern), within 2. Once resolved by the pass, once by `resolveImage`.
  func msaa() throws(GPUError) {
    guard f.multisample, rgbaTarget, d.limits.maxSamples >= 4, d.limits.formats(.rgba8).renderSamples.contains(4) else {
      return skip("msaa", "no 4-sample colour attachments")
    }
    guard f.resolveAttachments || f.resolveImage else { return skip("msaa", "no resolve") }
    let w = 16, h = 16
    let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 8.5, y1: 16, color: [1, 0, 0, 1])], width: Float(w), height: Float(h))
    let pso = try meshPipeline(multisample: MultisampleState(samples: 4))
    func judgeResolved(_ name: String, _ px: [UInt8]) {
      let n = judge(name, px, w, h, tolerance: 2) { x, y in
        if x < 8 { return [255, 0, 0, 255] }
        if x > 8 { return [0, 0, 255, 255] }
        return [128, 0, 127, 255]
      }
      ok("msaa: \(name), \(n) pixels, the edge pixel the mean of the colour and the clear within 2")
    }
    if f.resolveAttachments {
      let ms = try colorTarget(Int32(w), Int32(h), samples: 4)
      let resolved = try colorTarget(Int32(w), Int32(h))
      var list = GPUCommandList()
      let info = RenderingInfo(colors: [Attachment(view: ImageView(ms), load: .clear(0, 0, 1, 1), store: .discard, resolve: ImageView(resolved))])
      list.render(info) { r in r.draw(pso, root: mesh.address, vertices: 6) }
      judgeResolved("4x resolved by the pass", try readBack(list, resolved))
    } else {
      skip("msaa: resolve by the pass", "no resolve attachments")
    }
    if f.resolveImage {
      let ms = try colorTarget(Int32(w), Int32(h), samples: 4)
      let resolved = try colorTarget(Int32(w), Int32(h))
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: ms, load: .clear(0, 0, 1, 1), store: .store)])) { r in
        r.draw(pso, root: mesh.address, vertices: 6)
      }
      list.resolveImage(ms, to: resolved, regions: [ImageCopyRegion(extent: Extent3D(width: UInt32(w), height: UInt32(h)))])
      judgeResolved("4x resolved by resolveImage", try readBack(list, resolved))
    } else {
      skip("msaa: resolveImage", "no image resolves")
    }
    if f.resolveAttachments { try msaaMore() }
  }

  /// The covered samples of a pixel whose centre is half a pixel left of an edge, on Vulkan's standard sample locations (x in
  /// 1/16 pixel from the centre): the samples left of it, and one more where a sample lies on the edge (the rasterizer's tie).
  func samplesLeftOfCentre(_ n: Int) -> (covered: Int, tied: Int) {
    let xs: [Int]
    switch n {
    case 2: xs = [4, -4]
    case 4: xs = [-2, 6, -6, 2]
    case 8: xs = [1, -1, 5, -3, -5, -7, 3, 7]
    default: xs = [1, -1, -3, 4, -5, 2, 5, 3, -2, 0, -4, -6, -8, 7, 6, -7]
    }
    var covered = 0, tied = 0
    for x in xs {
      if x < 0 { covered += 1 }
      if x == 0 { tied += 1 }
    }
    return (covered, tied)
  }

  /// Every sample count the device offers resolved by the pass; a target stored and resolved at once; a kept multisampled target;
  /// the sample mask, sample shading, alpha to one and alpha to coverage, each resolved by the pass and judged.
  func msaaMore() throws(GPUError) {
    let w = 16, h = 16
    let edge = try meshBuffer([Rect(x0: 0, y0: 0, x1: 8.5, y1: 16, color: [1, 0, 0, 1])], width: Float(w), height: Float(h))
    let caps = d.limits.formats(.rgba8)
    func resolvedPass(_ n: UInt32, _ body: (inout GPUCommandList) -> Void, load: LoadAction = .clear(0, 0, 1, 1),
                      ms: GPUImage? = nil) throws(GPUError) -> [UInt8] {
      let target: GPUImage
      if let given = ms { target = given } else { target = try colorTarget(Int32(w), Int32(h), samples: n) }
      let resolved = try colorTarget(Int32(w), Int32(h))
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(view: ImageView(target), load: load, store: .discard, resolve: ImageView(resolved))])) { r in
        body(&r)
      }
      return try readBack(list, resolved)
    }
    func judgeEdge(_ name: String, _ n: Int, _ px: [UInt8]) -> Int {
      let k = samplesLeftOfCentre(n)
      return judge(name, px, w, h, tolerance: 2) { x, y in
        if x < 8 { return [255, 0, 0, 255] }
        if x > 8 { return [0, 0, 255, 255] }
        // The edge pixel: the mean of the covered samples' red and the others' blue; a tied sample may go either way.
        let lo = [UInt8((255 * k.covered + n / 2) / n), 0, UInt8((255 * (n - k.covered) + n / 2) / n), 255]
        let hi = [UInt8((255 * (k.covered + k.tied) + n / 2) / n), 0, UInt8((255 * (n - k.covered - k.tied) + n / 2) / n), 255]
        let p = pixel(px, w, x, y)
        return near(p, lo, 2) ? lo : hi
      }
    }
    // Each sample count.
    for n in [2, 4, 8, 16] where caps.renderSamples.contains(UInt32(n)) && UInt32(n) <= d.limits.maxSamples {
      let pso = try meshPipeline(multisample: MultisampleState(samples: UInt32(n)))
      let px = try resolvedPass(UInt32(n)) { r in r.draw(pso, root: edge.address, vertices: 6) }
      let judged = judgeEdge("msaa \(n)x", n, px)
      ok("msaa: \(n) samples resolved by the pass, \(judged) pixels, the edge pixel the mean of its covered samples within 2")
    }
    let pso4 = try meshPipeline(multisample: MultisampleState(samples: 4))
    // Stored and resolved by one pass: the resolve judged, and the stored samples resolved again by resolveImage.
    do {
      let ms = try colorTarget(Int32(w), Int32(h), samples: 4)
      let resolved = try colorTarget(Int32(w), Int32(h))
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(view: ImageView(ms), load: .clear(0, 0, 1, 1), store: .store, resolve: ImageView(resolved))])) { r in
        r.draw(pso4, root: edge.address, vertices: 6)
      }
      let a = judgeEdge("msaa stored and resolved", 4, try readBack(list, resolved))
      if f.resolveImage {
        let again = try colorTarget(Int32(w), Int32(h))
        var l2 = GPUCommandList()
        l2.resolveImage(ms, to: again, regions: [ImageCopyRegion(extent: Extent3D(width: UInt32(w), height: UInt32(h)))])
        let b = judgeEdge("msaa stored, then resolveImage", 4, try readBack(l2, again))
        ok("msaa: 4 samples stored and resolved by one pass, \(a) pixels, and the stored samples resolved again, \(b) pixels")
      } else {
        ok("msaa: 4 samples stored and resolved by one pass, \(a) pixels")
      }
    }
    // Kept: the samples a first pass stored are loaded by a second, which draws beside them and resolves.
    if f.loadAttachments {
      let ms = try colorTarget(Int32(w), Int32(h), samples: 4)
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: ms, load: .clear(0, 0, 1, 1), store: .store)])) { r in
        r.draw(pso4, root: edge.address, vertices: 6)
      }
      try run(list)
      let green = try meshBuffer([Rect(x0: 12, y0: 0, x1: 16, y1: 16, color: [0, 1, 0, 1])], width: Float(w), height: Float(h))
      let px = try resolvedPass(4, { r in r.draw(pso4, root: green.address, vertices: 6) }, load: .load, ms: ms)
      let k = samplesLeftOfCentre(4)
      let judged = judge("msaa kept", px, w, h, tolerance: 2) { x, y in
        if x < 8 { return [255, 0, 0, 255] }
        if x == 8 { return [UInt8((255 * k.covered + 2) / 4), 0, UInt8((255 * (4 - k.covered) + 2) / 4), 255] }
        if x < 12 { return [0, 0, 255, 255] }
        return [0, 255, 0, 255]
      }
      ok("msaa: 4 samples kept by a second pass (each loaded a sample at a time), drawn beside and resolved, \(judged) pixels")
    } else {
      skip("msaa: kept", "no kept attachments")
    }
    // A depth attachment of 4 samples resolved by the pass (sample 0), discarded and stored: a rectangle at depth 0.25 whose edge is
    // half way through a pixel, over a clear of 1; the edge pixel's sample 0 (Vulkan's (-2, -6)/16 of the centre) is inside it.
    if f.depthStencilResolve, let format = depthFormat(), d.limits.formats(format).depthSamples.contains(4) {
      let deep = try meshBuffer([Rect(x0: 0, y0: 0, x1: 8.5, y1: 16, zLeft: 0.25, zRight: 0.25, color: [1, 0, 0, 1])],
                                width: Float(w), height: Float(h))
      let pso = try meshPipeline(depthFormat: format, depthStencil: DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .always),
                                 multisample: MultisampleState(samples: 4))
      var judged = 0
      for store in [StoreAction.discard, .store] {
        let ms = try colorTarget(Int32(w), Int32(h), samples: 4)
        let msDepth = try image(format, Int32(w), Int32(h), samples: 4, usage: .depthStencilTarget)
        let resolved = try image(format, Int32(w), Int32(h), usage: .depthStencilTarget | .copySource)
        let readback = try d.allocate(.readback, bytes: w * h * 4)
        var list = GPUCommandList()
        list.render(RenderingInfo(colors: [Attachment(image: ms, load: .clear(0, 0, 1, 1), store: .discard)],
                                  depthStencil: DepthStencilAttachment(view: ImageView(msDepth), depthStore: store, clearDepth: 1,
                                                                       resolve: ImageView(resolved)))) { r in
          r.draw(pso, root: deep.address, vertices: 6)
        }
        list.copy(resolved, to: readback, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth),
                                                                      imageExtent: Extent3D(width: UInt32(w), height: UInt32(h)))])
        try run(list)
        let bytesPer = format == .depth16 ? 2 : 4
        let raw = read(readback, w * h * bytesPer)
        for y in 0..<h {
          for x in 0..<w {
            let o = (y * w + x) * bytesPer
            let got: Float = bytesPer == 2
              ? Float(UInt16(raw[o]) | UInt16(raw[o + 1]) << 8) / 65535
              : Float(bitPattern: UInt32(raw[o]) | UInt32(raw[o + 1]) << 8 | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24)
            let want: Float = x <= 8 ? 0.25 : 1
            if abs(got - want) > (bytesPer == 2 ? 0.0001 : 0) {
              fail("msaa depth resolve (\(store == .store ? "stored" : "discarded")): (\(x), \(y)) reads \(got), expected \(want)")
            }
            judged += 1
          }
        }
      }
      ok("msaa: a depth attachment of 4 samples resolved by the pass (sample 0) on \(name(format)), discarded and stored, \(judged) texels exact")
    } else {
      skip("msaa: depth resolve", "no depth and stencil resolves of 4 samples")
    }
    let whole = try meshBuffer([Rect(x0: 0, y0: 0, x1: 16, y1: 16, color: [1, 0, 0, 1])], width: Float(w), height: Float(h))
    // The sample mask: samples 0 and 2 of 4.
    do {
      let pso = try meshPipeline(multisample: MultisampleState(samples: 4, sampleMask: 0b0101))
      let px = try resolvedPass(4) { r in r.draw(pso, root: whole.address, vertices: 6) }
      let judged = judge("sample mask", px, w, h, tolerance: 2) { _, _ in [128, 0, 127, 255] }
      ok("msaa: a sample mask of samples 0 and 2 of 4, \(judged) pixels half the colour and half the clear within 2")
    }
    // Sample shading: a shader whose colour is its sample's own (red on the odd samples).
    if f.sampleShading && f.shaderSampleRateShading {
      let pso = try meshPipeline(multisample: MultisampleState(samples: 4, sampleShading: true, minSampleShading: 1),
                                 fragment: LoinnirShaders.sampleidFrag)
      let px = try resolvedPass(4) { r in r.draw(pso, root: whole.address, vertices: 6) }
      let judged = judge("sample shading", px, w, h, tolerance: 2) { _, _ in [128, 0, 0, 255] }
      ok("msaa: sample shading, a colour of each sample's own (gl_SampleID), \(judged) pixels the mean within 2")
    } else {
      skip("msaa: sample shading", "no sample shading")
    }
    // Alpha to one: a colour of alpha 0.25 written with alpha 1.
    if f.alphaToOne {
      let quarter = try meshBuffer([Rect(x0: 0, y0: 0, x1: 16, y1: 16, color: [1, 0, 0, 0.25])], width: Float(w), height: Float(h))
      let pso = try meshPipeline(multisample: MultisampleState(samples: 4, alphaToOne: true))
      let px = try resolvedPass(4) { r in r.draw(pso, root: quarter.address, vertices: 6) }
      let judged = judge("alpha to one", px, w, h, tolerance: 1) { _, _ in [255, 0, 0, 255] }
      ok("msaa: alpha to one, a colour of alpha 0.25 stored with alpha 1, \(judged) pixels")
    } else {
      skip("msaa: alpha to one", "no alpha to one")
    }
    // Alpha to coverage: alpha 0 covers no sample, alpha 1 every one, and alpha 0.5 some (the hardware's mapping, printed).
    if f.alphaToCoverage {
      let rects = [Rect(x0: 0, y0: 0, x1: 5, y1: 16, color: [1, 0, 0, 0]), Rect(x0: 5, y0: 0, x1: 10, y1: 16, color: [1, 0, 0, 1]),
                   Rect(x0: 10, y0: 0, x1: 16, y1: 16, color: [1, 0, 0, 0.5])]
      let mesh = try meshBuffer(rects, width: Float(w), height: Float(h))
      let pso = try meshPipeline(multisample: MultisampleState(samples: 4, alphaToCoverage: true))
      let px = try resolvedPass(4) { r in r.draw(pso, root: mesh.address, vertices: 18) }
      let half = pixel(px, w, 12, 8)
      let line = "loinnir-test: alpha to coverage: alpha 0.5 of 4 samples resolves to \(hex(half)) (red over a blue clear)"
      print(line)
      notes.append(line)
      let judged = judge("alpha to coverage", px, w, h, tolerance: 2) { x, _ in
        if x < 5 { return [0, 0, 255, 255] }
        if x < 10 { return [255, 0, 0, 255] }
        return half
      }
      // Some samples but not all: the red is the covered share, strictly between the clear and the colour.
      guard half[0] > 2 && half[0] < 253 else { fail("alpha to coverage: alpha 0.5 covered \(hex(half)), not some of the samples") }
      ok("msaa: alpha to coverage, alpha 0 covers no sample and 1 every one, \(judged) pixels, and 0.5 some (\(hex(half)))")
    } else {
      skip("msaa: alpha to coverage", "no alpha to coverage")
    }
  }

  // MARK: Layers

  /// The texels of layer `layer` of level `mip` of `image` (`width` by `height`, rgba8) after `list`.
  func readLayer(_ list: GPUCommandList, _ image: GPUImage, layer: UInt32, mip: UInt32 = 0, _ width: Int, _ height: Int) throws(GPUError) -> [UInt8] {
    var l = list
    let readback = try d.allocate(.readback, bytes: width * height * 4)
    l.copy(image, to: readback, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(mip: mip, baseLayer: layer),
                                                            imageExtent: Extent3D(width: UInt32(width), height: UInt32(height)))])
    try run(l)
    return read(readback, width * height * 4)
  }

  /// Passes of layers: a draw of an instance a layer (Layer written by the vertex stage) into 3 layers and into 10 (two of the
  /// hardware's tiler contexts), a second pass that keeps the 3 and draws into the first, a clear of two layers inside a pass, and a
  /// pass into a view of one layer of one level of an image of several; every texel of every layer exact.
  func layers() throws(GPUError) {
    guard f.arrayImages, rgbaTarget, f.imageRegionCopies else { return skip("layers", "no array images or region copies") }
    let w = 16, h = 16
    let usage: ImageUsage = .renderTarget | .copySource | .copyDestination
    let green = try meshBuffer([Rect(x0: 4, y0: 0, x1: 12, y1: 16, color: [0, 1, 0, 1])], width: Float(w), height: Float(h))
    func want(_ layer: Int, _ x: Int) -> [UInt8] { x >= 4 && x < 12 ? [UInt8(20 * layer), 255, 0, 255] : [0, 0, 255, 255] }
    if f.shaderViewportIndexLayer {
      let pso = try meshPipeline(vertex: LoinnirShaders.layerVert)
      for count in [3, 10] where UInt32(count) <= d.limits.maxImageArrayLayers {
        let image = try image(.rgba8, Int32(w), Int32(h), layers: UInt32(count), usage: usage)
        var list = GPUCommandList()
        list.render(RenderingInfo(colors: [Attachment(view: ImageView(image), load: .clear(0, 0, 1, 1))], layerCount: UInt32(count))) { r in
          r.draw(pso, root: green.address, vertices: 6, instances: UInt32(count))
        }
        try run(list)
        var judged = 0
        for l in 0..<count {
          let px = try readLayer(GPUCommandList(), image, layer: UInt32(l), w, h)
          judged += judge("layers \(count): layer \(l)", px, w, h) { x, _ in want(l, x) }
        }
        ok("layers: a draw of an instance a layer into \(count) layers (Layer from the vertex stage), \(judged) texels exact")
        if count == 3 && f.loadAttachments {
          // Kept: each layer loaded into its tile again, and a draw without Layer goes to the first.
          let blue = try meshBuffer([Rect(x0: 12, y0: 0, x1: 16, y1: 16, color: [1, 1, 1, 1])], width: Float(w), height: Float(h))
          let plain = try meshPipeline()
          var again = GPUCommandList()
          again.render(RenderingInfo(colors: [Attachment(view: ImageView(image), load: .load)], layerCount: 3)) { r in
            r.draw(plain, root: blue.address, vertices: 6)
          }
          try run(again)
          var n = 0
          for l in 0..<3 {
            let px = try readLayer(GPUCommandList(), image, layer: UInt32(l), w, h)
            n += judge("layers kept: layer \(l)", px, w, h) { x, _ in l == 0 && x >= 12 ? [255, 255, 255, 255] : want(l, x) }
          }
          ok("layers: 3 layers kept by a second pass (each loaded at its layer), a draw into the first, \(n) texels exact")
        }
      }
    } else {
      skip("layers: Layer from the vertex stage", "no shaderViewportIndexLayer")
    }
    // A clear of layers 1 and 2 of 3 inside a pass.
    if f.clearAttachments {
      let image = try image(.rgba8, Int32(w), Int32(h), layers: 3, usage: usage)
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(view: ImageView(image), load: .clear(0, 0, 1, 1))], layerCount: 3)) { r in
        r.clearAttachments([.color(index: 0, .float(1, 0, 0, 1))], rects: [ClearRect(x: 2, y: 2, width: 4, height: 4, baseLayer: 1, layerCount: 2)])
      }
      try run(list)
      var n = 0
      for l in 0..<3 {
        let px = try readLayer(GPUCommandList(), image, layer: UInt32(l), w, h)
        n += judge("layers clear: layer \(l)", px, w, h) { x, y in
          l >= 1 && x >= 2 && x < 6 && y >= 2 && y < 6 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
      }
      ok("layers: a rectangle of layers 1 and 2 of 3 cleared inside a pass, \(n) texels exact")
    }
    // A pass into a view of layer 1 and level 1 of an image of 2 layers and 2 levels: only that level of that layer changes.
    if f.mipmaps {
      let image = try image(.rgba8, Int32(w), Int32(h), mips: 2, layers: 2, usage: usage)
      var list = GPUCommandList()
      list.clear(image, color: .float(0, 0, 0, 1))
      let pso = try meshPipeline()
      let quarter = try meshBuffer([Rect(x0: 0, y0: 0, x1: 4, y1: 8, color: [0, 1, 0, 1])], width: 8, height: 8)
      let view = ImageView(image, dimension: .d2, baseMip: 1, mipCount: 1, baseLayer: 1, layerCount: 1)
      list.render(RenderingInfo(colors: [Attachment(view: view, load: .clear(1, 0, 0, 1))])) { r in
        r.draw(pso, root: quarter.address, vertices: 6)
      }
      try run(list)
      var n = 0
      for l in 0..<2 {
        for m in 0..<2 {
          let size = w >> m
          let px = try readLayer(GPUCommandList(), image, layer: UInt32(l), mip: UInt32(m), size, size)
          n += judge("view of a layer and a level: layer \(l), level \(m)", px, size, size) { x, _ in
            if l == 1 && m == 1 { return x < 4 ? [0, 255, 0, 255] : [255, 0, 0, 255] }
            return [0, 0, 0, 255]
          }
        }
      }
      ok("layers: a pass into a view of layer 1, level 1 (8 x 8) of an image of 2 layers and 2 levels, \(n) texels exact")
    }
  }

  // MARK: Multiview

  /// A multiview pass of views 1 and 3 (a mask with a gap) into an image of 4 layers that was black: each view's layer has its own
  /// rectangle (moved two pixels a view) and colour (red 20 times the view), and layers 0 and 2 stay black; then a second pass keeps
  /// the views (each loaded at its layer) and clears a corner inside the pass, in both views only.
  /// With `report`, a probe: a summary of what each layer reads is appended to `probeSummary` and nothing fails; true if every texel was
  /// exact.
  @discardableResult
  func multiview(mask: UInt32 = 0b1010, report: Bool = false) throws(GPUError) -> Bool {
    let f = d.limits.features
    guard f.multiview, d.limits.maxMultiviewViews >= 4, rgbaTarget, f.imageRegionCopies else {
      skip("multiview", "no multiview of 4 views")
      return false
    }
    let w = 16, h = 16
    let image = try image(.rgba8, Int32(w), Int32(h), layers: 4, usage: .renderTarget | .copySource | .copyDestination)
    let mesh = try meshBuffer([Rect(x0: 4, y0: 0, x1: 8, y1: 16, color: [0, 1, 0, 1])], width: Float(w), height: Float(h))
    let pso = try meshPipeline(vertex: LoinnirShaders.multiviewVert, viewMask: mask)
    var list = GPUCommandList()
    list.clear(image, color: .float(0, 0, 0, 1))
    list.render(RenderingInfo(colors: [Attachment(view: ImageView(image, dimension: .d2Array), load: .clear(0, 0, 1, 1))], viewMask: mask)) { r in
      r.draw(pso, root: mesh.address, vertices: 6)
    }
    try run(list)
    func want(_ l: Int, _ x: Int, _ y: Int, cleared: Bool) -> [UInt8] {
      if mask >> UInt32(l) & 1 == 0 { return [0, 0, 0, 255] }
      if cleared && x < 2 && y < 2 { return [255, 0, 0, 255] }
      return x >= 4 + 2 * l && x < 8 + 2 * l ? [UInt8(20 * l), 255, 0, 255] : [0, 0, 255, 255]
    }
    if report {
      var exact = true
      var line = " 0x" + String(mask, radix: 16) + ":"
      for l in 0..<4 {
        let px = try readLayer(GPUCommandList(), image, layer: UInt32(l), w, h)
        var wrong = 0
        var first = ""
        for y in 0..<h {
          for x in 0..<w where pixel(px, w, x, y) != want(l, x, y, cleared: false) {
            if wrong == 0 { first = " (\(x),\(y)) \(hex(pixel(px, w, x, y)))/\(hex(want(l, x, y, cleared: false)))" }
            wrong += 1
          }
        }
        if wrong != 0 { exact = false }
        line += " L\(l) \(wrong)\(first)"
      }
      probeSummary += line + ";"
      return exact
    }
    var n = 0
    for l in 0..<4 {
      let px = try readLayer(GPUCommandList(), image, layer: UInt32(l), w, h)
      n += judge("multiview: layer \(l)", px, w, h) { x, y in want(l, x, y, cleared: false) }
    }
    ok("multiview: views 1 and 3 (mask 0b1010) of 4 layers, each its own position and colour, layers 0 and 2 untouched, \(n) texels exact")
    if f.loadAttachments && f.clearAttachments {
      var again = GPUCommandList()
      again.render(RenderingInfo(colors: [Attachment(view: ImageView(image, dimension: .d2Array), load: .load)], viewMask: mask)) { r in
        r.clearAttachments([.color(index: 0, .float(1, 0, 0, 1))], rects: [ClearRect(x: 0, y: 0, width: 2, height: 2)])
      }
      try run(again)
      var k = 0
      for l in 0..<4 {
        let px = try readLayer(GPUCommandList(), image, layer: UInt32(l), w, h)
        k += judge("multiview kept: layer \(l)", px, w, h) { x, y in want(l, x, y, cleared: true) }
      }
      ok("multiview: the views kept by a second pass and a corner cleared inside it in both views only, \(k) texels exact")
    }
    return true
  }

  // MARK: Culling

  /// Two rectangles, one wound each way, drawn in four tiles of one target by a pipeline that culls back faces, front faces, none,
  /// and (with the other front face) back faces: what each tile shows follows from the winding.
  func cull() throws(GPUError) {
    guard f.cullModes, rgbaTarget else { return skip("cull", "no cull modes") }
    // `left` is wound the way a counter-clockwise-front pipeline calls a back face (on screen, y down, it runs clockwise).
    let left = Rect(x0: 2, y0: 2, x1: 14, y1: 14, color: [1, 0, 0, 1])
    var right = Rect(x0: 18, y0: 2, x1: 30, y1: 14, color: [0, 1, 0, 1])
    right.flip = true
    let mesh = try meshBuffer([left, right], width: 32, height: 16)
    let cases: [(CullMode, FrontFace, Bool, Bool)] = [
      (.back, .counterClockwise, false, true),   // only `right` is a front face
      (.front, .counterClockwise, true, false),  // only `left` is a back face
      (.none, .counterClockwise, true, true),
      (.back, .clockwise, true, false),
    ]
    var pipelines: [GPUPipeline] = []
    for c in cases {
      pipelines.append(try meshPipeline(rasterization: RasterizationState(cull: c.0, frontFace: c.1)))
    }
    let target = try colorTarget(64, 32)
    var list = GPUCommandList()
    let info = RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))])
    list.render(info) { r in
      for i in 0..<pipelines.count {
        r.setViewport(x: Float(i % 2 * 32), y: Float(i / 2 * 16), width: 32, height: 16)
        r.draw(pipelines[i], root: mesh.address, vertices: 12)
      }
    }
    let px = try readBack(list, target)
    var total = 0
    for i in 0..<cases.count {
      let c = cases[i]
      let ox = i % 2 * 32, oy = i / 2 * 16
      total += judge("cull (\(i))", px, 64, 32) { x, y in
        if x < ox || x >= ox + 32 || y < oy || y >= oy + 16 { return nil }
        if c.2 && left.contains(x - ox, y - oy) { return [255, 0, 0, 255] }
        if c.3 && right.contains(x - ox, y - oy) { return [0, 255, 0, 255] }
        return [0, 0, 255, 255]
      }
    }
    ok("cull: back, front, none and clockwise-front back culling, \(total) pixels exact")
  }

  // MARK: Blending

  struct BlendCase {
    var name: String
    var blend: ColorBlendAttachment
    var source: [Float]
    var constants: [Float] = [0, 0, 0, 0]
    var dynamicConstants = false
    var logic: LogicOp? = nil
    /// The fragment shader writes a second output, one minus the colour (dual.frag).
    var dual = false
  }

  func blendFactor(_ factor: BlendingFactor, _ i: Int, _ s: [Float], _ dst: [Float], _ c: [Float], dual: Bool = false) -> Float {
    let second = s.map { 1 - $0 }
    switch factor {
    case .src1Color: return dual ? second[i] : 0
    case .oneMinusSrc1Color: return dual ? 1 - second[i] : 0
    case .src1Alpha: return dual ? second[3] : 0
    case .oneMinusSrc1Alpha: return dual ? 1 - second[3] : 0
    case .zero: return 0
    case .one: return 1
    case .srcColor: return s[i]
    case .oneMinusSrcColor: return 1 - s[i]
    case .dstColor: return dst[i]
    case .oneMinusDstColor: return 1 - dst[i]
    case .srcAlpha: return s[3]
    case .oneMinusSrcAlpha: return 1 - s[3]
    case .dstAlpha: return dst[3]
    case .oneMinusDstAlpha: return 1 - dst[3]
    case .constantColor: return c[i]
    case .oneMinusConstantColor: return 1 - c[i]
    case .constantAlpha: return c[3]
    case .oneMinusConstantAlpha: return 1 - c[3]
    case .srcAlphaSaturate: return i == 3 ? 1 : min(s[3], 1 - dst[3])
    default: return 0
    }
  }

  func blendValue(_ op: BlendOp, _ sourceTerm: Float, _ destinationTerm: Float, _ s: Float, _ dst: Float) -> Float {
    var v: Float
    switch op {
    case .add: v = sourceTerm + destinationTerm
    case .subtract: v = sourceTerm - destinationTerm
    case .reverseSubtract: v = destinationTerm - sourceTerm
    case .min: v = min(s, dst)
    case .max: v = max(s, dst)
    }
    return min(max(v, 0), 1)
  }

  /// What the blend of `c` leaves where the target held `dst`, as bytes.
  func blended(_ c: BlendCase, _ dst: [Float]) -> [UInt8] {
    var out: [Float] = []
    let b = c.blend
    for i in 0..<4 {
      let colorChannel = i < 3
      let sf = blendFactor(colorChannel ? b.srcColor : b.srcAlpha, i, c.source, dst, c.constants, dual: c.dual)
      let df = blendFactor(colorChannel ? b.dstColor : b.dstAlpha, i, c.source, dst, c.constants, dual: c.dual)
      let v = blendValue(colorChannel ? b.colorOp : b.alphaOp, sf * c.source[i], df * dst[i], c.source[i], dst[i])
      let masked = (b.writeMask.rawValue >> UInt8(i)) & 1 != 0
      out.append(masked ? v : dst[i])
    }
    return bytes(out)
  }

  /// Several blend factors and operations, one in each 8 by 8 tile of a target cleared to one colour: the result of each against the
  /// formula, within 1 (the hardware rounds its own way). A logic operation is exact.
  func blend() throws(GPUError) {
    guard rgbaTarget, d.limits.formats(.rgba8).blendable else { return skip("blend", "rgba8 can't be blended into") }
    guard f.generalBlend else { return skip("blend", "only the two blend modes") }
    let dst: [Float] = [0.6, 0.4, 0.2, 1]
    func attach(_ sc: BlendingFactor, _ dc: BlendingFactor, _ co: BlendOp = .add, _ sa: BlendingFactor? = nil, _ da: BlendingFactor? = nil,
                _ ao: BlendOp? = nil, mask: ColorMask = .all) -> ColorBlendAttachment {
      ColorBlendAttachment(enabled: true, srcColor: sc, dstColor: dc, colorOp: co, srcAlpha: sa ?? sc, dstAlpha: da ?? dc, alphaOp: ao ?? co,
                           writeMask: mask)
    }
    let s1: [Float] = [0.8, 0.6, 0.4, 0.6]
    let s2: [Float] = [0.2, 0.1, 0.1, 0.4]
    var cases: [BlendCase] = [
      BlendCase(name: "alpha over", blend: .alphaOver, source: s1),
      BlendCase(name: "additive", blend: attach(.one, .one), source: [0.2, 0.3, 0.4, 0.3]),
      BlendCase(name: "multiply", blend: attach(.dstColor, .zero, .add, .dstAlpha, .zero), source: s1),
      BlendCase(name: "subtract", blend: attach(.one, .one, .subtract), source: s1),
      BlendCase(name: "reverse subtract", blend: attach(.one, .one, .reverseSubtract), source: s2),
      BlendCase(name: "min", blend: attach(.one, .one, .min), source: s1),
      BlendCase(name: "max", blend: attach(.one, .one, .max), source: s1),
      BlendCase(name: "source colour and one minus source colour", blend: attach(.srcColor, .oneMinusSrcColor), source: s1),
      BlendCase(name: "constant colour", blend: attach(.constantColor, .oneMinusConstantColor, .add, .constantAlpha, .oneMinusConstantAlpha),
                source: s1, constants: [0.25, 0.5, 0.75, 0.5]),
      BlendCase(name: "alpha saturate", blend: attach(.srcAlphaSaturate, .one), source: [0.5, 0.5, 0.5, 0.7]),
      BlendCase(name: "red and alpha only", blend: ColorBlendAttachment(enabled: false, writeMask: .red | .alpha), source: s1),
      BlendCase(name: "one minus destination alpha", blend: attach(.oneMinusDstAlpha, .dstAlpha), source: s1),
    ]
    if f.dynamicState {
      cases.append(BlendCase(name: "dynamic constants", blend: attach(.constantColor, .oneMinusConstantColor, .add, .constantAlpha, .oneMinusConstantAlpha),
                             source: s1, constants: [0.75, 0.25, 0.5, 0.25], dynamicConstants: true))
    }
    if f.logicOps {
      cases.append(BlendCase(name: "logic xor", blend: ColorBlendAttachment(enabled: false), source: s1, logic: .xor))
    }
    if f.dualSourceBlend {
      cases.append(BlendCase(name: "dual source colour", blend: attach(.one, .src1Color, .add, .one, .src1Alpha), source: s1, dual: true))
      cases.append(BlendCase(name: "dual source one minus second alpha", blend: attach(.src1Color, .oneMinusSrc1Alpha, .subtract), source: s2, dual: true))
    }
    var rects: [Rect] = []
    for c in cases { rects.append(Rect(x0: 0, y0: 0, x1: 8, y1: 8, color: c.source)) }
    let mesh = try meshBuffer(rects, width: 8, height: 8)
    // A device whose blend stage can't do an equation (Mali's fixed function has one multiplier: minimum, maximum, the saturated
    // source alpha and constants that differ among the channels an equation names need a blend shader) refuses that pipeline with
    // `.unsupported`; the case is then skipped, with the device's words, and the others are judged.
    var pipelines: [GPUPipeline?] = []
    var made = 0
    for c in cases {
      do throws(GPUError) {
        pipelines.append(try meshPipeline(
          attachmentBlends: [c.blend], logicOp: c.logic,
          blendConstants: BlendConstants(red: c.constants[0], green: c.constants[1], blue: c.constants[2], alpha: c.constants[3]),
          dynamic: c.dynamicConstants ? .blendConstants : DynamicStates(),
          fragment: c.dual ? LoinnirShaders.dualFrag : LoinnirShaders.meshFrag))
        made += 1
      } catch {
        guard case .unsupported(let why) = error else { throw error }
        pipelines.append(nil)
        skip("blend \(c.name)", "the device refuses: \(why)")
      }
    }
    guard made > 0 else { return }
    let columns = 4
    let rows = (cases.count + columns - 1) / columns
    let target = try colorTarget(Int32(columns * 8), Int32(rows * 8))
    var list = GPUCommandList()
    let info = RenderingInfo(colors: [Attachment(image: target, load: .clear(dst[0], dst[1], dst[2], dst[3]))])
    list.render(info) { r in
      for i in 0..<pipelines.count {
        guard let pso = pipelines[i] else { continue }
        r.setViewport(x: Float(i % columns * 8), y: Float(i / columns * 8), width: 8, height: 8)
        if cases[i].dynamicConstants {
          let k = cases[i].constants
          r.setBlendConstants(BlendConstants(red: k[0], green: k[1], blue: k[2], alpha: k[3]))
        }
        r.draw(pso, root: mesh.address, vertices: 6, firstVertex: UInt32(6 * i))
      }
    }
    let px = try readBack(list, target)
    let width = columns * 8
    for i in 0..<cases.count where pipelines[i] != nil {
      let ox = i % columns * 8, oy = i / columns * 8
      var want: [UInt8]
      var tolerance = 1
      if cases[i].logic != nil {
        let s = bytes(cases[i].source), dd = bytes(dst)
        want = [s[0] ^ dd[0], s[1] ^ dd[1], s[2] ^ dd[2], s[3] ^ dd[3]]
        tolerance = 0
      } else {
        want = blended(cases[i], dst)
      }
      let expected = want
      _ = judge("blend \(cases[i].name)", px, width, rows * 8, tolerance: tolerance) { x, y in
        x >= ox && x < ox + 8 && y >= oy && y < oy + 8 ? expected : nil
      }
    }
    ok("blend: \(made) of \(cases.count) factor and operation sets (alpha, additive, multiply, subtract, min, max, constants, saturate, write mask\(f.logicOps ? ", xor" : "")\(f.dualSourceBlend ? ", dual source" : "")), each tile within 1 of the formula")
  }

  // MARK: Sampling

  func params(_ m: GPUMemory, _ index: Int, texture: UInt32, sampler: UInt32, lod: Float = 0, w: Float = 0, direction: [Float] = [0, 0, 0, 0]) {
    let p = unsafe m.pointer!.advanced(by: index * 32)
    unsafe p.storeBytes(of: texture, toByteOffset: 0, as: UInt32.self)
    unsafe p.storeBytes(of: sampler, toByteOffset: 4, as: UInt32.self)
    unsafe p.storeBytes(of: lod, toByteOffset: 8, as: Float.self)
    unsafe p.storeBytes(of: w, toByteOffset: 12, as: Float.self)
    for i in 0..<4 { unsafe p.storeBytes(of: direction[i], toByteOffset: 16 + 4 * i, as: Float.self) }
  }

  func quadPipeline(_ fragment: [UInt8]) throws(GPUError) -> GPUPipeline {
    try d.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: LoinnirShaders.quadVert, fragment: fragment, colorFormats: [.rgba8], blend: .opaque))
  }

  /// Draws a quad in each of `count` 8 by 8 tiles of a row, the root of tile i the i-th of `table`'s 32 bytes, and reads the row back.
  func drawTiles(_ pso: GPUPipeline, _ table: GPUMemory, count: Int, before: GPUCommandList) throws(GPUError) -> [UInt8] {
    let target = try colorTarget(Int32(count * 8), 8)
    var list = before
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      for i in 0..<count {
        r.setViewport(x: Float(i * 8), y: 0, width: 8, height: 8)
        r.draw(pso, root: table.address + UInt64(32 * i), vertices: 6)
      }
    }
    return try readBack(list, target)
  }

  func tile(_ name: String, _ px: [UInt8], _ count: Int, tolerance: Int = 0, _ want: (Int) -> [UInt8]) -> Int {
    judge(name, px, count * 8, 8, tolerance: tolerance) { x, _ in want(x / 8) }
  }

  /// An 8 by 8 texture of four mip levels, each its own colour, sampled in a tile each at levels 0 to 3 by a sampler that takes the
  /// nearest level (exact), and at 1.5 by one that blends levels (the mean of levels 1 and 2, within 2).
  func mips() throws(GPUError) {
    guard f.mipmaps, f.sampledImages, rgbaTarget, d.limits.formats(.rgba8).sampled, d.limits.formats(.rgba8).filterable else {
      return skip("mips", "no mip levels or no sampling")
    }
    let levelColors: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 1, 1]]
    let texture = try image(.rgba8, 8, 8, mips: 4, usage: .sampled | .copyDestination)
    var list = GPUCommandList()
    for m in 0..<4 {
      let c = levelColors[m]
      list.clear(texture, color: .float(c[0], c[1], c[2], c[3]),
                 ranges: [ImageSubresourceRange(aspects: .color, baseMip: UInt32(m), mipCount: 1, baseLayer: 0, layerCount: 1)])
    }
    let slot = textureBase
    try d.writeTexture(slot, ImageView(texture))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    try d.writeSampler(2, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .linear))
    let table = try d.allocate(.upload, bytes: 32 * 5)
    for i in 0..<4 { params(table, i, texture: slot, sampler: 1, lod: Float(i)) }
    params(table, 4, texture: slot, sampler: 2, lod: 1.5)
    let pso = try quadPipeline(LoinnirShaders.lodFrag)
    let px = try drawTiles(pso, table, count: 5, before: list)
    var n = judge("mips", px, 40, 8) { x, _ in x < 32 ? bytes(levelColors[x / 8]) : nil }
    n += judge("mips (lod 1.5)", px, 40, 8, tolerance: 2) { x, _ in x >= 32 ? [0, 128, 127, 255] : nil }
    ok("mips: levels 0 to 3 by lod, exact, and lod 1.5 blended within 2, \(n) pixels")
  }

  /// A 4 by 4 by 4 texture whose slices are four colours, each read in a tile at its slice's depth, exactly.
  func volume() throws(GPUError) {
    guard f.volumeImages, f.sampledImages, rgbaTarget, d.limits.formats(.rgba8).sampled else { return skip("volume", "no 3D images") }
    var data: [UInt8] = []
    var slices: [[UInt8]] = []
    for k in 0..<4 {
      let c: [UInt8] = [UInt8((k + 1) * 60), UInt8(255 - k * 60), UInt8(k * 17), 255]
      slices.append(c)
      for _ in 0..<16 { data.append(contentsOf: c) }
    }
    let upload = try d.allocate(.upload, bytes: data.count)
    store(upload, bytes: data)
    let texture = try image(.rgba8, 4, 4, depth: 4, dimension: .d3, usage: .sampled | .copyDestination)
    var list = GPUCommandList()
    list.copy(upload, to: texture)
    let slot = textureBase + 1
    try d.writeTexture(slot, ImageView(texture))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let table = try d.allocate(.upload, bytes: 32 * 4)
    for k in 0..<4 { params(table, k, texture: slot, sampler: 1, w: (Float(k) + 0.5) / 4) }
    let pso = try quadPipeline(LoinnirShaders.volumeFrag)
    let px = try drawTiles(pso, table, count: 4, before: list)
    let n = tile("volume", px, 4) { i in slices[i] }
    ok("volume: a 4x4x4 texture read slice by slice, \(n) pixels exact")
  }

  /// A cube texture whose six faces are six colours, each read in a tile along its axis, exactly.
  func cube() throws(GPUError) {
    guard f.cubeImages, f.arrayImages, f.sampledImages, rgbaTarget, d.limits.formats(.rgba8).sampled else { return skip("cube", "no cube images") }
    let faces: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 0, 1], [1, 0, 1, 1], [0, 1, 1, 1]]
    let directions: [[Float]] = [[1, 0, 0, 0], [-1, 0, 0, 0], [0, 1, 0, 0], [0, -1, 0, 0], [0, 0, 1, 0], [0, 0, -1, 0]]
    let texture = try image(.rgba8, 4, 4, layers: 6, dimension: .cube, usage: .sampled | .copyDestination)
    var list = GPUCommandList()
    for i in 0..<6 {
      let c = faces[i]
      list.clear(texture, color: .float(c[0], c[1], c[2], c[3]),
                 ranges: [ImageSubresourceRange(aspects: .color, baseMip: 0, mipCount: 1, baseLayer: UInt32(i), layerCount: 1)])
    }
    let slot = textureBase + 2
    try d.writeTexture(slot, ImageView(texture))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let table = try d.allocate(.upload, bytes: 32 * 6)
    for i in 0..<6 { params(table, i, texture: slot, sampler: 1, direction: directions[i]) }
    let pso = try quadPipeline(LoinnirShaders.cubeFrag)
    let px = try drawTiles(pso, table, count: 6, before: list)
    let n = tile("cube", px, 6) { i in bytes(faces[i]) }
    ok("cube: six faces read along +x, -x, +y, -y, +z and -z, \(n) pixels exact")
  }

  /// A 1D texture of eight colours, read by a quad eight pixels wide: each pixel column is the texel of its own, exactly.
  func oneDimensional() throws(GPUError) {
    guard f.images1D, f.sampledImages, rgbaTarget, d.limits.formats(.rgba8).sampled else { return skip("1d", "no 1D images") }
    var data: [UInt8] = []
    var colors: [[UInt8]] = []
    for i in 0..<8 {
      let c: [UInt8] = [UInt8(i * 30 + 1), UInt8(255 - i * 20), UInt8(i * 7 + 5), 255]
      colors.append(c)
      data.append(contentsOf: c)
    }
    let upload = try d.allocate(.upload, bytes: data.count)
    store(upload, bytes: data)
    let texture = try image(.rgba8, 8, 1, dimension: .d1, usage: .sampled | .copyDestination)
    var list = GPUCommandList()
    list.copy(upload, to: texture)
    let slot = textureBase + 3
    try d.writeTexture(slot, ImageView(texture))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let table = try d.allocate(.upload, bytes: 32)
    params(table, 0, texture: slot, sampler: 1)
    let pso = try quadPipeline(LoinnirShaders.lookup1dFrag)
    let px = try drawTiles(pso, table, count: 1, before: list)
    let n = judge("1d", px, 8, 8) { x, _ in colors[x] }
    ok("1d: an 8-texel lookup table sampled by column, \(n) pixels exact")
  }

  /// A BGRA image read through an RGBA view that swaps red and blue: its bytes are (b, g, r, a) and the view reads the colours that
  /// were written, exactly, magnified two by two by a nearest sampler.
  func swizzle() throws(GPUError) {
    guard f.imageSwizzle, f.imageViews, f.sampledImages, rgbaTarget, d.limits.formats(.bgra8).sampled, d.limits.formats(.rgba8).sampled
    else { return skip("swizzle", "no mapped views") }
    var data: [UInt8] = []
    for y in 0..<4 {
      for x in 0..<4 {
        let c = pattern(x, y)
        data.append(contentsOf: [c[2], c[1], c[0], c[3]])
      }
    }
    let upload = try d.allocate(.upload, bytes: data.count)
    store(upload, bytes: data)
    let texture = try image(.bgra8, 4, 4, usage: .sampled | .copyDestination)
    var list = GPUCommandList()
    list.copy(upload, to: texture)
    let slot = textureBase + 4
    try d.writeTexture(slot, ImageView(texture, format: .rgba8, swizzle: ComponentMapping(r: .b, b: .r)))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let table = try d.allocate(.upload, bytes: 32)
    params(table, 0, texture: slot, sampler: 1)
    let pso = try quadPipeline(LoinnirShaders.lodFrag)
    let px = try drawTiles(pso, table, count: 1, before: list)
    let n = judge("swizzle", px, 8, 8) { x, y in pattern(x / 2, y / 2) }
    ok("swizzle: a BGRA image read through an RGBA view with red and blue swapped, \(n) pixels exact")
  }

  /// A red 4 by 4 texture sampled over three times its width with a border colour of the sampler's own: the outer thirds are
  /// that colour (within 1), and the middle is the texture's, exactly.
  func customBorder() throws(GPUError) {
    guard f.samplerBorder, f.sampledImages, rgbaTarget, d.limits.formats(.rgba8).sampled else { return skip("border", "no border colours") }
    guard f.customBorderColor else {
      return skip("custom border", "the device has no custom border colours (VK_EXT_custom_border_color); the Vulkan under Venus offers no device extensions")
    }
    var data: [UInt8] = []
    for _ in 0..<16 { data.append(contentsOf: [255, 0, 0, 255]) }
    let upload = try d.allocate(.upload, bytes: data.count)
    store(upload, bytes: data)
    let texture = try image(.rgba8, 4, 4, usage: .sampled | .copyDestination)
    var list = GPUCommandList()
    list.copy(upload, to: texture)
    let slot = textureBase + 5
    try d.writeTexture(slot, ImageView(texture))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToBorder, mipmapMode: .nearest,
                                            customBorderColor: .float(0.25, 0.5, 0.75, 1)))
    let table = try d.allocate(.upload, bytes: 32)
    params(table, 0, texture: slot, sampler: 1)
    let pso = try quadPipeline(LoinnirShaders.borderFrag)
    let px = try drawTiles(pso, table, count: 1, before: list)
    var n = judge("custom border", px, 8, 8, tolerance: 1) { x, _ in x < 2 || x > 5 ? [64, 128, 191, 255] : nil }
    n += judge("custom border (inside)", px, 8, 8) { x, _ in x == 3 || x == 4 ? [255, 0, 0, 255] : nil }
    ok("custom border: the outer columns are the sampler's own colour (0.25, 0.5, 0.75, 1) within 1 and the middle is the texture's, \(n) pixels")
  }

  /// A uniform texel buffer fetched from and a storage one stored to and given an atomic add, by one compute shader through the
  /// heap's texel-buffer arrays: dst[i] = src[i] * 3 + i + 1, read back from the buffer's own memory, exactly.
  func texelBuffers() throws(GPUError) {
    let c = d.limits.formats(.r32uint)
    guard f.uniformTexelBuffers, f.storageTexelBuffers, c.texelBuffer, c.storageTexelBuffer, c.storageTexelBufferAtomic else {
      return skip("texel buffers", "no texel buffers of r32uint")
    }
    let source = try d.allocate(.upload, bytes: 64)
    let target = try d.allocate(.readback, bytes: 64)
    var words: [UInt32] = []
    for i in 0..<16 { words.append(UInt32(i * 11 + 2)) }
    let p = unsafe source.pointer!.assumingMemoryBound(to: UInt32.self)
    let q = unsafe target.pointer!.assumingMemoryBound(to: UInt32.self)
    for i in 0..<16 {
      unsafe p[i] = words[i]
      unsafe q[i] = 0xDEAD_BEEF
    }
    try d.writeTexelBuffer(0, BufferView(source, format: .r32uint))
    try d.writeStorageTexelBuffer(0, BufferView(target, format: .r32uint))
    let pso = try d.makeComputePipeline(spirv: LoinnirShaders.texelbufferComp)
    var list = GPUCommandList()
    list.dispatch(pso, root: 0, x: 1, y: 1, z: 1)
    try run(list)
    var wrong = 0
    for i in 0..<16 {
      let got = unsafe q[i]
      if got != words[i] &* 3 &+ UInt32(i) &+ 1 { wrong += 1 }
    }
    if wrong != 0 {
      let first = unsafe q[0]
      fail("texel buffers: \(wrong) of 16 texels wrong, the first is \(first), expected \(words[0] * 3 + 1)")
    }
    ok("texel buffers: 16 texels fetched, stored and given an atomic add through the heap, exact")
  }

  // MARK: Copies, blits and clears

  /// An 8 by 8 pattern: red by column, green by row, blue by their sum.
  func pattern(_ x: Int, _ y: Int) -> [UInt8] { [UInt8(x * 32), UInt8(y * 32), UInt8((x + y) * 16), 255] }

  func patternData() -> [UInt8] {
    var data: [UInt8] = []
    for y in 0..<8 { for x in 0..<8 { data.append(contentsOf: pattern(x, y)) } }
    return data
  }

  func copyUsage() -> ImageUsage { .copySource | .copyDestination }

  /// `copyImage` of a region onto another image at another offset, and what it leaves alone.
  func copyRegion() throws(GPUError) {
    guard f.copyImage, f.clearImage else { return skip("copy region", "no image copies or clears") }
    let upload = try d.allocate(.upload, bytes: 256)
    store(upload, bytes: patternData())
    let a = try image(.rgba8, 8, 8, usage: copyUsage())
    let b = try image(.rgba8, 8, 8, usage: copyUsage())
    var list = GPUCommandList()
    list.copy(upload, to: a)
    list.clear(b, color: .float(0, 0, 0, 1))
    list.copyImage(a, to: b, regions: [ImageCopyRegion(srcOffset: Offset3D(x: 2, y: 2), dstOffset: Offset3D(x: 1, y: 3),
                                                       extent: Extent3D(width: 4, height: 4))])
    let px = try readBack(list, b)
    let n = judge("copy region", px, 8, 8) { x, y in
      if x >= 1 && x < 5 && y >= 3 && y < 7 { return pattern(x - 1 + 2, y - 3 + 2) }
      return [0, 0, 0, 255]
    }
    ok("copy region: a 4x4 region of an image placed at another offset, \(n) pixels exact")
  }

  /// `blitImage` at twice the size with nearest filtering, and flipped.
  func blit() throws(GPUError) {
    guard f.blitImage, d.limits.formats(.rgba8).blitSource, d.limits.formats(.rgba8).blitDestination else { return skip("blit", "no image blits") }
    let upload = try d.allocate(.upload, bytes: 256)
    store(upload, bytes: patternData())
    let a = try image(.rgba8, 8, 8, usage: copyUsage())
    let big = try image(.rgba8, 16, 16, usage: copyUsage())
    let flipped = try image(.rgba8, 8, 8, usage: copyUsage())
    var list = GPUCommandList()
    list.copy(upload, to: a)
    list.blitImage(a, to: big, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMax: Offset3D(x: 16, y: 16, z: 1))],
                   filter: .nearest)
    list.blitImage(a, to: flipped, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMin: Offset3D(x: 8, y: 0, z: 0),
                                                             dstMax: Offset3D(x: 0, y: 8, z: 1))], filter: .nearest)
    let bigPixels = try readBack(list, big)
    let flippedPixels = try readBack(GPUCommandList(), flipped)
    var n = judge("blit 2x", bigPixels, 16, 16) { x, y in pattern(x / 2, y / 2) }
    n += judge("blit flipped", flippedPixels, 8, 8) { x, y in pattern(7 - x, y) }
    ok("blit: 8x8 to 16x16 nearest and flipped horizontally, \(n) pixels exact")
  }

  /// Clears of images, in a pass, and of a buffer, with a fill and an update.
  func clears() throws(GPUError) {
    if f.clearImage {
      let image = try image(.rgba8, 4, 4, usage: copyUsage())
      var list = GPUCommandList()
      list.clear(image, color: .float(0.2, 0.4, 0.6, 0.8))
      let px = try readBack(list, image)
      let n = judge("clear image", px, 4, 4) { _, _ in [51, 102, 153, 204] }
      ok("clears: an image cleared to 0.2, 0.4, 0.6, 0.8, \(n) pixels exact")
    } else {
      skip("clears: an image", "no image clears")
    }
    if f.clearAttachments, rgbaTarget {
      let target = try colorTarget(8, 8)
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))])) { r in
        r.clearAttachments([.color(index: 0, .float(1, 0, 0, 1))], rects: [ClearRect(x: 2, y: 2, width: 4, height: 4)])
      }
      let px = try readBack(list, target)
      let n = judge("clear attachments", px, 8, 8) { x, y in x >= 2 && x < 6 && y >= 2 && y < 6 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
      ok("clears: a rectangle of a pass's attachment cleared inside the pass, \(n) pixels exact")
    } else {
      skip("clears: attachments inside a pass", "no clear attachments")
    }
    if f.fillBuffer && f.updateBuffer {
      let device = try d.allocate(.device, bytes: 64)
      let readback = try d.allocate(.readback, bytes: 64)
      var list = GPUCommandList()
      list.fill(device, bytes: 64, value: 0xAABB_CCDD)
      // Barriers between the transfers: the core's lists order work only where they say to (D58).
      list.barrier(from: .transfer, to: .transfer)
      list.update(device, offset: 16, data: [1, 2, 3, 4, 5, 6, 7, 8])
      list.barrier(from: .transfer, to: .transfer)
      list.copy(device, to: readback, bytes: 64)
      try run(list)
      let b = read(readback, 64)
      for i in 0..<64 {
        let want: UInt8 = i >= 16 && i < 24 ? UInt8(i - 15) : [0xDD, 0xCC, 0xBB, 0xAA][i % 4]
        if b[i] != want { fail("fill and update: byte \(i) is \(b[i]), expected \(want)") }
      }
      ok("clears: a buffer filled with a word and 8 bytes updated in it, 64 bytes exact")
    } else {
      skip("clears: a buffer", "no fill or update")
    }
    if f.imageRegionCopies {
      // Rows of 12 texels in the buffer, a 6 by 3 region placed at (2, 1) of an 8 by 8 image, and read back with rows of 8.
      var rows: [UInt8] = []
      for y in 0..<3 { for x in 0..<12 { rows.append(contentsOf: [UInt8(x * 10), UInt8(y * 50), 7, 255]) } }
      let upload = try d.allocate(.upload, bytes: rows.count)
      store(upload, bytes: rows)
      let readback = try d.allocate(.readback, bytes: 256)
      let image = try image(.rgba8, 8, 8, usage: copyUsage())
      var list = GPUCommandList()
      list.clear(image, color: .float(0, 0, 0, 1))
      list.copy(upload, to: image, regions: [BufferImageRegion(bufferRowLength: 12, imageOffset: Offset3D(x: 2, y: 1),
                                                               imageExtent: Extent3D(width: 6, height: 3))])
      list.copy(image, to: readback, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8))])
      try run(list)
      let px = read(readback, 256)
      let n = judge("buffer image regions", px, 8, 8) { x, y in
        if x >= 2 && x < 8 && y >= 1 && y < 4 { return [UInt8((x - 2) * 10), UInt8((y - 1) * 50), 7, 255] }
        return [0, 0, 0, 255]
      }
      ok("clears: a 6x3 region copied in from a buffer of 12-texel rows and out again, \(n) pixels exact")
    } else {
      skip("copy region: buffer and image", "no image copies with regions")
    }
  }

  // MARK: Run

  func lap(_ name: String, _ since: Int64) {
    print("loinnir-test: core case \(name) took \((Clock.monotonic() - since) / 1_000_000) ms")
  }

  func runAll() {
    let start = Clock.monotonic()
    describe()
    var t = Clock.monotonic()
    do throws(GPUError) { try depth() } catch { caught("depth", error) }
    lap("depth", t)
    t = Clock.monotonic()
    do throws(GPUError) { try stencil() } catch { caught("stencil", error) }
    lap("stencil", t)
    t = Clock.monotonic()
    do throws(GPUError) { try depth(kept: true) } catch { caught("depth kept", error) }
    do throws(GPUError) { try stencil(kept: true) } catch { caught("stencil kept", error) }
    lap("depth and stencil kept", t)
    t = Clock.monotonic()
    do throws(GPUError) { try msaa() } catch { caught("msaa", error) }
    lap("msaa", t)
    t = Clock.monotonic()
    do throws(GPUError) { try layers() } catch { caught("layers", error) }
    do throws(GPUError) { try multiview() } catch { caught("multiview", error) }
    do throws(GPUError) { try cull() } catch { caught("cull", error) }
    lap("cull", t)
    t = Clock.monotonic()
    do throws(GPUError) { try blend() } catch { caught("blend", error) }
    lap("blend", t)
    t = Clock.monotonic()
    do throws(GPUError) { try mips() } catch { caught("mips", error) }
    lap("mips", t)
    t = Clock.monotonic()
    do throws(GPUError) { try volume() } catch { caught("volume", error) }
    lap("volume", t)
    t = Clock.monotonic()
    do throws(GPUError) { try cube() } catch { caught("cube", error) }
    lap("cube", t)
    t = Clock.monotonic()
    do throws(GPUError) { try oneDimensional() } catch { caught("1d", error) }
    do throws(GPUError) { try swizzle() } catch { caught("swizzle", error) }
    do throws(GPUError) { try customBorder() } catch { caught("custom border", error) }
    do throws(GPUError) { try texelBuffers() } catch { caught("texel buffers", error) }
    lap("1d, swizzle, custom border and texel buffers", t)
    t = Clock.monotonic()
    elsewhereCases()
    lap("viewports and sparse resources", t)
    t = Clock.monotonic()
    do throws(GPUError) { try copyRegion() } catch { caught("copy region", error) }
    do throws(GPUError) { try blit() } catch { caught("blit", error) }
    do throws(GPUError) { try clears() } catch { caught("clears", error) }
    lap("copies, blits and clears", t)
    transferCases()
    t = Clock.monotonic()
    pipelineCases()
    lap("pipeline state", t)
    // The Mali backend's resources (ResourceCases.swift): they all run, and the run ends in a failure if a check failed.
    if d.backend.utf8.elementsEqual("mali".utf8) {
      resourceCases()
      if softFailures != 0 { fail("\(softFailures) checks of the resource cases failed") }
    }
    print("loinnir-test: core cases: \(passed) passed, \(skipped) skipped, \((Clock.monotonic() - start) / 1_000_000) ms")
  }
}
