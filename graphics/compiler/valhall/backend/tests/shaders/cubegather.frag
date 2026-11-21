#version 450
layout(set = 0, binding = 0) uniform textureCube tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec3 dir;
layout(location = 0) out vec4 c0;
void main() { c0 = textureGather(samplerCube(tex, smp), dir, 2); }
