// SPDX-License-Identifier: BSD-3-Clause

// Fences, semaphores and submission (D174 step 5, part 3). The device has one timeline, and every fence and
// semaphore is a value on it:
//  - a submission waits for the greatest device value among its waits and signals the next;
//  - a fence is the device value of the submission that signalled it;
//  - a binary semaphore is the device value that signalled it (0: not signalled);
//  - a timeline semaphore keeps the device value each of its values was signalled at, and a host signal is
//    reached at once.
// A wait for a value nothing has been submitted to signal can't be given to the core, which only waits for
// values it has signalled: such a submission fails (VK_ERROR_FEATURE_NOT_PRESENT).

import GPUCore
import TDVulkan

final class FenceObject: CoreObject {
  var signaled: Bool
  /// The device value of the submission that signals it (0: none yet).
  var value: UInt64 = 0
  init(signaled: Bool) { self.signaled = signaled }

  func done(_ completed: UInt64) -> Bool { signaled || (value != 0 && completed >= value) }
}

final class SemaphoreObject: CoreObject {
  let timeline: Bool
  /// Binary: the device value that signalled it, or 0. Timeline: the highest value the host has signalled, or the first.
  var value: UInt64
  /// Timeline: each value a submission signals, with the device value it is reached at, in increasing order.
  var points: [(semaphore: UInt64, device: UInt64)] = []

  init(timeline: Bool, initial: UInt64) {
    self.timeline = timeline
    value = initial
  }

  /// The device value after which the semaphore has reached `v`: 0 if it already has, nil if no submission signals it.
  func deviceValue(reaching v: UInt64) -> UInt64? {
    if v <= value { return 0 }
    for p in points where p.semaphore >= v { return p.device }
    return nil
  }

  /// The timeline semaphore's value now.
  func counter(_ completed: UInt64) -> UInt64 {
    var c = value
    for p in points where p.device <= completed && p.semaphore > c { c = p.semaphore }
    return c
  }
}

func core_vkCreateFence(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkFenceCreateInfo>?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                        _ pFence: UnsafeMutablePointer<VkFence?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pFence else { return VK_ERROR_INITIALIZATION_FAILED }
  unsafe out.pointee = Handle.make(FenceObject(signaled: unsafe info.pointee.flags & VK_FENCE_CREATE_SIGNALED_BIT.rawValue != 0))
  return VK_SUCCESS
}

func core_vkDestroyFence(_ device: VkDevice?, _ fence: VkFence?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(fence)
}

func core_vkResetFences(_ device: VkDevice?, _ fenceCount: UInt32, _ pFences: UnsafePointer<VkFence?>?) -> VkResult {
  for i in 0..<Int(fenceCount) {
    if let f = unsafe Handle.get(pFences![i], FenceObject.self) {
      f.signaled = false
      f.value = 0
    }
  }
  return VK_SUCCESS
}

func core_vkGetFenceStatus(_ device: VkDevice?, _ fence: VkFence?) -> VkResult {
  guard let d = unsafe Handle.get(device, DeviceObject.self), let f = unsafe Handle.get(fence, FenceObject.self) else { return VK_ERROR_DEVICE_LOST }
  d.retire()
  return f.done(d.gpu.completed) ? VK_SUCCESS : VK_NOT_READY
}

/// Waits until the device reaches the values `needed` (all of them, or the first of any), within `timeout`: a
/// timeout of 0 only looks. The core's wait takes no time limit, so a longer one waits for the value.
func waitForValues(_ d: DeviceObject, _ needed: [UInt64?], all: Bool, timeout: UInt64) -> VkResult {
  let done = d.gpu.completed
  if all {
    if needed.contains(where: { $0 == nil }) { return VK_TIMEOUT }
    var top: UInt64 = 0
    for n in needed { top = max(top, n!) }
    if top <= done { return VK_SUCCESS }
    if timeout == 0 { return VK_TIMEOUT }
    do throws(GPUError) { try d.gpu.wait(top) } catch { return vkResult(error) }
    d.retire()
    return VK_SUCCESS
  }
  var first: UInt64?
  for n in needed {
    guard let n else { continue }
    if n <= done { return VK_SUCCESS }
    first = min(first ?? n, n)
  }
  guard let first else { return VK_TIMEOUT }
  if timeout == 0 { return VK_TIMEOUT }
  do throws(GPUError) { try d.gpu.wait(first) } catch { return vkResult(error) }
  d.retire()
  return VK_SUCCESS
}

func core_vkWaitForFences(_ device: VkDevice?, _ fenceCount: UInt32, _ pFences: UnsafePointer<VkFence?>?, _ waitAll: VkBool32,
                          _ timeout: UInt64) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self) else { return VK_ERROR_DEVICE_LOST }
  var needed: [UInt64?] = []
  for i in 0..<Int(fenceCount) {
    guard let f = unsafe Handle.get(pFences![i], FenceObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
    // A signalled fence is reached already; one no submission signals can't be.
    needed.append(f.signaled ? 0 : (f.value == 0 ? nil : f.value))
  }
  return waitForValues(d, needed, all: waitAll != 0, timeout: timeout)
}

func core_vkCreateSemaphore(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkSemaphoreCreateInfo>?,
                            _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pSemaphore: UnsafeMutablePointer<VkSemaphore?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pSemaphore else { return VK_ERROR_INITIALIZATION_FAILED }
  var timeline = false
  var initial: UInt64 = 0
  if let t = unsafe findStructure(info.pointee.pNext, VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO) {
    let c = unsafe t.load(as: VkSemaphoreTypeCreateInfo.self)
    timeline = unsafe c.semaphoreType == VK_SEMAPHORE_TYPE_TIMELINE
    initial = unsafe c.initialValue
  }
  unsafe out.pointee = Handle.make(SemaphoreObject(timeline: timeline, initial: timeline ? initial : 0))
  return VK_SUCCESS
}

func core_vkDestroySemaphore(_ device: VkDevice?, _ semaphore: VkSemaphore?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(semaphore)
}

func core_vkGetSemaphoreCounterValue(_ device: VkDevice?, _ semaphore: VkSemaphore?, _ pValue: UnsafeMutablePointer<UInt64>?) -> VkResult {
  guard let d = unsafe Handle.get(device, DeviceObject.self), let s = unsafe Handle.get(semaphore, SemaphoreObject.self), s.timeline else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  unsafe pValue?.pointee = s.counter(d.gpu.completed)
  return VK_SUCCESS
}

func core_vkSignalSemaphore(_ device: VkDevice?, _ pSignalInfo: UnsafePointer<VkSemaphoreSignalInfo>?) -> VkResult {
  guard let i = unsafe pSignalInfo, let s = unsafe Handle.get(i.pointee.semaphore, SemaphoreObject.self), s.timeline else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  s.value = max(s.value, unsafe i.pointee.value)
  return VK_SUCCESS
}

func core_vkWaitSemaphores(_ device: VkDevice?, _ pWaitInfo: UnsafePointer<VkSemaphoreWaitInfo>?, _ timeout: UInt64) -> VkResult {
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pWaitInfo else { return VK_ERROR_DEVICE_LOST }
  var needed: [UInt64?] = []
  for i in 0..<Int(unsafe info.pointee.semaphoreCount) {
    guard let s = unsafe Handle.get(info.pointee.pSemaphores[i], SemaphoreObject.self), s.timeline else {
      return VK_ERROR_INITIALIZATION_FAILED
    }
    needed.append(s.deviceValue(reaching: unsafe info.pointee.pValues[i]))
  }
  let any = unsafe info.pointee.flags & VK_SEMAPHORE_WAIT_ANY_BIT.rawValue != 0
  return waitForValues(d, needed, all: !any, timeout: timeout)
}

// MARK: Submission

struct SubmitSemaphore {
  var semaphore: SemaphoreObject
  var value: UInt64
}

/// The device value a batch waits for: the greatest its semaphores need (a binary semaphore is consumed), nil where one waits
/// for a value nothing signals.
func batchWait(_ waits: [SubmitSemaphore]) -> UInt64? {
  var wait: UInt64 = 0
  for w in waits {
    if w.semaphore.timeline {
      guard let v = w.semaphore.deviceValue(reaching: w.value) else {
        say("unsupported: a wait for a semaphore value no submission signals")
        return nil
      }
      wait = max(wait, v)
    } else {
      wait = max(wait, w.semaphore.value)
      w.semaphore.value = 0
    }
  }
  return wait
}

/// A batch's semaphores signalled at the device value `signal`.
func batchSignal(_ signals: [SubmitSemaphore], _ signal: UInt64) {
  for s in signals {
    if s.semaphore.timeline { s.semaphore.points.append((s.value, signal)) } else { s.semaphore.value = signal }
  }
}

/// One batch: it waits, runs the command buffers' lists in order, and signals.
func submitBatch(_ q: QueueObject, waits: [SubmitSemaphore], buffers: [CommandBufferObject], signals: [SubmitSemaphore]) -> (VkResult, UInt64) {
  let d = q.device
  guard let wait = batchWait(waits) else { return (VK_ERROR_FEATURE_NOT_PRESENT, 0) }
  var list = GPUCommandList()
  for b in buffers { list.append(contentsOf: b.list) }
  let signal = d.nextValue()
  do throws(GPUError) { try d.gpu.graphicsQueue.submit(list, wait: wait, signal: signal) } catch { return (vkResult(error), 0) }
  d.lastSubmitted = signal
  for b in buffers {
    b.pendingValue = signal
    d.inFlight.append(InFlight(value: signal, buffer: b))
    // The secondary buffers it executed are in flight with it, and its events are as it left them.
    for s in b.executed {
      s.pendingValue = signal
      d.inFlight.append(InFlight(value: signal, buffer: s))
    }
    for w in b.eventWrites { w.event.isSet = w.set }
  }
  batchSignal(signals, signal)
  d.retire()
  return (VK_SUCCESS, signal)
}

// MARK: Sparse binding

/// The semaphores of a submission's or a bind's arrays, with the values a VkTimelineSemaphoreSubmitInfo gives them.
func semaphores(_ count: UInt32, _ list: UnsafePointer<VkSemaphore?>?, _ values: UnsafePointer<UInt64>?) -> [SubmitSemaphore]? {
  var out: [SubmitSemaphore] = []
  for k in 0..<Int(count) {
    guard let sem = unsafe Handle.get(list![k], SemaphoreObject.self) else { return nil }
    out.append(SubmitSemaphore(semaphore: sem, value: unsafe values.map { unsafe $0[k] } ?? 0))
  }
  return out
}

/// The core's memory a sparse bind names: nil for VK_NULL_HANDLE (a range bound to nothing).
func boundMemory(_ m: VkDeviceMemory?) -> GPUMemory? {
  unsafe Handle.get(m, MemoryObject.self)?.gpu
}

/// The core's binds for one VkBindSparseInfo, or nil where it names a buffer or image that isn't sparse.
func sparseBindings(_ info: VkBindSparseInfo) -> SparseBindings? {
  var b = SparseBindings()
  for i in 0..<Int(unsafe info.bufferBindCount) {
    let bb = unsafe info.pBufferBinds[i]
    guard let buffer = unsafe Handle.get(bb.buffer, BufferObject.self), let sparse = buffer.sparse else { return nil }
    for k in 0..<Int(unsafe bb.bindCount) {
      let m = unsafe bb.pBinds[k]
      unsafe b.buffers.append(SparseBufferBind(buffer: sparse, offset: Int(m.resourceOffset), size: Int(m.size), memory: unsafe boundMemory(m.memory),
                                        memoryOffset: Int(m.memoryOffset)))
    }
  }
  for i in 0..<Int(unsafe info.imageOpaqueBindCount) {
    let ob = unsafe info.pImageOpaqueBinds[i]
    guard let image = unsafe Handle.get(ob.image, ImageObject.self) else { return nil }
    for k in 0..<Int(unsafe ob.bindCount) {
      let m = unsafe ob.pBinds[k]
      unsafe b.opaque.append(SparseImageOpaqueBind(image: image.image, offset: Int(m.resourceOffset), size: Int(m.size),
                                            memory: unsafe boundMemory(m.memory), memoryOffset: Int(m.memoryOffset),
                                            metadata: m.flags & VK_SPARSE_MEMORY_BIND_METADATA_BIT.rawValue != 0))
    }
  }
  for i in 0..<Int(unsafe info.imageBindCount) {
    let ib = unsafe info.pImageBinds[i]
    guard let image = unsafe Handle.get(ib.image, ImageObject.self) else { return nil }
    for k in 0..<Int(unsafe ib.bindCount) {
      let m = unsafe ib.pBinds[k]
      var aspects = ImageAspects(rawValue: 0)
      if unsafe m.subresource.aspectMask & VK_IMAGE_ASPECT_COLOR_BIT.rawValue != 0 { aspects = aspects | .color }
      if unsafe m.subresource.aspectMask & VK_IMAGE_ASPECT_DEPTH_BIT.rawValue != 0 { aspects = aspects | .depth }
      if unsafe m.subresource.aspectMask & VK_IMAGE_ASPECT_STENCIL_BIT.rawValue != 0 { aspects = aspects | .stencil }
      unsafe b.images.append(SparseImageBind(image: image.image, aspects: aspects, mip: m.subresource.mipLevel, layer: m.subresource.arrayLayer,
                                      offset: Offset3D(x: m.offset.x, y: m.offset.y, z: m.offset.z),
                                      extent: Extent3D(width: m.extent.width, height: m.extent.height, depth: m.extent.depth),
                                      memory: unsafe boundMemory(m.memory), memoryOffset: Int(m.memoryOffset)))
    }
  }
  return b
}

/// Each VkBindSparseInfo is a batch of the core's queue: it waits for its semaphores, binds in order with the submissions,
/// and signals the next device value.
func core_vkQueueBindSparse(_ queue: VkQueue?, _ bindInfoCount: UInt32, _ pBindInfo: UnsafePointer<VkBindSparseInfo>?, _ fence: VkFence?) -> VkResult {
  guard let q = unsafe Handle.get(queue, QueueObject.self) else { return VK_ERROR_DEVICE_LOST }
  let d = q.device
  var last: UInt64 = 0
  for i in 0..<Int(bindInfoCount) {
    let info = unsafe pBindInfo![i]
    var waitValues: UnsafePointer<UInt64>?
    var signalValues: UnsafePointer<UInt64>?
    if let t = unsafe findStructure(info.pNext, VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO) {
      let ti = unsafe t.load(as: VkTimelineSemaphoreSubmitInfo.self)
      unsafe waitValues = ti.pWaitSemaphoreValues
      unsafe signalValues = ti.pSignalSemaphoreValues
    }
    guard let waits = unsafe semaphores(info.waitSemaphoreCount, info.pWaitSemaphores, waitValues),
      let signals = unsafe semaphores(info.signalSemaphoreCount, info.pSignalSemaphores, signalValues)
    else { return VK_ERROR_INITIALIZATION_FAILED }
    guard let bindings = unsafe sparseBindings(info) else {
      say("invalid: a sparse bind of a buffer or image that isn't sparse")
      return VK_ERROR_INITIALIZATION_FAILED
    }
    guard let wait = batchWait(waits) else { return VK_ERROR_FEATURE_NOT_PRESENT }
    let signal = d.nextValue()
    do throws(GPUError) { try d.gpu.graphicsQueue.bindSparse(bindings, wait: wait, signal: signal) } catch { return vkResult(error) }
    d.lastSubmitted = signal
    batchSignal(signals, signal)
    d.retire()
    last = signal
  }
  return unsafe finishSubmit(q, fence, last)
}

func core_vkQueueSubmit(_ queue: VkQueue?, _ submitCount: UInt32, _ pSubmits: UnsafePointer<VkSubmitInfo>?, _ fence: VkFence?) -> VkResult {
  guard let q = unsafe Handle.get(queue, QueueObject.self) else { return VK_ERROR_DEVICE_LOST }
  var last: UInt64 = 0
  for i in 0..<Int(submitCount) {
    let s = unsafe pSubmits![i]
    // A timeline semaphore's values come with the submission.
    var waitValues: UnsafePointer<UInt64>?
    var signalValues: UnsafePointer<UInt64>?
    if let t = unsafe findStructure(s.pNext, VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO) {
      let ti = unsafe t.load(as: VkTimelineSemaphoreSubmitInfo.self)
      unsafe waitValues = ti.pWaitSemaphoreValues
      unsafe signalValues = ti.pSignalSemaphoreValues
    }
    var waits: [SubmitSemaphore] = []
    for k in 0..<Int(unsafe s.waitSemaphoreCount) {
      guard let sem = unsafe Handle.get(s.pWaitSemaphores[k], SemaphoreObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
      waits.append(SubmitSemaphore(semaphore: sem, value: unsafe waitValues.map { unsafe $0[k] } ?? 0))
    }
    var signals: [SubmitSemaphore] = []
    for k in 0..<Int(unsafe s.signalSemaphoreCount) {
      guard let sem = unsafe Handle.get(s.pSignalSemaphores[k], SemaphoreObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
      signals.append(SubmitSemaphore(semaphore: sem, value: unsafe signalValues.map { unsafe $0[k] } ?? 0))
    }
    var buffers: [CommandBufferObject] = []
    for k in 0..<Int(unsafe s.commandBufferCount) {
      guard let b = unsafe Handle.get(s.pCommandBuffers[k], CommandBufferObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
      buffers.append(b)
    }
    let (r, v) = submitBatch(q, waits: waits, buffers: buffers, signals: signals)
    if r != VK_SUCCESS { return r }
    last = v
  }
  return unsafe finishSubmit(q, fence, last)
}

func core_vkQueueSubmit2(_ queue: VkQueue?, _ submitCount: UInt32, _ pSubmits: UnsafePointer<VkSubmitInfo2>?, _ fence: VkFence?) -> VkResult {
  guard let q = unsafe Handle.get(queue, QueueObject.self) else { return VK_ERROR_DEVICE_LOST }
  var last: UInt64 = 0
  for i in 0..<Int(submitCount) {
    let s = unsafe pSubmits![i]
    var waits: [SubmitSemaphore] = []
    for k in 0..<Int(unsafe s.waitSemaphoreInfoCount) {
      let w = unsafe s.pWaitSemaphoreInfos[k]
      guard let sem = unsafe Handle.get(w.semaphore, SemaphoreObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
      waits.append(SubmitSemaphore(semaphore: sem, value: unsafe w.value))
    }
    var signals: [SubmitSemaphore] = []
    for k in 0..<Int(unsafe s.signalSemaphoreInfoCount) {
      let w = unsafe s.pSignalSemaphoreInfos[k]
      guard let sem = unsafe Handle.get(w.semaphore, SemaphoreObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
      signals.append(SubmitSemaphore(semaphore: sem, value: unsafe w.value))
    }
    var buffers: [CommandBufferObject] = []
    for k in 0..<Int(unsafe s.commandBufferInfoCount) {
      guard let b = unsafe Handle.get(s.pCommandBufferInfos[k].commandBuffer, CommandBufferObject.self) else {
        return VK_ERROR_INITIALIZATION_FAILED
      }
      buffers.append(b)
    }
    let (r, v) = submitBatch(q, waits: waits, buffers: buffers, signals: signals)
    if r != VK_SUCCESS { return r }
    last = v
  }
  return unsafe finishSubmit(q, fence, last)
}

/// The fence of a submission is the value of its last batch; a fence with no batch is signalled by an empty one.
func finishSubmit(_ q: QueueObject, _ fence: VkFence?, _ last: UInt64) -> VkResult {
  guard let f = unsafe Handle.get(fence, FenceObject.self) else { return VK_SUCCESS }
  var value = last
  if value == 0 {
    let (r, v) = submitBatch(q, waits: [], buffers: [], signals: [])
    if r != VK_SUCCESS { return r }
    value = v
  }
  f.signaled = false
  f.value = value
  return VK_SUCCESS
}
