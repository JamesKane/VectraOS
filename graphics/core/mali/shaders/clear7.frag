// SPDX-License-Identifier: BSD-3-Clause
// The Mali backend's clear of colour attachment 7 inside a pass (clear.vert): the push words' colour, written as it is.
#version 460
layout(push_constant) uniform Clear { vec4 colour; float depth; } clear;
layout(location = 7) out vec4 outColor;
void main() { outColor = clear.colour; }
