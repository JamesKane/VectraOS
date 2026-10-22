// SPDX-License-Identifier: BSD-3-Clause

// The loader's driver registry on croi (M5g; M5k: loaded, not linked):
// Venus is lib/libvenus.so (graphics/vulkan/drivers/venus), which this
// loads with dlopen the first time the loader asks, handing it a channel
// to the program's /devices. The program's namespace is
// `GPUContext.namespace` if the program set it, else its Startup's. Like
// the hosted registry it speaks to the loader in standard types only. A
// program using it is todhchai_dlopen_host, with `libraries` in its
// manifest.

import GPUClient
import LibSys
import Launch
import Ld
import Node
import Sys

typealias DriverEntry = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?

@safe final class Loaded: @unchecked Sendable {
  var tried = false
  var entry: DriverEntry?
}
let loaded = Locked(Loaded())

/// Venus, loaded and given /devices; nil (said once) if it can't be.
func venus() -> DriverEntry? {
  unsafe loaded.withLock { l in
    if l.tried { return unsafe l.entry }
    l.tried = true
    if GPUContext.namespace == nil, let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)),
      let start = try? Startup(Handle(raw: raw))
    {
      GPUContext.namespace = start.namespace
    }
    guard let ns = GPUContext.namespace, let devices = try? ns.connect("/devices") else {
      print("vulkan: no /devices for a GPU")
      return nil
    }
    guard let library = DynamicLinker.open("libvenus.so"),
      let initialize = DynamicLinker.symbol("td_venus_init", in: library),
      let entry = DynamicLinker.symbol("td_venus_get_instance_proc_addr", in: library)
    else {
      print("vulkan: \(DynamicLinker.takeFailure() ?? "can't load libvenus.so")")
      return nil
    }
    typealias Initialize = @convention(c) (UInt32) -> Int32
    guard unsafe unsafeBitCast(initialize, to: Initialize.self)(devices.release()) == 0 else {
      print("vulkan: libvenus.so refused /devices")
      return nil
    }
    unsafe l.entry = unsafeBitCast(entry, to: DriverEntry.self)
    return unsafe l.entry
  }
}

@_silgen_name("td_vulkan_driver")
public func tdVulkanDriver(_ index: Int) -> (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)? {
  guard index == 0 else { return nil }
  return unsafe venus()
}
