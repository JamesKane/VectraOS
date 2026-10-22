// SPDX-License-Identifier: BSD-3-Clause

// Our Vulkan loader (M5f; architecture §10, principle 29): the Vulkan C ABI
// over the drivers a program is built with, no layers. Written from the
// loader-driver interface Khronos publishes ("Architecture of the Vulkan
// Loader Interfaces"): a driver gives out its commands through its
// vk_icdGetInstanceProcAddr, and leaves the first word of each dispatchable
// object for the loader, which puts the driver's dispatch table there
// (generated/Dispatch.swift's trampolines read it).
//
// Drivers come from a static registry, `td_vulkan_driver`, which whoever
// builds the program supplies (in standard types only: a driver's C header
// and ours declare the same types differently, so no file imports both) (the hosted libtdvulkan.so: Venus over vtest;
// natively: Venus over croi's GPU class). An instance is ours: it holds an
// instance of every driver that made one, and its physical devices are
// theirs, in registry order.

import TDVulkan

/// A driver in the registry: its name and its vk_icdGetInstanceProcAddr,
/// in plain pointers (VkInstance, a name, PFN_vkVoidFunction).
@safe public struct VulkanDriver {
  public let name: StaticString
  public let getInstanceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?

  public init(name: StaticString,
              getInstanceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)
  {
    self.name = name
    unsafe self.getInstanceProcAddr = getInstanceProcAddr
  }

  var gipa: PFN_vkGetInstanceProcAddr { unsafe unsafeBitCast(getInstanceProcAddr, to: PFN_vkGetInstanceProcAddr.self) }
}

/// The registry: driver `index`'s vk_icdGetInstanceProcAddr, or nil past
/// the last, from whoever links the program.
@_silgen_name("td_vulkan_driver")
func registeredDriver(_ index: Int) -> (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)?

/// The drivers this program has, in registry order.
func registeredDrivers() -> [VulkanDriver] {
  var all: [VulkanDriver] = []
  var i = 0
  while let gipa = unsafe registeredDriver(i) {
    unsafe all.append(VulkanDriver(name: "", getInstanceProcAddr: gipa))
    i += 1
  }
  return all
}

func loaderName(_ s: StaticString) -> UnsafePointer<CChar> {
  unsafe UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self)
}

/// Our instance: every driver's, with its table.
@safe final class LoaderInstance {
  var drivers: [(instance: VkInstance?, table: UnsafeMutablePointer<VulkanInstanceTable>, gipa: PFN_vkGetInstanceProcAddr)] =
    unsafe []
  var physicalDevices: [VkPhysicalDevice?]?

  /// The handle the application holds: 16 bytes, the loader's word, then us.
  static func handle(_ i: LoaderInstance) -> VkInstance {
    let p = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    unsafe p.storeBytes(of: 0x01CD_C0DE, as: UInt.self)
    unsafe p.storeBytes(of: UInt(bitPattern: Unmanaged.passRetained(i).toOpaque()), toByteOffset: 8, as: UInt.self)
    return OpaquePointer(p)
  }

  static func from(_ h: VkInstance?) -> LoaderInstance? {
    guard let h = unsafe h else { return nil }
    let s = unsafe UnsafeRawPointer(h).load(fromByteOffset: 8, as: UInt.self)
    guard let p = unsafe UnsafeRawPointer(bitPattern: s) else { return nil }
    return unsafe Unmanaged<LoaderInstance>.fromOpaque(p).takeUnretainedValue()
  }
}

/// The first driver's instance and table, for instance-level commands.
func loaderFirstDriver(_ instance: VkInstance?) -> (UnsafeMutablePointer<VulkanInstanceTable>, VkInstance?)? {
  guard let i = unsafe LoaderInstance.from(instance), let d = unsafe i.drivers.first else { return nil }
  return unsafe (d.table, d.instance)
}

/// A dispatchable object's table: its first word.
func loaderInstanceTable(_ h: OpaquePointer?) -> UnsafeMutablePointer<VulkanInstanceTable>? {
  guard let h = unsafe h else { return nil }
  return unsafe UnsafeRawPointer(h).load(as: UnsafeMutablePointer<VulkanInstanceTable>?.self)
}

func loaderDeviceTable(_ h: OpaquePointer?) -> UnsafeMutablePointer<VulkanDeviceTable>? {
  guard let h = unsafe h else { return nil }
  return unsafe UnsafeRawPointer(h).load(as: UnsafeMutablePointer<VulkanDeviceTable>?.self)
}

/// Puts a table in a driver's object's first word (where it left the magic).
func loaderSetTable(_ h: OpaquePointer?, _ table: UnsafeMutableRawPointer) {
  guard let h = unsafe h else { return }
  unsafe UnsafeMutableRawPointer(h).storeBytes(of: table, as: UnsafeMutableRawPointer.self)
}

/// A device's record: its table, then its driver's vkGetDeviceProcAddr.
enum LoaderDevice {
  static var size: Int { unsafe MemoryLayout<VulkanDeviceTable>.stride + MemoryLayout<PFN_vkGetDeviceProcAddr?>.stride }
  static func gdpa(_ table: UnsafeMutablePointer<VulkanDeviceTable>) -> PFN_vkGetDeviceProcAddr? {
    unsafe UnsafeRawPointer(table).load(fromByteOffset: MemoryLayout<VulkanDeviceTable>.stride,
                                        as: PFN_vkGetDeviceProcAddr?.self)
  }
}

func equal(_ a: UnsafePointer<CChar>?, _ b: StaticString) -> Bool {
  guard let a = unsafe a else { return false }
  var i = 0
  let s = unsafe b.utf8Start
  while unsafe s[i] != 0, unsafe UInt8(bitPattern: a[i]) == s[i] { i += 1 }
  return unsafe s[i] == 0 && a[i] == 0
}

// MARK: Global commands

@c(vkCreateInstance)
public func vkCreateInstance(_ pCreateInfo: UnsafePointer<VkInstanceCreateInfo>?,
                             _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                             _ pInstance: UnsafeMutablePointer<VkInstance?>?) -> VkResult
{
  guard let pInstance = unsafe pInstance else { return VK_ERROR_INITIALIZATION_FAILED }
  let instance = LoaderInstance()
  var last = VK_ERROR_INCOMPATIBLE_DRIVER
  for driver in registeredDrivers() {
    let gipa = unsafe driver.gipa
    guard let create = unsafe unsafeBitCast(gipa(nil, loaderName("vkCreateInstance")), to: PFN_vkCreateInstance?.self)
    else { continue }
    var made: VkInstance?
    let r = unsafe create(pCreateInfo, pAllocator, &made)
    guard r == VK_SUCCESS, let made = unsafe made else {
      last = r
      continue
    }
    let table = UnsafeMutablePointer<VulkanInstanceTable>.allocate(capacity: 1)
    unsafe table.initialize(to: VulkanInstanceTable(gipa, made))
    unsafe loaderSetTable(made, UnsafeMutableRawPointer(table))
    unsafe instance.drivers.append((made, table, gipa))
  }
  guard unsafe !instance.drivers.isEmpty else { return last }
  unsafe pInstance.pointee = LoaderInstance.handle(instance)
  return VK_SUCCESS
}

@c(vkDestroyInstance)
public func vkDestroyInstance(_ instance: VkInstance?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let i = unsafe LoaderInstance.from(instance), let h = unsafe instance else { return }
  for unsafe d in unsafe i.drivers {
    unsafe d.table.pointee.vkDestroyInstance?(d.instance, pAllocator)
    unsafe d.table.deinitialize(count: 1)
    unsafe d.table.deallocate()
  }
  let p = unsafe UnsafeMutableRawPointer(h)
  unsafe Unmanaged<LoaderInstance>.fromOpaque(UnsafeRawPointer(bitPattern: p.load(fromByteOffset: 8, as: UInt.self))!).release()
  unsafe p.deallocate()
}

@c(vkEnumerateInstanceVersion)
public func vkEnumerateInstanceVersion(_ pApiVersion: UnsafeMutablePointer<UInt32>?) -> VkResult {
  // The highest any driver reports (a driver without the command is 1.0).
  var version: UInt32 = 1 << 22
  for driver in registeredDrivers() {
    let gipa = unsafe driver.gipa
    if let f = unsafe unsafeBitCast(gipa(nil, loaderName("vkEnumerateInstanceVersion")),
                                    to: PFN_vkEnumerateInstanceVersion?.self)
    {
      var v: UInt32 = 0
      if unsafe f(&v) == VK_SUCCESS { version = max(version, v) }
    }
  }
  unsafe pApiVersion?.pointee = version
  return VK_SUCCESS
}

@c(vkEnumerateInstanceExtensionProperties)
public func vkEnumerateInstanceExtensionProperties(_ pLayerName: UnsafePointer<CChar>?,
                                                   _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                                   _ pProperties: UnsafeMutablePointer<VkExtensionProperties>?) -> VkResult
{
  if unsafe pLayerName != nil { return VK_ERROR_LAYER_NOT_PRESENT }
  guard let pCount = unsafe pPropertyCount else { return VK_ERROR_INITIALIZATION_FAILED }
  // Every driver's, once each.
  var all: [VkExtensionProperties] = []
  for driver in registeredDrivers() {
    let gipa = unsafe driver.gipa
    guard let f = unsafe unsafeBitCast(gipa(nil, loaderName("vkEnumerateInstanceExtensionProperties")),
                                       to: PFN_vkEnumerateInstanceExtensionProperties?.self)
    else { continue }
    var n: UInt32 = 0
    guard unsafe f(nil, &n, nil) == VK_SUCCESS, n > 0 else { continue }
    var some = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(n))
    guard unsafe f(nil, &n, &some) == VK_SUCCESS else { continue }
    for e in some.prefix(Int(n)) where !all.contains(where: { a in
      withUnsafeBytes(of: a.extensionName) { x in withUnsafeBytes(of: e.extensionName) { y in unsafe x.elementsEqual(y) } }
    }) { all.append(e) }
  }
  guard let out = unsafe pProperties else {
    unsafe pCount.pointee = UInt32(all.count)
    return VK_SUCCESS
  }
  let n = min(Int(unsafe pCount.pointee), all.count)
  for i in 0..<n { unsafe out[i] = all[i] }
  unsafe pCount.pointee = UInt32(n)
  return n < all.count ? VK_INCOMPLETE : VK_SUCCESS
}

@c(vkEnumerateInstanceLayerProperties)
public func vkEnumerateInstanceLayerProperties(_ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                               _ pProperties: UnsafeMutablePointer<VkLayerProperties>?) -> VkResult
{
  unsafe pPropertyCount?.pointee = 0  // no layers
  return VK_SUCCESS
}

@c(vkEnumerateDeviceLayerProperties)
public func vkEnumerateDeviceLayerProperties(_ physicalDevice: VkPhysicalDevice?,
                                             _ pPropertyCount: UnsafeMutablePointer<UInt32>?,
                                             _ pProperties: UnsafeMutablePointer<VkLayerProperties>?) -> VkResult
{
  unsafe pPropertyCount?.pointee = 0
  return VK_SUCCESS
}

@c(vkEnumeratePhysicalDevices)
public func vkEnumeratePhysicalDevices(_ instance: VkInstance?, _ pPhysicalDeviceCount: UnsafeMutablePointer<UInt32>?,
                                       _ pPhysicalDevices: UnsafeMutablePointer<VkPhysicalDevice?>?) -> VkResult
{
  guard let i = unsafe LoaderInstance.from(instance), let pCount = unsafe pPhysicalDeviceCount else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  if unsafe i.physicalDevices == nil {
    var all: [VkPhysicalDevice?] = unsafe []
    for unsafe d in unsafe i.drivers {
      guard let f = unsafe d.table.pointee.vkEnumeratePhysicalDevices else { continue }
      var n: UInt32 = 0
      guard unsafe f(d.instance, &n, nil) == VK_SUCCESS, n > 0 else { continue }
      var some = unsafe [VkPhysicalDevice?](repeating: nil, count: Int(n))
      guard unsafe f(d.instance, &n, &some) == VK_SUCCESS else { continue }
      for unsafe p in unsafe some.prefix(Int(n)) {
        unsafe loaderSetTable(p, UnsafeMutableRawPointer(d.table))
        unsafe all.append(p)
      }
    }
    unsafe i.physicalDevices = all
  }
  let all = unsafe i.physicalDevices ?? []
  guard let out = unsafe pPhysicalDevices else {
    unsafe pCount.pointee = UInt32(all.count)
    return VK_SUCCESS
  }
  let n = unsafe min(Int(pCount.pointee), all.count)
  for k in 0..<n { unsafe out[k] = all[k] }
  unsafe pCount.pointee = UInt32(n)
  return unsafe n < all.count ? VK_INCOMPLETE : VK_SUCCESS
}

/// A command's entry point, if it is of `levels` and a driver has it.
func lookup(_ pName: UnsafePointer<CChar>?, levels: [Int], has: (StaticString) -> Bool) -> PFN_vkVoidFunction? {
  for e in loaderEntries where unsafe equal(pName, e.name) {
    guard levels.contains(e.level) else { return nil }
    let ours = loaderHandwrittenNames.contains { unsafe equal(pName, $0) }
    return ours || has(e.name) ? e.function : nil
  }
  return nil
}

/// The loader's own commands, which it always gives out.
let loaderHandwrittenNames: [StaticString] = [
  "vkCreateInstance", "vkDestroyInstance", "vkEnumerateInstanceVersion", "vkEnumerateInstanceExtensionProperties",
  "vkEnumerateInstanceLayerProperties", "vkEnumeratePhysicalDevices", "vkGetInstanceProcAddr", "vkGetDeviceProcAddr",
  "vkEnumerateDeviceLayerProperties",
]

@c(vkGetInstanceProcAddr)
public func vkGetInstanceProcAddr(_ instance: VkInstance?, _ pName: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  guard let i = unsafe LoaderInstance.from(instance) else {
    return unsafe lookup(pName, levels: [0]) { _ in true }
  }
  // Any level's command, if one of the instance's drivers gives it out.
  return unsafe lookup(pName, levels: [0, 1, 2, 3]) { name in
    unsafe i.drivers.contains { d in unsafe d.gipa(d.instance, loaderName(name)) != nil }
  }
}

@c(vkGetDeviceProcAddr)
public func vkGetDeviceProcAddr(_ device: VkDevice?, _ pName: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  guard let t = unsafe loaderDeviceTable(device) else { return nil }
  let gdpa = unsafe LoaderDevice.gdpa(t)
  return unsafe lookup(pName, levels: [3]) { name in unsafe gdpa?(device, loaderName(name)) != nil }
}

// MARK: Devices and their dispatchable objects

@c(vkCreateDevice)
public func vkCreateDevice(_ physicalDevice: VkPhysicalDevice?, _ pCreateInfo: UnsafePointer<VkDeviceCreateInfo>?,
                           _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                           _ pDevice: UnsafeMutablePointer<VkDevice?>?) -> VkResult
{
  guard let t = unsafe loaderInstanceTable(physicalDevice), let create = unsafe t.pointee.vkCreateDevice,
    let gdpa = unsafe t.pointee.vkGetDeviceProcAddr, let pDevice = unsafe pDevice
  else { return VK_ERROR_INITIALIZATION_FAILED }
  let r = unsafe create(physicalDevice, pCreateInfo, pAllocator, pDevice)
  guard r == VK_SUCCESS else { return r }
  let record = UnsafeMutableRawPointer.allocate(byteCount: LoaderDevice.size, alignment: 8)
  let table = unsafe record.bindMemory(to: VulkanDeviceTable.self, capacity: 1)
  unsafe table.initialize(to: VulkanDeviceTable(gdpa, pDevice.pointee))
  unsafe (record + MemoryLayout<VulkanDeviceTable>.stride).storeBytes(of: Optional(gdpa), as: PFN_vkGetDeviceProcAddr?.self)
  unsafe loaderSetTable(pDevice.pointee, record)
  return r
}

@c(vkDestroyDevice)
public func vkDestroyDevice(_ device: VkDevice?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let t = unsafe loaderDeviceTable(device) else { return }
  unsafe t.pointee.vkDestroyDevice?(device, pAllocator)
  unsafe t.deinitialize(count: 1)
  unsafe UnsafeMutableRawPointer(t).deallocate()
}

@c(vkGetDeviceQueue)
public func vkGetDeviceQueue(_ device: VkDevice?, _ queueFamilyIndex: UInt32, _ queueIndex: UInt32,
                             _ pQueue: UnsafeMutablePointer<VkQueue?>?)
{
  guard let t = unsafe loaderDeviceTable(device), let f = unsafe t.pointee.vkGetDeviceQueue else { return }
  unsafe f(device, queueFamilyIndex, queueIndex, pQueue)
  unsafe loaderSetTable(pQueue?.pointee, UnsafeMutableRawPointer(t))
}

@c(vkGetDeviceQueue2)
public func vkGetDeviceQueue2(_ device: VkDevice?, _ pQueueInfo: UnsafePointer<VkDeviceQueueInfo2>?,
                              _ pQueue: UnsafeMutablePointer<VkQueue?>?)
{
  guard let t = unsafe loaderDeviceTable(device), let f = unsafe t.pointee.vkGetDeviceQueue2 else { return }
  unsafe f(device, pQueueInfo, pQueue)
  unsafe loaderSetTable(pQueue?.pointee, UnsafeMutableRawPointer(t))
}

@c(vkAllocateCommandBuffers)
public func vkAllocateCommandBuffers(_ device: VkDevice?, _ pAllocateInfo: UnsafePointer<VkCommandBufferAllocateInfo>?,
                                     _ pCommandBuffers: UnsafeMutablePointer<VkCommandBuffer?>?) -> VkResult
{
  guard let t = unsafe loaderDeviceTable(device), let f = unsafe t.pointee.vkAllocateCommandBuffers else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let r = unsafe f(device, pAllocateInfo, pCommandBuffers)
  guard r == VK_SUCCESS, let out = unsafe pCommandBuffers else { return r }
  for i in 0..<Int(unsafe pAllocateInfo?.pointee.commandBufferCount ?? 0) {
    unsafe loaderSetTable(out[i], UnsafeMutableRawPointer(t))
  }
  return r
}
