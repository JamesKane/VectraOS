// SPDX-License-Identifier: BSD-3-Clause

// The loader's driver registry on the device (D121): Venus, linked in
// (graphics/vulkan/drivers/venus), connected the first time the loader asks
// to the process's GPUs (GPUContext's namespace, else the process's own).
// Statically linked, as tier 0 is: no dlopen.

import GPUClient
import Node
import Sys
import VenusDriver
import VX

typealias DriverEntry = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?

final class Registered: @unchecked Sendable {
  let lock = Lock()
  var tried = false
}
let registered = Registered()

@_silgen_name("td_vulkan_driver")
public func tdVulkanDriver(_ index: Int) -> (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)? {
  guard index == 0 else { return nil }
  registered.lock.withLock {
    guard !registered.tried else { return }
    registered.tried = true
    if GPUContext.namespace == nil { GPUContext.namespace = processNamespace() }
    VenusDriver.connect = { (try? GPUContext(capset: 4)).map { GPUVenusTransport($0) } }
  }
  return unsafe venusGetInstanceProcAddr
}
