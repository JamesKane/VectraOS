// SPDX-License-Identifier: BSD-3-Clause
// The resource cases: a signed integer 2D texture read at the quad's coordinates; each channel is written as
// (value + 128) / 255, so a value from -128 to 127 is the byte it reads minus 128.
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform itexture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];
layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint textureIndex;
layout(location = 2) flat in uint samplerIndex;
layout(location = 3) flat in vec4 extra;
layout(location = 4) flat in vec4 direction;
layout(location = 0) out vec4 outColor;
void main() {
  ivec4 t = textureLod(isampler2D(textures[nonuniformEXT(textureIndex)], samplers[nonuniformEXT(samplerIndex)]), uv, 0.0);
  outColor = (vec4(t) + 128.0) / 255.0;
}
