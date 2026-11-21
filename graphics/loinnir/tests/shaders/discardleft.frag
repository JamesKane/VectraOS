// SPDX-License-Identifier: BSD-3-Clause
// The fragment shader discards the left half of an 8 pixel target by the pixel's x (the core's late depth update).
#version 460
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 outColor;
void main() {
  if (gl_FragCoord.x < 4.0) discard;
  outColor = color;
}
