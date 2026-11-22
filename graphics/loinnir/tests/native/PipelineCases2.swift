// SPDX-License-Identifier: BSD-3-Clause

// More of loinnir-test's pipeline-state cases on the Mali backend (PipelineCases.swift has the first): the blend constant, several
// colour targets, a fragment shader that writes the depth or discards, and two-sided stencil. They judge as PipelineCases does
// (every case speaks, the run ends after them all).

import GPUCore
import Sys

extension CoreCases {
  /// The blend constant with the same value in every channel (the hardware has one scalar), static and set by the pass: source
  /// times the constant plus destination times one minus it.
  func constantCases() throws(GPUError) -> Int {
    guard f.generalBlend else { skip("blend constants", "no general blend"); return 0 }
    var failed = 0
    let dst: [Float] = [0.6, 0.4, 0.2, 0.8]
    let src: [Float] = [0.8, 0.6, 0.4, 0.6]
    let blend = ColorBlendAttachment(enabled: true, srcColor: .constantColor, dstColor: .oneMinusConstantColor, colorOp: .add,
                                     srcAlpha: .constantAlpha, dstAlpha: .oneMinusConstantAlpha, alphaOp: .add)
    let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 8, y1: 8, color: src), Rect(x0: 0, y0: 0, x1: 8, y1: 8, color: src)], width: 8, height: 8)
    let staticK = BlendConstants(red: 0.25, green: 0.25, blue: 0.25, alpha: 0.25)
    let dynamicK = BlendConstants(red: 0.75, green: 0.75, blue: 0.75, alpha: 0.75)
    let a = try meshPipeline(attachmentBlends: [blend], blendConstants: staticK)
    let b = try meshPipeline(attachmentBlends: [blend], dynamic: .blendConstants)
    let target = try colorTarget(16, 8)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(dst[0], dst[1], dst[2], dst[3]))])) { c in
      c.setViewport(x: 0, y: 0, width: 8, height: 8)
      c.draw(a, root: mesh.address, vertices: 6)
      c.setViewport(x: 8, y: 0, width: 8, height: 8)
      c.setBlendConstants(dynamicK)
      c.draw(b, root: mesh.address, vertices: 6, firstVertex: 6)
    }
    let px = try readBack(list, target)
    func mix(_ k: Float) -> [UInt8] { bytes((0..<4).map { src[$0] * k + dst[$0] * (1 - k) }) }
    let left = mix(0.25), right = mix(0.75)
    failed += softJudge("blend constants: static 0.25 and set by the pass 0.75, within 1", px, 16, 8, tolerance: 1) { x, _ in x < 8 ? left : right }
    return failed
  }

  /// Three colour targets written by one shader's three outputs (the same, reversed, half), the second added to what it held and
  /// the third written in green only; and eight targets, five of them not written, which keep their clears.
  func targetCases() throws(GPUError) -> Int {
    guard f.multipleColorAttachments, d.limits.maxColorAttachments >= 3 else {
      skip("multiple colour targets", "no multiple colour attachments")
      return 0
    }
    var failed = 0
    let src: [Float] = [0.4, 0.2, 0.6, 1]
    let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 8, y1: 8, color: src)], width: 8, height: 8)
    let clears: [[Float]] = [[0, 0, 1, 1], [0.1, 0.2, 0.3, 0.5], [0.9, 0.8, 0.7, 0.6]]
    for count in [3, 8] {
      let name = count == 3 ? "three" : "eight"
      var blends: [ColorBlendAttachment] = [.opaque, .alphaOver, .opaque]
      for _ in 3..<max(count, 3) { blends.append(.opaque) }
      let pso = try d.makeGraphicsPipeline(GraphicsPipelineDescriptor(
        vertex: LoinnirShaders.meshVert, fragment: LoinnirShaders.mrtFrag, colorFormats: [PixelFormat](repeating: .rgba8, count: count),
        blend: .opaque, attachmentBlends: blends))
      var targets: [GPUImage] = []
      var attachments: [Attachment] = []
      var starts: [[Float]] = []
      for i in 0..<count {
        let t = try colorTarget(8, 8)
        targets.append(t)
        let c: [Float] = i < 3 ? clears[i] : [Float(i) / 8, 0.5, 0.25, 1]
        starts.append(c)
        attachments.append(Attachment(image: t, load: .clear(c[0], c[1], c[2], c[3])))
      }
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: attachments)) { c in c.draw(pso, root: mesh.address, vertices: 6) }
      var reads: [GPUMemory] = []
      for t in targets {
        let m = try d.allocate(.readback, bytes: 8 * 8 * 4)
        list.copy(t, to: m)
        reads.append(m)
      }
      try run(list)
      let out1: [Float] = [src[2], src[1], src[0], 1]
      let out2: [Float] = src.map { $0 * 0.5 }
      for i in 0..<count {
        let px = read(reads[i], 8 * 8 * 4)
        let c = starts[i]
        var want = c
        if i == 0 { want = src }
        if i == 1 { want = out1 }
        if i == 2 { want = out2 }
        let w = bytes(want)
        failed += softJudge("\(name) colour targets: target \(i)", px, 8, 8, tolerance: 1) { _, _ in w }
      }
    }
    return failed
  }

  /// A fragment shader that writes the depth, and one that discards: the depth test and update are late, so the shader's depth is
  /// the one tested and a discarded fragment leaves the depth alone.
  func lateDepthCases() throws(GPUError) -> Int {
    guard f.depth, let format = depthFormat() else { skip("late depth", "no depth"); return 0 }
    var failed = 0
    let ds = DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .less)
    do throws(GPUError) {
      let first = try meshPipeline(depthFormat: format, depthStencil: ds)
      let late = try d.makeGraphicsPipeline(GraphicsPipelineDescriptor(
        vertex: LoinnirShaders.meshVert, fragment: LoinnirShaders.depthwriteFrag, colorFormats: [.rgba8], blend: .opaque,
        depthStencilFormat: format, depthStencil: ds))
      // Tile 0: geometry at 0.9 (it would fail) with the shader's depth 0.3 (passes): green. Tile 1: geometry at 0.1 with the shader's
      // depth 0.7: stays red.
      let mesh = try meshBuffer([
        Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.5, zRight: 0.5, color: [1, 0, 0, 1]),
        Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.9, zRight: 0.9, color: [0, 1, 0, 0.3]),
        Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.1, zRight: 0.1, color: [0, 1, 0, 0.7]),
      ], width: 4, height: 4)
      let target = try colorTarget(8, 4)
      let depth = try image(format, 8, 4, usage: .depthStencilTarget)
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))],
                                depthStencil: DepthStencilAttachment(image: depth, clearDepth: 1))) { c in
        for i in 0..<2 {
          c.setViewport(x: Float(i * 4), y: 0, width: 4, height: 4)
          c.draw(first, root: mesh.address, vertices: 6, firstVertex: 0)
          c.draw(late, root: mesh.address, vertices: 6, firstVertex: UInt32(6 * (i + 1)))
        }
      }
      let px = try readBack(list, target)
      failed += softJudge("depth written by the fragment shader decides the test", px, 8, 4) { x, _ in x < 4 ? Self.green : Self.red }
    } catch { caughtCase("shader depth", error); failed += 1 }
    do throws(GPUError) {
      let first = try meshPipeline(depthFormat: format, depthStencil: ds)
      let discarding = try d.makeGraphicsPipeline(GraphicsPipelineDescriptor(
        vertex: LoinnirShaders.meshVert, fragment: LoinnirShaders.discardleftFrag, colorFormats: [.rgba8], blend: .opaque,
        depthStencilFormat: format, depthStencil: ds))
      let mesh = try meshBuffer([
        Rect(x0: 0, y0: 0, x1: 8, y1: 8, zLeft: 0.5, zRight: 0.5, color: [1, 0, 0, 1]),
        Rect(x0: 0, y0: 0, x1: 8, y1: 8, zLeft: 0.4, zRight: 0.4, color: [0, 1, 0, 1]),
        Rect(x0: 0, y0: 0, x1: 8, y1: 8, zLeft: 0.45, zRight: 0.45, color: [1, 1, 1, 1]),
      ], width: 8, height: 8)
      let target = try colorTarget(8, 8)
      let depth = try image(format, 8, 8, usage: .depthStencilTarget)
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))],
                                depthStencil: DepthStencilAttachment(image: depth, clearDepth: 1))) { c in
        c.draw(first, root: mesh.address, vertices: 6, firstVertex: 0)
        c.draw(discarding, root: mesh.address, vertices: 6, firstVertex: 6)
        c.draw(first, root: mesh.address, vertices: 6, firstVertex: 12)
      }
      let px = try readBack(list, target)
      failed += softJudge("a discarded fragment leaves the depth alone: the next rectangle shows where it was", px, 8, 8) { x, _ in
        x < 4 ? [255, 255, 255, 255] : Self.green
      }
    } catch { caughtCase("discard and depth", error); failed += 1 }
    return failed
  }

  /// A stencil test with different operations, masks and references for the faces: a front-facing rectangle (the flipped one) replaces with 0x35, a
  /// back-facing one with 0x5A under a write mask of 0x0F (so 0x0A), and two full-target draws pass where the stencil equals each.
  func stencilFaceCases() throws(GPUError) -> Int {
    guard f.stencil, f.depth, d.limits.formats(.stencil8).depthTarget else { skip("two-sided stencil", "no stencil"); return 0 }
    var failed = 0
    do throws(GPUError) {
      let none = [ColorBlendAttachment(writeMask: ColorMask(rawValue: 0))]
      func two(front: StencilFaceState, back: StencilFaceState) -> DepthStencilState { DepthStencilState(stencilTest: true, front: front, back: back) }
      let write = try meshPipeline(depthFormat: .stencil8, depthStencil: two(
        front: StencilFaceState(failOp: .keep, passOp: .replace, depthFailOp: .keep, compare: .always, compareMask: 0xFF, writeMask: 0xFF, reference: 0x35),
        back: StencilFaceState(failOp: .keep, passOp: .replace, depthFailOp: .keep, compare: .always, compareMask: 0xFF, writeMask: 0x0F, reference: 0x5A)),
        attachmentBlends: none)
      func equal(_ v: UInt32) -> StencilFaceState {
        StencilFaceState(failOp: .keep, passOp: .keep, depthFailOp: .keep, compare: .equal, compareMask: 0xFF, writeMask: 0xFF, reference: v)
      }
      let isFirst = try meshPipeline(depthFormat: .stencil8, depthStencil: two(front: equal(0x35), back: equal(0x35)))
      let isSecond = try meshPipeline(depthFormat: .stencil8, depthStencil: two(front: equal(0x0A), back: equal(0x0A)))
      var flipped = Rect(x0: 18, y0: 2, x1: 30, y1: 14, color: [1, 1, 1, 1])
      flipped.flip = true
      let mesh = try meshBuffer([
        Rect(x0: 2, y0: 2, x1: 14, y1: 14, color: [1, 1, 1, 1]), flipped,
        Rect(x0: 0, y0: 0, x1: 32, y1: 16, color: [0, 1, 0, 1]), Rect(x0: 0, y0: 0, x1: 32, y1: 16, color: [1, 0, 0, 1]),
      ], width: 32, height: 16)
      let target = try colorTarget(32, 16)
      let stencil = try image(.stencil8, 32, 16, usage: .depthStencilTarget)
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))],
                                depthStencil: DepthStencilAttachment(image: stencil, clearDepth: 1, clearStencil: 0))) { c in
        c.draw(write, root: mesh.address, vertices: 12)
        c.draw(isFirst, root: mesh.address, vertices: 6, firstVertex: 12)
        c.draw(isSecond, root: mesh.address, vertices: 6, firstVertex: 18)
      }
      let px = try readBack(list, target)
      failed += softJudge("stencil faces: front replaces 0x35, back replaces 0x5A under a write mask of 0x0F", px, 32, 16) { x, y in
        if x >= 2 && x < 14 && y >= 2 && y < 14 { return Self.red }  // wound as a counter-clockwise-front pipeline's back face
        if x >= 18 && x < 30 && y >= 2 && y < 14 { return Self.green }
        return Self.blue
      }
    } catch { caughtCase("two-sided stencil", error); failed += 1 }
    return failed
  }
}
