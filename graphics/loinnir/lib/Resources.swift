// SPDX-License-Identifier: BSD-3-Clause

// Loinnir's resources (sdk.md §5): memory reached by GPU address, and
// textures as indices into one global bindless heap. There are no vertex
// buffers or descriptor sets to manage: a draw gets one root pointer, and
// shaders read everything else through it.


/// Where an allocation lives.
public enum MemoryKind: Sendable {
  /// CPU-written, GPU-read: per-frame data, uploads.
  case upload
  /// GPU-only: the fastest for the GPU.
  case device
  /// GPU-written, CPU-read: results to inspect.
  case readback
}

/// GPU memory, with its address for shaders and, where the CPU can map it,
/// a pointer.
@safe public struct GPUAllocation: @unchecked Sendable {
  public let address: UInt64
  public let pointer: UnsafeMutableRawPointer?
  public let size: Int
  let buffer: VkBuffer
  let memory: VkDeviceMemory
}

public enum TextureFormat: Sendable {
  case rgba8, bgra8, r8
  var vk: VkFormat {
    switch self {
    case .rgba8: VK_FORMAT_R8G8B8A8_UNORM
    case .bgra8: VK_FORMAT_B8G8R8A8_UNORM
    case .r8: VK_FORMAT_R8_UNORM
    }
  }
  var bytesPerPixel: Int { self == .r8 ? 1 : 4 }
}

/// A texture: `index` is its place in the heap, which shaders use.
public struct Texture: Hashable, Sendable {
  public let index: UInt32
  public let width: Int32
  public let height: Int32
  public let format: TextureFormat
}

/// An image Loinnir owns, and its current layout: an opaque handle outside
/// Loinnir (a window's backbuffer is one).
@safe public final class ImageRecord {
  let image: VkImage
  let view: VkImageView
  let memory: VkDeviceMemory?
  let width: Int32, height: Int32
  let format: VkFormat
  var layout = VK_IMAGE_LAYOUT_UNDEFINED
  init(image: VkImage, view: VkImageView, memory: VkDeviceMemory?, width: Int32, height: Int32, format: VkFormat) {
    unsafe self.image = unsafe image
    unsafe self.view = unsafe view
    unsafe self.memory = unsafe memory
    self.width = width
    self.height = height
    self.format = format
  }
}

/// The global heap: one descriptor set holding every texture (binding 0,
/// an array of sampled images) and a linear sampler (binding 1).
@safe final class Heap {
  static let capacity: UInt32 = 4096
  let layout: VkDescriptorSetLayout
  let pool: VkDescriptorPool
  let set: VkDescriptorSet
  let sampler: VkSampler
  var next: UInt32 = 0
  /// Indices freed (their textures gone), used again first.
  var free: [UInt32] = []

  init(_ gpu: GPUContext) throws(LoinnirError) {
    let c = gpu.vk.commands
    var samplerInfo = unsafe VkSamplerCreateInfo()
    unsafe samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    unsafe samplerInfo.magFilter = VK_FILTER_LINEAR
    unsafe samplerInfo.minFilter = VK_FILTER_LINEAR
    unsafe samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    unsafe samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    unsafe samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    var s: VkSampler?
    unsafe try check(c.vkCreateSampler!(gpu.device, &samplerInfo, nil, &s), "vkCreateSampler")
    unsafe sampler = unsafe s!

    var bindings = unsafe [VkDescriptorSetLayoutBinding](repeating: VkDescriptorSetLayoutBinding(), count: 2)
    unsafe bindings[0].binding = 0
    unsafe bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
    unsafe bindings[0].descriptorCount = Self.capacity
    unsafe bindings[0].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    unsafe bindings[1].binding = 1
    unsafe bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER
    unsafe bindings[1].descriptorCount = 1
    unsafe bindings[1].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    var flags: [VkDescriptorBindingFlags] = [
      VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT.rawValue | VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT.rawValue, 0,
    ]
    var l: VkDescriptorSetLayout?
    var r: VkResult = flags.withUnsafeMutableBufferPointer { fp in
      var flagInfo = unsafe VkDescriptorSetLayoutBindingFlagsCreateInfo()
      unsafe flagInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
      unsafe flagInfo.bindingCount = 2
      unsafe flagInfo.pBindingFlags = unsafe UnsafePointer(fp.baseAddress)
      return withUnsafePointer(to: &flagInfo) { fip in
        bindings.withUnsafeBufferPointer { bp in
          var info = unsafe VkDescriptorSetLayoutCreateInfo()
          unsafe info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
          unsafe info.pNext = unsafe UnsafeRawPointer(fip)
          unsafe info.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT.rawValue
          unsafe info.bindingCount = 2
          unsafe info.pBindings = bp.baseAddress
          return unsafe c.vkCreateDescriptorSetLayout!(gpu.device, &info, nil, &l)
        }
      }
    }
    try check(r, "vkCreateDescriptorSetLayout")
    unsafe layout = unsafe l!

    var sizes = [VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, descriptorCount: Self.capacity),
                 VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLER, descriptorCount: 1)]
    var p: VkDescriptorPool?
    r = sizes.withUnsafeMutableBufferPointer { sp in
      var info = unsafe VkDescriptorPoolCreateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
      unsafe info.flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT.rawValue
      unsafe info.maxSets = 1
      unsafe info.poolSizeCount = 2
      unsafe info.pPoolSizes = unsafe UnsafePointer(sp.baseAddress)
      return unsafe c.vkCreateDescriptorPool!(gpu.device, &info, nil, &p)
    }
    try check(r, "vkCreateDescriptorPool")
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
      return unsafe c.vkAllocateDescriptorSets!(gpu.device, &info, &ds)
    }
    try check(r, "vkAllocateDescriptorSets")
    unsafe set = unsafe ds!

    var imageInfo = unsafe VkDescriptorImageInfo()
    unsafe imageInfo.sampler = unsafe s
    withUnsafePointer(to: &imageInfo) { ip in
      var write = unsafe VkWriteDescriptorSet()
      unsafe write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      unsafe write.dstSet = unsafe ds
      unsafe write.dstBinding = 1
      unsafe write.descriptorCount = 1
      unsafe write.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER
      unsafe write.pImageInfo = unsafe ip
      unsafe c.vkUpdateDescriptorSets!(gpu.device, 1, &write, 0, nil)
    }
  }

  /// Puts `view` at the next free index; returns it.
  func add(_ gpu: GPUContext, _ view: VkImageView) -> UInt32? {
    let index: UInt32
    if let reused = free.popLast() {
      index = reused
    } else {
      guard next < Self.capacity else { return nil }
      index = next
      next += 1
    }
    var imageInfo = unsafe VkDescriptorImageInfo()
    unsafe imageInfo.imageView = unsafe view
    unsafe imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    withUnsafePointer(to: &imageInfo) { ip in
      var write = unsafe VkWriteDescriptorSet()
      unsafe write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      unsafe write.dstSet = unsafe set
      unsafe write.dstBinding = 0
      unsafe write.dstArrayElement = index
      unsafe write.descriptorCount = 1
      unsafe write.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
      unsafe write.pImageInfo = unsafe ip
      unsafe gpu.vk.commands.vkUpdateDescriptorSets!(gpu.device, 1, &write, 0, nil)
    }
    return index
  }

  func destroy(_ gpu: GPUContext) {
    let c = gpu.vk.commands
    unsafe c.vkDestroyDescriptorPool!(gpu.device, pool, nil)
    unsafe c.vkDestroyDescriptorSetLayout!(gpu.device, layout, nil)
    unsafe c.vkDestroySampler!(gpu.device, sampler, nil)
  }
}

extension Loinnir {
  /// Frees a texture once the GPU is past the work submitted so far; its
  /// heap index can then be another's.
  public func free(_ texture: Texture) {
    guard let record = textures[texture.index] else { return }
    textures[texture.index] = nil
    retired.append((timelineValue, .texture(record, texture.index)))
    reclaim()
  }

  /// Frees memory once the GPU is past the work submitted so far.
  public func free(_ allocation: GPUAllocation) {
    allocations.removeAll { unsafe $0.buffer == allocation.buffer }
    retired.append((timelineValue, .allocation(allocation)))
    reclaim()
  }

  /// Destroys what was freed before the GPU's timeline reached `done`.
  func destroyRetired(_ done: UInt64) {
    let c = gpu.vk.commands
    retired.removeAll { r in
      guard r.value <= done else { return false }
      switch r.thing {
      case .texture(let t, let index):
        unsafe c.vkDestroyImageView!(gpu.device, t.view, nil)
        unsafe c.vkDestroyImage!(gpu.device, t.image, nil)
        if let m = unsafe t.memory { unsafe c.vkFreeMemory!(gpu.device, m, nil) }
        heap.free.append(index)
      case .allocation(let a):
        unsafe c.vkDestroyBuffer!(gpu.device, a.buffer, nil)
        unsafe c.vkFreeMemory!(gpu.device, a.memory, nil)
      }
      return true
    }
  }

  /// `bytes` of memory of `kind`, with its GPU address.
  public func alloc(_ kind: MemoryKind, bytes: Int) throws(LoinnirError) -> GPUAllocation {
    let c = gpu.vk.commands
    var info = unsafe VkBufferCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    unsafe info.size = VkDeviceSize(max(bytes, 16))
    unsafe info.usage = VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue
      | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue
    unsafe info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    var buffer: VkBuffer?
    unsafe try wrap(c.vkCreateBuffer!(gpu.device, &info, nil, &buffer), "vkCreateBuffer")
    var needs = VkMemoryRequirements()
    unsafe c.vkGetBufferMemoryRequirements!(gpu.device, buffer, &needs)
    let wanted: UInt32 = switch kind {
    case .upload: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
    case .readback: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue
    case .device: VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue
    }
    guard let type = memoryType(needs.memoryTypeBits, wanted)
      ?? (kind == .readback ? memoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue) : nil)
    else {
      unsafe c.vkDestroyBuffer!(gpu.device, buffer, nil)
      throw .unsupported("no memory type for \(kind)")
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
      return unsafe c.vkAllocateMemory!(gpu.device, &a, nil, &memory)
    }
    try wrap(r, "vkAllocateMemory")
    _ = unsafe c.vkBindBufferMemory!(gpu.device, buffer, memory, 0)
    var pointer: UnsafeMutableRawPointer?
    if kind != .device { _ = unsafe c.vkMapMemory!(gpu.device, memory, 0, VkDeviceSize(VK_WHOLE_SIZE), 0, &pointer) }
    var addressInfo = unsafe VkBufferDeviceAddressInfo()
    unsafe addressInfo.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO
    unsafe addressInfo.buffer = unsafe buffer
    let address = unsafe c.vkGetBufferDeviceAddress!(gpu.device, &addressInfo)
    let a = unsafe GPUAllocation(address: address, pointer: pointer, size: bytes, buffer: buffer!, memory: memory!)
    allocations.append(a)
    return a
  }

  /// A texture of `format`, in the heap. With `renderTarget`, it can also
  /// be rendered into (`render(to: .texture(t))`).
  public func texture(_ format: TextureFormat, width: Int32, height: Int32, renderTarget: Bool = false)
    throws(LoinnirError) -> Texture
  {
    let c = gpu.vk.commands
    var info = unsafe VkImageCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    unsafe info.imageType = VK_IMAGE_TYPE_2D
    unsafe info.format = format.vk
    unsafe info.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
    unsafe info.mipLevels = 1
    unsafe info.arrayLayers = 1
    unsafe info.samples = VK_SAMPLE_COUNT_1_BIT
    unsafe info.tiling = VK_IMAGE_TILING_OPTIMAL
    unsafe info.usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
      | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | (renderTarget ? VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue : 0)
    unsafe info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    var image: VkImage?
    unsafe try wrap(c.vkCreateImage!(gpu.device, &info, nil, &image), "vkCreateImage")
    var needs = VkMemoryRequirements()
    unsafe c.vkGetImageMemoryRequirements!(gpu.device, image, &needs)
    guard let type = memoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue) else {
      throw .unsupported("no device-local memory for a texture")
    }
    var a = unsafe VkMemoryAllocateInfo()
    unsafe a.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    unsafe a.allocationSize = needs.size
    unsafe a.memoryTypeIndex = type
    var memory: VkDeviceMemory?
    unsafe try wrap(c.vkAllocateMemory!(gpu.device, &a, nil, &memory), "vkAllocateMemory")
    _ = unsafe c.vkBindImageMemory!(gpu.device, image, memory, 0)
    let view = unsafe try makeView(image!, format.vk)
    guard let index = unsafe heap.add(gpu, view) else { throw .unsupported("the texture heap is full") }
    textures[index] = unsafe ImageRecord(image: image!, view: view, memory: memory, width: width, height: height, format: format.vk)
    return Texture(index: index, width: width, height: height, format: format)
  }

  func makeView(_ image: VkImage, _ format: VkFormat) throws(LoinnirError) -> VkImageView {
    var info = unsafe VkImageViewCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    unsafe info.image = unsafe image
    unsafe info.viewType = VK_IMAGE_VIEW_TYPE_2D
    unsafe info.format = format
    unsafe info.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0,
                                                    levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    var view: VkImageView?
    unsafe try wrap(gpu.vk.commands.vkCreateImageView!(gpu.device, &info, nil, &view), "vkCreateImageView")
    return unsafe view!
  }

  func memoryType(_ bits: UInt32, _ wanted: UInt32) -> UInt32? {
    var props = VkPhysicalDeviceMemoryProperties()
    unsafe gpu.vk.commands.vkGetPhysicalDeviceMemoryProperties!(gpu.physical, &props)
    let types = withUnsafeBytes(of: props.memoryTypes) { unsafe Array($0.bindMemory(to: VkMemoryType.self)) }
    return (0..<props.memoryTypeCount).first { bits & (1 << $0) != 0 && types[Int($0)].propertyFlags & wanted == wanted }
  }

  func wrap(_ r: VkResult, _ what: String) throws(LoinnirError) {
    guard r == VK_SUCCESS else { throw .vulkan(.failed(what, r)) }
  }
}

/// Throws a Vulkan failure as a Loinnir error.
func check(_ r: VkResult, _ what: String) throws(LoinnirError) {
  guard r == VK_SUCCESS else { throw .vulkan(.failed(what, r)) }
}
