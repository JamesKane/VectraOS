// SPDX-License-Identifier: BSD-3-Clause
// A quad over the whole viewport, and what a fragment shader needs to read a heap texture: its slot, the sampler's, a
// level of detail, a third coordinate and a direction. The root points at those 32 bytes.
#version 460
#extension GL_EXT_buffer_reference : require
layout(buffer_reference, std430) readonly buffer Params {
  uint texture;
  uint samplerSlot;
  float lod;
  float w;
  vec4 direction;
};
layout(push_constant) uniform Root { Params params; } root;
layout(location = 0) out vec2 uv;
layout(location = 1) flat out uint textureIndex;
layout(location = 2) flat out uint samplerIndex;
layout(location = 3) flat out vec4 extra;  // lod, w, unused, unused
layout(location = 4) flat out vec4 direction;
void main() {
  vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(1, 0), vec2(1, 1), vec2(0, 1));
  uv = corners[gl_VertexIndex];
  textureIndex = root.params.texture;
  samplerIndex = root.params.samplerSlot;
  extra = vec4(root.params.lod, root.params.w, 0, 0);
  direction = root.params.direction;
  gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
