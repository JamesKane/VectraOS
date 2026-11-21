// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan format each core format is, by name, for the format table's test (FormatTests): the table's block sizes,
// block extents, aspects and numeric types are checked against the specification's values for these names
// (`vulkanFormatFacts`, taken from data/vulkan/vk.xml). The switch is exhaustive: a format added to the core
// can't be left out of the test.

@testable import GPUCore

func vulkanName(_ f: PixelFormat) -> String {
  func astc(_ b: ASTCBlock, _ suffix: String) -> String {
    "VK_FORMAT_ASTC_\(b.width)x\(b.height)_\(suffix)_BLOCK"
  }
  switch f {
  case .r8: return "VK_FORMAT_R8_UNORM"
  case .r8snorm: return "VK_FORMAT_R8_SNORM"
  case .r8uint: return "VK_FORMAT_R8_UINT"
  case .r8sint: return "VK_FORMAT_R8_SINT"
  case .rg8: return "VK_FORMAT_R8G8_UNORM"
  case .rg8snorm: return "VK_FORMAT_R8G8_SNORM"
  case .rg8uint: return "VK_FORMAT_R8G8_UINT"
  case .rg8sint: return "VK_FORMAT_R8G8_SINT"
  case .rgba8: return "VK_FORMAT_R8G8B8A8_UNORM"
  case .rgba8snorm: return "VK_FORMAT_R8G8B8A8_SNORM"
  case .rgba8uint: return "VK_FORMAT_R8G8B8A8_UINT"
  case .rgba8sint: return "VK_FORMAT_R8G8B8A8_SINT"
  case .rgba8srgb: return "VK_FORMAT_R8G8B8A8_SRGB"
  case .bgra8: return "VK_FORMAT_B8G8R8A8_UNORM"
  case .bgra8srgb: return "VK_FORMAT_B8G8R8A8_SRGB"
  case .r16float: return "VK_FORMAT_R16_SFLOAT"
  case .r16uint: return "VK_FORMAT_R16_UINT"
  case .r16sint: return "VK_FORMAT_R16_SINT"
  case .rg16float: return "VK_FORMAT_R16G16_SFLOAT"
  case .rg16uint: return "VK_FORMAT_R16G16_UINT"
  case .rg16sint: return "VK_FORMAT_R16G16_SINT"
  case .rgba16float: return "VK_FORMAT_R16G16B16A16_SFLOAT"
  case .rgba16uint: return "VK_FORMAT_R16G16B16A16_UINT"
  case .rgba16sint: return "VK_FORMAT_R16G16B16A16_SINT"
  case .r32float: return "VK_FORMAT_R32_SFLOAT"
  case .r32uint: return "VK_FORMAT_R32_UINT"
  case .r32sint: return "VK_FORMAT_R32_SINT"
  case .rg32float: return "VK_FORMAT_R32G32_SFLOAT"
  case .rg32uint: return "VK_FORMAT_R32G32_UINT"
  case .rg32sint: return "VK_FORMAT_R32G32_SINT"
  case .rgba32float: return "VK_FORMAT_R32G32B32A32_SFLOAT"
  case .rgba32uint: return "VK_FORMAT_R32G32B32A32_UINT"
  case .rgba32sint: return "VK_FORMAT_R32G32B32A32_SINT"
  case .rgb10a2unorm: return "VK_FORMAT_A2B10G10R10_UNORM_PACK32"
  case .rg11b10float: return "VK_FORMAT_B10G11R11_UFLOAT_PACK32"
  case .rgb9e5: return "VK_FORMAT_E5B9G9R9_UFLOAT_PACK32"
  case .depth16: return "VK_FORMAT_D16_UNORM"
  case .depth32f: return "VK_FORMAT_D32_SFLOAT"
  case .depth24stencil8: return "VK_FORMAT_D24_UNORM_S8_UINT"
  case .depth32fstencil8: return "VK_FORMAT_D32_SFLOAT_S8_UINT"
  case .stencil8: return "VK_FORMAT_S8_UINT"
  case .astc(let b): return astc(b, "UNORM")
  case .astcSRGB(let b): return astc(b, "SRGB")
  case .etc2rgb8: return "VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK"
  case .etc2rgb8srgb: return "VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK"
  case .etc2rgb8a1: return "VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK"
  case .etc2rgb8a1srgb: return "VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK"
  case .etc2rgba8: return "VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK"
  case .etc2rgba8srgb: return "VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK"
  case .eacR11: return "VK_FORMAT_EAC_R11_UNORM_BLOCK"
  case .eacR11snorm: return "VK_FORMAT_EAC_R11_SNORM_BLOCK"
  case .eacRG11: return "VK_FORMAT_EAC_R11G11_UNORM_BLOCK"
  case .eacRG11snorm: return "VK_FORMAT_EAC_R11G11_SNORM_BLOCK"
  case .bc1rgb: return "VK_FORMAT_BC1_RGB_UNORM_BLOCK"
  case .bc1rgbsrgb: return "VK_FORMAT_BC1_RGB_SRGB_BLOCK"
  case .bc1rgba: return "VK_FORMAT_BC1_RGBA_UNORM_BLOCK"
  case .bc1rgbasrgb: return "VK_FORMAT_BC1_RGBA_SRGB_BLOCK"
  case .bc2: return "VK_FORMAT_BC2_UNORM_BLOCK"
  case .bc2srgb: return "VK_FORMAT_BC2_SRGB_BLOCK"
  case .bc3: return "VK_FORMAT_BC3_UNORM_BLOCK"
  case .bc3srgb: return "VK_FORMAT_BC3_SRGB_BLOCK"
  case .bc4: return "VK_FORMAT_BC4_UNORM_BLOCK"
  case .bc4snorm: return "VK_FORMAT_BC4_SNORM_BLOCK"
  case .bc5: return "VK_FORMAT_BC5_UNORM_BLOCK"
  case .bc5snorm: return "VK_FORMAT_BC5_SNORM_BLOCK"
  case .bc6hufloat: return "VK_FORMAT_BC6H_UFLOAT_BLOCK"
  case .bc6hsfloat: return "VK_FORMAT_BC6H_SFLOAT_BLOCK"
  case .bc7: return "VK_FORMAT_BC7_UNORM_BLOCK"
  case .bc7srgb: return "VK_FORMAT_BC7_SRGB_BLOCK"
  }
}
