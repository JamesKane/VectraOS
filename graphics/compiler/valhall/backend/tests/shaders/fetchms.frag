#version 450
#extension GL_EXT_samplerless_texture_functions : enable
layout(set = 0, binding = 0) uniform texture2DMS tex;
layout(location = 0) flat in ivec4 info;
layout(location = 0) out vec4 c0;
void main() {
  c0 = texelFetch(tex, ivec2(gl_FragCoord.xy), info.x);
}
