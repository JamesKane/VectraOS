#version 450
layout(set = 0, binding = 0) uniform texture1D tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in float u;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
void main() {
  c0 = texture(sampler1D(tex, smp), u);
  c1 = vec4(float(textureSize(sampler1D(tex, smp), 1)), 0.0, 0.0, 1.0);
}
