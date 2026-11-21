#version 450
layout(location = 0) out vec4 c0;
in float gl_ClipDistance[2];
void main() { c0 = vec4(gl_ClipDistance[1]); }
