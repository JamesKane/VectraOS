// SPDX-License-Identifier: BSD-3-Clause
// A combined image sampler of a 1D image: a lookup table read at one coordinate.
#version 460
layout(set = 0, binding = 0) uniform sampler1D lut;
layout(location = 0) in float u;
layout(location = 0) out vec4 color;
void main() {
  color = texture(lut, u);
}
