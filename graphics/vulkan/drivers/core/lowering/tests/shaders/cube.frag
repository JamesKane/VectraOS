// SPDX-License-Identifier: BSD-3-Clause
// A cube map: the layer takes no images but 2D ones.
#version 460
layout(set = 0, binding = 0) uniform samplerCube env;
layout(location = 0) in vec3 dir;
layout(location = 0) out vec4 color;
void main() { color = texture(env, dir); }
