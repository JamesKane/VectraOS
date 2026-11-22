// SPDX-License-Identifier: BSD-3-Clause

// The decision of valhall 09 section 9.7.1 for one render target, whole: fixed function or opaque where the blender can do
// the state, a blend shader where it can't (BlendShaderSpec.swift says what the shader computes).

extension BlendDescriptor {
  /// The descriptor of a target by 9.7.1's procedure. A target that needs a blend shader gets a descriptor in mode Shader
  /// whose address is not set, and the spec of the shader. `firstConstant` is the constant an earlier fixed-function target
  /// of the draw used.
  public static func planned(_ state: BlendState, renderTarget: Int, isSRGB: Bool, firstConstant: UInt32? = nil)
    -> (descriptor: BlendDescriptor, shader: BlendShaderSpec?)
  {
    // Row 1: nothing to write, or a no-op logic operation on a target that is neither float nor sRGB.
    if state.writeMask & 0xF == 0 || (state.logicOp == .noop && !isSRGB) {
      var off = BlendDescriptor(renderTarget: renderTarget, isSRGB: isSRGB)
      off.mode = .off
      return (off, nil)
    }
    do throws(BlendRefusal) {
      return (try BlendDescriptor(state: state, renderTarget: renderTarget, isSRGB: isSRGB, firstConstant: firstConstant), nil)
    } catch {
      let spec = BlendShaderSpec(
        renderTarget: renderTarget, isSRGB: isSRGB, blending: state.enabled, equation: state.equation, writeMask: state.writeMask,
        logic: state.logicOp, alphaToOne: state.alphaToOne)
      return (BlendDescriptor(shader: spec), spec)
    }
  }
}
