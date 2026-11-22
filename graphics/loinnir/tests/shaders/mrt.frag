// SPDX-License-Identifier: BSD-3-Clause
// Three colour outputs from one vertex colour: the same, its channels reversed, and half of it (the core's multiple colour targets).
#version 460
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 out0;
layout(location = 1) out vec4 out1;
layout(location = 2) out vec4 out2;
void main() {
  out0 = color;
  out1 = vec4(color.bgr, 1.0);
  out2 = color * 0.5;
}
