// SPDX-License-Identifier: BSD-3-Clause

// Sparse resources on Vulkan: a sparse buffer or image is a VkBuffer or VkImage made with the sparse flags and no memory, and
// `bindSparse` is vkQueueBindSparse on the backend's queue. The pages bound are the VkDeviceMemory behind ordinary memory
// (`allocate`). A bind is ordered with the queue's submissions on the timeline: it waits for everything submitted before it
// (vkQueueBindSparse isn't ordered with command buffers otherwise), and the next submission waits for it.

import GPUCore
import Vulkan

extension SparseFlags {
  var vkBufferFlags: UInt32 {
    var f: UInt32 = 0
    if contains(.binding) { f |= VK_BUFFER_CREATE_SPARSE_BINDING_BIT.rawValue }
    if contains(.residency) { f |= VK_BUFFER_CREATE_SPARSE_RESIDENCY_BIT.rawValue }
    if contains(.aliased) { f |= VK_BUFFER_CREATE_SPARSE_ALIASED_BIT.rawValue }
    return f
  }
  var vkImageFlags: UInt32 {
    var f: UInt32 = 0
    if contains(.binding) { f |= VK_IMAGE_CREATE_SPARSE_BINDING_BIT.rawValue }
    if contains(.residency) { f |= VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT.rawValue }
    if contains(.aliased) { f |= VK_IMAGE_CREATE_SPARSE_ALIASED_BIT.rawValue }
    return f
  }
}

extension ImageAspects {
  init(vk m: UInt32) {
    var a = ImageAspects(rawValue: 0)
    if m & VK_IMAGE_ASPECT_COLOR_BIT.rawValue != 0 { a = a | .color }
    if m & VK_IMAGE_ASPECT_DEPTH_BIT.rawValue != 0 { a = a | .depth }
    if m & VK_IMAGE_ASPECT_STENCIL_BIT.rawValue != 0 { a = a | .stencil }
    self = a
  }
}

extension SparseImageFormatProperties {
  init(vk p: VkSparseImageFormatProperties) {
    self.init(aspects: ImageAspects(vk: p.aspectMask),
              blockShape: Extent3D(width: p.imageGranularity.width, height: p.imageGranularity.height, depth: p.imageGranularity.depth),
              singleMipTail: p.flags & VK_SPARSE_IMAGE_FORMAT_SINGLE_MIPTAIL_BIT.rawValue != 0,
              alignedMipSize: p.flags & VK_SPARSE_IMAGE_FORMAT_ALIGNED_MIP_SIZE_BIT.rawValue != 0,
              nonStandardBlockSize: p.flags & VK_SPARSE_IMAGE_FORMAT_NONSTANDARD_BLOCK_SIZE_BIT.rawValue != 0)
  }
}

extension VulkanDevice {
  public func makeSparseBuffer(bytes: Int, flags: SparseFlags) throws(GPUError) -> GPUMemory {
    if let e = sparseBufferError(bytes: bytes, flags: flags, limits: limits) { throw e }
    let c = vk.commands
    var info = unsafe VkBufferCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    unsafe info.flags = flags.vkBufferFlags
    unsafe info.size = VkDeviceSize(bytes)
    unsafe info.usage = VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue
      | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue
      | VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue
    unsafe info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    var buffer: VkBuffer?
    let r = unsafe c.vkCreateBuffer!(device, &info, nil, &buffer)
    guard r != VK_ERROR_OUT_OF_DEVICE_MEMORY, r != VK_ERROR_OUT_OF_HOST_MEMORY else { throw .outOfMemory("a sparse buffer of \(bytes) bytes") }
    try vkCheck(r, "vkCreateBuffer (sparse)")
    var needs = VkMemoryRequirements()
    unsafe c.vkGetBufferMemoryRequirements!(device, buffer, &needs)
    var addressInfo = unsafe VkBufferDeviceAddressInfo()
    unsafe addressInfo.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO
    unsafe addressInfo.buffer = unsafe buffer
    let address = unsafe c.vkGetBufferDeviceAddress!(device, &addressInfo)
    let handle = buffers.insert(unsafe BufferRecord(buffer: buffer!, memory: nil, sparse: needs))
    return unsafe GPUMemory(handle: handle, address: address, pointer: nil, size: bytes, intent: .device, sparse: flags)
  }

  public func sparseRequirements(_ buffer: GPUMemory) throws(GPUError) -> SparseMemoryRequirements {
    guard let r = buffers[buffer.handle] else { throw .invalid("memory that isn't this device's") }
    guard let s = r.sparse else { throw .invalid("requirements of memory that isn't a sparse buffer") }
    return SparseMemoryRequirements(size: Int(s.size), pageBytes: Int(s.alignment))
  }

  public func sparseRequirements(_ image: GPUImage) throws(GPUError) -> SparseMemoryRequirements {
    guard let r = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard let s = r.sparse else { throw .invalid("requirements of an image that isn't sparse") }
    return SparseMemoryRequirements(size: Int(s.size), pageBytes: Int(s.alignment))
  }

  public func sparseImageRequirements(_ image: GPUImage) throws(GPUError) -> [SparseImageRequirements] {
    guard let r = images[image.handle] else { throw .invalid("an image that isn't this device's") }
    guard r.sparse != nil else { throw .invalid("requirements of an image that isn't sparse") }
    let c = vk.commands
    var count: UInt32 = 0
    unsafe c.vkGetImageSparseMemoryRequirements!(device, r.image, &count, nil)
    var reqs = unsafe [VkSparseImageMemoryRequirements](repeating: VkSparseImageMemoryRequirements(), count: Int(count))
    unsafe c.vkGetImageSparseMemoryRequirements!(device, r.image, &count, &reqs)
    return reqs.prefix(Int(count)).map { q in
      unsafe SparseImageRequirements(format: SparseImageFormatProperties(vk: q.formatProperties), mipTailFirstLevel: q.imageMipTailFirstLod,
                                     mipTailSize: Int(q.imageMipTailSize), mipTailOffset: Int(q.imageMipTailOffset),
                                     mipTailStride: Int(q.imageMipTailStride))
    }
  }

  public func sparseImageFormats(_ format: PixelFormat, dimension: ImageDimension, samples: UInt32, usage: ImageUsage)
    -> [SparseImageFormatProperties]
  {
    guard limits.features.sparseBinding else { return [] }
    let c = vk.commands
    var u: UInt32 = 0
    if usage.contains(.sampled) { u |= VK_IMAGE_USAGE_SAMPLED_BIT.rawValue }
    if usage.contains(.renderTarget) { u |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue }
    if usage.contains(.depthStencilTarget) { u |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue }
    if usage.contains(.storage) { u |= VK_IMAGE_USAGE_STORAGE_BIT.rawValue }
    if usage.contains(.copySource) { u |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue }
    if usage.contains(.copyDestination) { u |= VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue }
    var count: UInt32 = 0
    unsafe c.vkGetPhysicalDeviceSparseImageFormatProperties!(physical, format.vk, dimension.vkImageType, vkSamples(samples), u,
                                                              VK_IMAGE_TILING_OPTIMAL, &count, nil)
    var props = [VkSparseImageFormatProperties](repeating: VkSparseImageFormatProperties(), count: Int(count))
    unsafe c.vkGetPhysicalDeviceSparseImageFormatProperties!(physical, format.vk, dimension.vkImageType, vkSamples(samples), u,
                                                              VK_IMAGE_TILING_OPTIMAL, &count, &props)
    return props.prefix(Int(count)).map { SparseImageFormatProperties(vk: $0) }
  }

  /// The VkDeviceMemory behind `m` (nil for nothing), held to a resource whose binds take `req`: memory of a type the resource
  /// takes, at offsets on its pages.
  func bindMemory(_ m: GPUMemory?, _ offset: Int, _ req: VkMemoryRequirements) throws(GPUError) -> VkDeviceMemory? {
    guard let m else { return nil }
    guard let r = buffers[m.handle], let memory = unsafe r.memory else { throw .invalid("memory that isn't this device's") }
    if req.memoryTypeBits & (1 << r.memoryType) == 0 { throw .unsupported("binding memory of a type the sparse resource doesn't take") }
    if offset % Int(max(req.alignment, 1)) != 0 { throw .invalid("a sparse bind from memory off its pages") }
    return unsafe memory
  }
}

extension VulkanDevice {
  public func bindSparse(_ bindings: SparseBindings, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = bindings.validate(limits: limits) { throw e }
    if let e = rule.check(wait: wait, signal: signal) { throw e }
    reclaim()
    let c = vk.commands
    // Each resource's binds, as Vulkan takes them: one info for each bind (Vulkan allows several binds of a resource).
    var bufferBinds: [VkSparseMemoryBind] = unsafe []
    var bufferHandles: [VkBuffer?] = unsafe []
    for b in bindings.buffers {
      guard let r = buffers[b.buffer.handle], let req = r.sparse else { throw .invalid("memory that isn't this device's sparse buffer") }
      let page = Int(max(req.alignment, 1))
      if b.offset % page != 0 || (b.size % page != 0 && UInt64(b.offset + b.size) != req.size) || UInt64(b.offset + b.size) > req.size {
        throw .invalid("a sparse bind off the buffer's pages of \(page) bytes")
      }
      let memory = try unsafe bindMemory(b.memory, b.memoryOffset, req)
      unsafe bufferBinds.append(VkSparseMemoryBind(resourceOffset: VkDeviceSize(b.offset), size: VkDeviceSize(b.size), memory: memory,
                                                   memoryOffset: VkDeviceSize(b.memoryOffset), flags: 0))
      unsafe bufferHandles.append(r.buffer)
    }
    var opaqueBinds: [VkSparseMemoryBind] = unsafe []
    var opaqueHandles: [VkImage?] = unsafe []
    for b in bindings.opaque {
      guard let r = images[b.image.handle], let req = r.sparse else { throw .invalid("an image that isn't this device's sparse image") }
      let page = Int(max(req.alignment, 1))
      if b.offset % page != 0 || (b.size % page != 0 && UInt64(b.offset + b.size) != req.size) {
        throw .invalid("a sparse bind off the image's pages of \(page) bytes")
      }
      let memory = try unsafe bindMemory(b.memory, b.memoryOffset, req)
      unsafe opaqueBinds.append(VkSparseMemoryBind(resourceOffset: VkDeviceSize(b.offset), size: VkDeviceSize(b.size), memory: memory,
                                                   memoryOffset: VkDeviceSize(b.memoryOffset),
                                                   flags: b.metadata ? VK_SPARSE_MEMORY_BIND_METADATA_BIT.rawValue : 0))
      unsafe opaqueHandles.append(r.image)
    }
    var imageBinds: [VkSparseImageMemoryBind] = unsafe []
    var imageHandles: [VkImage?] = unsafe []
    for b in bindings.images {
      guard let r = images[b.image.handle], let req = r.sparse else { throw .invalid("an image that isn't this device's sparse image") }
      let memory = try unsafe bindMemory(b.memory, b.memoryOffset, req)
      let sub = VkImageSubresource(aspectMask: vkAspects(b.aspects), mipLevel: b.mip, arrayLayer: b.layer)
      unsafe imageBinds.append(VkSparseImageMemoryBind(subresource: sub, offset: VkOffset3D(x: b.offset.x, y: b.offset.y, z: b.offset.z),
                                                       extent: VkExtent3D(width: b.extent.width, height: b.extent.height,
                                                                          depth: b.extent.depth),
                                                       memory: memory, memoryOffset: VkDeviceSize(b.memoryOffset), flags: 0))
      unsafe imageHandles.append(r.image)
    }
    // The bind waits for everything submitted before it, and for `wait`.
    var waitValue = max(wait, rule.lastSignalled)
    var signalValue = signal
    var semaphore: VkSemaphore? = timeline
    let r: VkResult = unsafe bufferBinds.withUnsafeBufferPointer { bb in
      unsafe opaqueBinds.withUnsafeBufferPointer { ob in
        unsafe imageBinds.withUnsafeBufferPointer { ib in
          var bufferInfos = unsafe (0..<bb.count).map { i in
            unsafe VkSparseBufferMemoryBindInfo(buffer: bufferHandles[i], bindCount: 1, pBinds: bb.baseAddress! + i)
          }
          var opaqueInfos = unsafe (0..<ob.count).map { i in
            unsafe VkSparseImageOpaqueMemoryBindInfo(image: opaqueHandles[i], bindCount: 1, pBinds: ob.baseAddress! + i)
          }
          var imageInfos = unsafe (0..<ib.count).map { i in
            unsafe VkSparseImageMemoryBindInfo(image: imageHandles[i], bindCount: 1, pBinds: ib.baseAddress! + i)
          }
          return unsafe withUnsafePointer(to: &signalValue) { sv in
            unsafe withUnsafePointer(to: &waitValue) { wv in
              var timelineInfo = unsafe VkTimelineSemaphoreSubmitInfo()
              unsafe timelineInfo.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
              unsafe timelineInfo.signalSemaphoreValueCount = 1
              unsafe timelineInfo.pSignalSemaphoreValues = unsafe sv
              unsafe timelineInfo.waitSemaphoreValueCount = waitValue == 0 ? 0 : 1
              unsafe timelineInfo.pWaitSemaphoreValues = waitValue == 0 ? nil : unsafe wv
              return unsafe withUnsafePointer(to: &timelineInfo) { tp in
                unsafe withUnsafePointer(to: &semaphore) { sp in
                  unsafe bufferInfos.withUnsafeMutableBufferPointer { bi in
                    unsafe opaqueInfos.withUnsafeMutableBufferPointer { oi in
                      unsafe imageInfos.withUnsafeMutableBufferPointer { ii in
                        var info = unsafe VkBindSparseInfo()
                        unsafe info.sType = VK_STRUCTURE_TYPE_BIND_SPARSE_INFO
                        unsafe info.pNext = unsafe UnsafeRawPointer(tp)
                        unsafe info.waitSemaphoreCount = waitValue == 0 ? 0 : 1
                        unsafe info.pWaitSemaphores = waitValue == 0 ? nil : unsafe sp
                        unsafe info.bufferBindCount = UInt32(bi.count)
                        unsafe info.pBufferBinds = bi.isEmpty ? nil : UnsafePointer(bi.baseAddress)
                        unsafe info.imageOpaqueBindCount = UInt32(oi.count)
                        unsafe info.pImageOpaqueBinds = oi.isEmpty ? nil : UnsafePointer(oi.baseAddress)
                        unsafe info.imageBindCount = UInt32(ii.count)
                        unsafe info.pImageBinds = ii.isEmpty ? nil : UnsafePointer(ii.baseAddress)
                        unsafe info.signalSemaphoreCount = 1
                        unsafe info.pSignalSemaphores = unsafe sp
                        return unsafe c.vkQueueBindSparse!(queue, 1, &info, nil)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    try vkCheck(r, "vkQueueBindSparse")
    _ = rule.accept(wait: wait, signal: signal)
    // The next submission waits for the bind.
    sparseBound = signal
  }
}
