// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan commands the driver implements itself; the rest pass through
// to the renderer as generated (generated/Entries.swift). These are the
// ones that make objects with state, bind queues to timelines (§14.2),
// map memory through blobs (§13.2), keep fences on vtest syncs (§14.3),
// record command buffers, or that the renderer refuses (§16.3).

import TDVenus
import Venus

public enum VenusDriver {
  /// Connects a new instance's transport; set by whoever loads the driver,
  /// before its first instance.
  public static var connect: (() -> (any VenusTransport)?)? {
    get { settings.connect }
    set { settings.connect = newValue }
  }
  /// Whether contexts use a ring (§10); direct submission otherwise.
  public static var useRing: Bool {
    get { settings.useRing }
    set { settings.useRing = newValue }
  }

  /// The settings' storage: a class, so that both builds see them alike
  /// (set once, before the driver runs).
  final class Settings: @unchecked Sendable {
    var connect: (() -> (any VenusTransport)?)?
    var useRing = true
  }
  static let settings = Settings()
  /// What the driver reports: Vulkan 1.3, as `venusSelection`.
  public static let apiVersion: UInt32 = 1 << 22 | 3 << 12

  /// A command's entry point by name, or nil.
  public static func procAddress(_ name: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
    guard let name = unsafe name else { return nil }
    for entry in venusEntries {
      var i = 0
      let s = unsafe entry.name.utf8Start
      while unsafe s[i] != 0, unsafe UInt8(bitPattern: name[i]) == s[i] { i += 1 }
      if unsafe s[i] == 0 && name[i] == 0 { return entry.function }
    }
    return nil
  }
}

/// A command's result when the transport failed.
let lostResult = VK_ERROR_DEVICE_LOST

func state<T: VenusState>(_ h: OpaquePointer?, _ type: T.Type) -> T? { unsafe VenusHandle.state(h) as? T }

// MARK: Instance

func venus_vkEnumerateInstanceVersion(_ pApiVersion: UnsafeMutablePointer<UInt32>?) -> VkResult {
  unsafe pApiVersion?.pointee = VenusDriver.apiVersion
  return VK_SUCCESS
}

func venus_vkEnumerateInstanceExtensionProperties(_ pLayerName: UnsafePointer<CChar>?,
                                                  _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                                  _ pProperties: UnsafeMutablePointer<VkExtensionProperties>?) -> VkResult
{
  if unsafe pLayerName != nil { return VK_ERROR_LAYER_NOT_PRESENT }
  unsafe pPropertyCount?.pointee = 0
  return VK_SUCCESS
}

func venus_vkEnumerateInstanceLayerProperties(_ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                              _ pProperties: UnsafeMutablePointer<VkLayerProperties>?) -> VkResult
{
  unsafe pPropertyCount?.pointee = 0
  return VK_SUCCESS
}

func venus_vkCreateInstance(_ pCreateInfo: UnsafePointer<VkInstanceCreateInfo>?,
                            _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                            _ pInstance: UnsafeMutablePointer<VkInstance?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let pInstance = unsafe pInstance else { return VK_ERROR_INITIALIZATION_FAILED }
  // No layers, and no instance extensions yet (the renderer enables its own).
  if unsafe info.pointee.enabledLayerCount > 0 { return VK_ERROR_LAYER_NOT_PRESENT }
  if unsafe info.pointee.enabledExtensionCount > 0 { return VK_ERROR_EXTENSION_NOT_PRESENT }
  guard let transport = VenusDriver.connect?(), let context = try? VenusContext(transport, direct: !VenusDriver.useRing)
  else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let instance = InstanceState(context)
  do {
    return try context.locked { () throws(VenusLost) -> VkResult in
      let h = unsafe VenusHandle.make(id: context.newID(), state: instance, dispatchable: true)
      var handle: VkInstance? = unsafe h
      var copy = unsafe info.pointee
      let r = try unsafe context.call(Venus.vkCreateInstance_replySize(&copy, nil, &handle),
                                      { e in unsafe Venus.vkCreateInstance(&e, reply: true, &copy, nil, &handle) },
                                      { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                        try unsafe Venus.vkCreateInstance_reply(&d, &copy, nil, &handle)
                                      })
      guard r == VK_SUCCESS else {
        unsafe VenusHandle.free(h)
        return r
      }
      unsafe pInstance.pointee = h
      return r
    }
  } catch {
    return VK_ERROR_INITIALIZATION_FAILED
  }
}

func venus_vkDestroyInstance(_ instance: VkInstance?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let s = unsafe state(instance, InstanceState.self) else { return }
  let context = s.context
  _ = try? context.locked { () throws(VenusLost) in
    try context.send { e in unsafe Venus.vkDestroyInstance(&e, reply: false, instance, nil) }
    try context.flush()
  }
  for unsafe p in unsafe s.physicalDevices { unsafe VenusHandle.free(p) }
  unsafe VenusHandle.free(instance)
}

func venus_vkEnumeratePhysicalDevices(_ instance: VkInstance?, _ pPhysicalDeviceCount: UnsafeMutablePointer<UInt32>?,
                                      _ pPhysicalDevices: UnsafeMutablePointer<VkPhysicalDevice?>?) -> VkResult
{
  guard let s = unsafe state(instance, InstanceState.self), let pCount = unsafe pPhysicalDeviceCount else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let context = s.context
  do {
    try context.locked { () throws(VenusLost) in
      guard !s.enumerated else { return }
      // The count, then ids for that many, which binds them (§9).
      var count: UInt32 = 0
      _ = try unsafe context.call(Venus.vkEnumeratePhysicalDevices_replySize(instance, &count, nil),
                                  { e in unsafe Venus.vkEnumeratePhysicalDevices(&e, reply: true, instance, &count, nil) },
                                  { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                    try unsafe Venus.vkEnumeratePhysicalDevices_reply(&d, instance, &count, nil)
                                  })
      var handles: [VkPhysicalDevice?] = unsafe []
      var states: [PhysicalDeviceState] = []
      for _ in 0..<count {
        let p = PhysicalDeviceState(context)
        states.append(p)
        unsafe handles.append(VenusHandle.make(id: context.newID(), state: p, dispatchable: true))
      }
      if count > 0 {
        _ = try handles.withUnsafeMutableBufferPointer { b throws(VenusLost) -> VkResult in
          try unsafe context.call(Venus.vkEnumeratePhysicalDevices_replySize(instance, &count, b.baseAddress),
                                  { e in unsafe Venus.vkEnumeratePhysicalDevices(&e, reply: true, instance, &count, b.baseAddress) },
                                  { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                    try unsafe Venus.vkEnumeratePhysicalDevices_reply(&d, instance, &count, b.baseAddress)
                                  })
        }
      }
      for unsafe (h, p) in unsafe zip(handles, states) {
        try unsafe context.call(Venus.vkGetPhysicalDeviceMemoryProperties_replySize(h, &p.memory),
                                { e in unsafe Venus.vkGetPhysicalDeviceMemoryProperties(&e, reply: true, h, &p.memory) },
                                { (d: inout VenusDecoder) throws(VenusError) in
                                  try unsafe Venus.vkGetPhysicalDeviceMemoryProperties_reply(&d, h, &p.memory)
                                })
      }
      unsafe s.physicalDevices = handles.compactMap { unsafe $0 }
      s.enumerated = true
    }
  } catch {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let all = unsafe s.physicalDevices
  guard let out = unsafe pPhysicalDevices else {
    unsafe pCount.pointee = UInt32(all.count)
    return VK_SUCCESS
  }
  let n = unsafe min(Int(unsafe pCount.pointee), all.count)
  for i in 0..<n { unsafe out[i] = all[i] }
  unsafe pCount.pointee = UInt32(n)
  return unsafe n < all.count ? VK_INCOMPLETE : VK_SUCCESS
}

/// The version a physical device reports: no more than the driver's or
/// the renderer's protocol's (§15).
func clamp(_ version: UInt32, _ context: VenusContext) -> UInt32 {
  min(version, VenusDriver.apiVersion, context.rendererVersion & ~0xFFF)
}

func venus_vkGetPhysicalDeviceProperties(_ physicalDevice: VkPhysicalDevice?,
                                         _ pProperties: UnsafeMutablePointer<VkPhysicalDeviceProperties>?)
{
  guard let context = unsafe VenusHandle.context(physicalDevice), let p = unsafe pProperties else { return }
  _ = try? context.locked { () throws(VenusLost) in
    try unsafe context.call(Venus.vkGetPhysicalDeviceProperties_replySize(physicalDevice, p),
                            { e in unsafe Venus.vkGetPhysicalDeviceProperties(&e, reply: true, physicalDevice, p) },
                            { (d: inout VenusDecoder) throws(VenusError) in
                              try unsafe Venus.vkGetPhysicalDeviceProperties_reply(&d, physicalDevice, p)
                            })
  }
  unsafe p.pointee.apiVersion = clamp(p.pointee.apiVersion, context)
}

func venus_vkGetPhysicalDeviceProperties2(_ physicalDevice: VkPhysicalDevice?,
                                          _ pProperties: UnsafeMutablePointer<VkPhysicalDeviceProperties2>?)
{
  guard let context = unsafe VenusHandle.context(physicalDevice), let p = unsafe pProperties else { return }
  _ = try? context.locked { () throws(VenusLost) in
    try unsafe context.call(Venus.vkGetPhysicalDeviceProperties2_replySize(physicalDevice, p),
                            { e in unsafe Venus.vkGetPhysicalDeviceProperties2(&e, reply: true, physicalDevice, p) },
                            { (d: inout VenusDecoder) throws(VenusError) in
                              try unsafe Venus.vkGetPhysicalDeviceProperties2_reply(&d, physicalDevice, p)
                            })
  }
  unsafe p.pointee.properties.apiVersion = clamp(p.pointee.properties.apiVersion, context)
}

/// Extensions the driver implements itself, never sent to the renderer:
/// VK_FUCHSIA_external_memory where the transport can export a blob's VMO.
func clientExtensions(_ context: VenusContext) -> [StaticString] {
  context.canExportVMOs ? ["VK_FUCHSIA_external_memory"] : []
}

func venus_vkEnumerateDeviceExtensionProperties(_ physicalDevice: VkPhysicalDevice?, _ pLayerName: UnsafePointer<CChar>?,
                                                _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                                _ pProperties: UnsafeMutablePointer<VkExtensionProperties>?) -> VkResult
{
  if unsafe pLayerName != nil { return VK_ERROR_LAYER_NOT_PRESENT }
  guard let context = unsafe VenusHandle.context(physicalDevice), let pCount = unsafe pPropertyCount else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let ours = clientExtensions(context)  // core 1.3 and these, so far
  guard let out = unsafe pProperties else {
    unsafe pCount.pointee = UInt32(ours.count)
    return VK_SUCCESS
  }
  let n = min(Int(unsafe pCount.pointee), ours.count)
  for i in 0..<n {
    var p = VkExtensionProperties()
    p.specVersion = 1
    withUnsafeMutableBytes(of: &p.extensionName) { b in
      for unsafe (k, c) in unsafe UnsafeBufferPointer(start: ours[i].utf8Start, count: ours[i].utf8CodeUnitCount).enumerated() {
        unsafe b[k] = c
      }
    }
    unsafe out[i] = p
  }
  unsafe pCount.pointee = UInt32(n)
  return n < ours.count ? VK_INCOMPLETE : VK_SUCCESS
}

/// Whether C string `name` is one of `names`.
func listed(_ name: UnsafePointer<CChar>?, in names: [StaticString]) -> Bool {
  guard let name = unsafe name else { return false }
  return names.contains { n in
    var i = 0
    let s = unsafe n.utf8Start
    while unsafe s[i] != 0, unsafe UInt8(bitPattern: name[i]) == s[i] { i += 1 }
    return unsafe s[i] == 0 && name[i] == 0
  }
}

func venus_vkGetMemoryZirconHandleFUCHSIA(_ device: VkDevice?,
                                         _ pGetZirconHandleInfo: UnsafePointer<VkMemoryGetZirconHandleInfoFUCHSIA>?,
                                         _ pZirconHandle: UnsafeMutablePointer<zx_handle_t>?) -> VkResult
{
  guard let info = unsafe pGetZirconHandleInfo, let m = unsafe state(info.pointee.memory, MemoryState.self),
    m.resource != 0, let vmo = m.context.transport.exportVMO(resource: m.resource)
  else { return VK_ERROR_INVALID_EXTERNAL_HANDLE }
  unsafe pZirconHandle?.pointee = vmo
  return VK_SUCCESS
}

func venus_vkEnumerateDeviceLayerProperties(_ physicalDevice: VkPhysicalDevice?,
                                            _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                            _ pProperties: UnsafeMutablePointer<VkLayerProperties>?) -> VkResult
{
  unsafe pPropertyCount?.pointee = 0
  return VK_SUCCESS
}

func venus_vkGetInstanceProcAddr(_ instance: VkInstance?, _ pName: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  unsafe VenusDriver.procAddress(pName)
}

func venus_vkGetDeviceProcAddr(_ device: VkDevice?, _ pName: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  unsafe VenusDriver.procAddress(pName)
}

// MARK: Device and queues

func venus_vkCreateDevice(_ physicalDevice: VkPhysicalDevice?, _ pCreateInfo: UnsafePointer<VkDeviceCreateInfo>?,
                          _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                          _ pDevice: UnsafeMutablePointer<VkDevice?>?) -> VkResult
{
  guard let physical = unsafe state(physicalDevice, PhysicalDeviceState.self), let info = unsafe pCreateInfo,
    let pDevice = unsafe pDevice
  else { return VK_ERROR_INITIALIZATION_FAILED }
  // Only the driver's own extensions, which the renderer doesn't see.
  let context = physical.context
  for i in 0..<Int(unsafe info.pointee.enabledExtensionCount) {
    guard unsafe listed(info.pointee.ppEnabledExtensionNames?[i], in: clientExtensions(context)) else {
      return VK_ERROR_EXTENSION_NOT_PRESENT
    }
  }
  var forwarded = unsafe info.pointee
  unsafe forwarded.enabledExtensionCount = 0
  unsafe forwarded.ppEnabledExtensionNames = nil
  do {
    return try context.locked { () throws(VenusLost) -> VkResult in
      let device = DeviceState(context, physical: physical)
      let h = unsafe VenusHandle.make(id: context.newID(), state: device, dispatchable: true)
      unsafe device.handle = h
      var handle: VkDevice? = unsafe h
      let r = try unsafe context.call(Venus.vkCreateDevice_replySize(physicalDevice, &forwarded, nil, &handle),
                                      { e in unsafe Venus.vkCreateDevice(&e, reply: true, physicalDevice, &forwarded, nil, &handle) },
                                      { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                        try unsafe Venus.vkCreateDevice_reply(&d, physicalDevice, &forwarded, nil, &handle)
                                      })
      guard r == VK_SUCCESS else {
        unsafe VenusHandle.free(h)
        return r
      }
      // Every queue now, each bound to a timeline of its own (§14.2).
      for i in 0..<Int(unsafe info.pointee.queueCreateInfoCount) {
        let q = unsafe info.pointee.pQueueCreateInfos[i]
        for index in unsafe 0..<q.queueCount {
          guard let timeline = context.newTimeline() else { return VK_ERROR_TOO_MANY_OBJECTS }
          let queue = QueueState(context, device: device, timeline: timeline, sync: try context.transport.createSync(0))
          let qh = unsafe VenusHandle.make(id: context.newID(), state: queue, dispatchable: true)
          var qhandle: VkQueue? = unsafe qh
          var ring = unsafe VkDeviceQueueTimelineInfoMESA(sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_TIMELINE_INFO_MESA, pNext: nil,
                                                   ringIdx: timeline)
          try withUnsafePointer(to: &ring) { ring throws(VenusLost) in
            var queueInfo = unsafe VkDeviceQueueInfo2(sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2, pNext: UnsafeRawPointer(ring),
                                                      flags: q.flags, queueFamilyIndex: q.queueFamilyIndex, queueIndex: index)
            try context.send { e in unsafe Venus.vkGetDeviceQueue2(&e, reply: false, h, &queueInfo, &qhandle) }
          }
          unsafe device.queues.append((q.queueFamilyIndex, index, q.flags, qh))
        }
      }
      unsafe pDevice.pointee = h
      return r
    }
  } catch {
    return lostResult
  }
}

func venus_vkDestroyDevice(_ device: VkDevice?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let s = unsafe state(device, DeviceState.self) else { return }
  let context = s.context
  _ = try? context.locked { () throws(VenusLost) in
    try context.send { e in unsafe Venus.vkDestroyDevice(&e, reply: false, device, nil) }
    try context.flush()
  }
  for unsafe q in unsafe s.queues {
    if let qs = unsafe state(q.handle, QueueState.self) {
      context.transport.destroySync(qs.sync)
      unsafe VenusHandle.free(qs.idleFence)  // the device took the fence itself
    }
    unsafe VenusHandle.free(q.handle)
  }
  unsafe VenusHandle.free(device)
}

func venus_vkGetDeviceQueue(_ device: VkDevice?, _ queueFamilyIndex: UInt32, _ queueIndex: UInt32,
                            _ pQueue: UnsafeMutablePointer<VkQueue?>?)
{
  guard let s = unsafe state(device, DeviceState.self) else { return }
  unsafe pQueue?.pointee = s.queues.first { unsafe $0.family == queueFamilyIndex && $0.index == queueIndex && $0.flags == 0 }?.handle
}

func venus_vkGetDeviceQueue2(_ device: VkDevice?, _ pQueueInfo: UnsafePointer<VkDeviceQueueInfo2>?,
                             _ pQueue: UnsafeMutablePointer<VkQueue?>?)
{
  guard let s = unsafe state(device, DeviceState.self), let i = unsafe pQueueInfo?.pointee else { return }
  unsafe pQueue?.pointee = s.queues.first {
    unsafe $0.family == i.queueFamilyIndex && $0.index == i.queueIndex && $0.flags == i.flags
  }?.handle
}

/// A submission's stream: through the ring alone when the renderer waits on
/// fences itself, else on the queue's timeline with its sync's next value.
func submit(_ queue: VkQueue?, _ fence: VkFence?, _ encode: (inout VenusEncoder) -> Void) -> VkResult {
  guard let q = unsafe state(queue, QueueState.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  let context = q.context
  do {
    try context.locked { () throws(VenusLost) in
      var e = VenusEncoder()
      encode(&e)
      q.submitted += 1
      if context.rendererWaits {
        try context.send(e.bytes)
        return
      }
      try context.send(e.bytes, timeline: q.timeline, syncs: [(q.sync, q.submitted)])
      if let f = unsafe state(fence, FenceState.self) {
        f.sync = q.sync
        f.value = q.submitted
        f.signaled = false
      }
    }
    return VK_SUCCESS
  } catch {
    return lostResult
  }
}

func venus_vkQueueSubmit(_ queue: VkQueue?, _ submitCount: UInt32, _ pSubmits: UnsafePointer<VkSubmitInfo>?,
                         _ fence: VkFence?) -> VkResult
{
  unsafe submit(queue, fence) { e in unsafe Venus.vkQueueSubmit(&e, reply: false, queue, submitCount, pSubmits, fence) }
}

func venus_vkQueueSubmit2(_ queue: VkQueue?, _ submitCount: UInt32, _ pSubmits: UnsafePointer<VkSubmitInfo2>?,
                          _ fence: VkFence?) -> VkResult
{
  unsafe submit(queue, fence) { e in unsafe Venus.vkQueueSubmit2(&e, reply: false, queue, submitCount, pSubmits, fence) }
}

/// Fences waited on by the renderer, in calls of at most a second (a
/// call's reply is waited for a minute at most): VK_SUCCESS, VK_TIMEOUT
/// when `timeout` passes, or lost.
func rendererWait(_ context: VenusContext, _ device: VkDevice?, _ fences: UnsafePointer<VkFence?>?, _ count: UInt32,
                  waitAll: VkBool32, timeout: UInt64) -> VkResult
{
  var left = timeout
  while true {
    let chunk = min(left, 1_000_000_000)
    let r: VkResult
    do {
      r = try context.locked { () throws(VenusLost) -> VkResult in
        try unsafe context.call(Venus.vkWaitForFences_replySize(device, count, fences, waitAll, chunk),
                                { e in unsafe Venus.vkWaitForFences(&e, reply: true, device, count, fences, waitAll, chunk) },
                                { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                  try unsafe Venus.vkWaitForFences_reply(&d, device, count, fences, waitAll, chunk)
                                })
      }
    } catch {
      return lostResult
    }
    guard r == VK_TIMEOUT, left > chunk else { return r }
    if left != UInt64.max { left -= chunk }
  }
}

/// Until each queue's work is done: an empty submission with the queue's
/// own fence, waited on by the renderer; or each queue's sync.
func idle(_ queues: [QueueState]) -> VkResult {
  guard let context = queues.first?.context else { return VK_SUCCESS }
  if context.rendererWaits {
    for q in queues {
      guard let device = unsafe q.device.handle else { continue }
      do {
        try context.locked { () throws(VenusLost) in
          if unsafe q.idleFence == nil {
            var info = unsafe VkFenceCreateInfo()
            unsafe info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            var handle: VkFence? = unsafe VenusHandle.make(id: context.newID(), state: nil, dispatchable: false)
            _ = try unsafe context.call(Venus.vkCreateFence_replySize(device, &info, nil, &handle),
                                        { e in unsafe Venus.vkCreateFence(&e, reply: true, device, &info, nil, &handle) },
                                        { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                          try unsafe Venus.vkCreateFence_reply(&d, device, &info, nil, &handle)
                                        })
            unsafe q.idleFence = handle
          }
          let fence = unsafe q.idleFence
          let queueHandle = unsafe q.device.queues.first { unsafe state($0.handle, QueueState.self) === q }?.handle
          try context.send { e in unsafe Venus.vkQueueSubmit(&e, reply: false, queueHandle, 0, nil, fence) }
        }
      } catch {
        return lostResult
      }
      var fence = unsafe q.idleFence
      let r = unsafe rendererWait(context, device, &fence, 1, waitAll: 1, timeout: UInt64.max)
      guard r == VK_SUCCESS else { return r }
      _ = try? context.locked { () throws(VenusLost) in
        try context.send { e in unsafe Venus.vkResetFences(&e, reply: false, device, 1, &fence) }
      }
    }
    return VK_SUCCESS
  }
  let targets: [(id: UInt32, value: UInt64)]
  do {
    targets = try context.locked { () throws(VenusLost) in queues.map { ($0.sync, $0.submitted) } }
    guard try context.transport.wait(targets, any: false, timeoutNanoseconds: UInt64.max) else { return lostResult }
  } catch {
    return lostResult
  }
  return VK_SUCCESS
}

func venus_vkQueueWaitIdle(_ queue: VkQueue?) -> VkResult {
  guard let q = unsafe state(queue, QueueState.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  return idle([q])
}

func venus_vkDeviceWaitIdle(_ device: VkDevice?) -> VkResult {
  guard let s = unsafe state(device, DeviceState.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  return unsafe idle(s.queues.compactMap { unsafe state($0.handle, QueueState.self) })
}

// MARK: Fences

func venus_vkCreateFence(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkFenceCreateInfo>?,
                         _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                         _ pFence: UnsafeMutablePointer<VkFence?>?) -> VkResult
{
  guard let context = unsafe VenusHandle.context(device), let info = unsafe pCreateInfo, let pFence = unsafe pFence else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  do {
    return try context.locked { () throws(VenusLost) -> VkResult in
      let fence = FenceState(context)
      fence.signaled = unsafe info.pointee.flags & 1 != 0  // VK_FENCE_CREATE_SIGNALED_BIT
      let h = unsafe VenusHandle.make(id: context.newID(), state: fence, dispatchable: false)
      var handle: VkFence? = unsafe h
      let r = try unsafe context.call(Venus.vkCreateFence_replySize(device, info, nil, &handle),
                                      { e in unsafe Venus.vkCreateFence(&e, reply: true, device, info, nil, &handle) },
                                      { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                        try unsafe Venus.vkCreateFence_reply(&d, device, info, nil, &handle)
                                      })
      guard r == VK_SUCCESS else {
        unsafe VenusHandle.free(h)
        return r
      }
      unsafe pFence.pointee = h
      return r
    }
  } catch {
    return lostResult
  }
}

func venus_vkDestroyFence(_ device: VkDevice?, _ fence: VkFence?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let context = unsafe VenusHandle.context(device), unsafe fence != nil else { return }
  _ = try? context.locked { () throws(VenusLost) in
    try context.send { e in unsafe Venus.vkDestroyFence(&e, reply: false, device, fence, nil) }
  }
  unsafe VenusHandle.free(fence)
}

func venus_vkResetFences(_ device: VkDevice?, _ fenceCount: UInt32, _ pFences: UnsafePointer<VkFence?>?) -> VkResult {
  guard let context = unsafe VenusHandle.context(device) else { return VK_ERROR_INITIALIZATION_FAILED }
  do {
    try context.locked { () throws(VenusLost) in
      for i in 0..<Int(fenceCount) {
        if let f = unsafe state(pFences?[i], FenceState.self) {
          f.signaled = false
          f.value = 0
        }
      }
      try context.send { e in unsafe Venus.vkResetFences(&e, reply: false, device, fenceCount, pFences) }
    }
    return VK_SUCCESS
  } catch {
    return lostResult
  }
}

func venus_vkGetFenceStatus(_ device: VkDevice?, _ fence: VkFence?) -> VkResult {
  guard let f = unsafe state(fence, FenceState.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  if f.context.rendererWaits {
    do {
      return try f.context.locked { () throws(VenusLost) -> VkResult in
        try unsafe f.context.call(Venus.vkGetFenceStatus_replySize(device, fence),
                                  { e in unsafe Venus.vkGetFenceStatus(&e, reply: true, device, fence) },
                                  { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                    try unsafe Venus.vkGetFenceStatus_reply(&d, device, fence)
                                  })
      }
    } catch {
      return lostResult
    }
  }
  if f.signaled { return VK_SUCCESS }
  guard f.value > 0 else { return VK_NOT_READY }
  guard let now = try? f.context.transport.readSync(f.sync) else { return lostResult }
  return now >= f.value ? VK_SUCCESS : VK_NOT_READY
}

func venus_vkWaitForFences(_ device: VkDevice?, _ fenceCount: UInt32, _ pFences: UnsafePointer<VkFence?>?,
                           _ waitAll: VkBool32, _ timeout: UInt64) -> VkResult
{
  guard let context = unsafe VenusHandle.context(device) else { return VK_ERROR_INITIALIZATION_FAILED }
  if context.rendererWaits {
    return unsafe rendererWait(context, device, pFences, fenceCount, waitAll: waitAll, timeout: timeout)
  }
  var targets: [(id: UInt32, value: UInt64)] = []
  var done = 0, never = 0
  _ = try? context.locked { () throws(VenusLost) in
    for i in 0..<Int(fenceCount) {
      guard let f = unsafe state(pFences?[i], FenceState.self) else { continue }
      if f.signaled { done += 1 } else if f.value == 0 { never += 1 } else { targets.append((f.sync, f.value)) }
    }
  }
  if waitAll == 0 && done > 0 { return VK_SUCCESS }
  if targets.isEmpty { return never == 0 ? VK_SUCCESS : VK_TIMEOUT }
  if waitAll != 0 && never > 0 { return VK_TIMEOUT }  // never submitted since its reset: can't signal
  do {
    return try context.transport.wait(targets, any: waitAll == 0, timeoutNanoseconds: timeout) ? VK_SUCCESS : VK_TIMEOUT
  } catch {
    return lostResult
  }
}

// MARK: Memory

func venus_vkAllocateMemory(_ device: VkDevice?, _ pAllocateInfo: UnsafePointer<VkMemoryAllocateInfo>?,
                            _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                            _ pMemory: UnsafeMutablePointer<VkDeviceMemory?>?) -> VkResult
{
  guard let dev = unsafe state(device, DeviceState.self), let info = unsafe pAllocateInfo, let pMemory = unsafe pMemory else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let context = dev.context
  do {
    return try context.locked { () throws(VenusLost) -> VkResult in
      let memory = MemoryState(context)
      let id = context.newID()
      let h = unsafe VenusHandle.make(id: id, state: memory, dispatchable: false)
      var handle: VkDeviceMemory? = unsafe h
      // Host-visible memory in whole pages: the blob is mapped for its size,
      // and a hypervisor maps only whole pages into the guest (KVM emulates
      // a partly-mapped page's accesses, and can't emulate SSE ones).
      let index = Int(unsafe info.pointee.memoryTypeIndex)
      let flags = withUnsafeBytes(of: dev.physical.memory.memoryTypes) { b in
        unsafe b.load(fromByteOffset: index * MemoryLayout<VkMemoryType>.stride, as: VkMemoryType.self).propertyFlags
      }
      let hostVisible = index < 32 && flags & 2 != 0  // VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
      var sized = unsafe info.pointee
      if hostVisible { unsafe sized.allocationSize = unsafe (sized.allocationSize + 4095) & ~4095 }
      let r = try unsafe context.call(Venus.vkAllocateMemory_replySize(device, &sized, nil, &handle),
                                      { e in unsafe Venus.vkAllocateMemory(&e, reply: true, device, &sized, nil, &handle) },
                                      { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                        try unsafe Venus.vkAllocateMemory_reply(&d, device, &sized, nil, &handle)
                                      })
      guard r == VK_SUCCESS else {
        unsafe VenusHandle.free(h)
        return r
      }
      // Host-visible memory comes to us as a blob (§13.2).
      if hostVisible {
        let size = unsafe Int(sized.allocationSize)
        let blob = try unsafe context.transport.createBlob(id: id, size: size, flags: VenusBlob.mappable)
        memory.resource = unsafe blob.resource
        unsafe memory.address = blob.address
        memory.size = size
      }
      unsafe pMemory.pointee = h
      return r
    }
  } catch {
    return lostResult
  }
}

func venus_vkFreeMemory(_ device: VkDevice?, _ memory: VkDeviceMemory?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let m = unsafe state(memory, MemoryState.self) else { return }
  let context = m.context
  _ = try? context.locked { () throws(VenusLost) in
    if m.resource != 0 { unsafe context.transport.release(resource: m.resource, address: m.address, size: m.size) }
    try context.send { e in unsafe Venus.vkFreeMemory(&e, reply: false, device, memory, nil) }
  }
  unsafe VenusHandle.free(memory)
}

func venus_vkMapMemory(_ device: VkDevice?, _ memory: VkDeviceMemory?, _ offset: VkDeviceSize, _ size: VkDeviceSize,
                       _ flags: VkMemoryMapFlags, _ ppData: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> VkResult
{
  guard let m = unsafe state(memory, MemoryState.self), let address = unsafe m.address else {
    return VK_ERROR_MEMORY_MAP_FAILED
  }
  unsafe ppData?.pointee = address + Int(offset)
  return VK_SUCCESS
}

func venus_vkUnmapMemory(_ device: VkDevice?, _ memory: VkDeviceMemory?) {}

// Coherent through the blob's mapping (§13.2): nothing to do.
func venus_vkFlushMappedMemoryRanges(_ device: VkDevice?, _ memoryRangeCount: UInt32,
                                     _ pMemoryRanges: UnsafePointer<VkMappedMemoryRange>?) -> VkResult { VK_SUCCESS }

func venus_vkInvalidateMappedMemoryRanges(_ device: VkDevice?, _ memoryRangeCount: UInt32,
                                          _ pMemoryRanges: UnsafePointer<VkMappedMemoryRange>?) -> VkResult { VK_SUCCESS }

// MARK: Command buffers

func venus_vkAllocateCommandBuffers(_ device: VkDevice?, _ pAllocateInfo: UnsafePointer<VkCommandBufferAllocateInfo>?,
                                    _ pCommandBuffers: UnsafeMutablePointer<VkCommandBuffer?>?) -> VkResult
{
  guard let context = unsafe VenusHandle.context(device), let info = unsafe pAllocateInfo, let out = unsafe pCommandBuffers
  else { return VK_ERROR_INITIALIZATION_FAILED }
  let n = Int(unsafe info.pointee.commandBufferCount)
  do {
    return try context.locked { () throws(VenusLost) -> VkResult in
      for i in 0..<n {
        unsafe out[i] = VenusHandle.make(id: context.newID(), state: CommandBufferState(context), dispatchable: true)
      }
      let r = try unsafe context.call(Venus.vkAllocateCommandBuffers_replySize(device, info, out),
                                      { e in unsafe Venus.vkAllocateCommandBuffers(&e, reply: true, device, info, out) },
                                      { (d: inout VenusDecoder) throws(VenusError) -> VkResult in
                                        try unsafe Venus.vkAllocateCommandBuffers_reply(&d, device, info, out)
                                      })
      if r != VK_SUCCESS {
        for i in 0..<n {
          unsafe VenusHandle.free(out[i])
          unsafe out[i] = nil
        }
      }
      return r
    }
  } catch {
    return lostResult
  }
}

func venus_vkFreeCommandBuffers(_ device: VkDevice?, _ commandPool: VkCommandPool?, _ commandBufferCount: UInt32,
                                _ pCommandBuffers: UnsafePointer<VkCommandBuffer?>?)
{
  guard let context = unsafe VenusHandle.context(device), let p = unsafe pCommandBuffers else { return }
  _ = try? context.locked { () throws(VenusLost) in
    try context.send { e in
      unsafe Venus.vkFreeCommandBuffers(&e, reply: false, device, commandPool, commandBufferCount, p)
    }
  }
  for i in 0..<Int(commandBufferCount) { unsafe VenusHandle.free(p[i]) }
}

func venus_vkBeginCommandBuffer(_ commandBuffer: VkCommandBuffer?, _ pBeginInfo: UnsafePointer<VkCommandBufferBeginInfo>?)
  -> VkResult
{
  guard let cb = unsafe state(commandBuffer, CommandBufferState.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  cb.encoder = VenusEncoder()
  unsafe Venus.vkBeginCommandBuffer(&cb.encoder, reply: false, commandBuffer, pBeginInfo)
  return VK_SUCCESS
}

func venus_vkEndCommandBuffer(_ commandBuffer: VkCommandBuffer?) -> VkResult {
  guard let cb = unsafe state(commandBuffer, CommandBufferState.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  unsafe Venus.vkEndCommandBuffer(&cb.encoder, reply: false, commandBuffer)
  let stream = cb.encoder.bytes
  cb.encoder = VenusEncoder()
  do {
    try cb.context.locked { () throws(VenusLost) in try cb.context.send(stream) }
    return VK_SUCCESS
  } catch {
    return lostResult
  }
}

func venus_vkResetCommandBuffer(_ commandBuffer: VkCommandBuffer?, _ flags: VkCommandBufferResetFlags) -> VkResult {
  guard let cb = unsafe state(commandBuffer, CommandBufferState.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  cb.encoder = VenusEncoder()
  do {
    try cb.context.locked { () throws(VenusLost) in
      try cb.context.send { e in unsafe Venus.vkResetCommandBuffer(&e, reply: false, commandBuffer, flags) }
    }
    return VK_SUCCESS
  } catch {
    return lostResult
  }
}
