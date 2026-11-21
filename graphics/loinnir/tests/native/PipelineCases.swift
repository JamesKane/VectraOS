// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's cases for the core's pipeline state on the Mali backend (D174's amendment, step 3; gpucore(2)): the scissor,
// the topologies (points, lines, strips, fans, primitive restart), line width, every depth compare, depth bias and clamp,
// and rasterizer discard. Each draws pixel-aligned shapes and judges exactly where the hardware's rules are exact (a pixel an
// edge's rule decides is not judged). Unlike CoreCases, a case that disagrees doesn't end the run: it says which pixels,
// and the run ends after every case has spoken, so one run on the board shows everything. They are the core's own
// commands on whatever device they are given; a feature the device lacks skips the case.

import GPUCore
import Sys

extension CoreCases {
  /// The vertex of mesh.vert: a position and a colour, 32 bytes.
  struct Vertex {
    var x: Float, y: Float, z: Float = 0.5
    var color: [Float]
  }

  func rawMesh(_ list: [Vertex], width: Float, height: Float) throws(GPUError) -> GPUMemory {
    var v: [Float] = []
    for p in list {
      v.append(p.x / width * 2 - 1)
      v.append(p.y / height * 2 - 1)
      v.append(p.z)
      v.append(1)
      v.append(contentsOf: p.color)
    }
    let m = try d.allocate(.upload, bytes: max(v.count, 1) * 4)
    store(m, floats: v)
    return m
  }

  /// Like `judge`, but says what it found and goes on: the number of pixels wrong, and the first.
  func softJudge(_ name: String, _ px: [UInt8], _ width: Int, _ height: Int, tolerance: Int = 0, _ want: (Int, Int) -> [UInt8]?) -> Int {
    var judged = 0
    var wrong = 0
    var first = ""
    for y in 0..<height {
      for x in 0..<width {
        guard let w = want(x, y) else { continue }
        judged += 1
        let p = pixel(px, width, x, y)
        if !near(p, w, tolerance) {
          wrong += 1
          if first.isEmpty { first = "(\(x), \(y)) reads \(hex(p)), expected \(hex(w))" }
        }
      }
    }
    if wrong == 0 {
      passed += 1
      print("loinnir-test: ok: pipeline: \(name), \(judged) pixels exact")
    } else {
      print("loinnir-test: MISMATCH: pipeline: \(name): \(wrong) of \(judged) pixels wrong, the first \(first)")
    }
    return wrong == 0 ? 0 : 1
  }

  static let blue: [UInt8] = [0, 0, 255, 255]
  static let red: [UInt8] = [255, 0, 0, 255]
  static let green: [UInt8] = [0, 255, 0, 255]

  func plain(_ topology: PrimitiveTopology = .triangleList, restart: Bool = false, raster: RasterizationState = RasterizationState(),
             dynamic: DynamicStates = DynamicStates()) throws(GPUError) -> GPUPipeline {
    try d.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: LoinnirShaders.meshVert, fragment: LoinnirShaders.meshFrag, colorFormats: [.rgba8], blend: .opaque, topology: topology,
      rasterization: raster, dynamic: dynamic, primitiveRestart: restart))
  }

  /// One pass over a fresh 32 by 32 target cleared to blue, and its pixels.
  func onePass(_ size: Int32 = 32, _ body: (inout GPUCommandList) -> Void) throws(GPUError) -> [UInt8] {
    let target = try colorTarget(size, size)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))]), body)
    return try readBack(list, target)
  }

  // MARK: Scissor

  func scissorCase() throws(GPUError) -> Int {
    let pso = try plain()
    let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 32, y1: 32, color: [0, 1, 0, 1])], width: 32, height: 32)
    let px = try onePass { r in
      r.setScissor(x: 8, y: 6, width: 16, height: 10)
      r.draw(pso, root: mesh.address, vertices: 6)
    }
    return softJudge("scissor: a full-target rectangle inside a 16 by 10 box", px, 32, 32) { x, y in
      x >= 8 && x < 24 && y >= 6 && y < 16 ? Self.green : Self.blue
    }
  }

  // MARK: Topologies

  func topologyCases() throws(GPUError) -> Int {
    var failed = 0
    let r = Self.red, g = Self.green
    let rf: [Float] = [1, 0, 0, 1], gf: [Float] = [0, 1, 0, 1]
    // Points: each covers its pixel and no other.
    do throws(GPUError) {
      let pts: [(Float, Float)] = [(3.5, 4.5), (10.5, 10.5), (20.5, 5.5), (30.5, 30.5)]
      let mesh = try rawMesh(pts.map { Vertex(x: $0.0, y: $0.1, color: rf) }, width: 32, height: 32)
      let pso = try plain(.pointList)
      let px = try onePass { c in c.draw(pso, root: mesh.address, vertices: 4) }
      failed += softJudge("point list: four points, one pixel each", px, 32, 32) { x, y in
        for p in pts where Int(p.0) == x && Int(p.1) == y { return r }
        return Self.blue
      }
    } catch { caughtCase("point list", error); failed += 1 }
    // A horizontal line list segment, and a strip of two segments.
    do throws(GPUError) {
      let mesh = try rawMesh([Vertex(x: 2, y: 8.5, color: rf), Vertex(x: 14, y: 8.5, color: rf),
                              Vertex(x: 18, y: 20.5, color: gf), Vertex(x: 28, y: 20.5, color: gf)], width: 32, height: 32)
      let pso = try plain(.lineList)
      let px = try onePass { c in c.draw(pso, root: mesh.address, vertices: 4) }
      failed += softJudge("line list: two horizontal segments, the row of each", px, 32, 32) { x, y in
        if x >= 4 && x <= 12 { if y == 8 { return r }; if y == 7 || y == 9 { return Self.blue } }
        if x >= 20 && x <= 26 { if y == 20 { return g }; if y == 19 || y == 21 { return Self.blue } }
        if x >= 0 && x < 2 && y < 32 { return Self.blue }
        return nil
      }
    } catch { caughtCase("line list", error); failed += 1 }
    do throws(GPUError) {
      let mesh = try rawMesh([Vertex(x: 2, y: 4.5, color: rf), Vertex(x: 14.5, y: 4.5, color: rf), Vertex(x: 14.5, y: 20.5, color: rf)],
                             width: 32, height: 32)
      let pso = try plain(.lineStrip)
      let px = try onePass { c in c.draw(pso, root: mesh.address, vertices: 3) }
      failed += softJudge("line strip: a corner of two segments", px, 32, 32) { x, y in
        if y == 4 && x >= 4 && x <= 12 { return r }
        if x == 14 && y >= 7 && y <= 17 { return r }
        if y == 10 && x >= 4 && x <= 10 { return Self.blue }
        if x == 10 && y >= 8 && y <= 18 { return Self.blue }
        if x == 18 && y >= 8 && y <= 18 { return Self.blue }
        return nil
      }
    } catch { caughtCase("line strip", error); failed += 1 }
    // A strip and a fan of two triangles each cover a rectangle exactly.
    do throws(GPUError) {
      let mesh = try rawMesh([Vertex(x: 4, y: 4, color: gf), Vertex(x: 20, y: 4, color: gf), Vertex(x: 4, y: 20, color: gf),
                              Vertex(x: 20, y: 20, color: gf)], width: 32, height: 32)
      let pso = try plain(.triangleStrip)
      let px = try onePass { c in c.draw(pso, root: mesh.address, vertices: 4) }
      failed += softJudge("triangle strip: four vertices, a rectangle", px, 32, 32) { x, y in x >= 4 && x < 20 && y >= 4 && y < 20 ? g : Self.blue }
    } catch { caughtCase("triangle strip", error); failed += 1 }
    do throws(GPUError) {
      let mesh = try rawMesh([Vertex(x: 4, y: 4, color: gf), Vertex(x: 20, y: 4, color: gf), Vertex(x: 20, y: 20, color: gf),
                              Vertex(x: 4, y: 20, color: gf)], width: 32, height: 32)
      let pso = try plain(.triangleFan)
      let px = try onePass { c in c.draw(pso, root: mesh.address, vertices: 4) }
      failed += softJudge("triangle fan: four vertices, a rectangle", px, 32, 32) { x, y in x >= 4 && x < 20 && y >= 4 && y < 20 ? g : Self.blue }
    } catch { caughtCase("triangle fan", error); failed += 1 }
    // Primitive restart: two strips in one indexed draw, 16 and 32 bit indices; with no gap the strips would join.
    for wide in [false, true] {
      let name = wide ? "uint32" : "uint16"
      do throws(GPUError) {
        let mesh = try rawMesh([Vertex(x: 2, y: 2, color: rf), Vertex(x: 10, y: 2, color: rf), Vertex(x: 2, y: 10, color: rf),
                                Vertex(x: 10, y: 10, color: rf), Vertex(x: 16, y: 16, color: gf), Vertex(x: 28, y: 16, color: gf),
                                Vertex(x: 16, y: 28, color: gf), Vertex(x: 28, y: 28, color: gf)], width: 32, height: 32)
        let indices = try d.allocate(.upload, bytes: 64)
        let order: [UInt32] = [0, 1, 2, 3, wide ? 0xFFFF_FFFF : 0xFFFF, 4, 5, 6, 7]
        var bytes: [UInt8] = []
        for i in order {
          bytes.append(UInt8(truncatingIfNeeded: i))
          bytes.append(UInt8(truncatingIfNeeded: i >> 8))
          if wide {
            bytes.append(UInt8(truncatingIfNeeded: i >> 16))
            bytes.append(UInt8(truncatingIfNeeded: i >> 24))
          }
        }
        store(indices, bytes: bytes)
        let pso = try plain(.triangleStrip, restart: true)
        let px = try onePass { c in
          c.drawIndexed(pso, root: mesh.address, indices: indices, indexType: wide ? .uint32 : .uint16, count: UInt32(order.count))
        }
        failed += softJudge("primitive restart: two strips of \(name) indices, nothing between them", px, 32, 32) { x, y in
          if x >= 2 && x < 10 && y >= 2 && y < 10 { return r }
          if x >= 16 && x < 28 && y >= 16 && y < 28 { return g }
          return Self.blue
        }
      } catch { caughtCase("primitive restart \(name)", error); failed += 1 }
    }
    return failed
  }

  func caughtCase(_ name: String, _ e: GPUError) {
    switch e {
    case .unsupported(let why): print("loinnir-test: skip: pipeline: \(name): the device refuses: \(why)")
    case .invalid(let why): print("loinnir-test: MISMATCH: pipeline: \(name): invalid: \(why)")
    case .outOfMemory(let what): print("loinnir-test: MISMATCH: pipeline: \(name): out of memory: \(what)")
    case .failed(let call, let code): print("loinnir-test: MISMATCH: pipeline: \(name): \(call) failed with \(code)")
    case .noDevice(let why): print("loinnir-test: MISMATCH: pipeline: \(name): no device: \(why)")
    case .lost: fail("pipeline: \(name): the GPU was lost")
    }
  }

  // MARK: Line width

  func lineWidthCases() throws(GPUError) -> Int {
    guard f.wideLines else { skip("line width", "no wide lines"); return 0 }
    var failed = 0
    let rf: [Float] = [1, 0, 0, 1]
    let mesh = try rawMesh([Vertex(x: 2, y: 8, color: rf), Vertex(x: 30, y: 8, color: rf)], width: 32, height: 32)
    for dynamic in [false, true] {
      do throws(GPUError) {
        let pso = try plain(.lineList, raster: RasterizationState(lineWidth: dynamic ? 1 : 4), dynamic: dynamic ? .lineWidth : DynamicStates())
        let px = try onePass { c in
          if dynamic { c.setLineWidth(4) }
          c.draw(pso, root: mesh.address, vertices: 2)
        }
        failed += softJudge("line width 4\(dynamic ? " (dynamic)" : ""): four rows", px, 32, 32) { x, y in
          guard x >= 6 && x <= 26 else { return nil }
          if y >= 6 && y < 10 { return Self.red }
          if y < 5 || y > 10 { return Self.blue }
          return nil
        }
      } catch { caughtCase("line width", error); failed += 1 }
    }
    return failed
  }

  // MARK: Depth

  /// Every compare op: a rectangle at depth 0.5 written, then one at 0.4, 0.5 and 0.6 drawn with the op over it; the second
  /// shows where the compare of its depth with the first's passes. Eight tiles of 4 by 4, a pass for each relation.
  func compareCases() throws(GPUError) -> Int {
    guard f.depth, let format = depthFormat(), f.dynamicState else { skip("depth compare ops", "no depth"); return 0 }
    var failed = 0
    let ops: [(CompareOp, String)] = [(.never, "never"), (.less, "less"), (.equal, "equal"), (.lessOrEqual, "lessOrEqual"),
                                      (.greater, "greater"), (.notEqual, "notEqual"), (.greaterOrEqual, "greaterOrEqual"), (.always, "always")]
    for (zb, relation) in [(Float(0.4), "nearer"), (0.5, "equal"), (0.6, "farther")] {
      do throws(GPUError) {
        let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.5, zRight: 0.5, color: [1, 0, 0, 1]),
                                   Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: zb, zRight: zb, color: [0, 1, 0, 1])], width: 4, height: 4)
        let first = try meshPipeline(depthFormat: format, depthStencil: DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .always))
        var tests: [GPUPipeline] = []
        for (op, _) in ops {
          tests.append(try meshPipeline(depthFormat: format, depthStencil: DepthStencilState(depthTest: true, depthWrite: false, depthCompare: op)))
        }
        let target = try colorTarget(32, 4)
        let depth = try image(format, 32, 4, usage: .depthStencilTarget)
        var list = GPUCommandList()
        let info = RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))],
                                 depthStencil: DepthStencilAttachment(image: depth, clearDepth: 1))
        list.render(info) { c in
          for i in 0..<ops.count {
            c.setViewport(x: Float(i * 4), y: 0, width: 4, height: 4)
            c.draw(first, root: mesh.address, vertices: 6, firstVertex: 0)
            c.draw(tests[i], root: mesh.address, vertices: 6, firstVertex: 6)
          }
        }
        let px = try readBack(list, target)
        failed += softJudge("depth compare ops against 0.5 with a rectangle \(relation) than it", px, 32, 4) { x, _ in
          let (op, _) = ops[x / 4]
          let pass: Bool
          switch op {
          case .never: pass = false
          case .less: pass = zb < 0.5
          case .equal: pass = zb == 0.5
          case .lessOrEqual: pass = zb <= 0.5
          case .greater: pass = zb > 0.5
          case .notEqual: pass = zb != 0.5
          case .greaterOrEqual: pass = zb >= 0.5
          case .always: pass = true
          }
          return pass ? Self.green : Self.red
        }
      } catch { caughtCase("depth compare ops", error); failed += 1 }
    }
    return failed
  }

  /// Depth bias, its clamp and the dynamic bias, and depth clamp, each as tiles of a rectangle drawn against a first one at the
  /// same depth.
  func biasCases() throws(GPUError) -> Int {
    guard f.depth, f.depthBias, let format = depthFormat() else { skip("depth bias", "no depth bias"); return 0 }
    var failed = 0
    do throws(GPUError) {
      // Tiles: 0 no bias (equal depth fails `less`); 1 a negative constant bias passes; 2 a negative slope-less bias set by the
      // pass (dynamic); 3 a huge negative bias held by a clamp of -0.01 against a depth 0.2 above stays behind; 4 the same
      // without the clamp passes; 5 a positive bias fails `less`... of a rectangle 0.001 nearer.
      let a = [Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.5, zRight: 0.5, color: [1, 0, 0, 1]),
               Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.5, zRight: 0.5, color: [0, 1, 0, 1]),
               Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.7, zRight: 0.7, color: [0, 1, 0, 1]),
               Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 0.499, zRight: 0.499, color: [0, 1, 0, 1])]
      let mesh = try meshBuffer(a, width: 4, height: 4)
      func test(_ bias: Bool, _ constant: Float, _ clamp: Float, dynamic: Bool = false) throws(GPUError) -> GPUPipeline {
        try meshPipeline(depthFormat: format, depthStencil: DepthStencilState(depthTest: true, depthWrite: false, depthCompare: .less),
                         rasterization: RasterizationState(depthBias: bias, depthBiasConstant: constant, depthBiasClamp: clamp, depthBiasSlope: 0),
                         dynamic: dynamic ? .depthBias : DynamicStates())
      }
      let first = try meshPipeline(depthFormat: format, depthStencil: DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .always))
      let none = try test(false, 0, 0)
      let negative = try test(true, -64, 0)
      let dynamicBias = try test(true, 0, 0, dynamic: true)
      let clamped = try test(true, -1e9, -0.01)
      let unclamped = try test(true, -1e9, 0)
      let positive = try test(true, 1e9, 0)
      let draws: [(GPUPipeline, Int, Bool)] = [(none, 6, false), (negative, 6, true), (dynamicBias, 6, true), (clamped, 12, false), (unclamped, 12, true),
                                               (positive, 18, false)]
      let target = try colorTarget(24, 4)
      let depth = try image(format, 24, 4, usage: .depthStencilTarget)
      var list = GPUCommandList()
      let info = RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))],
                               depthStencil: DepthStencilAttachment(image: depth, clearDepth: 1))
      list.render(info) { c in
        for i in 0..<draws.count {
          c.setViewport(x: Float(i * 4), y: 0, width: 4, height: 4)
          c.draw(first, root: mesh.address, vertices: 6, firstVertex: 0)
          if i == 2 { c.setDepthBias(constant: -64, clamp: 0, slope: 0) }
          c.draw(draws[i].0, root: mesh.address, vertices: 6, firstVertex: UInt32(draws[i].1))
        }
      }
      let px = try readBack(list, target)
      failed += softJudge("depth bias: none, constant, dynamic, clamped, unclamped, positive", px, 24, 4) { x, _ in
        draws[x / 4].2 ? Self.green : Self.red
      }
    } catch { caughtCase("depth bias", error); failed += 1 }
    guard f.depthClamp else { skip("depth clamp", "no depth clamp"); return failed }
    do throws(GPUError) {
      // A rectangle beyond the far plane: clipped away, or, with clamp, drawn at depth 1 (which `lessOrEqual` passes at the clear).
      let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 4, y1: 4, zLeft: 1.5, zRight: 1.5, color: [0, 1, 0, 1])], width: 4, height: 4)
      let ds = DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .lessOrEqual)
      let clip = try meshPipeline(depthFormat: format, depthStencil: ds)
      let clamp = try meshPipeline(depthFormat: format, depthStencil: ds, rasterization: RasterizationState(depthClamp: true))
      let target = try colorTarget(8, 4)
      let depth = try image(format, 8, 4, usage: .depthStencilTarget)
      var list = GPUCommandList()
      let info = RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))],
                               depthStencil: DepthStencilAttachment(image: depth, clearDepth: 1))
      list.render(info) { c in
        c.setViewport(x: 0, y: 0, width: 4, height: 4)
        c.draw(clip, root: mesh.address, vertices: 6)
        c.setViewport(x: 4, y: 0, width: 4, height: 4)
        c.draw(clamp, root: mesh.address, vertices: 6)
      }
      let px = try readBack(list, target)
      failed += softJudge("depth clamp: clipped beyond the far plane, drawn at depth 1 when clamped", px, 8, 4) { x, _ in
        x < 4 ? Self.blue : Self.green
      }
    } catch { caughtCase("depth clamp", error); failed += 1 }
    return failed
  }

  // MARK: Rasterizer discard

  func discardCase() throws(GPUError) -> Int {
    guard f.rasterizerDiscard else { skip("rasterizer discard", "no rasterizer discard"); return 0 }
    let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 32, y1: 32, color: [0, 1, 0, 1]), Rect(x0: 8, y0: 8, x1: 16, y1: 16, color: [1, 0, 0, 1])],
                              width: 32, height: 32)
    let discarding = try plain(raster: RasterizationState(rasterizerDiscard: true))
    let normal = try plain()
    let px = try onePass { c in
      c.draw(discarding, root: mesh.address, vertices: 6)
      c.draw(normal, root: mesh.address, vertices: 6, firstVertex: 6)
    }
    return softJudge("rasterizer discard: the discarded rectangle never appears, the next draw does", px, 32, 32) { x, y in
      x >= 8 && x < 16 && y >= 8 && y < 16 ? Self.red : Self.blue
    }
  }

  // MARK: Run

  func pipelineCases() {
    // Judged on the Mali backend, whose pipeline state these cases were written with; the Vulkan backend has CoreCases.
    guard d.backend.utf8.elementsEqual("mali".utf8) else { return skip("pipeline cases", "the Mali backend's (this is \(d.backend))") }
    guard f.cullModes || f.depth || f.extendedTopologies else { return skip("pipeline cases", "none of the pipeline state") }
    var failed = 0
    let start = Clock.monotonic()
    do throws(GPUError) { failed += try scissorCase() } catch { caughtCase("scissor", error); failed += 1 }
    do throws(GPUError) { failed += try topologyCases() } catch { caughtCase("topologies", error); failed += 1 }
    do throws(GPUError) { failed += try lineWidthCases() } catch { caughtCase("line width", error); failed += 1 }
    do throws(GPUError) { failed += try compareCases() } catch { caughtCase("compare ops", error); failed += 1 }
    do throws(GPUError) { failed += try biasCases() } catch { caughtCase("bias", error); failed += 1 }
    do throws(GPUError) { failed += try discardCase() } catch { caughtCase("discard", error); failed += 1 }
    do throws(GPUError) { failed += try constantCases() } catch { caughtCase("constants", error); failed += 1 }
    do throws(GPUError) { failed += try targetCases() } catch { caughtCase("targets", error); failed += 1 }
    do throws(GPUError) { failed += try stencilFaceCases() } catch { caughtCase("stencil faces", error); failed += 1 }
    do throws(GPUError) { failed += try lateDepthCases() } catch { caughtCase("late depth", error); failed += 1 }
    print("loinnir-test: pipeline cases: \(failed) failed, \((Clock.monotonic() - start) / 1_000_000) ms")
    if failed > 0 { fail("pipeline cases: \(failed) of them failed (MISMATCH lines above)") }
  }
}
