// SPDX-License-Identifier: BSD-3-Clause

// The whole decision of valhall 09 section 9.7.1 for a target, and the descriptor in mode Shader (09 section 9.2.2, 9.10.1).

import MaliCore
import Testing

@Suite struct BlendPlanTests {
  private func planned(_ s: BlendState, srgb: Bool = false) -> (descriptor: BlendDescriptor, shader: BlendShaderSpec?) {
    BlendDescriptor.planned(s, renderTarget: 0, isSRGB: srgb)
  }

  @Test func whatTheBlenderDoesStaysFixedFunction() {
    #expect(planned(.disabled).descriptor.mode == .opaque && planned(.disabled).shader == nil)
    #expect(planned(BlendState(enabled: true, equation: .alpha)).descriptor.mode == .fixedFunction)
    #expect(planned(BlendState(enabled: true, writeMask: 0)).descriptor.mode == .off)
    // A no-op logic operation on a target that is neither float nor sRGB writes nothing.
    #expect(planned(BlendState(enabled: false, logicOp: .noop)).descriptor.mode == .off)
  }

  @Test func whatItCantDoGetsAShader() {
    let max = BlendEquation(
      colourOperation: .max, colourSource: .one, colourDestination: .one, alphaOperation: .max, alphaSource: .one, alphaDestination: .one)
    for s in [
      BlendState(enabled: true, equation: max), BlendState(enabled: true, logicOp: .xor), BlendState(enabled: false, alphaToOne: true),
      BlendState(enabled: true, equation: BlendEquation(colourSource: .src1Colour, colourDestination: .zero, alphaSource: .one, alphaDestination: .zero)),
      BlendState(enabled: true, equation: BlendEquation(colourSource: .constantColour, colourDestination: .zero, alphaSource: .one, alphaDestination: .zero), constant: [0.1, 0.2, 0.3, 1]),
    ] {
      let p = planned(s)
      #expect(p.descriptor.mode == .shader && p.shader != nil, "\(s)")
    }
    // A logic operation on sRGB is a shader even when it is a no-op (the source is stored).
    #expect(planned(BlendState(enabled: false, logicOp: .noop), srgb: true).shader != nil)
  }

  @Test func theShaderDescriptorIsTheWorkedOne() {
    let spec = BlendShaderSpec(blending: true)
    var d = BlendDescriptor(shader: spec, address: 0x1230)
    // A shader that reads no destination has no Load Destination; the worked shaders of 9.10.1 do.
    #expect(d.words == [0x0000_0A00, 0, 0, 0x1230])
    d = BlendDescriptor(shader: BlendShaderSpec(blending: true, equation: BlendEquation(
      colourOperation: .max, colourSource: .one, colourDestination: .one, alphaOperation: .max, alphaSource: .one, alphaDestination: .one)),
      address: 0x1230)
    #expect(d.words == [0x0000_0A01, 0, 0, 0x1230])
    #expect(BlendShaderSpec(renderTarget: 0).opaqueOperand == 0x000E_D000_0000_0019)
  }
}
