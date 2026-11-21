#version 450
layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
layout(location = 2) out vec4 c2;
void main() {
  c0 = textureGather(sampler2D(tex, smp), uv, 1);
  c1 = textureGatherOffset(sampler2D(tex, smp), uv, ivec2(1, 0), 2);
  c2 = textureGather(sampler2D(tex, smp), uv);
}
