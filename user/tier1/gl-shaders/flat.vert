// SPDX-License-Identifier: BSD-3-Clause
// gl-test (gl-test(8)) and gles(3)'s host tests: a position scaled and moved in x and y (the compiler takes no
// matrices yet), in GL ES 2.0's clip space (z from -w to w), the block both stages share.
#version 450
layout(location = 0) in vec4 position;
layout(set = 0, binding = 0, std140) uniform Uniforms { vec4 transform; vec4 color; };
void main() { gl_Position = vec4(position.xy * transform.xy + transform.zw, position.zw); }
