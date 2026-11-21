#version 450
#extension GL_EXT_nonuniform_qualifier : enable
layout(set = 0, binding = 0) uniform texture2D texs[3];
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec2 uv;
layout(location = 1) flat in int which;
layout(location = 0) out vec4 c0;
void main() { c0 = texture(sampler2D(texs[nonuniformEXT(which)], smp), uv); }
