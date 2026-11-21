// SPDX-License-Identifier: BSD-3-Clause
// A 3D texture sampled at the depth the root gives.
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture3D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];
layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint textureIndex;
layout(location = 2) flat in uint samplerIndex;
layout(location = 3) flat in vec4 extra;
layout(location = 4) flat in vec4 direction;
layout(location = 0) out vec4 outColor;
void main() {
  outColor = textureLod(sampler3D(textures[nonuniformEXT(textureIndex)], samplers[nonuniformEXT(samplerIndex)]), vec3(uv, extra.y), 0.0);
}
