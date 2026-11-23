// SPDX-License-Identifier: BSD-3-Clause

// `clearAttachments` on Mali (gpucore(2)): a clear inside a pass is a draw of the pass, in order with the others. The
// hardware's clears are the tile's starting values (valhall 08 section 8.7), which a pass has once; a clear between draws is
// drawn. Each rectangle is the draw's scissor (06 section 6.7.1) over a rectangle that covers the viewport (the whole
// target, depth 0 to 1); a colour attachment's draw writes the colour through its own fragment shader (one per location,
// MaliShaders' clear0 to clear7) with an opaque blend and every other target off; the depth and stencil are one draw whose
// rectangle is at the depth cleared, with the depth test Always and the depth written, and the stencil test Always with
// Replace by the value cleared, and no colour written (every blend descriptor off, 09 section 9.3: a BLEND to an off target
// is a no-op). The application's viewport, scissor and state are not used, as Vulkan's clear says.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

extension MaliDevice {
  /// The clear's vertex shaders (one layer, and an instance a layer) and the fragment shader of each colour location, compiled at
  /// first use.
  func clearShaders() throws(GPUError) -> (vertex: VertexShader, layered: VertexShader, fragments: [FragmentShader]) {
    if let s = clearPrograms { return s }
    guard let vs = try compile(MaliShaders.clearVert).vertex, let layered = try compile(MaliShaders.clearLayeredVert).vertex else {
      throw .invalid("the clear module has no vertex shader")
    }
    var fs: [FragmentShader] = []
    for code in [MaliShaders.clear0Frag, MaliShaders.clear1Frag, MaliShaders.clear2Frag, MaliShaders.clear3Frag,
                 MaliShaders.clear4Frag, MaliShaders.clear5Frag, MaliShaders.clear6Frag, MaliShaders.clear7Frag] {
      guard let f = try compile(code).fragment else { throw .invalid("a clear module has no fragment shader") }
      fs.append(f)
    }
    clearPrograms = (vs, layered, fs)
    return (vs, layered, fs)
  }

  /// The draws of a `clearAttachments` in the pass being planned, whose colour targets are `planTargets`.
  func appendClears(
    _ attachments: [ClearAttachment], _ rects: [ClearRect], into draws: inout [PassDraw], target: ImageRecord?, zs: ZSBinding?,
    view: ImageView?, layers: Int
  ) throws(GPUError) {
    guard target != nil, let v = view else { throw .invalid("a clear of attachments outside a pass") }
    let shaders = try clearShaders()
    let width = Int(v.width), height = Int(v.height)
    let count = planTargets.count
    func off(_ target: Int) -> BlendDescriptor {
      BlendDescriptor.planned(BlendState(enabled: false, writeMask: 0), renderTarget: target,
                              isSRGB: planTargets[target].descriptor.format == .bgra8srgb).descriptor
    }
    func opaque(_ target: Int) -> BlendDescriptor {
      BlendDescriptor.planned(BlendState(enabled: false, writeMask: 0xF), renderTarget: target,
                              isSRGB: planTargets[target].descriptor.format == .bgra8srgb).descriptor
    }
    for rect in rects {
      let scissor = PipelineMapping.scissorBox(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height),
                                               targetWidth: width, targetHeight: height)
      for a in attachments {
        var colour: [Float] = [0, 0, 0, 0]
        var depth: Float = 0
        var location = 0
        var state = DrawPipelineState()
        state.scissor = scissor
        state.viewport = DrawViewport(x: 0, y: 0, width: Float(width), height: Float(height))
        var writesColour = false
        switch a {
        case .color(let index, let c):
          guard index >= 0 && index < count else { throw .invalid("a clear of a colour attachment the pass doesn't have") }
          guard case .float(let red, let green, let blue, let alpha) = c else {
            throw .unsupported("an integer clear colour: the pass's formats are normalized")
          }
          colour = [red, green, blue, alpha]
          location = index
          writesColour = true
        case .depthStencil(let aspects, let d, let s):
          guard let z = zs else { throw .invalid("a clear of a depth attachment the pass doesn't have") }
          let format = z.image.descriptor.format
          var ds = ZSDescriptorState()
          ds.depthFunction = 7
          if aspects.contains(.depth) && format.hasDepth {
            ds.depthWrite = true
            depth = min(max(d, 0), 1)
          }
          if aspects.contains(.stencil) && format.hasStencil {
            ds.stencilTest = true
            var face = StencilFaceWords()
            face.function = 7
            face.failOperation = 1
            face.depthFailOperation = 1
            face.passOperation = 1
            face.reference = s & 0xFF
            ds.front = face
            ds.back = face
          }
          state.depthStencil = ds
        }
        guard draws.count < 16 else { throw .unsupported("a pass of more than 16 draws") }
        // In a pass of layers, an instance for each layer cleared, which the vertex shader sends to its layer.
        let push = [colour[0].bitPattern, colour[1].bitPattern, colour[2].bitPattern, colour[3].bitPattern, depth.bitPattern, rect.baseLayer]
        var draw = PassDraw(vertexShader: layers > 1 ? shaders.layered : shaders.vertex, fragmentShader: shaders.fragments[location],
                            vertexCount: 6, instanceCount: layers > 1 ? Int(rect.layerCount) : 1, push: push,
                            blend: writesColour && location == 0 ? opaque(0) : off(0))
        var extra: [BlendDescriptor] = []
        for t in 1..<max(count, 1) { extra.append(writesColour && location == t ? opaque(t) : off(t)) }
        draw.extraBlends = count > 1 ? extra : []
        draw.state = state
        draws.append(draw)
      }
    }
  }
}
