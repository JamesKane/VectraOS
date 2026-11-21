// SPDX-License-Identifier: BSD-3-Clause

// What the physical device reports, and what the core says of it: the features the backend asks of the device (the
// ones the core has a flag for, taken where the device has them), the limits, and each format's capabilities from
// vkGetPhysicalDeviceFormatProperties. A flag is set from what the device reports and never assumed.

import GPUCore
import Vulkan

/// The features and properties of a physical device that the core names.
@safe struct HostFeatures {
  var core = VkPhysicalDeviceFeatures()
  var f11 = unsafe VkPhysicalDeviceVulkan11Features()
  var f12 = unsafe VkPhysicalDeviceVulkan12Features()
  var f13 = unsafe VkPhysicalDeviceVulkan13Features()
  var p11 = unsafe VkPhysicalDeviceVulkan11Properties()
  /// VK_EXT_custom_border_color's features, and whether the device has the extension (the structure is chained only then).
  var customBorder = unsafe VkPhysicalDeviceCustomBorderColorFeaturesEXT()
  var hasCustomBorder = false
  var limits = VkPhysicalDeviceLimits()
  /// The Vulkan version the device reports. A device of 1.3 or later has every feature the spec makes mandatory of it, which is how
  /// the flags for those are set: from what the device says it is, not assumed.
  var apiVersion: UInt32 = 0

  init() {
    unsafe f11.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
    unsafe f12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    unsafe f13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    unsafe p11.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES
    unsafe customBorder.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT
  }

  /// What the device has.
  static func query(_ c: VulkanCommands, _ physical: VkPhysicalDevice) -> HostFeatures {
    var h = HostFeatures()
    h.hasCustomBorder = unsafe VulkanDevice.supports(c, physical, ["VK_EXT_custom_border_color"])
    var all = unsafe VkPhysicalDeviceFeatures2()
    unsafe all.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
    unsafe withUnsafeMutablePointer(to: &h.customBorder) { pcb in
    unsafe h.f13.pNext = h.hasCustomBorder ? unsafe UnsafeMutableRawPointer(pcb) : nil
    unsafe withUnsafeMutablePointer(to: &h.f13) { p13 in
      unsafe h.f12.pNext = unsafe UnsafeMutableRawPointer(p13)
      unsafe withUnsafeMutablePointer(to: &h.f12) { p12 in
        unsafe h.f11.pNext = unsafe UnsafeMutableRawPointer(p12)
        unsafe withUnsafeMutablePointer(to: &h.f11) { p11 in
          unsafe all.pNext = unsafe UnsafeMutableRawPointer(p11)
          unsafe c.vkGetPhysicalDeviceFeatures2!(physical, &all)
        }
      }
    }
    }
    unsafe h.customBorder.pNext = nil
    unsafe h.f11.pNext = nil
    unsafe h.f12.pNext = nil
    unsafe h.f13.pNext = nil
    h.core = unsafe all.features
    var props = unsafe VkPhysicalDeviceProperties2()
    unsafe props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
    unsafe withUnsafeMutablePointer(to: &h.p11) { p in
      unsafe props.pNext = unsafe UnsafeMutableRawPointer(p)
      unsafe c.vkGetPhysicalDeviceProperties2!(physical, &props)
    }
    unsafe h.p11.pNext = nil
    h.limits = unsafe props.properties.limits
    h.apiVersion = unsafe props.properties.apiVersion
    return h
  }

  /// What the backend asks of the device: the features the core names that the device has, the heap's, and what the
  /// backend's own commands need.
  func enabled(storageOK: Bool, texelOK: Bool = false) -> HostFeatures {
    var e = HostFeatures()
    e.hasCustomBorder = hasCustomBorder
    unsafe e.customBorder.customBorderColors = customBorder.customBorderColors
    unsafe e.customBorder.customBorderColorWithoutFormat = customBorder.customBorderColorWithoutFormat
    unsafe e.core.samplerAnisotropy = core.samplerAnisotropy
    unsafe e.core.depthClamp = core.depthClamp
    unsafe e.core.depthBiasClamp = core.depthBiasClamp
    unsafe e.core.fillModeNonSolid = core.fillModeNonSolid
    unsafe e.core.wideLines = core.wideLines
    unsafe e.core.depthBounds = core.depthBounds
    unsafe e.core.independentBlend = core.independentBlend
    unsafe e.core.dualSrcBlend = core.dualSrcBlend
    unsafe e.core.logicOp = core.logicOp
    unsafe e.core.geometryShader = core.geometryShader
    unsafe e.core.tessellationShader = core.tessellationShader
    unsafe e.core.sampleRateShading = core.sampleRateShading
    unsafe e.core.textureCompressionASTC_LDR = core.textureCompressionASTC_LDR
    unsafe e.core.textureCompressionETC2 = core.textureCompressionETC2
    unsafe e.core.textureCompressionBC = core.textureCompressionBC
    unsafe e.core.multiDrawIndirect = core.multiDrawIndirect
    unsafe e.core.drawIndirectFirstInstance = core.drawIndirectFirstInstance
    unsafe e.core.imageCubeArray = core.imageCubeArray
    unsafe e.core.pipelineStatisticsQuery = core.pipelineStatisticsQuery
    unsafe e.core.shaderFloat64 = core.shaderFloat64
    unsafe e.core.shaderInt64 = core.shaderInt64
    unsafe e.core.shaderInt16 = core.shaderInt16
    unsafe e.core.shaderStorageImageExtendedFormats = core.shaderStorageImageExtendedFormats
    unsafe e.core.shaderStorageImageReadWithoutFormat = core.shaderStorageImageReadWithoutFormat
    unsafe e.core.shaderStorageImageWriteWithoutFormat = core.shaderStorageImageWriteWithoutFormat
    unsafe e.core.shaderStorageImageMultisample = core.shaderStorageImageMultisample
    unsafe e.core.shaderClipDistance = core.shaderClipDistance
    unsafe e.core.shaderCullDistance = core.shaderCullDistance
    unsafe e.core.shaderImageGatherExtended = core.shaderImageGatherExtended
    unsafe e.core.shaderResourceMinLod = core.shaderResourceMinLod
    unsafe e.f11.multiview = f11.multiview
    unsafe e.f11.shaderDrawParameters = f11.shaderDrawParameters
    unsafe e.f12.bufferDeviceAddress = 1
    unsafe e.f12.timelineSemaphore = 1
    // The bindless heap (descriptor indexing).
    unsafe e.f12.descriptorIndexing = 1
    unsafe e.f12.runtimeDescriptorArray = 1
    unsafe e.f12.descriptorBindingPartiallyBound = 1
    unsafe e.f12.descriptorBindingSampledImageUpdateAfterBind = 1
    unsafe e.f12.shaderSampledImageArrayNonUniformIndexing = 1
    if storageOK {
      unsafe e.f12.descriptorBindingStorageImageUpdateAfterBind = 1
      unsafe e.f12.shaderStorageImageArrayNonUniformIndexing = 1
    }
    if texelOK {
      unsafe e.f12.descriptorBindingUniformTexelBufferUpdateAfterBind = 1
      unsafe e.f12.descriptorBindingStorageTexelBufferUpdateAfterBind = 1
      unsafe e.f12.shaderUniformTexelBufferArrayNonUniformIndexing = 1
      unsafe e.f12.shaderStorageTexelBufferArrayNonUniformIndexing = 1
    }
    unsafe e.f12.shaderFloat16 = f12.shaderFloat16
    unsafe e.f12.shaderInt8 = f12.shaderInt8
    unsafe e.f12.drawIndirectCount = f12.drawIndirectCount
    unsafe e.f12.samplerMirrorClampToEdge = f12.samplerMirrorClampToEdge
    unsafe e.f12.shaderBufferInt64Atomics = f12.shaderBufferInt64Atomics
    unsafe e.f12.shaderOutputViewportIndex = f12.shaderOutputViewportIndex
    unsafe e.f12.shaderOutputLayer = f12.shaderOutputLayer
    unsafe e.f13.dynamicRendering = 1
    unsafe e.f13.synchronization2 = 1
    unsafe e.f13.shaderDemoteToHelperInvocation = f13.shaderDemoteToHelperInvocation
    return e
  }

  /// Calls `body` with the head of the feature chain (a `VkPhysicalDeviceFeatures2`, for `VkDeviceCreateInfo.pNext`).
  mutating func withChain<R>(_ body: (UnsafeRawPointer) -> R) -> R {
    var all = unsafe VkPhysicalDeviceFeatures2()
    unsafe all.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
    unsafe all.features = core
    let haveBorder = hasCustomBorder
    return unsafe withUnsafeMutablePointer(to: &customBorder) { pcb in
      return unsafe withUnsafeMutablePointer(to: &f13) { p13 in
        unsafe f13.pNext = haveBorder ? unsafe UnsafeMutableRawPointer(pcb) : nil
        unsafe f12.pNext = unsafe UnsafeMutableRawPointer(p13)
        return unsafe withUnsafeMutablePointer(to: &f12) { p12 in
          unsafe f11.pNext = unsafe UnsafeMutableRawPointer(p12)
          return unsafe withUnsafeMutablePointer(to: &f11) { p11 in
            unsafe all.pNext = unsafe UnsafeMutableRawPointer(p11)
            return withUnsafePointer(to: &all) { unsafe body(UnsafeRawPointer($0)) }
          }
        }
      }
    }
  }

  /// The core's limits and features as this device offers them.
  func deviceLimits(_ c: VulkanCommands, _ physical: VkPhysicalDevice, storageOK: Bool, texelOK: Bool, timestampBits: UInt32,
                    queueFlags: UInt32) -> DeviceLimits {
    var l = DeviceLimits()
    var f = DeviceFeatures()
    // What Vulkan 1.3 requires of every device (the backend's device needs dynamic rendering, which is 1.3's).
    let required = apiVersion >= (1 << 22) | (3 << 12)
    // The queue the backend uses does graphics, which includes transfers.
    let transfer = queueFlags & (VK_QUEUE_GRAPHICS_BIT.rawValue | VK_QUEUE_COMPUTE_BIT.rawValue | VK_QUEUE_TRANSFER_BIT.rawValue) != 0
    f.indexedDraw = required
    f.indirectDraw = required
    f.indirectDispatch = required
    f.sampledImages = required
    f.uniformTexelBuffers = texelOK
    f.storageTexelBuffers = texelOK
    f.storageImages = storageOK
    f.timestampQueries = timestampBits > 0
    f.occlusionQueries = required
    f.loadAttachments = required
    f.multipleDrawsPerPass = required
    f.multipleColorAttachments = limits.maxColorAttachments > 1
    // Images: depth and stencil are set below, from the formats the device offers.
    f.mipmaps = required
    f.arrayImages = limits.maxImageArrayLayers > 1
    f.cubeImages = required
    f.volumeImages = limits.maxImageDimension3D > 1
    f.multisample = limits.framebufferColorSampleCounts > 1
    f.imageViews = required
    f.images1D = required
    f.imageSwizzle = required
    f.compressedASTC = core.textureCompressionASTC_LDR != 0
    f.compressedETC2 = core.textureCompressionETC2 != 0
    f.compressedBC = core.textureCompressionBC != 0
    // Samplers.
    f.samplerAnisotropy = core.samplerAnisotropy != 0
    f.samplerCompare = required
    f.samplerBorder = required
    f.customBorderColor = unsafe hasCustomBorder && customBorder.customBorderColors != 0 && customBorder.customBorderColorWithoutFormat != 0
    f.unnormalizedCoordinates = required
    f.samplerMinMagFilters = required
    f.samplerAxisAddressModes = required
    f.samplerMirrorClampToEdge = unsafe f12.samplerMirrorClampToEdge != 0
    // Pipeline state.
    f.cullModes = required
    f.rasterizerDiscard = required
    f.generalBlend = required
    f.independentBlend = core.independentBlend != 0
    f.dualSourceBlend = core.dualSrcBlend != 0
    f.logicOps = core.logicOp != 0
    f.fillModeNonSolid = core.fillModeNonSolid != 0
    f.wideLines = core.wideLines != 0
    f.depthClamp = core.depthClamp != 0
    f.depthBias = required
    f.depthBounds = core.depthBounds != 0
    f.geometryShader = core.geometryShader != 0
    f.tessellation = core.tessellationShader != 0
    f.multiview = unsafe f11.multiview != 0
    f.extendedTopologies = required
    f.primitiveRestart = required
    f.sampleShading = core.sampleRateShading != 0
    f.alphaToCoverage = required
    // alphaToOne and depthStencilResolve are reported false: the backend doesn't enable or replay them.
    f.alphaToOne = false
    f.specializationConstants = required
    f.dynamicState = required
    // Commands.
    f.copyImage = required && transfer
    f.blitImage = required && transfer
    f.resolveImage = required && transfer && f.multisample
    f.resolveAttachments = required && f.multisample
    f.depthStencilResolve = false
    f.imageRegionCopies = required && transfer
    f.fillBuffer = required && transfer
    f.updateBuffer = required && transfer
    f.clearImage = required && transfer
    f.clearAttachments = required
    f.drawIndirectCount = unsafe f12.drawIndirectCount != 0
    f.pipelineStatisticsQueries = core.pipelineStatisticsQuery != 0
    f.importHandle = false
    // What shaders may do.
    f.shaderFloat16 = unsafe f12.shaderFloat16 != 0
    f.shaderInt8 = unsafe f12.shaderInt8 != 0
    f.shaderInt16 = core.shaderInt16 != 0
    f.shaderInt64 = core.shaderInt64 != 0
    f.shaderFloat64 = core.shaderFloat64 != 0
    f.subgroupOperations = unsafe p11.subgroupSize > 0 && p11.subgroupSupportedOperations & VK_SUBGROUP_FEATURE_BASIC_BIT.rawValue != 0
    f.shaderAtomic32 = required
    f.shaderAtomic64 = unsafe f12.shaderBufferInt64Atomics != 0
    f.shaderDerivatives = required
    f.shaderStorageImageExtendedFormats = core.shaderStorageImageExtendedFormats != 0
    f.shaderStorageImageReadWithoutFormat = core.shaderStorageImageReadWithoutFormat != 0
    f.shaderStorageImageWriteWithoutFormat = core.shaderStorageImageWriteWithoutFormat != 0
    f.shaderClipDistance = core.shaderClipDistance != 0
    f.shaderCullDistance = core.shaderCullDistance != 0
    f.shaderImageGatherExtended = core.shaderImageGatherExtended != 0
    f.shaderMinLod = core.shaderResourceMinLod != 0
    f.shaderDrawParameters = unsafe f11.shaderDrawParameters != 0
    f.shaderDemoteToHelperInvocation = unsafe f13.shaderDemoteToHelperInvocation != 0
    f.shaderViewportIndexLayer = unsafe f12.shaderOutputViewportIndex != 0 && f12.shaderOutputLayer != 0
    f.shaderSampleRateShading = core.sampleRateShading != 0

    // Limits.
    l.heapTextures = Heap.textureCapacity
    l.heapSamplers = Heap.samplerCapacity
    l.heapStorageImages = storageOK ? VulkanDevice.heapStorageImageSlots : 0
    l.heapTexelBuffers = texelOK ? VulkanDevice.heapTexelBufferSlots : 0
    l.heapStorageTexelBuffers = texelOK ? VulkanDevice.heapTexelBufferSlots : 0
    l.maxTexelBufferElements = texelOK ? limits.maxTexelBufferElements : 0
    l.maxImageDimension = Int32(truncatingIfNeeded: limits.maxImageDimension2D)
    l.maxImageDimension3D = Int32(truncatingIfNeeded: limits.maxImageDimension3D)
    l.maxImageArrayLayers = limits.maxImageArrayLayers
    let sampleSets = limits.framebufferColorSampleCounts & limits.framebufferDepthSampleCounts
    l.maxSamples = SampleCounts(rawValue: sampleSets).maximum
    if l.maxSamples == 0 { l.maxSamples = 1 }
    l.maxAnisotropy = core.samplerAnisotropy != 0 ? limits.maxSamplerAnisotropy : 1
    l.maxLineWidth = core.wideLines != 0 ? limits.lineWidthRange.1 : 1
    l.maxColorAttachments = min(limits.maxColorAttachments, 8)
    l.maxMultiviewViews = unsafe f11.multiview != 0 ? p11.maxMultiviewViewCount : 0
    l.maxPatchControlPoints = core.tessellationShader != 0 ? limits.maxTessellationPatchSize : 0
    l.subgroupSize = unsafe f.subgroupOperations ? p11.subgroupSize : 0
    // The period is in nanoseconds a tick (a float); kept in picoseconds.
    l.timestampPeriodPicoseconds = timestampBits > 0 ? UInt64(limits.timestampPeriod * 1000) : 0

    // Each format's capabilities, from what the device says it can do with it.
    for format in PixelFormat.all {
      var props = VkFormatProperties()
      unsafe c.vkGetPhysicalDeviceFormatProperties!(physical, format.vk, &props)
      let t = props.optimalTilingFeatures
      func has(_ bit: VkFormatFeatureFlagBits) -> Bool { t & bit.rawValue != 0 }
      var caps = FormatCapabilities()
      caps.sampled = has(VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)
      caps.filterable = has(VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT)
      caps.renderTarget = has(VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)
      caps.blendable = has(VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT)
      caps.storage = storageOK && has(VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT)
      caps.storageAtomic = caps.storage && has(VK_FORMAT_FEATURE_STORAGE_IMAGE_ATOMIC_BIT)
      caps.depthTarget = has(VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT)
      caps.blitSource = has(VK_FORMAT_FEATURE_BLIT_SRC_BIT)
      caps.blitDestination = has(VK_FORMAT_FEATURE_BLIT_DST_BIT)
      let b = props.bufferFeatures
      caps.texelBuffer = texelOK && b & VK_FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER_BIT.rawValue != 0
      caps.storageTexelBuffer = texelOK && b & VK_FORMAT_FEATURE_STORAGE_TEXEL_BUFFER_BIT.rawValue != 0
      caps.storageTexelBufferAtomic = caps.storageTexelBuffer && b & VK_FORMAT_FEATURE_STORAGE_TEXEL_BUFFER_ATOMIC_BIT.rawValue != 0
      if !(caps.sampled || caps.renderTarget || caps.storage || caps.depthTarget || caps.blitSource || caps.blitDestination
        || caps.texelBuffer || caps.storageTexelBuffer) { continue }
      let sampledSamples: UInt32
      if format.isDepthStencil {
        sampledSamples = limits.sampledImageDepthSampleCounts
      } else if format.channelClass == .float {
        sampledSamples = limits.sampledImageColorSampleCounts
      } else {
        sampledSamples = limits.sampledImageIntegerSampleCounts
      }
      caps.sampledSamples = SampleCounts(rawValue: sampledSamples | 1)
      caps.renderSamples = SampleCounts(rawValue: (format.channelClass == .float ? limits.framebufferColorSampleCounts
                                                   : limits.framebufferColorSampleCounts & limits.sampledImageIntegerSampleCounts) | 1)
      caps.depthSamples = SampleCounts(rawValue: limits.framebufferDepthSampleCounts | limits.framebufferStencilSampleCounts | 1)
      caps.storageSamples = SampleCounts(rawValue: limits.storageImageSampleCounts | 1)
      l.setFormat(format, caps)
    }
    f.shaderImageAtomics = l.formats(.r32uint).storageAtomic
    for format in PixelFormat.all where l.formats(format).depthTarget {
      if format.hasDepth { f.depth = true }
      if format.hasStencil { f.stencil = true }
    }
    l.features = f
    return l
  }
}
