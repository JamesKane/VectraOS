// SPDX-License-Identifier: BSD-3-Clause
// mesh.vert for the core's multiview case: view v's position is moved 0.25 right per view (two pixels of a 16-pixel target) and its
// red is 20 * v of 255, so each view's layer shows that its position and its varying are its own.
#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_multiview : require

struct Vertex {
  vec4 position;
  vec4 color;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Vertices { Vertex v[]; };
layout(push_constant) uniform Root { Vertices vertices; } root;

layout(location = 0) out vec4 color;

void main() {
  Vertex v = root.vertices.v[gl_VertexIndex];
  gl_Position = v.position + vec4(0.25 * float(gl_ViewIndex), 0.0, 0.0, 0.0);
  color = vec4(float(20 * int(gl_ViewIndex)) / 255.0, v.color.gba);
}
