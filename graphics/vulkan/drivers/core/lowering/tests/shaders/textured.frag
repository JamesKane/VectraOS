// SPDX-License-Identifier: BSD-3-Clause
// A uniform buffer and a combined image sampler, in set 1: the colour of a texel, tinted.
#version 460
layout(set = 1, binding = 0, std140) uniform Params { vec4 tint; float gain; } params;
layout(set = 1, binding = 1) uniform sampler2D tex;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
void main() {
  color = texture(tex, uv) * params.tint * params.gain;
}
