#version 450
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
layout(location = 2) out ivec4 c2;
layout(location = 3) out vec4 c3;
void main() {
  c0 = gl_FragCoord;
  c1 = vec4(gl_PointCoord, gl_FrontFacing ? 1.0 : 0.0, float(gl_SampleID));
  c2 = ivec4(gl_PrimitiveID, gl_Layer, gl_SampleMaskIn[0], gl_HelperInvocation ? 1 : 0);
  c3 = vec4(gl_SamplePosition, 0.0, 1.0);
  gl_SampleMask[0] = gl_SampleMaskIn[0] & 0x5;
  gl_FragDepth = gl_FragCoord.z * 0.5;
}
