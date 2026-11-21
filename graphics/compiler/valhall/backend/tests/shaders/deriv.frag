#version 450
layout(location = 0) in vec4 v;
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
layout(location = 2) out vec4 c2;
layout(location = 3) out vec4 c3;
void main() {
  c0 = vec4(dFdx(v.x), dFdy(v.y), dFdxCoarse(v.z), dFdyCoarse(v.w));
  c1 = vec4(dFdxFine(v.x), dFdyFine(v.y), dFdxFine(v.z), dFdyFine(v.w));
  c2 = fwidth(v);
  c3 = vec4(fwidthFine(v.xy), fwidthCoarse(v.zw));
}
