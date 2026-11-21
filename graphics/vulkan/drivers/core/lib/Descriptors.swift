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
  /// The samplers a binding was made with (pImmutableSamplers), one per element: their heap slots go into every set
  /// of this layout when it is allocated, and an update never writes them.
  let immutable: [(binding: UInt32, samplers: [SamplerObject])]
  init(layout: SetLayout, immutable: [(binding: UInt32, samplers: [SamplerObject])] = []) {
    self.layout = layout
    self.immutable = immutable
  }
  func hasImmutableSamplers(_ binding: UInt32) -> Bool { immutable.contains { $0.binding == binding } }
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

/// Whether the descriptor type is a dynamic buffer (its address gets one of the draw's dynamic offsets added).
func isDynamicDescriptor(_ t: VkDescriptorType) -> Bool {
  t == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC || t == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC
}

func descriptorKind(_ t: VkDescriptorType) -> DescriptorKind? {
  if t == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER || t == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC { return .uniformBuffer }
  if t == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER || t == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC { return .storageBuffer }
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
  var immutable: [(binding: UInt32, samplers: [SamplerObject])] = []
  for i in 0..<Int(unsafe info.pointee.bindingCount) {
    let b = unsafe info.pointee.pBindings[i]
    guard let kind = unsafe descriptorKind(b.descriptorType) else {
      say(unsafe "unsupported: a descriptor of type \(b.descriptorType.rawValue)")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    if let samplers = unsafe b.pImmutableSamplers {
      guard kind == .sampler || kind == .combinedImageSampler else { return VK_ERROR_INITIALIZATION_FAILED }
      var list: [SamplerObject] = []
      for k in 0..<Int(unsafe b.descriptorCount) {
        guard let s = unsafe Handle.get(samplers[k], SamplerObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
        list.append(s)
      }
      unsafe immutable.append((b.binding, list))
    }
    unsafe bindings.append(
      DescriptorBinding(binding: b.binding, kind: kind, count: b.descriptorCount, dynamic: isDynamicDescriptor(b.descriptorType)))
  }
  unsafe pSetLayout.pointee = Handle.make(SetLayoutObject(layout: SetLayout(bindings: bindings), immutable: immutable))
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
  var dynamic = 0
  for s in sets { dynamic += s?.layout.dynamicCount ?? 0 }
  if dynamic > RootBlock.maxDynamicOffsets {
    say("unsupported: a pipeline layout of more than \(RootBlock.maxDynamicOffsets) dynamic descriptors")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
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
    writeImmutableSamplers(s)
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
func descriptorLocation(_ layout: SetLayout, binding: UInt32, element: UInt32) -> (offset: Int, kind: DescriptorKind, binding: UInt32)? {
  guard var i = layout.bindings.firstIndex(where: { $0.binding == binding }) else { return nil }
  var e = Int(element)
  while i < layout.bindings.count && e >= Int(layout.bindings[i].count) {
    e -= Int(layout.bindings[i].count)
    i += 1
  }
  guard i < layout.bindings.count else { return nil }
  return (Int(layout.offsets[i]) + e * descriptorSize, layout.bindings[i].kind, layout.bindings[i].binding)
}

/// A set's immutable samplers' slots, into the record of a set just allocated.
func writeImmutableSamplers(_ set: DescriptorSetObject) {
  guard let base = unsafe set.pointer else { return }
  for (binding, samplers) in set.layout.immutable {
    for (k, s) in samplers.enumerated() {
      guard let at = descriptorLocation(set.layout.layout, binding: binding, element: UInt32(k)) else { continue }
      unsafe (base + at.offset).storeBytes(of: s.slot, toByteOffset: at.kind == .combinedImageSampler ? 4 : 0, as: UInt32.self)
    }
  }
}

/// One 16-byte descriptor of `kind` at `p`: a buffer's `address` and `range`, or the heap slots of a view and a
/// sampler. A sampler that isn't written leaves its slot as it was (an immutable sampler's).
func storeDescriptor(_ p: UnsafeMutableRawPointer, _ kind: DescriptorKind, address: UInt64, range: UInt64, view: ImageViewObject?,
                     sampler: SamplerObject?, keepSampler: Bool)
{
  switch kind {
  case .uniformBuffer, .storageBuffer:
    unsafe p.storeBytes(of: address, as: UInt64.self)
    unsafe p.storeBytes(of: range, toByteOffset: 8, as: UInt64.self)
  case .sampledImage:
    unsafe p.storeBytes(of: 0, as: UInt64.self)
    unsafe p.storeBytes(of: 0, toByteOffset: 8, as: UInt64.self)
    if let s = view?.textureSlot { unsafe p.storeBytes(of: s, as: UInt32.self) }
  case .storageImage:
    unsafe p.storeBytes(of: 0, as: UInt64.self)
    unsafe p.storeBytes(of: 0, toByteOffset: 8, as: UInt64.self)
    if let s = view?.storageSlot { unsafe p.storeBytes(of: s, as: UInt32.self) }
  case .sampler:
    if keepSampler { return }
    unsafe p.storeBytes(of: 0, as: UInt64.self)
    unsafe p.storeBytes(of: 0, toByteOffset: 8, as: UInt64.self)
    if let s = sampler { unsafe p.storeBytes(of: s.slot, as: UInt32.self) }
  case .combinedImageSampler:
    unsafe p.storeBytes(of: 0, toByteOffset: 8, as: UInt64.self)
    unsafe p.storeBytes(of: 0, as: UInt32.self)
    if !keepSampler { unsafe p.storeBytes(of: 0, toByteOffset: 4, as: UInt32.self) }
    if let s = view?.textureSlot { unsafe p.storeBytes(of: s, as: UInt32.self) }
    if !keepSampler, let s = sampler { unsafe p.storeBytes(of: s.slot, toByteOffset: 4, as: UInt32.self) }
  }
}

func writeDescriptor(_ set: DescriptorSetObject, _ at: Int, _ kind: DescriptorKind, binding: UInt32, buffer: VkDescriptorBufferInfo?,
                     image: VkDescriptorImageInfo?)
{
  guard let base = unsafe set.pointer else { return }
  let p = unsafe base + at
  var address: UInt64 = 0
  var range: UInt64 = 0
  if let info = unsafe buffer, let b = unsafe Handle.get(info.buffer, BufferObject.self), let a = b.address {
    address = unsafe a + info.offset
    range = unsafe info.range == ~0 ? b.size - min(info.offset, b.size) : info.range
  }
  unsafe storeDescriptor(
    p, kind, address: address, range: range, view: unsafe image.flatMap { unsafe Handle.get($0.imageView, ImageViewObject.self) },
    sampler: unsafe image.flatMap { unsafe Handle.get($0.sampler, SamplerObject.self) },
    keepSampler: set.layout.hasImmutableSamplers(binding))
}

// MARK: Descriptor buffers (VK_EXT_descriptor_buffer)
//
// A descriptor buffer is the set record itself, in memory the application owns: the layout's size and its bindings'
// offsets are SetLayout's, vkGetDescriptorEXT writes the 16-byte descriptor, and binding a buffer at an offset puts
// that address in the root block's set slot, as binding a set does.

func core_vkGetDescriptorSetLayoutSizeEXT(_ device: VkDevice?, _ layout: VkDescriptorSetLayout?, _ pLayoutSizeInBytes: UnsafeMutablePointer<VkDeviceSize>?) {
  guard let l = unsafe Handle.get(layout, SetLayoutObject.self) else { return }
  unsafe pLayoutSizeInBytes?.pointee = VkDeviceSize((l.layout.size + descriptorBufferOffsetAlignment - 1) & ~(descriptorBufferOffsetAlignment - 1))
}

func core_vkGetDescriptorSetLayoutBindingOffsetEXT(_ device: VkDevice?, _ layout: VkDescriptorSetLayout?, _ binding: UInt32,
                                                   _ pOffset: UnsafeMutablePointer<VkDeviceSize>?)
{
  guard let l = unsafe Handle.get(layout, SetLayoutObject.self), let b = l.layout.find(binding) else { return }
  unsafe pOffset?.pointee = VkDeviceSize(b.offset)
}

let descriptorBufferOffsetAlignment = descriptorSize

func core_vkGetDescriptorEXT(_ device: VkDevice?, _ pDescriptorInfo: UnsafePointer<VkDescriptorGetInfoEXT>?, _ dataSize: Int,
                             _ pDescriptor: UnsafeMutableRawPointer?)
{
  guard let info = unsafe pDescriptorInfo, let p = unsafe pDescriptor, dataSize >= descriptorSize,
    let kind = descriptorKind(unsafe info.pointee.type), !isDynamicDescriptor(unsafe info.pointee.type)
  else { return }
  unsafe p.initializeMemory(as: UInt8.self, repeating: 0, count: descriptorSize)
  var address: UInt64 = 0
  var range: UInt64 = 0
  var image: VkDescriptorImageInfo?
  var sampler: SamplerObject?
  switch kind {
  case .uniformBuffer:
    if let a = unsafe info.pointee.data.pUniformBuffer {
      address = unsafe a.pointee.address
      range = unsafe a.pointee.range
    }
  case .storageBuffer:
    if let a = unsafe info.pointee.data.pStorageBuffer {
      address = unsafe a.pointee.address
      range = unsafe a.pointee.range
    }
  case .sampledImage: unsafe image = info.pointee.data.pSampledImage?.pointee
  case .storageImage: unsafe image = info.pointee.data.pStorageImage?.pointee
  case .combinedImageSampler: unsafe image = info.pointee.data.pCombinedImageSampler?.pointee
  case .sampler: sampler = unsafe info.pointee.data.pSampler.flatMap { unsafe Handle.get($0.pointee, SamplerObject.self) }
  }
  if kind == .combinedImageSampler { sampler = unsafe image.flatMap { unsafe Handle.get($0.sampler, SamplerObject.self) } }
  unsafe storeDescriptor(
    p, kind, address: address, range: range, view: unsafe image.flatMap { unsafe Handle.get($0.imageView, ImageViewObject.self) },
    sampler: sampler, keepSampler: false)
}

func core_vkCmdBindDescriptorBuffersEXT(_ commandBuffer: VkCommandBuffer?, _ bufferCount: UInt32,
                                        _ pBindingInfos: UnsafePointer<VkDescriptorBufferBindingInfoEXT>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let infos = unsafe pBindingInfos else { return }
  if Int(bufferCount) > maxDescriptorBuffers {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "more than \(maxDescriptorBuffers) descriptor buffers")
    return
  }
  for i in 0..<Int(bufferCount) { b.descriptorBuffers[i] = unsafe infos[i].address }
}

func core_vkCmdSetDescriptorBufferOffsetsEXT(_ commandBuffer: VkCommandBuffer?, _ pipelineBindPoint: VkPipelineBindPoint,
                                             _ layout: VkPipelineLayout?, _ firstSet: UInt32, _ setCount: UInt32,
                                             _ pBufferIndices: UnsafePointer<UInt32>?, _ pOffsets: UnsafePointer<VkDeviceSize>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let indices = unsafe pBufferIndices,
    let offsets = unsafe pOffsets
  else { return }
  if Int(firstSet) + Int(setCount) > RootBlock.maxSets {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "descriptor sets past \(RootBlock.maxSets)")
    return
  }
  for i in 0..<Int(setCount) {
    let k = Int(unsafe indices[i])
    guard k < maxDescriptorBuffers else { continue }
    let address = unsafe b.descriptorBuffers[k] + offsets[i]
    if pipelineBindPoint == VK_PIPELINE_BIND_POINT_COMPUTE {
      b.computeSets[Int(firstSet) + i] = address
      b.computeDynamicOffsets[Int(firstSet) + i] = []
    } else {
      b.sets[Int(firstSet) + i] = address
      b.dynamicOffsets[Int(firstSet) + i] = []
    }
  }
}

/// The descriptor buffers one command buffer binds at once.
let maxDescriptorBuffers = 4

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
      unsafe writeDescriptor(set, at.offset, at.kind, binding: at.binding, buffer: buffer, image: image)
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
