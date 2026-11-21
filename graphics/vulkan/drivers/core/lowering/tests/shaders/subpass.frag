// SPDX-License-Identifier: BSD-3-Clause
// An input attachment: the colour the subpass before wrote at this fragment, doubled.
#version 460
layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput prev;
layout(location = 0) out vec4 color;
void main() {
  color = subpassLoad(prev) * 2.0;
}
