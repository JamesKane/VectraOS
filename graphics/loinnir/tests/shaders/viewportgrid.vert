// SPDX-License-Identifier: BSD-3-Clause
// mesh.vert for the core's viewports cases: instance i draws with viewport i (ViewportIndex from the vertex stage), in a colour
// of its own: red i & 3, green (i >> 2) & 3 in thirds, blue 1 less (i >> 4) & 15 fifteenths (never black).
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
  uint k = uint(gl_InstanceIndex);
  color = vec4(float(k & 3u) / 3.0, float((k >> 2) & 3u) / 3.0, 1.0 - float((k >> 4) & 15u) / 15.0, 1.0);
}
