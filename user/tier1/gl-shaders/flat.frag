// SPDX-License-Identifier: BSD-3-Clause
// gl-test and gles(3)'s host tests: the uniform colour.
#version 450
layout(set = 0, binding = 0, std140) uniform Uniforms { vec4 transform; vec4 color; };
layout(location = 0) out vec4 fragColor;
void main() { fragColor = color; }
