// SPDX-License-Identifier: BSD-3-Clause
// The multisampled form, run per sample (gl_SampleID), of the Mali backend's second pre-frame shader for a depth attachment (valhall 08 sections 8.2.1.1 and 8.10): run once for
// each tile before a pass that keeps the depth, it fetches the depth plane at the pixel and writes it as the fragment's
// depth, which the frame shader's depth/stencil descriptor (Always, written, from the shader) puts in the tile. The plane is
// texture 0 of the shader's own heap, and the sampler its dummy one.
#version 460
layout(set = 0, binding = 0) uniform texture2DMS textures[];
layout(set = 0, binding = 1) uniform sampler nearestSampler;
void main() { gl_FragDepth = texelFetch(sampler2DMS(textures[0], nearestSampler), ivec2(gl_FragCoord.xy), gl_SampleID).r; }
