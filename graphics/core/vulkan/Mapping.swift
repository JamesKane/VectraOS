// SPDX-License-Identifier: BSD-3-Clause

// The core's words in Vulkan's: each format, factor, operation and mode is the Vulkan one of the same name, so the
// mapping is one to one.

import GPUCore
import Vulkan

extension PixelFormat {
  var vk: VkFormat {
    switch self {
    case .r8: VK_FORMAT_R8_UNORM
    case .r8snorm: VK_FORMAT_R8_SNORM
    case .r8uint: VK_FORMAT_R8_UINT
    case .r8sint: VK_FORMAT_R8_SINT
    case .rg8: VK_FORMAT_R8G8_UNORM
    case .rg8snorm: VK_FORMAT_R8G8_SNORM
    case .rg8uint: VK_FORMAT_R8G8_UINT
    case .rg8sint: VK_FORMAT_R8G8_SINT
    case .rgba8: VK_FORMAT_R8G8B8A8_UNORM
    case .rgba8snorm: VK_FORMAT_R8G8B8A8_SNORM
    case .rgba8uint: VK_FORMAT_R8G8B8A8_UINT
    case .rgba8sint: VK_FORMAT_R8G8B8A8_SINT
    case .rgba8srgb: VK_FORMAT_R8G8B8A8_SRGB
    case .bgra8: VK_FORMAT_B8G8R8A8_UNORM
    case .bgra8srgb: VK_FORMAT_B8G8R8A8_SRGB
    case .r16float: VK_FORMAT_R16_SFLOAT
    case .r16uint: VK_FORMAT_R16_UINT
    case .r16sint: VK_FORMAT_R16_SINT
    case .rg16float: VK_FORMAT_R16G16_SFLOAT
    case .rg16uint: VK_FORMAT_R16G16_UINT
    case .rg16sint: VK_FORMAT_R16G16_SINT
    case .rgba16float: VK_FORMAT_R16G16B16A16_SFLOAT
    case .rgba16uint: VK_FORMAT_R16G16B16A16_UINT
    case .rgba16sint: VK_FORMAT_R16G16B16A16_SINT
    case .r32float: VK_FORMAT_R32_SFLOAT
    case .r32uint: VK_FORMAT_R32_UINT
    case .r32sint: VK_FORMAT_R32_SINT
    case .rg32float: VK_FORMAT_R32G32_SFLOAT
    case .rg32uint: VK_FORMAT_R32G32_UINT
    case .rg32sint: VK_FORMAT_R32G32_SINT
    case .rgba32float: VK_FORMAT_R32G32B32A32_SFLOAT
    case .rgba32uint: VK_FORMAT_R32G32B32A32_UINT
    case .rgba32sint: VK_FORMAT_R32G32B32A32_SINT
    case .rgb10a2unorm: VK_FORMAT_A2B10G10R10_UNORM_PACK32
    case .rg11b10float: VK_FORMAT_B10G11R11_UFLOAT_PACK32
    case .rgb9e5: VK_FORMAT_E5B9G9R9_UFLOAT_PACK32
    case .depth16: VK_FORMAT_D16_UNORM
    case .depth32f: VK_FORMAT_D32_SFLOAT
    case .depth24stencil8: VK_FORMAT_D24_UNORM_S8_UINT
    case .depth32fstencil8: VK_FORMAT_D32_SFLOAT_S8_UINT
    case .stencil8: VK_FORMAT_S8_UINT
    // The ASTC formats are numbered in pairs (unorm, sRGB) in the order of `ASTCBlock.all`.
    case .astc(let b): VkFormat(rawValue: 157 + 2 * UInt32(Self.astcIndex(b)))
    case .astcSRGB(let b): VkFormat(rawValue: 158 + 2 * UInt32(Self.astcIndex(b)))
    case .etc2rgb8: VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK
    case .etc2rgb8srgb: VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK
    case .etc2rgb8a1: VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK
    case .etc2rgb8a1srgb: VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK
    case .etc2rgba8: VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK
    case .etc2rgba8srgb: VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK
    case .eacR11: VK_FORMAT_EAC_R11_UNORM_BLOCK
    case .eacR11snorm: VK_FORMAT_EAC_R11_SNORM_BLOCK
    case .eacRG11: VK_FORMAT_EAC_R11G11_UNORM_BLOCK
    case .eacRG11snorm: VK_FORMAT_EAC_R11G11_SNORM_BLOCK
    case .bc1rgb: VK_FORMAT_BC1_RGB_UNORM_BLOCK
    case .bc1rgbsrgb: VK_FORMAT_BC1_RGB_SRGB_BLOCK
    case .bc1rgba: VK_FORMAT_BC1_RGBA_UNORM_BLOCK
    case .bc1rgbasrgb: VK_FORMAT_BC1_RGBA_SRGB_BLOCK
    case .bc2: VK_FORMAT_BC2_UNORM_BLOCK
    case .bc2srgb: VK_FORMAT_BC2_SRGB_BLOCK
    case .bc3: VK_FORMAT_BC3_UNORM_BLOCK
    case .bc3srgb: VK_FORMAT_BC3_SRGB_BLOCK
    case .bc4: VK_FORMAT_BC4_UNORM_BLOCK
    case .bc4snorm: VK_FORMAT_BC4_SNORM_BLOCK
    case .bc5: VK_FORMAT_BC5_UNORM_BLOCK
    case .bc5snorm: VK_FORMAT_BC5_SNORM_BLOCK
    case .bc6hufloat: VK_FORMAT_BC6H_UFLOAT_BLOCK
    case .bc6hsfloat: VK_FORMAT_BC6H_SFLOAT_BLOCK
    case .bc7: VK_FORMAT_BC7_UNORM_BLOCK
    case .bc7srgb: VK_FORMAT_BC7_SRGB_BLOCK
    }
  }

  private static func astcIndex(_ b: ASTCBlock) -> Int {
    var i = 0
    for x in ASTCBlock.all {
      if x == b { return i }
      i += 1
    }
    return 0
  }
}

extension CompareOp {
  var vk: VkCompareOp {
    switch self {
    case .never: VK_COMPARE_OP_NEVER
    case .less: VK_COMPARE_OP_LESS
    case .equal: VK_COMPARE_OP_EQUAL
    case .lessOrEqual: VK_COMPARE_OP_LESS_OR_EQUAL
    case .greater: VK_COMPARE_OP_GREATER
    case .notEqual: VK_COMPARE_OP_NOT_EQUAL
    case .greaterOrEqual: VK_COMPARE_OP_GREATER_OR_EQUAL
    case .always: VK_COMPARE_OP_ALWAYS
    }
  }
}

extension StencilOp {
  var vk: VkStencilOp {
    switch self {
    case .keep: VK_STENCIL_OP_KEEP
    case .zero: VK_STENCIL_OP_ZERO
    case .replace: VK_STENCIL_OP_REPLACE
    case .incrementClamp: VK_STENCIL_OP_INCREMENT_AND_CLAMP
    case .decrementClamp: VK_STENCIL_OP_DECREMENT_AND_CLAMP
    case .invert: VK_STENCIL_OP_INVERT
    case .incrementWrap: VK_STENCIL_OP_INCREMENT_AND_WRAP
    case .decrementWrap: VK_STENCIL_OP_DECREMENT_AND_WRAP
    }
  }
}

extension StencilFaceState {
  var vk: VkStencilOpState {
    VkStencilOpState(failOp: failOp.vk, passOp: passOp.vk, depthFailOp: depthFailOp.vk, compareOp: compare.vk,
                     compareMask: compareMask, writeMask: writeMask, reference: reference)
  }
}

extension BlendingFactor {
  var vk: VkBlendFactor {
    switch self {
    case .zero: VK_BLEND_FACTOR_ZERO
    case .one: VK_BLEND_FACTOR_ONE
    case .srcColor: VK_BLEND_FACTOR_SRC_COLOR
    case .oneMinusSrcColor: VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR
    case .dstColor: VK_BLEND_FACTOR_DST_COLOR
    case .oneMinusDstColor: VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR
    case .srcAlpha: VK_BLEND_FACTOR_SRC_ALPHA
    case .oneMinusSrcAlpha: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
    case .dstAlpha: VK_BLEND_FACTOR_DST_ALPHA
    case .oneMinusDstAlpha: VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA
    case .constantColor: VK_BLEND_FACTOR_CONSTANT_COLOR
    case .oneMinusConstantColor: VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR
    case .constantAlpha: VK_BLEND_FACTOR_CONSTANT_ALPHA
    case .oneMinusConstantAlpha: VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA
    case .srcAlphaSaturate: VK_BLEND_FACTOR_SRC_ALPHA_SATURATE
    case .src1Color: VK_BLEND_FACTOR_SRC1_COLOR
    case .oneMinusSrc1Color: VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR
    case .src1Alpha: VK_BLEND_FACTOR_SRC1_ALPHA
    case .oneMinusSrc1Alpha: VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA
    }
  }
}

extension BlendOp {
  var vk: VkBlendOp {
    switch self {
    case .add: VK_BLEND_OP_ADD
    case .subtract: VK_BLEND_OP_SUBTRACT
    case .reverseSubtract: VK_BLEND_OP_REVERSE_SUBTRACT
    case .min: VK_BLEND_OP_MIN
    case .max: VK_BLEND_OP_MAX
    }
  }
}

extension LogicOp {
  var vk: VkLogicOp {
    switch self {
    case .clear: VK_LOGIC_OP_CLEAR
    case .and: VK_LOGIC_OP_AND
    case .andReverse: VK_LOGIC_OP_AND_REVERSE
    case .copy: VK_LOGIC_OP_COPY
    case .andInverted: VK_LOGIC_OP_AND_INVERTED
    case .noop: VK_LOGIC_OP_NO_OP
    case .xor: VK_LOGIC_OP_XOR
    case .or: VK_LOGIC_OP_OR
    case .nor: VK_LOGIC_OP_NOR
    case .equivalent: VK_LOGIC_OP_EQUIVALENT
    case .invert: VK_LOGIC_OP_INVERT
    case .orReverse: VK_LOGIC_OP_OR_REVERSE
    case .copyInverted: VK_LOGIC_OP_COPY_INVERTED
    case .orInverted: VK_LOGIC_OP_OR_INVERTED
    case .nand: VK_LOGIC_OP_NAND
    case .set: VK_LOGIC_OP_SET
    }
  }
}

extension PrimitiveTopology {
  var vk: VkPrimitiveTopology {
    switch self {
    case .triangleList: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    case .triangleStrip: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
    case .lineList: VK_PRIMITIVE_TOPOLOGY_LINE_LIST
    case .pointList: VK_PRIMITIVE_TOPOLOGY_POINT_LIST
    case .lineStrip: VK_PRIMITIVE_TOPOLOGY_LINE_STRIP
    case .triangleFan: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN
    case .patchList: VK_PRIMITIVE_TOPOLOGY_PATCH_LIST
    }
  }
}

extension SamplerFilter {
  var vk: VkFilter { self == .linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST }
}

extension SamplerAddressMode {
  var vk: VkSamplerAddressMode {
    switch self {
    case .clampToEdge: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    case .repeat: VK_SAMPLER_ADDRESS_MODE_REPEAT
    case .mirroredRepeat: VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
    case .mirrorClampToEdge: VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE
    case .clampToBorder: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
    }
  }
}

extension BorderColor {
  var vk: VkBorderColor {
    switch self {
    case .transparentBlackFloat: VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
    case .transparentBlackInt: VK_BORDER_COLOR_INT_TRANSPARENT_BLACK
    case .opaqueBlackFloat: VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK
    case .opaqueBlackInt: VK_BORDER_COLOR_INT_OPAQUE_BLACK
    case .opaqueWhiteFloat: VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE
    case .opaqueWhiteInt: VK_BORDER_COLOR_INT_OPAQUE_WHITE
    }
  }
}

extension ImageViewDimension {
  var vk: VkImageViewType {
    switch self {
    case .d2: VK_IMAGE_VIEW_TYPE_2D
    case .d2Array: VK_IMAGE_VIEW_TYPE_2D_ARRAY
    case .cube: VK_IMAGE_VIEW_TYPE_CUBE
    case .cubeArray: VK_IMAGE_VIEW_TYPE_CUBE_ARRAY
    case .d3: VK_IMAGE_VIEW_TYPE_3D
    }
  }
}

func vkSamples(_ n: UInt32) -> VkSampleCountFlagBits { VkSampleCountFlagBits(rawValue: n) }

func vkLayers(_ s: ImageSubresourceLayers) -> VkImageSubresourceLayers {
  VkImageSubresourceLayers(aspectMask: vkAspects(s.aspects), mipLevel: s.mip, baseArrayLayer: s.baseLayer, layerCount: s.layerCount)
}

func vkRange(_ r: ImageSubresourceRange) -> VkImageSubresourceRange {
  VkImageSubresourceRange(aspectMask: vkAspects(r.aspects), baseMipLevel: r.baseMip, levelCount: r.mipCount, baseArrayLayer: r.baseLayer,
                          layerCount: r.layerCount)
}

func vkOffset(_ o: Offset3D) -> VkOffset3D { VkOffset3D(x: o.x, y: o.y, z: o.z) }
func vkExtent(_ e: Extent3D) -> VkExtent3D { VkExtent3D(width: e.width, height: e.height, depth: e.depth) }
