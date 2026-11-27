// SPDX-License-Identifier: BSD-3-Clause
// gl-test and gles(3)'s host tests: a position and a texture coordinate.
#version 450
layout(location = 0) in vec4 position;
layout(location = 1) in vec2 texcoord;
layout(set = 0, binding = 0, std140) uniform Uniforms { vec4 transform; vec4 color; };
layout(location = 0) out vec2 uv;
void main() { uv = texcoord; gl_Position = vec4(position.xy * transform.xy + transform.zw, position.zw); }
