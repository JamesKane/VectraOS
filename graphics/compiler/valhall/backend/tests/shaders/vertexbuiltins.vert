#version 460
layout(location = 0) out vec4 o0;
layout(location = 1) flat out ivec4 o1;
out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };
void main() {
  o0 = vec4(float(gl_VertexIndex), float(gl_InstanceIndex), 0.0, 1.0);
  o1 = ivec4(gl_BaseVertex, gl_BaseInstance, gl_DrawID, gl_VertexIndex);
  gl_Position = vec4(float(gl_VertexIndex) * 0.01, float(gl_InstanceIndex) * 0.1, 0.0, 1.0);
  gl_PointSize = 2.0;
}
