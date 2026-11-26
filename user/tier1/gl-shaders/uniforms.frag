// SPDX-License-Identifier: BSD-3-Clause
// gles(3)'s host tests: the fragment stage of uniforms.vert's program, two samplers.
#version 450
struct Light { vec4 position; float power; };
layout(set = 0, binding = 0, std140) uniform Uniforms { float f; vec2 v2; vec3 v3; int i; bool b; float weights[3]; mat3 m3; mat4 m4; Light light; ivec4 iv; };
layout(set = 0, binding = 1) uniform sampler2D base;
layout(set = 0, binding = 2) uniform sampler2D detail;
layout(location = 0) out vec4 fragColor;
void main() { fragColor = texture(base, vec2(0.5)) + texture(detail, vec2(0.25)) * f; }
