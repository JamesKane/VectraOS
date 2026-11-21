#version 450
// vulkan-test's triangle: a position and a colour from the vertex buffer.
layout(location = 0) in vec2 position;
layout(location = 1) in vec4 color;
layout(location = 0) out vec4 vcolor;

void main() {
  gl_Position = vec4(position, 0.0, 1.0);
  vcolor = color;
}
