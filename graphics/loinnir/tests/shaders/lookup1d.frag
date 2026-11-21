// SPDX-License-Identifier: BSD-3-Clause
// A 1D texture sampled at the quad's horizontal coordinate: a lookup table.
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture1D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];
layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint textureIndex;
layout(location = 2) flat in uint samplerIndex;
layout(location = 3) flat in vec4 extra;
layout(location = 4) flat in vec4 direction;
layout(location = 0) out vec4 outColor;
void main() {
  outColor = textureLod(sampler1D(textures[nonuniformEXT(textureIndex)], samplers[nonuniformEXT(samplerIndex)]), uv.x, 0.0);
}
