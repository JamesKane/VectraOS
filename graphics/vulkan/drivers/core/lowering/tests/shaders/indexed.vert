// SPDX-License-Identifier: BSD-3-Clause
// Integer attributes and the program's own VertexIndex and InstanceIndex (signed, as GLSL declares them): the
// fetch reads the same built-ins.
#version 460
layout(location = 0) in float weight;
layout(location = 1) in ivec2 ids;
layout(location = 2) in uint flag;
layout(location = 0) flat out ivec2 outIds;
layout(location = 1) flat out uint outFlag;
void main() {
  outIds = ids;
  outFlag = flag + uint(gl_InstanceIndex);
  gl_Position = vec4(float(gl_VertexIndex), weight, float(gl_InstanceIndex), 1.0);
}
