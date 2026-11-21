#version 450
layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 extra;
layout(location = 0) out vec4 col;
void main() { col = texture(sampler2D(tex, smp), uv, extra.x); }
