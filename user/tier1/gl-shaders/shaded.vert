// SPDX-License-Identifier: BSD-3-Clause
// gl-test and gles(3)'s host tests: a colour for each vertex.
#version 450
layout(location = 0) in vec4 position;
layout(location = 1) in vec4 vertexColor;
layout(location = 0) out vec4 shade;
void main() { shade = vertexColor; gl_Position = position; }
