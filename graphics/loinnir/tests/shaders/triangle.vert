// SPDX-License-Identifier: BSD-3-Clause
// A triangle read through the root pointer: no vertex buffers.
#version 460
#extension GL_EXT_buffer_reference : require

struct Vertex {
  vec2 position;
  vec4 color;  // std430: offset 16, so a vertex is 32 bytes
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Vertices { Vertex v[]; };
layout(push_constant) uniform Root { Vertices vertices; } root;

layout(location = 0) out vec4 color;

void main() {
  Vertex v = root.vertices.v[gl_VertexIndex];
  gl_Position = vec4(v.position, 0.0, 1.0);
  color = v.color;
}
