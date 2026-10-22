// SPDX-License-Identifier: BSD-3-Clause

// The loader's driver registry on the host (M5f): Venus over vtest
// ($VTEST_SOCKET_NAME). libtdvulkan.so is our loader with this; natively,
// a registry of its own gives Venus over croi's GPU class. It speaks to the
// loader in standard types only (Loader.swift: the two C headers can't meet
// in one file).

import VenusDriver
import VenusVtest

@_silgen_name("td_vulkan_driver")
public func tdVulkanDriver(_ index: Int) -> (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)? {
  guard index == 0 else { return nil }
  if VenusDriver.connect == nil { VenusDriver.connect = { try? VtestTransport() } }
  return { _, name in unsafe unsafeBitCast(VenusDriver.procAddress(name), to: UnsafeRawPointer?.self) }
}
