#version 450
layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) flat in ivec4 info;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
void main() {
  ivec2 p = ivec2(gl_FragCoord.xy);
  c0 = texelFetch(sampler2D(tex, smp), p, info.x);
  c1 = texelFetchOffset(sampler2D(tex, smp), p, 1, ivec2(2, 1));
}
