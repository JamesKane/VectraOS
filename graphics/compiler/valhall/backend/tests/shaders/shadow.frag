#version 450
layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform samplerShadow smp;
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 extra;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
layout(location = 2) out vec4 c2;
void main() {
  c0 = vec4(texture(sampler2DShadow(tex, smp), vec3(uv, extra.x)));
  c1 = vec4(textureLod(sampler2DShadow(tex, smp), vec3(uv, extra.x), 1.0));
  c2 = textureGather(sampler2DShadow(tex, smp), uv, extra.x);
}
