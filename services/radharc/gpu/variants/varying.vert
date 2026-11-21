// SPDX-License-Identifier: BSD-3-Clause
// A diagnostic variant of Radharc's compose shaders (compose-test's bisection of the quads the GPU leaves clear): an interpolated (not flat) varying added.
#version 460
#extension GL_EXT_buffer_reference : require
struct Quad {
  vec4 rect;      // x, y, width, height, in pixels
  ivec4 source;   // source x, y in the texture; the texture's heap index; the kind
  uvec4 color;    // 0x00RRGGBB, then padding
};
layout(buffer_reference, std430) readonly buffer Params { vec4 screen; Quad quads[]; };
layout(push_constant) uniform Root { Params params; } root;
layout(location = 0) flat out ivec4 source;
layout(location = 1) flat out uint color;
layout(location = 2) flat out vec2 origin;
layout(location = 3) out float wobble;
void main() {
  vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(1, 0), vec2(1, 1), vec2(0, 1));
  Quad q = root.params.quads[gl_InstanceIndex];
  vec2 p = q.rect.xy + corners[gl_VertexIndex] * q.rect.zw;
  source = q.source;
  color = q.color.x;
  origin = q.rect.xy;
  wobble = corners[gl_VertexIndex].x;
  gl_Position = vec4(p / root.params.screen.xy * 2.0 - 1.0, 0.0, 1.0);
}
