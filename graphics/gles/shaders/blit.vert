// SPDX-License-Identifier: BSD-3-Clause
// gles(2)'s copy by a draw: a triangle over the whole target, for blit.frag.
#version 450
void main() {
  vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
