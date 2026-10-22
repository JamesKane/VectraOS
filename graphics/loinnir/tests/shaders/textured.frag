// SPDX-License-Identifier: BSD-3-Clause
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler linearSampler;
layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint textureIndex;
layout(location = 0) out vec4 outColor;
void main() { outColor = texture(sampler2D(textures[nonuniformEXT(textureIndex)], linearSampler), uv); }
