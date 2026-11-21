#version 450
layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec2 uv;
layout(location = 1) flat in ivec4 info;
layout(location = 0) out vec4 c0;
layout(location = 1) out ivec4 c1;
layout(location = 2) out vec4 c2;
void main() {
  ivec2 s = textureSize(sampler2D(tex, smp), info.x);
  c1 = ivec4(s, textureQueryLevels(sampler2D(tex, smp)), 7);
  c0 = vec4(textureQueryLod(sampler2D(tex, smp), uv), 0.0, 1.0);
  c2 = vec4(float(s.x), float(s.y), 0.0, 1.0);
}
