// SPDX-License-Identifier: BSD-3-Clause
// A vertex shader of a multiview draw: its position and its varying depend on the view (ViewIndex).
#version 460
#extension GL_EXT_multiview : require
layout(location = 0) out vec4 c;
void main() {
  gl_Position = vec4(float(gl_ViewIndex), float(gl_VertexIndex), 0.0, 1.0);
  c = vec4(float(gl_ViewIndex) + 0.5);
}
