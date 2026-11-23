// SPDX-License-Identifier: BSD-3-Clause
// The multisampled form of preload.frag, run per sample (gl_SampleID): the Mali backend's first pre-frame shader (valhall 08 section 8.10): run once for each tile before a pass that keeps the
// target's contents, it reads the image at the pixel's own position (a fetch: no filtering, no coordinates to scale) and
// writes it as the pixel's colour, which the pass's opaque blend stores in the tile as it is. The image is texture 0 of
// the shader's own heap (an array of the pass's layers, read at the layer the shader runs for: gl_Layer, the frame argument) and the sampler its dummy one.
#version 460
layout(set = 0, binding = 0) uniform texture2DMSArray textures[];
layout(set = 0, binding = 1) uniform sampler nearestSampler;
layout(location = 0) out vec4 outColor;
void main() { outColor = texelFetch(sampler2DMSArray(textures[0], nearestSampler), ivec3(ivec2(gl_FragCoord.xy), gl_Layer), gl_SampleID); }
