// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan backend's memory, images and heap: buffers with device
// addresses (memory by intent), images with the layout the backend tracks,
// and the one bindless heap, a descriptor set of three arrays (sampled
// images at binding 0, samplers at 1, storage images at 2 where the device
// has them).

import GPUCore
import Vulkan

/// A view of part of a buffer as texels, kept until the buffer is destroyed.
@safe struct CachedBufferView {
  let offset: Int
  let range: Int
  let format: PixelFormat
  let handle: VkBufferView
}

/// A buffer, its memory and the texel-buffer views made of it. A sparse buffer has no memory of its own: its pages are bound
/// by `bindSparse` (Sparse.swift), and `sparse` is what binds to it need.
@safe final class BufferRecord {
  let buffer: VkBuffer
  let memory: VkDeviceMemory?
  /// The memory type `memory` is of (a sparse bind of it into a resource needs the resource to take that type).
  let memoryType: UInt32
  var sparse: VkMemoryRequirements?
  var views: [CachedBufferView] = []
  init(buffer: VkBuffer, memory: VkDeviceMemory?, memoryType: UInt32 = 0, sparse: VkMemoryRequirements? = nil) {
    unsafe self.buffer = unsafe buffer
    unsafe self.memory = unsafe memory
    self.memoryType = memoryType
    self.sparse = sparse
  }
  @safe func destroy(_ c: VulkanCommands, _ device: VkDevice) {
    for v in views { unsafe c.vkDestroyBufferView!(device, v.handle, nil) }
    unsafe c.vkDestroyBuffer!(device, buffer, nil)
    unsafe c.vkFreeMemory!(device, memory, nil)
  }
}

/// A view made of an image, kept until the image is destroyed.
@safe struct CachedView {
  let view: ImageView
  let handle: VkImageView
}

/// An image, the views made of it, and its current layout (one for the whole image: every transition covers every
/// mip level, layer and aspect).
@safe final class ImageRecord {
  let image: VkImage
  /// nil for a sparse image, whose pages `bindSparse` binds.
  let memory: VkDeviceMemory?
  let descriptor: ImageDescriptor
  /// A sparse image's requirements: its opaque size, the page, and the memory types binds may use.
  var sparse: VkMemoryRequirements?
  var layout = VK_IMAGE_LAYOUT_UNDEFINED
  var views: [CachedView] = []
  init(image: VkImage, memory: VkDeviceMemory?, descriptor: ImageDescriptor, sparse: VkMemoryRequirements? = nil) {
    unsafe self.image = unsafe image
    unsafe self.memory = unsafe memory
    self.descriptor = descriptor
    self.sparse = sparse
  }
  @safe func destroy(_ c: VulkanCommands, _ device: VkDevice) {
    for v in views { unsafe c.vkDestroyImageView!(device, v.handle, nil) }
    unsafe c.vkDestroyImage!(device, image, nil)
    unsafe c.vkFreeMemory!(device, memory, nil)
  }

  /// The layout the image rests in between commands: storage images in general (shaders write and read them),
  /// sampled ones ready to sample, others where the last command left them.
  var restLayout: VkImageLayout {
    if descriptor.usage.contains(.storage) { return VK_IMAGE_LAYOUT_GENERAL }
    if descriptor.usage.contains(.sampled) {
      return descriptor.format.isDepthStencil ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    }
    return layout
  }

  /// Every subresource of the image.
  var fullRange: VkImageSubresourceRange {
    VkImageSubresourceRange(aspectMask: vkAspects(descriptor.format.aspects), baseMipLevel: 0, levelCount: descriptor.mipLevels,
                            baseArrayLayer: 0, layerCount: descriptor.layers)
  }
}

func vkAspects(_ a: ImageAspects) -> UInt32 {
  var m: UInt32 = 0
  if a.contains(.color) { m |= VK_IMAGE_ASPECT_COLOR_BIT.rawValue }
  if a.contains(.depth) { m |= VK_IMAGE_ASPECT_DEPTH_BIT.rawValue }
  if a.contains(.stencil) { m |= VK_IMAGE_ASPECT_STENCIL_BIT.rawValue }
  return m
}

/// A pipeline.
@safe final class SamplerRecord {
  let sampler: VkSampler
  init(_ sampler: VkSampler) { unsafe self.sampler = unsafe sampler }
}

/// A pipeline.
@safe final class PipelineRecord {
  let pipeline: VkPipeline
  init(_ pipeline: VkPipeline) { unsafe self.pipeline = unsafe pipeline }
}

/// A set of queries.
@safe final class QueryRecord {
  let pool: VkQueryPool
  let kind: QueryKind
  let count: Int
  init(pool: VkQueryPool, kind: QueryKind, count: Int) {
    unsafe self.pool = unsafe pool
    self.kind = kind
    self.count = count
  }
}

/// The global heap: one descriptor set holding every texture (binding 0, an array of sampled images), every
/// sampler (binding 1) and, where the device has them, every storage image (binding 2).
@safe final class Heap {
  static let textureCapacity: UInt32 = 4096
  static let samplerCapacity: UInt32 = 16
  let layout: VkDescriptorSetLayout
  let pool: VkDescriptorPool
  let set: VkDescriptorSet

  @safe init(_ c: VulkanCommands, _ device: VkDevice, storageImages: Bool, texelBuffers: Bool = false) throws(GPUError) {
    // The arrays that are there: textures (0), samplers (1), storage images (2), uniform texel buffers (3) and storage
    // texel buffers (4). A binding of the layout is its number and its type; the numbers needn't be contiguous.
    var wanted: [(binding: UInt32, type: VkDescriptorType, count: UInt32)] = [
      (0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, Self.textureCapacity),
      (1, VK_DESCRIPTOR_TYPE_SAMPLER, Self.samplerCapacity),
    ]
    if storageImages { wanted.append((2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, VulkanDevice.heapStorageImageSlots)) }
    if texelBuffers {
      wanted.append((3, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, VulkanDevice.heapTexelBufferSlots))
      wanted.append((4, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VulkanDevice.heapTexelBufferSlots))
    }
    let bindingCount = UInt32(wanted.count)
    var bindings = unsafe [VkDescriptorSetLayoutBinding](repeating: VkDescriptorSetLayoutBinding(), count: wanted.count)
    for (i, w) in wanted.enumerated() {
      unsafe bindings[i].binding = w.binding
      unsafe bindings[i].descriptorType = w.type
      unsafe bindings[i].descriptorCount = w.count
      unsafe bindings[i].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    }
    let flag = VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT.rawValue | VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT.rawValue
    var flags = [VkDescriptorBindingFlags](repeating: flag, count: wanted.count)
    var l: VkDescriptorSetLayout?
    var r: VkResult = flags.withUnsafeMutableBufferPointer { fp in
      var flagInfo = unsafe VkDescriptorSetLayoutBindingFlagsCreateInfo()
      unsafe flagInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
      unsafe flagInfo.bindingCount = bindingCount
      unsafe flagInfo.pBindingFlags = unsafe UnsafePointer(fp.baseAddress)
      return withUnsafePointer(to: &flagInfo) { fip in
        bindings.withUnsafeBufferPointer { bp in
          var info = unsafe VkDescriptorSetLayoutCreateInfo()
          unsafe info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
          unsafe info.pNext = unsafe UnsafeRawPointer(fip)
          unsafe info.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT.rawValue
          unsafe info.bindingCount = bindingCount
          unsafe info.pBindings = bp.baseAddress
          return unsafe c.vkCreateDescriptorSetLayout!(device, &info, nil, &l)
        }
      }
    }
    try vkCheck(r, "vkCreateDescriptorSetLayout")
    unsafe layout = unsafe l!

    var sizes = wanted.map { VkDescriptorPoolSize(type: $0.type, descriptorCount: $0.count) }
    var p: VkDescriptorPool?
    r = sizes.withUnsafeMutableBufferPointer { sp in
      var info = unsafe VkDescriptorPoolCreateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
      unsafe info.flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT.rawValue
      unsafe info.maxSets = 1
      unsafe info.poolSizeCount = bindingCount
      unsafe info.pPoolSizes = unsafe UnsafePointer(sp.baseAddress)
      return unsafe c.vkCreateDescriptorPool!(device, &info, nil, &p)
    }
    try vkCheck(r, "vkCreateDescriptorPool")
    unsafe pool = unsafe p!

    var setLayout: VkDescriptorSetLayout? = unsafe l
    var ds: VkDescriptorSet?
    let poolHandle = unsafe p
    r = withUnsafePointer(to: &setLayout) { lp in
      var info = unsafe VkDescriptorSetAllocateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
      unsafe info.descriptorPool = unsafe poolHandle
      unsafe info.descriptorSetCount = 1
      unsafe info.pSetLayouts = unsafe lp
      return unsafe c.vkAllocateDescriptorSets!(device, &info, &ds)
    }
    try vkCheck(r, "vkAllocateDescriptorSets")
    unsafe set = unsafe ds!
  }

  @safe func destroy(_ c: VulkanCommands, _ device: VkDevice) {
    unsafe c.vkDestroyDescriptorPool!(device, pool, nil)
    unsafe c.vkDestroyDescriptorSetLayout!(device, layout, nil)
  }

  /// Writes one texel-buffer descriptor of `type` at binding, `index`.
  @safe func writeBufferView(_ c: VulkanCommands, _ device: VkDevice, binding: UInt32, index: UInt32, type: VkDescriptorType,
                             view: VkBufferView) {
    var handle: VkBufferView? = unsafe view
    withUnsafePointer(to: &handle) { hp in
      var write = unsafe VkWriteDescriptorSet()
      unsafe write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      unsafe write.dstSet = unsafe set
      unsafe write.dstBinding = binding
      unsafe write.dstArrayElement = index
      unsafe write.descriptorCount = 1
      unsafe write.descriptorType = type
      unsafe write.pTexelBufferView = unsafe hp
      unsafe c.vkUpdateDescriptorSets!(device, 1, &write, 0, nil)
    }
  }

  /// Writes one descriptor of `type` at binding, `index`.
  @safe func write(_ c: VulkanCommands, _ device: VkDevice, binding: UInt32, index: UInt32, type: VkDescriptorType,
             view: VkImageView?, sampler: VkSampler?, layout imageLayout: VkImageLayout) {
    var imageInfo = unsafe VkDescriptorImageInfo()
    unsafe imageInfo.sampler = unsafe sampler
    unsafe imageInfo.imageView = unsafe view
    unsafe imageInfo.imageLayout = imageLayout
    withUnsafePointer(to: &imageInfo) { ip in
      var write = unsafe VkWriteDescriptorSet()
      unsafe write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      unsafe write.dstSet = unsafe set
      unsafe write.dstBinding = binding
      unsafe write.dstArrayElement = index
      unsafe write.descriptorCount = 1
      unsafe write.descriptorType = type
      unsafe write.pImageInfo = unsafe ip
      unsafe c.vkUpdateDescriptorSets!(device, 1, &write, 0, nil)
    }
  }
}

extension VulkanDevice {
  // MARK: Memory

  public func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    let c = vk.commands
    var info = unsafe VkBufferCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    unsafe info.size = VkDeviceSize(max(bytes, 16))
    unsafe info.usage = VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue
      | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue
      | VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue
      | VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT.rawValue
    unsafe info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    var buffer: VkBuffer?
    unsafe try vkCheck(c.vkCreateBuffer!(device, &info, nil, &buffer), "vkCreateBuffer")
    var needs = VkMemoryRequirements()
    unsafe c.vkGetBufferMemoryRequirements!(device, buffer, &needs)
    let wanted: UInt32 = switch intent {
    case .upload: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
    case .readback: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue
    case .device: VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue
    }
    guard let type = memoryType(needs.memoryTypeBits, wanted)
      ?? (intent == .readback ? memoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue) : nil)
    else {
      unsafe c.vkDestroyBuffer!(device, buffer, nil)
      throw .unsupported("no memory type for \(intent)")
    }
    var memory: VkDeviceMemory?
    var flags = unsafe VkMemoryAllocateFlagsInfo()
    unsafe flags.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO
    unsafe flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT.rawValue
    let r: VkResult = withUnsafePointer(to: &flags) { fp in
      var a = unsafe VkMemoryAllocateInfo()
      unsafe a.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
      unsafe a.pNext = unsafe UnsafeRawPointer(fp)
      unsafe a.allocationSize = needs.size
      unsafe a.memoryTypeIndex = type
      return unsafe c.vkAllocateMemory!(device, &a, nil, &memory)
    }
    if r != VK_SUCCESS { unsafe c.vkDestroyBuffer!(device, buffer, nil) }
    guard r != VK_ERROR_OUT_OF_DEVICE_MEMORY, r != VK_ERROR_OUT_OF_HOST_MEMORY else { throw .outOfMemory("\(bytes) bytes") }
    try vkCheck(r, "vkAllocateMemory")
    _ = unsafe c.vkBindBufferMemory!(device, buffer, memory, 0)
    var pointer: UnsafeMutableRawPointer?
    if intent != .device { _ = unsafe c.vkMapMemory!(device, memory, 0, VkDeviceSize(VK_WHOLE_SIZE), 0, &pointer) }
    var addressInfo = unsafe VkBufferDeviceAddressInfo()
    unsafe addressInfo.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO
    unsafe addressInfo.buffer = unsafe buffer
    let address = unsafe c.vkGetBufferDeviceAddress!(device, &addressInfo)
    let handle = buffers.insert(unsafe BufferRecord(buffer: buffer!, memory: memory!, memoryType: type))
    return unsafe GPUMemory(handle: handle, address: address, pointer: pointer, size: bytes, intent: intent)
  }

  public func free(_ memory: GPUMemory) {
    guard let record = buffers.remove(memory.handle) else { return }
    retire(.buffer(record))
  }

  /// A new handle to `memory`'s VMO, for another process (VK_FUCHSIA_external_memory); nil where the driver can't.
  public func exportHandle(_ memory: GPUMemory) -> UInt32? {
    guard let record = buffers[memory.handle], record.memory != nil,
      let export = unsafe vk.commands.vkGetMemoryZirconHandleFUCHSIA
    else { return nil }
    var info = unsafe VkMemoryGetZirconHandleInfoFUCHSIA()
    unsafe info.sType = VK_STRUCTURE_TYPE_MEMORY_GET_ZIRCON_HANDLE_INFO_FUCHSIA
    unsafe info.memory = record.memory
    unsafe info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ZIRCON_VMO_BIT_FUCHSIA
    var vmo: zx_handle_t = 0
    guard unsafe export(device, &info, &vmo) == VK_SUCCESS else { return nil }
    return vmo
  }

  // MARK: Images

  public func makeImage(_ d: ImageDescriptor) throws(GPUError) -> GPUImage {
    let c = vk.commands
    guard d.width > 0, d.height > 0, d.width <= limits.maxImageDimension, d.height <= limits.maxImageDimension else {
      throw .unsupported("an image of \(d.width) x \(d.height)")
    }
    if let e = d.check(limits: limits) { throw e }
    var info = unsafe VkImageCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    var flags: UInt32 = d.sparse.vkImageFlags
    if d.dimension == .cube { flags |= VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue }
    // Views of other formats (of a class) and the 2D array views of a cube's layers.
    if !d.format.isCompressed && !d.format.isDepthStencil { flags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue }
    unsafe info.flags = flags
    unsafe info.imageType = d.dimension.vkImageType
    unsafe info.format = d.format.vk
    unsafe info.extent = VkExtent3D(width: UInt32(d.width), height: UInt32(d.height), depth: UInt32(d.depth))
    unsafe info.mipLevels = d.mipLevels
    unsafe info.arrayLayers = d.layers
    unsafe info.samples = vkSamples(d.samples)
    unsafe info.tiling = VK_IMAGE_TILING_OPTIMAL
    var usage: UInt32 = 0
    if d.usage.contains(.sampled) { usage |= VK_IMAGE_USAGE_SAMPLED_BIT.rawValue }
    if d.usage.contains(.renderTarget) { usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue }
    if d.usage.contains(.depthStencilTarget) { usage |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue }
    if d.usage.contains(.storage) { usage |= VK_IMAGE_USAGE_STORAGE_BIT.rawValue }
    if d.usage.contains(.copySource) { usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue }
    if d.usage.contains(.copyDestination) { usage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue }
    unsafe info.usage = usage
    unsafe info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    var image: VkImage?
    unsafe try vkCheck(c.vkCreateImage!(device, &info, nil, &image), "vkCreateImage")
    var needs = VkMemoryRequirements()
    unsafe c.vkGetImageMemoryRequirements!(device, image, &needs)
    // A sparse image has no memory until its pages are bound.
    if !d.sparse.isEmpty {
      let handle = images.insert(unsafe ImageRecord(image: image!, memory: nil, descriptor: d, sparse: needs))
      return GPUImage(handle: handle, descriptor: d)
    }
    guard let type = memoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue) else {
      unsafe c.vkDestroyImage!(device, image, nil)
      throw .unsupported("no device-local memory for an image")
    }
    var a = unsafe VkMemoryAllocateInfo()
    unsafe a.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    unsafe a.allocationSize = needs.size
    unsafe a.memoryTypeIndex = type
    var memory: VkDeviceMemory?
    let r: VkResult = unsafe c.vkAllocateMemory!(device, &a, nil, &memory)
    if r != VK_SUCCESS { unsafe c.vkDestroyImage!(device, image, nil) }
    guard r != VK_ERROR_OUT_OF_DEVICE_MEMORY, r != VK_ERROR_OUT_OF_HOST_MEMORY else { throw .outOfMemory("an image") }
    try vkCheck(r, "vkAllocateMemory")
    _ = unsafe c.vkBindImageMemory!(device, image, memory, 0)
    let handle = images.insert(unsafe ImageRecord(image: image!, memory: memory!, descriptor: d))
    return GPUImage(handle: handle, descriptor: d)
  }

  public func destroy(_ image: GPUImage) {
    guard let record = images.remove(image.handle) else { return }
    retire(.image(record))
  }

  /// The Vulkan view of `v` (made once, and kept until the image goes).
  @safe func vkView(_ record: ImageRecord, _ v: ImageView) throws(GPUError) -> VkImageView {
    for cached in record.views where cached.view == v { return unsafe cached.handle }
    var info = unsafe VkImageViewCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    unsafe info.image = unsafe record.image
    unsafe info.viewType = v.dimension.vk
    unsafe info.format = v.format.vk
    unsafe info.components = v.swizzle.vk
    unsafe info.subresourceRange = VkImageSubresourceRange(aspectMask: vkAspects(v.aspects), baseMipLevel: v.baseMip, levelCount: v.mipCount,
                                                          baseArrayLayer: v.baseLayer, layerCount: v.layerCount)
    var view: VkImageView?
    unsafe try vkCheck(vk.commands.vkCreateImageView!(device, &info, nil, &view), "vkCreateImageView")
    record.views.append(unsafe CachedView(view: v, handle: view!))
    return unsafe view!
  }

  // MARK: The heap

  @safe public func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    try writeTexture(index, ImageView(image))
  }

  @safe public func writeTexture(_ index: UInt32, _ view: ImageView) throws(GPUError) {
    guard index < Heap.textureCapacity else { throw .invalid("texture slot \(index)") }
    guard let record = images[view.image.handle] else { throw .invalid("an image that isn't this device's") }
    if let e = view.check(for: .texture, limits: limits) { throw e }
    let handle = try vkView(record, view)
    heap.write(vk.commands, device, binding: 0, index: index, type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, view: unsafe handle,
               sampler: nil, layout: record.restLayout)
  }

  public func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < Heap.samplerCapacity else { throw .invalid("sampler slot \(index)") }
    if let e = sampler.check(limits: limits) { throw e }
    let c = vk.commands
    var info = unsafe VkSamplerCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    unsafe info.magFilter = sampler.magFilter.vk
    unsafe info.minFilter = sampler.minFilter.vk
    unsafe info.mipmapMode = sampler.mipmapMode == .linear ? VK_SAMPLER_MIPMAP_MODE_LINEAR : VK_SAMPLER_MIPMAP_MODE_NEAREST
    unsafe info.addressModeU = sampler.addressModeU.vk
    unsafe info.addressModeV = sampler.addressModeV.vk
    unsafe info.addressModeW = sampler.addressModeW.vk
    unsafe info.mipLodBias = sampler.mipLodBias
    unsafe info.anisotropyEnable = sampler.maxAnisotropy > 1 ? 1 : 0
    unsafe info.maxAnisotropy = sampler.maxAnisotropy
    if let compare = sampler.compare {
      unsafe info.compareEnable = 1
      unsafe info.compareOp = compare.vk
    }
    unsafe info.minLod = sampler.minLod
    unsafe info.maxLod = sampler.maxLod
    unsafe info.borderColor = sampler.borderColor.vk
    unsafe info.unnormalizedCoordinates = sampler.unnormalizedCoordinates ? 1 : 0
    // A colour of the sampler's own (VK_EXT_custom_border_color, with no format named): the extension's structure, and the
    // custom colour in place of the six.
    var custom = unsafe VkSamplerCustomBorderColorCreateInfoEXT()
    unsafe custom.sType = VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT
    unsafe custom.format = VK_FORMAT_UNDEFINED
    switch sampler.customBorderColor {
    case .float(let r, let g, let b, let a)?:
      var value = VkClearColorValue()
      unsafe value.float32 = (r, g, b, a)
      unsafe custom.customBorderColor = value
      unsafe info.borderColor = VK_BORDER_COLOR_FLOAT_CUSTOM_EXT
    case .int(let r, let g, let b, let a)?:
      var value = VkClearColorValue()
      unsafe value.int32 = (r, g, b, a)
      unsafe custom.customBorderColor = value
      unsafe info.borderColor = VK_BORDER_COLOR_INT_CUSTOM_EXT
    case nil: break
    }
    var s: VkSampler?
    let created: VkResult = withUnsafePointer(to: &custom) { cp in
      if sampler.customBorderColor != nil { unsafe info.pNext = unsafe UnsafeRawPointer(cp) }
      return unsafe c.vkCreateSampler!(device, &info, nil, &s)
    }
    try vkCheck(created, "vkCreateSampler")
    if let old = samplers[Int(index)] { retire(.sampler(old)) }
    samplers[Int(index)] = unsafe SamplerRecord(s!)
    heap.write(c, device, binding: 1, index: index, type: VK_DESCRIPTOR_TYPE_SAMPLER, view: nil, sampler: s,
               layout: VK_IMAGE_LAYOUT_UNDEFINED)
  }

  @safe public func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    try writeStorageImage(index, ImageView(image))
  }

  @safe public func writeStorageImage(_ index: UInt32, _ view: ImageView) throws(GPUError) {
    guard limits.features.storageImages else { throw .unsupported("storage images in the heap") }
    guard index < limits.heapStorageImages else { throw .invalid("storage slot \(index)") }
    guard let record = images[view.image.handle] else { throw .invalid("an image that isn't this device's") }
    if let e = view.check(for: .storage, limits: limits) { throw e }
    let handle = try vkView(record, view)
    heap.write(vk.commands, device, binding: 2, index: index, type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, view: unsafe handle,
               sampler: nil, layout: VK_IMAGE_LAYOUT_GENERAL)
  }

  // MARK: Texel buffers

  /// The Vulkan view of `v` of `record`'s buffer (made once, and kept until the buffer goes).
  @safe func vkBufferView(_ record: BufferRecord, _ v: BufferView) throws(GPUError) -> VkBufferView {
    for cached in record.views where cached.offset == v.offset && cached.range == v.range && cached.format == v.format {
      return unsafe cached.handle
    }
    var info = unsafe VkBufferViewCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO
    unsafe info.buffer = unsafe record.buffer
    unsafe info.format = v.format.vk
    unsafe info.offset = VkDeviceSize(v.offset)
    unsafe info.range = VkDeviceSize(v.range)
    var view: VkBufferView?
    unsafe try vkCheck(vk.commands.vkCreateBufferView!(device, &info, nil, &view), "vkCreateBufferView")
    record.views.append(unsafe CachedBufferView(offset: v.offset, range: v.range, format: v.format, handle: view!))
    return unsafe view!
  }

  @safe public func writeTexelBuffer(_ index: UInt32, _ view: BufferView) throws(GPUError) {
    guard limits.features.uniformTexelBuffers else { throw .unsupported("uniform texel buffers in the heap") }
    guard index < limits.heapTexelBuffers else { throw .invalid("texel buffer slot \(index)") }
    guard let record = buffers[view.memory.handle] else { throw .invalid("memory that isn't this device's") }
    if let e = view.check(for: .uniform, limits: limits) { throw e }
    guard view.offset % texelOffsetAlignment == 0 else { throw .unsupported("a texel buffer view at an offset the device doesn't align") }
    let handle = try vkBufferView(record, view)
    heap.writeBufferView(vk.commands, device, binding: 3, index: index, type: VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, view: unsafe handle)
  }

  @safe public func writeStorageTexelBuffer(_ index: UInt32, _ view: BufferView) throws(GPUError) {
    guard limits.features.storageTexelBuffers else { throw .unsupported("storage texel buffers in the heap") }
    guard index < limits.heapStorageTexelBuffers else { throw .invalid("storage texel buffer slot \(index)") }
    guard let record = buffers[view.memory.handle] else { throw .invalid("memory that isn't this device's") }
    if let e = view.check(for: .storage, limits: limits) { throw e }
    guard view.offset % texelOffsetAlignment == 0 else { throw .unsupported("a texel buffer view at an offset the device doesn't align") }
    let handle = try vkBufferView(record, view)
    heap.writeBufferView(vk.commands, device, binding: 4, index: index, type: VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, view: unsafe handle)
  }

  // MARK: Queries

  public func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet {
    guard count > 0 else { throw .invalid("a query set of no queries") }
    var info = unsafe VkQueryPoolCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
    switch kind {
    case .timestamp:
      guard limits.features.timestampQueries else { throw .unsupported("timestamp queries") }
      unsafe info.queryType = VK_QUERY_TYPE_TIMESTAMP
    case .occlusion:
      unsafe info.queryType = VK_QUERY_TYPE_OCCLUSION
    case .pipelineStatistics(let s):
      guard limits.features.pipelineStatisticsQueries else { throw .unsupported("pipeline statistics queries") }
      if s.rawValue == 0 { throw .invalid("a statistics query of no counters") }
      unsafe info.queryType = VK_QUERY_TYPE_PIPELINE_STATISTICS
      // The core's counters are the bits of Vulkan's, in the same order.
      unsafe info.pipelineStatistics = s.rawValue
    }
    unsafe info.queryCount = UInt32(count)
    var pool: VkQueryPool?
    unsafe try vkCheck(vk.commands.vkCreateQueryPool!(device, &info, nil, &pool), "vkCreateQueryPool")
    let handle = querySets.insert(unsafe QueryRecord(pool: pool!, kind: kind, count: count))
    return GPUQuerySet(handle: handle, kind: kind, count: count)
  }

  public func destroy(_ set: GPUQuerySet) {
    guard let record = querySets.remove(set.handle) else { return }
    retire(.queries(record))
  }

  public func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] {
    guard let record = querySets[set.handle] else { throw .invalid("a query set that isn't this device's") }
    guard first >= 0, count >= 0, first + count <= record.count else { throw .invalid("queries past the set") }
    var per = 1
    if case .pipelineStatistics(let s) = record.kind { per = s.count }
    var out = [UInt64](repeating: 0, count: count * per)
    guard count > 0 else { return out }
    let r: VkResult = out.withUnsafeMutableBytes { bytes in
      unsafe vk.commands.vkGetQueryPoolResults!(device, record.pool, UInt32(first), UInt32(count), count * per * 8, bytes.baseAddress,
                                                VkDeviceSize(per * 8), VK_QUERY_RESULT_64_BIT.rawValue)
    }
    try vkCheck(r, "vkGetQueryPoolResults")
    return out
  }

  // MARK: Helpers

  func memoryType(_ bits: UInt32, _ wanted: UInt32) -> UInt32? {
    var props = VkPhysicalDeviceMemoryProperties()
    unsafe vk.commands.vkGetPhysicalDeviceMemoryProperties!(physical, &props)
    let types = withUnsafeBytes(of: props.memoryTypes) { unsafe Array($0.bindMemory(to: VkMemoryType.self)) }
    return (0..<props.memoryTypeCount).first { bits & (1 << $0) != 0 && types[Int($0)].propertyFlags & wanted == wanted }
  }
}
