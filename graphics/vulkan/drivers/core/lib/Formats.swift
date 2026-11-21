// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan formats the core names, and what the device does with each (D174 amendment, step 5): `pixelFormat` and
// `vulkanFormat` are the one table, and the format properties are `DeviceLimits.formats(_:)` mapped onto Vulkan's
// feature bits. A format the core has no name for has no properties: the layer reports it as unsupported.

import GPUCore
import TDVulkan

private let formatTable: [(vk: VkFormat, core: PixelFormat)] = [
  (VK_FORMAT_R8_UNORM, .r8), (VK_FORMAT_R8_SNORM, .r8snorm), (VK_FORMAT_R8_UINT, .r8uint), (VK_FORMAT_R8_SINT, .r8sint),
  (VK_FORMAT_R8G8_UNORM, .rg8), (VK_FORMAT_R8G8_SNORM, .rg8snorm), (VK_FORMAT_R8G8_UINT, .rg8uint), (VK_FORMAT_R8G8_SINT, .rg8sint),
  (VK_FORMAT_R8G8B8A8_UNORM, .rgba8), (VK_FORMAT_R8G8B8A8_SNORM, .rgba8snorm), (VK_FORMAT_R8G8B8A8_UINT, .rgba8uint),
  (VK_FORMAT_R8G8B8A8_SINT, .rgba8sint), (VK_FORMAT_R8G8B8A8_SRGB, .rgba8srgb), (VK_FORMAT_B8G8R8A8_UNORM, .bgra8),
  (VK_FORMAT_B8G8R8A8_SRGB, .bgra8srgb),
  (VK_FORMAT_R16_SFLOAT, .r16float), (VK_FORMAT_R16_UINT, .r16uint), (VK_FORMAT_R16_SINT, .r16sint),
  (VK_FORMAT_R16G16_SFLOAT, .rg16float), (VK_FORMAT_R16G16_UINT, .rg16uint), (VK_FORMAT_R16G16_SINT, .rg16sint),
  (VK_FORMAT_R16G16B16A16_SFLOAT, .rgba16float), (VK_FORMAT_R16G16B16A16_UINT, .rgba16uint), (VK_FORMAT_R16G16B16A16_SINT, .rgba16sint),
  (VK_FORMAT_R32_SFLOAT, .r32float), (VK_FORMAT_R32_UINT, .r32uint), (VK_FORMAT_R32_SINT, .r32sint),
  (VK_FORMAT_R32G32_SFLOAT, .rg32float), (VK_FORMAT_R32G32_UINT, .rg32uint), (VK_FORMAT_R32G32_SINT, .rg32sint),
  (VK_FORMAT_R32G32B32A32_SFLOAT, .rgba32float), (VK_FORMAT_R32G32B32A32_UINT, .rgba32uint), (VK_FORMAT_R32G32B32A32_SINT, .rgba32sint),
  (VK_FORMAT_A2B10G10R10_UNORM_PACK32, .rgb10a2unorm), (VK_FORMAT_B10G11R11_UFLOAT_PACK32, .rg11b10float),
  (VK_FORMAT_E5B9G9R9_UFLOAT_PACK32, .rgb9e5),
  (VK_FORMAT_D16_UNORM, .depth16), (VK_FORMAT_D32_SFLOAT, .depth32f), (VK_FORMAT_D24_UNORM_S8_UINT, .depth24stencil8),
  (VK_FORMAT_D32_SFLOAT_S8_UINT, .depth32fstencil8), (VK_FORMAT_S8_UINT, .stencil8),
  (VK_FORMAT_ASTC_4x4_UNORM_BLOCK, .astc(.b4x4)), (VK_FORMAT_ASTC_4x4_SRGB_BLOCK, .astcSRGB(.b4x4)),
  (VK_FORMAT_ASTC_5x4_UNORM_BLOCK, .astc(.b5x4)), (VK_FORMAT_ASTC_5x4_SRGB_BLOCK, .astcSRGB(.b5x4)),
  (VK_FORMAT_ASTC_5x5_UNORM_BLOCK, .astc(.b5x5)), (VK_FORMAT_ASTC_5x5_SRGB_BLOCK, .astcSRGB(.b5x5)),
  (VK_FORMAT_ASTC_6x5_UNORM_BLOCK, .astc(.b6x5)), (VK_FORMAT_ASTC_6x5_SRGB_BLOCK, .astcSRGB(.b6x5)),
  (VK_FORMAT_ASTC_6x6_UNORM_BLOCK, .astc(.b6x6)), (VK_FORMAT_ASTC_6x6_SRGB_BLOCK, .astcSRGB(.b6x6)),
  (VK_FORMAT_ASTC_8x5_UNORM_BLOCK, .astc(.b8x5)), (VK_FORMAT_ASTC_8x5_SRGB_BLOCK, .astcSRGB(.b8x5)),
  (VK_FORMAT_ASTC_8x6_UNORM_BLOCK, .astc(.b8x6)), (VK_FORMAT_ASTC_8x6_SRGB_BLOCK, .astcSRGB(.b8x6)),
  (VK_FORMAT_ASTC_8x8_UNORM_BLOCK, .astc(.b8x8)), (VK_FORMAT_ASTC_8x8_SRGB_BLOCK, .astcSRGB(.b8x8)),
  (VK_FORMAT_ASTC_10x5_UNORM_BLOCK, .astc(.b10x5)), (VK_FORMAT_ASTC_10x5_SRGB_BLOCK, .astcSRGB(.b10x5)),
  (VK_FORMAT_ASTC_10x6_UNORM_BLOCK, .astc(.b10x6)), (VK_FORMAT_ASTC_10x6_SRGB_BLOCK, .astcSRGB(.b10x6)),
  (VK_FORMAT_ASTC_10x8_UNORM_BLOCK, .astc(.b10x8)), (VK_FORMAT_ASTC_10x8_SRGB_BLOCK, .astcSRGB(.b10x8)),
  (VK_FORMAT_ASTC_10x10_UNORM_BLOCK, .astc(.b10x10)), (VK_FORMAT_ASTC_10x10_SRGB_BLOCK, .astcSRGB(.b10x10)),
  (VK_FORMAT_ASTC_12x10_UNORM_BLOCK, .astc(.b12x10)), (VK_FORMAT_ASTC_12x10_SRGB_BLOCK, .astcSRGB(.b12x10)),
  (VK_FORMAT_ASTC_12x12_UNORM_BLOCK, .astc(.b12x12)), (VK_FORMAT_ASTC_12x12_SRGB_BLOCK, .astcSRGB(.b12x12)),
  (VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK, .etc2rgb8), (VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK, .etc2rgb8srgb),
  (VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK, .etc2rgb8a1), (VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK, .etc2rgb8a1srgb),
  (VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK, .etc2rgba8), (VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK, .etc2rgba8srgb),
  (VK_FORMAT_EAC_R11_UNORM_BLOCK, .eacR11), (VK_FORMAT_EAC_R11_SNORM_BLOCK, .eacR11snorm),
  (VK_FORMAT_EAC_R11G11_UNORM_BLOCK, .eacRG11), (VK_FORMAT_EAC_R11G11_SNORM_BLOCK, .eacRG11snorm),
  (VK_FORMAT_BC1_RGB_UNORM_BLOCK, .bc1rgb), (VK_FORMAT_BC1_RGB_SRGB_BLOCK, .bc1rgbsrgb),
  (VK_FORMAT_BC1_RGBA_UNORM_BLOCK, .bc1rgba), (VK_FORMAT_BC1_RGBA_SRGB_BLOCK, .bc1rgbasrgb),
  (VK_FORMAT_BC2_UNORM_BLOCK, .bc2), (VK_FORMAT_BC2_SRGB_BLOCK, .bc2srgb), (VK_FORMAT_BC3_UNORM_BLOCK, .bc3),
  (VK_FORMAT_BC3_SRGB_BLOCK, .bc3srgb), (VK_FORMAT_BC4_UNORM_BLOCK, .bc4), (VK_FORMAT_BC4_SNORM_BLOCK, .bc4snorm),
  (VK_FORMAT_BC5_UNORM_BLOCK, .bc5), (VK_FORMAT_BC5_SNORM_BLOCK, .bc5snorm), (VK_FORMAT_BC6H_UFLOAT_BLOCK, .bc6hufloat),
  (VK_FORMAT_BC6H_SFLOAT_BLOCK, .bc6hsfloat), (VK_FORMAT_BC7_UNORM_BLOCK, .bc7), (VK_FORMAT_BC7_SRGB_BLOCK, .bc7srgb),
]

/// The core's format for a Vulkan format, nil where the core has none.
func pixelFormat(_ f: VkFormat) -> PixelFormat? {
  for e in formatTable where e.vk == f { return e.core }
  return nil
}

/// The Vulkan format of a core format.
func vulkanFormat(_ f: PixelFormat) -> VkFormat? {
  for e in formatTable where e.core == f { return e.vk }
  return nil
}

/// Every Vulkan format the core names.
var knownVulkanFormats: [VkFormat] { formatTable.map { $0.vk } }

/// The image aspects a `VkImageAspectFlags` mask names.
func imageAspects(_ mask: VkImageAspectFlags) -> ImageAspects {
  var a = ImageAspects(rawValue: 0)
  if mask & VK_IMAGE_ASPECT_COLOR_BIT.rawValue != 0 { a = a | .color }
  if mask & VK_IMAGE_ASPECT_DEPTH_BIT.rawValue != 0 { a = a | .depth }
  if mask & VK_IMAGE_ASPECT_STENCIL_BIT.rawValue != 0 { a = a | .stencil }
  return a
}

/// The Vulkan feature bits of a format on this device: the core's capabilities, as Vulkan words them. A format the device
/// doesn't list has none.
func formatFeatureBits(_ format: PixelFormat, _ limits: DeviceLimits) -> UInt32 {
  var listed = false
  for e in limits.formatTable where e.format == format { listed = true }
  guard listed else { return 0 }
  let c = limits.formats(format)
  let f = limits.features
  var bits: UInt32 = 0
  func add(_ b: VkFormatFeatureFlagBits) { bits |= b.rawValue }
  if c.sampled && f.sampledImages {
    add(VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)
    if c.filterable { add(VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT) }
  }
  if c.storage && f.storageImages {
    add(VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT)
    if c.storageAtomic { add(VK_FORMAT_FEATURE_STORAGE_IMAGE_ATOMIC_BIT) }
  }
  if c.renderTarget {
    add(VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)
    if c.blendable { add(VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT) }
  }
  if c.depthTarget { add(VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) }
  if c.blitSource { add(VK_FORMAT_FEATURE_BLIT_SRC_BIT) }
  if c.blitDestination { add(VK_FORMAT_FEATURE_BLIT_DST_BIT) }
  add(VK_FORMAT_FEATURE_TRANSFER_SRC_BIT)
  add(VK_FORMAT_FEATURE_TRANSFER_DST_BIT)
  return bits
}
