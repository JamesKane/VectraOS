// SPDX-License-Identifier: BSD-3-Clause

// The Venus client driver over the GPU class (D121, after todhchai's
// libvenus.so): its transport on a GPU context, and its
// vkGetInstanceProcAddr, which the native registry gives the loader. It is
// linked into the program, as tier 0 is.

import GPUClient
import Node
import Sys
import VenusDriver

/// Venus's transport over a GPU context.
final class GPUVenusTransport: VenusTransport {
  let gpu: GPUContext
  init(_ gpu: GPUContext) { self.gpu = gpu }

  var capset: [UInt8] { gpu.capset }
  func lock() { gpu.lock() }
  func unlock() { gpu.unlock() }

  func createSharedMemory(size: Int) throws(VenusLost) -> (resource: UInt32, address: UnsafeMutableRawPointer) {
    guard let b = try? unsafe gpu.createBlob(id: 0, size: size, flags: VenusBlob.mappable), let address = unsafe b.address else {
      throw VenusLost()
    }
    return unsafe (b.resource, address)
  }

  func createBlob(id: UInt64, size: Int, flags: UInt32) throws(VenusLost)
    -> (resource: UInt32, address: UnsafeMutableRawPointer?)
  {
    do throws(GPUClientError) { return try unsafe gpu.createBlob(id: id, size: size, flags: flags) } catch {
      throw VenusLost()
    }
  }

  func release(resource: UInt32, address: UnsafeMutableRawPointer?, size: Int) { gpu.release(resource: resource) }

  func createSync(_ initial: UInt64) throws(VenusLost) -> UInt32 {
    do throws(GPUClientError) { return try gpu.createSync(initial) } catch { throw VenusLost() }
  }

  func destroySync(_ id: UInt32) { gpu.destroySync(id) }

  func readSync(_ id: UInt32) throws(VenusLost) -> UInt64 {
    do throws(GPUClientError) { return try gpu.readSync(id) } catch { throw VenusLost() }
  }

  func writeSync(_ id: UInt32, _ value: UInt64) throws(VenusLost) {
    do throws(GPUClientError) { try gpu.writeSync(id, value) } catch { throw VenusLost() }
  }

  func submit(_ stream: [UInt8], timeline: UInt32, syncs: [(id: UInt32, value: UInt64)]) throws(VenusLost) {
    do throws(GPUClientError) { try gpu.submit(stream, timeline: timeline, syncs: syncs) } catch { throw VenusLost() }
  }

  func wait(_ syncs: [(id: UInt32, value: UInt64)], any: Bool, timeoutNanoseconds: UInt64) throws(VenusLost) -> Bool {
    do throws(GPUClientError) { return try gpu.wait(syncs, any: any, timeoutNanoseconds: timeoutNanoseconds) } catch {
      throw VenusLost()
    }
  }

  func pause(nanoseconds: UInt64) { gpu.pause(nanoseconds: nanoseconds) }
  func exportVMO(resource: UInt32) -> UInt32? { gpu.duplicateVMO(resource: resource) }
  var canExportVMOs: Bool { true }
}

/// The driver's vkGetInstanceProcAddr, as the loader calls a driver's.
let venusGetInstanceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer? = {
  instance, name in unsafe unsafeBitCast(VenusDriver.procAddress(name), to: UnsafeRawPointer?.self)
}
