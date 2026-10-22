// SPDX-License-Identifier: BSD-3-Clause
// Radharc's GPU renderer (D121, after todhchai's): the CPU renderer's quads
// (services/radharc/lib's `render`), texel for pixel, into an sRGB target,
// so that the hardware blends in linear light as Light does (D110): a fill;
// a window's image, opaque, or with alpha premultiplied (color 1) or
// straight (color 2); a glyph (the atlas's coverage); the cursor; the
// screen dimmed beneath the prompt to a quarter of its light; the prompt's
// seal (a texture, clear where there is none). Colours come as sRGB and go
// out in light.
#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler linearSampler;
layout(location = 0) flat in ivec4 source;
layout(location = 1) flat in uint color;
layout(location = 2) flat in vec2 origin;
layout(location = 0) out vec4 outColor;

// sRGB's transfer, decoded.
vec3 light(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
vec3 unpack(uint c) { return vec3((c >> 16) & 255u, (c >> 8) & 255u, c & 255u) / 255.0; }

void main() {
  int kind = source.w;
  if (kind == 0) {  // fill
    outColor = vec4(light(unpack(color)), 1.0);
    return;
  }
  if (kind == 4) {  // dim: what is beneath, at a quarter of its light
    outColor = vec4(0.0, 0.0, 0.0, 0.75);
    return;
  }
  ivec2 at = source.xy + ivec2(floor(gl_FragCoord.xy - origin));
  vec4 t = texelFetch(sampler2D(textures[nonuniformEXT(source.z)], linearSampler), at, 0);
  if (kind == 1) {  // image: 0xAARRGGBB
    if (color == 1u) {  // premultiplied: its channels decode to light already multiplied
      if (t.a <= 0.0) discard;
      outColor = vec4(light(t.rgb) / t.a, t.a);
    } else if (color == 2u) {  // straight
      outColor = vec4(light(t.rgb), t.a);
    } else {
      outColor = vec4(light(t.rgb), 1.0);
    }
  } else if (kind == 2) {  // glyph: the atlas's coverage
    if (t.r < 0.5) discard;
    outColor = vec4(light(unpack(color)), 1.0);
  } else {  // cursor, seal: their own textures, clear where they aren't
    if (t.a < 0.5) discard;
    outColor = vec4(light(t.rgb), 1.0);
  }
}
