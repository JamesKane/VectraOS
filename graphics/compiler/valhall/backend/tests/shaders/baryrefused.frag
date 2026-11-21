#version 450
#extension GL_EXT_fragment_shader_barycentric : enable
layout(location = 0) out vec4 c0;
void main() { c0 = vec4(gl_BaryCoordEXT, 1.0); }
