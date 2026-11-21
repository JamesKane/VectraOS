// SPDX-License-Identifier: BSD-3-Clause

// Descriptor set layouts, pipeline layouts, pools and sets (D174 step 5, parts 2 and 3). A set is a record in its
// pool's `.upload` memory: binding `b`'s element `i` is at the layout's offset for `b`, plus 16 * `i`; a buffer's
// descriptor is its address and range, an image's or a sampler's the heap slot its view or sampler took. The
// record is read when the work runs, as Vulkan says.

import GPUCore
import TDVulkan
import VulkanLowering

final class SetLayoutObject: CoreObject {
  let layout: SetLayout
  init(layout: SetLayout) { self.layout = layout }
  /// What a set of this layout takes in a pool: at least 16 bytes, so a set always has an address.
  var recordBytes: Int { max(16, layout.size) }
}

final class PipelineLayoutObject: CoreObject {
  let sets: [SetLayoutObject?]
  let pushConstantBytes: Int
  init(sets: [SetLayoutObject?], pushConstantBytes: Int) {
    self.sets = sets
    self.pushConstantBytes = pushConstantBytes
  }
  var lowering: LoweringLayout {
    LoweringLayout(sets: sets.map { $0?.layout }, pushConstantBytes: pushConstantBytes)
  }
}

func descriptorKind(_ t: VkDescriptorType) -> DescriptorKind? {
  if t == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER { return .uniformBuffer }
  if t == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER { return .storageBuffer }
  if t == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE { return .sampledImage }
  if t == VK_DESCRIPTOR_TYPE_SAMPLER { return .sampler }
  if t == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER { return .combinedImageSampler }
  if t == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE { return .storageImage }
  return nil
}

func core_vkCreateDescriptorSetLayout(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkDescriptorSetLayoutCreateInfo>?,
                                      _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                      _ pSetLayout: UnsafeMutablePointer<VkDescriptorSetLayout?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let pSetLayout = unsafe pSetLayout else { return VK_ERROR_INITIALIZATION_FAILED }
  var bindings: [DescriptorBinding] = []
  for i in 0..<Int(unsafe info.pointee.bindingCount) {
    let b = unsafe info.pointee.pBindings[i]
    guard let kind = unsafe descriptorKind(b.descriptorType) else {
      say(unsafe "unsupported: a descriptor of type \(b.descriptorType.rawValue)")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    if unsafe b.pImmutableSamplers != nil {
      say("unsupported: immutable samplers")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    unsafe bindings.append(DescriptorBinding(binding: b.binding, kind: kind, count: b.descriptorCount))
  }
  unsafe pSetLayout.pointee = Handle.make(SetLayoutObject(layout: SetLayout(bindings: bindings)))
  return VK_SUCCESS
}

func core_vkDestroyDescriptorSetLayout(_ device: VkDevice?, _ descriptorSetLayout: VkDescriptorSetLayout?,
                                       _ pAllocator: UnsafePointer<VkAllocationCallbacks>?)
{
  unsafe Handle.destroy(descriptorSetLayout)
}

func core_vkCreatePipelineLayout(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkPipelineLayoutCreateInfo>?,
                                 _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                 _ pPipelineLayout: UnsafeMutablePointer<VkPipelineLayout?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pPipelineLayout else { return VK_ERROR_INITIALIZATION_FAILED }
  let n = Int(unsafe info.pointee.setLayoutCount)
  if n > RootBlock.maxSets {
    say("unsupported: a pipeline layout of more than \(RootBlock.maxSets) sets")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  var sets: [SetLayoutObject?] = []
  for i in 0..<n { sets.append(unsafe Handle.get(info.pointee.pSetLayouts[i], SetLayoutObject.self)) }
  var push = 0
  for i in 0..<Int(unsafe info.pointee.pushConstantRangeCount) {
    let r = unsafe info.pointee.pPushConstantRanges[i]
    push = max(push, Int(r.offset) + Int(r.size))
  }
  if push > RootBlock.maxPushConstantBytes {
    say("unsupported: push constants of \(push) bytes")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  unsafe out.pointee = Handle.make(PipelineLayoutObject(sets: sets, pushConstantBytes: push))
  return VK_SUCCESS
}

func core_vkDestroyPipelineLayout(_ device: VkDevice?, _ pipelineLayout: VkPipelineLayout?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(pipelineLayout)
}

// MARK: Pools and sets

@safe final class DescriptorSetObject: CoreObject {
  let layout: SetLayoutObject
  let pool: DescriptorPoolObject
  let offset: Int
  let bytes: Int
  var handle: OpaquePointer?
  init(layout: SetLayoutObject, pool: DescriptorPoolObject, offset: Int, bytes: Int) {
    self.layout = layout
    self.pool = pool
    self.offset = offset
    self.bytes = bytes
  }
  var address: UInt64 { pool.memory.address + UInt64(offset) }
  var pointer: UnsafeMutableRawPointer? { unsafe pool.memory.pointer.map { unsafe $0 + offset } }
}

final class DescriptorPoolObject: CoreObject {
  let memory: GPUMemory
  let device: DeviceObject
  let canFree: Bool
  let maxSets: Int
  var bump = 0
  var holes: [(offset: Int, bytes: Int)] = []
  var sets: [DescriptorSetObject] = []
  init(memory: GPUMemory, device: DeviceObject, canFree: Bool, maxSets: Int) {
    self.memory = memory
    self.device = device
    self.canFree = canFree
    self.maxSets = maxSets
  }

  /// A record of `bytes`: a hole that was freed, or the next of the pool.
  func take(_ bytes: Int) -> Int? {
    for i in holes.indices where holes[i].bytes >= bytes {
      let at = holes[i].offset
      if holes[i].bytes == bytes { holes.remove(at: i) } else {
        holes[i].offset += bytes
        holes[i].bytes -= bytes
      }
      return at
    }
    if bump + bytes > memory.size { return nil }
    defer { bump += bytes }
    return bump
  }

  func release(_ s: DescriptorSetObject) {
    if let i = sets.firstIndex(where: { $0 === s }) { sets.remove(at: i) }
    holes.append((s.offset, s.bytes))
    unsafe Handle.destroy(s.handle)
    unsafe s.handle = nil
  }

  func releaseAll() {
    for s in sets {
      unsafe Handle.destroy(s.handle)
      unsafe s.handle = nil
    }
    sets = []
    holes = []
    bump = 0
  }
}

func core_vkCreateDescriptorPool(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkDescriptorPoolCreateInfo>?,
                                 _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                 _ pDescriptorPool: UnsafeMutablePointer<VkDescriptorPool?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let out = unsafe pDescriptorPool else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  var descriptors = 0
  for i in 0..<Int(unsafe info.pointee.poolSizeCount) {
    let s = unsafe info.pointee.pPoolSizes[i]
    if descriptorKind(s.type) == nil {
      say("unsupported: a descriptor pool of type \(s.type.rawValue)")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    descriptors += Int(s.descriptorCount)
  }
  let maxSets = Int(unsafe info.pointee.maxSets)
  // A record per set at least, and every descriptor 16 bytes.
  let bytes = (descriptors + maxSets) * descriptorSize
  do throws(GPUError) {
    let memory = try d.gpu.allocate(.upload, bytes: max(bytes, 16))
    let canFree = unsafe info.pointee.flags & VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT.rawValue != 0
    unsafe out.pointee = Handle.make(DescriptorPoolObject(memory: memory, device: d, canFree: canFree, maxSets: maxSets))
  } catch { return vkResult(error) }
  return VK_SUCCESS
}

func core_vkDestroyDescriptorPool(_ device: VkDevice?, _ descriptorPool: VkDescriptorPool?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let p = unsafe Handle.get(descriptorPool, DescriptorPoolObject.self) else { return }
  p.releaseAll()
  p.device.gpu.free(p.memory)
  unsafe Handle.destroy(descriptorPool)
}

func core_vkResetDescriptorPool(_ device: VkDevice?, _ descriptorPool: VkDescriptorPool?, _ flags: VkDescriptorPoolResetFlags) -> VkResult {
  guard let p = unsafe Handle.get(descriptorPool, DescriptorPoolObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  p.releaseAll()
  return VK_SUCCESS
}

func core_vkAllocateDescriptorSets(_ device: VkDevice?, _ pAllocateInfo: UnsafePointer<VkDescriptorSetAllocateInfo>?,
                                   _ pDescriptorSets: UnsafeMutablePointer<VkDescriptorSet?>?) -> VkResult
{
  guard let info = unsafe pAllocateInfo, let out = unsafe pDescriptorSets,
    let pool = unsafe Handle.get(info.pointee.descriptorPool, DescriptorPoolObject.self)
  else { return VK_ERROR_INITIALIZATION_FAILED }
  let n = Int(unsafe info.pointee.descriptorSetCount)
  var made: [DescriptorSetObject] = []
  var failure: VkResult?
  for i in 0..<n {
    guard let layout = unsafe Handle.get(info.pointee.pSetLayouts[i], SetLayoutObject.self) else {
      failure = VK_ERROR_INITIALIZATION_FAILED
      break
    }
    let bytes = (layout.recordBytes + 15) & ~15
    guard pool.sets.count + made.count < pool.maxSets, let at = pool.take(bytes) else {
      failure = VK_ERROR_OUT_OF_POOL_MEMORY
      break
    }
    let s = DescriptorSetObject(layout: layout, pool: pool, offset: at, bytes: bytes)
    if let p = unsafe s.pointer { unsafe p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes) }
    made.append(s)
    // The set is live as soon as it has its place, so a failure below gives it back.
    pool.sets.append(s)
  }
  if let failure {
    for s in made { pool.release(s) }
    for i in 0..<n { unsafe out[i] = nil }
    return failure
  }
  for i in 0..<n {
    let h = unsafe Handle.make(made[i])
    unsafe made[i].handle = unsafe h
    unsafe out[i] = h
  }
  return VK_SUCCESS
}

func core_vkFreeDescriptorSets(_ device: VkDevice?, _ descriptorPool: VkDescriptorPool?, _ descriptorSetCount: UInt32,
                               _ pDescriptorSets: UnsafePointer<VkDescriptorSet?>?) -> VkResult
{
  guard let pool = unsafe Handle.get(descriptorPool, DescriptorPoolObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  guard pool.canFree else { return VK_ERROR_FEATURE_NOT_PRESENT }
  for i in 0..<Int(descriptorSetCount) {
    if let s = unsafe Handle.get(pDescriptorSets![i], DescriptorSetObject.self) { pool.release(s) }
  }
  return VK_SUCCESS
}

// MARK: Writing descriptors

/// Where binding `binding`'s element `element` is in `set`'s record, and what it is. An element past its binding's
/// count carries on into the next binding, as the specification says.
func descriptorLocation(_ layout: SetLayout, binding: UInt32, element: UInt32) -> (offset: Int, kind: DescriptorKind)? {
  guard var i = layout.bindings.firstIndex(where: { $0.binding == binding }) else { return nil }
  var e = Int(element)
  while i < layout.bindings.count && e >= Int(layout.bindings[i].count) {
    e -= Int(layout.bindings[i].count)
    i += 1
  }
  guard i < layout.bindings.count else { return nil }
  return (Int(layout.offsets[i]) + e * descriptorSize, layout.bindings[i].kind)
}

func writeDescriptor(_ set: DescriptorSetObject, _ at: Int, _ kind: DescriptorKind, buffer: VkDescriptorBufferInfo?,
                     image: VkDescriptorImageInfo?)
{
  guard let base = unsafe set.pointer else { return }
  let p = unsafe base + at
  unsafe p.storeBytes(of: 0, as: UInt64.self)
  unsafe p.storeBytes(of: 0, toByteOffset: 8, as: UInt64.self)
  switch kind {
  case .uniformBuffer, .storageBuffer:
    guard let info = unsafe buffer, let b = unsafe Handle.get(info.buffer, BufferObject.self), let address = b.address else { return }
    let range = unsafe info.range == ~0 ? b.size - min(info.offset, b.size) : info.range
    unsafe p.storeBytes(of: address + info.offset, as: UInt64.self)
    unsafe p.storeBytes(of: range, toByteOffset: 8, as: UInt64.self)
  case .sampledImage:
    if let v = unsafe image.flatMap({ unsafe Handle.get($0.imageView, ImageViewObject.self) }), let s = v.textureSlot {
      unsafe p.storeBytes(of: s, as: UInt32.self)
    }
  case .storageImage:
    if let v = unsafe image.flatMap({ unsafe Handle.get($0.imageView, ImageViewObject.self) }), let s = v.storageSlot {
      unsafe p.storeBytes(of: s, as: UInt32.self)
    }
  case .sampler:
    if let s = unsafe image.flatMap({ unsafe Handle.get($0.sampler, SamplerObject.self) }) { unsafe p.storeBytes(of: s.slot, as: UInt32.self) }
  case .combinedImageSampler:
    if let v = unsafe image.flatMap({ unsafe Handle.get($0.imageView, ImageViewObject.self) }), let s = v.textureSlot {
      unsafe p.storeBytes(of: s, as: UInt32.self)
    }
    if let s = unsafe image.flatMap({ unsafe Handle.get($0.sampler, SamplerObject.self) }) {
      unsafe p.storeBytes(of: s.slot, toByteOffset: 4, as: UInt32.self)
    }
  }
}

func core_vkUpdateDescriptorSets(_ device: VkDevice?, _ descriptorWriteCount: UInt32, _ pDescriptorWrites: UnsafePointer<VkWriteDescriptorSet>?,
                                 _ descriptorCopyCount: UInt32, _ pDescriptorCopies: UnsafePointer<VkCopyDescriptorSet>?)
{
  for i in 0..<Int(descriptorWriteCount) {
    let w = unsafe pDescriptorWrites![i]
    guard let set = unsafe Handle.get(w.dstSet, DescriptorSetObject.self) else { continue }
    for k in unsafe 0..<Int(w.descriptorCount) {
      guard let at = unsafe descriptorLocation(set.layout.layout, binding: w.dstBinding, element: w.dstArrayElement + UInt32(k)) else {
        break
      }
      let buffer: VkDescriptorBufferInfo? = unsafe w.pBufferInfo.map { unsafe $0[k] }
      let image: VkDescriptorImageInfo? = unsafe w.pImageInfo.map { unsafe $0[k] }
      unsafe writeDescriptor(set, at.offset, at.kind, buffer: buffer, image: image)
    }
  }
  for i in 0..<Int(descriptorCopyCount) {
    let c = unsafe pDescriptorCopies![i]
    guard let from = unsafe Handle.get(c.srcSet, DescriptorSetObject.self), let to = unsafe Handle.get(c.dstSet, DescriptorSetObject.self),
      let source = unsafe from.pointer, let target = unsafe to.pointer
    else { continue }
    for k in unsafe 0..<Int(c.descriptorCount) {
      guard let a = unsafe descriptorLocation(from.layout.layout, binding: c.srcBinding, element: c.srcArrayElement + UInt32(k)),
        let b = unsafe descriptorLocation(to.layout.layout, binding: c.dstBinding, element: c.dstArrayElement + UInt32(k))
      else { break }
      unsafe (target + b.offset).copyMemory(from: source + a.offset, byteCount: descriptorSize)
    }
  }
}
