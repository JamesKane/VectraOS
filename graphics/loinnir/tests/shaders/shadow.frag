// SPDX-License-Identifier: BSD-3-Clause
// The resource cases: a depth texture compared with the reference the root gives in extra.x (the sampler's compare function:
// reference op depth), written as 0 or 1 in every colour channel.
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform samplerShadow samplers[];
layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint textureIndex;
layout(location = 2) flat in uint samplerIndex;
layout(location = 3) flat in vec4 extra;
layout(location = 4) flat in vec4 direction;
layout(location = 0) out vec4 outColor;
void main() {
  float r = textureLod(sampler2DShadow(textures[nonuniformEXT(textureIndex)], samplers[nonuniformEXT(samplerIndex)]), vec3(uv, extra.x), 0.0);
  outColor = vec4(r, r, r, 1.0);
}
