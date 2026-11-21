// SPDX-License-Identifier: BSD-3-Clause
// Vertex buffers: a float3 position and an rgba8 colour (binding 0), and a per-instance offset (binding 1).
#version 460
layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 shift;
layout(location = 0) out vec4 vertexColor;
void main() {
  vertexColor = color;
  gl_Position = vec4(position.xy + shift, position.z, 1.0);
}
