// SPDX-License-Identifier: BSD-3-Clause
// The stencil reference from the shader (FragStencilRefEXT) beside the depth: ZS_EMIT with both (12c.6.2).
#version 460
#extension GL_ARB_shader_stencil_export : require
void main() {
  gl_FragStencilRefARB = int(gl_FragCoord.x) + 3;
  gl_FragDepth = 0.25;
}
