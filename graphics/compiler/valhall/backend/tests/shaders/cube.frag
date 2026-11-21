#version 450
layout(set = 0, binding = 0) uniform textureCube tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec3 dir;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
void main() {
  c0 = texture(samplerCube(tex, smp), dir);
  c1 = vec4(vec2(textureSize(samplerCube(tex, smp), 0)), 0.0, 1.0);
}
