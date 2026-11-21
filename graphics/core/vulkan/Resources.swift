// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan backend's memory, images and heap: buffers with device
// addresses (memory by intent), images with the layout the backend tracks,
// and the one bindless heap, a descriptor set of three arrays (sampled
// images at binding 0, samplers at 1, storage images at 2 where the device
// has them).

import GPUCore
import Vulkan

/// A buffer and its memory.
@safe final class BufferRecord {
  let buffer: VkBuffer
  let memory: VkDeviceMemory
  init(buffer: VkBuffer, memory: VkDeviceMemory) {
    unsafe self.buffer = unsafe buffer
    unsafe self.memory = unsafe memory
  }
  @safe func destroy(_ c: VulkanCommands, _ device: VkDevice) {
    unsafe c.vkDestroyBuffer!(device, buffer, nil)
    unsafe c.vkFreeMemory!(device, memory, nil)
  }
}

/// An image, its view and its current layout.
@safe final class ImageRecord {
  let image: VkImage
  let view: VkImageView
  let memory: VkDeviceMemory
  let descriptor: ImageDescriptor
  var layout = VK_IMAGE_LAYOUT_UNDEFINED
  init(image: VkImage, view: VkImageView, memory: VkDeviceMemory, descriptor: ImageDescriptor) {
    unsafe self.image = unsafe image
    unsafe self.view = unsafe view
    unsafe self.memory = unsafe memory
    self.descriptor = descriptor
  }
  @safe func destroy(_ c: VulkanCommands, _ device: VkDevice) {
    unsafe c.vkDestroyImageView!(device, view, nil)
    unsafe c.vkDestroyImage!(device, image, nil)
    unsafe c.vkFreeMemory!(device, memory, nil)
  }

  /// The layout the image rests in between commands: storage images in general (shaders write and read them),
  /// sampled ones ready to sample, others where the last command left them.
  var restLayout: VkImageLayout {
    if descriptor.usage.contains(.storage) { return VK_IMAGE_LAYOUT_GENERAL }
    if descriptor.usage.contains(.sampled) { return VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL }
    return layout
  }
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

extension PixelFormat {
  var vk: VkFormat {
    switch self {
    case .rgba8: VK_FORMAT_R8G8B8A8_UNORM
    case .bgra8: VK_FORMAT_B8G8R8A8_UNORM
    case .bgra8srgb: VK_FORMAT_B8G8R8A8_SRGB
    case .r8: VK_FORMAT_R8_UNORM
    }
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

  @safe init(_ c: VulkanCommands, _ device: VkDevice, storageImages: Bool) throws(GPUError) {
    let bindingCount: UInt32 = storageImages ? 3 : 2
    var bindings = unsafe [VkDescriptorSetLayoutBinding](repeating: VkDescriptorSetLayoutBinding(), count: 3)
    unsafe bindings[0].binding = 0
    unsafe bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
    unsafe bindings[0].descriptorCount = Self.textureCapacity
    unsafe bindings[0].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    unsafe bindings[1].binding = 1
    unsafe bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER
    unsafe bindings[1].descriptorCount = Self.samplerCapacity
    unsafe bindings[1].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    unsafe bindings[2].binding = 2
    unsafe bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
    unsafe bindings[2].descriptorCount = VulkanDevice.heapStorageImageSlots
    unsafe bindings[2].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    let flag = VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT.rawValue | VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT.rawValue
    var flags: [VkDescriptorBindingFlags] = [flag, flag, flag]
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

    var sizes = [VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, descriptorCount: Self.textureCapacity),
                 VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLER, descriptorCount: Self.samplerCapacity),
                 VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, descriptorCount: VulkanDevice.heapStorageImageSlots)]
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
    let handle = buffers.insert(unsafe BufferRecord(buffer: buffer!, memory: memory!))
    return unsafe GPUMemory(handle: handle, address: address, pointer: pointer, size: bytes, intent: intent)
  }

  public func free(_ memory: GPUMemory) {
    guard let record = buffers.remove(memory.handle) else { return }
    retire(.buffer(record))
  }

  /// A new handle to `memory`'s VMO, for another process (VK_FUCHSIA_external_memory); nil where the driver can't.
  public func exportHandle(_ memory: GPUMemory) -> UInt32? {
    guard let record = buffers[memory.handle],
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
    var info = unsafe VkImageCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    unsafe info.imageType = VK_IMAGE_TYPE_2D
    unsafe info.format = d.format.vk
    unsafe info.extent = VkExtent3D(width: UInt32(d.width), height: UInt32(d.height), depth: 1)
    unsafe info.mipLevels = 1
    unsafe info.arrayLayers = 1
    unsafe info.samples = VK_SAMPLE_COUNT_1_BIT
    unsafe info.tiling = VK_IMAGE_TILING_OPTIMAL
    var usage: UInt32 = 0
    if d.usage.contains(.sampled) { usage |= VK_IMAGE_USAGE_SAMPLED_BIT.rawValue }
    if d.usage.contains(.renderTarget) { usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue }
    if d.usage.contains(.storage) { usage |= VK_IMAGE_USAGE_STORAGE_BIT.rawValue }
    if d.usage.contains(.copySource) { usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue }
    if d.usage.contains(.copyDestination) { usage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue }
    unsafe info.usage = usage
    unsafe info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    var image: VkImage?
    unsafe try vkCheck(c.vkCreateImage!(device, &info, nil, &image), "vkCreateImage")
    var needs = VkMemoryRequirements()
    unsafe c.vkGetImageMemoryRequirements!(device, image, &needs)
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

    var viewInfo = unsafe VkImageViewCreateInfo()
    unsafe viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    unsafe viewInfo.image = unsafe image
    unsafe viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
    unsafe viewInfo.format = d.format.vk
    unsafe viewInfo.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0,
                                                              levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    var view: VkImageView?
    unsafe try vkCheck(c.vkCreateImageView!(device, &viewInfo, nil, &view), "vkCreateImageView")
    let handle = images.insert(unsafe ImageRecord(image: image!, view: view!, memory: memory!, descriptor: d))
    return GPUImage(handle: handle, descriptor: d)
  }

  public func destroy(_ image: GPUImage) {
    guard let record = images.remove(image.handle) else { return }
    retire(.image(record))
  }

  // MARK: The heap

  @safe public func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < Heap.textureCapacity else { throw .invalid("texture slot \(index)") }
    guard let record = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard image.usage.contains(.sampled) else { throw .invalid("a texture that isn't sampled") }
    heap.write(vk.commands, device, binding: 0, index: index, type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, view: unsafe record.view,
               sampler: nil, layout: record.restLayout)
  }

  public func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < Heap.samplerCapacity else { throw .invalid("sampler slot \(index)") }
    let c = vk.commands
    var info = unsafe VkSamplerCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    let filter = sampler.filter == .linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST
    unsafe info.magFilter = filter
    unsafe info.minFilter = filter
    let mode: VkSamplerAddressMode = switch sampler.addressMode {
    case .clampToEdge: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    case .repeat: VK_SAMPLER_ADDRESS_MODE_REPEAT
    case .mirroredRepeat: VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
    }
    unsafe info.addressModeU = mode
    unsafe info.addressModeV = mode
    unsafe info.addressModeW = mode
    var s: VkSampler?
    unsafe try vkCheck(c.vkCreateSampler!(device, &info, nil, &s), "vkCreateSampler")
    if let old = samplers[Int(index)] { retire(.sampler(old)) }
    samplers[Int(index)] = unsafe SamplerRecord(s!)
    heap.write(c, device, binding: 1, index: index, type: VK_DESCRIPTOR_TYPE_SAMPLER, view: nil, sampler: unsafe s,
               layout: VK_IMAGE_LAYOUT_UNDEFINED)
  }

  @safe public func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard limits.features.storageImages else { throw .unsupported("storage images in the heap") }
    guard index < limits.heapStorageImages else { throw .invalid("storage slot \(index)") }
    guard let record = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard image.usage.contains(.storage) else { throw .invalid("a storage image that isn't") }
    heap.write(vk.commands, device, binding: 2, index: index, type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, view: unsafe record.view,
               sampler: nil, layout: VK_IMAGE_LAYOUT_GENERAL)
  }

  // MARK: Queries

  public func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet {
    guard count > 0 else { throw .invalid("a query set of no queries") }
    switch kind {
    case .timestamp: guard limits.features.timestampQueries else { throw .unsupported("timestamp queries") }
    case .occlusion: break
    }
    var info = unsafe VkQueryPoolCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
    unsafe info.queryType = kind == .timestamp ? VK_QUERY_TYPE_TIMESTAMP : VK_QUERY_TYPE_OCCLUSION
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
    var out = [UInt64](repeating: 0, count: count)
    guard count > 0 else { return out }
    let r: VkResult = out.withUnsafeMutableBytes { bytes in
      unsafe vk.commands.vkGetQueryPoolResults!(device, record.pool, UInt32(first), UInt32(count), count * 8, bytes.baseAddress, 8,
                                                VK_QUERY_RESULT_64_BIT.rawValue)
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
