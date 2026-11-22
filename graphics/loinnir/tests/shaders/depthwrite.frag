// SPDX-License-Identifier: BSD-3-Clause
// The fragment shader writes the depth: the vertex colour's alpha (the core's late depth test).
#version 460
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 outColor;
void main() {
  outColor = vec4(color.rgb, 1.0);
  gl_FragDepth = color.a;
}
