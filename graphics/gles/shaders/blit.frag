// SPDX-License-Identifier: BSD-3-Clause
// gles(2)'s copy by a draw: each texel of the source's level 0 where the target's is, exactly (an image no copy
// reads, a compressed attachment, copied into one that can be).
#version 450
layout(set = 0, binding = 1) uniform sampler2D source;
layout(location = 0) out vec4 color;
void main() { color = texelFetch(source, ivec2(gl_FragCoord.xy), 0); }
