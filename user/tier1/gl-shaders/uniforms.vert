// SPDX-License-Identifier: BSD-3-Clause
// gles(3)'s host tests: a block of every kind of uniform, std140, read by the reflection and written by glUniform*.
#version 450
struct Light { vec4 position; float power; };
layout(set = 0, binding = 0, std140) uniform Uniforms { float f; vec2 v2; vec3 v3; int i; bool b; float weights[3]; mat3 m3; mat4 m4; Light light; ivec4 iv; };
layout(location = 0) in vec4 position;
void main() { gl_Position = position * f + vec4(v2, v3.x, float(i)) + vec4(b ? 1.0 : 0.0) + vec4(weights[2]) + vec4(m3[1], 1.0) + m4[3] + light.position * light.power + vec4(iv); }
