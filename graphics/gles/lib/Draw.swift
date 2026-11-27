// SPDX-License-Identifier: BSD-3-Clause

// Draws (gles(3), "Drawing"): DrawArrays and DrawElements, Clear, ReadPixels, Flush and Finish.
//
// A draw is one command of the open pass: its pipeline, found by the state it needs (made once, the first time that
// state is drawn with), and its root block, written into the upload ring:
//
//   offset   0   u64 set[4]            set[0]: the program's set record, just after the root block
//   offset  32   u64 vertexBuffer[8]   each attribute location's vertex buffer
//   offset  96   the set record:       binding 0, the uniform block (u64 address, u64 range);
//                                      bindings 1 on, each sampler's u32 texture slot, u32 sampler slot
//
// as vulkanlowering(2) lays them out. Each attribute location is a vertex buffer of its own, read from offset 0, so
// the vertex stage is lowered against each location's format and stride and nothing else: a buffer's float attribute
// is read where it is; a client array is copied into the ring, from the first vertex the draw reads to the last; an
// attribute of another type is converted to floats as it is copied; a disabled one is its constant, a vertex buffer of
// stride 0. The uniform block is copied into the ring when a glUniform* has changed it since its last copy.
//
// GL's window coordinates have their first row at the bottom, as the core's attachments have theirs at row 0: a
// framebuffer object is drawn as it is. A window's image has its first row at the top, so its viewport and scissor are
// flipped, and with them the winding that faces front.

import GPUCore
import VulkanLowering

/// What a pipeline is made for besides its program: the vertex layout, the primitives, the attachments and GL's fixed
/// state, packed.
struct PipelineKey: Hashable {
  var layout: VertexLayout
  var topology: UInt8
  var colorFormat: UInt8
  var depthFormat: UInt8
  /// Enables and small state, a bit or a few each.
  var flags: UInt32
  var blend: UInt32
  var stencilFront: UInt32
  var stencilBack: UInt32
}

func formatCode(_ f: PixelFormat?) -> UInt8 {
  guard let f else { return 0 }
  switch f {
  case .rgba8: return 1
  case .bgra8: return 2
  case .bgra8srgb: return 3
  case .depth16: return 4
  case .depth32f: return 5
  case .depth24stencil8: return 6
  case .depth32fstencil8: return 7
  case .stencil8: return 8
  default: return 9
  }
}

func blendFactor(_ f: GLenum) -> BlendingFactor {
  switch f {
  case GL_ZERO: .zero
  case GL_SRC_COLOR: .srcColor
  case GL_ONE_MINUS_SRC_COLOR: .oneMinusSrcColor
  case GL_DST_COLOR: .dstColor
  case GL_ONE_MINUS_DST_COLOR: .oneMinusDstColor
  case GL_SRC_ALPHA: .srcAlpha
  case GL_ONE_MINUS_SRC_ALPHA: .oneMinusSrcAlpha
  case GL_DST_ALPHA: .dstAlpha
  case GL_ONE_MINUS_DST_ALPHA: .oneMinusDstAlpha
  case GL_CONSTANT_COLOR: .constantColor
  case GL_ONE_MINUS_CONSTANT_COLOR: .oneMinusConstantColor
  case GL_CONSTANT_ALPHA: .constantAlpha
  case GL_ONE_MINUS_CONSTANT_ALPHA: .oneMinusConstantAlpha
  case GL_SRC_ALPHA_SATURATE: .srcAlphaSaturate
  default: .one
  }
}

/// A GL blend factor as four bits (its place among GL's).
func blendCode(_ f: GLenum) -> UInt32 {
  switch f {
  case GL_ZERO: 0
  case GL_ONE: 1
  case GL_SRC_COLOR: 2
  case GL_ONE_MINUS_SRC_COLOR: 3
  case GL_DST_COLOR: 4
  case GL_ONE_MINUS_DST_COLOR: 5
  case GL_SRC_ALPHA: 6
  case GL_ONE_MINUS_SRC_ALPHA: 7
  case GL_DST_ALPHA: 8
  case GL_ONE_MINUS_DST_ALPHA: 9
  case GL_CONSTANT_COLOR: 10
  case GL_ONE_MINUS_CONSTANT_COLOR: 11
  case GL_CONSTANT_ALPHA: 12
  case GL_ONE_MINUS_CONSTANT_ALPHA: 13
  default: 14
  }
}

let blendFactors: [GLenum] = [
  GL_ZERO, GL_ONE, GL_SRC_COLOR, GL_ONE_MINUS_SRC_COLOR, GL_DST_COLOR, GL_ONE_MINUS_DST_COLOR, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
  GL_DST_ALPHA, GL_ONE_MINUS_DST_ALPHA, GL_CONSTANT_COLOR, GL_ONE_MINUS_CONSTANT_COLOR, GL_CONSTANT_ALPHA,
  GL_ONE_MINUS_CONSTANT_ALPHA, GL_SRC_ALPHA_SATURATE,
]

func blendOp(_ e: GLenum) -> BlendOp {
  switch e {
  case GL_FUNC_SUBTRACT: .subtract
  case GL_FUNC_REVERSE_SUBTRACT: .reverseSubtract
  default: .add
  }
}

func compareOp(_ f: GLenum) -> CompareOp {
  switch f {
  case GL_NEVER: .never
  case GL_LESS: .less
  case GL_EQUAL: .equal
  case GL_LEQUAL: .lessOrEqual
  case GL_GREATER: .greater
  case GL_NOTEQUAL: .notEqual
  case GL_GEQUAL: .greaterOrEqual
  default: .always
  }
}

func stencilOperation(_ o: GLenum) -> StencilOp {
  switch o {
  case GL_ZERO: .zero
  case GL_REPLACE: .replace
  case GL_INCR: .incrementClamp
  case GL_DECR: .decrementClamp
  case GL_INVERT: .invert
  case GL_INCR_WRAP: .incrementWrap
  case GL_DECR_WRAP: .decrementWrap
  default: .keep
  }
}

func stencilOpCode(_ o: GLenum) -> UInt32 {
  switch o {
  case GL_ZERO: 1
  case GL_REPLACE: 2
  case GL_INCR: 3
  case GL_DECR: 4
  case GL_INVERT: 5
  case GL_INCR_WRAP: 6
  case GL_DECR_WRAP: 7
  default: 0
  }
}

let stencilOps: [GLenum] = [GL_KEEP, GL_ZERO, GL_REPLACE, GL_INCR, GL_DECR, GL_INVERT, GL_INCR_WRAP, GL_DECR_WRAP]

func topology(_ mode: GLenum) -> PrimitiveTopology? {
  switch mode {
  case GL_POINTS: .pointList
  case GL_LINES: .lineList
  case GL_LINE_STRIP, GL_LINE_LOOP: .lineStrip
  case GL_TRIANGLES: .triangleList
  case GL_TRIANGLE_STRIP: .triangleStrip
  case GL_TRIANGLE_FAN: .triangleFan
  default: nil
  }
}

let topologies: [PrimitiveTopology] = [.pointList, .lineList, .lineStrip, .triangleList, .triangleStrip, .triangleFan]

/// The dynamic state every pipeline leaves to the pass.
let dynamicStates: DynamicStates = .stencilReference | .stencilCompareMask | .stencilWriteMask | .depthBias | .blendConstants
  | .lineWidth

/// The last draw's pipeline and what it was found by (its target by number: two targets of one number are one).
final class LastPipeline {
  let program: GLProgram
  let link: UInt64
  let serial: UInt64
  let layout: VertexLayout
  let topology: PrimitiveTopology
  let target: UInt64
  let pipeline: GPUPipeline
  init(_ program: GLProgram, _ link: UInt64, _ serial: UInt64, _ layout: VertexLayout, _ topology: PrimitiveTopology, _ target: UInt64,
       _ pipeline: GPUPipeline) {
    self.program = program
    self.link = link
    self.serial = serial
    self.layout = layout
    self.topology = topology
    self.target = target
    self.pipeline = pipeline
  }
}

/// What a draw reads its indices from.
enum IndexSource {
  case none
  case indices(type: GLenum, offset: UInt)
}

extension GLContext {
  // MARK: Pipelines

  /// The key of GL's fixed state for drawing into `target` with `mode`'s primitives and `layout`.
  func pipelineKey(_ layout: VertexLayout, _ topology: PrimitiveTopology, _ target: RenderTarget) -> PipelineKey {
    var flags: UInt32 = 0
    func bit(_ on: Bool, _ n: UInt32) { if on { flags |= 1 << n } }
    bit(blend && target.color != nil, 0)
    bit(depthTest && target.hasDepth, 1)
    bit(depthMask && depthTest && target.hasDepth, 2)
    bit(stencilTest && target.hasStencil, 3)
    bit(cullFace, 4)
    bit(polygonOffsetFill, 5)
    bit(sampleAlphaToCoverage, 6)
    bit(sampleCoverage, 7)
    bit(target.flipped, 8)
    bit(sampleCoverageInvert, 9)
    bit(sampleCoverageValue >= 0.5, 10)
    bit(frontFace == GL_CW, 11)
    var mask: UInt32 = 0
    if colorMask.0 { mask |= 1 }
    if colorMask.1 { mask |= 2 }
    if colorMask.2 { mask |= 4 }
    if colorMask.3 && target.colorAlpha { mask |= 8 }
    if target.color == nil { mask = 0 }
    flags |= mask << 12
    flags |= UInt32(cullFaceMode - GL_FRONT) << 16  // FRONT, BACK; FRONT_AND_BACK is 0x408
    flags |= (depthFunc - GL_NEVER) << 20
    let b = blendCode(blendSrcRGB) | blendCode(blendDstRGB) << 4 | blendCode(blendSrcAlpha) << 8 | blendCode(blendDstAlpha) << 12
      | (blendEquationRGB - GL_FUNC_ADD) << 16 | (blendEquationAlpha - GL_FUNC_ADD) << 20
    func stencil(_ s: StencilFace) -> UInt32 {
      (s.function - GL_NEVER) | stencilOpCode(s.fail) << 4 | stencilOpCode(s.depthFail) << 8 | stencilOpCode(s.depthPass) << 12
    }
    var t: UInt8 = 0
    for (i, x) in topologies.enumerated() where x == topology { t = UInt8(i) }
    return PipelineKey(layout: layout, topology: t, colorFormat: formatCode(target.colorFormat ?? target.scratch?.format),
                       depthFormat: formatCode(target.depthStencilFormat), flags: flags, blend: blend && target.color != nil ? b : 0,
                       stencilFront: stencilTest ? stencil(stencilFront) : 0, stencilBack: stencilTest ? stencil(stencilBack) : 0)
  }

  /// The descriptor of the pipeline `key` stands for.
  func pipelineDescriptor(_ program: GLProgram, _ key: PipelineKey, vertex: [UInt8], _ target: RenderTarget)
    -> GraphicsPipelineDescriptor
  {
    let f = key.flags
    func on(_ n: UInt32) -> Bool { f & (1 << n) != 0 }
    var blendState = ColorBlendAttachment()
    blendState.writeMask = ColorMask(rawValue: UInt8((f >> 12) & 15))
    if on(0) {
      blendState.enabled = true
      blendState.srcColor = blendFactor(blendFactors[Int(key.blend & 15)])
      blendState.dstColor = blendFactor(blendFactors[Int((key.blend >> 4) & 15)])
      blendState.srcAlpha = blendFactor(blendFactors[Int((key.blend >> 8) & 15)])
      blendState.dstAlpha = blendFactor(blendFactors[Int((key.blend >> 12) & 15)])
      blendState.colorOp = blendOp(GL_FUNC_ADD + ((key.blend >> 16) & 15))
      blendState.alphaOp = blendOp(GL_FUNC_ADD + ((key.blend >> 20) & 15))
    }
    var ds = DepthStencilState()
    ds.depthTest = on(1)
    ds.depthWrite = on(2)
    ds.depthCompare = on(1) ? compareOp(GL_NEVER + ((f >> 20) & 15)) : .always
    if on(3) {
      ds.stencilTest = true
      func face(_ s: UInt32) -> StencilFaceState {
        StencilFaceState(failOp: stencilOperation(stencilOps[Int((s >> 4) & 15)]),
                         passOp: stencilOperation(stencilOps[Int((s >> 12) & 15)]),
                         depthFailOp: stencilOperation(stencilOps[Int((s >> 8) & 15)]), compare: compareOp(GL_NEVER + (s & 15)))
      }
      ds.front = face(key.stencilFront)
      ds.back = face(key.stencilBack)
    }
    var r = RasterizationState()
    if on(4) {
      switch GL_FRONT + ((f >> 16) & 15) {
      case GL_FRONT: r.cull = .front
      case GL_BACK: r.cull = .back
      default: r.cull = .frontAndBack
      }
    }
    // GL's counter-clockwise, in the core's coordinates: the opposite winding for a framebuffer drawn as it is (its
    // rows count up where the core's area formula counts down), the same for a flipped window.
    let glCCW = !on(11)
    r.frontFace = glCCW == on(8) ? .counterClockwise : .clockwise
    r.depthBias = on(5)
    var ms = MultisampleState()
    ms.alphaToCoverage = on(6) && frame.limits.features.alphaToCoverage
    if on(7) { ms.sampleMask = on(10) != on(9) ? ~0 : 0 }
    var colorFormats: [PixelFormat] = []
    if let c = target.colorFormat { colorFormats.append(c) } else if let s = target.scratch { colorFormats.append(s.format) }
    return GraphicsPipelineDescriptor(vertex: vertex, fragment: program.fragmentBytes, colorFormats: colorFormats, blend: .opaque,
                                      topology: topologies[Int(key.topology)], depthStencilFormat: target.depthStencilFormat,
                                      depthStencil: ds, rasterization: r, multisample: ms,
                                      attachmentBlends: colorFormats.isEmpty ? nil : [blendState], dynamic: dynamicStates)
  }

  /// The pipeline for a draw: the program's, found by its key or made now.
  func pipeline(_ program: GLProgram, _ layout: VertexLayout, _ topology: PrimitiveTopology, _ target: RenderTarget)
    throws(GPUError) -> GPUPipeline
  {
    // The last draw's, where nothing it was found by has changed: no key is made (and nothing of the target copied).
    if let c = lastPipeline, c.program === program, c.link == program.linkSerial, c.serial == pipelineSerial, c.layout == layout,
      c.topology == topology, target.id != 0, c.target == target.id
    {
      return c.pipeline
    }
    let key = pipelineKey(layout, topology, target)
    if let p = program.pipelines[key] {
      lastPipeline = LastPipeline(program, program.linkSerial, pipelineSerial, layout, topology, target.id, p)
      return p
    }
    let vertex: [UInt8]
    do throws(LoweringError) { vertex = try program.vertexStage(layout) } catch {
      throw .unsupported("the vertex stage can't be lowered for this vertex layout: \(error)")
    }
    let p = try device.makeGraphicsPipeline(pipelineDescriptor(program, key, vertex: vertex, target))
    program.pipelines[key] = p
    lastPipeline = LastPipeline(program, program.linkSerial, pipelineSerial, layout, topology, target.id, p)
    pipelinesMade += 1
    frame.stats.pipelines += 1
    return p
  }

  // MARK: Passes

  /// The open pass on `target`, begun: the one there is, unless it is another target's, or has drawn and must
  /// see what was written to an image this draw reads (a barrier goes before a pass, not in it).
  func openPass(_ target: RenderTarget, reads: [UInt64]) {
    if var p = frame.pass, p.target == target {
      let mustSplit = (p.begun && reads.contains { frame.written.contains($0) })
      if !mustSplit {
        for r in reads where !p.reads.contains(r) { p.reads.append(r) }
        frame.pass = p
        if !p.begun { frame.begin() }
        return
      }
    }
    frame.endPass()
    frame.pass = OpenPass(target: target, reads: reads)
    frame.begin()
  }

  /// The viewport of GL's, in the core's coordinates of `target`.
  /// A program whose vertex stage flips y itself (the driver words' positionYScale of -1) is drawn into a window with
  /// the viewport upright, at the window's rows from the top.
  func coreViewport(_ t: RenderTarget, shaderFlips: Bool) -> Viewport {
    let (n, f) = depthRange
    let x = Float(viewport.x), w = Float(viewport.width), h = Float(viewport.height)
    if t.flipped && shaderFlips {
      return Viewport(x: x, y: Float(t.height) - Float(viewport.y) - h, width: w, height: h, minDepth: n, maxDepth: f)
    }
    if t.flipped {
      return Viewport(x: x, y: Float(t.height) - Float(viewport.y), width: w, height: -h, minDepth: n, maxDepth: f)
    }
    return Viewport(x: x, y: Float(viewport.y), width: w, height: h, minDepth: n, maxDepth: f)
  }

  /// The scissor (or, with the test off, the whole target) clamped to `target`, in the core's coordinates.
  func coreScissor(_ t: RenderTarget) -> RenderArea {
    guard scissorTest else { return RenderArea(width: UInt32(t.width), height: UInt32(t.height)) }
    let x0 = min(max(scissor.x, 0), t.width), y0 = min(max(scissor.y, 0), t.height)
    let x1 = min(max(scissor.x &+ scissor.width, 0), t.width), y1 = min(max(scissor.y &+ scissor.height, 0), t.height)
    let y = t.flipped ? t.height - y1 : y0
    return RenderArea(x: x0, y: y, width: UInt32(max(x1 - x0, 0)), height: UInt32(max(y1 - y0, 0)))
  }

  /// Records the pass's state where it differs from GL's now.
  func recordDynamicState(_ t: RenderTarget, shaderFlips: Bool = false) {
    guard var p = frame.pass else { return }
    let v = coreViewport(t, shaderFlips: shaderFlips)
    if p.viewport != v {
      frame.list.setViewports([v])
      p.viewport = v
    }
    let s = coreScissor(t)
    if p.scissor != s {
      frame.list.setScissor(x: s.x, y: s.y, width: s.width, height: s.height)
      p.scissor = s
    }
    if t.hasStencil {
      let ref = (UInt32(bitPattern: stencilFront.reference) & 0xFF, UInt32(bitPattern: stencilBack.reference) & 0xFF)
      if p.stencilReference == nil || p.stencilReference! != ref {
        frame.list.setStencilReference(.front, ref.0)
        frame.list.setStencilReference(.back, ref.1)
        p.stencilReference = ref
      }
      let compare = (stencilFront.valueMask & 0xFF, stencilBack.valueMask & 0xFF)
      if p.stencilCompare == nil || p.stencilCompare! != compare {
        frame.list.setStencilCompareMask(.front, compare.0)
        frame.list.setStencilCompareMask(.back, compare.1)
        p.stencilCompare = compare
      }
      let write = (stencilFront.writeMask & 0xFF, stencilBack.writeMask & 0xFF)
      if p.stencilWrite == nil || p.stencilWrite! != write {
        frame.list.setStencilWriteMask(.front, write.0)
        frame.list.setStencilWriteMask(.back, write.1)
        p.stencilWrite = write
      }
    }
    if polygonOffsetFill {
      let bias = (polygonOffset.units, polygonOffset.factor)
      if p.depthBias == nil || p.depthBias! != bias {
        frame.list.setDepthBias(constant: bias.0, slope: bias.1)
        p.depthBias = bias
      }
    }
    if blend {
      let k = BlendConstants(red: blendColor.0, green: blendColor.1, blue: blendColor.2, alpha: blendColor.3)
      if p.blendConstants != k {
        frame.list.setBlendConstants(k)
        p.blendConstants = k
      }
    }
    let width = frame.limits.features.wideLines ? min(lineWidth, frame.limits.maxLineWidth) : 1
    if p.lineWidth != width {
      frame.list.setLineWidth(width)
      p.lineWidth = width
    }
    frame.pass = p
  }

  // MARK: Vertex input

  /// The vertices a draw reads, first and last: GL's for DrawArrays, the indices' least and greatest for DrawElements.
  func vertexRange(first: Int, count: Int, indices: UnsafeRawPointer?, type: GLenum) -> (Int, Int) {
    guard let p = unsafe indices else { return (first, first + count - 1) }
    var lo = Int.max, hi = 0
    for i in 0..<count {
      let v: Int
      switch type {
      case GL_UNSIGNED_BYTE: v = Int(unsafe p.load(fromByteOffset: i, as: UInt8.self))
      case GL_UNSIGNED_SHORT: v = Int(unsafe p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
      default: v = Int(unsafe p.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
      }
      lo = min(lo, v)
      hi = max(hi, v)
    }
    return lo <= hi ? (lo, hi) : (0, 0)
  }

  /// Fills `root`'s vertex buffers for the program's attributes, and gives the layout the vertex stage reads them as.
  /// `range` is the vertices read (needed only where something is copied: `rangeOf` gives it, once).
  func vertexInputs(_ program: GLProgram, root: UnsafeMutableRawPointer, range rangeOf: () -> (Int, Int)) throws(GPUError)
    -> VertexLayout
  {
    var layout = VertexLayout()
    var range: (Int, Int)?
    for (n, location) in program.attributeLocations.enumerated() {
      let a = vertexArray.attributes[Int(location)]
      var address: UInt64
      var format: VertexFormat
      var stride: UInt32
      if !a.enabled {
        let u = try frame.ring.allocate(16)
        for c in 0..<4 { unsafe u.pointer.storeBytes(of: constantAttributes[4 * Int(location) + c], toByteOffset: 4 * c, as: Float.self) }
        address = u.address
        format = .rgba32Float
        stride = 0
      } else {
        let s = a.effectiveStride
        let native = nativeVertexFormat(size: a.size, type: a.type, normalized: a.normalized)
        if let b = a.buffer, let native, s % 4 == 0, a.pointer % 4 == 0, UInt32(s) <= VertexLayout.maxStride {
          // Read where it is.
          guard let m = try deviceCopy(b) else {
            address = 0
            format = native
            stride = UInt32(s)
            layout.append(format: vertexFormatCode(format), stride: stride)
            continue
          }
          address = m.address + UInt64(a.pointer)
          format = native
          stride = UInt32(s)
        } else {
          // Copied (and converted, unless it is native and only misplaced) from the first vertex read to the last.
          if range == nil { range = rangeOf() }
          let (lo, hi) = range!
          let count = hi - lo + 1
          var source: UnsafeRawPointer?
          if let b = a.buffer {
            if let bytes = unsafe b.bytes { unsafe source = UnsafeRawPointer(bytes) + Int(a.pointer) }
          } else {
            unsafe source = UnsafeRawPointer(bitPattern: a.pointer)
          }
          if let native {
            let tight = native.bytes
            let u = try frame.ring.allocate(max(count * tight, 16))
            if let source = unsafe source {
              for v in 0..<count {
                unsafe (u.pointer + v * tight).copyMemory(from: source + (lo + v) * s, byteCount: tight)
              }
            }
            address = u.address &- UInt64(lo * tight)
            format = native
            stride = UInt32(tight)
          } else {
            let tight = 4 * a.size
            let u = try frame.ring.allocate(max(count * tight, 16))
            if let source = unsafe source {
              unsafe convertAttribute(source + lo * s, count: count, size: a.size, type: a.type, normalized: a.normalized, stride: s,
                                      into: u.pointer)
            }
            address = u.address &- UInt64(lo * tight)
            format = floatVertexFormat(a.size)
            stride = UInt32(tight)
          }
        }
      }
      _ = n
      unsafe root.storeBytes(of: address, toByteOffset: RootBlock.vertexBuffersOffset + 8 * Int(location), as: UInt64.self)
      layout.append(format: vertexFormatCode(format), stride: stride)
    }
    return layout
  }

  // MARK: Draws

  /// One draw: `count` vertices from `first`, or `count` indices.
  func draw(_ mode: GLenum, first: Int, count: Int, indices: IndexSource) {
    guard let topology = topology(mode) else { return fail(.invalidEnum) }
    guard count >= 0, first >= 0 else { return fail(.invalidValue) }
    guard let target = currentTarget() else { return }
    guard let program, program.linkStatus, count > 0 else { return }
    do throws(GPUError) { try record(program, mode, topology, first: first, count: count, indices: indices, target) } catch {
      fail(error)
    }
  }

  private func record(_ program: GLProgram, _ mode: GLenum, _ topology: PrimitiveTopology, first: Int, count: Int,
                      indices: IndexSource, _ target: RenderTarget) throws(GPUError) {
    // The textures first: finding a sampler slot may submit the open list.
    // The context's own arrays, kept between draws: a draw makes none.
    var slots = drawSlots
    var reads = drawReads
    slots.removeAll(keepingCapacity: true)
    reads.removeAll(keepingCapacity: true)
    drawSlots = []
    drawReads = []
    defer {
      drawSlots = slots
      drawReads = reads
    }
    for n in program.samplerBindings.indices {
      let unit = program.unit(n)
      guard unit >= 0, unit < GLContext.textureUnits else {
        slots.append((try frame.incompleteSlot(cube: program.samplerIsCube[n]), try sampler(for: SamplerDescriptor())))
        continue
      }
      let s = try samplerSlots(unit: unit, cube: program.samplerIsCube[n])
      slots.append((s.texture, s.sampler))
      if let image = s.image, !reads.contains(image) { reads.append(image) }
    }

    // The indices.
    var indexMemory: GPUMemory?
    var indexOffset = 0
    var indexType = IndexType.uint16
    var indexPointer: UnsafeRawPointer?
    var glIndexType = GL_UNSIGNED_SHORT
    var drawCount = count
    if case .indices(let type, let offset) = indices {
      glIndexType = type
      let size = type == GL_UNSIGNED_BYTE ? 1 : type == GL_UNSIGNED_SHORT ? 2 : 4
      if let b = vertexArray.elementBuffer {
        guard Int(offset) + count * size <= b.size, let bytes = unsafe b.bytes else { return fail(.invalidOperation) }
        unsafe indexPointer = UnsafeRawPointer(bytes) + Int(offset)
        if type != GL_UNSIGNED_BYTE && Int(offset) % size == 0 && mode != GL_LINE_LOOP {
          indexMemory = try deviceCopy(b)
          indexOffset = Int(offset)
          indexType = type == GL_UNSIGNED_INT ? .uint32 : .uint16
        }
      } else {
        unsafe indexPointer = UnsafeRawPointer(bitPattern: offset)
        guard unsafe indexPointer != nil else { return }
      }
      if indexMemory == nil, let src = unsafe indexPointer {
        // Copied: bytes widened to shorts, a loop closed.
        let wide = type == GL_UNSIGNED_INT
        let each = wide ? 4 : 2
        let total = count + (mode == GL_LINE_LOOP ? 1 : 0)
        let u = try frame.ring.allocate(max(total * each, 16))
        for i in 0..<total {
          let k = i < count ? i : 0
          let v: UInt32
          switch type {
          case GL_UNSIGNED_BYTE: v = UInt32(unsafe src.load(fromByteOffset: k, as: UInt8.self))
          case GL_UNSIGNED_SHORT: v = UInt32(unsafe src.loadUnaligned(fromByteOffset: 2 * k, as: UInt16.self))
          default: v = unsafe src.loadUnaligned(fromByteOffset: 4 * k, as: UInt32.self)
          }
          if wide { unsafe u.pointer.storeBytes(of: v, toByteOffset: 4 * i, as: UInt32.self) } else {
            unsafe u.pointer.storeBytes(of: UInt16(truncatingIfNeeded: v), toByteOffset: 2 * i, as: UInt16.self)
          }
        }
        indexMemory = u.memory
        indexOffset = u.offset
        indexType = wide ? .uint32 : .uint16
        drawCount = total
      }
    } else if mode == GL_LINE_LOOP {
      // A loop of DrawArrays is a strip of indices that ends where it began.
      let u = try frame.ring.allocate(max((count + 1) * 4, 16))
      for i in 0...count { unsafe u.pointer.storeBytes(of: UInt32(first + (i < count ? i : 0)), toByteOffset: 4 * i, as: UInt32.self) }
      indexMemory = u.memory
      indexOffset = u.offset
      indexType = .uint32
      drawCount = count + 1
    }

    // The root block and the set record.
    let record = program.setLayout.size
    let rootBytes = 96
    let root = try frame.ring.allocate(rootBytes + record)
    unsafe root.pointer.initializeMemory(as: UInt8.self, repeating: 0, count: rootBytes)
    let layout = try unsafe vertexInputs(program, root: root.pointer) {
      unsafe vertexRange(first: first, count: count, indices: indexPointer, type: glIndexType)
    }
    unsafe root.pointer.storeBytes(of: root.address + UInt64(rootBytes), toByteOffset: RootBlock.setsOffset, as: UInt64.self)
    if let at = program.interface.driverWords, let block = unsafe program.block, at + 28 <= program.blockBytes {
      // The driver words for this target: GL's rows kept (off-screen), or flipped (a window, first row its top).
      // (Stored one by one: an array of them was an allocation every draw.)
      let (n, f) = depthRange
      let flipped = target.flipped
      func word(_ k: Int, _ w: Float) {
        guard unsafe block.load(fromByteOffset: at + 4 * k, as: Float.self) != w else { return }
        unsafe block.storeBytes(of: w, toByteOffset: at + 4 * k, as: Float.self)
        program.blockDirty = true
      }
      word(0, flipped ? -1 : 1)
      word(1, flipped ? -1 : 1)
      word(2, flipped ? Float(target.height) : 0)
      word(3, flipped ? 1 : -1)
      word(4, n)
      word(5, f)
      word(6, f - n)
    }
    if program.blockDirty || program.blockStamp != frame.ring.recycles || program.blockAddress == 0 {
      let u = try frame.ring.allocate(program.blockBytes)
      unsafe u.pointer.copyMemory(from: program.block!, byteCount: program.blockBytes)
      program.blockAddress = u.address
      program.blockStamp = frame.ring.recycles
      program.blockDirty = false
    }
    let set = unsafe root.pointer + rootBytes
    if program.blockRecordOffset >= 0 {
      unsafe set.storeBytes(of: program.blockAddress, toByteOffset: program.blockRecordOffset, as: UInt64.self)
      unsafe set.storeBytes(of: UInt64(program.blockBytes), toByteOffset: program.blockRecordOffset + 8, as: UInt64.self)
    }
    for (n, at) in program.samplerRecordOffsets.enumerated() where at >= 0 {
      unsafe set.storeBytes(of: slots[n].0, toByteOffset: at, as: UInt32.self)
      unsafe set.storeBytes(of: slots[n].1, toByteOffset: at + 4, as: UInt32.self)
    }

    let pipeline = try self.pipeline(program, layout, topology, target)
    openPass(target, reads: reads)
    recordDynamicState(target, shaderFlips: program.interface.driverWords != nil)
    if let m = indexMemory {
      frame.list.drawIndexed(pipeline, root: root.address, indices: m, indexOffset: indexOffset, indexType: indexType,
                             count: UInt32(drawCount))
    } else {
      frame.list.draw(pipeline, root: root.address, vertices: UInt32(count), firstVertex: UInt32(first))
    }
    frame.pass!.draws += 1
    if depthTest { frame.pass!.usedDepth = true }
    if colorMask.0 || colorMask.1 || colorMask.2 || colorMask.3 { frame.pass!.usedColor = true }
    if stencilTest { frame.pass!.usedStencil = true }
    frame.drawsSubmitted += 1
    frame.stats.draws += 1
  }

  func drawArrays(_ mode: GLenum, _ first: GLint, _ count: GLsizei) {
    draw(mode, first: Int(first), count: Int(count), indices: .none)
  }

  func drawElements(_ mode: GLenum, _ count: GLsizei, _ type: GLenum, _ offset: UnsafeRawPointer?) {
    guard type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_SHORT || type == GL_UNSIGNED_INT else { return fail(.invalidEnum) }
    draw(mode, first: 0, count: Int(count), indices: .indices(type: type, offset: UInt(bitPattern: unsafe offset)))
  }

  // MARK: Clears

  func clear(_ mask: GLbitfield) {
    guard mask & ~(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT) == 0 else { return fail(.invalidValue) }
    guard let t = currentTarget() else { return }
    var c = PendingClear()
    let anyColor = colorMask.0 || colorMask.1 || colorMask.2 || (colorMask.3 && t.colorAlpha)
    if mask & GL_COLOR_BUFFER_BIT != 0, t.color != nil, anyColor {
      func clamp(_ v: Float) -> Float { min(max(v, 0), 1) }
      c.color = (clamp(clearColor.0), clamp(clearColor.1), clamp(clearColor.2), clamp(clearColor.3))
    }
    if mask & GL_DEPTH_BUFFER_BIT != 0, t.hasDepth, depthMask { c.depth = min(max(clearDepth, 0), 1) }
    if mask & GL_STENCIL_BUFFER_BIT != 0, t.hasStencil, stencilFront.writeMask & 0xFF != 0 {
      c.stencil = UInt32(bitPattern: clearStencil) & 0xFF
    }
    guard c.color != nil || c.depth != nil || c.stencil != nil else { return }
    let area = coreScissor(t)
    let whole = area.x == 0 && area.y == 0 && area.width == UInt32(t.width) && area.height == UInt32(t.height)
    let colorWhole = c.color == nil || (colorMask.0 && colorMask.1 && colorMask.2 && (colorMask.3 || !t.colorAlpha))
    let stencilWhole = c.stencil == nil || stencilFront.writeMask & 0xFF == 0xFF
    if whole && colorWhole && stencilWhole {
      // Before the pass draws: what it loads.
      if frame.pass == nil || frame.pass!.target != t {
        frame.endPass()
        frame.pass = OpenPass(target: t)
      }
      if !frame.pass!.begun {
        if let v = c.color { frame.pass!.clear.color = v }
        if let v = c.depth { frame.pass!.clear.depth = v }
        if let v = c.stencil { frame.pass!.clear.stencil = v }
        return
      }
    }
    guard area.width > 0, area.height > 0 else { return }
    guard frame.limits.features.clearAttachments else {
      say("a clear of part of the framebuffer: the device has no clears inside a pass")
      return
    }
    // In the pass: a clear of the attachments' rectangle.
    openPass(t, reads: [])
    var attachments: [ClearAttachment] = []
    if let v = c.color { attachments.append(.color(index: 0, .float(v.0, v.1, v.2, t.colorAlpha ? v.3 : 1))) }
    var aspects = ImageAspects(rawValue: 0)
    if c.depth != nil { aspects = aspects | .depth }
    if c.stencil != nil { aspects = aspects | .stencil }
    if !aspects.isEmpty { attachments.append(.depthStencil(aspects: aspects, depth: c.depth ?? 1, stencil: c.stencil ?? 0)) }
    frame.list.clearAttachments(attachments, rects: [ClearRect(x: area.x, y: area.y, width: area.width, height: area.height)])
    frame.pass!.draws += 1
    if c.depth != nil { frame.pass!.usedDepth = true }
    if c.color != nil { frame.pass!.usedColor = true }
    if c.stencil != nil { frame.pass!.usedStencil = true }
  }

  // MARK: Discarding

  /// glDiscardFramebufferEXT: the open pass on the bound framebuffer doesn't store what is named.
  func discard(_ attachments: [GLenum]) {
    let fbo = framebuffer != nil
    for a in attachments {
      switch a {
      case GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT, GL_STENCIL_ATTACHMENT: if !fbo { return fail(.invalidEnum) }
      case GL_COLOR_EXT, GL_DEPTH_EXT, GL_STENCIL_EXT: if fbo { return fail(.invalidEnum) }
      default: return fail(.invalidEnum)
      }
    }
    guard let t = currentTarget(), frame.pass?.target == t else { return }
    for a in attachments {
      switch a {
      case GL_COLOR_ATTACHMENT0, GL_COLOR_EXT: frame.pass!.discardColor = true
      case GL_DEPTH_ATTACHMENT, GL_DEPTH_EXT: frame.pass!.discardDepth = true
      default: frame.pass!.discardStencil = true
      }
    }
  }

  // MARK: Reading, flushing and finishing

  func readPixels(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum,
                  _ pixels: UnsafeMutableRawPointer?) {
    guard width >= 0, height >= 0 else { return fail(.invalidValue) }
    guard format == GL_RGBA || format == GL_RGB || format == GL_ALPHA || format == GL_LUMINANCE || format == GL_LUMINANCE_ALPHA
    else { return fail(.invalidEnum) }
    guard type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_SHORT_5_6_5 || type == GL_UNSIGNED_SHORT_4_4_4_4
      || type == GL_UNSIGNED_SHORT_5_5_5_1
    else { return fail(.invalidEnum) }
    // RGBA and UNSIGNED_BYTE, which is also the implementation's read format.
    guard format == GL_RGBA, type == GL_UNSIGNED_BYTE else { return fail(.invalidOperation) }
    guard let t = currentTarget() else { return }
    guard let color = t.color, let pixels = unsafe pixels, width > 0, height > 0 else { return }
    let x0 = max(x, 0), y0 = max(y, 0), x1 = min(x + width, t.width), y1 = min(y + height, t.height)
    guard x1 > x0, y1 > y0 else { return }
    let w = Int(x1 - x0), h = Int(y1 - y0)
    do throws(GPUError) {
      let m = try readbackMemory(w * h * 4)
      frame.endPass()
      // An image no copy reads (drawn into and sampled alone) is drawn into one that can be read first.
      let source = try copyable(color, width: t.width, height: t.height)
      frame.barrier(before: [source.image.handle])
      let sy = t.flipped ? t.height - y1 : y0
      frame.list.copy(source.image, to: m, regions: [
        BufferImageRegion(subresource: ImageSubresourceLayers(mip: source.baseMip, baseLayer: source.baseLayer),
                          imageOffset: Offset3D(x: x0, y: sy), imageExtent: Extent3D(width: UInt32(w), height: UInt32(h))),
      ])
      try frame.finish()
      let rowBytes = align(Int(width) * 4, packAlignment)
      let out = unsafe pixels + Int(y0 - y) * rowBytes + Int(x0 - x) * 4
      unsafe readBack(m.pointer!, sourceRowBytes: w * 4, width: w, height: h, bgra: color.format == .bgra8 || color.format == .bgra8srgb,
                      flip: t.flipped, opaque: !t.colorAlpha, into: out, rowBytes: rowBytes)
    } catch { fail(error) }
  }

  /// Readback memory of at least `bytes`, kept for the next ReadPixels.
  func readbackMemory(_ bytes: Int) throws(GPUError) -> GPUMemory {
    if let m = readback, m.size >= bytes { return m }
    if let m = readback { frame.release(m) }
    let m = try device.allocate(.readback, bytes: max(bytes, 4096))
    readback = m
    return m
  }

  func flush() {
    do throws(GPUError) { try frame.submit() } catch { fail(error) }
  }

  func finish() {
    do throws(GPUError) { try frame.finish() } catch { fail(error) }
    frame.frameEnded()
  }
}
