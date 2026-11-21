#version 450
layout(set = 0, binding = 0) uniform texture3D tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec3 uvw;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
void main() {
  c0 = texture(sampler3D(tex, smp), uvw);
  c1 = vec4(vec3(textureSize(sampler3D(tex, smp), 1)), 1.0);
}
