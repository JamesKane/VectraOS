// SPDX-License-Identifier: BSD-3-Clause
// mesh.vert for the core's viewports case: instance i draws with viewport i (ViewportIndex from the vertex stage), the first
// in the vertex's colour and the second in it with red and green swapped.
#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_ARB_shader_viewport_layer_array : require

struct Vertex {
  vec4 position;
  vec4 color;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Vertices { Vertex v[]; };
layout(push_constant) uniform Root { Vertices vertices; } root;

layout(location = 0) out vec4 color;

void main() {
  Vertex v = root.vertices.v[gl_VertexIndex];
  gl_Position = v.position;
  gl_ViewportIndex = gl_InstanceIndex;
  color = gl_InstanceIndex == 0 ? v.color : v.color.grba;
}
