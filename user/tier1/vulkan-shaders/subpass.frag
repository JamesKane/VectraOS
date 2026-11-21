#version 450
// vulkan-test's second subpass: the colour the first wrote at this fragment, with red and blue exchanged.
layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput prev;
layout(location = 0) out vec4 outColor;

void main() {
  vec4 c = subpassLoad(prev);
  outColor = vec4(c.b, c.g, c.r, c.a);
}
