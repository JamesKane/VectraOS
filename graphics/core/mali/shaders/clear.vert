// SPDX-License-Identifier: BSD-3-Clause
// The Mali backend's clear inside a pass (gpucore(2) `clearAttachments`): a rectangle over the whole viewport at the
// depth the clear writes, two triangles of six vertices; the draw's scissor is the rectangle cleared. The push words are
// the colour (0 to 3) and the depth (4), the same words for both stages.
#version 460
layout(push_constant) uniform Clear { vec4 colour; float depth; } clear;
void main() {
  int i = gl_VertexIndex;
  float x = (i == 1 || i == 4 || i == 5) ? 1.0 : -1.0;
  float y = (i == 2 || i == 3 || i == 5) ? 1.0 : -1.0;
  gl_Position = vec4(x, y, clear.depth, 1.0);
}
