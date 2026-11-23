// SPDX-License-Identifier: BSD-3-Clause
// mesh.vert for the core's layers case: instance i draws into layer i (Layer from the vertex stage), its red 20 * i of 255 and the
// rest the vertex's colour.
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
  gl_Layer = gl_InstanceIndex;
  color = vec4(float(20 * gl_InstanceIndex) / 255.0, v.color.gba);
}
