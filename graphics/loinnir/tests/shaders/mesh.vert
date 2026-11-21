// SPDX-License-Identifier: BSD-3-Clause
// Vertices read through the root pointer, with a clip-space position (so a test sets the depth) and a colour: the
// scenes of the core's test (depth, stencil, MSAA, blending, culling).
#version 460
#extension GL_EXT_buffer_reference : require

struct Vertex {
  vec4 position;
  vec4 color;  // a vertex is 32 bytes
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Vertices { Vertex v[]; };
layout(push_constant) uniform Root { Vertices vertices; } root;

layout(location = 0) out vec4 color;

void main() {
  Vertex v = root.vertices.v[gl_VertexIndex];
  gl_Position = v.position;
  color = v.color;
}
