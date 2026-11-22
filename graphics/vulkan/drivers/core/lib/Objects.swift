// SPDX-License-Identifier: BSD-3-Clause

// The objects behind the layer's handles (D174 step 5). Every handle points at 16 bytes: the loader's word
// (ICD_LOADER_MAGIC until the loader puts its dispatch table there; 0 in non-dispatchable objects), then the
// object, retained. The objects are Swift classes; the core is Swift, and everything the layer keeps is a value
// or a class of its own, never a pointer into the application's structures.

import GPUCore
import TDVulkan
import VulkanLowering

/// The hooks whoever links the layer sets, once, before the loader creates an instance.
public enum CoreDriver {
  /// Makes the device the layer runs on (the registry's: `MaliDevice` on the board, `VulkanDevice` over Venus
  /// under QEMU). Called by `vkCreateInstance`; an instance fails with `VK_ERROR_INCOMPATIBLE_DRIVER` where it is
  /// nil or throws.
  nonisolated(unsafe) public static var device: (() throws(GPUError) -> any GPUDevice)?
  /// The lowering `vkCreate*Pipelines` runs each stage through: `lower` unless a test gives another.
  nonisolated(unsafe) public static var lowering:
    (([UInt32], ShaderStage, String, LoweringLayout, [SpecConstant]) throws(LoweringError) -> [UInt32]) = {
      (s, st, e, l, c) throws(LoweringError) in
      try lower(spirv: s, stage: st, entryPoint: e, layout: l, specialization: c)
    }
  /// Where the layer says why it refused something (the debug message that names a feature).
  nonisolated(unsafe) public static var message: ((String) -> Void)?
  /// The desktop's windows, which VK_KHR_surface and VK_KHR_swapchain present to (VK_VECTRA_window_surface opens one). Nil: the
  /// layer has no presentation, and says so in its extensions.
  nonisolated(unsafe) public static var windowSystem: (any WindowSystem)?
}

/// VK_ERROR_INVALID_SHADER_NV (the extension is not in the header): a shader the lowering or the core would not take.
let vkErrorInvalidShader = VkResult(rawValue: -1000012000)

func say(_ s: String) { unsafe CoreDriver.message?(s) }

class CoreObject {}

enum Handle {
  static let loaderMagic: UInt64 = 0x01CD_C0DE

  static func make(_ o: CoreObject, dispatchable: Bool = false) -> OpaquePointer {
    let p = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    unsafe p.storeBytes(of: dispatchable ? loaderMagic : 0, as: UInt64.self)
    unsafe p.storeBytes(of: UInt(bitPattern: Unmanaged.passRetained(o).toOpaque()), toByteOffset: 8, as: UInt.self)
    return OpaquePointer(p)
  }

  /// The object a handle names (not retained for the caller), if it is a `T`.
  static func get<T: CoreObject>(_ h: OpaquePointer?, _ type: T.Type) -> T? {
    guard let h = unsafe h else { return nil }
    let s = unsafe UnsafeRawPointer(h).load(fromByteOffset: 8, as: UInt.self)
    guard let p = unsafe UnsafeRawPointer(bitPattern: s) else { return nil }
    return unsafe Unmanaged<CoreObject>.fromOpaque(p).takeUnretainedValue() as? T
  }

  /// Frees a handle and drops its hold on the object.
  static func destroy(_ h: OpaquePointer?) {
    guard let h = unsafe h else { return }
    let p = unsafe UnsafeMutableRawPointer(h)
    let s = unsafe p.load(fromByteOffset: 8, as: UInt.self)
    if let o = unsafe UnsafeRawPointer(bitPattern: s) { unsafe Unmanaged<CoreObject>.fromOpaque(o).release() }
    unsafe p.deallocate()
  }
}

/// A core call's error as the Vulkan result for it.
func vkResult(_ e: GPUError) -> VkResult {
  switch e {
  case .unsupported(let why):
    say("unsupported: \(why)")
    return VK_ERROR_FEATURE_NOT_PRESENT
  case .invalid(let why):
    say("invalid: \(why)")
    return VK_ERROR_UNKNOWN
  case .outOfMemory: return VK_ERROR_OUT_OF_DEVICE_MEMORY
  case .failed(let what, _):
    say("failed: \(what)")
    return VK_ERROR_UNKNOWN
  case .noDevice: return VK_ERROR_INITIALIZATION_FAILED
  case .lost: return VK_ERROR_DEVICE_LOST
  }
}

func vkResult(_ e: LoweringError) -> VkResult {
  switch e {
  case .unsupported(let why):
    say("unsupported: \(why)")
    return VK_ERROR_FEATURE_NOT_PRESENT
  case .invalid(let why), .malformed(let why):
    say("invalid shader: \(why)")
    return vkErrorInvalidShader
  }
}

// MARK: Instance, physical device, device, queue

@safe final class InstanceObject: CoreObject {
  let gpu: any GPUDevice
  var physicalHandle: OpaquePointer?
  init(gpu: any GPUDevice) { self.gpu = gpu }
}

final class PhysicalDeviceObject: CoreObject {
  let gpu: any GPUDevice
  init(gpu: any GPUDevice) { self.gpu = gpu }
}

final class QueueObject: CoreObject {
  let device: DeviceObject
  init(device: DeviceObject) { self.device = device }
}

/// A submission's command buffer, kept while the timeline has not reached its value.
struct InFlight {
  var value: UInt64
  var buffer: CommandBufferObject
}

@safe final class DeviceObject: CoreObject {
  let gpu: any GPUDevice
  var queueHandle: OpaquePointer?
  /// The highest timeline value this device's submissions signal.
  var lastSubmitted: UInt64 = 0
  var inFlight: [InFlight] = []
  /// Arena chunks to free once the timeline reaches their value.
  var retired: [(value: UInt64, memory: GPUMemory)] = []
  var textureSlots: [Bool]
  var samplerSlots: [Bool]
  var storageSlots: [Bool]
  /// The heap's uniform and storage texel-buffer slots in use.
  var texelSlots: [Bool]
  var storageTexelSlots: [Bool]

  init(gpu: any GPUDevice) {
    self.gpu = gpu
    let l = gpu.limits
    textureSlots = [Bool](repeating: false, count: Int(l.heapTextures))
    samplerSlots = [Bool](repeating: false, count: Int(l.heapSamplers))
    storageSlots = [Bool](repeating: false, count: Int(l.heapStorageImages))
    texelSlots = [Bool](repeating: false, count: Int(l.heapTexelBuffers))
    storageTexelSlots = [Bool](repeating: false, count: Int(l.heapStorageTexelBuffers))
  }

  var features: DeviceFeatures { gpu.limits.features }

  /// The next value this device's timeline can be signalled to.
  func nextValue() -> UInt64 { max(lastSubmitted, gpu.completed) + 1 }

  /// Frees the arena memory the timeline has passed; the command buffers that held it let go.
  func retire() {
    let done = gpu.completed
    var i = 0
    while i < retired.count {
      if retired[i].value <= done {
        gpu.free(retired[i].memory)
        retired.remove(at: i)
      } else {
        i += 1
      }
    }
    i = 0
    while i < inFlight.count {
      if inFlight[i].value <= done { inFlight.remove(at: i) } else { i += 1 }
    }
  }

  /// Waits for everything submitted, and retires.
  func waitIdle() -> VkResult {
    if lastSubmitted > 0 {
      do throws(GPUError) { try gpu.wait(lastSubmitted) } catch { return vkResult(error) }
    }
    retire()
    return VK_SUCCESS
  }

  func takeSlot(_ slots: inout [Bool]) -> UInt32? {
    for i in slots.indices where !slots[i] {
      slots[i] = true
      return UInt32(i)
    }
    return nil
  }
}
