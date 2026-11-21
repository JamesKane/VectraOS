#version 450
#extension GL_EXT_demote_to_helper_invocation : enable
layout(location = 0) in vec4 v;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
void main() {
  float before = helperInvocationEXT() ? 1.0 : 0.0;
  if (v.x > 0.5) demote;
  float after = helperInvocationEXT() ? 1.0 : 0.0;
  c0 = vec4(before, after, dFdx(v.y), dFdy(v.y));
  c1 = vec4(dFdx(before), dFdy(before), dFdx(after), dFdy(after));
}
