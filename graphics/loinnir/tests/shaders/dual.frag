// SPDX-License-Identifier: BSD-3-Clause
#version 460
layout(location = 0) in vec4 color;
layout(location = 0, index = 0) out vec4 outColor;
layout(location = 0, index = 1) out vec4 outSecond;
void main() { outColor = color; outSecond = vec4(1.0) - color; }
