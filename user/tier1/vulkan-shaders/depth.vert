#version 450
// vulkan-test's depth case: a position with its depth, and a colour, from the vertex buffer.
layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 0) out vec4 vcolor;

void main() {
  gl_Position = vec4(position, 1.0);
  vcolor = color;
}
