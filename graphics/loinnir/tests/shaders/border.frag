// SPDX-License-Identifier: BSD-3-Clause
// A 2D texture sampled over three times its width, from -1 to 2 across the quad: the outer thirds are what the sampler's border is.
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];
layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint textureIndex;
layout(location = 2) flat in uint samplerIndex;
layout(location = 3) flat in vec4 extra;
layout(location = 4) flat in vec4 direction;
layout(location = 0) out vec4 outColor;
void main() {
  outColor = textureLod(sampler2D(textures[nonuniformEXT(textureIndex)], samplers[nonuniformEXT(samplerIndex)]),
                        vec2(uv.x * 3.0 - 1.0, uv.y), 0.0);
}
