// SPDX-License-Identifier: BSD-3-Clause

// Instance, physical device, device and queue (D174 step 5, part 3): one physical device per core device, Vulkan
// 1.3, one queue family that draws, computes and copies, limits taken from `DeviceLimits`.

import GPUCore
import TDVulkan
import VulkanLowering

let layerApiVersion: UInt32 = 1 << 22 | 3 << 12 | 0

func core_vkEnumerateInstanceVersion(_ pApiVersion: UnsafeMutablePointer<UInt32>?) -> VkResult {
  unsafe pApiVersion?.pointee = layerApiVersion
  return VK_SUCCESS
}

func core_vkEnumerateInstanceExtensionProperties(_ pLayerName: UnsafePointer<CChar>?,
                                                 _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                                 _ pProperties: UnsafeMutablePointer<VkExtensionProperties>?) -> VkResult
{
  if unsafe pLayerName != nil { return VK_ERROR_LAYER_NOT_PRESENT }
  unsafe pPropertyCount?.pointee = 0
  return VK_SUCCESS
}

func core_vkEnumerateInstanceLayerProperties(_ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                             _ pProperties: UnsafeMutablePointer<VkLayerProperties>?) -> VkResult
{
  unsafe pPropertyCount?.pointee = 0
  return VK_SUCCESS
}

func core_vkEnumerateDeviceLayerProperties(_ physicalDevice: VkPhysicalDevice?, _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                           _ pProperties: UnsafeMutablePointer<VkLayerProperties>?) -> VkResult
{
  unsafe pPropertyCount?.pointee = 0
  return VK_SUCCESS
}

func core_vkEnumerateDeviceExtensionProperties(_ physicalDevice: VkPhysicalDevice?, _ pLayerName: UnsafePointer<CChar>?,
                                               _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                               _ pProperties: UnsafeMutablePointer<VkExtensionProperties>?) -> VkResult
{
  if unsafe pLayerName != nil { return VK_ERROR_LAYER_NOT_PRESENT }
  guard let count = unsafe pPropertyCount else { return VK_SUCCESS }
  guard let out = unsafe pProperties else {
    unsafe count.pointee = UInt32(deviceExtensions.count)
    return VK_SUCCESS
  }
  let n = min(Int(unsafe count.pointee), deviceExtensions.count)
  for i in 0..<n {
    var e = VkExtensionProperties()
    e.specVersion = deviceExtensions[i].version
    unsafe withUnsafeMutableBytes(of: &e.extensionName) { raw in
      var k = 0
      for b in deviceExtensions[i].name.utf8 where k < 255 {
        unsafe raw[k] = b
        k += 1
      }
    }
    unsafe out[i] = e
  }
  unsafe count.pointee = UInt32(n)
  return n < deviceExtensions.count ? VK_INCOMPLETE : VK_SUCCESS
}

/// The device extensions the layer has: VK_EXT_descriptor_buffer (D174 section 4).
let deviceExtensions: [(name: String, version: UInt32)] = [("VK_EXT_descriptor_buffer", 1)]

func core_vkCreateInstance(_ pCreateInfo: UnsafePointer<VkInstanceCreateInfo>?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                           _ pInstance: UnsafeMutablePointer<VkInstance?>?) -> VkResult
{
  guard let pInstance = unsafe pInstance, let info = unsafe pCreateInfo else { return VK_ERROR_INITIALIZATION_FAILED }
  // The layer has no instance extensions.
  if unsafe info.pointee.enabledExtensionCount > 0 { return VK_ERROR_EXTENSION_NOT_PRESENT }
  guard let make = unsafe CoreDriver.device else { return VK_ERROR_INCOMPATIBLE_DRIVER }
  let gpu: any GPUDevice
  do throws(GPUError) { gpu = try make() } catch { return VK_ERROR_INCOMPATIBLE_DRIVER }
  let instance = InstanceObject(gpu: gpu)
  unsafe instance.physicalHandle = unsafe Handle.make(PhysicalDeviceObject(gpu: gpu), dispatchable: true)
  unsafe pInstance.pointee = Handle.make(instance, dispatchable: true)
  return VK_SUCCESS
}

func core_vkDestroyInstance(_ instance: VkInstance?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let i = unsafe Handle.get(instance, InstanceObject.self) else { return }
  unsafe Handle.destroy(i.physicalHandle)
  unsafe i.physicalHandle = nil
  unsafe Handle.destroy(instance)
}

func core_vkEnumeratePhysicalDevices(_ instance: VkInstance?, _ pPhysicalDeviceCount: UnsafeMutablePointer<UInt32>?,
                                     _ pPhysicalDevices: UnsafeMutablePointer<VkPhysicalDevice?>?) -> VkResult
{
  guard let i = unsafe Handle.get(instance, InstanceObject.self), let pCount = unsafe pPhysicalDeviceCount else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  guard let out = unsafe pPhysicalDevices else {
    unsafe pCount.pointee = 1
    return VK_SUCCESS
  }
  if unsafe pCount.pointee == 0 { return VK_INCOMPLETE }
  unsafe out[0] = i.physicalHandle
  unsafe pCount.pointee = 1
  return VK_SUCCESS
}

// MARK: Properties

func fillProperties(_ gpu: any GPUDevice, _ p: inout VkPhysicalDeviceProperties) {
  let l = gpu.limits
  p = VkPhysicalDeviceProperties()
  p.apiVersion = layerApiVersion
  p.driverVersion = 1
  p.deviceType = VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
  unsafe withUnsafeMutableBytes(of: &p.deviceName) { raw in
    var i = 0
    for b in gpu.name.utf8 where i < 255 {
      unsafe raw[i] = b
      i += 1
    }
  }
  var m = VkPhysicalDeviceLimits()
  let dim = UInt32(max(l.maxImageDimension, 1))
  m.maxImageDimension1D = dim
  m.maxImageDimension2D = dim
  m.maxImageDimension3D = 1
  m.maxImageDimensionCube = 1
  m.maxImageArrayLayers = 1
  m.maxUniformBufferRange = 1 << 16
  m.maxStorageBufferRange = 1 << 30
  m.maxPushConstantsSize = 128
  m.maxMemoryAllocationCount = 4096
  m.maxSamplerAllocationCount = l.heapSamplers
  m.bufferImageGranularity = 1
  m.maxBoundDescriptorSets = 4
  m.maxPerStageDescriptorSamplers = l.heapSamplers
  m.maxPerStageDescriptorUniformBuffers = 1 << 12
  m.maxPerStageDescriptorStorageBuffers = 1 << 12
  m.maxPerStageDescriptorSampledImages = l.heapTextures
  m.maxPerStageDescriptorInputAttachments = l.heapTextures
  m.maxPerStageDescriptorStorageImages = l.heapStorageImages
  m.maxPerStageResources = 1 << 16
  m.maxDescriptorSetSamplers = l.heapSamplers
  m.maxDescriptorSetUniformBuffers = 1 << 12
  m.maxDescriptorSetUniformBuffersDynamic = 8
  m.maxDescriptorSetStorageBuffersDynamic = 4
  m.maxDescriptorSetStorageBuffers = 1 << 12
  m.maxDescriptorSetSampledImages = l.heapTextures
  m.maxDescriptorSetInputAttachments = l.heapTextures
  m.maxDescriptorSetStorageImages = l.heapStorageImages
  m.maxVertexInputAttributes = 16
  m.maxVertexInputBindings = UInt32(RootBlockLimits.vertexBuffers)
  m.maxVertexInputAttributeOffset = 2047
  m.maxVertexInputBindingStride = 2048
  m.maxVertexOutputComponents = 64
  m.maxFragmentInputComponents = 64
  m.maxFragmentOutputAttachments = 8
  m.maxFragmentCombinedOutputResources = 16
  m.maxComputeSharedMemorySize = 16384
  m.maxComputeWorkGroupCount = (65535, 65535, 65535)
  m.maxComputeWorkGroupInvocations = 256
  m.maxComputeWorkGroupSize = (256, 256, 64)
  m.subPixelPrecisionBits = 4
  m.subTexelPrecisionBits = 4
  m.mipmapPrecisionBits = 4
  m.maxDrawIndexedIndexValue = ~0
  m.maxDrawIndirectCount = 1
  m.maxSamplerLodBias = 4
  m.maxSamplerAnisotropy = 1
  m.maxViewports = 1
  m.maxViewportDimensions = (dim, dim)
  m.viewportBoundsRange = (-Float(dim) * 2, Float(dim) * 2)
  m.viewportSubPixelBits = 0
  m.minMemoryMapAlignment = 64
  m.minTexelBufferOffsetAlignment = 16
  m.minUniformBufferOffsetAlignment = 64
  m.minStorageBufferOffsetAlignment = 16
  m.minTexelOffset = -8
  m.maxTexelOffset = 7
  m.maxFramebufferWidth = dim
  m.maxFramebufferHeight = dim
  m.maxFramebufferLayers = 1
  m.framebufferColorSampleCounts = 1
  m.framebufferNoAttachmentsSampleCounts = 1
  m.maxColorAttachments = 8
  m.sampledImageColorSampleCounts = 1
  m.sampledImageIntegerSampleCounts = 1
  m.storageImageSampleCounts = 1
  m.maxSampleMaskWords = 1
  m.timestampComputeAndGraphics = l.features.timestampQueries ? 1 : 0
  m.timestampPeriod = Float(l.timestampPeriodPicoseconds) / 1000
  m.discreteQueuePriorities = 1
  m.pointSizeRange = (1, 1)
  m.lineWidthRange = (1, 1)
  m.optimalBufferCopyOffsetAlignment = 4
  m.optimalBufferCopyRowPitchAlignment = 4
  m.nonCoherentAtomSize = 64
  fillDeviceLimits(&m, l)
  p.limits = m
}

/// The numbers of the root block the limits state (RootBlock's, as plain integers).
enum RootBlockLimits {
  static let vertexBuffers = 8
}

func core_vkGetPhysicalDeviceProperties(_ physicalDevice: VkPhysicalDevice?,
                                        _ pProperties: UnsafeMutablePointer<VkPhysicalDeviceProperties>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let p = unsafe pProperties else { return }
  unsafe fillProperties(d.gpu, &p.pointee)
}

/// A structure of a `pNext` chain: its type and the next.
func chainNext(_ p: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  let b = unsafe p.assumingMemoryBound(to: VkBaseOutStructure.self)
  return unsafe UnsafeMutableRawPointer(b.pointee.pNext)
}

func chainType(_ p: UnsafeMutableRawPointer) -> VkStructureType {
  unsafe p.assumingMemoryBound(to: VkBaseOutStructure.self).pointee.sType
}

func core_vkGetPhysicalDeviceProperties2(_ physicalDevice: VkPhysicalDevice?,
                                         _ pProperties: UnsafeMutablePointer<VkPhysicalDeviceProperties2>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let p = unsafe pProperties else { return }
  unsafe fillProperties(d.gpu, &p.pointee.properties)
  unsafe fillPropertyStructures(UnsafeMutableRawPointer(p.pointee.pNext), d.gpu.limits)
}

/// VK_EXT_descriptor_buffer's properties: every descriptor is 16 bytes (DescriptorKind), a set record is its descriptor
/// buffer, and the root block holds the set addresses, so a buffer's offset is the set's address.
func fillDescriptorBufferProperties(_ s: inout VkPhysicalDeviceDescriptorBufferPropertiesEXT) {
  let type = unsafe s.sType
  let next = unsafe s.pNext
  unsafe s = VkPhysicalDeviceDescriptorBufferPropertiesEXT()
  unsafe s.sType = type
  unsafe s.pNext = next
  unsafe s.combinedImageSamplerDescriptorSingleArray = 1
  unsafe s.descriptorBufferOffsetAlignment = VkDeviceSize(descriptorBufferOffsetAlignment)
  unsafe s.maxDescriptorBufferBindings = UInt32(maxDescriptorBuffers)
  unsafe s.maxResourceDescriptorBufferBindings = UInt32(maxDescriptorBuffers)
  unsafe s.maxSamplerDescriptorBufferBindings = UInt32(maxDescriptorBuffers)
  unsafe s.samplerDescriptorSize = descriptorSize
  unsafe s.combinedImageSamplerDescriptorSize = descriptorSize
  unsafe s.sampledImageDescriptorSize = descriptorSize
  unsafe s.storageImageDescriptorSize = descriptorSize
  unsafe s.uniformBufferDescriptorSize = descriptorSize
  unsafe s.robustUniformBufferDescriptorSize = descriptorSize
  unsafe s.storageBufferDescriptorSize = descriptorSize
  unsafe s.robustStorageBufferDescriptorSize = descriptorSize
  unsafe s.maxSamplerDescriptorBufferRange = 1 << 30
  unsafe s.maxResourceDescriptorBufferRange = 1 << 30
  unsafe s.samplerDescriptorBufferAddressSpaceSize = 1 << 30
  unsafe s.resourceDescriptorBufferAddressSpaceSize = 1 << 30
  unsafe s.descriptorBufferAddressSpaceSize = 1 << 30
}

func core_vkGetPhysicalDeviceFeatures(_ physicalDevice: VkPhysicalDevice?,
                                      _ pFeatures: UnsafeMutablePointer<VkPhysicalDeviceFeatures>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let p = unsafe pFeatures else { return }
  unsafe fillFeatures(&p.pointee, d.gpu)
}

func core_vkGetPhysicalDeviceFeatures2(_ physicalDevice: VkPhysicalDevice?,
                                       _ pFeatures: UnsafeMutablePointer<VkPhysicalDeviceFeatures2>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let p = unsafe pFeatures else { return }
  unsafe fillFeatures(&p.pointee.features, d.gpu)
  var next = unsafe UnsafeMutableRawPointer(p.pointee.pNext)
  while let q = unsafe next {
    let following = unsafe chainNext(q)
    unsafe fillFeatureStructure(q, d.gpu)
    unsafe next = following
  }
}

func fillQueueFamily(_ p: inout VkQueueFamilyProperties, _ gpu: any GPUDevice) {
  p = VkQueueFamilyProperties()
  p.queueFlags = VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue | VK_QUEUE_COMPUTE_BIT.rawValue | VK_QUEUE_TRANSFER_BIT.rawValue)
  p.queueCount = 1
  p.timestampValidBits = gpu.limits.features.timestampQueries ? 64 : 0
  p.minImageTransferGranularity = VkExtent3D(width: 1, height: 1, depth: 1)
}

func core_vkGetPhysicalDeviceQueueFamilyProperties(_ physicalDevice: VkPhysicalDevice?,
                                                   _ pQueueFamilyPropertyCount: UnsafeMutablePointer<UInt32>?,
                                                   _ pQueueFamilyProperties: UnsafeMutablePointer<VkQueueFamilyProperties>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let pCount = unsafe pQueueFamilyPropertyCount else { return }
  guard let out = unsafe pQueueFamilyProperties else {
    unsafe pCount.pointee = 1
    return
  }
  if unsafe pCount.pointee >= 1 { unsafe fillQueueFamily(&out[0], d.gpu) }
  unsafe pCount.pointee = min(unsafe pCount.pointee, 1)
}

func core_vkGetPhysicalDeviceQueueFamilyProperties2(_ physicalDevice: VkPhysicalDevice?,
                                                    _ pQueueFamilyPropertyCount: UnsafeMutablePointer<UInt32>?,
                                                    _ pQueueFamilyProperties: UnsafeMutablePointer<VkQueueFamilyProperties2>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let pCount = unsafe pQueueFamilyPropertyCount else { return }
  guard let out = unsafe pQueueFamilyProperties else {
    unsafe pCount.pointee = 1
    return
  }
  if unsafe pCount.pointee >= 1 { unsafe fillQueueFamily(&out[0].queueFamilyProperties, d.gpu) }
  unsafe pCount.pointee = min(unsafe pCount.pointee, 1)
}

/// The three memory types, one per intent (D174 step 5): 0 device-local, 1 host-visible and coherent, 2 also cached.
enum MemoryTypes {
  static let device: UInt32 = 0
  static let upload: UInt32 = 1
  static let readback: UInt32 = 2
  static let allBits: UInt32 = 7

  static func intent(_ type: UInt32) -> MemoryIntent? {
    switch type {
    case device: .device
    case upload: .upload
    case readback: .readback
    default: nil
    }
  }
}

func fillMemoryProperties(_ m: inout VkPhysicalDeviceMemoryProperties) {
  m = VkPhysicalDeviceMemoryProperties()
  m.memoryHeapCount = 1
  let local = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue
  let visible = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
  unsafe withUnsafeMutableBytes(of: &m.memoryHeaps) { raw in
    let heaps = unsafe raw.baseAddress!.assumingMemoryBound(to: VkMemoryHeap.self)
    unsafe heaps[0] = VkMemoryHeap(size: 1 << 32, flags: VkMemoryHeapFlags(VK_MEMORY_HEAP_DEVICE_LOCAL_BIT.rawValue))
  }
  m.memoryTypeCount = 3
  unsafe withUnsafeMutableBytes(of: &m.memoryTypes) { raw in
    let types = unsafe raw.baseAddress!.assumingMemoryBound(to: VkMemoryType.self)
    unsafe types[0] = VkMemoryType(propertyFlags: VkMemoryPropertyFlags(local), heapIndex: 0)
    unsafe types[1] = VkMemoryType(propertyFlags: VkMemoryPropertyFlags(local | visible), heapIndex: 0)
    unsafe types[2] = VkMemoryType(propertyFlags: VkMemoryPropertyFlags(local | visible | VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue),
                                   heapIndex: 0)
  }
}

func core_vkGetPhysicalDeviceMemoryProperties(_ physicalDevice: VkPhysicalDevice?,
                                              _ pMemoryProperties: UnsafeMutablePointer<VkPhysicalDeviceMemoryProperties>?)
{
  guard let p = unsafe pMemoryProperties else { return }
  unsafe fillMemoryProperties(&p.pointee)
}

func core_vkGetPhysicalDeviceMemoryProperties2(_ physicalDevice: VkPhysicalDevice?,
                                               _ pMemoryProperties: UnsafeMutablePointer<VkPhysicalDeviceMemoryProperties2>?)
{
  guard let p = unsafe pMemoryProperties else { return }
  unsafe fillMemoryProperties(&p.pointee.memoryProperties)
}

// MARK: Formats

func core_vkGetPhysicalDeviceFormatProperties(_ physicalDevice: VkPhysicalDevice?, _ format: VkFormat,
                                              _ pFormatProperties: UnsafeMutablePointer<VkFormatProperties>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let p = unsafe pFormatProperties else { return }
  unsafe p.pointee = formatProperties(format, d.gpu.limits)
}

func core_vkGetPhysicalDeviceFormatProperties2(_ physicalDevice: VkPhysicalDevice?, _ format: VkFormat,
                                               _ pFormatProperties: UnsafeMutablePointer<VkFormatProperties2>?)
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let p = unsafe pFormatProperties else { return }
  unsafe p.pointee.formatProperties = formatProperties(format, d.gpu.limits)
}

func core_vkGetPhysicalDeviceImageFormatProperties(_ physicalDevice: VkPhysicalDevice?, _ format: VkFormat, _ type: VkImageType,
                                                   _ tiling: VkImageTiling, _ usage: VkImageUsageFlags,
                                                   _ flags: VkImageCreateFlags,
                                                   _ pImageFormatProperties: UnsafeMutablePointer<VkImageFormatProperties>?) -> VkResult
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let p = unsafe pImageFormatProperties else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  guard let props = imageFormatProperties(format, type, usage, flags, d.gpu.limits) else { return VK_ERROR_FORMAT_NOT_SUPPORTED }
  unsafe p.pointee = props
  return VK_SUCCESS
}

func core_vkGetPhysicalDeviceImageFormatProperties2(_ physicalDevice: VkPhysicalDevice?,
                                                    _ pImageFormatInfo: UnsafePointer<VkPhysicalDeviceImageFormatInfo2>?,
                                                    _ pImageFormatProperties: UnsafeMutablePointer<VkImageFormatProperties2>?) -> VkResult
{
  guard let d = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let i = unsafe pImageFormatInfo,
    let p = unsafe pImageFormatProperties
  else { return VK_ERROR_INITIALIZATION_FAILED }
  guard let props = unsafe imageFormatProperties(i.pointee.format, i.pointee.type, i.pointee.usage, i.pointee.flags, d.gpu.limits)
  else { return VK_ERROR_FORMAT_NOT_SUPPORTED }
  unsafe p.pointee.imageFormatProperties = props
  return VK_SUCCESS
}

func core_vkGetPhysicalDeviceSparseImageFormatProperties(_ physicalDevice: VkPhysicalDevice?, _ format: VkFormat, _ type: VkImageType,
                                                         _ samples: VkSampleCountFlagBits, _ usage: VkImageUsageFlags,
                                                         _ tiling: VkImageTiling, _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                                         _ pProperties: UnsafeMutablePointer<VkSparseImageFormatProperties>?)
{
  unsafe pPropertyCount?.pointee = 0
}

// MARK: Device and queue

func core_vkCreateDevice(_ physicalDevice: VkPhysicalDevice?, _ pCreateInfo: UnsafePointer<VkDeviceCreateInfo>?,
                         _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pDevice: UnsafeMutablePointer<VkDevice?>?) -> VkResult
{
  guard let phys = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self), let info = unsafe pCreateInfo,
    let pDevice = unsafe pDevice
  else { return VK_ERROR_INITIALIZATION_FAILED }
  for i in 0..<Int(unsafe info.pointee.enabledExtensionCount) {
    guard let name = unsafe info.pointee.ppEnabledExtensionNames[i], unsafe deviceExtensions.contains(where: { unsafe $0.name == String(cString: name) }) else {
      return VK_ERROR_EXTENSION_NOT_PRESENT
    }
  }
  // One queue family, one queue.
  for i in 0..<Int(unsafe info.pointee.queueCreateInfoCount) {
    let q = unsafe info.pointee.pQueueCreateInfos[i]
    if unsafe q.queueFamilyIndex != 0 || q.queueCount > 1 { return VK_ERROR_INITIALIZATION_FAILED }
  }
  // What it is asked to enable must be what it has.
  if let enabled = unsafe info.pointee.pEnabledFeatures {
    var have = VkPhysicalDeviceFeatures()
    fillFeatures(&have, phys.gpu)
    let n = MemoryLayout<VkPhysicalDeviceFeatures>.size / MemoryLayout<VkBool32>.size
    let bad = unsafe withUnsafeBytes(of: have) { h in
      unsafe withUnsafeBytes(of: enabled.pointee) { e in
        for i in 0..<n {
          let a = unsafe e.load(fromByteOffset: i * 4, as: UInt32.self)
          let b = unsafe h.load(fromByteOffset: i * 4, as: UInt32.self)
          if a != 0 && b == 0 { return true }
        }
        return false
      }
    }
    if bad { return VK_ERROR_FEATURE_NOT_PRESENT }
  }
  var next = unsafe UnsafeMutableRawPointer(mutating: info.pointee.pNext)
  while let q = unsafe next {
    let type = unsafe chainType(q)
    if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 {
      var have = VkPhysicalDeviceFeatures()
      fillFeatures(&have, phys.gpu)
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceFeatures2.self).pointee.features
      if !featuresWithin(s, have) { return VK_ERROR_FEATURE_NOT_PRESENT }
    } else if type == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT {
      let s = unsafe q.assumingMemoryBound(to: VkPhysicalDeviceDescriptorBufferFeaturesEXT.self).pointee
      if unsafe s.descriptorBufferCaptureReplay != 0 || s.descriptorBufferPushDescriptors != 0 { return VK_ERROR_FEATURE_NOT_PRESENT }
    } else if unsafe !featureStructureWithin(q, phys.gpu) {
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    unsafe next = unsafe chainNext(q)
  }
  let device = DeviceObject(gpu: phys.gpu)
  unsafe device.queueHandle = unsafe Handle.make(QueueObject(device: device), dispatchable: true)
  unsafe pDevice.pointee = Handle.make(device, dispatchable: true)
  return VK_SUCCESS
}

/// Whether every VkBool32 of `asked` (a features structure, after its type and next) that is set is set in `have`.
func featuresWithin<T>(_ asked: T, _ have: T) -> Bool {
  let skip = T.self == VkPhysicalDeviceFeatures.self ? 0 : 16
  let size = MemoryLayout<T>.size
  return unsafe withUnsafeBytes(of: asked) { a in
    unsafe withUnsafeBytes(of: have) { h in
      var at = skip
      while at + 4 <= size {
        if unsafe a.load(fromByteOffset: at, as: UInt32.self) != 0 && h.load(fromByteOffset: at, as: UInt32.self) == 0 { return false }
        at += 4
      }
      return true
    }
  }
}

func core_vkDestroyDevice(_ device: VkDevice?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let d = unsafe Handle.get(device, DeviceObject.self) else { return }
  _ = d.waitIdle()
  unsafe Handle.destroy(d.queueHandle)
  unsafe d.queueHandle = nil
  unsafe Handle.destroy(device)
}

func core_vkGetDeviceQueue(_ device: VkDevice?, _ queueFamilyIndex: UInt32, _ queueIndex: UInt32, _ pQueue: UnsafeMutablePointer<VkQueue?>?) {
  guard let d = unsafe Handle.get(device, DeviceObject.self), queueFamilyIndex == 0, queueIndex == 0 else { return }
  unsafe pQueue?.pointee = d.queueHandle
}

func core_vkGetDeviceQueue2(_ device: VkDevice?, _ pQueueInfo: UnsafePointer<VkDeviceQueueInfo2>?, _ pQueue: UnsafeMutablePointer<VkQueue?>?) {
  guard let i = unsafe pQueueInfo else { return }
  unsafe core_vkGetDeviceQueue(device, unsafe i.pointee.queueFamilyIndex, unsafe i.pointee.queueIndex, pQueue)
}

func core_vkDeviceWaitIdle(_ device: VkDevice?) -> VkResult {
  guard let d = unsafe Handle.get(device, DeviceObject.self) else { return VK_ERROR_DEVICE_LOST }
  return d.waitIdle()
}

func core_vkQueueWaitIdle(_ queue: VkQueue?) -> VkResult {
  guard let q = unsafe Handle.get(queue, QueueObject.self) else { return VK_ERROR_DEVICE_LOST }
  return q.device.waitIdle()
}

/// The layer's own vkGetInstanceProcAddr and vkGetDeviceProcAddr, which the loader reads from its table like any command.
func core_vkGetInstanceProcAddr(_ instance: VkInstance?, _ pName: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  unsafe coreProcAddress(pName)
}

func core_vkGetDeviceProcAddr(_ device: VkDevice?, _ pName: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  unsafe coreProcAddress(pName)
}
