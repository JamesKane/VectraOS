// SPDX-License-Identifier: BSD-3-Clause

// Memory, buffers, images, views and samplers (D174 step 5, part 3). A `VkBuffer` is its memory plus an offset; a
// `VkImage` is a core image made at `vkCreateImage`, and binding memory to it records nothing; a view or a sampler
// that the heap reaches takes its slot when it is made.

import GPUCore
import TDVulkan

// MARK: Memory

final class MemoryObject: CoreObject {
  let gpu: GPUMemory
  let type: UInt32
  let device: DeviceObject
  init(gpu: GPUMemory, type: UInt32, device: DeviceObject) {
    self.gpu = gpu
    self.type = type
    self.device = device
  }
}

func core_vkAllocateMemory(_ device: VkDevice?, _ pAllocateInfo: UnsafePointer<VkMemoryAllocateInfo>?,
                           _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                           _ pMemory: UnsafeMutablePointer<VkDeviceMemory?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pAllocateInfo, let pMemory = unsafe pMemory else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let type = unsafe info.pointee.memoryTypeIndex
  guard let intent = MemoryTypes.intent(type) else { return VK_ERROR_FEATURE_NOT_PRESENT }
  let size = unsafe Int(info.pointee.allocationSize)
  guard size > 0 else { return VK_ERROR_OUT_OF_DEVICE_MEMORY }
  do throws(GPUError) {
    let m = try d.gpu.allocate(intent, bytes: size)
    unsafe pMemory.pointee = Handle.make(MemoryObject(gpu: m, type: type, device: d))
  } catch { return vkResult(error) }
  return VK_SUCCESS
}

func core_vkFreeMemory(_ device: VkDevice?, _ memory: VkDeviceMemory?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let m = unsafe Handle.get(memory, MemoryObject.self) else { return }
  m.device.gpu.free(m.gpu)
  unsafe Handle.destroy(memory)
}

func core_vkMapMemory(_ device: VkDevice?, _ memory: VkDeviceMemory?, _ offset: VkDeviceSize, _ size: VkDeviceSize,
                      _ flags: VkMemoryMapFlags, _ ppData: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> VkResult
{
  guard let m = unsafe Handle.get(memory, MemoryObject.self), let pp = unsafe ppData else { return VK_ERROR_MEMORY_MAP_FAILED }
  guard let base = unsafe m.gpu.pointer, offset < UInt64(m.gpu.size) else { return VK_ERROR_MEMORY_MAP_FAILED }
  unsafe pp.pointee = unsafe base + Int(offset)
  return VK_SUCCESS
}

func core_vkUnmapMemory(_ device: VkDevice?, _ memory: VkDeviceMemory?) {}

/// Host-visible memory is coherent, so flushing and invalidating have nothing to do.
func core_vkFlushMappedMemoryRanges(_ device: VkDevice?, _ memoryRangeCount: UInt32,
                                    _ pMemoryRanges: UnsafePointer<VkMappedMemoryRange>?) -> VkResult { VK_SUCCESS }

func core_vkInvalidateMappedMemoryRanges(_ device: VkDevice?, _ memoryRangeCount: UInt32,
                                         _ pMemoryRanges: UnsafePointer<VkMappedMemoryRange>?) -> VkResult { VK_SUCCESS }

// MARK: Buffers

final class BufferObject: CoreObject {
  let size: UInt64
  let usage: UInt32
  var memory: MemoryObject?
  var offset: UInt64 = 0
  init(size: UInt64, usage: UInt32) {
    self.size = size
    self.usage = usage
  }

  /// The buffer's bytes' GPU address, once memory is bound.
  var address: UInt64? { memory.map { $0.gpu.address + offset } }
  /// The core's memory for the buffer, and where in it the buffer starts.
  var place: (memory: GPUMemory, offset: Int)? { memory.map { ($0.gpu, Int(offset)) } }
}

func core_vkCreateBuffer(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkBufferCreateInfo>?,
                         _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pBuffer: UnsafeMutablePointer<VkBuffer?>?) -> VkResult
{
  guard let _ = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let pBuffer = unsafe pBuffer else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  // Sparse buffers and buffers with their own address capture aren't there.
  if unsafe info.pointee.flags != 0 { return VK_ERROR_FEATURE_NOT_PRESENT }
  unsafe pBuffer.pointee = Handle.make(BufferObject(size: unsafe info.pointee.size, usage: unsafe info.pointee.usage))
  return VK_SUCCESS
}

func core_vkDestroyBuffer(_ device: VkDevice?, _ buffer: VkBuffer?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(buffer)
}

func bufferRequirements(_ b: BufferObject) -> VkMemoryRequirements {
  VkMemoryRequirements(size: (b.size + 63) & ~63, alignment: 64, memoryTypeBits: MemoryTypes.allBits)
}

func core_vkGetBufferMemoryRequirements(_ device: VkDevice?, _ buffer: VkBuffer?,
                                        _ pMemoryRequirements: UnsafeMutablePointer<VkMemoryRequirements>?)
{
  guard let b = unsafe Handle.get(buffer, BufferObject.self) else { return }
  unsafe pMemoryRequirements?.pointee = bufferRequirements(b)
}

func core_vkGetBufferMemoryRequirements2(_ device: VkDevice?, _ pInfo: UnsafePointer<VkBufferMemoryRequirementsInfo2>?,
                                         _ pMemoryRequirements: UnsafeMutablePointer<VkMemoryRequirements2>?)
{
  guard let i = unsafe pInfo, let b = unsafe Handle.get(i.pointee.buffer, BufferObject.self) else { return }
  unsafe pMemoryRequirements?.pointee.memoryRequirements = bufferRequirements(b)
}

func bindBuffer(_ buffer: VkBuffer?, _ memory: VkDeviceMemory?, _ offset: UInt64) -> VkResult {
  guard let b = unsafe Handle.get(buffer, BufferObject.self), let m = unsafe Handle.get(memory, MemoryObject.self) else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  if offset + b.size > UInt64(m.gpu.size) { return VK_ERROR_OUT_OF_DEVICE_MEMORY }
  b.memory = m
  b.offset = offset
  return VK_SUCCESS
}

func core_vkBindBufferMemory(_ device: VkDevice?, _ buffer: VkBuffer?, _ memory: VkDeviceMemory?, _ memoryOffset: VkDeviceSize) -> VkResult {
  unsafe bindBuffer(buffer, memory, memoryOffset)
}

func core_vkBindBufferMemory2(_ device: VkDevice?, _ bindInfoCount: UInt32, _ pBindInfos: UnsafePointer<VkBindBufferMemoryInfo>?) -> VkResult {
  for i in 0..<Int(bindInfoCount) {
    let b = unsafe pBindInfos![i]
    let r = unsafe bindBuffer(b.buffer, b.memory, b.memoryOffset)
    if r != VK_SUCCESS { return r }
  }
  return VK_SUCCESS
}

func core_vkGetBufferDeviceAddress(_ device: VkDevice?, _ pInfo: UnsafePointer<VkBufferDeviceAddressInfo>?) -> VkDeviceAddress {
  guard let i = unsafe pInfo, let b = unsafe Handle.get(i.pointee.buffer, BufferObject.self) else { return 0 }
  return b.address ?? 0
}

// MARK: Images

final class ImageObject: CoreObject {
  let image: GPUImage
  let device: DeviceObject
  init(image: GPUImage, device: DeviceObject) {
    self.image = image
    self.device = device
  }
}

func core_vkCreateImage(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkImageCreateInfo>?,
                        _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pImage: UnsafeMutablePointer<VkImage?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let pImage = unsafe pImage else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let c = unsafe info.pointee
  // 2D, one mip level, one layer, one sample, and no flags (no cube, no sparse, no mutable format).
  guard unsafe c.imageType == VK_IMAGE_TYPE_2D, unsafe c.mipLevels == 1, unsafe c.arrayLayers == 1, unsafe c.extent.depth == 1,
    unsafe c.samples == VK_SAMPLE_COUNT_1_BIT, unsafe c.flags == 0
  else {
    say("unsupported: an image that isn't 2D with one mip level, one layer and one sample")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  guard let format = unsafe pixelFormat(c.format) else {
    say(unsafe "unsupported: an image of format \(c.format.rawValue)")
    return VK_ERROR_FORMAT_NOT_SUPPORTED
  }
  var usage = ImageUsage(rawValue: 0)
  let u = unsafe c.usage
  if u & VK_IMAGE_USAGE_SAMPLED_BIT.rawValue != 0 { usage = usage | .sampled }
  if u & VK_IMAGE_USAGE_STORAGE_BIT.rawValue != 0 { usage = usage | .storage }
  if u & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue != 0 { usage = usage | .renderTarget }
  if u & VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue != 0 { usage = usage | .copySource }
  if u & VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue != 0 {
    // vkCmdClearColorImage is a pass that clears, so a destination is a target where one can be.
    usage = usage | .copyDestination
    if format != .r8 { usage = usage | .renderTarget }
  }
  if u & ~(VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_STORAGE_BIT.rawValue | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue
    | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue) != 0
  {
    say("unsupported: an image usage past sampled, storage, colour attachment and transfer")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  do throws(GPUError) {
    let image = unsafe try d.gpu.makeImage(ImageDescriptor(format: format, width: Int32(c.extent.width), height: Int32(c.extent.height),
                                                     usage: usage))
    unsafe pImage.pointee = Handle.make(ImageObject(image: image, device: d))
  } catch { return vkResult(error) }
  return VK_SUCCESS
}

func core_vkDestroyImage(_ device: VkDevice?, _ image: VkImage?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let i = unsafe Handle.get(image, ImageObject.self) else { return }
  i.device.gpu.destroy(i.image)
  unsafe Handle.destroy(image)
}

/// An image's memory is the device's: the requirements are nominal (the pixels, in any type), and binding keeps nothing.
func imageRequirements(_ i: ImageObject) -> VkMemoryRequirements {
  let bytes = UInt64(i.image.width) * UInt64(i.image.height) * UInt64(i.image.format.bytesPerPixel)
  return VkMemoryRequirements(size: (bytes + 255) & ~255, alignment: 256, memoryTypeBits: MemoryTypes.allBits)
}

func core_vkGetImageMemoryRequirements(_ device: VkDevice?, _ image: VkImage?,
                                       _ pMemoryRequirements: UnsafeMutablePointer<VkMemoryRequirements>?)
{
  guard let i = unsafe Handle.get(image, ImageObject.self) else { return }
  unsafe pMemoryRequirements?.pointee = imageRequirements(i)
}

func core_vkGetImageMemoryRequirements2(_ device: VkDevice?, _ pInfo: UnsafePointer<VkImageMemoryRequirementsInfo2>?,
                                        _ pMemoryRequirements: UnsafeMutablePointer<VkMemoryRequirements2>?)
{
  guard let n = unsafe pInfo, let i = unsafe Handle.get(n.pointee.image, ImageObject.self) else { return }
  unsafe pMemoryRequirements?.pointee.memoryRequirements = imageRequirements(i)
}

func core_vkBindImageMemory(_ device: VkDevice?, _ image: VkImage?, _ memory: VkDeviceMemory?, _ memoryOffset: VkDeviceSize) -> VkResult {
  unsafe Handle.get(image, ImageObject.self) == nil ? VK_ERROR_INITIALIZATION_FAILED : VK_SUCCESS
}

func core_vkBindImageMemory2(_ device: VkDevice?, _ bindInfoCount: UInt32, _ pBindInfos: UnsafePointer<VkBindImageMemoryInfo>?) -> VkResult {
  for i in 0..<Int(bindInfoCount) where unsafe Handle.get(pBindInfos![i].image, ImageObject.self) == nil {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  return VK_SUCCESS
}

// MARK: Image views

final class ImageViewObject: CoreObject {
  let image: ImageObject
  var textureSlot: UInt32?
  var storageSlot: UInt32?
  init(image: ImageObject) { self.image = image }
}

func core_vkCreateImageView(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkImageViewCreateInfo>?,
                            _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                            _ pView: UnsafeMutablePointer<VkImageView?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let pView = unsafe pView,
    let image = unsafe Handle.get(info.pointee.image, ImageObject.self)
  else { return VK_ERROR_INITIALIZATION_FAILED }
  let c = unsafe info.pointee
  let r = unsafe c.subresourceRange
  // The whole image, in its own format, as it is.
  guard unsafe c.viewType == VK_IMAGE_VIEW_TYPE_2D, unsafe pixelFormat(c.format) == image.image.format, r.baseMipLevel == 0,
    r.levelCount == 1 || r.levelCount == ~0, r.baseArrayLayer == 0, r.layerCount == 1 || r.layerCount == ~0
  else {
    say("unsupported: a view of part of an image or of another format")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  let swizzle = unsafe c.components
  // Identity (or each component as itself) only: the heap has no swizzle.
  if swizzle.r != VK_COMPONENT_SWIZZLE_IDENTITY && swizzle.r != VK_COMPONENT_SWIZZLE_R
    || swizzle.g != VK_COMPONENT_SWIZZLE_IDENTITY && swizzle.g != VK_COMPONENT_SWIZZLE_G
    || swizzle.b != VK_COMPONENT_SWIZZLE_IDENTITY && swizzle.b != VK_COMPONENT_SWIZZLE_B
    || swizzle.a != VK_COMPONENT_SWIZZLE_IDENTITY && swizzle.a != VK_COMPONENT_SWIZZLE_A
  {
    say("unsupported: a view with a swizzle")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  let view = ImageViewObject(image: image)
  do throws(GPUError) {
    if image.image.usage.contains(.sampled) {
      guard let slot = d.takeSlot(&d.textureSlots) else { return VK_ERROR_OUT_OF_DEVICE_MEMORY }
      view.textureSlot = slot
      try d.gpu.writeTexture(slot, image.image)
    }
    if image.image.usage.contains(.storage) {
      guard let slot = d.takeSlot(&d.storageSlots) else {
        releaseViewSlots(d, view)
        return VK_ERROR_OUT_OF_DEVICE_MEMORY
      }
      view.storageSlot = slot
      try d.gpu.writeStorageImage(slot, image.image)
    }
  } catch {
    releaseViewSlots(d, view)
    return vkResult(error)
  }
  unsafe pView.pointee = Handle.make(view)
  return VK_SUCCESS
}

func releaseViewSlots(_ d: DeviceObject, _ v: ImageViewObject) {
  if let s = v.textureSlot { d.textureSlots[Int(s)] = false }
  if let s = v.storageSlot { d.storageSlots[Int(s)] = false }
  v.textureSlot = nil
  v.storageSlot = nil
}

func core_vkDestroyImageView(_ device: VkDevice?, _ imageView: VkImageView?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let d = unsafe Handle.get(device, DeviceObject.self), let v = unsafe Handle.get(imageView, ImageViewObject.self) else { return }
  releaseViewSlots(d, v)
  unsafe Handle.destroy(imageView)
}

// MARK: Samplers

final class SamplerObject: CoreObject {
  let slot: UInt32
  init(slot: UInt32) { self.slot = slot }
}

func core_vkCreateSampler(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkSamplerCreateInfo>?,
                          _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pSampler: UnsafeMutablePointer<VkSampler?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let pSampler = unsafe pSampler else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let c = unsafe info.pointee
  // The core's sampler has a filter and one address mode.
  let mode: SamplerAddressMode
  if unsafe c.addressModeU == VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE { mode = .clampToEdge } else if unsafe c.addressModeU == VK_SAMPLER_ADDRESS_MODE_REPEAT {
    mode = .repeat
  } else if unsafe c.addressModeU == VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT { mode = .mirroredRepeat } else {
    say(unsafe "unsupported: a sampler address mode of \(c.addressModeU.rawValue)")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  guard unsafe c.addressModeV == c.addressModeU, unsafe c.addressModeW == c.addressModeU, unsafe c.compareEnable == 0, unsafe c.unnormalizedCoordinates == 0 else {
    say("unsupported: a sampler with its own mode per axis, a compare or unnormalised coordinates")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  guard let slot = d.takeSlot(&d.samplerSlots) else { return VK_ERROR_OUT_OF_DEVICE_MEMORY }
  do throws(GPUError) {
    unsafe try d.gpu.writeSampler(slot, SamplerDescriptor(filter: c.magFilter == VK_FILTER_NEAREST ? .nearest : .linear, addressMode: mode))
  } catch {
    d.samplerSlots[Int(slot)] = false
    return vkResult(error)
  }
  unsafe pSampler.pointee = Handle.make(SamplerObject(slot: slot))
  return VK_SUCCESS
}

func core_vkDestroySampler(_ device: VkDevice?, _ sampler: VkSampler?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let d = unsafe Handle.get(device, DeviceObject.self), let s = unsafe Handle.get(sampler, SamplerObject.self) else { return }
  d.samplerSlots[Int(s.slot)] = false
  unsafe Handle.destroy(sampler)
}
