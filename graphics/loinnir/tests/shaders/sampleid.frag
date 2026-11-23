// SPDX-License-Identifier: BSD-3-Clause
// The core's MSAA case: a colour of each sample's own (red on the odd samples, none on the even), so a resolve of a shader run per
// sample is half red wherever the primitive covers the pixel.
#version 460
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 outColor;
void main() { outColor = vec4((gl_SampleID & 1) == 1 ? 1.0 : 0.0, 0.0, 0.0, 1.0); }
