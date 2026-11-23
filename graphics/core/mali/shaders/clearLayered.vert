// SPDX-License-Identifier: BSD-3-Clause
// clear.vert for a clear of layers of a pass of layers: instance i draws into layer `base + i` (Layer, the extended record and the
// draw's layer index, valhall 06 section 6.12). The push words are the colour (0 to 3), the depth (4) and the first layer (5).
#version 460
#extension GL_ARB_shader_viewport_layer_array : require
layout(push_constant) uniform Clear { vec4 colour; float depth; int base; } clear;
void main() {
  int i = gl_VertexIndex;
  float x = (i == 1 || i == 4 || i == 5) ? 1.0 : -1.0;
  float y = (i == 2 || i == 3 || i == 5) ? 1.0 : -1.0;
  gl_Position = vec4(x, y, clear.depth, 1.0);
  gl_Layer = clear.base + gl_InstanceIndex;
}
