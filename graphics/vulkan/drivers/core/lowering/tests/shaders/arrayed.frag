// SPDX-License-Identifier: BSD-3-Clause
// An array of textures and a sampler, indexed by a flat varying: a handle that can differ between lanes.
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture2D textures[4];
layout(set = 0, binding = 1) uniform sampler smp;
layout(location = 0) flat in int which;
layout(location = 1) in vec2 uv;
layout(location = 0) out vec4 color;
void main() {
  color = texture(sampler2D(textures[nonuniformEXT(which)], smp), uv);
}
