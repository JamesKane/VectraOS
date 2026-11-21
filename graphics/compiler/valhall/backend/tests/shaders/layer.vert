#version 450
#extension GL_ARB_shader_viewport_layer_array : enable
out gl_PerVertex { vec4 gl_Position; };
void main() {
  gl_Position = vec4(float(gl_VertexIndex) * 0.01, 0.0, 0.0, 1.0);
  gl_Layer = gl_VertexIndex & 3;
}
