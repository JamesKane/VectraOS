// SPDX-License-Identifier: BSD-3-Clause

// The layer over a full-feature core device (D174 amendment, step 5): what each Vulkan call becomes in the core, and
// that the features and limits it reports are the device's. The fake is `FakeGPU(limits: FakeGPU.fullLimits())`: every
// feature, every format, up to eight samples; `FakeGPU()` is the device with only what the core had before.

import GPUCore
import Testing
import TDVulkan
@testable import VulkanCoreDriver
import VulkanLowering

/// A copy of `a` that lives as long as the test process: Vulkan's structures point at their arrays.
func leak<T>(_ a: [T]) -> UnsafePointer<T> {
  let p = UnsafeMutablePointer<T>.allocate(capacity: max(a.count, 1))
  p.initialize(from: a, count: a.count)
  return UnsafePointer(p)
}

func fullVK() -> VK { VK(gpu: FakeGPU(limits: FakeGPU.fullLimits())) }

extension VK {
  func fullImage(_ type: VkImageType = VK_IMAGE_TYPE_2D, _ format: VkFormat, _ w: UInt32, _ h: UInt32, depth: UInt32 = 1,
                 mips: UInt32 = 1, layers: UInt32 = 1, samples: VkSampleCountFlagBits = VK_SAMPLE_COUNT_1_BIT, usage: UInt32,
                 flags: UInt32 = 0) -> (VkResult, VkImage?)
  {
    var info = VkImageCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    info.flags = flags
    info.imageType = type
    info.format = format
    info.extent = VkExtent3D(width: w, height: h, depth: depth)
    info.mipLevels = mips
    info.arrayLayers = layers
    info.samples = samples
    info.tiling = VK_IMAGE_TILING_OPTIMAL
    info.usage = usage
    var out: VkImage?
    let r = fn("vkCreateImage", PFN_vkCreateImage.self)(device, &info, nil, &out)
    return (r, out)
  }

  func fullView(_ image: VkImage?, _ type: VkImageViewType, _ format: VkFormat, aspect: UInt32 = 1, mip: UInt32 = 0, levels: UInt32 = 1,
                layer: UInt32 = 0, layers: UInt32 = 1) -> (VkResult, VkImageView?)
  {
    var info = VkImageViewCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    info.image = image
    info.viewType = type
    info.format = format
    info.subresourceRange = VkImageSubresourceRange(aspectMask: aspect, baseMipLevel: mip, levelCount: levels, baseArrayLayer: layer,
                                                    layerCount: layers)
    var out: VkImageView?
    let r = fn("vkCreateImageView", PFN_vkCreateImageView.self)(device, &info, nil, &out)
    return (r, out)
  }

  func attachment(_ format: VkFormat, samples: VkSampleCountFlagBits = VK_SAMPLE_COUNT_1_BIT, load: VkAttachmentLoadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                  store: VkAttachmentStoreOp = VK_ATTACHMENT_STORE_OP_STORE, stencilLoad: VkAttachmentLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                  stencilStore: VkAttachmentStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE) -> VkAttachmentDescription
  {
    VkAttachmentDescription(flags: 0, format: format, samples: samples, loadOp: load, storeOp: store, stencilLoadOp: stencilLoad,
                            stencilStoreOp: stencilStore, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED, finalLayout: VK_IMAGE_LAYOUT_GENERAL)
  }
}

struct SubpassSpec {
  var colors: [UInt32]
  var resolves: [UInt32]? = nil
  var depth: UInt32? = nil
  var inputs: [UInt32] = []
}

func makePass(_ vk: VK, _ attachments: [VkAttachmentDescription], _ subpasses: [SubpassSpec], viewMasks: [UInt32]? = nil) -> (VkResult, VkRenderPass?) {
  var descs: [VkSubpassDescription] = []
  for s in subpasses {
    var d = VkSubpassDescription()
    d.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
    d.colorAttachmentCount = UInt32(s.colors.count)
    d.pColorAttachments = leak(s.colors.map { VkAttachmentReference(attachment: $0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) })
    if let r = s.resolves {
      d.pResolveAttachments = leak(r.map { VkAttachmentReference(attachment: $0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) })
    }
    if !s.inputs.isEmpty {
      d.inputAttachmentCount = UInt32(s.inputs.count)
      d.pInputAttachments = leak(s.inputs.map { VkAttachmentReference(attachment: $0, layout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) })
    }
    if let depth = s.depth {
      d.pDepthStencilAttachment = leak([VkAttachmentReference(attachment: depth, layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)])
    }
    descs.append(d)
  }
  var info = VkRenderPassCreateInfo()
  info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
  info.attachmentCount = UInt32(attachments.count)
  info.pAttachments = leak(attachments)
  info.subpassCount = UInt32(descs.count)
  info.pSubpasses = leak(descs)
  var multiview = VkRenderPassMultiviewCreateInfo()
  if let m = viewMasks {
    multiview.sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO
    multiview.subpassCount = UInt32(m.count)
    multiview.pViewMasks = leak(m)
    info.pNext = UnsafeRawPointer(leak([multiview]))
  }
  var out: VkRenderPass?
  let r = vk.fn("vkCreateRenderPass", PFN_vkCreateRenderPass.self)(vk.device, &info, nil, &out)
  return (r, out)
}

func makeFramebuffer(_ vk: VK, _ pass: VkRenderPass?, _ views: [VkImageView?], _ w: UInt32, _ h: UInt32, layers: UInt32 = 1) -> VkFramebuffer? {
  var info = VkFramebufferCreateInfo()
  info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
  info.renderPass = pass
  info.attachmentCount = UInt32(views.count)
  info.pAttachments = leak(views)
  info.width = w
  info.height = h
  info.layers = layers
  var out: VkFramebuffer?
  let r = vk.fn("vkCreateFramebuffer", PFN_vkCreateFramebuffer.self)(vk.device, &info, nil, &out)
  precondition(r == VK_SUCCESS)
  return out
}

/// Every piece of a graphics pipeline's fixed state, for a test to set.
struct Pieces {
  var raster = VkPipelineRasterizationStateCreateInfo()
  var multisample = VkPipelineMultisampleStateCreateInfo()
  var depthStencil = VkPipelineDepthStencilStateCreateInfo()
  var blend = VkPipelineColorBlendStateCreateInfo()
  var blendAttachments: [VkPipelineColorBlendAttachmentState] = []
  var assembly = VkPipelineInputAssemblyStateCreateInfo()
  var tessellation = VkPipelineTessellationStateCreateInfo()
  var dynamic: [VkDynamicState] = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
  var subpass: UInt32 = 0
  var sampleMask: [UInt32]?
  /// Dynamic rendering's formats, where there is no render pass.
  var renderingColors: [VkFormat] = []
  var depthFormat: VkFormat = VK_FORMAT_UNDEFINED
  var viewMask: UInt32 = 0
  /// The viewport state's counts, and its viewports and scissors (read where they aren't dynamic).
  var viewportCount: UInt32 = 1
  var viewports: [VkViewport] = []
  var scissors: [VkRect2D] = []
  var stages: [VkShaderStageFlagBits] = [VK_SHADER_STAGE_VERTEX_BIT, VK_SHADER_STAGE_FRAGMENT_BIT]

  init() {
    raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
    raster.lineWidth = 1
    multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
    depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
    blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
    assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    tessellation.sType = VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO
  }
}

func buildPipeline(_ vk: VK, _ layout: VkPipelineLayout?, _ pass: VkRenderPass?, _ p: Pieces) -> (VkResult, VkPipeline?) {
  var p = p
  let name = leak(Array("main".utf8CString))
  var stages: [VkPipelineShaderStageCreateInfo] = []
  for s in p.stages {
    stages.append(VkPipelineShaderStageCreateInfo(sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, pNext: nil, flags: 0, stage: s,
                                                  module: vk.shaderModule(), pName: name, pSpecializationInfo: nil))
  }
  var vertex = VkPipelineVertexInputStateCreateInfo()
  vertex.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
  var viewportState = VkPipelineViewportStateCreateInfo()
  viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
  viewportState.viewportCount = p.viewportCount
  viewportState.scissorCount = p.viewportCount
  if !p.viewports.isEmpty { viewportState.pViewports = leak(p.viewports) }
  if !p.scissors.isEmpty { viewportState.pScissors = leak(p.scissors) }
  var dynamic = VkPipelineDynamicStateCreateInfo()
  dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
  dynamic.dynamicStateCount = UInt32(p.dynamic.count)
  dynamic.pDynamicStates = leak(p.dynamic)
  if let mask = p.sampleMask { p.multisample.pSampleMask = leak(mask) }
  p.blend.attachmentCount = UInt32(p.blendAttachments.count)
  p.blend.pAttachments = leak(p.blendAttachments)
  var info = VkGraphicsPipelineCreateInfo()
  info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
  info.stageCount = UInt32(stages.count)
  info.pStages = leak(stages)
  info.pVertexInputState = leak([vertex])
  info.pInputAssemblyState = leak([p.assembly])
  info.pTessellationState = leak([p.tessellation])
  info.pViewportState = leak([viewportState])
  info.pRasterizationState = leak([p.raster])
  info.pMultisampleState = leak([p.multisample])
  info.pDepthStencilState = leak([p.depthStencil])
  info.pColorBlendState = leak([p.blend])
  info.pDynamicState = leak([dynamic])
  info.layout = layout
  info.renderPass = pass
  info.subpass = p.subpass
  if pass == nil {
    var rendering = VkPipelineRenderingCreateInfo()
    rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
    rendering.viewMask = p.viewMask
    rendering.colorAttachmentCount = UInt32(p.renderingColors.count)
    rendering.pColorAttachmentFormats = leak(p.renderingColors)
    rendering.depthAttachmentFormat = p.depthFormat
    info.pNext = UnsafeRawPointer(leak([rendering]))
  }
  var out: VkPipeline?
  let r = vk.fn("vkCreateGraphicsPipelines", PFN_vkCreateGraphicsPipelines.self)(vk.device, nil, 1, &info, nil, &out)
  return (r, out)
}

func blendAttachment(_ enable: Bool = false, src: VkBlendFactor = VK_BLEND_FACTOR_ONE, dst: VkBlendFactor = VK_BLEND_FACTOR_ZERO,
                     op: VkBlendOp = VK_BLEND_OP_ADD, srcAlpha: VkBlendFactor = VK_BLEND_FACTOR_ONE, dstAlpha: VkBlendFactor = VK_BLEND_FACTOR_ZERO,
                     alphaOp: VkBlendOp = VK_BLEND_OP_ADD, mask: UInt32 = 0xF) -> VkPipelineColorBlendAttachmentState {
  VkPipelineColorBlendAttachmentState(blendEnable: enable ? 1 : 0, srcColorBlendFactor: src, dstColorBlendFactor: dst, colorBlendOp: op,
                                      srcAlphaBlendFactor: srcAlpha, dstAlphaBlendFactor: dstAlpha, alphaBlendOp: alphaOp, colorWriteMask: mask)
}

let colorUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
let depthUsage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
let sampledUsage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue

extension VulkanCoreDriverTests {
  // MARK: Formats, features and limits

  @Test func formatPropertiesAreTheDevicesTable() throws {
    let vk = fullVK()
    let props = vk.fn("vkGetPhysicalDeviceFormatProperties", PFN_vkGetPhysicalDeviceFormatProperties.self)
    var count = 0
    for f in knownVulkanFormats {
      var p = VkFormatProperties()
      props(vk.physical, f, &p)
      let core = pixelFormat(f)!
      #expect(p.optimalTilingFeatures == VkFormatFeatureFlags(formatFeatureBits(core, vk.gpu.limits)), "\(core)")
      #expect(p.optimalTilingFeatures != 0, "\(core) has no features on the full device")
      count += 1
    }
    #expect(count == PixelFormat.all.count)
    // Every core format has its Vulkan format and back.
    for f in PixelFormat.all { #expect(vulkanFormat(f).flatMap { pixelFormat($0) } == f, "\(f)") }

    var p = VkFormatProperties()
    props(vk.physical, VK_FORMAT_D32_SFLOAT, &p)
    #expect(p.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue != 0)
    #expect(p.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT.rawValue == 0)
    props(vk.physical, VK_FORMAT_R32G32B32A32_UINT, &p)
    #expect(p.optimalTilingFeatures & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue != 0)
    #expect(p.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT.rawValue == 0)
    #expect(p.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT.rawValue == 0)
    props(vk.physical, VK_FORMAT_R32_UINT, &p)
    #expect(p.optimalTilingFeatures & VK_FORMAT_FEATURE_STORAGE_IMAGE_ATOMIC_BIT.rawValue != 0)
    // A format the core has no name for has none.
    props(vk.physical, VK_FORMAT_R8G8B8_UNORM, &p)
    #expect(p.optimalTilingFeatures == 0 && p.linearTilingFeatures == 0 && p.bufferFeatures == 0)

    // The pre-amendment device lists four formats: the rest have nothing there.
    let old = VK()
    old.fn("vkGetPhysicalDeviceFormatProperties", PFN_vkGetPhysicalDeviceFormatProperties.self)(old.physical, VK_FORMAT_D32_SFLOAT, &p)
    #expect(p.optimalTilingFeatures == 0)
    old.fn("vkGetPhysicalDeviceFormatProperties", PFN_vkGetPhysicalDeviceFormatProperties.self)(old.physical, VK_FORMAT_R8G8B8A8_UNORM, &p)
    #expect(p.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT.rawValue != 0)

    // The "2" form is the same.
    var p2 = VkFormatProperties2()
    p2.sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2
    vk.fn("vkGetPhysicalDeviceFormatProperties2", PFN_vkGetPhysicalDeviceFormatProperties2.self)(vk.physical, VK_FORMAT_BC7_SRGB_BLOCK, &p2)
    #expect(p2.formatProperties.optimalTilingFeatures == VkFormatFeatureFlags(formatFeatureBits(.bc7srgb, vk.gpu.limits)))
  }

  @Test func imageFormatPropertiesFollowTheFormatsAndUsage() throws {
    let vk = fullVK()
    let query = vk.fn("vkGetPhysicalDeviceImageFormatProperties", PFN_vkGetPhysicalDeviceImageFormatProperties.self)
    var p = VkImageFormatProperties()
    #expect(query(vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, colorUsage, 0, &p) == VK_SUCCESS)
    #expect(p.maxExtent.width == 4096 && p.maxExtent.depth == 1)
    #expect(p.maxMipLevels == 13)
    #expect(p.maxArrayLayers == 256)
    // Up to eight samples as a color attachment.
    #expect(p.sampleCounts == 15)
    #expect(query(vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_3D, VK_IMAGE_TILING_OPTIMAL, sampledUsage, 0, &p) == VK_SUCCESS)
    #expect(p.maxExtent.depth == 2048 && p.maxArrayLayers == 1 && p.sampleCounts == 1)
    #expect(query(vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, sampledUsage, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue, &p) == VK_SUCCESS)
    // A compressed format is sampled and copied only.
    #expect(query(vk.physical, VK_FORMAT_BC1_RGB_UNORM_BLOCK, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, colorUsage, 0, &p) == VK_ERROR_FORMAT_NOT_SUPPORTED)
    #expect(query(vk.physical, VK_FORMAT_BC1_RGB_UNORM_BLOCK, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, sampledUsage, 0, &p) == VK_SUCCESS)
    #expect(query(vk.physical, VK_FORMAT_D32_SFLOAT, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, depthUsage, 0, &p) == VK_SUCCESS)
    #expect(query(vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT.rawValue, 0, &p) == VK_SUCCESS)  // an input attachment is read as a texture

    // The device without them has one level, one layer, one sample, 2D.
    let old = VK()
    #expect(old.fn("vkGetPhysicalDeviceImageFormatProperties", PFN_vkGetPhysicalDeviceImageFormatProperties.self)(
      old.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, colorUsage, 0, &p) == VK_SUCCESS)
    #expect(p.maxMipLevels == 1 && p.maxArrayLayers == 1 && p.sampleCounts == 1)
    #expect(old.fn("vkGetPhysicalDeviceImageFormatProperties", PFN_vkGetPhysicalDeviceImageFormatProperties.self)(
      old.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_3D, VK_IMAGE_TILING_OPTIMAL, colorUsage, 0, &p) == VK_ERROR_FORMAT_NOT_SUPPORTED)
  }

  @Test func featuresAreTheDevicesAndNeverMore() throws {
    let full = fullVK()
    let old = VK()
    var ff = VkPhysicalDeviceFeatures()
    var fo = VkPhysicalDeviceFeatures()
    full.fn("vkGetPhysicalDeviceFeatures", PFN_vkGetPhysicalDeviceFeatures.self)(full.physical, &ff)
    old.fn("vkGetPhysicalDeviceFeatures", PFN_vkGetPhysicalDeviceFeatures.self)(old.physical, &fo)
    #expect(ff.geometryShader == 1 && ff.tessellationShader == 1 && ff.depthClamp == 1 && ff.depthBounds == 1)
    #expect(ff.samplerAnisotropy == 1 && ff.independentBlend == 1 && ff.dualSrcBlend == 1 && ff.logicOp == 1 && ff.wideLines == 1)
    #expect(ff.fillModeNonSolid == 1 && ff.sampleRateShading == 1 && ff.alphaToOne == 1 && ff.imageCubeArray == 1)
    #expect(ff.textureCompressionBC == 1 && ff.textureCompressionETC2 == 1 && ff.textureCompressionASTC_LDR == 1)
    #expect(ff.pipelineStatisticsQuery == 1 && ff.occlusionQueryPrecise == 1 && ff.multiDrawIndirect == 1)
    #expect(ff.shaderFloat64 == 1 && ff.shaderInt64 == 1 && ff.shaderInt16 == 1 && ff.shaderClipDistance == 1)
    // Nothing the core has no word for.
    #expect(ff.sparseBinding == 0 && ff.robustBufferAccess == 0 && ff.multiViewport == 0 && ff.largePoints == 0)
    // The device that has none says none.
    #expect(fo.geometryShader == 0 && fo.tessellationShader == 0 && fo.depthClamp == 0 && fo.samplerAnisotropy == 0)
    #expect(fo.independentBlend == 0 && fo.logicOp == 0 && fo.fillModeNonSolid == 0 && fo.shaderFloat64 == 0 && fo.imageCubeArray == 0)
    #expect(fo.pipelineStatisticsQuery == 0 && fo.textureCompressionBC == 0)

    // Features 2 with the structures a client chains.
    func chain(_ vk: VK) -> (VkPhysicalDeviceVulkan11Features, VkPhysicalDeviceVulkan12Features, VkPhysicalDeviceVulkan13Features, VkPhysicalDeviceMultiviewFeatures) {
      var multiview = VkPhysicalDeviceMultiviewFeatures()
      multiview.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_FEATURES
      var v13 = VkPhysicalDeviceVulkan13Features()
      v13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
      var v12 = VkPhysicalDeviceVulkan12Features()
      v12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
      var v11 = VkPhysicalDeviceVulkan11Features()
      v11.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
      withUnsafeMutablePointer(to: &multiview) { m in
        withUnsafeMutablePointer(to: &v13) { a in
          withUnsafeMutablePointer(to: &v12) { b in
            withUnsafeMutablePointer(to: &v11) { c in
              m.pointee.pNext = nil
              a.pointee.pNext = UnsafeMutableRawPointer(m)
              b.pointee.pNext = UnsafeMutableRawPointer(a)
              c.pointee.pNext = UnsafeMutableRawPointer(b)
              var f2 = VkPhysicalDeviceFeatures2()
              f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
              f2.pNext = UnsafeMutableRawPointer(c)
              vk.fn("vkGetPhysicalDeviceFeatures2", PFN_vkGetPhysicalDeviceFeatures2.self)(vk.physical, &f2)
            }
          }
        }
      }
      return (v11, v12, v13, multiview)
    }
    let (a11, a12, a13, am) = chain(full)
    #expect(a11.multiview == 1 && a11.shaderDrawParameters == 1 && am.multiview == 1)
    #expect(a12.drawIndirectCount == 1 && a12.shaderFloat16 == 1 && a12.shaderInt8 == 1 && a12.samplerMirrorClampToEdge == 1)
    #expect(a12.bufferDeviceAddress == 1 && a12.timelineSemaphore == 1 && a13.dynamicRendering == 1 && a13.synchronization2 == 1)
    #expect(a13.shaderDemoteToHelperInvocation == 1)
    let (o11, o12, o13, om) = chain(old)
    #expect(o11.multiview == 0 && om.multiview == 0 && o12.drawIndirectCount == 0 && o12.shaderFloat16 == 0)
    #expect(o12.bufferDeviceAddress == 1 && o13.dynamicRendering == 1 && o13.shaderDemoteToHelperInvocation == 0)

    // A device asked for what it lacks fails to be made.
    func create(_ vk: VK, geometry: Bool, multiview: Bool = false) -> VkResult {
      var q = VkDeviceQueueCreateInfo()
      q.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
      q.queueCount = 1
      q.pQueuePriorities = leak([Float(1)])
      var features = VkPhysicalDeviceFeatures()
      features.geometryShader = geometry ? 1 : 0
      var mv = VkPhysicalDeviceMultiviewFeatures()
      mv.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_FEATURES
      mv.multiview = multiview ? 1 : 0
      var d = VkDeviceCreateInfo()
      d.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
      d.queueCreateInfoCount = 1
      d.pQueueCreateInfos = leak([q])
      d.pEnabledFeatures = leak([features])
      d.pNext = UnsafeRawPointer(leak([mv]))
      var device: VkDevice?
      return vk.fn("vkCreateDevice", PFN_vkCreateDevice.self)(vk.physical, &d, nil, &device)
    }
    #expect(create(full, geometry: true, multiview: true) == VK_SUCCESS)
    #expect(create(old, geometry: true) == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(create(old, geometry: false, multiview: true) == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(create(old, geometry: false) == VK_SUCCESS)
  }

  @Test func limitsAreTheDevicesToo() throws {
    let vk = fullVK()
    var p = VkPhysicalDeviceProperties()
    vk.fn("vkGetPhysicalDeviceProperties", PFN_vkGetPhysicalDeviceProperties.self)(vk.physical, &p)
    let l = p.limits
    #expect(l.maxImageDimension2D == 4096 && l.maxImageDimension3D == 2048 && l.maxImageDimensionCube == 4096)
    #expect(l.maxImageArrayLayers == 256 && l.maxSamplerAnisotropy == 16)
    #expect(l.framebufferColorSampleCounts == 15 && l.sampledImageColorSampleCounts == 15)
    #expect(l.lineWidthRange.0 == 1 && l.lineWidthRange.1 == 8)
    #expect(l.maxColorAttachments == 8 && l.maxFragmentOutputAttachments == 8 && l.maxFragmentDualSrcAttachments == 1)
    #expect(l.maxTessellationPatchSize == 32)
    #expect(l.timestampPeriod == 40)

    var multiview = VkPhysicalDeviceMultiviewProperties()
    multiview.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_PROPERTIES
    var subgroup = VkPhysicalDeviceSubgroupProperties()
    subgroup.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES
    withUnsafeMutablePointer(to: &multiview) { m in
      withUnsafeMutablePointer(to: &subgroup) { s in
        s.pointee.pNext = UnsafeMutableRawPointer(m)
        var p2 = VkPhysicalDeviceProperties2()
        p2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        p2.pNext = UnsafeMutableRawPointer(s)
        vk.fn("vkGetPhysicalDeviceProperties2", PFN_vkGetPhysicalDeviceProperties2.self)(vk.physical, &p2)
      }
    }
    #expect(multiview.maxMultiviewViewCount == 4)
    #expect(subgroup.subgroupSize == 32 && subgroup.supportedOperations != 0)

    // The device with none: no 3D, no layers, no samples, one color attachment's worth of what it says.
    let old = VK()
    old.fn("vkGetPhysicalDeviceProperties", PFN_vkGetPhysicalDeviceProperties.self)(old.physical, &p)
    #expect(p.limits.maxImageDimension3D == 1 && p.limits.maxImageArrayLayers == 1 && p.limits.framebufferColorSampleCounts == 1)
    #expect(p.limits.maxSamplerAnisotropy == 1 && p.limits.lineWidthRange.1 == 1 && p.limits.maxTessellationPatchSize == 0)
  }

  // MARK: Images, views and samplers

  @Test func imagesWithMipsLayersVolumesCubesAndSamples() throws {
    let vk = fullVK()
    func described(_ r: (VkResult, VkImage?)) -> ImageDescriptor {
      #expect(r.0 == VK_SUCCESS)
      return vk.gpu.images.last!.descriptor
    }
    var d = described(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 64, 32, mips: 7, layers: 3, usage: sampledUsage))
    #expect(d == ImageDescriptor(format: .rgba8, width: 64, height: 32, mipLevels: 7, layers: 3, usage: .sampled | .copySource | .copyDestination))
    d = described(vk.fullImage(VK_IMAGE_TYPE_3D, VK_FORMAT_R16_SFLOAT, 8, 8, depth: 16, mips: 5, usage: sampledUsage))
    #expect(d.dimension == .d3 && d.depth == 16 && d.mipLevels == 5 && d.layers == 1)
    d = described(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, layers: 12, usage: sampledUsage, flags: VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue))
    #expect(d.dimension == .cube && d.layers == 12)
    d = described(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 32, 32, samples: VK_SAMPLE_COUNT_4_BIT, usage: colorUsage))
    #expect(d.samples == 4 && d.usage == .renderTarget | .copySource | .copyDestination)
    d = described(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_D32_SFLOAT_S8_UINT, 32, 32, samples: VK_SAMPLE_COUNT_8_BIT, usage: depthUsage))
    #expect(d.format == .depth32fstencil8 && d.samples == 8 && d.usage == .depthStencilTarget | .copyDestination)
    d = described(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_BC7_UNORM_BLOCK, 16, 16, mips: 3, usage: sampledUsage))
    #expect(d.format == .bc7)

    // What the core says is wrong is the core's refusal; what it lacks, the device's.
    #expect(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, mips: 9, usage: sampledUsage).0 == VK_ERROR_UNKNOWN)
    #expect(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, samples: VK_SAMPLE_COUNT_16_BIT, usage: colorUsage).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(vk.fullImage(VK_IMAGE_TYPE_1D, VK_FORMAT_R8G8B8A8_UNORM, 16, 1, usage: sampledUsage).0 == VK_SUCCESS)
    #expect(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, usage: VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT.rawValue).0 == VK_SUCCESS)
    #expect(vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, usage: sampledUsage, flags: VK_IMAGE_CREATE_SPARSE_BINDING_BIT.rawValue).0 == VK_ERROR_FEATURE_NOT_PRESENT)

    // The old device refuses them as its own.
    let old = VK()
    #expect(old.fullImage(VK_IMAGE_TYPE_3D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, depth: 8, usage: sampledUsage).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(old.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, mips: 2, usage: sampledUsage).0 == VK_ERROR_FEATURE_NOT_PRESENT)

    // Memory requirements count every level, layer and sample.
    var info = VkImageMemoryRequirementsInfo2()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2
    info.image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, mips: 2, layers: 2, usage: sampledUsage).1
    var req = VkMemoryRequirements2()
    req.sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2
    vk.fn("vkGetImageMemoryRequirements2", PFN_vkGetImageMemoryRequirements2.self)(vk.device, &info, &req)
    #expect(req.memoryRequirements.size == ((16 * 16 + 8 * 8) * 4 * 2 + 255) & ~255)
  }

  @Test func viewsOfSubresourcesAndOfCompatibleFormats() throws {
    let vk = fullVK()
    let image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, mips: 4, layers: 6, usage: sampledUsage,
                             flags: VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue).1
    func core(_ v: VkImageView?) -> ImageView { Handle.get(v, ImageViewObject.self)!.view }
    var r = vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D_ARRAY, VK_FORMAT_R8G8B8A8_UNORM, mip: 1, levels: 2, layer: 2, layers: 3)
    #expect(r.0 == VK_SUCCESS)
    var v = core(r.1)
    #expect(v.baseMip == 1 && v.mipCount == 2 && v.baseLayer == 2 && v.layerCount == 3 && v.dimension == .d2Array && v.format == .rgba8)
    // The rest of the levels and layers.
    r = vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D_ARRAY, VK_FORMAT_R8G8B8A8_UNORM, mip: 1, levels: ~0, layer: 1, layers: ~0)
    v = core(r.1)
    #expect(v.mipCount == 3 && v.layerCount == 5)
    // Another format of the same size class.
    r = vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_SRGB, levels: 4)
    #expect(r.0 == VK_SUCCESS)
    #expect(core(r.1).format == .rgba8srgb)
    // The heap holds each (the image is sampled): a slot for its texture with the view's own shape.
    let slot = Handle.get(r.1, ImageViewObject.self)!.textureSlot!
    #expect(vk.gpu.textureViews[slot]?.format == .rgba8srgb && vk.gpu.textureViews[slot]?.mipCount == 4)
    // Not of a format of another size, nor past the image.
    #expect(vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R16G16B16A16_SFLOAT).0 == VK_ERROR_UNKNOWN)
    #expect(vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D_ARRAY, VK_FORMAT_R8G8B8A8_UNORM, layer: 5, layers: 2).0 == VK_ERROR_UNKNOWN)
    // A view with a swizzle is the core's mapping, and a 1D view of a 2D image is not a view the core makes.
    var info = VkImageViewCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    info.image = image
    info.viewType = VK_IMAGE_VIEW_TYPE_2D
    info.format = VK_FORMAT_R8G8B8A8_UNORM
    info.components.r = VK_COMPONENT_SWIZZLE_B
    info.subresourceRange = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    var out: VkImageView?
    #expect(vk.fn("vkCreateImageView", PFN_vkCreateImageView.self)(vk.device, &info, nil, &out) == VK_SUCCESS)
    #expect(core(out).swizzle == ComponentMapping(r: .b))
    #expect(vk.fullView(image, VK_IMAGE_VIEW_TYPE_1D, VK_FORMAT_R8G8B8A8_UNORM).0 == VK_ERROR_UNKNOWN)  // a 1D view of a 2D image

    // A cube image: cube, cube array and layer views; a volume: a 3D view; depth and stencil: one aspect each.
    let cube = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, layers: 12, usage: sampledUsage, flags: VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue).1
    #expect(core(vk.fullView(cube, VK_IMAGE_VIEW_TYPE_CUBE, VK_FORMAT_R8G8B8A8_UNORM, layer: 6, layers: 6).1).dimension == .cube)
    #expect(core(vk.fullView(cube, VK_IMAGE_VIEW_TYPE_CUBE_ARRAY, VK_FORMAT_R8G8B8A8_UNORM, layers: 12).1).dimension == .cubeArray)
    #expect(core(vk.fullView(cube, VK_IMAGE_VIEW_TYPE_2D_ARRAY, VK_FORMAT_R8G8B8A8_UNORM, layers: 12).1).dimension == .d2Array)
    #expect(vk.fullView(image, VK_IMAGE_VIEW_TYPE_CUBE, VK_FORMAT_R8G8B8A8_UNORM, layers: 6).0 == VK_ERROR_UNKNOWN)
    let volume = vk.fullImage(VK_IMAGE_TYPE_3D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, depth: 8, usage: sampledUsage).1
    #expect(core(vk.fullView(volume, VK_IMAGE_VIEW_TYPE_3D, VK_FORMAT_R8G8B8A8_UNORM).1).dimension == .d3)
    let depth = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_D32_SFLOAT_S8_UINT, 16, 16, usage: depthUsage | VK_IMAGE_USAGE_SAMPLED_BIT.rawValue).1
    let depthOnly = vk.fullView(depth, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_D32_SFLOAT_S8_UINT, aspect: VK_IMAGE_ASPECT_DEPTH_BIT.rawValue)
    #expect(depthOnly.0 == VK_SUCCESS)
    #expect(core(depthOnly.1).aspects == .depth)
    #expect(Handle.get(depthOnly.1, ImageViewObject.self)!.textureSlot != nil)
    // The attachment's view has both aspects and takes no heap slot.
    let both = vk.fullView(depth, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_D32_SFLOAT_S8_UINT, aspect: 6)
    #expect(both.0 == VK_SUCCESS && core(both.1).aspects == .depthStencil)
    #expect(Handle.get(both.1, ImageViewObject.self)!.textureSlot == nil)
  }

  @Test func theFullSamplerState() throws {
    let vk = fullVK()
    var info = VkSamplerCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    info.magFilter = VK_FILTER_LINEAR
    info.minFilter = VK_FILTER_NEAREST
    info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR
    info.addressModeU = VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE
    info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
    info.addressModeW = VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
    info.mipLodBias = 0.5
    info.anisotropyEnable = 1
    info.maxAnisotropy = 8
    info.compareEnable = 1
    info.compareOp = VK_COMPARE_OP_GREATER_OR_EQUAL
    info.minLod = 1
    info.maxLod = 5
    info.borderColor = VK_BORDER_COLOR_INT_OPAQUE_WHITE
    var s: VkSampler?
    #expect(vk.fn("vkCreateSampler", PFN_vkCreateSampler.self)(vk.device, &info, nil, &s) == VK_SUCCESS)
    let slot = Handle.get(s, SamplerObject.self)!.slot
    #expect(vk.gpu.samplers[slot] == SamplerDescriptor(
      minFilter: .nearest, magFilter: .linear, mipmapMode: .linear, addressModeU: .mirrorClampToEdge, addressModeV: .clampToBorder,
      addressModeW: .mirroredRepeat, borderColor: .opaqueWhiteInt, mipLodBias: 0.5, minLod: 1, maxLod: 5, maxAnisotropy: 8,
      compare: .greaterOrEqual))
    // Every border colour, and unnormalised coordinates.
    for (vkc, core) in [
      (VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK, BorderColor.transparentBlackFloat), (VK_BORDER_COLOR_INT_TRANSPARENT_BLACK, .transparentBlackInt),
      (VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK, .opaqueBlackFloat), (VK_BORDER_COLOR_INT_OPAQUE_BLACK, .opaqueBlackInt),
      (VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE, .opaqueWhiteFloat), (VK_BORDER_COLOR_INT_OPAQUE_WHITE, .opaqueWhiteInt),
    ] {
      var b = VkSamplerCreateInfo()
      b.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
      b.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
      b.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
      b.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
      b.borderColor = vkc
      b.maxLod = 1000
      var out: VkSampler?
      #expect(vk.fn("vkCreateSampler", PFN_vkCreateSampler.self)(vk.device, &b, nil, &out) == VK_SUCCESS, "\(vk.messages)")
      #expect(vk.gpu.samplers[Handle.get(out, SamplerObject.self)!.slot]?.borderColor == core)
    }
    var u = VkSamplerCreateInfo()
    u.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    u.unnormalizedCoordinates = 1
    u.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    u.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    u.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    u.maxLod = 0
    var out: VkSampler?
    #expect(vk.fn("vkCreateSampler", PFN_vkCreateSampler.self)(vk.device, &u, nil, &out) == VK_SUCCESS)
    #expect(vk.gpu.samplers[Handle.get(out, SamplerObject.self)!.slot]?.unnormalizedCoordinates == true)
    // A custom border colour is the structure on the chain; with none the call is wrong, and the colour is read where an axis clamps to the border.
    var custom = info
    custom.borderColor = VkBorderColor(rawValue: 1000287003)
    #expect(vk.fn("vkCreateSampler", PFN_vkCreateSampler.self)(vk.device, &custom, nil, &out) == VK_ERROR_INITIALIZATION_FAILED)
    var colour = VkSamplerCustomBorderColorCreateInfoEXT()
    colour.sType = VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT
    colour.customBorderColor.float32 = (0.25, 0.5, 0.75, 1)
    withUnsafePointer(to: &colour) { cp in
      custom.pNext = UnsafeRawPointer(cp)
      #expect(vk.fn("vkCreateSampler", PFN_vkCreateSampler.self)(vk.device, &custom, nil, &out) == VK_SUCCESS)
    }
    #expect(vk.gpu.samplers[Handle.get(out, SamplerObject.self)!.slot]?.customBorderColor == .float(0.25, 0.5, 0.75, 1))
    custom.pNext = nil
    let old = VK()
    #expect(old.fn("vkCreateSampler", PFN_vkCreateSampler.self)(old.device, &info, nil, &out) == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  // MARK: Pipeline state

  @Test func depthStencilAndRasterizationAndMultisample() throws {
    let vk = fullVK()
    let layout = vk.pipelineLayout([])
    let (_, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM, samples: VK_SAMPLE_COUNT_4_BIT), vk.attachment(VK_FORMAT_D24_UNORM_S8_UINT, samples: VK_SAMPLE_COUNT_4_BIT)],
                             [SubpassSpec(colors: [0], depth: 1)])
    var p = Pieces()
    p.depthStencil.depthTestEnable = 1
    p.depthStencil.depthWriteEnable = 1
    p.depthStencil.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL
    p.depthStencil.depthBoundsTestEnable = 1
    p.depthStencil.minDepthBounds = 0.25
    p.depthStencil.maxDepthBounds = 0.75
    p.depthStencil.stencilTestEnable = 1
    p.depthStencil.front = VkStencilOpState(failOp: VK_STENCIL_OP_ZERO, passOp: VK_STENCIL_OP_REPLACE, depthFailOp: VK_STENCIL_OP_INVERT,
                                            compareOp: VK_COMPARE_OP_EQUAL, compareMask: 0x0F, writeMask: 0xF0, reference: 7)
    p.depthStencil.back = VkStencilOpState(failOp: VK_STENCIL_OP_INCREMENT_AND_WRAP, passOp: VK_STENCIL_OP_DECREMENT_AND_CLAMP,
                                           depthFailOp: VK_STENCIL_OP_KEEP, compareOp: VK_COMPARE_OP_NOT_EQUAL, compareMask: 1, writeMask: 2, reference: 3)
    p.raster.cullMode = VK_CULL_MODE_BACK_BIT.rawValue
    p.raster.frontFace = VK_FRONT_FACE_CLOCKWISE
    p.raster.polygonMode = VK_POLYGON_MODE_LINE
    p.raster.depthBiasEnable = 1
    p.raster.depthBiasConstantFactor = 1.5
    p.raster.depthBiasClamp = 2
    p.raster.depthBiasSlopeFactor = 3
    p.raster.depthClampEnable = 1
    p.raster.lineWidth = 2
    p.multisample.rasterizationSamples = VK_SAMPLE_COUNT_4_BIT
    p.multisample.sampleShadingEnable = 1
    p.multisample.minSampleShading = 0.5
    p.multisample.alphaToCoverageEnable = 1
    p.multisample.alphaToOneEnable = 1
    p.sampleMask = [0b1010]
    p.blendAttachments = [blendAttachment()]
    let r = buildPipeline(vk, layout, pass, p)
    #expect(r.0 == VK_SUCCESS)
    let d = vk.gpu.graphicsPipelines[0]
    #expect(d.depthStencilFormat == .depth24stencil8)
    #expect(d.depthStencil == DepthStencilState(
      depthTest: true, depthWrite: true, depthCompare: .lessOrEqual, depthBoundsTest: true, minDepthBounds: 0.25, maxDepthBounds: 0.75, stencilTest: true,
      front: StencilFaceState(failOp: .zero, passOp: .replace, depthFailOp: .invert, compare: .equal, compareMask: 0x0F, writeMask: 0xF0, reference: 7),
      back: StencilFaceState(failOp: .incrementWrap, passOp: .decrementClamp, depthFailOp: .keep, compare: .notEqual, compareMask: 1, writeMask: 2, reference: 3)))
    #expect(d.rasterization == RasterizationState(
      cull: .back, frontFace: .clockwise, polygonMode: .line, depthBias: true, depthBiasConstant: 1.5, depthBiasClamp: 2, depthBiasSlope: 3,
      depthClamp: true, lineWidth: 2, rasterizerDiscard: false))
    #expect(d.multisample == MultisampleState(samples: 4, sampleMask: 0b1010, alphaToCoverage: true, alphaToOne: true, sampleShading: true, minSampleShading: 0.5))
    #expect(d.targets == PipelineTargets(colorFormats: [.rgba8], depthStencilFormat: .depth24stencil8, samples: 4, viewMask: 0))

    // Discard, every cull mode and every polygon mode.
    for (mode, want) in [(VK_CULL_MODE_NONE.rawValue, CullMode.none), (VK_CULL_MODE_FRONT_BIT.rawValue, .front), (VK_CULL_MODE_BACK_BIT.rawValue, .back),
                         (VK_CULL_MODE_FRONT_AND_BACK.rawValue, .frontAndBack)] {
      var q = Pieces()
      q.blendAttachments = [blendAttachment()]
      q.raster.cullMode = mode
      q.raster.rasterizerDiscardEnable = 1
      q.raster.polygonMode = VK_POLYGON_MODE_POINT
      #expect(buildPipeline(vk, layout, makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])]).1, q).0 == VK_SUCCESS)
      #expect(vk.gpu.graphicsPipelines.last!.rasterization.cull == want)
      #expect(vk.gpu.graphicsPipelines.last!.rasterization.polygonMode == .point && vk.gpu.graphicsPipelines.last!.rasterization.rasterizerDiscard)
    }

    // Depth and stencil state of a pass that has none is ignored, as Vulkan says; the old device refuses a depth attachment.
    let (_, plain) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])])
    var q = Pieces()
    q.blendAttachments = [blendAttachment()]
    q.depthStencil.depthTestEnable = 1
    #expect(buildPipeline(vk, layout, plain, q).0 == VK_SUCCESS)
    #expect(vk.gpu.graphicsPipelines.last!.depthStencil == DepthStencilState())
    let old = VK()
    let (_, oldPass) = makePass(old, [old.attachment(VK_FORMAT_R8G8B8A8_UNORM), old.attachment(VK_FORMAT_D32_SFLOAT)], [SubpassSpec(colors: [0], depth: 1)])
    #expect(buildPipeline(old, old.pipelineLayout([]), oldPass, q).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    var cull = Pieces()
    cull.blendAttachments = [blendAttachment()]
    cull.raster.cullMode = VK_CULL_MODE_BACK_BIT.rawValue
    #expect(buildPipeline(old, old.pipelineLayout([]), renderPass(old), cull).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  @Test func blendPerAttachmentLogicOpAndConstants() throws {
    let vk = fullVK()
    let layout = vk.pipelineLayout([])
    let (_, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM), vk.attachment(VK_FORMAT_R16G16B16A16_SFLOAT)],
                             [SubpassSpec(colors: [0, 1])])
    var p = Pieces()
    p.blendAttachments = [
      blendAttachment(true, src: VK_BLEND_FACTOR_SRC_ALPHA, dst: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, srcAlpha: VK_BLEND_FACTOR_ONE, dstAlpha: VK_BLEND_FACTOR_ZERO),
      blendAttachment(true, src: VK_BLEND_FACTOR_SRC1_COLOR, dst: VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA, op: VK_BLEND_OP_REVERSE_SUBTRACT,
                      srcAlpha: VK_BLEND_FACTOR_SRC_ALPHA_SATURATE, dstAlpha: VK_BLEND_FACTOR_DST_ALPHA, alphaOp: VK_BLEND_OP_MAX, mask: 0b0101),
    ]
    p.blend.logicOpEnable = 1
    p.blend.logicOp = VK_LOGIC_OP_XOR
    p.blend.blendConstants = (0.25, 0.5, 0.75, 1)
    #expect(buildPipeline(vk, layout, pass, p).0 == VK_SUCCESS)
    let d = vk.gpu.graphicsPipelines[0]
    #expect(d.attachmentBlends == [
      ColorBlendAttachment(enabled: true, srcColor: .srcAlpha, dstColor: .oneMinusSrcAlpha, colorOp: .add, srcAlpha: .one, dstAlpha: .zero, alphaOp: .add, writeMask: .all),
      ColorBlendAttachment(enabled: true, srcColor: .src1Color, dstColor: .oneMinusConstantAlpha, colorOp: .reverseSubtract, srcAlpha: .srcAlphaSaturate,
                           dstAlpha: .dstAlpha, alphaOp: .max, writeMask: .red | .blue),
    ])
    #expect(d.logicOp == .xor)
    #expect(d.blendConstants == BlendConstants(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
    // Every logic op, in Vulkan's order.
    let ops: [LogicOp] = [.clear, .and, .andReverse, .copy, .andInverted, .noop, .xor, .or, .nor, .equivalent, .invert, .orReverse, .copyInverted, .orInverted, .nand, .set]
    for (i, want) in ops.enumerated() {
      var q = Pieces()
      q.blendAttachments = [blendAttachment()]
      q.blend.logicOpEnable = 1
      q.blend.logicOp = VkLogicOp(rawValue: UInt32(i))
      #expect(buildPipeline(vk, layout, makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])]).1, q).0 == VK_SUCCESS)
      #expect(vk.gpu.graphicsPipelines.last!.logicOp == want)
    }

    // A device without general blends has opaque and source alpha over and refuses the rest; it draws source alpha for the
    // alpha too as it always has.
    let old = VK()
    let oldPass = renderPass(old)
    var alpha = Pieces()
    alpha.blendAttachments = [blendAttachment(true, src: VK_BLEND_FACTOR_SRC_ALPHA, dst: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                                              srcAlpha: VK_BLEND_FACTOR_SRC_ALPHA, dstAlpha: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA)]
    #expect(buildPipeline(old, old.pipelineLayout([]), oldPass, alpha).0 == VK_SUCCESS)
    #expect(old.gpu.graphicsPipelines.last!.attachmentBlends == [.alphaOver])
    var other = Pieces()
    other.blendAttachments = [blendAttachment(true, src: VK_BLEND_FACTOR_ONE, dst: VK_BLEND_FACTOR_ONE)]
    #expect(buildPipeline(old, old.pipelineLayout([]), oldPass, other).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    var masked = Pieces()
    masked.blendAttachments = [blendAttachment(false, mask: 0b0011)]
    #expect(buildPipeline(old, old.pipelineLayout([]), oldPass, masked).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  @Test func topologiesTessellationAndGeometry() throws {
    let vk = fullVK()
    let layout = vk.pipelineLayout([])
    let (_, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])])
    for (t, want) in [(VK_PRIMITIVE_TOPOLOGY_POINT_LIST, PrimitiveTopology.pointList), (VK_PRIMITIVE_TOPOLOGY_LINE_LIST, .lineList),
                      (VK_PRIMITIVE_TOPOLOGY_LINE_STRIP, .lineStrip), (VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, .triangleList),
                      (VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, .triangleStrip), (VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, .triangleFan)] {
      var p = Pieces()
      p.blendAttachments = [blendAttachment()]
      p.assembly.topology = t
      #expect(buildPipeline(vk, layout, pass, p).0 == VK_SUCCESS)
      #expect(vk.gpu.graphicsPipelines.last!.topology == want)
    }
    var restart = Pieces()
    restart.blendAttachments = [blendAttachment()]
    restart.assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
    restart.assembly.primitiveRestartEnable = 1
    #expect(buildPipeline(vk, layout, pass, restart).0 == VK_SUCCESS)
    #expect(vk.gpu.graphicsPipelines.last!.primitiveRestart)
    // Adjacency has no core word.
    var adjacency = Pieces()
    adjacency.blendAttachments = [blendAttachment()]
    adjacency.assembly.topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST_WITH_ADJACENCY
    #expect(buildPipeline(vk, layout, pass, adjacency).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    // Patches with the two tessellation stages, and a geometry stage.
    var patches = Pieces()
    patches.blendAttachments = [blendAttachment()]
    patches.assembly.topology = VK_PRIMITIVE_TOPOLOGY_PATCH_LIST
    patches.tessellation.patchControlPoints = 3
    patches.stages = [VK_SHADER_STAGE_VERTEX_BIT, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT,
                      VK_SHADER_STAGE_GEOMETRY_BIT, VK_SHADER_STAGE_FRAGMENT_BIT]
    #expect(buildPipeline(vk, layout, pass, patches).0 == VK_SUCCESS)
    let d = vk.gpu.graphicsPipelines.last!
    #expect(d.topology == .patchList && d.patchControlPoints == 3)
    #expect(d.tessellationControl != nil && d.tessellationEvaluation != nil && d.geometry != nil)
    // The stages were lowered each as its own.
    #expect(loweredStages.suffix(5).map { $0.stage } == [.vertex, .fragment, .geometry, .tessellationControl, .tessellationEvaluation])
    // The old device has none of it.
    let old = VK()
    #expect(buildPipeline(old, old.pipelineLayout([]), renderPass(old), patches).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  @Test func dynamicStateIsTheCores() throws {
    let vk = fullVK()
    let layout = vk.pipelineLayout([])
    let (_, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM), vk.attachment(VK_FORMAT_D32_SFLOAT_S8_UINT)], [SubpassSpec(colors: [0], depth: 1)])
    var p = Pieces()
    p.blendAttachments = [blendAttachment()]
    p.dynamic = [
      VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_BLEND_CONSTANTS, VK_DYNAMIC_STATE_DEPTH_BIAS, VK_DYNAMIC_STATE_DEPTH_BOUNDS,
      VK_DYNAMIC_STATE_LINE_WIDTH, VK_DYNAMIC_STATE_STENCIL_REFERENCE, VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK, VK_DYNAMIC_STATE_STENCIL_WRITE_MASK,
    ]
    let (r, pipeline) = buildPipeline(vk, layout, pass, p)
    #expect(r == VK_SUCCESS)
    #expect(vk.gpu.graphicsPipelines[0].dynamic.rawValue == 127)
    // A dynamic state the core has no word for (cull mode, as 1.3 has it) refuses the pipeline.
    var other = p
    other.dynamic = [VK_DYNAMIC_STATE_CULL_MODE]
    #expect(buildPipeline(vk, layout, pass, other).0 == VK_ERROR_FEATURE_NOT_PRESENT)

    let image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: colorUsage).1
    let depth = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_D32_SFLOAT_S8_UINT, 8, 8, usage: depthUsage).1
    let views = [vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM).1, vk.fullView(depth, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_D32_SFLOAT_S8_UINT, aspect: 6).1]
    let fb = makeFramebuffer(vk, pass, views, 8, 8)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    // State set before the pass, and between draws: sent once, where it differs.
    var constants: [Float] = [0.1, 0.2, 0.3, 0.4]
    vk.fn("vkCmdSetBlendConstants", PFN_vkCmdSetBlendConstants.self)(cb, &constants)
    vk.fn("vkCmdSetDepthBias", PFN_vkCmdSetDepthBias.self)(cb, 1, 2, 3)
    vk.fn("vkCmdSetDepthBounds", PFN_vkCmdSetDepthBounds.self)(cb, 0.2, 0.8)
    vk.fn("vkCmdSetLineWidth", PFN_vkCmdSetLineWidth.self)(cb, 3)
    vk.fn("vkCmdSetStencilReference", PFN_vkCmdSetStencilReference.self)(cb, VK_STENCIL_FACE_FRONT_AND_BACK.rawValue, 9)
    vk.fn("vkCmdSetStencilCompareMask", PFN_vkCmdSetStencilCompareMask.self)(cb, VK_STENCIL_FACE_FRONT_BIT.rawValue, 0x0F)
    vk.fn("vkCmdSetStencilCompareMask", PFN_vkCmdSetStencilCompareMask.self)(cb, VK_STENCIL_FACE_BACK_BIT.rawValue, 0xF0)
    vk.fn("vkCmdSetStencilWriteMask", PFN_vkCmdSetStencilWriteMask.self)(cb, VK_STENCIL_FACE_FRONT_AND_BACK.rawValue, 0x3C)
    var viewport = VkViewport(x: 0, y: 0, width: 8, height: 8, minDepth: 0, maxDepth: 1)
    var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb, 0, 1, &viewport)
    vk.fn("vkCmdSetScissor", PFN_vkCmdSetScissor.self)(cb, 0, 1, &scissor)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    var clears = [VkClearValue(), VkClearValue()]
    clears[1].depthStencil = VkClearDepthStencilValue(depth: 0.5, stencil: 4)
    clears.withUnsafeBufferPointer { cv in
      begin.clearValueCount = 2
      begin.pClearValues = cv.baseAddress
      vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin, VK_SUBPASS_CONTENTS_INLINE)
    }
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    vk.fn("vkCmdSetLineWidth", PFN_vkCmdSetLineWidth.self)(cb, 2)
    vk.fn("vkCmdSetStencilReference", PFN_vkCmdSetStencilReference.self)(cb, VK_STENCIL_FACE_BACK_BIT.rawValue, 1)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    // Begin, then each state once before the first draw (the two faces of a value that differs one at a time), the draws, and
    // only what changed before the third.
    var names: [String] = []
    for x in c {
      switch x {
      case .beginRendering: names.append("begin")
      case .setViewport: names.append("viewport")
      case .setScissor: names.append("scissor")
      case .setBlendConstants(let k): #expect(k == BlendConstants(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)); names.append("blend")
      case .setDepthBias(let a, let b, let s): #expect(a == 1 && b == 2 && s == 3); names.append("bias")
      case .setDepthBounds(let a, let b): #expect(a == 0.2 && b == 0.8); names.append("bounds")
      case .setLineWidth(let w): names.append("line\(Int(w))")
      case .setStencilReference(let f, let v): names.append("ref\(f.rawValue):\(v)")
      case .setStencilCompareMask(let f, let v): names.append("cmask\(f.rawValue):\(v)")
      case .setStencilWriteMask(let f, let v): names.append("wmask\(f.rawValue):\(v)")
      case .draw: names.append("draw")
      case .endRendering: names.append("end")
      default: names.append("other")
      }
    }
    #expect(names == ["begin", "viewport", "scissor", "blend", "bias", "bounds", "line3", "ref3:9", "cmask1:15", "cmask2:240", "wmask3:60", "draw", "draw", "line2", "ref2:1", "draw", "end"])
    guard case .beginRendering(let info) = c[0] else { return }
    #expect(info.depthStencil?.clearDepth == 0.5 && info.depthStencil?.clearStencil == 4)
    #expect(info.depthStencil?.depthLoad == .clear && info.depthStencil?.stencilLoad == .dontCare)

    // The old device has no dynamic state: such a pipeline is refused and the list would be.
    let old = VK()
    #expect(buildPipeline(old, old.pipelineLayout([]), renderPass(old), p).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  // MARK: Passes

  @Test func depthAndMultisampleRenderPassesAndDynamicRendering() throws {
    let vk = fullVK()
    let color = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, samples: VK_SAMPLE_COUNT_4_BIT, usage: colorUsage).1
    let resolve = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, usage: colorUsage).1
    let depth = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_D32_SFLOAT, 16, 16, samples: VK_SAMPLE_COUNT_4_BIT, usage: depthUsage).1
    let views = [VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_D32_SFLOAT].enumerated().map { i, f in
      vk.fullView([color, resolve, depth][i], VK_IMAGE_VIEW_TYPE_2D, f, aspect: i == 2 ? 2 : 1).1
    }
    let (r, pass) = makePass(
      vk,
      [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM, samples: VK_SAMPLE_COUNT_4_BIT, load: VK_ATTACHMENT_LOAD_OP_CLEAR, store: VK_ATTACHMENT_STORE_OP_DONT_CARE),
       vk.attachment(VK_FORMAT_R8G8B8A8_UNORM, load: VK_ATTACHMENT_LOAD_OP_DONT_CARE),
       vk.attachment(VK_FORMAT_D32_SFLOAT, samples: VK_SAMPLE_COUNT_4_BIT, load: VK_ATTACHMENT_LOAD_OP_CLEAR, store: VK_ATTACHMENT_STORE_OP_DONT_CARE)],
      [SubpassSpec(colors: [0], resolves: [1], depth: 2)])
    #expect(r == VK_SUCCESS)
    let fb = makeFramebuffer(vk, pass, views, 16, 16)
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 16, height: 16))
    var clears = [VkClearValue(), VkClearValue(), VkClearValue()]
    clears[0].color.float32 = (1, 0, 0, 1)
    clears[2].depthStencil = VkClearDepthStencilValue(depth: 0.25, stencil: 0)
    clears.withUnsafeBufferPointer { cv in
      begin.clearValueCount = 3
      begin.pClearValues = cv.baseAddress
      vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin, VK_SUBPASS_CONTENTS_INLINE)
    }
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    #expect(c.count == 2)
    guard case .beginRendering(let info) = c[0] else { return }
    #expect(info.colors.count == 1 && info.colors[0].load == .clear(1, 0, 0, 1) && info.colors[0].store == .discard)
    #expect(info.colors[0].view.samples == 4 && info.colors[0].resolve?.image == vk.gpu.images[1])
    #expect(info.depthStencil?.view.format == .depth32f && info.depthStencil?.depthLoad == .clear && info.depthStencil?.depthStore == .discard)
    #expect(info.depthStencil?.clearDepth == 0.25)

    // Dynamic rendering with the same attachments, a depth resolve, layers and a view mask.
    let cb2 = vk.commandBuffer(vk.commandPool())
    vk.begin(cb2)
    var colorInfo = VkRenderingAttachmentInfo()
    colorInfo.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
    colorInfo.imageView = views[0]
    colorInfo.resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT
    colorInfo.resolveImageView = views[1]
    colorInfo.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD
    colorInfo.storeOp = VK_ATTACHMENT_STORE_OP_STORE
    var depthInfo = VkRenderingAttachmentInfo()
    depthInfo.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
    depthInfo.imageView = views[2]
    depthInfo.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
    depthInfo.storeOp = VK_ATTACHMENT_STORE_OP_STORE
    depthInfo.clearValue.depthStencil = VkClearDepthStencilValue(depth: 0.75, stencil: 0)
    var rendering = VkRenderingInfo()
    rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
    rendering.renderArea = VkRect2D(offset: VkOffset2D(x: 2, y: 2), extent: VkExtent2D(width: 8, height: 8))
    rendering.layerCount = 1
    rendering.colorAttachmentCount = 1
    rendering.pColorAttachments = leak([colorInfo])
    rendering.pDepthAttachment = leak([depthInfo])
    vk.fn("vkCmdBeginRendering", PFN_vkCmdBeginRendering.self)(cb2, &rendering)
    vk.fn("vkCmdEndRendering", PFN_vkCmdEndRendering.self)(cb2)
    #expect(vk.end(cb2) == VK_SUCCESS)
    #expect(vk.submit([cb2]) == VK_SUCCESS)
    guard case .beginRendering(let d) = vk.gpu.submitted[1].list.commands[0] else { return }
    #expect(d.colors[0].load == .load && d.colors[0].store == .store && d.colors[0].resolve != nil)
    #expect(d.depthStencil?.clearDepth == 0.75 && d.depthStencil?.stencilLoad == .dontCare)
    #expect(d.renderArea == RenderArea(x: 2, y: 2, width: 8, height: 8))

    // Integer attachments are cleared by the pass's own clear of attachments.
    let ints = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R32G32B32A32_UINT, 8, 8, usage: colorUsage).1
    let intView = vk.fullView(ints, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R32G32B32A32_UINT).1
    var ci = VkRenderingAttachmentInfo()
    ci.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
    ci.imageView = intView
    ci.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
    ci.storeOp = VK_ATTACHMENT_STORE_OP_STORE
    ci.clearValue.color.uint32 = (1, 2, 3, 4)
    var ri = VkRenderingInfo()
    ri.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
    ri.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    ri.layerCount = 1
    ri.colorAttachmentCount = 1
    ri.pColorAttachments = leak([ci])
    let cb3 = vk.commandBuffer(vk.commandPool())
    vk.begin(cb3)
    vk.fn("vkCmdBeginRendering", PFN_vkCmdBeginRendering.self)(cb3, &ri)
    vk.fn("vkCmdEndRendering", PFN_vkCmdEndRendering.self)(cb3)
    #expect(vk.end(cb3) == VK_SUCCESS)
    #expect(vk.submit([cb3]) == VK_SUCCESS)
    let list = vk.gpu.submitted[2].list.commands
    guard case .beginRendering(let ii) = list[0] else { return }
    #expect(ii.colors[0].load == .dontCare)
    #expect(list[1] == .clearAttachments([.color(index: 0, .uint(1, 2, 3, 4))], rects: [ClearRect(x: 0, y: 0, width: 8, height: 8, baseLayer: 0, layerCount: 1)]))
  }

  @Test func subpassesAreSuccessiveCorePasses() throws {
    let vk = fullVK()
    let a = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: colorUsage).1
    let b = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R16G16B16A16_SFLOAT, 8, 8, usage: colorUsage).1
    let d = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_D16_UNORM, 8, 8, usage: depthUsage).1
    let views = [vk.fullView(a, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM).1, vk.fullView(b, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R16G16B16A16_SFLOAT).1,
                 vk.fullView(d, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_D16_UNORM, aspect: 2).1]
    // Subpass 0 draws into a and the depth; subpass 1 into b and a again (a is read-modify-written); subpass 2 into b.
    let (r, pass) = makePass(
      vk,
      [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM, load: VK_ATTACHMENT_LOAD_OP_CLEAR, store: VK_ATTACHMENT_STORE_OP_STORE),
       vk.attachment(VK_FORMAT_R16G16B16A16_SFLOAT, load: VK_ATTACHMENT_LOAD_OP_DONT_CARE, store: VK_ATTACHMENT_STORE_OP_STORE),
       vk.attachment(VK_FORMAT_D16_UNORM, load: VK_ATTACHMENT_LOAD_OP_CLEAR, store: VK_ATTACHMENT_STORE_OP_DONT_CARE)],
      [SubpassSpec(colors: [0], depth: 2), SubpassSpec(colors: [1, 0]), SubpassSpec(colors: [1])])
    #expect(r == VK_SUCCESS)
    let layout = vk.pipelineLayout([])
    // A pipeline is made for the subpass it draws in.
    var p = Pieces()
    p.blendAttachments = [blendAttachment(), blendAttachment()]
    p.subpass = 1
    #expect(buildPipeline(vk, layout, pass, p).0 == VK_SUCCESS)
    #expect(vk.gpu.graphicsPipelines[0].colorFormats == [.rgba16float, .rgba8] && vk.gpu.graphicsPipelines[0].depthStencilFormat == nil)
    let fb = makeFramebuffer(vk, pass, views, 8, 8)
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    var clears = [VkClearValue(), VkClearValue(), VkClearValue()]
    clears[0].color.float32 = (0, 1, 0, 1)
    clears.withUnsafeBufferPointer { cv in
      begin.clearValueCount = 3
      begin.pClearValues = cv.baseAddress
      vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin, VK_SUBPASS_CONTENTS_INLINE)
    }
    vk.fn("vkCmdNextSubpass", PFN_vkCmdNextSubpass.self)(cb, VK_SUBPASS_CONTENTS_INLINE)
    vk.fn("vkCmdNextSubpass", PFN_vkCmdNextSubpass.self)(cb, VK_SUBPASS_CONTENTS_INLINE)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    // Each subpass is a core pass, and a barrier separates it from the next.
    #expect(c.count == 8)
    guard case .beginRendering(let s0) = c[0], case .beginRendering(let s1) = c[3], case .beginRendering(let s2) = c[6] else { return }
    #expect(c[1] == .endRendering && c[4] == .endRendering && c[7] == .endRendering)
    #expect(c[2] == .barrier(from: .fragment, to: .fragment) && c[5] == .barrier(from: .fragment, to: .fragment))
    // The first use of an attachment has the pass's load; the later ones load what was stored; the last has the pass's store.
    #expect(s0.colors.count == 1 && s0.colors[0].load == .clear(0, 1, 0, 1) && s0.colors[0].store == .store)
    #expect(s0.depthStencil?.depthLoad == .clear && s0.depthStencil?.depthStore == .discard)
    #expect(s1.colors.map { $0.view.format } == [.rgba16float, .rgba8] && s1.depthStencil == nil)
    #expect(s1.colors[0].load == .dontCare && s1.colors[0].store == .store)
    #expect(s1.colors[1].load == .load && s1.colors[1].store == .store)
    #expect(s2.colors.count == 1 && s2.colors[0].load == .load && s2.colors[0].store == .store)

    // An input attachment is a subpass's read of an attachment as a texture: the render pass is made.
    var attachments = [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)]
    var sub = VkSubpassDescription()
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
    sub.inputAttachmentCount = 1
    sub.pInputAttachments = leak([VkAttachmentReference(attachment: 0, layout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)])
    var info = VkRenderPassCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
    info.attachmentCount = 1
    info.pAttachments = leak(attachments)
    info.subpassCount = 1
    info.pSubpasses = leak([sub])
    var out: VkRenderPass?
    attachments.removeAll()
    #expect(vk.fn("vkCreateRenderPass", PFN_vkCreateRenderPass.self)(vk.device, &info, nil, &out) == VK_SUCCESS)
  }

  @Test func multiviewPassesAndPipelines() throws {
    let vk = fullVK()
    let color = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, layers: 4, usage: colorUsage).1
    let view = vk.fullView(color, VK_IMAGE_VIEW_TYPE_2D_ARRAY, VK_FORMAT_R8G8B8A8_UNORM, layers: 4).1
    let (r, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])], viewMasks: [0b0101])
    #expect(r == VK_SUCCESS)
    var p = Pieces()
    p.blendAttachments = [blendAttachment()]
    #expect(buildPipeline(vk, vk.pipelineLayout([]), pass, p).0 == VK_SUCCESS)
    #expect(vk.gpu.graphicsPipelines[0].viewMask == 0b0101)
    #expect(vk.gpu.graphicsPipelines[0].targets.viewMask == 0b0101)
    let fb = makeFramebuffer(vk, pass, [view], 8, 8, layers: 4)
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin, VK_SUBPASS_CONTENTS_INLINE)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    guard case .beginRendering(let info) = vk.gpu.submitted[0].list.commands[0] else { return }
    #expect(info.viewMask == 0b0101 && info.layerCount == 1)

    // Dynamic rendering: the mask in the pipeline's rendering info and in the pass, and layers where there is no mask.
    var q = Pieces()
    q.blendAttachments = [blendAttachment()]
    q.renderingColors = [VK_FORMAT_R8G8B8A8_UNORM]
    q.viewMask = 0b11
    #expect(buildPipeline(vk, vk.pipelineLayout([]), nil, q).0 == VK_SUCCESS)
    #expect(vk.gpu.graphicsPipelines[1].viewMask == 0b11)
    var attachment = VkRenderingAttachmentInfo()
    attachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
    attachment.imageView = view
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD
    attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE
    for (mask, layers, wantLayers) in [(UInt32(0b11), UInt32(1), UInt32(1)), (0, 3, 3)] {
      var ri = VkRenderingInfo()
      ri.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
      ri.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
      ri.layerCount = layers
      ri.viewMask = mask
      ri.colorAttachmentCount = 1
      ri.pColorAttachments = leak([attachment])
      let c = vk.commandBuffer(vk.commandPool())
      vk.begin(c)
      vk.fn("vkCmdBeginRendering", PFN_vkCmdBeginRendering.self)(c, &ri)
      vk.fn("vkCmdEndRendering", PFN_vkCmdEndRendering.self)(c)
      #expect(vk.end(c) == VK_SUCCESS)
      #expect(vk.submit([c]) == VK_SUCCESS)
      guard case .beginRendering(let i) = vk.gpu.submitted.last!.list.commands[0] else { return }
      #expect(i.viewMask == mask && i.layerCount == wantLayers)
    }
    // The device without multiview refuses the pass when it is recorded.
    let old = VK()
    let (_, oldPass) = makePass(old, [old.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])], viewMasks: [1])
    var oldPieces = Pieces()
    oldPieces.blendAttachments = [blendAttachment()]
    #expect(buildPipeline(old, old.pipelineLayout([]), oldPass, oldPieces).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  // MARK: Commands

  @Test func copiesBlitsResolvesAndRegions() throws {
    let vk = fullVK()
    let a = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, mips: 3, layers: 4, usage: sampledUsage).1
    let b = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 32, 32, mips: 3, layers: 4, usage: sampledUsage).1
    let ms = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 16, 16, samples: VK_SAMPLE_COUNT_4_BIT, usage: colorUsage).1
    let (ga, gb, gms) = (vk.gpu.images[0], vk.gpu.images[1], vk.gpu.images[2])
    let layers = VkImageSubresourceLayers(aspectMask: 1, mipLevel: 1, baseArrayLayer: 1, layerCount: 2)
    let memory = vk.allocate(MemoryTypes.upload, 65536)
    let buffer = vk.buffer(32768, usage: VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue, in: memory, at: 4096)
    let place = Handle.get(buffer, BufferObject.self)!.place!
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var copy = VkImageCopy(srcSubresource: layers, srcOffset: VkOffset3D(x: 1, y: 2, z: 0), dstSubresource: layers, dstOffset: VkOffset3D(x: 3, y: 4, z: 0),
                           extent: VkExtent3D(width: 2, height: 2, depth: 1))
    vk.fn("vkCmdCopyImage", PFN_vkCmdCopyImage.self)(cb, a, VK_IMAGE_LAYOUT_GENERAL, b, VK_IMAGE_LAYOUT_GENERAL, 1, &copy)
    var blit = VkImageBlit(srcSubresource: layers, srcOffsets: (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: 8, y: 8, z: 1)),
                           dstSubresource: layers, dstOffsets: (VkOffset3D(x: 16, y: 16, z: 0), VkOffset3D(x: 0, y: 0, z: 1)))
    vk.fn("vkCmdBlitImage", PFN_vkCmdBlitImage.self)(cb, a, VK_IMAGE_LAYOUT_GENERAL, b, VK_IMAGE_LAYOUT_GENERAL, 1, &blit, VK_FILTER_LINEAR)
    var resolve = VkImageResolve(srcSubresource: VkImageSubresourceLayers(aspectMask: 1, mipLevel: 0, baseArrayLayer: 0, layerCount: 1),
                                 srcOffset: VkOffset3D(), dstSubresource: VkImageSubresourceLayers(aspectMask: 1, mipLevel: 0, baseArrayLayer: 0, layerCount: 1),
                                 dstOffset: VkOffset3D(), extent: VkExtent3D(width: 16, height: 16, depth: 1))
    vk.fn("vkCmdResolveImage", PFN_vkCmdResolveImage.self)(cb, ms, VK_IMAGE_LAYOUT_GENERAL, a, VK_IMAGE_LAYOUT_GENERAL, 1, &resolve)
    var region = VkBufferImageCopy(bufferOffset: 256, bufferRowLength: 16, bufferImageHeight: 8, imageSubresource: layers,
                                   imageOffset: VkOffset3D(x: 4, y: 4, z: 0), imageExtent: VkExtent3D(width: 4, height: 4, depth: 1))
    vk.fn("vkCmdCopyBufferToImage", PFN_vkCmdCopyBufferToImage.self)(cb, buffer, a, VK_IMAGE_LAYOUT_GENERAL, 1, &region)
    vk.fn("vkCmdCopyImageToBuffer", PFN_vkCmdCopyImageToBuffer.self)(cb, a, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &region)
    // The 1.3 forms of the same.
    var copy2 = VkImageCopy2(sType: VK_STRUCTURE_TYPE_IMAGE_COPY_2, pNext: nil, srcSubresource: layers, srcOffset: VkOffset3D(), dstSubresource: layers,
                             dstOffset: VkOffset3D(), extent: VkExtent3D(width: 1, height: 1, depth: 1))
    var info2 = VkCopyImageInfo2()
    info2.sType = VK_STRUCTURE_TYPE_COPY_IMAGE_INFO_2
    info2.srcImage = a
    info2.dstImage = b
    info2.regionCount = 1
    info2.pRegions = leak([copy2])
    vk.fn("vkCmdCopyImage2", PFN_vkCmdCopyImage2.self)(cb, &info2)
    var bc = VkBufferCopy(srcOffset: 8, dstOffset: 16, size: 32)
    vk.fn("vkCmdCopyBuffer", PFN_vkCmdCopyBuffer.self)(cb, buffer, buffer, 1, &bc)
    copy2.extent.width = 2
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    let sub = ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 1, layerCount: 2)
    #expect(c[0] == .copyImage(src: ga, dst: gb, regions: [ImageCopyRegion(srcSubresource: sub, srcOffset: Offset3D(x: 1, y: 2), dstSubresource: sub,
                                                                              dstOffset: Offset3D(x: 3, y: 4), extent: Extent3D(width: 2, height: 2))]))
    #expect(c[1] == .blitImage(src: ga, dst: gb, regions: [ImageBlitRegion(srcSubresource: sub, srcMin: Offset3D(), srcMax: Offset3D(x: 8, y: 8, z: 1),
                                                                             dstSubresource: sub, dstMin: Offset3D(x: 16, y: 16), dstMax: Offset3D(x: 0, y: 0, z: 1))],
                               filter: .linear))
    #expect(c[2] == .resolveImage(src: gms, dst: ga, regions: [ImageCopyRegion(extent: Extent3D(width: 16, height: 16))]))
    let r = BufferImageRegion(bufferOffset: place.offset + 256, bufferRowLength: 16, bufferImageHeight: 8, subresource: sub,
                              imageOffset: Offset3D(x: 4, y: 4), imageExtent: Extent3D(width: 4, height: 4))
    #expect(c[3] == .copyBufferToImageRegions(place.memory, ga, regions: [r]))
    #expect(c[4] == .copyImageToBufferRegions(ga, place.memory, regions: [r]))
    guard case .copyImage(_, _, let regions2) = c[5] else { return }
    #expect(regions2.count == 1 && regions2[0].extent == Extent3D(width: 1, height: 1))
    #expect(c[6] == .copyBuffer(from: place.memory, fromOffset: place.offset + 8, to: place.memory, toOffset: place.offset + 16, bytes: 32))

    // The device without them: a region copy of a whole image still works, a partial one and a blit don't.
    let old = VK()
    let oi = old.image(usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
    let om = old.allocate(MemoryTypes.upload, 4096)
    let ob = old.buffer(1024, usage: VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue, in: om)
    let ocb = old.commandBuffer(old.commandPool())
    old.begin(ocb)
    var whole = VkBufferImageCopy(bufferOffset: 0, bufferRowLength: 0, bufferImageHeight: 0,
                                  imageSubresource: VkImageSubresourceLayers(aspectMask: 1, mipLevel: 0, baseArrayLayer: 0, layerCount: 1), imageOffset: VkOffset3D(),
                                  imageExtent: VkExtent3D(width: 4, height: 4, depth: 1))
    old.fn("vkCmdCopyBufferToImage", PFN_vkCmdCopyBufferToImage.self)(ocb, ob, oi, VK_IMAGE_LAYOUT_GENERAL, 1, &whole)
    #expect(old.end(ocb) == VK_SUCCESS)
    old.begin(ocb)
    var blit2 = blit
    old.fn("vkCmdBlitImage", PFN_vkCmdBlitImage.self)(ocb, oi, VK_IMAGE_LAYOUT_GENERAL, oi, VK_IMAGE_LAYOUT_GENERAL, 1, &blit2, VK_FILTER_NEAREST)
    #expect(old.end(ocb) != VK_SUCCESS)
  }

  @Test func clearsFillsAndUpdates() throws {
    let vk = fullVK()
    let img = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, mips: 2, layers: 3, usage: colorUsage).1
    let ints = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R32G32_SINT, 8, 8, usage: colorUsage).1
    let depth = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_D24_UNORM_S8_UINT, 8, 8, mips: 2, usage: depthUsage).1
    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let buffer = vk.buffer(1024, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue, in: memory, at: 128)
    let place = Handle.get(buffer, BufferObject.self)!.place!
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var color = VkClearColorValue()
    color.float32 = (0.5, 0.25, 0, 1)
    var range = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 1, levelCount: ~0, baseArrayLayer: 1, layerCount: ~0)
    vk.fn("vkCmdClearColorImage", PFN_vkCmdClearColorImage.self)(cb, img, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range)
    var integer = VkClearColorValue()
    integer.int32 = (-1, 2, 0, 0)
    var all1 = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    vk.fn("vkCmdClearColorImage", PFN_vkCmdClearColorImage.self)(cb, ints, VK_IMAGE_LAYOUT_GENERAL, &integer, 1, &all1)
    var ds = VkClearDepthStencilValue(depth: 0.5, stencil: 7)
    var dsRange = VkImageSubresourceRange(aspectMask: 6, baseMipLevel: 0, levelCount: 2, baseArrayLayer: 0, layerCount: 1)
    vk.fn("vkCmdClearDepthStencilImage", PFN_vkCmdClearDepthStencilImage.self)(cb, depth, VK_IMAGE_LAYOUT_GENERAL, &ds, 1, &dsRange)
    vk.fn("vkCmdFillBuffer", PFN_vkCmdFillBuffer.self)(cb, buffer, 16, 64, 0xAABB_CCDD)
    var bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    vk.fn("vkCmdUpdateBuffer", PFN_vkCmdUpdateBuffer.self)(cb, buffer, 32, 8, &bytes)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    let (gi, gints, gd) = (vk.gpu.images[0], vk.gpu.images[1], vk.gpu.images[2])
    #expect(c[0] == .clearColorImage(gi, .float(0.5, 0.25, 0, 1), ranges: [ImageSubresourceRange(aspects: .color, baseMip: 1, mipCount: 1, baseLayer: 1, layerCount: 2)]))
    #expect(c[1] == .clearColorImage(gints, .sint(-1, 2, 0, 0), ranges: [ImageSubresourceRange()]))
    #expect(c[2] == .clearDepthStencilImage(gd, depth: 0.5, stencil: 7, ranges: [ImageSubresourceRange(aspects: .depthStencil, baseMip: 0, mipCount: 2)]))
    #expect(c[3] == .fillBuffer(place.memory, offset: place.offset + 16, bytes: 64, value: 0xAABB_CCDD))
    #expect(c[4] == .updateBuffer(place.memory, offset: place.offset + 32, data: bytes))

    // clearAttachments in a pass clears the colour by its format and the depth by its aspects.
    let colorView = vk.fullView(img, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, levels: 1).1
    let intView = vk.fullView(ints, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R32G32_SINT).1
    let cb2 = vk.commandBuffer(vk.commandPool())
    vk.begin(cb2)
    func attachment(_ v: VkImageView?) -> VkRenderingAttachmentInfo {
      var a = VkRenderingAttachmentInfo()
      a.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
      a.imageView = v
      a.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD
      a.storeOp = VK_ATTACHMENT_STORE_OP_STORE
      return a
    }
    var ri = VkRenderingInfo()
    ri.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
    ri.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    ri.layerCount = 1
    ri.colorAttachmentCount = 2
    ri.pColorAttachments = leak([attachment(colorView), attachment(intView)])
    vk.fn("vkCmdBeginRendering", PFN_vkCmdBeginRendering.self)(cb2, &ri)
    var clearValue = VkClearValue()
    clearValue.color.float32 = (1, 1, 1, 1)
    var intValue = VkClearValue()
    intValue.color.int32 = (5, 6, 0, 0)
    let attachments = [VkClearAttachment(aspectMask: 1, colorAttachment: 0, clearValue: clearValue), VkClearAttachment(aspectMask: 1, colorAttachment: 1, clearValue: intValue)]
    var rect = VkClearRect(rect: VkRect2D(offset: VkOffset2D(x: 1, y: 1), extent: VkExtent2D(width: 4, height: 4)), baseArrayLayer: 0, layerCount: 1)
    vk.fn("vkCmdClearAttachments", PFN_vkCmdClearAttachments.self)(cb2, 2, leak(attachments), 1, &rect)
    vk.fn("vkCmdEndRendering", PFN_vkCmdEndRendering.self)(cb2)
    #expect(vk.end(cb2) == VK_SUCCESS)
    #expect(vk.submit([cb2]) == VK_SUCCESS)
    let c2 = vk.gpu.submitted[1].list.commands
    #expect(c2[1] == .clearAttachments([.color(index: 0, .float(1, 1, 1, 1)), .color(index: 1, .sint(5, 6, 0, 0))],
                                       rects: [ClearRect(x: 1, y: 1, width: 4, height: 4, baseLayer: 0, layerCount: 1)]))

    // A device without clears: a clear of a whole simple image is the pass it always was, and a partial one fails.
    let old = VK()
    let oi = old.image(usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue)
    let ocb = old.commandBuffer(old.commandPool())
    old.begin(ocb)
    var one = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    old.fn("vkCmdClearColorImage", PFN_vkCmdClearColorImage.self)(ocb, oi, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &one)
    #expect(old.end(ocb) == VK_SUCCESS)
    guard case .beginRendering = old.gpu.submitted.first?.list.commands.first ?? .endRendering else {
      #expect(old.submit([ocb]) == VK_SUCCESS)
      return
    }
  }

  @Test func countedIndirectDrawsAndStatisticsQueries() throws {
    let vk = fullVK()
    let layout = vk.pipelineLayout([])
    let (_, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])])
    var p = Pieces()
    p.blendAttachments = [blendAttachment()]
    let pipeline = buildPipeline(vk, layout, pass, p).1
    let image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: colorUsage).1
    let view = vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM).1
    let fb = makeFramebuffer(vk, pass, [view], 8, 8)
    let memory = vk.allocate(MemoryTypes.upload, 8192)
    let usage = VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue
    let args = vk.buffer(1024, usage: usage, in: memory, at: 0)
    let counts = vk.buffer(64, usage: usage, in: memory, at: 2048)
    let place = Handle.get(args, BufferObject.self)!.place!
    let cplace = Handle.get(counts, BufferObject.self)!.place!

    // A pipeline-statistics pool and an occlusion pool.
    var info = VkQueryPoolCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
    info.queryType = VK_QUERY_TYPE_PIPELINE_STATISTICS
    info.queryCount = 2
    info.pipelineStatistics = VK_QUERY_PIPELINE_STATISTIC_VERTEX_SHADER_INVOCATIONS_BIT.rawValue | VK_QUERY_PIPELINE_STATISTIC_FRAGMENT_SHADER_INVOCATIONS_BIT.rawValue
      | VK_QUERY_PIPELINE_STATISTIC_COMPUTE_SHADER_INVOCATIONS_BIT.rawValue
    var pool: VkQueryPool?
    #expect(vk.fn("vkCreateQueryPool", PFN_vkCreateQueryPool.self)(vk.device, &info, nil, &pool) == VK_SUCCESS)
    #expect(vk.gpu.querySets[0].kind == .pipelineStatistics(PipelineStatistics.vertexShaderInvocations | .fragmentShaderInvocations | .computeShaderInvocations))

    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin, VK_SUBPASS_CONTENTS_INLINE)
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    var viewport = VkViewport(x: 0, y: 0, width: 8, height: 8, minDepth: 0, maxDepth: 1)
    var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb, 0, 1, &viewport)
    vk.fn("vkCmdSetScissor", PFN_vkCmdSetScissor.self)(cb, 0, 1, &scissor)
    vk.fn("vkCmdBeginQuery", PFN_vkCmdBeginQuery.self)(cb, pool, 1, 0)
    vk.fn("vkCmdDrawIndirectCount", PFN_vkCmdDrawIndirectCount.self)(cb, args, 64, counts, 8, 10, 16)
    vk.fn("vkCmdBindIndexBuffer", PFN_vkCmdBindIndexBuffer.self)(cb, args, 512, VK_INDEX_TYPE_UINT16)
    vk.fn("vkCmdDrawIndexedIndirectCount", PFN_vkCmdDrawIndexedIndirectCount.self)(cb, args, 128, counts, 16, 4, 20)
    vk.fn("vkCmdEndQuery", PFN_vkCmdEndQuery.self)(cb, pool, 1)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    var seen = 0
    for x in c {
      switch x {
      case .drawIndirectCount(_, _, let a, let off, let cb, let cOff, let max, let stride):
        #expect(a == place.memory && off == place.offset + 64 && cb == cplace.memory && cOff == cplace.offset + 8 && max == 10 && stride == 16)
        seen += 1
      case .drawIndexedIndirectCount(_, _, _, let ioff, let type, _, let off, _, let cOff, let max, let stride):
        #expect(ioff == place.offset + 512 && type == .uint16 && off == place.offset + 128 && cOff == cplace.offset + 16 && max == 4 && stride == 20)
        seen += 1
      case .beginQuery(let s, let i): #expect(s.kind == vk.gpu.querySets[0].kind && i == 1); seen += 1
      case .endQuery(_, let i): #expect(i == 1); seen += 1
      default: break
      }
    }
    #expect(seen == 4)

    // Results: one value for each counter of each query, in the order of the bits.
    vk.gpu.queryResults = [10, 11, 12, 20, 21, 22]
    var data = [UInt64](repeating: 0, count: 8)
    #expect(vk.fn("vkGetQueryPoolResults", PFN_vkGetQueryPoolResults.self)(vk.device, pool, 0, 2, 64, &data, 32, VK_QUERY_RESULT_64_BIT.rawValue | VK_QUERY_RESULT_WAIT_BIT.rawValue) == VK_SUCCESS)
    #expect(Array(data[0..<3]) == [10, 11, 12] && Array(data[4..<7]) == [20, 21, 22])
    // The old device has no statistics.
    let old = VK()
    var oldPool: VkQueryPool?
    #expect(old.fn("vkCreateQueryPool", PFN_vkCreateQueryPool.self)(old.device, &info, nil, &oldPool) == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  @Test func secondaryCommandBuffersAndEvents() throws {
    let vk = fullVK()
    let layout = vk.pipelineLayout([])
    let (_, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])])
    var p = Pieces()
    p.blendAttachments = [blendAttachment()]
    let pipeline = buildPipeline(vk, layout, pass, p).1
    let image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: colorUsage).1
    let fb = makeFramebuffer(vk, pass, [vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM).1], 8, 8)
    let pool = vk.commandPool()
    var alloc = VkCommandBufferAllocateInfo()
    alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    alloc.commandPool = pool
    alloc.level = VK_COMMAND_BUFFER_LEVEL_SECONDARY
    alloc.commandBufferCount = 1
    var secondary: VkCommandBuffer?
    #expect(vk.fn("vkAllocateCommandBuffers", PFN_vkAllocateCommandBuffers.self)(vk.device, &alloc, &secondary) == VK_SUCCESS)

    // The secondary draws inside the primary's pass, with the pass continued.
    var inheritance = VkCommandBufferInheritanceInfo()
    inheritance.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO
    inheritance.renderPass = pass
    inheritance.framebuffer = fb
    var sbegin = VkCommandBufferBeginInfo()
    sbegin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    sbegin.flags = VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT.rawValue
    sbegin.pInheritanceInfo = leak([inheritance])
    #expect(vk.fn("vkBeginCommandBuffer", PFN_vkBeginCommandBuffer.self)(secondary, &sbegin) == VK_SUCCESS)
    var viewport = VkViewport(x: 0, y: 0, width: 8, height: 8, minDepth: 0, maxDepth: 1)
    var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(secondary, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(secondary, 0, 1, &viewport)
    vk.fn("vkCmdSetScissor", PFN_vkCmdSetScissor.self)(secondary, 0, 1, &scissor)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(secondary, 3, 1, 0, 0)
    #expect(vk.end(secondary) == VK_SUCCESS)

    let event = {
      var info = VkEventCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_EVENT_CREATE_INFO
      var e: VkEvent?
      #expect(vk.fn("vkCreateEvent", PFN_vkCreateEvent.self)(vk.device, &info, nil, &e) == VK_SUCCESS)
      return e
    }()
    #expect(vk.fn("vkGetEventStatus", PFN_vkGetEventStatus.self)(vk.device, event) == VK_EVENT_RESET)
    let primary = vk.commandBuffer(pool)
    vk.begin(primary)
    vk.fn("vkCmdSetEvent", PFN_vkCmdSetEvent.self)(primary, event, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT.rawValue)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(primary, &begin, VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS)
    var buffers = [secondary]
    vk.fn("vkCmdExecuteCommands", PFN_vkCmdExecuteCommands.self)(primary, 1, &buffers)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(primary)
    var events = [event]
    vk.fn("vkCmdWaitEvents", PFN_vkCmdWaitEvents.self)(primary, 1, &events, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT.rawValue, VK_PIPELINE_STAGE_VERTEX_SHADER_BIT.rawValue, 0, nil, 0, nil, 0, nil)
    #expect(vk.end(primary) == VK_SUCCESS)
    // Nothing runs, so the event is not set until the buffer is submitted.
    #expect(vk.fn("vkGetEventStatus", PFN_vkGetEventStatus.self)(vk.device, event) == VK_EVENT_RESET)
    #expect(vk.submit([primary]) == VK_SUCCESS)
    #expect(vk.fn("vkGetEventStatus", PFN_vkGetEventStatus.self)(vk.device, event) == VK_EVENT_SET)
    let c = vk.gpu.submitted[0].list.commands
    // begin, the secondary's draw (its state first), end, the wait's barrier.
    guard case .beginRendering = c[0] else { return }
    #expect(c[1] == .setViewport(x: 0, y: 0, width: 8, height: 8))
    #expect(c[2] == .setScissor(x: 0, y: 0, width: 8, height: 8))
    guard case .draw = c[3] else { return }
    #expect(c[4] == .endRendering)
    #expect(c[5] == .barrier(from: .compute, to: .vertex))
    #expect(vk.fn("vkResetEvent", PFN_vkResetEvent.self)(vk.device, event) == VK_SUCCESS)
    #expect(vk.fn("vkSetEvent", PFN_vkSetEvent.self)(vk.device, event) == VK_SUCCESS)
    #expect(vk.fn("vkGetEventStatus", PFN_vkGetEventStatus.self)(vk.device, event) == VK_EVENT_SET)
  }

  @Test func imageBarriersNameTheirSubresources() throws {
    let vk = fullVK()
    let image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, mips: 2, layers: 2, usage: sampledUsage).1
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var barrier = VkImageMemoryBarrier()
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
    barrier.image = image
    barrier.subresourceRange = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 1, levelCount: ~0, baseArrayLayer: 0, layerCount: ~0)
    vk.fn("vkCmdPipelineBarrier", PFN_vkCmdPipelineBarrier.self)(cb, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue, 0, 0, nil, 0, nil, 1, &barrier)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    #expect(c[0] == .barrier(from: .transfer, to: .fragment))
    #expect(c[1] == .imageBarrier(from: .transfer, to: .fragment, image: vk.gpu.images[0],
                                  range: ImageSubresourceRange(aspects: .color, baseMip: 1, mipCount: 1, baseLayer: 0, layerCount: 2)))
  }
}
