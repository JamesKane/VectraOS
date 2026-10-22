// SPDX-License-Identifier: BSD-3-Clause
// A full-target quad (two triangles) sampling one heap texture; the root
// points at the texture's index.
#version 460
#extension GL_EXT_buffer_reference : require
layout(buffer_reference, std430) readonly buffer Params { uint texture; };
layout(push_constant) uniform Root { Params params; } root;
layout(location = 0) out vec2 uv;
layout(location = 1) flat out uint textureIndex;
void main() {
  vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(1, 0), vec2(1, 1), vec2(0, 1));
  uv = corners[gl_VertexIndex];
  textureIndex = root.params.texture;
  gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
