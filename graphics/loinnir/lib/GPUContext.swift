// SPDX-License-Identifier: BSD-3-Clause

// The device Loinnir renders with (D174 section 5): a core device, whichever
// backend the platform opened for it. Loinnir's own code calls the core
// (graphics/core, gpucore(2)) and nothing under it; what picks the backend is
// the platform's (hosted/Platform.swift: Vulkan; native/Present.swift: the
// native driver of a GPU that offers `csf`, else Vulkan over Venus).

import GPUCore

// The Vulkan vocabulary is still Loinnir's error's: its users read a failed call's name and result.
@_exported import Vulkan

public enum LoinnirError: Error, Equatable {
  case vulkan(VulkanError)
  /// The window refused (its error, in words: the SDK is the device's).
  case window(String)
  /// No device is the compositor's, or none can render what it takes, or this one's driver doesn't do it yet.
  case unsupported(String)
}

extension LoinnirError {
  /// A core error as Loinnir's has always said it: a failed call carries its name and result as a Vulkan
  /// failure (whichever backend failed), a missing loader is a missing loader, the rest are `unsupported`.
  init(_ e: GPUError) {
    switch e {
    case .failed(let call, let code): self = .vulkan(.failed(call, VkResult(rawValue: code)))
    case .noDevice(let why): self = why.utf8.elementsEqual("no Vulkan loader".utf8) ? .vulkan(.noLoader) : .unsupported(why)
    case .unsupported(let why): self = .unsupported(why)
    case .invalid(let why): self = .unsupported("invalid: " + why)
    case .outOfMemory(let what): self = .unsupported("out of memory: " + what)
    case .lost: self = .unsupported("the GPU was lost")
    }
  }
}

/// The GPU Loinnir draws with.
@safe public final class GPUContext {
  /// The core device: a backend of `graphics/core`.
  public let core: any GPUDevice
  public var name: String { core.name }
  /// Which backend drives it: "vulkan" or "mali".
  public var backend: String { core.backend }

  /// Whether textures can be sampled from the heap on this GPU (a driver may not have them yet).
  public var canSample: Bool { core.limits.features.sampledImages }

  init(core: any GPUDevice) { self.core = core }

  /// A device with no window: the platform's choice (the first discrete GPU, or the one the board offers).
  public convenience init() throws(LoinnirError) {
    loinnirPlatformSetup()
    do { self.init(core: try loinnirOpenDevice()) } catch { throw LoinnirError(error) }
  }
}
