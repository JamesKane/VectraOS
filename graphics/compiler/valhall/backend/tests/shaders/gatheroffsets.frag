#version 450
#extension GL_ARB_gpu_shader5 : enable
layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 c0;
void main() {
  c0 = textureGatherOffsets(sampler2D(tex, smp), uv, ivec2[4](ivec2(0, 0), ivec2(2, 0), ivec2(0, 3), ivec2(-1, -1)), 0);
}
