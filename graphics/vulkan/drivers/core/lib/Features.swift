// SPDX-License-Identifier: BSD-3-Clause

// The device's features and limits as Vulkan words them (D174 amendment, step 5): every flag is `DeviceFeatures`' or
// `DeviceLimits`', and a feature the core's device lacks is reported absent, never emulated. What Vulkan has that the
// core has no word for (sparse resources, 16-bit storage, protected memory...) is absent.

import GPUCore
import TDVulkan

/// `VkPhysicalDeviceFeatures` for a device.
func fillFeatures(_ f: inout VkPhysicalDeviceFeatures, _ gpu: any GPUDevice) {
  let d = gpu.limits.features
  f = VkPhysicalDeviceFeatures()
  func b(_ v: Bool) -> VkBool32 { v ? 1 : 0 }
  f.fullDrawIndexUint32 = b(d.indexedDraw)
  f.imageCubeArray = b(d.cubeImages && d.arrayImages)
  f.independentBlend = b(d.independentBlend)
  f.geometryShader = b(d.geometryShader)
  f.tessellationShader = b(d.tessellation)
  f.sampleRateShading = b(d.sampleShading)
  f.dualSrcBlend = b(d.dualSourceBlend)
  f.logicOp = b(d.logicOps)
  f.multiDrawIndirect = b(d.indirectDraw)
  f.drawIndirectFirstInstance = b(d.indirectDraw)
  f.depthClamp = b(d.depthClamp)
  f.depthBiasClamp = b(d.depthBias)
  f.fillModeNonSolid = b(d.fillModeNonSolid)
  f.depthBounds = b(d.depthBounds)
  f.wideLines = b(d.wideLines)
  f.alphaToOne = b(d.alphaToOne)
  f.samplerAnisotropy = b(d.samplerAnisotropy)
  f.textureCompressionETC2 = b(d.compressedETC2)
  f.textureCompressionASTC_LDR = b(d.compressedASTC)
  f.textureCompressionBC = b(d.compressedBC)
  f.occlusionQueryPrecise = b(d.occlusionQueries)
  f.pipelineStatisticsQuery = b(d.pipelineStatisticsQueries)
  f.fragmentStoresAndAtomics = b(d.shaderAtomic32)
  f.shaderImageGatherExtended = b(d.shaderImageGatherExtended)
  f.shaderStorageImageExtendedFormats = b(d.shaderStorageImageExtendedFormats)
  f.shaderStorageImageReadWithoutFormat = b(d.shaderStorageImageReadWithoutFormat)
  f.shaderStorageImageWriteWithoutFormat = b(d.shaderStorageImageWriteWithoutFormat)
  // The heap's arrays and the set records are indexed at run time, as the lowering reads them.
  f.shaderUniformBufferArrayDynamicIndexing = 1
  f.shaderStorageBufferArrayDynamicIndexing = 1
  f.shaderSampledImageArrayDynamicIndexing = b(d.sampledImages)
  f.shaderStorageImageArrayDynamicIndexing = b(d.storageImages)
  f.shaderClipDistance = b(d.shaderClipDistance)
  f.shaderCullDistance = b(d.shaderCullDistance)
  f.shaderFloat64 = b(d.shaderFloat64)
  f.shaderInt64 = b(d.shaderInt64)
  f.shaderInt16 = b(d.shaderInt16)
  f.shaderResourceMinLod = b(d.shaderMinLod)
}

/// A features structure of a `pNext` chain: its size, and a function that fills it for a device (leaving its type and next
/// alone and every flag it has no feature for clear).
@unsafe struct FeatureStructure {
  var size: Int
  var fill: (UnsafeMutableRawPointer, DeviceFeatures) -> Void
}

private func b32(_ v: Bool) -> VkBool32 { v ? 1 : 0 }

@unsafe func featureStructure(_ type: VkStructureType) -> FeatureStructure? {
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceVulkan11Features>.size) { q, d in
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceVulkan11Features.self)
      unsafe s.pointee.multiview = b32(d.multiview)
      unsafe s.pointee.shaderDrawParameters = b32(d.shaderDrawParameters)
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceVulkan12Features>.size) { q, d in
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceVulkan12Features.self)
      unsafe s.pointee.bufferDeviceAddress = 1
      unsafe s.pointee.timelineSemaphore = 1
      unsafe s.pointee.drawIndirectCount = b32(d.drawIndirectCount)
      unsafe s.pointee.samplerMirrorClampToEdge = b32(d.samplerMirrorClampToEdge)
      unsafe s.pointee.shaderFloat16 = b32(d.shaderFloat16)
      unsafe s.pointee.shaderInt8 = b32(d.shaderInt8)
      unsafe s.pointee.shaderBufferInt64Atomics = b32(d.shaderAtomic64)
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceVulkan13Features>.size) { q, d in
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceVulkan13Features.self)
      unsafe s.pointee.dynamicRendering = 1
      unsafe s.pointee.synchronization2 = 1
      unsafe s.pointee.shaderDemoteToHelperInvocation = b32(d.shaderDemoteToHelperInvocation)
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceBufferDeviceAddressFeatures>.size) { q, _ in
      unsafe q.assumingMemoryBound(to: VkPhysicalDeviceBufferDeviceAddressFeatures.self).pointee.bufferDeviceAddress = 1
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceTimelineSemaphoreFeatures>.size) { q, _ in
      unsafe q.assumingMemoryBound(to: VkPhysicalDeviceTimelineSemaphoreFeatures.self).pointee.timelineSemaphore = 1
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceDynamicRenderingFeatures>.size) { q, _ in
      unsafe q.assumingMemoryBound(to: VkPhysicalDeviceDynamicRenderingFeatures.self).pointee.dynamicRendering = 1
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceSynchronization2Features>.size) { q, _ in
      unsafe q.assumingMemoryBound(to: VkPhysicalDeviceSynchronization2Features.self).pointee.synchronization2 = 1
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceMultiviewFeatures>.size) { q, d in
      unsafe q.assumingMemoryBound(to: VkPhysicalDeviceMultiviewFeatures.self).pointee.multiview = b32(d.multiview)
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceShaderDrawParametersFeatures>.size) { q, d in
      unsafe q.assumingMemoryBound(to: VkPhysicalDeviceShaderDrawParametersFeatures.self).pointee.shaderDrawParameters =
        b32(d.shaderDrawParameters)
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceShaderFloat16Int8Features>.size) { q, d in
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceShaderFloat16Int8Features.self)
      unsafe s.pointee.shaderFloat16 = b32(d.shaderFloat16)
      unsafe s.pointee.shaderInt8 = b32(d.shaderInt8)
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DEMOTE_TO_HELPER_INVOCATION_FEATURES {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceShaderDemoteToHelperInvocationFeatures>.size) { q, d in
      unsafe q.assumingMemoryBound(to: VkPhysicalDeviceShaderDemoteToHelperInvocationFeatures.self).pointee
        .shaderDemoteToHelperInvocation = b32(d.shaderDemoteToHelperInvocation)
    }
  }
  if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT {
    return unsafe FeatureStructure(size: MemoryLayout<VkPhysicalDeviceDescriptorBufferFeaturesEXT>.size) { q, _ in
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceDescriptorBufferFeaturesEXT.self)
      unsafe s.pointee.descriptorBuffer = 1
      unsafe s.pointee.descriptorBufferImageLayoutIgnored = 1
    }
  }
  return nil
}

/// Fills the features structure at `q` (of the type it says): every flag clear but the ones the device has.
func fillFeatureStructure(_ q: UnsafeMutableRawPointer, _ gpu: any GPUDevice) {
  guard let s = unsafe featureStructure(unsafe chainType(q)) else { return }
  // Past the type and the next pointer, all flags: cleared, then set from the device.
  unsafe (q + 16).initializeMemory(as: UInt8.self, repeating: 0, count: s.size - 16)
  unsafe s.fill(q, gpu.limits.features)
}

/// Whether the features structure at `q` asks for nothing the device lacks.
func featureStructureWithin(_ q: UnsafeMutableRawPointer, _ gpu: any GPUDevice) -> Bool {
  guard let s = unsafe featureStructure(unsafe chainType(q)) else { return true }
  let have = unsafe UnsafeMutableRawPointer.allocate(byteCount: s.size, alignment: 16)
  defer { unsafe have.deallocate() }
  unsafe have.copyMemory(from: q, byteCount: 16)
  unsafe (have + 16).initializeMemory(as: UInt8.self, repeating: 0, count: s.size - 16)
  unsafe s.fill(have, gpu.limits.features)
  var at = 16
  let size = unsafe s.size
  while at + 4 <= size {
    if unsafe q.load(fromByteOffset: at, as: UInt32.self) != 0 && have.load(fromByteOffset: at, as: UInt32.self) == 0 { return false }
    at += 4
  }
  return true
}

// MARK: Properties

/// The sample counts up to `most` (a power of two), as Vulkan's flag bits.
func sampleCountMask(_ most: UInt32) -> UInt32 { most <= 1 ? 1 : (most << 1) - 1 }

/// What the device's limits give of `VkPhysicalDeviceLimits`, past what the layer fixes itself.
func fillDeviceLimits(_ m: inout VkPhysicalDeviceLimits, _ l: DeviceLimits) {
  let f = l.features
  let dim = UInt32(max(l.maxImageDimension, 1))
  m.maxImageDimension1D = dim
  m.maxImageDimension2D = dim
  m.maxImageDimension3D = f.volumeImages ? UInt32(max(l.maxImageDimension3D > 0 ? l.maxImageDimension3D : l.maxImageDimension, 1)) : 1
  m.maxImageDimensionCube = f.cubeImages ? dim : 1
  m.maxImageArrayLayers = f.arrayImages ? max(l.maxImageArrayLayers, 1) : 1
  m.maxSamplerAnisotropy = f.samplerAnisotropy ? max(l.maxAnisotropy, 1) : 1
  let samples = f.multisample ? sampleCountMask(l.maxSamples) : 1
  m.framebufferColorSampleCounts = samples
  m.framebufferDepthSampleCounts = f.depth || f.stencil ? samples : 1
  m.framebufferStencilSampleCounts = f.stencil ? samples : 1
  m.framebufferNoAttachmentsSampleCounts = samples
  m.sampledImageColorSampleCounts = samples
  m.sampledImageIntegerSampleCounts = samples
  m.sampledImageDepthSampleCounts = f.depth ? samples : 1
  m.sampledImageStencilSampleCounts = f.stencil ? samples : 1
  m.storageImageSampleCounts = samples
  m.maxColorAttachments = max(f.multipleColorAttachments ? l.maxColorAttachments : 1, 1)
  m.maxFragmentOutputAttachments = m.maxColorAttachments
  m.maxFragmentDualSrcAttachments = f.dualSourceBlend ? 1 : 0
  m.maxFramebufferLayers = m.maxImageArrayLayers
  m.maxFramebufferWidth = dim
  m.maxFramebufferHeight = dim
  m.lineWidthRange = (1, f.wideLines ? max(l.maxLineWidth, 1) : 1)
  m.lineWidthGranularity = f.wideLines ? 0.125 : 0
  m.maxTessellationPatchSize = f.tessellation ? l.maxPatchControlPoints : 0
  m.maxDrawIndirectCount = f.indirectDraw ? 1 << 20 : 1
  m.maxSamplerAllocationCount = l.heapSamplers
  m.timestampComputeAndGraphics = f.timestampQueries ? 1 : 0
  m.timestampPeriod = Float(l.timestampPeriodPicoseconds) / 1000
  m.maxSamplerLodBias = 15
}

func fillSubgroupProperties(_ size: inout UInt32, _ stages: inout UInt32, _ ops: inout UInt32, _ l: DeviceLimits) {
  size = l.subgroupSize
  guard l.features.subgroupOperations else {
    stages = 0
    ops = 0
    return
  }
  stages = VK_SHADER_STAGE_COMPUTE_BIT.rawValue | VK_SHADER_STAGE_FRAGMENT_BIT.rawValue
  // Basic, vote, arithmetic, ballot, shuffle and quad.
  ops = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x80
}

/// The structures of a `pNext` chain of properties that the device fills.
func fillPropertyStructures(_ chain: UnsafeMutableRawPointer?, _ l: DeviceLimits) {
  var next = unsafe chain
  while let q = unsafe next {
    let type = unsafe chainType(q)
    let following = unsafe chainNext(q)
    if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT {
      unsafe fillDescriptorBufferProperties(&q.assumingMemoryBound(to: VkPhysicalDeviceDescriptorBufferPropertiesEXT.self).pointee)
    } else if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES {
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceSubgroupProperties.self)
      var size: UInt32 = 0
      var stages: UInt32 = 0
      var ops: UInt32 = 0
      fillSubgroupProperties(&size, &stages, &ops, l)
      unsafe s.pointee.subgroupSize = size
      unsafe s.pointee.supportedStages = VkShaderStageFlags(stages)
      unsafe s.pointee.supportedOperations = VkSubgroupFeatureFlags(ops)
      unsafe s.pointee.quadOperationsInAllStages = 0
    } else if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_PROPERTIES {
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceMultiviewProperties.self)
      unsafe s.pointee.maxMultiviewViewCount = l.features.multiview ? l.maxMultiviewViews : 0
      unsafe s.pointee.maxMultiviewInstanceIndex = l.features.multiview ? 0x7FFF_FFFF : 0
    } else if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES {
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceVulkan11Properties.self)
      var size: UInt32 = 0
      var stages: UInt32 = 0
      var ops: UInt32 = 0
      fillSubgroupProperties(&size, &stages, &ops, l)
      unsafe s.pointee.subgroupSize = size
      unsafe s.pointee.subgroupSupportedStages = VkShaderStageFlags(stages)
      unsafe s.pointee.subgroupSupportedOperations = VkSubgroupFeatureFlags(ops)
      unsafe s.pointee.maxMultiviewViewCount = l.features.multiview ? l.maxMultiviewViews : 0
      unsafe s.pointee.maxMultiviewInstanceIndex = l.features.multiview ? 0x7FFF_FFFF : 0
      unsafe s.pointee.maxMemoryAllocationSize = 1 << 30
    }
    unsafe next = following
  }
}

// MARK: Formats and images

func formatProperties(_ format: VkFormat, _ l: DeviceLimits) -> VkFormatProperties {
  var f = VkFormatProperties()
  if let px = pixelFormat(format) {
    let bits = formatFeatureBits(px, l)
    f.optimalTilingFeatures = VkFormatFeatureFlags(bits)
    f.linearTilingFeatures = VkFormatFeatureFlags(bits)
  }
  return f
}

/// What an image of the format, type, usage and flags may be on the device, or nil where none can be made.
func imageFormatProperties(_ format: VkFormat, _ type: VkImageType, _ usage: UInt32, _ flags: UInt32, _ l: DeviceLimits)
  -> VkImageFormatProperties?
{
  guard let px = pixelFormat(format) else { return nil }
  let f = l.features
  var listed = false
  for e in l.formatTable where e.format == px { listed = true }
  guard listed else { return nil }
  let c = l.formats(px)
  // Flags: cube and mutable-format images only.
  let known = VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue | VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue
  if flags & ~known != 0 { return nil }
  if flags & VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue != 0 && !(f.cubeImages && type == VK_IMAGE_TYPE_2D) { return nil }
  if flags & VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue != 0 && !f.imageViews { return nil }
  var dimension3 = false
  if type == VK_IMAGE_TYPE_2D {
  } else if type == VK_IMAGE_TYPE_3D {
    guard f.volumeImages else { return nil }
    dimension3 = true
  } else { return nil }
  // The usage the format allows, and the sample counts it allows all of them at.
  var samples: UInt32 = 0x7F
  var any = false
  if usage & VK_IMAGE_USAGE_SAMPLED_BIT.rawValue != 0 {
    guard c.sampled && f.sampledImages else { return nil }
    samples &= c.sampledSamples.rawValue
    any = true
  }
  if usage & VK_IMAGE_USAGE_STORAGE_BIT.rawValue != 0 {
    guard c.storage && f.storageImages else { return nil }
    samples &= c.storageSamples.rawValue
    any = true
  }
  if usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue != 0 {
    guard c.renderTarget else { return nil }
    samples &= c.renderSamples.rawValue
    any = true
  }
  if usage & VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue != 0 {
    guard c.depthTarget else { return nil }
    samples &= c.depthSamples.rawValue
    any = true
  }
  if usage & VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT.rawValue != 0 { return nil }
  if !any { samples = 1 }
  if !f.multisample || dimension3 { samples = 1 }
  if px.isCompressed { samples = 1 }
  samples &= sampleCountMask(l.maxSamples)
  if samples == 0 { samples = 1 }
  let dim = UInt32(max(l.maxImageDimension, 1))
  let dim3 = UInt32(max(l.maxImageDimension3D > 0 ? l.maxImageDimension3D : l.maxImageDimension, 1))
  let extent = dimension3 ? VkExtent3D(width: dim3, height: dim3, depth: dim3) : VkExtent3D(width: dim, height: dim, depth: 1)
  var mips: UInt32 = 1
  if f.mipmaps { mips = UInt32(32 - max(dimension3 ? dim3 : dim, 1).leadingZeroBitCount) }
  let layers: UInt32 = dimension3 ? 1 : (f.arrayImages ? max(l.maxImageArrayLayers, 1) : (f.cubeImages ? 6 : 1))
  let texel = UInt64(max(px.texelBlock.bytes, 1))
  return VkImageFormatProperties(maxExtent: extent, maxMipLevels: mips, maxArrayLayers: layers, sampleCounts: samples,
                                 maxResourceSize: UInt64(extent.width) * UInt64(extent.height) * UInt64(extent.depth) * UInt64(layers) * texel)
}
