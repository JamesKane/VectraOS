// SPDX-License-Identifier: BSD-3-Clause
// gles(2)'s mipmaps by a draw: each texel of a level the filtered mean of the four of the level above (a sampler
// that filters linearly, at the centre of the four), for blit.vert's triangle.
#version 450
layout(set = 0, binding = 1) uniform sampler2D source;
layout(location = 0) out vec4 color;
void main() {
  vec2 size = max(vec2(textureSize(source, 0)) * 0.5, vec2(1.0));
  color = textureLod(source, gl_FragCoord.xy / floor(size), 0.0);
}
