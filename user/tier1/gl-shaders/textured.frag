// SPDX-License-Identifier: BSD-3-Clause
// gl-test and gles(3)'s host tests: a texture by the uniform colour.
#version 450
layout(set = 0, binding = 0, std140) uniform Uniforms { vec4 transform; vec4 color; };
layout(set = 0, binding = 1) uniform sampler2D tex;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;
void main() { fragColor = texture(tex, uv) * color; }
