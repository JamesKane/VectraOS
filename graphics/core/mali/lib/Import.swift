// SPDX-License-Identifier: BSD-3-Clause

// Memory and images over another process's pages (gpucore(2); panthor 04 section 4.8.3.1 and 09 section 9.6.4, 11 section
// 11.7.1): `exportHandle` gives a handle to the VMO behind memory, `exportWindowHandle` one behind a window's image (a
// `scanout` image, with its row stride), and `importHandle` maps the pages of such a handle into this device's VM as the owner's
// were bound (memory GPU-cacheable, as a client's memory is; an image write-combining, as a scanout image is), and into this process, as the VMO's owner
// mapped them (write-combining, for what this backend exports). The pages are the other process's too, so they are
// non-coherent for the CPU of either: nothing here takes it that a CPU write in the other process is visible without a
// barrier the writer made; what the GPU reads is what the owner had made visible when the submission was made, and every
// stream's end cleans the GPU's caches (CSBuilder.cleanCachesForHost) and every job begins with the driver's clean and invalidate, so a
// later submission reads what was written in between, through either mapping.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

extension MaliDevice {
  /// A new handle to the VMO behind `memory`: for another process to be given, which maps it (or imports it) as it likes.
  public func exportHandle(_ memory: GPUMemory) -> UInt32? {
    guard let region = memories[memory.handle] else { return nil }
    return region.buffer.exportMappableVMO()
  }

  /// A new handle to a `scanout` image's pages that another process may map and import (`importHandle(_:as:rowBytes:)`), and
  /// its row stride: a window's image (`makePresentImage`), where `exportHandle(_:)` gives the display's, which can't map them.
  /// Its rows are as every linear image's here, `width * 4` bytes rounded up to 64.
  public func exportWindowHandle(_ image: GPUImage) -> (handle: UInt32, rowBytes: Int)? {
    guard let r = images[image.handle], r.descriptor.usage.contains(.scanout), r.descriptor.format.bytesPerPixel == 4,
      r.descriptor.mipLevels == 1, r.descriptor.layers == 1, let handle = r.region.buffer.exportMappableVMO()
    else { return nil }
    return (handle, r.rowStride)
  }

  public func importHandle(_ vmo: UInt32, intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard bytes > 0 else { throw .invalid("an import of no bytes") }
    reclaim()
    let region = try makeImportedRegion(vmo, bytes: bytes, gpuCacheable: true)
    let handle = memories.insert(region)
    return unsafe GPUMemory(handle: handle, address: region.address, pointer: intent == .device ? nil : region.buffer.pointer,
                            size: bytes, intent: intent)
  }

  /// An image over the pages of `vmo` from its start: one level and layer of four-byte texels in rows `rowBytes` apart. The
  /// row stride of a linear plane must be a multiple of 64 bytes (valhall 05 section 5.5.5, R1.1, and 03 section 3.9.8: the
  /// texture unit reads zeros from any other), and as the reference does, an import that breaks it is refused, with no copy
  /// to fall back on (R1.4). Its plane descriptors can't follow its texels (the pages are the owner's), so every view of it
  /// has an array of its own.
  public func importHandle(_ vmo: UInt32, as d: ImageDescriptor, rowBytes: Int) throws(GPUError) -> GPUImage {
    guard d.dimension == .d2, d.mipLevels == 1, d.layers == 1, d.samples == 1, !d.format.isCompressed, !d.format.isDepthStencil,
      d.format.bytesPerPixel == 4
    else { throw .unsupported("an imported image that isn't one level and layer of four-byte texels") }
    guard rowBytes % ImageLayout.alignment == 0, rowBytes >= Int(d.width) * 4 else {
      throw .unsupported("an imported image of rows \(rowBytes) bytes apart: a linear plane's rows are a multiple of 64 bytes, at least its width")
    }
    var plain = d
    plain.usage = d.usage.contains(.scanout) ? d.usage : d.usage | .scanout
    if let e = plain.check(limits: baseLimits) { throw e }
    guard let texel = d.format.texelFormat(aspect: .color) else { throw .unsupported("an imported image of \(d.format)") }
    reclaim()
    let layout = ImageLayout(format: texel, kind: .linear, width: Int(d.width), height: Int(d.height), rowStride: rowBytes)
    let region = try makeImportedRegion(vmo, bytes: rowBytes * Int(d.height), gpuCacheable: false)
    let record = ImageRecord(region: region, descriptor: d, rowStride: rowBytes, layout: layout, planeAt: nil)
    record.planes = [AspectPlane(aspect: .color, layout: layout, offset: 0, texel: texel)]
    return GPUImage(handle: images.insert(record), descriptor: d)
  }

  /// The pages of `vmo` mapped here and bound in the VM. A window's image is bound write-combining, as its owner's scanout image is:
  /// the texture unit only reads it, so the L2 holding its lines buys nothing, and every process that touches the pages then maps
  /// them alike. Memory is GPU-cacheable, as a client's own is, so shader atomics work in it.
  func makeImportedRegion(_ vmo: UInt32, bytes: Int, gpuCacheable: Bool) throws(GPUError) -> Region {
    let size = (bytes + 4095) & ~4095
    let buffer = try transport.importBuffer(vmo: vmo, size: size)
    let address: UInt64
    do { address = try takeAddress(size) } catch {
      transport.destroyBuffer(buffer)
      throw error
    }
    do { try transport.bind(vm: vm, buffer: buffer, address: address, gpuCacheable: gpuCacheable) } catch {
      transport.destroyBuffer(buffer)
      throw error
    }
    return Region(buffer: buffer, address: address, size: buffer.size)
  }
}
