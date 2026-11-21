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
  /// Made with VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT: its views may be of another compatible format.
  let mutableFormat: Bool
  init(image: GPUImage, device: DeviceObject, mutableFormat: Bool = false) {
    self.image = image
    self.device = device
    self.mutableFormat = mutableFormat
  }
}

/// The core's usage for a Vulkan image's, or nil where it names one the core hasn't.
func imageUsage(_ u: UInt32, format: PixelFormat, _ gpu: any GPUDevice) -> ImageUsage? {
  var usage = ImageUsage(rawValue: 0)
  var rest = u
  func take(_ bit: VkImageUsageFlagBits, _ core: ImageUsage) {
    if rest & bit.rawValue != 0 {
      usage = usage | core
      rest &= ~bit.rawValue
    }
  }
  take(VK_IMAGE_USAGE_SAMPLED_BIT, .sampled)
  take(VK_IMAGE_USAGE_STORAGE_BIT, .storage)
  take(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, .renderTarget)
  take(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, .depthStencilTarget)
  take(VK_IMAGE_USAGE_TRANSFER_SRC_BIT, .copySource)
  take(VK_IMAGE_USAGE_TRANSFER_DST_BIT, .copyDestination)
  // A transient attachment is a hint the device has no use for.
  rest &= ~VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT.rawValue
  if rest != 0 { return nil }
  // Without the core's clears, vkCmdClearColorImage is a pass that clears: a destination is a target where one can be.
  if usage.contains(.copyDestination) && !gpu.limits.features.clearImage && !format.isDepthStencil && !format.isCompressed
    && gpu.limits.formats(format).renderTarget
  {
    usage = usage | .renderTarget
  }
  return usage
}

func core_vkCreateImage(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkImageCreateInfo>?,
                        _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pImage: UnsafeMutablePointer<VkImage?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let pImage = unsafe pImage else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let c = unsafe info.pointee
  let known = VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue | VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue
  guard unsafe c.flags & ~known == 0 else {
    say("unsupported: sparse, aliased or array-compatible images")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  guard let format = unsafe pixelFormat(c.format) else {
    say(unsafe "unsupported: an image of format \(c.format.rawValue)")
    return VK_ERROR_FORMAT_NOT_SUPPORTED
  }
  guard let usage = unsafe imageUsage(c.usage, format: format, d.gpu) else {
    say("unsupported: an image usage past sampled, storage, attachments and transfer")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  let dimension: ImageDimension
  var depth: Int32 = 1
  if unsafe c.imageType == VK_IMAGE_TYPE_2D {
    dimension = unsafe c.flags & VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue != 0 ? .cube : .d2
  } else if unsafe c.imageType == VK_IMAGE_TYPE_3D {
    dimension = .d3
    depth = unsafe Int32(c.extent.depth)
  } else {
    say("unsupported: a 1D image")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  let descriptor = unsafe ImageDescriptor(
    format: format, width: Int32(c.extent.width), height: Int32(c.extent.height), depth: depth, mipLevels: c.mipLevels,
    layers: c.arrayLayers, samples: c.samples.rawValue, dimension: dimension, usage: usage)
  do throws(GPUError) {
    let image = try d.gpu.makeImage(descriptor)
    let mutable = unsafe c.flags & VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue != 0
    unsafe pImage.pointee = Handle.make(ImageObject(image: image, device: d, mutableFormat: mutable))
  } catch { return vkResult(error) }
  return VK_SUCCESS
}

func core_vkDestroyImage(_ device: VkDevice?, _ image: VkImage?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let i = unsafe Handle.get(image, ImageObject.self) else { return }
  i.device.gpu.destroy(i.image)
  unsafe Handle.destroy(image)
}

/// An image's memory is the device's: the requirements are nominal (every texel of every mip level and layer, in any
/// type), and binding keeps nothing.
func imageRequirements(_ i: ImageObject) -> VkMemoryRequirements {
  var bytes: UInt64 = 0
  let d = i.image.descriptor
  for level in 0..<d.mipLevels { bytes += UInt64(d.byteSize(mip: level)) }
  bytes *= UInt64(d.layers) * UInt64(max(d.samples, 1))
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
  /// The view as the core says it: the part of the image, the format, the dimension and the aspects.
  let view: ImageView
  var textureSlot: UInt32?
  var storageSlot: UInt32?
  init(image: ImageObject, view: ImageView) {
    self.image = image
    self.view = view
  }
}

func viewDimension(_ t: VkImageViewType) -> ImageViewDimension? {
  if t == VK_IMAGE_VIEW_TYPE_2D { return .d2 }
  if t == VK_IMAGE_VIEW_TYPE_2D_ARRAY { return .d2Array }
  if t == VK_IMAGE_VIEW_TYPE_CUBE { return .cube }
  if t == VK_IMAGE_VIEW_TYPE_CUBE_ARRAY { return .cubeArray }
  if t == VK_IMAGE_VIEW_TYPE_3D { return .d3 }
  return nil
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
  guard let dimension = viewDimension(unsafe c.viewType) else {
    say("unsupported: a 1D view")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  guard let format = unsafe pixelFormat(c.format) else {
    say(unsafe "unsupported: a view of format \(c.format.rawValue)")
    return VK_ERROR_FORMAT_NOT_SUPPORTED
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
  let aspects = imageAspects(r.aspectMask)
  if aspects.isEmpty { return VK_ERROR_INITIALIZATION_FAILED }
  let remaining = ~UInt32(0)
  let core = ImageView(
    image.image, format: format, dimension: dimension, baseMip: r.baseMipLevel,
    mipCount: r.levelCount == remaining ? nil : r.levelCount, baseLayer: r.baseArrayLayer,
    layerCount: r.layerCount == remaining ? nil : r.layerCount, aspects: aspects)
  let view = ImageViewObject(image: image, view: core)
  // What the core refuses of a view (a part of an image, a format, a dimension) it refuses when the view meets the heap,
  // a pass or a copy; a view the heap is to hold is judged now.
  let single = aspects == .color || aspects == .depth || aspects == .stencil
  do throws(GPUError) {
    if image.image.usage.contains(.sampled) && single {
      guard let slot = d.takeSlot(&d.textureSlots) else { return VK_ERROR_OUT_OF_DEVICE_MEMORY }
      view.textureSlot = slot
      try d.gpu.writeTexture(slot, core)
    }
    if image.image.usage.contains(.storage) && core.mipCount == 1 && !format.isDepthStencil {
      guard let slot = d.takeSlot(&d.storageSlots) else {
        releaseViewSlots(d, view)
        return VK_ERROR_OUT_OF_DEVICE_MEMORY
      }
      view.storageSlot = slot
      try d.gpu.writeStorageImage(slot, core)
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

func samplerAddressMode(_ m: VkSamplerAddressMode) -> SamplerAddressMode? {
  if m == VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE { return .clampToEdge }
  if m == VK_SAMPLER_ADDRESS_MODE_REPEAT { return .repeat }
  if m == VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT { return .mirroredRepeat }
  if m == VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE { return .mirrorClampToEdge }
  if m == VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER { return .clampToBorder }
  return nil
}

func borderColor(_ c: VkBorderColor) -> BorderColor? {
  if c == VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK { return .transparentBlackFloat }
  if c == VK_BORDER_COLOR_INT_TRANSPARENT_BLACK { return .transparentBlackInt }
  if c == VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK { return .opaqueBlackFloat }
  if c == VK_BORDER_COLOR_INT_OPAQUE_BLACK { return .opaqueBlackInt }
  if c == VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE { return .opaqueWhiteFloat }
  if c == VK_BORDER_COLOR_INT_OPAQUE_WHITE { return .opaqueWhiteInt }
  return nil
}

func compareOp(_ o: VkCompareOp) -> CompareOp {
  if o == VK_COMPARE_OP_NEVER { return .never }
  if o == VK_COMPARE_OP_LESS { return .less }
  if o == VK_COMPARE_OP_EQUAL { return .equal }
  if o == VK_COMPARE_OP_LESS_OR_EQUAL { return .lessOrEqual }
  if o == VK_COMPARE_OP_GREATER { return .greater }
  if o == VK_COMPARE_OP_NOT_EQUAL { return .notEqual }
  if o == VK_COMPARE_OP_GREATER_OR_EQUAL { return .greaterOrEqual }
  return .always
}

func core_vkCreateSampler(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkSamplerCreateInfo>?,
                          _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pSampler: UnsafeMutablePointer<VkSampler?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let pSampler = unsafe pSampler else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let c = unsafe info.pointee
  guard let u = samplerAddressMode(unsafe c.addressModeU), let v = samplerAddressMode(unsafe c.addressModeV),
    let w = samplerAddressMode(unsafe c.addressModeW), let border = borderColor(unsafe c.borderColor)
  else {
    say("unsupported: a sampler address mode or a custom border colour")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  let descriptor = unsafe SamplerDescriptor(
    minFilter: c.minFilter == VK_FILTER_NEAREST ? .nearest : .linear, magFilter: c.magFilter == VK_FILTER_NEAREST ? .nearest : .linear,
    mipmapMode: c.mipmapMode == VK_SAMPLER_MIPMAP_MODE_NEAREST ? .nearest : .linear, addressModeU: u, addressModeV: v,
    addressModeW: w, borderColor: border, mipLodBias: c.mipLodBias, minLod: c.minLod, maxLod: c.maxLod,
    maxAnisotropy: c.anisotropyEnable != 0 ? c.maxAnisotropy : 1, compare: c.compareEnable != 0 ? compareOp(c.compareOp) : nil,
    unnormalizedCoordinates: c.unnormalizedCoordinates != 0)
  guard let slot = d.takeSlot(&d.samplerSlots) else { return VK_ERROR_OUT_OF_DEVICE_MEMORY }
  do throws(GPUError) {
    try d.gpu.writeSampler(slot, descriptor)
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
