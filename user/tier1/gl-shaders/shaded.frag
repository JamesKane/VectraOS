// SPDX-License-Identifier: BSD-3-Clause
// gl-test and gles(3)'s host tests: the colour each vertex gave.
#version 450
layout(location = 0) in vec4 shade;
layout(location = 0) out vec4 fragColor;
void main() { fragColor = shade; }
