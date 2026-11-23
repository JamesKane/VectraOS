// SPDX-License-Identifier: BSD-3-Clause
// The multisampled form, run per sample (gl_SampleID), of the Mali backend's second pre-frame shader for a stencil attachment (valhall 08 sections 8.2.1.1 and 8.10): it fetches the
// stencil plane at the pixel and gives it as the stencil reference, which the frame shader's depth/stencil descriptor (the
// test Always, every operation Replace, the reference from the shader) puts in the tile. The plane is texture 0 of the
// shader's own heap, and the sampler its dummy one.
#version 460
#extension GL_ARB_shader_stencil_export : require
layout(set = 0, binding = 0) uniform utexture2DMS textures[];
layout(set = 0, binding = 1) uniform sampler nearestSampler;
void main() { gl_FragStencilRefARB = int(texelFetch(usampler2DMS(textures[0], nearestSampler), ivec2(gl_FragCoord.xy), gl_SampleID).r); }
